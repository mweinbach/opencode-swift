import Synchronization
import OpenCodePlatform

/// A one-shot result that any number of tasks can wait for; the first completion wins. Waiting is cancellable.
final class MachineDeferred<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var waiters: [Int: CheckedContinuation<Value, any Error>] = [:]
        var nextWaiter = 0
    }

    private let state = Mutex(State())

    init() {}

    var isDone: Bool { state.withLock { $0.result != nil } }

    /// Completes with `result` unless already complete. Returns whether this call completed it.
    @discardableResult
    func complete(_ result: Result<Value, any Error>) -> Bool {
        let waiters: [CheckedContinuation<Value, any Error>]? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = result
            let all = Array(s.waiters.values)
            s.waiters.removeAll()
            return all
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(with: result) }
        return true
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool { complete(.success(value)) }

    @discardableResult
    func fail(_ error: any Error) -> Bool { complete(.failure(error)) }

    func wait() async throws -> Value {
        let id = state.withLock { s -> Int in
            s.nextWaiter += 1
            return s.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let ready: Result<Value, any Error>? = state.withLock { s in
                    if let result = s.result { return result }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    s.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// Port of `core/src/machine/driver.ts`: a machine reached through a worker that dials in.
public enum MachineDriver {
    /// How long a start whose connection was lost waits for the worker to come back before it is reported unknown.
    static let startGrace: Duration = .seconds(15)
    /// `CrossSpawnSpawner.RELEASE_FORCE_KILL_AFTER`.
    static let releaseForceKillAfter: Duration = .seconds(3)

    // parity: core/src/machine/driver.ts#NotSent [status=implemented hash=473edd59cbd7]
    public struct NotSent: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machine.NotSent"
        public let machine: String

        public init(machine: String) { self.machine = machine }

        // parity: core/src/machine/driver.ts#NotSent.message [status=implemented hash=598cbdf18157]
        public var message: String { "\(machine) is offline, command not sent" }
        public var description: String { message }
    }

    // parity: core/src/machine/driver.ts#Unknown [status=implemented hash=5861ea4e7a3b]
    public struct Unknown: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machine.Unknown"
        public let machine: String

        public init(machine: String) { self.machine = machine }

        // parity: core/src/machine/driver.ts#Unknown.message [status=implemented hash=4f1d10bc0706]
        public var message: String { "Lost connection to \(machine). The command may or may not have started." }
        public var description: String { message }
    }

    /// The worker no longer has a process: it restarted, or it forgot the process.
    // parity: core/src/machine/driver.ts#ProcessLost [status=implemented hash=803e3e1d67ae]
    public struct ProcessLost: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "Machine.ProcessLost"
        public let machine: String
        public let restarted: Bool

        public init(machine: String, restarted: Bool) {
            self.machine = machine
            self.restarted = restarted
        }

        // parity: core/src/machine/driver.ts#ProcessLost.message [status=implemented hash=65815cd3413e]
        public var message: String {
            restarted
                ? "\(machine)'s worker restarted, the process was lost"
                : "\(machine)'s worker no longer has the process"
        }

        public var description: String { message }
    }

    /// A start the worker refused, with the worker's reason.
    public struct StartFailed: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { message }
    }

    /// A process option a machine cannot honour.
    public struct Unsupported: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let machine: String
        public let what: String
        public init(machine: String, what: String) {
            self.machine = machine
            self.what = what
        }
        public var description: String { "\(what) not supported on \(machine)" }
    }

    /// One connection from the worker, as the endpoint that accepted it hands it over.
    // parity: core/src/machine/driver.ts#Connection [status=implemented hash=29fc9134a455]
    public struct Connection: Sendable {
        public let hello: MachineWire.Hello
        /// Queues the message and returns. A message queued on a connection that is lost is dropped. Called while the
        /// machine's state is locked, so it must not call back into the machine.
        public let send: @Sendable (MachineWire.ToWorker) -> Void
        /// The messages after `hello`. Ends when the connection is lost.
        public let messages: AsyncStream<MachineWire.FromWorker>

        public init(
            hello: MachineWire.Hello,
            send: @escaping @Sendable (MachineWire.ToWorker) -> Void,
            messages: AsyncStream<MachineWire.FromWorker>
        ) {
            self.hello = hello
            self.send = send
            self.messages = messages
        }
    }

    // parity: core/src/machine/driver.ts#Interface [status=implemented hash=2773bad43234]
    public protocol Interface: Sendable {
        var environment: any CoreLocation.Environment.Interface { get }
        /// Serves one connection until it is lost. A newer connection replaces it: the one being served counts as lost
        /// the moment the newer one arrives, and its end changes nothing after that.
        func connect(_ connection: Connection) async
        /// Ends the machine for good: loses its connection and fails every process still tracked with `error`, so
        /// nothing waits on an instance that will not be used again.
        func close(_ error: any Error)
        /// The hello of the connection being served, if there is one.
        func hello() -> MachineWire.Hello?
    }

    /// A machine reached through a worker that dials in: its environment, and where the worker's connections arrive.
    // parity: core/src/machine/driver.ts#make [status=adapted hash=b2df7cb9b47d]
    public static func make(_ id: String) -> any Interface {
        Machine(id: id)
    }

    // MARK: - Machine

    final class Link: Sendable {
        let hello: MachineWire.Hello
        let send: @Sendable (MachineWire.ToWorker) -> Void
        let lost = MachineDeferred<Void>()

        init(hello: MachineWire.Hello, send: @escaping @Sendable (MachineWire.ToWorker) -> Void) {
            self.hello = hello
            self.send = send
        }
    }

    final class Process: Sendable {
        let started = MachineDeferred<Int>()
        let exited = MachineDeferred<Finished>()
    }

    /// A process's exit with every byte of its merged output.
    struct Finished: Sendable {
        let exit: MachineWire.Exit
        let output: [UInt8]
    }

    struct Tracked {
        let process: Process
        /// Bytes of output passed on so far, which is where an attach resumes.
        var delivered = 0
        var output: [UInt8] = []
    }

    struct State {
        var processes: [MachineWire.ProcessID: Tracked] = [:]
        var link: Link?
        /// File calls sent on the current link and not yet answered.
        var calls: [Int: (link: Link, reply: MachineDeferred<MachineWire.FileReply>)] = [:]
        var next = MachineDeferred<Link>()
        /// The worker behind the newest connection. Every process in `processes` was started on it.
        var instance: MachineWire.Instance?
        var req = 0
    }

    // Each change to this state, with the messages it sends, is one locked step: nothing else runs half-way through
    // one, so a command is never reported unsent after it was sent.
    final class Machine: Interface, Sendable {
        let id: String
        let state = Mutex(State())

        init(id: String) {
            self.id = id
        }

        var environment: any CoreLocation.Environment.Interface {
            CoreLocation.Environment.Service(
                id: CoreLocation.Environment.ID.make(id),
                files: Files(machine: self),
                spawner: Spawner(machine: self)
            )
        }

        func hello() -> MachineWire.Hello? {
            state.withLock { $0.link?.hello }
        }

        /// The current link, or the next one to arrive.
        func online() async throws -> Link {
            let (current, next) = state.withLock { ($0.link, $0.next) }
            if let current { return current }
            return try await next.wait()
        }

        // Idempotent, so a replaced connection ending later changes nothing.
        static func lose(_ current: Link, machine: String, in s: inout State) {
            if s.link === current { s.link = nil }
            current.lost.succeed(())
            for (req, call) in s.calls where call.link === current {
                s.calls.removeValue(forKey: req)
                call.reply.fail(Unknown(machine: machine))
            }
        }

        // The process will not be heard from again: whoever waits on it gets `error`.
        static func gone(_ processID: MachineWire.ProcessID, error: any Error, in s: inout State) {
            guard let tracked = s.processes.removeValue(forKey: processID) else { return }
            tracked.process.started.fail(error)
            tracked.process.exited.fail(error)
        }

        func close(_ error: any Error) {
            state.withLock { s in
                if let link = s.link { Self.lose(link, machine: id, in: &s) }
                for processID in Array(s.processes.keys) { Self.gone(processID, error: error, in: &s) }
            }
        }

        func connect(_ connection: Connection) async {
            let current = Link(hello: connection.hello, send: connection.send)
            state.withLock { s in
                if let link = s.link { Self.lose(link, machine: id, in: &s) }
                let restarted = connection.hello.instance != s.instance
                s.instance = connection.hello.instance
                var listed: [MachineWire.ProcessID: MachineWire.HelloProcess] = [:]
                for entry in connection.hello.processes { listed[entry.id] = entry }
                // A release is safe to repeat, so one lost with an earlier connection is sent again. Running ones are left alone.
                for entry in connection.hello.processes where entry.state == .exited && s.processes[entry.id] == nil {
                    current.send(.release(id: entry.id))
                }
                for (processID, tracked) in s.processes {
                    if let entry = listed[processID], !restarted {
                        // Settles a start whose reply was lost with the last connection.
                        tracked.process.started.succeed(entry.pid)
                        current.send(.attach(id: processID, from: tracked.delivered))
                        continue
                    }
                    // A start the same worker does not list never reached it, so a retry is safe. A new worker lost
                    // everything, and the same one may have forgotten a process it ran.
                    let error: any Error
                    if tracked.process.started.isDone {
                        error = ProcessLost(machine: id, restarted: restarted)
                    } else if restarted {
                        error = Unknown(machine: id)
                    } else {
                        error = NotSent(machine: id)
                    }
                    Self.gone(processID, error: error, in: &s)
                }
                s.link = current
                s.next.succeed(current)
                s.next = MachineDeferred()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await message in connection.messages {
                        self.receive(current, message)
                    }
                }
                group.addTask {
                    _ = try? await current.lost.wait()
                }
                await group.next()
                group.cancelAll()
            }
            state.withLock { s in Self.lose(current, machine: id, in: &s) }
        }

        func receive(_ current: Link, _ message: MachineWire.FromWorker) {
            state.withLock { s in
                guard s.link === current else { return }
                switch message {
                case .hello:
                    return
                case .fs(let reply):
                    if let call = s.calls.removeValue(forKey: reply.req) { call.reply.succeed(reply) }
                case .started(let processID, let pid):
                    s.processes[processID]?.process.started.succeed(pid)
                case .failed(let processID, let request, let text):
                    guard s.processes[processID] != nil else { return }
                    // A refused start never ran, and a refused attach means the worker no longer has the process. A
                    // refused kill changes nothing: the exit still arrives through the attach, or the attach is refused too.
                    switch request {
                    case .start: Self.gone(processID, error: StartFailed(message: text), in: &s)
                    case .attach: Self.gone(processID, error: ProcessLost(machine: id, restarted: false), in: &s)
                    case .kill: return
                    }
                case .output(let processID, let offset, let data):
                    guard var tracked = s.processes[processID] else { return }
                    // A chunk past what was delivered follows a lost one; the exit's byte count attaches again from the gap.
                    if offset > tracked.delivered { return }
                    let skip = min(tracked.delivered - offset, data.count)
                    let fresh = data[skip...]
                    tracked.delivered += fresh.count
                    tracked.output += fresh
                    s.processes[processID] = tracked
                case .exit(let exit):
                    guard let tracked = s.processes[exit.id] else { return }
                    if exit.bytes > tracked.delivered {
                        current.send(.attach(id: exit.id, from: tracked.delivered))
                        return
                    }
                    s.processes.removeValue(forKey: exit.id)
                    current.send(.release(id: exit.id))
                    tracked.process.exited.succeed(Finished(exit: exit, output: tracked.output))
                }
            }
        }

        // MARK: Processes

        /// Until the process is gone, sends the signal on each connection as it becomes current, as a kill is safe to repeat.
        func terminate(_ processID: MachineWire.ProcessID, _ process: Process, signal: MachineWire.Signal) async {
            if process.exited.isDone { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await process.exited.wait() }
                group.addTask {
                    while !Task.isCancelled {
                        guard let current = try? await self.online() else { return }
                        current.send(.kill(id: processID, signal: signal))
                        _ = try? await current.lost.wait()
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }

        func stop(_ processID: MachineWire.ProcessID, _ process: Process, signal: MachineWire.Signal, forceKillAfter: Duration?) async {
            guard let forceKillAfter else {
                await terminate(processID, process, signal: signal)
                return
            }
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await self.terminate(processID, process, signal: signal)
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: forceKillAfter)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finished { await terminate(processID, process, signal: .SIGKILL) }
        }

        /// Stopped like a local process when the run that spawned it is cancelled, a start still unanswered included,
        /// but never waiting for a machine that is away: a process still there is forgotten.
        func release(_ processID: MachineWire.ProcessID, _ process: Process, killSignal: MachineWire.Signal) async {
            let link = state.withLock { $0.link }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.stop(processID, process, signal: killSignal, forceKillAfter: MachineDriver.releaseForceKillAfter)
                }
                group.addTask {
                    if let link { _ = try? await link.lost.wait() }
                }
                await group.next()
                group.cancelAll()
            }
            _ = state.withLock { $0.processes.removeValue(forKey: processID) }
        }

        func spawn(_ spec: ProcessSpec) async throws -> CoreLocation.Environment.SpawnedProcess {
            if let stdin = spec.stdin, !stdin.isEmpty { throw Unsupported(machine: id, what: "stdin is") }
            guard let cwd = spec.workingDirectory else {
                throw Unsupported(machine: id, what: "a command without a working directory is")
            }
            let killSignal = MachineWire.Signal.SIGTERM
            let processID = MachineWire.ProcessID(MachineDriver.randomUUID())
            let process = Process()
            // The worker's own environment is the base: the server's never crosses.
            let start = MachineWire.ToWorker.start(
                id: processID,
                argv: [spec.executable] + spec.arguments,
                cwd: cwd,
                env: spec.environment ?? [:]
            )
            // Registered and sent in one step, on the connection that is current in that step.
            let live: Link = try state.withLock { s in
                guard let link = s.link else { throw NotSent(machine: id) }
                s.processes[processID] = Tracked(process: process)
                link.send(start)
                return link
            }
            let pid: Int
            do {
                pid = try await withThrowingTaskGroup(of: Int.self) { group in
                    group.addTask { try await process.started.wait() }
                    group.addTask {
                        try await live.lost.wait()
                        try await Task.sleep(for: MachineDriver.startGrace)
                        throw Unknown(machine: self.id)
                    }
                    defer { group.cancelAll() }
                    guard let pid = try await group.next() else { throw CancellationError() }
                    return pid
                }
            } catch is CancellationError {
                await cancelled(processID, process, killSignal: killSignal)
                throw CancellationError()
            } catch {
                state.withLock { s in Self.gone(processID, error: error, in: &s) }
                throw error
            }
            return CoreLocation.Environment.SpawnedProcess(
                pid: pid,
                wait: { [self] in
                    let finished: Finished
                    do {
                        finished = try await process.exited.wait()
                    } catch is CancellationError {
                        await self.cancelled(processID, process, killSignal: killSignal)
                        throw CancellationError()
                    }
                    guard let code = finished.exit.code else {
                        throw CrossSpawnSpawner.KilledBySignal(signal: finished.exit.signal ?? killSignal.rawValue)
                    }
                    return ProcessOutput(exitCode: Int32(truncatingIfNeeded: code), stdout: finished.output, stderr: [])
                },
                stop: { [self] in
                    await self.release(processID, process, killSignal: killSignal)
                }
            )
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            let handle = try await spawn(spec)
            return try await handle.wait()
        }

        /// Runs the release in a task of its own, so the cancellation that called for it cannot cut it short.
        private func cancelled(_ processID: MachineWire.ProcessID, _ process: Process, killSignal: MachineWire.Signal) async {
            await Task.detached { await self.release(processID, process, killSignal: killSignal) }.value
        }

        // MARK: Files

        // The worker keeps the `Files` contract: each call is answered with its own result and only the refusals it allows.
        func call(_ path: String, _ request: MachineWire.Call) async throws -> MachineWire.FileResult {
            typealias Files = CoreLocation.Environment.Files
            let (callID, reply): (Int, MachineDeferred<MachineWire.FileReply>) = try state.withLock { s in
                guard let current = s.link else { throw Files.Failed(path: path, cause: NotSent(machine: id)) }
                s.req += 1
                let callID = s.req
                let reply = MachineDeferred<MachineWire.FileReply>()
                s.calls[callID] = (current, reply)
                current.send(.fs(MachineWire.FileCall(req: callID, call: request)))
                return (callID, reply)
            }
            let answer: MachineWire.FileReply
            do {
                defer { _ = state.withLock { $0.calls.removeValue(forKey: callID) } }
                answer = try await reply.wait()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Files.Failed(path: path, cause: error)
            }
            switch answer.outcome {
            case .success(let result):
                return result
            case .failure(let error):
                if error.kind == .notFound { throw Files.NotFound(path: path) }
                if error.kind == .wrongKind, let actual = error.actual { throw Files.WrongKind(path: path, actual: actual) }
                throw Files.Failed(path: path, message: error.message)
            }
        }
    }

    static func randomUUID() -> String {
        var bytes = MachineCrypto.randomBytes(16)
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { byte -> String in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    struct Spawner: CoreLocation.Environment.SpawnableProcessSpawner {
        let machine: Machine
        func spawn(_ spec: ProcessSpec) async throws -> CoreLocation.Environment.SpawnedProcess {
            try await machine.spawn(spec)
        }
        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            try await machine.run(spec)
        }
    }

    struct Files: CoreLocation.Environment.Files.Interface {
        typealias Env = CoreLocation.Environment.Files
        let machine: Machine

        private func unexpected(_ path: String) -> Env.Failed {
            Env.Failed(path: path, message: "Unexpected reply from \(machine.id)")
        }

        private static func info(_ info: MachineWire.FileInfo) -> Env.FileInfo {
            Env.FileInfo(type: info.type, size: Int64(info.size), mtimeMs: Int64(info.mtimeMs))
        }

        func stat(_ path: String) async throws -> Env.FileInfo {
            guard case .info(let info) = try await machine.call(path, .stat(path: path)) else { throw unexpected(path) }
            return Self.info(info)
        }

        func list(_ path: String) async throws -> [Env.DirEntry] {
            guard case .list(let entries) = try await machine.call(path, .list(path: path)) else { throw unexpected(path) }
            return entries.map { Env.DirEntry(name: $0.name, type: $0.type) }
        }

        func read(_ path: String, range: Env.ReadRange?) async throws -> Env.ReadResult {
            let wireRange = range.map { MachineWire.Range(offset: $0.offset, length: $0.length) }
            guard case .read(let result) = try await machine.call(path, .read(path: path, range: wireRange)) else {
                throw unexpected(path)
            }
            return Env.ReadResult(info: Self.info(result.info), bytes: result.bytes)
        }

        func write(_ path: String, bytes: [UInt8]) async throws {
            _ = try await machine.call(path, .write(path: path, bytes: bytes))
        }

        func append(_ path: String, bytes: [UInt8]) async throws {
            _ = try await machine.call(path, .append(path: path, bytes: bytes))
        }

        func remove(_ path: String) async throws {
            _ = try await machine.call(path, .remove(path: path))
        }

        func mkdir(_ path: String) async throws {
            _ = try await machine.call(path, .mkdir(path: path))
        }

        func move(from: String, to: String) async throws {
            _ = try await machine.call(from, .move(from: from, to: to))
        }
    }
}
