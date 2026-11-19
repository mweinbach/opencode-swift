#if !os(WASI)
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Top-Level Convenience Typealiases

public typealias ProcessDaemonService = ProcessDaemon.TerminalService
public typealias ProcessDaemonClient = ProcessDaemon.TerminalClient

// MARK: - ProcessDaemon Core Service & Client

extension ProcessDaemon {
    public static let defaultCols: UInt16 = 100
    public static let defaultRows: UInt16 = 30
    public static let defaultReplayCapacity: Int = 2 * 1024 * 1024
    public static let maxInputBytes: Int = 1024 * 1024
    public static let maxRowsBytes: Int = 1024 * 1024

    // MARK: - Service Response & Request Types (`src/service.rs`)

    // parity: process-daemon/src/service.rs#TerminalSnapshot [status=implemented hash=cb94280dfdeb]
    public struct TerminalSnapshot: Equatable, Sendable {
        public let info: ProcessInfo
        public let text: String
        public let checkpoint: [UInt8]
        public let cursorX: UInt16
        public let cursorY: UInt16

        public init(info: ProcessInfo, text: String, checkpoint: [UInt8], cursorX: UInt16, cursorY: UInt16) {
            self.info = info
            self.text = text
            self.checkpoint = checkpoint
            self.cursorX = cursorX
            self.cursorY = cursorY
        }
    }

    // parity: process-daemon/src/service.rs#TerminalRows [status=implemented hash=8025d6bba8e2]
    public struct TerminalRows: Equatable, Sendable {
        public let process: ProcessInfo
        public let lines: [String]
        public let cursorX: UInt16
        public let cursorY: UInt16

        public init(process: ProcessInfo, lines: [String], cursorX: UInt16, cursorY: UInt16) {
            self.process = process
            self.lines = lines
            self.cursorX = cursorX
            self.cursorY = cursorY
        }
    }

    // parity: process-daemon/src/service.rs#RawReplay [status=implemented hash=4807bad53a9e]
    public struct RawReplay: Equatable, Sendable {
        public let requestedOffset: UInt64
        public let availableOffset: UInt64
        public let endOffset: UInt64
        public let truncated: Bool
        public let bytes: [UInt8]

        public init(
            requestedOffset: UInt64,
            availableOffset: UInt64,
            endOffset: UInt64,
            truncated: Bool,
            bytes: [UInt8]
        ) {
            self.requestedOffset = requestedOffset
            self.availableOffset = availableOffset
            self.endOffset = endOffset
            self.truncated = truncated
            self.bytes = bytes
        }
    }

    // parity: process-daemon/src/service.rs#StreamEvent [status=implemented hash=80188cc2c0a5]
    public enum StreamEvent: Equatable, Sendable {
        case output(start: UInt64, end: UInt64, bytes: [UInt8])
        case resized(cols: UInt16, rows: UInt16, generation: UInt64, checkpoint: [UInt8])
        case exited(ProcessExit)
        case controllerChanged(attachmentId: String?, generation: UInt64)
        case titleChanged(title: String)
        case foregroundProcessChanged(process: String?)
    }

    // parity: process-daemon/src/service.rs#CreatePty [status=implemented hash=d8e5c801274e]
    public struct CreatePty: Equatable, Sendable {
        public var program: String
        public var args: [String]
        public var cwd: String
        public var env: [String: String]
        public var groupId: String
        public var title: String
        public var cols: UInt16
        public var rows: UInt16

        public init(
            program: String,
            args: [String] = [],
            cwd: String = "/",
            env: [String: String] = [:],
            groupId: String = "default",
            title: String = "",
            cols: UInt16 = ProcessDaemon.defaultCols,
            rows: UInt16 = ProcessDaemon.defaultRows
        ) {
            self.program = program
            self.args = args
            self.cwd = cwd
            self.env = env
            self.groupId = groupId
            self.title = title.isEmpty ? program : title
            self.cols = cols
            self.rows = rows
        }

        // parity: process-daemon/src/service.rs#shell [status=implemented hash=e92cf29c5333]
        public static func shell(environment: any EnvironmentProviding = SystemEnvironment()) throws -> CreatePty {
            let program = environment.variable("SHELL") ?? (Platform.current == .windows ? "cmd.exe" : "/bin/sh")
            let title = program.split(separator: "/").last.map(String.init) ?? "shell"
            #if !os(WASI)
            let cwd = FileManager.default.currentDirectoryPath
            #else
            let cwd = "/"
            #endif
            return CreatePty(
                program: program,
                args: [],
                cwd: cwd,
                env: [:],
                groupId: "local:\(cwd)",
                title: title,
                cols: ProcessDaemon.defaultCols,
                rows: ProcessDaemon.defaultRows
            )
        }
    }

    // parity: process-daemon/src/service.rs#CreatePipe [status=implemented hash=8bd7a634cc5a]
    public struct CreatePipe: Equatable, Sendable {
        public var program: String
        public var args: [String]
        public var cwd: String
        public var env: [String: String]
        public var groupId: String
        public var outputPath: String
        public var metadata: PipeMetadata

        public init(
            program: String,
            args: [String] = [],
            cwd: String,
            env: [String: String] = [:],
            groupId: String = "default",
            outputPath: String,
            metadata: PipeMetadata = [:]
        ) {
            self.program = program
            self.args = args
            self.cwd = cwd
            self.env = env
            self.groupId = groupId
            self.outputPath = outputPath
            self.metadata = metadata
        }
    }

    // MARK: - Bounded Replay Buffer

    internal struct ReplayBuffer: Sendable {
        private var bytes: [UInt8] = []
        private let capacity: Int
        internal private(set) var head: UInt64 = 0
        internal private(set) var tail: UInt64 = 0

        init(capacity: Int) {
            self.capacity = max(0, capacity)
        }

        mutating func append(_ chunk: [UInt8]) -> (start: UInt64, end: UInt64) {
            let start = tail
            tail = tail &+ UInt64(chunk.count)
            if capacity == 0 {
                bytes.removeAll()
                head = tail
                return (start, tail)
            }
            bytes.append(contentsOf: chunk)
            if bytes.count > capacity {
                let excess = bytes.count - capacity
                bytes.removeFirst(excess)
            }
            head = tail &- UInt64(bytes.count)
            return (start, tail)
        }

        func readFrom(_ requestedOffset: UInt64) throws -> RawReplay {
            if requestedOffset > tail {
                throw DaemonError("requested offset \(requestedOffset) is beyond tail \(tail)")
            }
            let availableOffset = max(requestedOffset, head)
            let skip = Int(availableOffset - head)
            let slice = skip <= bytes.count ? Array(bytes[skip...]) : []
            return RawReplay(
                requestedOffset: requestedOffset,
                availableOffset: availableOffset,
                endOffset: tail,
                truncated: requestedOffset < head,
                bytes: slice
            )
        }
    }

    // MARK: - Event Queue & Subscriber Attachment (`TerminalAttachment`, `ProcessWait`)

    internal final class EventQueue: @unchecked Sendable {
        private let cond = PortableCondition()
        private var queue: [StreamEvent] = []
        private let capacity: Int
        private var closed = false
        private var disconnected = false

        init(capacity: Int = 1024) {
            self.capacity = max(1, capacity)
        }

        var isDisconnected: Bool {
            cond.withLock { disconnected || closed }
        }

        var isClosed: Bool {
            cond.withLock { closed && queue.isEmpty }
        }

        @discardableResult
        func push(_ event: StreamEvent, dropWhenFull: Bool) -> Bool {
            cond.withLock {
                if disconnected || closed { return false }
                if queue.count >= capacity {
                    if dropWhenFull {
                        disconnected = true
                        cond.broadcast()
                        return false
                    }
                    queue.removeFirst()
                }
                queue.append(event)
                cond.broadcast()
                return true
            }
        }

        func pop(timeoutMs: UInt64? = nil) -> StreamEvent? {
            cond.withLock {
                let deadline = timeoutMs.map { monotonicNowMs() &+ $0 }
                while queue.isEmpty && !closed && !disconnected {
                    if let deadline {
                        let now = monotonicNowMs()
                        if now >= deadline { return nil }
                        _ = cond.wait(timeoutMs: deadline - now)
                    } else {
                        #if os(WASI)
                        return nil
                        #else
                        _ = cond.wait(timeoutMs: 25)
                        #endif
                    }
                }
                if queue.isEmpty { return nil }
                return queue.removeFirst()
            }
        }

        func drainAvailable() -> [StreamEvent] {
            cond.withLock {
                let out = queue
                queue.removeAll()
                return out
            }
        }

        func markDisconnected() {
            cond.withLock {
                disconnected = true
                cond.broadcast()
            }
        }

        func close() {
            cond.withLock {
                closed = true
                cond.broadcast()
            }
        }
    }

    // parity: process-daemon/src/service.rs#TerminalAttachment [status=implemented hash=199c99c2b95d]
    public final class TerminalAttachment: @unchecked Sendable {
        public let process: ProcessInfo
        public let role: AttachmentRole
        public let generation: UInt64
        public let replay: RawReplay
        internal let queue: EventQueue
        private let onDetach: @Sendable () -> Void
        private let detached = Mutex<Bool>(false)

        internal init(
            process: ProcessInfo,
            role: AttachmentRole,
            generation: UInt64,
            replay: RawReplay,
            queue: EventQueue,
            onDetach: @escaping @Sendable () -> Void
        ) {
            self.process = process
            self.role = role
            self.generation = generation
            self.replay = replay
            self.queue = queue
            self.onDetach = onDetach
        }

        deinit {
            detach()
        }

        public var isClosed: Bool {
            queue.isClosed
        }

        public func nextEvent(timeoutMs: UInt64? = nil) -> StreamEvent? {
            queue.pop(timeoutMs: timeoutMs)
        }

        public func drainEvents() -> [StreamEvent] {
            queue.drainAvailable()
        }

        public func detach() {
            let shouldRun = detached.withLock { already -> Bool in
                if already { return false }
                already = true
                return true
            }
            if shouldRun {
                queue.markDisconnected()
                onDetach()
            }
        }
    }

    // parity: process-daemon/src/service.rs#ProcessWait [status=implemented hash=1d91414a25d6]
    public final class ProcessWait: @unchecked Sendable {
        public enum PollResult: Equatable, Sendable {
            case exited(ProcessExit)
            case terminated
            case pending
        }

        private let cond = PortableCondition()
        private var exitValue: ProcessExit?
        private var isTerminated = false

        internal init(initialExit: ProcessExit? = nil) {
            self.exitValue = initialExit
        }

        internal func resolve(_ exit: ProcessExit) {
            cond.withLock {
                if exitValue == nil {
                    exitValue = exit
                }
                cond.broadcast()
            }
        }

        internal func markTerminated() {
            cond.withLock {
                isTerminated = true
                cond.broadcast()
            }
        }

        public func poll(timeoutMs: UInt64) -> PollResult {
            cond.withLock {
                let deadline = monotonicNowMs() &+ timeoutMs
                while exitValue == nil && !isTerminated {
                    let now = monotonicNowMs()
                    if now >= deadline { return .pending }
                    _ = cond.wait(timeoutMs: deadline - now)
                }
                if let exitValue { return .exited(exitValue) }
                return .terminated
            }
        }

        // parity: process-daemon/src/service.rs#recv [status=implemented hash=50448fa369db]
        public func recv(timeoutMs: UInt64? = nil) throws -> ProcessExit {
            try cond.withLock {
                let deadline = timeoutMs.map { monotonicNowMs() &+ $0 }
                while exitValue == nil && !isTerminated {
                    if let deadline {
                        let now = monotonicNowMs()
                        if now >= deadline {
                            throw DaemonError("wait timed out")
                        }
                        _ = cond.wait(timeoutMs: deadline - now)
                    } else {
                        #if os(WASI)
                        throw DaemonError("terminated")
                        #else
                        _ = cond.wait(timeoutMs: 25)
                        #endif
                    }
                }
                if let exitValue { return exitValue }
                throw DaemonError("terminated")
            }
        }
    }

    // MARK: - Platform Pipe & PTY Backends (`src/service/pipe/unix.rs`, `pipe/windows.rs`, `windows.rs`)

    public enum UnixPipe {
        // parity: process-daemon/src/service/pipe/unix.rs#Process [status=implemented hash=088fd0d3da20]
        public final class Process: @unchecked Sendable {
            private let processID: UInt32
            private let lock = Mutex<(reaped: Bool, signalFn: (@Sendable (ProcessSignal) throws -> Void)?, killFn: (@Sendable () -> Void)?, reapFn: (@Sendable () -> Void)?)>((false, nil, nil, nil))

            public init(
                pid: UInt32,
                signalFn: (@Sendable (ProcessSignal) throws -> Void)? = nil,
                killFn: (@Sendable () -> Void)? = nil,
                reapFn: (@Sendable () -> Void)? = nil
            ) {
                self.processID = pid
                self.lock.withLock { state in
                    state.signalFn = signalFn
                    state.killFn = killFn
                    state.reapFn = reapFn
                }
            }

            // parity: process-daemon/src/service/pipe/unix.rs#pid [status=implemented hash=460d52d29d7d]
            public func pid() -> UInt32 {
                processID
            }

            // parity: process-daemon/src/service/pipe/unix.rs#kill [status=implemented hash=effbcdc97244]
            public func kill() {
                let fn = lock.withLock { state -> (@Sendable () -> Void)? in
                    guard !state.reaped else { return nil }
                    return state.killFn
                }
                if let fn {
                    fn()
                    return
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if let spid = Int32(exactly: processID), spid > 0 {
                    _ = killpg(spid, SIGKILL)
                    _ = DarwinOrPosixKill.send(spid, SIGKILL)
                }
                #endif
            }

            // parity: process-daemon/src/service/pipe/unix.rs#signal [status=implemented hash=dcdef71104d3]
            public func signal(_ signal: ProcessSignal) throws {
                let (reaped, fn) = lock.withLock { ($0.reaped, $0.signalFn) }
                if reaped { return }
                if let fn {
                    try fn(signal)
                    return
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                guard let spid = Int32(exactly: processID), spid > 0 else { return }
                let sig: Int32
                switch signal {
                case .term: sig = SIGTERM
                case .int: sig = SIGINT
                case .kill: sig = SIGKILL
                }
                _ = killpg(spid, sig)
                let rc = DarwinOrPosixKill.send(spid, sig)
                if rc == -1 && errno != ESRCH && errno != EPERM {
                    throw DaemonError("failed to signal process \(processID): errno \(errno)")
                }
                #endif
            }

            // parity: process-daemon/src/service/pipe/unix.rs#reap [status=implemented hash=6bd9c0c1b779]
            public func reap() {
                let fn = lock.withLock { state -> (@Sendable () -> Void)? in
                    if state.reaped { return nil }
                    state.reaped = true
                    return state.reapFn
                }
                fn?()
            }
        }

        // parity: process-daemon/src/service/pipe/unix.rs#spawn_pipe [status=implemented hash=1f078f620050]
        public static func spawn_pipe(
            id: TerminalId,
            order: UInt64,
            request: CreatePipe,
            backend: BackendMode = .native
        ) throws -> SessionActor {
            try SessionActor.spawnPipe(id: id, order: order, request: request, backend: backend)
        }
    }

    public enum WindowsPipe {
        // parity: process-daemon/src/service/pipe/windows.rs#Process [status=adapted hash=8fdb1185926c]
        public final class Process: @unchecked Sendable {
            private let processID: UInt32
            private let state = Mutex<(reaped: Bool, killedSignal: String?, killFn: (@Sendable () -> Void)?)>((false, nil, nil))

            public init(pid: UInt32, killFn: (@Sendable () -> Void)? = nil) {
                self.processID = pid
                self.state.withLock { $0.killFn = killFn }
            }

            // parity: process-daemon/src/service/pipe/windows.rs#pid [status=implemented hash=460d52d29d7d]
            public func pid() -> UInt32 {
                processID
            }

            // parity: process-daemon/src/service/pipe/windows.rs#kill [status=adapted hash=d67485a38d5c]
            public func kill() {
                let fn = state.withLock { s -> (@Sendable () -> Void)? in
                    guard !s.reaped else { return nil }
                    if s.killedSignal == nil { s.killedSignal = "SIGKILL" }
                    return s.killFn
                }
                fn?()
            }

            // parity: process-daemon/src/service/pipe/windows.rs#signal [status=adapted hash=dd48fe757d60]
            public func signal(_ signal: ProcessSignal) throws {
                let fn = state.withLock { s -> (@Sendable () -> Void)? in
                    guard !s.reaped else { return nil }
                    if s.killedSignal == nil { s.killedSignal = signal.rawValue }
                    return s.killFn
                }
                fn?()
            }

            // parity: process-daemon/src/service/pipe/windows.rs#reap [status=implemented hash=bf2d59d394a3]
            public func reap() {
                state.withLock { $0.reaped = true }
            }

            public var recordedSignal: String? {
                state.withLock { $0.killedSignal }
            }
        }

        // parity: process-daemon/src/service/pipe/windows.rs#spawn_pipe [status=adapted hash=14801e6f0399]
        public static func spawn_pipe(
            id: TerminalId,
            order: UInt64,
            request: CreatePipe,
            backend: BackendMode = .native
        ) throws -> SessionActor {
            try SessionActor.spawnPipe(id: id, order: order, request: request, backend: backend)
        }
    }

    public enum WindowsPty {
        // parity: process-daemon/src/service/windows.rs#wait_and_close [status=adapted hash=8a7dbea7ff4c]
        public static func wait_and_close(
            waitForExit: @Sendable () -> Result<UInt32?, DaemonError>,
            onExit: @Sendable (Result<UInt32?, DaemonError>) -> Void,
            onCloseMaster: @Sendable () -> Void
        ) {
            let result = waitForExit()
            onExit(result)
            onCloseMaster()
        }
    }

    // MARK: - Injectable Backend Mode (Native OS PTY/Pipe vs Deterministic Simulated PTY/Pipe)

    /// Controls how `TerminalService` launches PTY and pipe processes.
    public enum BackendMode: Sendable {
        /// Uses real OS PTYs (`posix_openpt` + `Foundation.Process`) and pipes where supported,
        /// falling back to `.simulated` on restricted platforms (iOS/WASI).
        case native
        /// Pure in-memory deterministic PTY/pipe backend for fast cross-platform tests on all platforms including WASI.
        /// Optional hook is invoked whenever input bytes are written to a simulated PTY.
        case simulated(onWrite: (@Sendable (TerminalId, [UInt8], SessionActor) -> Void)? = nil)
    }

    // MARK: - Per-Process Session Actor

    public final class SessionActor: @unchecked Sendable {
        private struct Subscriber: Sendable {
            let token: UInt64
            let queue: EventQueue
            var role: AttachmentRole
            var lastControl: UInt64
        }

        internal let id: TerminalId
        internal let order: UInt64
        internal let mode: ProcessMode
        private let lock = Mutex<Int>(0) // serializes all session state access
        private let stateLock: ReentrantSessionLock = ReentrantSessionLock()

        private var info: ProcessInfo
        private let createTitle: String
        private var oscTitle: String?
        private var terminal: Ghostty.Terminal?
        private var replay: ReplayBuffer
        private var subscribers: [String: Subscriber] = [:]
        private var nextSubToken: UInt64 = 1
        private var controller: String?
        private var controllerGeneration: UInt64 = 0
        private var childExit: (exitCode: UInt32?, signal: String?, error: String?)?
        private var readerEof: Bool = false
        private var finalExit: ProcessExit?
        private var waiters: [ProcessWait] = []
        private var outputLines: UInt64 = 0
        private var isStopped: Bool = false
        private var writeHandler: (@Sendable ([UInt8]) throws -> Void)?
        private var resizeHandler: (@Sendable (UInt16, UInt16) throws -> Void)?
        private var killHandler: (@Sendable () -> Void)?
        private var pipeProcess: UnixPipe.Process?
        #if !os(WASI)
        private var pipeOutputHandle: FileHandle?
        #endif

        internal init(
            id: TerminalId,
            order: UInt64,
            info: ProcessInfo,
            terminal: Ghostty.Terminal?,
            replayCapacity: Int
        ) {
            self.id = id
            self.order = order
            self.mode = info.mode
            self.info = info
            self.createTitle = info.pty?.title ?? ""
            self.terminal = terminal
            self.replay = ReplayBuffer(capacity: replayCapacity)
        }

        internal func currentInfo() -> ProcessInfo {
            stateLock.withLock { info }
        }

        /// Injects output bytes (for real reader threads and deterministic simulated tests).
        public func emitOutput(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            let pendingReplies: [[UInt8]] = stateLock.withLock {
                if isStopped { return [] }
                var newlines: UInt64 = 0
                if mode == .pipe {
                    #if !os(WASI)
                    if let handle = pipeOutputHandle {
                        do {
                            try handle.write(contentsOf: Data(bytes))
                            for b in bytes where b == UInt8(ascii: "\n") {
                                newlines &+= 1
                            }
                        } catch {
                            try? handle.close()
                            pipeOutputHandle = nil
                            info.pipe?.outputError = "failed to write output file: \(error)"
                        }
                    } else {
                        // Simulated pipe without a host file still counts newlines if no outputError
                        if info.pipe?.outputError == nil {
                            for b in bytes where b == UInt8(ascii: "\n") {
                                newlines &+= 1
                            }
                        }
                    }
                    #else
                    if info.pipe?.outputError == nil {
                        for b in bytes where b == UInt8(ascii: "\n") {
                            newlines &+= 1
                        }
                    }
                    #endif
                }

                let (start, end) = replay.append(bytes)
                outputLines &+= newlines
                var replies: [[UInt8]] = []

                if let term = terminal {
                    term.vt_write(bytes)
                    replies = term.take_writes()
                }

                info.outputHead = replay.head
                info.outputTail = replay.tail
                if info.pipe != nil {
                    info.pipe?.outputLines = outputLines
                }

                broadcastLocked(.output(start: start, end: end, bytes: bytes))

                if let term = terminal, let rawTitle = term.take_title() {
                    oscTitle = rawTitle.isEmpty ? nil : rawTitle
                    if let changed = refreshTitleLocked(userTitleUpdate: nil) {
                        broadcastLocked(.titleChanged(title: changed))
                    }
                }
                return replies
            }

            if !pendingReplies.isEmpty, let writer = stateLock.withLock({ writeHandler }) {
                for reply in pendingReplies {
                    try? writer(reply)
                }
            }
        }

        /// Marks the PTY/pipe output stream as having reached EOF.
        public func emitReaderEof() {
            stateLock.withLock {
                #if !os(WASI)
                if let handle = pipeOutputHandle {
                    try? handle.close()
                    pipeOutputHandle = nil
                }
                #endif
                readerEof = true
                tryFinalizeExitLocked()
            }
        }

        /// Records child process termination (exit code or signal).
        public func emitChildExit(exitCode: UInt32?, signal: String? = nil, failureMessage: String? = nil) {
            stateLock.withLock {
                if childExit == nil {
                    childExit = (exitCode, signal, failureMessage)
                }
                tryFinalizeExitLocked()
            }
        }

        /// Records an output file failure for pipe processes.
        public func emitOutputFileError(_ message: String) {
            stateLock.withLock {
                info.pipe?.outputError = message
            }
        }

        /// Records a reader failure (publishes exit with error on pipe processes, or marks PTY failed).
        public func emitReaderFailed(_ message: String) {
            stateLock.withLock {
                if mode == .pipe {
                    #if !os(WASI)
                    if let handle = pipeOutputHandle {
                        try? handle.close()
                        pipeOutputHandle = nil
                    }
                    #endif
                    readerEof = true
                    if info.pipe?.outputError == nil {
                        info.pipe?.outputError = "failed to read process output: \(message)"
                    }
                    tryFinalizeExitLocked()
                } else if finalExit == nil {
                    info.lifecycle = .failed(message: message)
                }
            }
        }

        private func tryFinalizeExitLocked() {
            guard readerEof, finalExit == nil, let result = childExit else { return }
            let now = max(currentUnixMs(), info.startedAt)
            let exit = ProcessExit(
                exitCode: result.exitCode,
                signal: result.signal,
                finalOffset: replay.tail,
                outputLines: mode == .pipe ? outputLines : nil,
                outputError: info.pipe?.outputError,
                exitedAt: now
            )
            if let failMsg = result.error {
                info.lifecycle = .failed(message: failMsg)
            } else {
                info.lifecycle = .exited(exitCode: result.exitCode, signal: result.signal)
            }
            info.exitedAt = now
            finalExit = exit
            for waiter in waiters {
                waiter.resolve(exit)
            }
            waiters.removeAll()
            broadcastLocked(.exited(exit))
        }

        internal func write(attachmentId: String?, bytes: [UInt8]) throws {
            let writer = try stateLock.withLock { () -> (@Sendable ([UInt8]) throws -> Void)? in
                try authorizeControllerLocked(attachmentId: attachmentId)
                guard !isStopped else { throw DaemonError("terminal actor stopped") }
                return writeHandler
            }
            try writer?(bytes)
        }

        internal func resize(attachmentId: String?, cols: UInt16, rows: UInt16) throws {
            let replies = try stateLock.withLock { () -> [[UInt8]] in
                try authorizeControllerLocked(attachmentId: attachmentId)
                return try applyResizeLocked(cols: cols, rows: rows)
            }
            if !replies.isEmpty, let writer = stateLock.withLock({ writeHandler }) {
                for reply in replies { try? writer(reply) }
            }
        }

        internal func control(attachmentId: String, cols: UInt16, rows: UInt16, bytes: [UInt8]?) throws {
            let (replies, writer) = try stateLock.withLock { () -> ([[UInt8]], (@Sendable ([UInt8]) throws -> Void)?) in
                guard subscribers[attachmentId] != nil else {
                    throw DaemonError("attachment \(attachmentId) is not subscribed")
                }
                if controller != attachmentId {
                    if let current = controller, var oldSub = subscribers[current] {
                        oldSub.role = .observer
                        subscribers[current] = oldSub
                    }
                    controllerGeneration &+= 1
                    controller = attachmentId
                    if var sub = subscribers[attachmentId] {
                        sub.role = .controller
                        sub.lastControl = controllerGeneration
                        subscribers[attachmentId] = sub
                    }
                    broadcastLocked(.controllerChanged(attachmentId: attachmentId, generation: controllerGeneration))
                }
                var replies: [[UInt8]] = []
                if info.pty?.cols != cols || info.pty?.rows != rows {
                    replies = try applyResizeLocked(cols: cols, rows: rows)
                }
                return (replies, writeHandler)
            }
            if let writer {
                for reply in replies { try? writer(reply) }
                if let bytes {
                    try writer(bytes)
                }
            }
        }

        private func applyResizeLocked(cols: UInt16, rows: UInt16) throws -> [[UInt8]] {
            guard let term = terminal else {
                throw DaemonError("pipe processes have no terminal")
            }
            try resizeHandler?(cols, rows)
            try term.resize(cols: cols, rows: rows)
            let replies = term.take_writes()
            info.pty?.cols = cols
            info.pty?.rows = rows
            let checkpoint = try formatTerminalVT(term)
            broadcastLocked(.resized(
                cols: cols,
                rows: rows,
                generation: controllerGeneration,
                checkpoint: checkpoint
            ))
            return replies
        }

        internal func snapshot() throws -> TerminalSnapshot {
            try stateLock.withLock {
                guard let term = terminal else {
                    throw DaemonError("pipe processes have no terminal")
                }
                let plainBytes = try term.format(.plain)
                let text = String(decoding: plainBytes, as: UTF8.self)
                let checkpoint = try formatTerminalVT(term)
                return TerminalSnapshot(
                    info: info,
                    text: text,
                    checkpoint: checkpoint,
                    cursorX: try term.cursor_x(),
                    cursorY: try term.cursor_y()
                )
            }
        }

        internal func readRows(count requestedRows: UInt16?) throws -> TerminalRows {
            try stateLock.withLock {
                guard let term = terminal else {
                    throw DaemonError("pipe processes have no terminal")
                }
                let rows: UInt16
                if let requestedRows {
                    rows = requestedRows
                } else {
                    rows = try term.rows()
                }
                guard rows > 0 else {
                    throw DaemonError("row count must be positive")
                }
                let total = try term.total_rows()
                let count = min(Int(rows), total)
                // Charge JSON array punctuation and per-row overhead matching upstream MAX_ROWS_BYTES budget.
                var bytes = 2 + count * (MemoryLayout<String>.size + 1)
                if bytes > ProcessDaemon.maxRowsBytes {
                    throw DaemonError("rows exceed \(ProcessDaemon.maxRowsBytes) byte limit")
                }
                var lines: [String] = []
                lines.reserveCapacity(count)
                for y in (total - count)..<total {
                    let remaining = ProcessDaemon.maxRowsBytes - bytes
                    if remaining <= 0 {
                        throw DaemonError("rows exceed \(ProcessDaemon.maxRowsBytes) byte limit")
                    }
                    var sliceBuf = [UInt8](repeating: 0, count: remaining)
                    let len = try term.format_row(UInt32(y), buffer: &sliceBuf)
                    let line = String(decoding: sliceBuf[0..<len], as: UTF8.self)
                    let jsonLen = PureJSON.stringifyCompact(.string(line)).utf8.count
                    bytes += jsonLen
                    if bytes > ProcessDaemon.maxRowsBytes {
                        throw DaemonError("rows exceed \(ProcessDaemon.maxRowsBytes) byte limit")
                    }
                    lines.append(line)
                }
                return TerminalRows(
                    process: info,
                    lines: lines,
                    cursorX: try term.cursor_x(),
                    cursorY: try term.cursor_y()
                )
            }
        }

        internal func rename(title: String?) throws {
            stateLock.withLock {
                let normalized = title.flatMap { $0.isEmpty ? nil : $0 }
                if let changed = refreshTitleLocked(userTitleUpdate: .some(normalized)) {
                    broadcastLocked(.titleChanged(title: changed))
                }
            }
        }

        internal func replayFrom(offset: UInt64) throws -> RawReplay {
            try stateLock.withLock {
                try replay.readFrom(offset)
            }
        }

        internal func attach(
            offset: UInt64,
            attachmentId: String,
            role: AttachmentRole,
            takeover: Bool
        ) throws -> TerminalAttachment {
            try stateLock.withLock {
                if role == .controller {
                    if let current = controller {
                        if current != attachmentId && !takeover {
                            throw DaemonError("terminal already has controller \(current)")
                        }
                        if current != attachmentId, var oldSub = subscribers[current] {
                            oldSub.role = .observer
                            subscribers[current] = oldSub
                        }
                    }
                    if controller != attachmentId {
                        controllerGeneration &+= 1
                        controller = attachmentId
                    }
                }
                let rep = try replay.readFrom(offset)
                let queue = EventQueue()
                let token = nextSubToken
                nextSubToken &+= 1
                subscribers[attachmentId] = Subscriber(
                    token: token,
                    queue: queue,
                    role: role,
                    lastControl: role == .controller ? controllerGeneration : 0
                )
                if role == .controller {
                    broadcastLocked(.controllerChanged(attachmentId: controller, generation: controllerGeneration))
                }
                if let exit = finalExit {
                    _ = queue.push(.exited(exit), dropWhenFull: false)
                }
                let currentProcess = info
                let gen = controllerGeneration
                return TerminalAttachment(
                    process: currentProcess,
                    role: role,
                    generation: gen,
                    replay: rep,
                    queue: queue,
                    onDetach: { [weak self] in
                        self?.detach(attachmentId: attachmentId, token: token)
                    }
                )
            }
        }

        private func detach(attachmentId: String, token: UInt64) {
            stateLock.withLock {
                guard let existing = subscribers[attachmentId], existing.token == token else {
                    return
                }
                subscribers.removeValue(forKey: attachmentId)
                if controller == attachmentId {
                    controllerGeneration &+= 1
                    controller = promoteLatestLocked(generation: controllerGeneration)
                    broadcastLocked(.controllerChanged(attachmentId: controller, generation: controllerGeneration))
                }
            }
        }

        internal func addWaiter() -> ProcessWait {
            stateLock.withLock {
                if let exit = finalExit {
                    return ProcessWait(initialExit: exit)
                }
                let waiter = ProcessWait()
                if isStopped {
                    waiter.markTerminated()
                } else {
                    waiters.append(waiter)
                }
                return waiter
            }
        }

        internal func signalPipe(_ signal: ProcessSignal) throws {
            let proc = stateLock.withLock { pipeProcess }
            guard let proc else {
                throw DaemonError("process \(id) cannot be signalled")
            }
            try proc.signal(signal)
        }

        internal func setMetadata(_ metadata: PipeMetadata) throws {
            try stateLock.withLock {
                guard info.pipe != nil else {
                    throw DaemonError("process \(id) is not a pipe process")
                }
                info.pipe?.metadata = metadata
            }
        }

        internal func shutdown() {
            let killFn: (@Sendable () -> Void)? = stateLock.withLock {
                if isStopped { return nil }
                isStopped = true
                for waiter in waiters {
                    waiter.markTerminated()
                }
                waiters.removeAll()
                for (_, sub) in subscribers {
                    sub.queue.close()
                }
                subscribers.removeAll()
                #if !os(WASI)
                if let handle = pipeOutputHandle {
                    try? handle.close()
                    pipeOutputHandle = nil
                }
                #endif
                return killHandler
            }
            killFn?()
        }

        private func authorizeControllerLocked(attachmentId: String?) throws {
            guard let attachmentId else {
                if controller == nil { return }
                throw DaemonError("terminal input requires the active controller attachment")
            }
            if controller != attachmentId {
                throw DaemonError("attachment \(attachmentId) is not the terminal controller")
            }
        }

        private func refreshTitleLocked(userTitleUpdate: String??) -> String? {
            guard var pty = info.pty else { return nil }
            if let update = userTitleUpdate {
                pty.userTitle = update
            }
            let effective = pty.userTitle ?? oscTitle ?? createTitle
            let changed = (pty.title != effective)
            pty.title = effective
            info.pty = pty
            return changed ? effective : nil
        }

        private func broadcastLocked(_ event: StreamEvent) {
            var dropped: [String] = []
            for (subId, sub) in subscribers {
                if sub.queue.isDisconnected {
                    dropped.append(subId)
                    continue
                }
                let ok = sub.queue.push(event, dropWhenFull: sub.role == .observer)
                if !ok {
                    dropped.append(subId)
                }
            }
            var controllerDropped = false
            for subId in dropped {
                subscribers.removeValue(forKey: subId)
                if controller == subId {
                    controllerDropped = true
                }
            }
            if controllerDropped {
                controllerGeneration &+= 1
                controller = promoteLatestLocked(generation: controllerGeneration)
                broadcastLocked(.controllerChanged(attachmentId: controller, generation: controllerGeneration))
            }
        }

        private func promoteLatestLocked(generation: UInt64) -> String? {
            subscribers = subscribers.filter { !$0.value.queue.isDisconnected }
            guard let best = subscribers.max(by: { $0.value.lastControl < $1.value.lastControl }) else {
                return nil
            }
            var sub = best.value
            sub.role = .controller
            sub.lastControl = generation
            subscribers[best.key] = sub
            return best.key
        }

        private func formatTerminalVT(_ term: Ghostty.Terminal) throws -> [UInt8] {
            var bytes = try term.format(.vt)
            let cx = try term.cursor_x()
            let cy = try term.cursor_y()
            bytes.append(contentsOf: "\u{1B}[\(cy + 1);\(cx + 1)H".utf8)
            return bytes
        }

        // MARK: - Spawning PTY & Pipe Sessions

        internal static func spawnPty(
            id: TerminalId,
            order: UInt64,
            request: CreatePty,
            replayCapacity: Int,
            backend: BackendMode
        ) throws -> SessionActor {
            let terminal = try Ghostty.Terminal.new(Ghostty.TerminalOptions(
                cols: request.cols,
                rows: request.rows,
                maxScrollback: replayCapacity
            ))

            switch backend {
            case .simulated(let onWrite):
                let info = ProcessInfo(
                    id: id,
                    mode: .pty,
                    pid: UInt32(truncatingIfNeeded: id & 0xFFFF) + 1000,
                    command: [request.program] + request.args,
                    cwd: request.cwd,
                    groupId: request.groupId,
                    lifecycle: .running,
                    outputHead: 0,
                    outputTail: 0,
                    startedAt: currentUnixMs(),
                    exitedAt: nil,
                    pty: PtyInfo(
                        title: request.title,
                        userTitle: nil,
                        foregroundProcess: nil,
                        cols: request.cols,
                        rows: request.rows
                    ),
                    pipe: nil
                )
                let actor = SessionActor(
                    id: id,
                    order: order,
                    info: info,
                    terminal: terminal,
                    replayCapacity: replayCapacity
                )
                actor.writeHandler = { [weak actor] bytes in
                    guard let actor else { return }
                    if let onWrite {
                        onWrite(id, bytes, actor)
                    } else {
                        actor.emitOutput(bytes)
                    }
                }
                actor.resizeHandler = { _, _ in }
                actor.killHandler = { [weak actor] in
                    actor?.emitChildExit(exitCode: nil, signal: "SIGKILL")
                    actor?.emitReaderEof()
                }
                return actor

            case .native:
                #if (os(macOS) || os(Linux)) && (canImport(Darwin) || canImport(Glibc) || canImport(Musl))
                return try spawnNativeUnixPty(
                    id: id,
                    order: order,
                    request: request,
                    terminal: terminal,
                    replayCapacity: replayCapacity
                )
                #else
                return try spawnPty(
                    id: id,
                    order: order,
                    request: request,
                    replayCapacity: replayCapacity,
                    backend: .simulated(onWrite: nil)
                )
                #endif
            }
        }

        internal static func spawnPipe(
            id: TerminalId,
            order: UInt64,
            request: CreatePipe,
            backend: BackendMode
        ) throws -> SessionActor {
            switch backend {
            case .simulated:
                #if !os(WASI)
                let outputHandle = try openPipeOutputFile(at: request.outputPath)
                #endif
                let syntheticPid = UInt32(truncatingIfNeeded: id & 0xFFFF) + 2000
                let info = ProcessInfo(
                    id: id,
                    mode: .pipe,
                    pid: syntheticPid,
                    command: [request.program] + request.args,
                    cwd: request.cwd,
                    groupId: request.groupId,
                    lifecycle: .running,
                    outputHead: 0,
                    outputTail: 0,
                    startedAt: currentUnixMs(),
                    exitedAt: nil,
                    pty: nil,
                    pipe: PipeInfo(
                        outputPath: request.outputPath,
                        outputLines: 0,
                        outputError: nil,
                        metadata: request.metadata
                    )
                )
                let actor = SessionActor(
                    id: id,
                    order: order,
                    info: info,
                    terminal: nil,
                    replayCapacity: 0
                )
                #if !os(WASI)
                actor.pipeOutputHandle = outputHandle
                #endif
                let pipeProc = UnixPipe.Process(
                    pid: syntheticPid,
                    signalFn: { [weak actor] sig in
                        actor?.emitChildExit(exitCode: nil, signal: sig.rawValue)
                        actor?.emitReaderEof()
                    },
                    killFn: { [weak actor] in
                        actor?.emitChildExit(exitCode: nil, signal: "SIGKILL")
                        actor?.emitReaderEof()
                    }
                )
                actor.pipeProcess = pipeProc
                actor.killHandler = {
                    pipeProc.kill()
                    pipeProc.reap()
                }
                return actor

            case .native:
                #if os(macOS) || os(Linux) || os(Windows)
                return try spawnNativePipe(id: id, order: order, request: request)
                #else
                return try spawnPipe(id: id, order: order, request: request, backend: .simulated(onWrite: nil))
                #endif
            }
        }

        #if (os(macOS) || os(Linux)) && (canImport(Darwin) || canImport(Glibc) || canImport(Musl))
        private static func spawnNativeUnixPty(
            id: TerminalId,
            order: UInt64,
            request: CreatePty,
            terminal: Ghostty.Terminal,
            replayCapacity: Int
        ) throws -> SessionActor {
            let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
            guard masterFD >= 0 else {
                throw DaemonError("posix_openpt failed with errno \(errno)")
            }
            guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0, let slaveNamePtr = ptsname(masterFD) else {
                let err = errno
                _ = close(masterFD)
                throw DaemonError("failed to initialize PTY slave: errno \(err)")
            }
            let slavePath = String(cString: slaveNamePtr)
            let slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
            guard slaveFD >= 0 else {
                let err = errno
                _ = close(masterFD)
                throw DaemonError("open(\(slavePath)) failed with errno \(err)")
            }

            var ws = winsize(ws_row: request.rows, ws_col: request.cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)

            let process = Foundation.Process()
            if request.program.contains("/") {
                process.executableURL = URL(fileURLWithPath: request.program)
                process.arguments = request.args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [request.program] + request.args
            }
            process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
            var env = Foundation.ProcessInfo.processInfo.environment
            for (k, v) in request.env { env[k] = v }
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            process.environment = env

            let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle

            do {
                try process.run()
            } catch {
                _ = close(slaveFD)
                _ = close(masterFD)
                throw DaemonError("failed to spawn \(request.program): \(error)")
            }
            _ = close(slaveFD)

            let childPid = UInt32(max(0, process.processIdentifier))
            let info = ProcessInfo(
                id: id,
                mode: .pty,
                pid: childPid,
                command: [request.program] + request.args,
                cwd: request.cwd,
                groupId: request.groupId,
                lifecycle: .running,
                outputHead: 0,
                outputTail: 0,
                startedAt: currentUnixMs(),
                exitedAt: nil,
                pty: PtyInfo(
                    title: request.title,
                    userTitle: nil,
                    foregroundProcess: nil,
                    cols: request.cols,
                    rows: request.rows
                ),
                pipe: nil
            )
            let actor = SessionActor(
                id: id,
                order: order,
                info: info,
                terminal: terminal,
                replayCapacity: replayCapacity
            )

            let masterBox = Mutex<Int32>(masterFD)
            actor.writeHandler = { bytes in
                guard !bytes.isEmpty else { return }
                let fd = masterBox.withLock { $0 }
                guard fd >= 0 else { throw DaemonError("PTY closed") }
                var offset = 0
                while offset < bytes.count {
                    let n = bytes.withUnsafeBytes { ptr in
                        DarwinOrPosixIO.write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
                    }
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw DaemonError("PTY write failed with errno \(errno)")
                    }
                    offset += n
                }
            }
            actor.resizeHandler = { cols, rows in
                let fd = masterBox.withLock { $0 }
                guard fd >= 0 else { throw DaemonError("PTY closed") }
                var newWS = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(fd, UInt(TIOCSWINSZ), &newWS)
            }
            actor.killHandler = {
                if process.isRunning {
                    _ = DarwinOrPosixKill.send(process.processIdentifier, SIGKILL)
                    process.terminate()
                }
                let fd = masterBox.withLock { cur -> Int32 in
                    let old = cur
                    cur = -1
                    return old
                }
                if fd >= 0 { _ = close(fd) }
            }

            // Reader thread draining PTY master output
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 8192)
                while true {
                    let fd = masterBox.withLock { $0 }
                    if fd < 0 {
                        actor.emitReaderEof()
                        break
                    }
                    let n = buf.withUnsafeMutableBytes { ptr in
                        DarwinOrPosixIO.read(fd, ptr.baseAddress!, ptr.count)
                    }
                    if n > 0 {
                        actor.emitOutput(Array(buf[0..<n]))
                    } else if n == 0 {
                        actor.emitReaderEof()
                        break
                    } else {
                        let err = errno
                        if err == EINTR { continue }
                        if err == EIO || err == EBADF {
                            actor.emitReaderEof()
                            break
                        }
                        actor.emitReaderFailed("errno \(err)")
                        break
                    }
                }
            }

            // Child exit waiter thread
            Thread.detachNewThread {
                process.waitUntilExit()
                if process.terminationReason == .uncaughtSignal {
                    actor.emitChildExit(exitCode: nil, signal: "SIG\(process.terminationStatus)")
                } else {
                    actor.emitChildExit(exitCode: UInt32(bitPattern: process.terminationStatus))
                }
            }

            return actor
        }
        #endif

        #if os(macOS) || os(Linux) || os(Windows)
        private static func spawnNativePipe(
            id: TerminalId,
            order: UInt64,
            request: CreatePipe
        ) throws -> SessionActor {
            let outputHandle = try openPipeOutputFile(at: request.outputPath)
            let pipe = Pipe()
            let process = Foundation.Process()
            if request.program.contains("/") || request.program.contains("\\") {
                process.executableURL = URL(fileURLWithPath: request.program)
                process.arguments = request.args
            } else {
                #if os(Windows)
                process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
                process.arguments = ["/c", request.program] + request.args
                #else
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [request.program] + request.args
                #endif
            }
            process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
            process.environment = request.env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                try? outputHandle.close()
                throw DaemonError("failed to spawn \(request.program): \(error)")
            }
            try? pipe.fileHandleForWriting.close()

            let childPid = UInt32(max(0, process.processIdentifier))
            let info = ProcessInfo(
                id: id,
                mode: .pipe,
                pid: childPid,
                command: [request.program] + request.args,
                cwd: request.cwd,
                groupId: request.groupId,
                lifecycle: .running,
                outputHead: 0,
                outputTail: 0,
                startedAt: currentUnixMs(),
                exitedAt: nil,
                pty: nil,
                pipe: PipeInfo(
                    outputPath: request.outputPath,
                    outputLines: 0,
                    outputError: nil,
                    metadata: request.metadata
                )
            )
            let actor = SessionActor(
                id: id,
                order: order,
                info: info,
                terminal: nil,
                replayCapacity: 0
            )
            actor.pipeOutputHandle = outputHandle

            let recordedSignal = Mutex<String?>(nil)
            let pipeProc = UnixPipe.Process(
                pid: childPid,
                signalFn: { sig in
                    guard process.isRunning else { return }
                    recordedSignal.withLock { if $0 == nil { $0 = sig.rawValue } }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let cSig: Int32 = switch sig {
                    case .term: SIGTERM
                    case .int: SIGINT
                    case .kill: SIGKILL
                    }
                    _ = DarwinOrPosixKill.send(process.processIdentifier, cSig)
                    #else
                    process.terminate()
                    #endif
                },
                killFn: {
                    guard process.isRunning else { return }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    _ = DarwinOrPosixKill.send(process.processIdentifier, SIGKILL)
                    #else
                    process.terminate()
                    #endif
                },
                reapFn: {
                    if process.isRunning {
                        process.waitUntilExit()
                    }
                }
            )
            actor.pipeProcess = pipeProc
            actor.killHandler = {
                pipeProc.kill()
                try? pipe.fileHandleForReading.close()
            }

            let readerHandle = pipe.fileHandleForReading
            Thread.detachNewThread {
                while true {
                    let data = readerHandle.availableData
                    if data.isEmpty {
                        actor.emitReaderEof()
                        break
                    }
                    actor.emitOutput(Array(data))
                }
                try? readerHandle.close()
            }

            Thread.detachNewThread {
                process.waitUntilExit()
                pipeProc.reap()
                if process.terminationReason == .uncaughtSignal {
                    let sigName = recordedSignal.withLock { $0 } ?? posixSignalName(process.terminationStatus)
                    actor.emitChildExit(exitCode: nil, signal: sigName)
                } else if let sigName = recordedSignal.withLock({ $0 }) {
                    actor.emitChildExit(exitCode: nil, signal: sigName)
                } else {
                    actor.emitChildExit(exitCode: UInt32(bitPattern: process.terminationStatus))
                }
            }

            return actor
        }
        #endif

        #if !os(WASI)
        private static func openPipeOutputFile(at path: String) throws -> FileHandle {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o666)
            guard fd >= 0 else {
                throw DaemonError("failed to open output file \(path): errno \(errno)")
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            #else
            let url = URL(fileURLWithPath: path)
            FileManager.default.createFile(atPath: path, contents: Data())
            return try FileHandle(forWritingTo: url)
            #endif
        }
        #endif
    }

    // MARK: - Persistent Terminal & Pipe Registry Service (`src/service.rs`)

    // parity: process-daemon/src/service.rs#TerminalService [status=implemented hash=cf9858a40dfe]
    public final class TerminalService: @unchecked Sendable {
        private struct Registry: Sendable {
            var sessions: [TerminalId: SessionActor] = [:]
            var nextOrder: UInt64 = 0
        }

        private let registry = Mutex(Registry())
        public let replayCapacity: Int
        public let backend: BackendMode

        private init(replayCapacity: Int, backend: BackendMode) {
            self.replayCapacity = replayCapacity
            self.backend = backend
        }

        deinit {
            shutdown()
        }

        // parity: process-daemon/src/service.rs#new [status=implemented hash=b7fa9567fadd]
        public static func new(
            replayCapacity: Int = ProcessDaemon.defaultReplayCapacity,
            backend: BackendMode = .native
        ) -> TerminalService {
            TerminalService(replayCapacity: replayCapacity, backend: backend)
        }

        /// Direct handle access for deterministic simulated-process tests.
        public func sessionActor(for id: TerminalId) -> SessionActor? {
            registry.withLock { $0.sessions[id] }
        }

        // parity: process-daemon/src/service.rs#create_pty [status=implemented hash=34308b5d964c]
        public func create_pty(_ request: CreatePty) throws -> ProcessInfo {
            try validateSize(cols: request.cols, rows: request.rows)
            try validateProgram(request.program)
            return try insertSession { id, order in
                try SessionActor.spawnPty(
                    id: id,
                    order: order,
                    request: request,
                    replayCapacity: replayCapacity,
                    backend: backend
                )
            }
        }

        // parity: process-daemon/src/service.rs#create_pipe [status=implemented hash=a4f0a4df775d]
        public func create_pipe(_ request: CreatePipe) throws -> ProcessInfo {
            try validateProgram(request.program)
            guard isAbsolutePath(request.cwd) else {
                throw DaemonError("cwd must be absolute")
            }
            guard isAbsolutePath(request.outputPath) else {
                throw DaemonError("output_path must be absolute")
            }
            try validateMetadata(request.metadata)
            return try insertSession { id, order in
                try UnixPipe.spawn_pipe(id: id, order: order, request: request, backend: backend)
            }
        }

        private func insertSession(
            _ make: (TerminalId, UInt64) throws -> SessionActor
        ) throws -> ProcessInfo {
            let (id, order) = registry.withLock { reg -> (TerminalId, UInt64) in
                let maxSafeInt: UInt64 = (1 << 53) - 1
                var candidate: UInt64 = 0
                repeat {
                    candidate = UInt64.random(in: 1...maxSafeInt)
                } while reg.sessions[candidate] != nil
                let ord = reg.nextOrder
                reg.nextOrder &+= 1
                return (candidate, ord)
            }
            let actor = try make(id, order)
            let info = actor.currentInfo()
            registry.withLock { $0.sessions[id] = actor }
            return info
        }

        // parity: process-daemon/src/service.rs#list [status=implemented hash=1e25ce8a5997]
        public func list(_ mode: ProcessMode) throws -> [ProcessInfo] {
            let matching = registry.withLock { reg -> [SessionActor] in
                reg.sessions.values
                    .filter { $0.mode == mode }
                    .sorted { $0.order < $1.order }
            }
            return matching.map { $0.currentInfo() }
        }

        // parity: process-daemon/src/service.rs#get [status=implemented hash=9b07e699d08a]
        public func get(_ id: TerminalId) throws -> ProcessInfo {
            try requireHandle(id).currentInfo()
        }

        // parity: process-daemon/src/service.rs#wait [status=implemented hash=91468ed78cb6]
        public func wait(_ id: TerminalId) throws -> ProcessWait {
            try requirePipe(id).addWaiter()
        }

        // parity: process-daemon/src/service.rs#signal [status=implemented hash=66fa59ccc393]
        public func signal(id: TerminalId, signal: ProcessSignal) throws {
            try requirePipe(id).signalPipe(signal)
        }

        // parity: process-daemon/src/service.rs#set_metadata [status=implemented hash=37afad94c08d]
        public func set_metadata(id: TerminalId, metadata: PipeMetadata) throws {
            try validateMetadata(metadata)
            try requirePipe(id).setMetadata(metadata)
        }

        // parity: process-daemon/src/service.rs#write [status=implemented hash=04eb885fd4a0]
        public func write(id: TerminalId, bytes: [UInt8]) throws {
            try write_for(id: id, attachmentId: nil, bytes: bytes)
        }

        // parity: process-daemon/src/service.rs#write_for [status=implemented hash=f5e4f49fd3ad]
        public func write_for(id: TerminalId, attachmentId: String?, bytes: [UInt8]) throws {
            if bytes.count > ProcessDaemon.maxInputBytes {
                throw DaemonError("input exceeds \(ProcessDaemon.maxInputBytes) byte limit")
            }
            try requirePty(id).write(attachmentId: attachmentId, bytes: bytes)
        }

        // parity: process-daemon/src/service.rs#resize [status=implemented hash=cba4b23acc68]
        public func resize(id: TerminalId, cols: UInt16, rows: UInt16) throws {
            try resize_for(id: id, attachmentId: nil, cols: cols, rows: rows)
        }

        // parity: process-daemon/src/service.rs#resize_for [status=implemented hash=d8fac430bb33]
        public func resize_for(id: TerminalId, attachmentId: String?, cols: UInt16, rows: UInt16) throws {
            let pty = try requirePty(id)
            try validateSize(cols: cols, rows: rows)
            try pty.resize(attachmentId: attachmentId, cols: cols, rows: rows)
        }

        // parity: process-daemon/src/service.rs#control [status=implemented hash=9718f5ea3817]
        public func control(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16) throws {
            let pty = try requirePty(id)
            try validateSize(cols: cols, rows: rows)
            try pty.control(attachmentId: attachmentId, cols: cols, rows: rows, bytes: nil)
        }

        // parity: process-daemon/src/service.rs#input [status=implemented hash=f58bec981c83]
        public func input(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16, bytes: [UInt8]) throws {
            let pty = try requirePty(id)
            try validateSize(cols: cols, rows: rows)
            if bytes.count > ProcessDaemon.maxInputBytes {
                throw DaemonError("input exceeds \(ProcessDaemon.maxInputBytes) byte limit")
            }
            try pty.control(attachmentId: attachmentId, cols: cols, rows: rows, bytes: bytes)
        }

        // parity: process-daemon/src/service.rs#snapshot [status=implemented hash=562e497b0477]
        public func snapshot(_ id: TerminalId) throws -> TerminalSnapshot {
            try requirePty(id).snapshot()
        }

        // parity: process-daemon/src/service.rs#read_rows [status=implemented hash=66550b6ae77a]
        public func read_rows(id: TerminalId, rows: UInt16? = nil) throws -> TerminalRows {
            try requirePty(id).readRows(count: rows)
        }

        // parity: process-daemon/src/service.rs#rename [status=implemented hash=1505ec1e1bb6]
        public func rename(id: TerminalId, title: String?) throws {
            try requirePty(id).rename(title: title)
        }

        // parity: process-daemon/src/service.rs#replay [status=implemented hash=faaed38f6f72]
        public func replay(id: TerminalId, offset: UInt64) throws -> RawReplay {
            try requireHandle(id).replayFrom(offset: offset)
        }

        // parity: process-daemon/src/service.rs#attach [status=implemented hash=f8fe24689c85]
        public func attach(
            id: TerminalId,
            offset: UInt64,
            attachmentId: String,
            role: AttachmentRole,
            takeover: Bool
        ) throws -> TerminalAttachment {
            try requireHandle(id).attach(
                offset: offset,
                attachmentId: attachmentId,
                role: role,
                takeover: takeover
            )
        }

        // parity: process-daemon/src/service.rs#terminate [status=implemented hash=0542fc181732]
        public func terminate(_ id: TerminalId) throws {
            let actor = try registry.withLock { reg -> SessionActor in
                guard let removed = reg.sessions.removeValue(forKey: id) else {
                    throw DaemonError("process \(id) not found")
                }
                return removed
            }
            actor.shutdown()
        }

        // parity: process-daemon/src/service.rs#shutdown [status=implemented hash=7184d3cae252]
        public func shutdown() {
            let actors = registry.withLock { reg -> [SessionActor] in
                let all = Array(reg.sessions.values)
                reg.sessions.removeAll()
                return all
            }
            for actor in actors {
                actor.shutdown()
            }
        }

        private func requireHandle(_ id: TerminalId) throws -> SessionActor {
            try registry.withLock { reg in
                guard let actor = reg.sessions[id] else {
                    throw DaemonError("process \(id) not found")
                }
                return actor
            }
        }

        private func requirePty(_ id: TerminalId) throws -> SessionActor {
            let actor = try requireHandle(id)
            if !actor.mode.is_pty() {
                throw DaemonError("process \(id) is a pipe process, which has no terminal")
            }
            return actor
        }

        private func requirePipe(_ id: TerminalId) throws -> SessionActor {
            let actor = try requireHandle(id)
            if actor.mode != .pipe {
                throw DaemonError("process \(id) is a terminal, not a pipe process")
            }
            return actor
        }

        private func validateProgram(_ program: String) throws {
            if program.allSatisfy(\.isWhitespace) {
                throw DaemonError("program cannot be empty")
            }
        }

        private func validateSize(cols: UInt16, rows: UInt16) throws {
            if cols == 0 || rows == 0 {
                throw DaemonError("terminal dimensions must be positive")
            }
        }

        private func validateMetadata(_ metadata: PipeMetadata) throws {
            #if !os(WASI)
            let data = try JSONEncoder().encode(metadata)
            if data.count > ProcessDaemon.MAX_METADATA_BYTES {
                throw DaemonError("metadata exceeds \(ProcessDaemon.MAX_METADATA_BYTES) byte limit")
            }
            #else
            var estimatedBytes = 2
            for (k, v) in metadata {
                estimatedBytes += k.utf8.count + String(describing: v).utf8.count + 4
            }
            if estimatedBytes > ProcessDaemon.MAX_METADATA_BYTES {
                throw DaemonError("metadata exceeds \(ProcessDaemon.MAX_METADATA_BYTES) byte limit")
            }
            #endif
        }
    }

    // MARK: - Protocol v9 Client (`src/client.rs`)

    // parity: process-daemon/src/client.rs#RemoteSnapshot [status=implemented hash=e63f49a350d0]
    public struct RemoteSnapshot: Equatable, Sendable {
        public let terminal: ProcessInfo
        public let text: String
        public let checkpoint: [UInt8]
        public let cursorX: UInt16
        public let cursorY: UInt16

        public init(terminal: ProcessInfo, text: String, checkpoint: [UInt8], cursorX: UInt16, cursorY: UInt16) {
            self.terminal = terminal
            self.text = text
            self.checkpoint = checkpoint
            self.cursorX = cursorX
            self.cursorY = cursorY
        }
    }

    // parity: process-daemon/src/client.rs#RemoteReplay [status=implemented hash=bcfed9b576c3]
    public struct RemoteReplay: Equatable, Sendable {
        public let requestedOffset: UInt64
        public let availableOffset: UInt64
        public let endOffset: UInt64
        public let truncated: Bool
        public let bytes: [UInt8]

        public init(
            requestedOffset: UInt64,
            availableOffset: UInt64,
            endOffset: UInt64,
            truncated: Bool,
            bytes: [UInt8]
        ) {
            self.requestedOffset = requestedOffset
            self.availableOffset = availableOffset
            self.endOffset = endOffset
            self.truncated = truncated
            self.bytes = bytes
        }
    }

    // parity: process-daemon/src/client.rs#TerminalSubscription [status=implemented hash=3f0e80fce854]
    public final class TerminalSubscription: @unchecked Sendable {
        private let stream: Transport.Unix.Connection
        public let terminal: ProcessInfo
        public let role: AttachmentRole
        public let generation: UInt64
        public let replay: RemoteReplay

        internal init(
            stream: Transport.Unix.Connection,
            terminal: ProcessInfo,
            role: AttachmentRole,
            generation: UInt64,
            replay: RemoteReplay
        ) {
            self.stream = stream
            self.terminal = terminal
            self.role = role
            self.generation = generation
            self.replay = replay
        }

        deinit {
            stream.closeConnection()
        }

        public func close() {
            stream.closeConnection()
        }

        // parity: process-daemon/src/client.rs#next_event [status=implemented hash=b883f056cd40]
        public func next_event() throws -> SubscriptionEvent {
            try ProcessDaemon.read_subscription_event(stream)
        }
    }

    // parity: process-daemon/src/client.rs#TerminalClient [status=implemented hash=624e251a8311]
    public final class TerminalClient: @unchecked Sendable {
        public let registration: Registration
        private var ownerStream: Transport.Unix.Connection?
        private var ownedServer: Daemon.Server.RunningInstance?

        public init(registration: Registration) {
            self.registration = registration
        }

        internal init(
            registration: Registration,
            ownerStream: Transport.Unix.Connection?,
            ownedServer: Daemon.Server.RunningInstance? = nil
        ) {
            self.registration = registration
            self.ownerStream = ownerStream
            self.ownedServer = ownedServer
        }

        deinit {
            ownerStream?.closeConnection()
        }

        /// Starts a daemon server for `directory` (in-memory or Unix socket) and claims ownership.
        // parity: process-daemon/src/client.rs#start [status=adapted hash=1ab4969adba8]
        public static func start(
            _ directory: String,
            useInMemoryEndpoint: Bool = false,
            backend: BackendMode = .native
        ) throws -> TerminalClient {
            let service = TerminalService.new(backend: backend)
            let server = try Daemon.Server.startBackground(
                directory: directory,
                useInMemoryEndpoint: useInMemoryEndpoint || directory.hasPrefix("memory://"),
                service: service
            )
            let reg = server.registration
            let stream = try Transport.Unix.Connection.connect(reg.socket)
            try stream.set_read_timeout(5_000)
            try stream.set_write_timeout(5_000)
            try ProcessDaemon.write_frame(
                stream,
                value: Envelope(
                    token: reg.token,
                    request: .own(instanceId: reg.instanceId, ticket: nil)
                )
            )
            let response: Response = try ProcessDaemon.read_frame(stream)
            guard case .owned = response else {
                stream.closeConnection()
                server.stopAndWait()
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return TerminalClient(registration: reg, ownerStream: stream, ownedServer: server)
        }

        // parity: process-daemon/src/client.rs#discover [status=implemented hash=0825a7b0e8d4]
        public static func discover(_ directory: String) throws -> TerminalClient {
            let reg = try Daemon.read_registration(directory)
            guard reg.protocolVersion == ProcessDaemon.PROTOCOL_VERSION else {
                throw DaemonError(
                    "opencode-pty protocol mismatch: service=\(reg.protocolVersion), client=\(ProcessDaemon.PROTOCOL_VERSION)"
                )
            }
            let client = TerminalClient(registration: reg)
            let pong = try client.sendRequest(.ping)
            guard case let .pong(instanceId, pid, proto, _) = pong,
                  instanceId == reg.instanceId,
                  pid == reg.pid,
                  proto == ProcessDaemon.PROTOCOL_VERSION else {
                throw DaemonError("opencode-pty registration did not match the running service")
            }
            return client
        }

        /// Requests a restart handoff ticket over the held owner connection.
        public func prepareHandoff() throws -> (ticket: String, expiresAt: UInt64) {
            guard let ownerStream else {
                throw DaemonError("handoff requires the owner connection")
            }
            try ProcessDaemon.write_frame(
                ownerStream,
                value: Envelope(token: registration.token, request: .prepareHandoff)
            )
            let response: Response = try ProcessDaemon.read_frame(ownerStream)
            switch response {
            case let .handoff(ticket, expiresAt):
                return (ticket, expiresAt)
            case .error(let message):
                throw DaemonError(message)
            default:
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
        }

        /// Claims ownership of an existing daemon instance using an optional handoff ticket.
        public func claimOwnership(ticket: String? = nil) throws -> TerminalClient {
            let stream = try Transport.Unix.Connection.connect(registration.socket)
            try ProcessDaemon.write_frame(
                stream,
                value: Envelope(
                    token: registration.token,
                    request: .own(instanceId: registration.instanceId, ticket: ticket)
                )
            )
            let response: Response = try ProcessDaemon.read_frame(stream)
            switch response {
            case .owned:
                return TerminalClient(registration: registration, ownerStream: stream)
            case .error(let message):
                stream.closeConnection()
                throw DaemonError(message)
            default:
                stream.closeConnection()
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
        }

        public func releaseOwnership() {
            ownerStream?.closeConnection()
            ownerStream = nil
        }

        public func ping() throws -> Response {
            try sendRequest(.ping)
        }

        // parity: process-daemon/src/client.rs#create_pty [status=implemented hash=cc0717d5efde]
        public func create_pty(_ request: CreatePty) throws -> ProcessInfo {
            let response = try sendRequest(.createPty(
                program: request.program,
                args: request.args,
                cwd: request.cwd,
                env: request.env,
                groupId: request.groupId,
                title: request.title,
                cols: request.cols,
                rows: request.rows
            ))
            guard case .created(let process) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return process
        }

        // parity: process-daemon/src/client.rs#create_pipe [status=implemented hash=379c2f466103]
        public func create_pipe(_ request: CreatePipe) throws -> ProcessInfo {
            let response = try sendRequest(.createPipe(
                program: request.program,
                args: request.args,
                cwd: request.cwd,
                env: request.env,
                groupId: request.groupId,
                outputPath: request.outputPath,
                metadata: request.metadata
            ))
            guard case .created(let process) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return process
        }

        // parity: process-daemon/src/client.rs#list [status=implemented hash=ff2fee1e4390]
        public func list(_ mode: ProcessMode) throws -> [ProcessInfo] {
            let response = try sendRequest(.list(mode: mode))
            guard case .processes(let processes) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return processes
        }

        // parity: process-daemon/src/client.rs#get [status=implemented hash=61234247ec65]
        public func get(_ id: TerminalId) throws -> ProcessInfo {
            let response = try sendRequest(.get(id: id))
            guard case .process(let process) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return process
        }

        // parity: process-daemon/src/client.rs#wait [status=implemented hash=69dfc7f2bb75]
        public func wait(_ id: TerminalId) throws -> Response {
            let response = try sendRequest(.wait(id: id))
            guard case .exited = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return response
        }

        // parity: process-daemon/src/client.rs#signal [status=implemented hash=0960dfca0ae0]
        public func signal(id: TerminalId, signal: ProcessSignal) throws {
            try expectOk(.signal(id: id, signal: signal))
        }

        // parity: process-daemon/src/client.rs#set_metadata [status=implemented hash=c6d6836116d0]
        public func set_metadata(id: TerminalId, metadata: PipeMetadata) throws {
            try expectOk(.setMetadata(id: id, metadata: metadata))
        }

        // parity: process-daemon/src/client.rs#write [status=implemented hash=0a448b8efafb]
        public func write(id: TerminalId, data: [UInt8]) throws {
            try write_for(id: id, attachmentId: nil, data: data)
        }

        // parity: process-daemon/src/client.rs#write_for [status=implemented hash=b999d2015a0c]
        public func write_for(id: TerminalId, attachmentId: String?, data: [UInt8]) throws {
            try expectOk(.write(id: id, attachmentId: attachmentId, dataBase64: bytesToBase64(data)))
        }

        // parity: process-daemon/src/client.rs#resize [status=implemented hash=cba4b23acc68]
        public func resize(id: TerminalId, cols: UInt16, rows: UInt16) throws {
            try resize_for(id: id, attachmentId: nil, cols: cols, rows: rows)
        }

        // parity: process-daemon/src/client.rs#resize_for [status=implemented hash=6ef147e9e72d]
        public func resize_for(id: TerminalId, attachmentId: String?, cols: UInt16, rows: UInt16) throws {
            try expectOk(.resize(id: id, attachmentId: attachmentId, cols: cols, rows: rows))
        }

        // parity: process-daemon/src/client.rs#control [status=implemented hash=4eb49d0c6a81]
        public func control(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16) throws {
            try expectOk(.control(id: id, attachmentId: attachmentId, cols: cols, rows: rows))
        }

        // parity: process-daemon/src/client.rs#input [status=implemented hash=a7daed2f1c79]
        public func input(id: TerminalId, attachmentId: String, cols: UInt16, rows: UInt16, data: [UInt8]) throws {
            try expectOk(.input(
                id: id,
                attachmentId: attachmentId,
                cols: cols,
                rows: rows,
                dataBase64: bytesToBase64(data)
            ))
        }

        // parity: process-daemon/src/client.rs#snapshot [status=implemented hash=89e8cd358ec3]
        public func snapshot(_ id: TerminalId) throws -> RemoteSnapshot {
            let response = try sendRequest(.snapshot(id: id))
            guard case let .snapshot(terminal, text, checkpointBase64, cursorX, cursorY) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            let checkpoint: [UInt8]
            do {
                checkpoint = try base64ToBytes(checkpointBase64)
            } catch {
                throw DaemonError("invalid checkpoint base64: \(error)")
            }
            return RemoteSnapshot(
                terminal: terminal,
                text: text,
                checkpoint: checkpoint,
                cursorX: cursorX,
                cursorY: cursorY
            )
        }

        // parity: process-daemon/src/client.rs#read_rows [status=implemented hash=a84de534b747]
        public func read_rows(id: TerminalId, rows: UInt16? = nil) throws -> TerminalRows {
            let response = try sendRequest(.readRows(id: id, rows: rows))
            guard case let .rows(process, lines, cursorX, cursorY) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            return TerminalRows(process: process, lines: lines, cursorX: cursorX, cursorY: cursorY)
        }

        public func rename(id: TerminalId, title: String?) throws {
            try expectOk(.rename(id: id, title: title))
        }

        // parity: process-daemon/src/client.rs#replay [status=implemented hash=cd1dfb1fc2fb]
        public func replay(id: TerminalId, offset: UInt64) throws -> RemoteReplay {
            let response = try sendRequest(.replay(id: id, offset: offset))
            guard case let .replay(req, avail, end, truncated, dataBase64) = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
            let bytes: [UInt8]
            do {
                bytes = try base64ToBytes(dataBase64)
            } catch {
                throw DaemonError("invalid replay base64: \(error)")
            }
            return RemoteReplay(
                requestedOffset: req,
                availableOffset: avail,
                endOffset: end,
                truncated: truncated,
                bytes: bytes
            )
        }

        // parity: process-daemon/src/client.rs#terminate [status=implemented hash=5f3b11d6b60f]
        public func terminate(_ id: TerminalId) throws {
            try expectOk(.terminate(id: id))
        }

        // parity: process-daemon/src/client.rs#subscribe [status=implemented hash=3438035e996a]
        public func subscribe(
            id: TerminalId,
            offset: UInt64,
            attachmentId: String,
            role: AttachmentRole,
            takeover: Bool
        ) throws -> TerminalSubscription {
            let stream = try Transport.Unix.Connection.connect(registration.socket)
            try ProcessDaemon.write_frame(
                stream,
                value: Envelope(
                    token: registration.token,
                    request: .subscribe(
                        id: id,
                        offset: offset,
                        attachmentId: attachmentId,
                        role: role,
                        takeover: takeover
                    )
                )
            )
            let response: Response = try ProcessDaemon.read_frame(stream)
            switch response {
            case let .attached(terminal, attachedRole, generation, req, avail, end, truncated, replayBase64):
                let bytes: [UInt8]
                do {
                    bytes = try base64ToBytes(replayBase64)
                } catch {
                    stream.closeConnection()
                    throw DaemonError("invalid subscription replay base64: \(error)")
                }
                return TerminalSubscription(
                    stream: stream,
                    terminal: terminal,
                    role: attachedRole,
                    generation: generation,
                    replay: RemoteReplay(
                        requestedOffset: req,
                        availableOffset: avail,
                        endOffset: end,
                        truncated: truncated,
                        bytes: bytes
                    )
                )
            case .error(let message):
                stream.closeConnection()
                throw DaemonError(message)
            default:
                stream.closeConnection()
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
        }

        // parity: process-daemon/src/client.rs#shutdown [status=implemented hash=dd18ba1f09af]
        public func shutdown() throws {
            try expectOk(.shutdown)
            ownedServer?.waitUntilStopped(timeoutMs: 3_000)
        }

        private func expectOk(_ request: Request) throws {
            let response = try sendRequest(request)
            guard case .ok = response else {
                throw DaemonError("unexpected opencode-pty response: \(response)")
            }
        }

        private func sendRequest(_ request: Request) throws -> Response {
            let stream = try Transport.Unix.Connection.connect(registration.socket)
            defer { stream.closeConnection() }
            try ProcessDaemon.write_frame(
                stream,
                value: Envelope(token: registration.token, request: request)
            )
            let response: Response = try ProcessDaemon.read_frame(stream)
            if case .error(let message) = response {
                throw DaemonError(message)
            }
            return response
        }

        // parity: process-daemon/src/client.rs#run_cli [status=adapted hash=c15693d4d59b]
        public static func run_cli(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws -> String {
            guard let command = arguments.first else {
                return "usage: opencode-pty [play|status|list|watch ID|stop|daemon] --name NAME [--runtime-dir DIR]"
            }
            var idx = 1
            var name: String?
            var root: String?
            var positional: [String] = []
            while idx < arguments.count {
                let arg = arguments[idx]
                idx += 1
                if arg == "--name" {
                    guard idx < arguments.count else { throw DaemonError("--name needs a value") }
                    name = arguments[idx]
                    idx += 1
                } else if arg == "--runtime-dir" {
                    guard idx < arguments.count else { throw DaemonError("--runtime-dir needs a value") }
                    root = arguments[idx]
                    idx += 1
                } else {
                    positional.append(arg)
                }
            }

            func resolveDirectory() throws -> String {
                guard let name else {
                    throw DaemonError("--name is required; use `opencode-pty help`")
                }
                return try Daemon.runtime_dir(root: root, name: name)
            }

            switch command {
            case "version", "--version", "-V":
                return "opencode-pty 0.1.0 (protocol \(ProcessDaemon.PROTOCOL_VERSION))"
            case "help", "--help", "-h":
                return "usage: opencode-pty [play|status|list|watch ID|stop|daemon] --name NAME [--runtime-dir DIR]"
            case "daemon":
                guard positional.isEmpty else {
                    throw DaemonError("usage: opencode-pty daemon --name NAME [--runtime-dir DIR]")
                }
                try Daemon.run(try resolveDirectory())
                return "stopped"
            case "status":
                let client = try TerminalClient.discover(try resolveDirectory())
                let count = try client.list(.pty).count
                return "opencode-pty running: pid=\(client.registration.pid) instance=\(client.registration.instanceId) terminals=\(count)"
            case "list":
                let client = try TerminalClient.discover(try resolveDirectory())
                let terms = try client.list(.pty)
                if terms.isEmpty { return "no terminals" }
                return terms.map { "\($0.id) \($0.pty?.title ?? "")" }.joined(separator: "\n")
            case "stop":
                let client = try TerminalClient.discover(try resolveDirectory())
                let pid = client.registration.pid
                try client.shutdown()
                return "stopped opencode-pty pid=\(pid) (all terminals exited)"
            default:
                throw DaemonError("unknown command \"\(command)\"; use `opencode-pty help`")
            }
        }
    }
}

// MARK: - Internal Session Synchronization & POSIX Signal Helpers

private final class ReentrantSessionLock: @unchecked Sendable {
    #if !os(WASI)
    private let lock = NSRecursiveLock()
    #endif

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        #if !os(WASI)
        lock.lock()
        defer { lock.unlock() }
        #endif
        return try body()
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
private enum DarwinOrPosixKill {
    static func send(_ pid: Int32, _ sig: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.kill(pid, sig)
        #elseif canImport(Glibc)
        return Glibc.kill(pid, sig)
        #else
        return Musl.kill(pid, sig)
        #endif
    }
}

private enum DarwinOrPosixIO {
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buf, count)
        #elseif canImport(Glibc)
        return Glibc.read(fd, buf, count)
        #else
        return Musl.read(fd, buf, count)
        #endif
    }

    static func write(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buf, count)
        #elseif canImport(Glibc)
        return Glibc.write(fd, buf, count)
        #else
        return Musl.write(fd, buf, count)
        #endif
    }
}

private func posixSignalName(_ signal: Int32) -> String {
    switch signal {
    case SIGHUP: return "SIGHUP"
    case SIGINT: return "SIGINT"
    case SIGQUIT: return "SIGQUIT"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGABRT: return "SIGABRT"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    case SIGKILL: return "SIGKILL"
    case SIGUSR1: return "SIGUSR1"
    case SIGSEGV: return "SIGSEGV"
    case SIGUSR2: return "SIGUSR2"
    case SIGPIPE: return "SIGPIPE"
    case SIGALRM: return "SIGALRM"
    case SIGTERM: return "SIGTERM"
    default: return "SIG\(signal)"
    }
}
#endif
