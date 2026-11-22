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

/// Unbounded output byte-chunk queue supporting clean completion, error failure, and shutdown (dropping unread data).
final class MachineOutputQueue: Sendable {
    private enum Terminal {
        case done
        case failed(any Error)
    }

    private struct State {
        var chunks: [[UInt8]] = []
        var terminal: Terminal?
        var isShutdown = false
        var waiter: CheckedContinuation<[UInt8]?, any Error>?
    }

    private let state = Mutex(State())

    func offer(_ chunk: [UInt8]) {
        let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, any Error>? in
            if s.isShutdown || s.terminal != nil { return nil }
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.chunks.append(chunk)
            return nil
        }
        waiter?.resume(returning: chunk)
    }

    func end() {
        let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, any Error>? in
            if s.isShutdown || s.terminal != nil { return nil }
            s.terminal = .done
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }

    func fail(_ error: any Error) {
        let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, any Error>? in
            if s.isShutdown || s.terminal != nil { return nil }
            s.terminal = .failed(error)
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(throwing: error)
    }

    func shutdown() {
        let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, any Error>? in
            s.isShutdown = true
            s.chunks.removeAll()
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async throws -> [UInt8]? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, any Error>) in
                let immediate: Result<[UInt8]?, any Error>? = state.withLock { s in
                    if !s.chunks.isEmpty {
                        return .success(s.chunks.removeFirst())
                    }
                    if s.isShutdown {
                        return .success(nil)
                    }
                    if let terminal = s.terminal {
                        switch terminal {
                        case .done: return .success(nil)
                        case .failed(let error): return .failure(error)
                        }
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    s.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<[UInt8]?, any Error>? in
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func stream() -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream {
            try await self.next()
        }
    }
}

/// Port of `core/src/machine/driver.ts`: a machine reached through a worker that dials in.
public enum MachineDriver {
    /// How long a start whose connection was lost waits for the worker to come back before it is reported unknown.
    static let startGrace: Duration = .seconds(15)
    /// The worker refuses a stdin write larger than 64 KiB.
    public static let maxStdinChunkSize = 64 * 1024
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

    /// A stdin write whose connection dropped before acknowledgment.
    public struct StdinUnknown: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let machine: String
        public var cause: Unknown { Unknown(machine: machine) }
        public init(machine: String) { self.machine = machine }
        public var message: String { "Lost connection to \(machine). The stdin operation's outcome is unknown." }
        public var description: String { message }
    }

    /// A stdin write refused by the worker (e.g. broken pipe) or rejected locally (e.g. concurrent write pending).
    public struct StdinFailed: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { message }
    }

    /// Raised when a caller reads both `all` and `stdout`/`stderr` on the same process handle.
    public struct OutputViewConflict: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public init() {}
        public var message: String { "read either all, or stdout and stderr, not both" }
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

    /// Live transport metadata reported by a worker connection.
    // parity: core/src/machine/driver.ts#ConnectionInfo [status=implemented hash=9673a46e824d]
    public struct ConnectionInfo: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Equatable, Hashable, Sendable, Codable {
            case websocket
            case iroh
        }

        public enum Path: String, Equatable, Hashable, Sendable, Codable {
            case direct
            case relayed
        }

        public let kind: Kind
        public let path: Path?
        /// Round-trip time in milliseconds.
        public let rtt: Double?

        public init(kind: Kind, path: Path? = nil, rtt: Double? = nil) {
            self.kind = kind
            self.path = path
            self.rtt = rtt
        }
    }

    /// One connection from the worker, as the endpoint that accepted it hands it over.
    // parity: core/src/machine/driver.ts#Connection [status=implemented hash=e53bb7d149a3]
    public struct Connection: Sendable {
        public let describe: (@Sendable () -> ConnectionInfo)?
        public let hello: MachineWire.Hello
        /// Queues the message and returns. A message queued on a connection that is lost is dropped. Called while the
        /// machine's state is locked, so it must not call back into the machine.
        public let send: @Sendable (MachineWire.ToWorker) -> Void
        /// The messages after `hello`. Ends when the connection is lost.
        public let messages: AsyncStream<MachineWire.FromWorker>

        public init(
            hello: MachineWire.Hello,
            send: @escaping @Sendable (MachineWire.ToWorker) -> Void,
            messages: AsyncStream<MachineWire.FromWorker>,
            describe: (@Sendable () -> ConnectionInfo)? = nil
        ) {
            self.describe = describe
            self.hello = hello
            self.send = send
            self.messages = messages
        }
    }

    /// Stdin configuration for a spawned machine process.
    public enum StdinOption: Sendable {
        case ignore
        case pipe(endOnDone: Bool = true)
        case stream(AsyncThrowingStream<[UInt8], any Error>, endOnDone: Bool = true)
        case inherit
    }

    /// Full spawn options mirroring Effect's `ChildProcess.make` options supported by `driver.ts`.
    public struct SpawnOptions: Sendable {
        public let command: String
        public let args: [String]
        public let cwd: String?
        public let env: [String: String]
        public let stdin: StdinOption
        public let killSignal: MachineWire.Signal
        public let forceKillAfter: Duration?
        public let shell: Bool
        public let additionalFds: Bool

        public init(
            command: String,
            args: [String] = [],
            cwd: String?,
            env: [String: String] = [:],
            stdin: StdinOption = .ignore,
            killSignal: MachineWire.Signal = .SIGTERM,
            forceKillAfter: Duration? = nil,
            shell: Bool = false,
            additionalFds: Bool = false
        ) {
            self.command = command
            self.args = args
            self.cwd = cwd
            self.env = env
            self.stdin = stdin
            self.killSignal = killSignal
            self.forceKillAfter = forceKillAfter
            self.shell = shell
            self.additionalFds = additionalFds
        }
    }

    /// Live handle to a process running on a remote machine, supporting separate/merged output views and acknowledged
    /// streaming stdin.
    public struct ProcessHandle: Sendable {
        public let pid: Int
        public let exitCode: @Sendable () async throws -> Int
        public let isRunning: @Sendable () -> Bool
        public let kill: @Sendable (MachineWire.Signal?, Duration?) async -> Void
        public let release: @Sendable () async -> Void
        public let writeStdin: @Sendable ([UInt8]) async throws -> Void
        public let closeStdin: @Sendable () async throws -> Void
        public let stdout: @Sendable () -> AsyncThrowingStream<[UInt8], any Error>
        public let stderr: @Sendable () -> AsyncThrowingStream<[UInt8], any Error>
        public let all: @Sendable () -> AsyncThrowingStream<[UInt8], any Error>
        /// Background task pumping a source `StdinOption.stream`, when one was supplied at spawn.
        public let stdinTask: Task<Void, any Error>?
    }

    // parity: core/src/machine/driver.ts#Interface [status=implemented hash=d3192acd726b]
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
        func describe() -> ConnectionInfo?
    }

    /// A machine reached through a worker that dials in: its environment, and where the worker's connections arrive.
    // parity: core/src/machine/driver.ts#make [status=adapted hash=249624f46959]
    public static func make(_ id: String) -> any Interface {
        Machine(id: id)
    }

    /// Spawns a process with full streaming stdio and output-view control on a driver created by `make`.
    public static func spawn(_ machine: any Interface, options: SpawnOptions) async throws -> ProcessHandle {
        guard let impl = machine as? Machine else {
            throw Unsupported(machine: machine.environment.id.rawValue, what: "streaming spawn is")
        }
        return try await impl.spawnHandle(options)
    }

    // MARK: - Machine

    final class Link: Sendable {
        let describe: (@Sendable () -> ConnectionInfo)?
        let hello: MachineWire.Hello
        let send: @Sendable (MachineWire.ToWorker) -> Void
        let lost = MachineDeferred<Void>()

        init(
            hello: MachineWire.Hello,
            send: @escaping @Sendable (MachineWire.ToWorker) -> Void,
            describe: (@Sendable () -> ConnectionInfo)?
        ) {
            self.describe = describe
            self.hello = hello
            self.send = send
        }
    }

    enum OutputView: Sendable {
        case merged
        case separate
    }

    enum OutputChannel: Sendable {
        case stdout
        case stderr
        case all
    }

    final class Process: Sendable {
        let started = MachineDeferred<Int>()
        let stdout = MachineOutputQueue()
        let stderr = MachineOutputQueue()
        let all = MachineOutputQueue()
        let exited = MachineDeferred<MachineWire.Exit>()
        private let viewLock = Mutex<OutputView?>(nil)

        func failOutputs(_ error: any Error) {
            stdout.fail(error)
            stderr.fail(error)
            all.fail(error)
        }

        func endOutputs() {
            stdout.end()
            stderr.end()
            all.end()
        }

        /// Enforces mutually exclusive merged (`all`) vs separate (`stdout`/`stderr`) output consumption, shutting down
        /// the unused view so long-lived stdio servers never retain an unread copy.
        func stream(_ channel: OutputChannel) -> AsyncThrowingStream<[UInt8], any Error> {
            let allowed = viewLock.withLock { selected -> Bool in
                if selected == nil {
                    if channel == .all {
                        selected = .merged
                        stdout.shutdown()
                        stderr.shutdown()
                    } else {
                        selected = .separate
                        all.shutdown()
                    }
                }
                return (selected == .merged) == (channel == .all)
            }
            if !allowed {
                return AsyncThrowingStream { throw OutputViewConflict() }
            }
            switch channel {
            case .stdout: return stdout.stream()
            case .stderr: return stderr.stream()
            case .all: return all.stream()
            }
        }
    }

    struct Tracked {
        let process: Process
        /// Bytes of output passed on so far, which is where an attach resumes.
        var delivered = 0
    }

    struct State {
        var processes: [MachineWire.ProcessID: Tracked] = [:]
        var link: Link?
        /// File calls sent on the current link and not yet answered.
        var calls: [Int: (link: Link, reply: MachineDeferred<MachineWire.FileReply>)] = [:]
        /// Stdin writes sent on the current link and not yet acknowledged.
        var inputs: [Int: (link: Link, id: MachineWire.ProcessID, reply: MachineDeferred<Void>)] = [:]
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
                spawner: Spawner(machine: self),
                // A worker is a POSIX machine with none of this server's shell paths, and its driver runs only argv, cwd
                // and env: `sh -c` is the contract every worker can meet.
                facts: CoreLocation.Environment.Facts(path: .posix, shell: "sh")
            )
        }

        func hello() -> MachineWire.Hello? {
            state.withLock { $0.link?.hello }
        }

        func describe() -> ConnectionInfo? {
            let fn = state.withLock { $0.link?.describe }
            return fn?()
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
            for (req, input) in s.inputs where input.link === current {
                s.inputs.removeValue(forKey: req)
                input.reply.fail(Unknown(machine: machine))
            }
        }

        // The process will not be heard from again: whoever waits on it gets `error`.
        static func gone(_ processID: MachineWire.ProcessID, error: any Error, in s: inout State) {
            guard let tracked = s.processes.removeValue(forKey: processID) else { return }
            tracked.process.started.fail(error)
            tracked.process.exited.fail(error)
            tracked.process.failOutputs(error)
        }

        func close(_ error: any Error) {
            state.withLock { s in
                if let link = s.link { Self.lose(link, machine: id, in: &s) }
                for processID in Array(s.processes.keys) { Self.gone(processID, error: error, in: &s) }
            }
        }

        func connect(_ connection: Connection) async {
            let current = Link(hello: connection.hello, send: connection.send, describe: connection.describe)
            state.withLock { s in
                if let link = s.link { Self.lose(link, machine: id, in: &s) }
                let restarted = connection.hello.instance != s.instance
                s.instance = connection.hello.instance
                var listed: [MachineWire.ProcessID: MachineWire.HelloProcess] = [:]
                for entry in connection.hello.processes { listed[entry.id] = entry }
                // Nothing here will ever read a process this home does not know, so it is stopped and forgotten. The
                // worker signals at once and the release drops it, so its exit is never reported. A release is safe to
                // repeat.
                for entry in connection.hello.processes {
                    if s.processes[entry.id] != nil { continue }
                    if entry.state == .running {
                        current.send(.kill(id: entry.id, signal: .SIGKILL))
                    }
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
                case .stdin(let processID, let req, let outcome):
                    guard let input = s.inputs[req], input.link === current, input.id == processID else { return }
                    s.inputs.removeValue(forKey: req)
                    switch outcome {
                    case .ok:
                        input.reply.succeed(())
                    case .failed(let text):
                        input.reply.fail(StdinFailed(message: text))
                    }
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
                case .output(let processID, let offset, let stream, let data):
                    guard var tracked = s.processes[processID] else { return }
                    // A chunk past what was delivered follows a lost one; the exit's byte count attaches again from the gap.
                    if offset > tracked.delivered { return }
                    let skip = min(tracked.delivered - offset, data.count)
                    let fresh = Array(data[skip...])
                    tracked.delivered += fresh.count
                    s.processes[processID] = tracked
                    if !fresh.isEmpty {
                        switch stream {
                        case .stdout: tracked.process.stdout.offer(fresh)
                        case .stderr: tracked.process.stderr.offer(fresh)
                        }
                        tracked.process.all.offer(fresh)
                    }
                case .exit(let exit):
                    guard let tracked = s.processes[exit.id] else { return }
                    if exit.bytes > tracked.delivered {
                        current.send(.attach(id: exit.id, from: tracked.delivered))
                        return
                    }
                    s.processes.removeValue(forKey: exit.id)
                    current.send(.release(id: exit.id))
                    tracked.process.exited.succeed(exit)
                    tracked.process.endOutputs()
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
        /// but never waiting for a machine that is away: a process still there is forgotten, and stopped when the
        /// machine's next hello lists it.
        func release(
            _ processID: MachineWire.ProcessID,
            _ process: Process,
            killSignal: MachineWire.Signal,
            forceKillAfter: Duration? = nil
        ) async {
            let link = state.withLock { $0.link }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.stop(
                        processID,
                        process,
                        signal: killSignal,
                        forceKillAfter: forceKillAfter ?? MachineDriver.releaseForceKillAfter
                    )
                }
                group.addTask {
                    if let link { _ = try? await link.lost.wait() }
                }
                await group.next()
                group.cancelAll()
            }
            _ = state.withLock { $0.processes.removeValue(forKey: processID) }
        }

        func sendStdinFrame(_ processID: MachineWire.ProcessID, data: [UInt8]?) async throws {
            let (request, reply): (Int, MachineDeferred<Void>) = try state.withLock { s in
                guard let current = s.link else { throw NotSent(machine: id) }
                if s.inputs.values.contains(where: { $0.link === current && $0.id == processID }) {
                    throw StdinFailed(message: "stdin write already pending")
                }
                s.req += 1
                let request = s.req
                let reply = MachineDeferred<Void>()
                s.inputs[request] = (current, processID, reply)
                current.send(.stdin(id: processID, req: request, data: data))
                return (request, reply)
            }
            do {
                defer { _ = state.withLock { $0.inputs.removeValue(forKey: request) } }
                try await reply.wait()
            } catch is Unknown {
                throw StdinUnknown(machine: id)
            }
        }

        func writeStdinChunked(_ processID: MachineWire.ProcessID, data: [UInt8]) async throws {
            if data.isEmpty { return }
            var offset = 0
            while offset < data.count {
                let end = min(offset + MachineDriver.maxStdinChunkSize, data.count)
                try await sendStdinFrame(processID, data: Array(data[offset..<end]))
                offset = end
            }
        }

        func spawnHandle(_ options: SpawnOptions) async throws -> ProcessHandle {
            let piped: Bool
            let endOnDone: Bool
            let sourceStream: AsyncThrowingStream<[UInt8], any Error>?
            switch options.stdin {
            case .ignore:
                piped = false
                endOnDone = true
                sourceStream = nil
            case .pipe(let end):
                piped = true
                endOnDone = end
                sourceStream = nil
            case .stream(let stream, let end):
                piped = true
                endOnDone = end
                sourceStream = stream
            case .inherit:
                throw Unsupported(machine: id, what: "stdin is")
            }
            if options.shell { throw Unsupported(machine: id, what: "the shell option is") }
            if options.additionalFds { throw Unsupported(machine: id, what: "extra file descriptors are") }
            guard let cwd = options.cwd else {
                throw Unsupported(machine: id, what: "a command without a working directory is")
            }

            let killSignal = options.killSignal
            let processID = MachineWire.ProcessID(MachineDriver.randomUUID())
            let process = Process()
            // The worker's own environment is the base: the server's never crosses.
            let start = MachineWire.ToWorker.start(
                id: processID,
                argv: [options.command] + options.args,
                cwd: cwd,
                env: options.env,
                stdin: piped
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
                await cancelled(processID, process, killSignal: killSignal, forceKillAfter: options.forceKillAfter)
                throw CancellationError()
            } catch {
                state.withLock { s in Self.gone(processID, error: error, in: &s) }
                throw error
            }

            let writeStdin: @Sendable ([UInt8]) async throws -> Void = { [self] data in
                guard piped else { throw Unsupported(machine: self.id, what: "stdin is") }
                try await self.writeStdinChunked(processID, data: data)
            }
            let closeStdin: @Sendable () async throws -> Void = { [self] in
                guard piped else { throw Unsupported(machine: self.id, what: "stdin is") }
                try await self.sendStdinFrame(processID, data: nil)
            }

            let stdinTask: Task<Void, any Error>?
            if let sourceStream {
                stdinTask = Task { [self] in
                    do {
                        for try await chunk in sourceStream {
                            try await writeStdin(chunk)
                        }
                        if endOnDone {
                            try await closeStdin()
                        }
                    } catch {
                        // Stop only when delivery was lost: unsent or unacknowledged input cannot be replayed.
                        if error is NotSent || error is StdinUnknown || error is Unknown {
                            await self.stop(processID, process, signal: killSignal, forceKillAfter: nil)
                        }
                        throw error
                    }
                }
            } else {
                stdinTask = nil
            }

            return ProcessHandle(
                pid: pid,
                exitCode: { [self] in
                    let exit: MachineWire.Exit
                    do {
                        exit = try await process.exited.wait()
                    } catch is CancellationError {
                        stdinTask?.cancel()
                        await self.cancelled(processID, process, killSignal: killSignal, forceKillAfter: options.forceKillAfter)
                        throw CancellationError()
                    }
                    guard let code = exit.code else {
                        throw CrossSpawnSpawner.KilledBySignal(signal: exit.signal ?? killSignal.rawValue)
                    }
                    return code
                },
                isRunning: { !process.exited.isDone },
                kill: { [self] signal, forceAfter in
                    await self.stop(
                        processID,
                        process,
                        signal: signal ?? killSignal,
                        forceKillAfter: forceAfter
                    )
                },
                release: { [self] in
                    stdinTask?.cancel()
                    await self.release(
                        processID,
                        process,
                        killSignal: killSignal,
                        forceKillAfter: options.forceKillAfter
                    )
                },
                writeStdin: writeStdin,
                closeStdin: closeStdin,
                stdout: { process.stream(.stdout) },
                stderr: { process.stream(.stderr) },
                all: { process.stream(.all) },
                stdinTask: stdinTask
            )
        }

        func spawn(_ spec: ProcessSpec) async throws -> CoreLocation.Environment.SpawnedProcess {
            let stdinOption: StdinOption
            if let bytes = spec.stdin {
                stdinOption = .stream(
                    AsyncThrowingStream { continuation in
                        if !bytes.isEmpty { continuation.yield(bytes) }
                        continuation.finish()
                    },
                    endOnDone: true
                )
            } else {
                stdinOption = .ignore
            }
            let handle = try await spawnHandle(SpawnOptions(
                command: spec.executable,
                args: spec.arguments,
                cwd: spec.workingDirectory,
                env: spec.environment ?? [:],
                stdin: stdinOption
            ))
            let stdoutStream = handle.stdout()
            let stderrStream = handle.stderr()
            return CoreLocation.Environment.SpawnedProcess(
                pid: handle.pid,
                wait: {
                    async let stdoutBytes: [UInt8] = {
                        var collected: [UInt8] = []
                        for try await chunk in stdoutStream { collected.append(contentsOf: chunk) }
                        return collected
                    }()
                    async let stderrBytes: [UInt8] = {
                        var collected: [UInt8] = []
                        for try await chunk in stderrStream { collected.append(contentsOf: chunk) }
                        return collected
                    }()
                    do {
                        let code = try await handle.exitCode()
                        let out = try await stdoutBytes
                        let err = try await stderrBytes
                        return ProcessOutput(exitCode: Int32(truncatingIfNeeded: code), stdout: out, stderr: err)
                    } catch {
                        _ = try? await stdoutBytes
                        _ = try? await stderrBytes
                        throw error
                    }
                },
                stop: {
                    await handle.release()
                }
            )
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            let handle = try await spawn(spec)
            return try await handle.wait()
        }

        /// Runs the release in a task of its own, so the cancellation that called for it cannot cut it short.
        private func cancelled(
            _ processID: MachineWire.ProcessID,
            _ process: Process,
            killSignal: MachineWire.Signal,
            forceKillAfter: Duration? = nil
        ) async {
            await Task.detached {
                await self.release(processID, process, killSignal: killSignal, forceKillAfter: forceKillAfter)
            }.value
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
