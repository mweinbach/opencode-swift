#if !os(WASI)
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Portable Condition Helper

internal final class PortableCondition: @unchecked Sendable {
    #if !os(WASI)
    private let cond = NSCondition()
    #endif

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        #if !os(WASI)
        cond.lock()
        defer { cond.unlock() }
        #endif
        return try body()
    }

    func wait(timeoutMs: UInt64? = nil) -> Bool {
        #if !os(WASI)
        if let timeoutMs {
            let until = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000.0)
            return cond.wait(until: until)
        }
        cond.wait()
        return true
        #else
        return false
        #endif
    }

    func signal() {
        #if !os(WASI)
        cond.signal()
        #endif
    }

    func broadcast() {
        #if !os(WASI)
        cond.broadcast()
        #endif
    }
}

internal func monotonicNowMs() -> UInt64 {
    #if !os(WASI)
    return UInt64((ProcessInfo.processInfo.systemUptime * 1_000.0).rounded())
    #else
    return UInt64(max(0, Flock.currentEpochMs()))
    #endif
}

internal func currentUnixMs() -> UInt64 {
    UInt64(max(0, Flock.currentEpochMs()))
}

internal func currentProcessID() -> UInt32 {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    return UInt32(max(0, getpid()))
    #elseif canImport(WinSDK)
    return UInt32(GetCurrentProcessId())
    #else
    return 1
    #endif
}

// MARK: - ProcessDaemon Transport & Daemon Server

extension ProcessDaemon {
    public enum Transport {
        // MARK: - Shared Transport Contracts (`src/transport/mod.rs`)

        /// Platform-neutral readiness returned by `StreamListener.waitForReadiness`.
        public struct Readiness: Equatable, Hashable, Sendable {
            public var connection: Bool
            public var timedOut: Bool

            public init(connection: Bool = false, timedOut: Bool = false) {
                self.connection = connection
                self.timedOut = timedOut
            }
        }

        /// Platform-neutral wake channel shared by `Daemon.Control` and `StreamListener`.
        public protocol WakeChannel: Sendable {
            func notify()
            func drain() -> Bool
            func pending() -> Bool
        }

        /// Platform-neutral idempotent cancellation handle waking blocked reads and writes.
        public protocol ConnectionCancellation: Sendable {
            func cancel()
        }

        /// Platform-neutral peer disconnect monitor for subscriptions and `wait` calls.
        public protocol ConnectionDisconnectMonitor: Sendable {
            func disconnected() -> Bool
            func finish()
        }

        /// Platform-neutral local full-duplex byte-stream connection shared by `Daemon.Server` and `TerminalClient`.
        public protocol StreamConnection: ByteReader, ByteWriter, Sendable {
            func closeConnection()
            func set_read_timeout(_ timeoutMs: UInt64?) throws
            func set_write_timeout(_ timeoutMs: UInt64?) throws
            func makeCancellation() throws -> any ConnectionCancellation
            func finish_response() throws
            func makeDisconnectMonitor() throws -> any ConnectionDisconnectMonitor
        }

        /// Platform-neutral local byte-stream listener shared by `Daemon.Server`.
        public protocol StreamListener: Sendable {
            func acceptConnection() throws -> (any StreamConnection)?
            func stop()
            func waitForReadiness(wake: any WakeChannel, listen: Bool, timeoutMs: UInt64) throws -> Readiness
        }

        /// Connects to a registered daemon endpoint using the appropriate platform transport:
        /// in-memory (`memory://`), verified Windows named pipe (`connect_to` checking server PID),
        /// or Unix domain socket.
        public static func connect(registration: ProcessDaemon.Registration) throws -> any StreamConnection {
            if registration.socket.hasPrefix("memory://") {
                return try Unix.Connection.connect(registration.socket)
            }
            #if os(Windows)
            return try Windows.Connection.connect_to(registration.socket, serverPid: registration.pid)
            #else
            if WindowsNamedPipeHelpers.hasLocalPipePrefix(registration.socket) {
                return try Windows.Connection.connect_to(registration.socket, serverPid: registration.pid)
            }
            return try Unix.Connection.connect(registration.socket)
            #endif
        }

        // MARK: - Retained Allocation Wrapper (`src/transport/retained.rs`)

        // parity: process-daemon/src/transport/retained.rs#Retained [status=implemented hash=0bc8d24d73b0]
        public final class Retained<T>: @unchecked Sendable {
            private let pointer: UnsafeMutablePointer<T>

            private init(_ pointer: UnsafeMutablePointer<T>) {
                self.pointer = pointer
            }

            deinit {
                pointer.deinitialize(count: 1)
                pointer.deallocate()
            }

            // parity: process-daemon/src/transport/retained.rs#new [status=implemented hash=6fde82f79c8f]
            public static func new(_ value: T) -> Retained<T> {
                let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
                ptr.initialize(to: value)
                return Retained(ptr)
            }

            // parity: process-daemon/src/transport/retained.rs#as_ptr [status=implemented hash=6a98027499c4]
            public func as_ptr() -> UnsafeMutablePointer<T> {
                pointer
            }
        }

        // MARK: - Portable In-Memory Full-Duplex Byte Stream Transport

        /// In-memory half of a full-duplex byte-stream connection supporting blocking reads,
        /// timeouts, half-close, and instant cancellation across every Swift platform including WASI.
        public final class InMemoryConnection: ByteReader, ByteWriter, @unchecked Sendable {
            private final class PipeBuffer: @unchecked Sendable {
                let cond = PortableCondition()
                var bytes: [UInt8] = []
                var writeClosed = false
                var cancelled = false
            }

            private let inbound: PipeBuffer
            private let outbound: PipeBuffer
            private let timeouts = Mutex<(readMs: UInt64?, writeMs: UInt64?)>((nil, nil))

            private init(inbound: PipeBuffer, outbound: PipeBuffer) {
                self.inbound = inbound
                self.outbound = outbound
            }

            public static func pair() -> (InMemoryConnection, InMemoryConnection) {
                let aToB = PipeBuffer()
                let bToA = PipeBuffer()
                return (
                    InMemoryConnection(inbound: bToA, outbound: aToB),
                    InMemoryConnection(inbound: aToB, outbound: bToA)
                )
            }

            public func setReadTimeoutMs(_ ms: UInt64?) {
                timeouts.withLock { $0.readMs = ms }
            }

            public func setWriteTimeoutMs(_ ms: UInt64?) {
                timeouts.withLock { $0.writeMs = ms }
            }

            public func writeAll(_ bytes: [UInt8]) throws {
                if bytes.isEmpty { return }
                try outbound.cond.withLock {
                    if outbound.cancelled {
                        throw DaemonError("connection cancelled")
                    }
                    if outbound.writeClosed {
                        throw DaemonError("broken pipe")
                    }
                    outbound.bytes.append(contentsOf: bytes)
                    outbound.cond.broadcast()
                }
            }

            public func flush() throws {}

            public func readSome(maxCount: Int) throws -> [UInt8] {
                if maxCount <= 0 { return [] }
                let timeoutMs = timeouts.withLock { $0.readMs }
                return try inbound.cond.withLock {
                    let deadline = timeoutMs.map { monotonicNowMs() &+ $0 }
                    while inbound.bytes.isEmpty && !inbound.writeClosed && !inbound.cancelled {
                        if let deadline {
                            let now = monotonicNowMs()
                            if now >= deadline {
                                throw DaemonError("connection read timed out")
                            }
                            _ = inbound.cond.wait(timeoutMs: deadline - now)
                        } else {
                            #if os(WASI)
                            throw DaemonError("unexpected EOF")
                            #else
                            _ = inbound.cond.wait(timeoutMs: 50)
                            #endif
                        }
                    }
                    // Like a real socket or pipe, bytes the peer wrote before it cancelled stay readable;
                    // cancellation is only reported once the buffer is drained.
                    if inbound.bytes.isEmpty {
                        if inbound.cancelled {
                            throw DaemonError("connection cancelled")
                        }
                        return []
                    }
                    let count = min(maxCount, inbound.bytes.count)
                    let out = Array(inbound.bytes[0..<count])
                    inbound.bytes.removeFirst(count)
                    return out
                }
            }

            public func readExact(_ count: Int) throws -> [UInt8] {
                if count == 0 { return [] }
                var result: [UInt8] = []
                result.reserveCapacity(count)
                while result.count < count {
                    let chunk = try readSome(maxCount: count - result.count)
                    if chunk.isEmpty {
                        throw DaemonError("unexpected EOF while reading \(count) byte(s)")
                    }
                    result.append(contentsOf: chunk)
                }
                return result
            }

            public func closeWrite() {
                outbound.cond.withLock {
                    outbound.writeClosed = true
                    outbound.cond.broadcast()
                }
            }

            public func close() {
                outbound.cond.withLock {
                    outbound.writeClosed = true
                    outbound.cond.broadcast()
                }
                inbound.cond.withLock {
                    inbound.writeClosed = true
                    inbound.cond.broadcast()
                }
            }

            public func cancel() {
                inbound.cond.withLock {
                    inbound.cancelled = true
                    inbound.cond.broadcast()
                }
                outbound.cond.withLock {
                    outbound.cancelled = true
                    outbound.cond.broadcast()
                }
            }

            /// Waits until the peer closes or cancels this connection.
            public func waitForDisconnect(timeoutMs: UInt64? = nil) -> Bool {
                inbound.cond.withLock {
                    let deadline = timeoutMs.map { monotonicNowMs() &+ $0 }
                    while !inbound.writeClosed && !inbound.cancelled && inbound.bytes.isEmpty {
                        if let deadline {
                            let now = monotonicNowMs()
                            if now >= deadline { return false }
                            _ = inbound.cond.wait(timeoutMs: deadline - now)
                        } else {
                            #if os(WASI)
                            return false
                            #else
                            _ = inbound.cond.wait(timeoutMs: 25)
                            #endif
                        }
                    }
                    return true
                }
            }

            public var isPeerClosed: Bool {
                inbound.cond.withLock { inbound.writeClosed || inbound.cancelled }
            }
        }

        /// In-memory wake channel used by `InMemoryListener` and `Control`.
        public final class InMemoryWake: @unchecked Sendable {
            internal let cond = PortableCondition()
            internal var notified = false

            public init() {}

            public func notify() {
                cond.withLock {
                    notified = true
                    cond.broadcast()
                }
            }

            public func drain() -> Bool {
                cond.withLock {
                    let was = notified
                    notified = false
                    return was
                }
            }

            public func pending() -> Bool {
                cond.withLock { notified }
            }
        }

        /// In-memory listener registered in `InMemoryHub` for deterministic cross-platform IPC tests.
        public final class InMemoryListener: @unchecked Sendable {
            public let endpoint: String
            public let serverPid: UInt32
            private let cond = PortableCondition()
            private var pending: [InMemoryConnection] = []
            private var stopped = false
            private var released = false
            private weak var wakeWaiter: InMemoryWake?

            fileprivate init(endpoint: String, serverPid: UInt32) {
                self.endpoint = endpoint
                self.serverPid = serverPid
            }

            deinit {
                release()
            }

            fileprivate func enqueue(_ conn: InMemoryConnection) throws {
                let waiter = try cond.withLock { () -> InMemoryWake? in
                    if stopped || released {
                        throw DaemonError("listener at \(endpoint) is not accepting connections")
                    }
                    pending.append(conn)
                    cond.broadcast()
                    return wakeWaiter
                }
                waiter?.notify()
            }

            public func accept() -> InMemoryConnection? {
                cond.withLock {
                    if stopped || pending.isEmpty { return nil }
                    return pending.removeFirst()
                }
            }

            public func stop() {
                cond.withLock {
                    stopped = true
                    pending.forEach { $0.cancel() }
                    pending.removeAll()
                    cond.broadcast()
                }
            }

            public func release() {
                let shouldRemove = cond.withLock { () -> Bool in
                    if released { return false }
                    released = true
                    stopped = true
                    pending.forEach { $0.cancel() }
                    pending.removeAll()
                    cond.broadcast()
                    return true
                }
                if shouldRemove {
                    InMemoryHub.shared.unregister(endpoint: endpoint)
                }
            }

            public func wait(wake: InMemoryWake, listen: Bool, timeoutMs: UInt64) -> (connection: Bool, timedOut: Bool) {
                let deadline = monotonicNowMs() &+ timeoutMs
                while true {
                    let hasConn = cond.withLock { () -> Bool in
                        self.wakeWaiter = wake
                        return listen && !stopped && !pending.isEmpty
                    }
                    if hasConn {
                        return (connection: true, timedOut: false)
                    }
                    if wake.pending() {
                        return (connection: false, timedOut: false)
                    }
                    let now = monotonicNowMs()
                    if now >= deadline {
                        return (connection: false, timedOut: true)
                    }
                    let slice = min(deadline - now, 10)
                    wake.cond.withLock {
                        if !wake.notified {
                            _ = wake.cond.wait(timeoutMs: slice)
                        }
                    }
                }
            }
        }

        /// Process-global registry of in-memory daemon endpoints (works on every platform including WASI).
        public final class InMemoryHub: @unchecked Sendable {
            public static let shared = InMemoryHub()

            private let listeners = Mutex<[String: InMemoryListener]>([:])

            public init() {}

            public func bind(endpoint: String, serverPid: UInt32? = nil) throws -> InMemoryListener {
                let effectivePid = serverPid ?? currentProcessID()
                return try listeners.withLock { map in
                    if map[endpoint] != nil {
                        throw DaemonError("endpoint already bound: \(endpoint)")
                    }
                    let listener = InMemoryListener(endpoint: endpoint, serverPid: effectivePid)
                    map[endpoint] = listener
                    return listener
                }
            }

            public func connect(endpoint: String, expectedServerPid: UInt32? = nil) throws -> InMemoryConnection {
                let listener = try listeners.withLock { map -> InMemoryListener in
                    guard let listener = map[endpoint] else {
                        throw DaemonError("endpoint not found: \(endpoint)")
                    }
                    return listener
                }
                if let expectedServerPid, listener.serverPid != expectedServerPid {
                    throw DaemonError("named pipe server is not the registered opencode-pty daemon")
                }
                let (client, server) = InMemoryConnection.pair()
                try listener.enqueue(server)
                return client
            }

            fileprivate func unregister(endpoint: String) {
                listeners.withLock { _ = $0.removeValue(forKey: endpoint) }
            }
        }

        // MARK: - Unix Domain Socket Transport (`src/transport/unix.rs`)

        public enum Unix {
            // parity: process-daemon/src/transport/unix.rs#Readiness [status=implemented hash=d88bc660bae1]
            public struct Readiness: Equatable, Hashable, Sendable {
                public var connection: Bool
                public var timedOut: Bool

                public init(connection: Bool = false, timedOut: Bool = false) {
                    self.connection = connection
                    self.timedOut = timedOut
                }
            }

            // parity: process-daemon/src/transport/unix.rs#Wake [status=implemented hash=5eebba101a48]
            public final class Wake: WakeChannel, @unchecked Sendable {
                internal let memoryWake = InMemoryWake()
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                internal let readFD: Int32
                internal let writeFD: Int32
                #endif

                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                private init(readFD: Int32, writeFD: Int32) {
                    self.readFD = readFD
                    self.writeFD = writeFD
                }

                deinit {
                    if readFD >= 0 { _ = close(readFD) }
                    if writeFD >= 0 { _ = close(writeFD) }
                }
                #else
                private init() {}
                #endif

                // parity: process-daemon/src/transport/unix.rs#new [status=implemented hash=3d255d1efd98]
                public static func new() throws -> Wake {
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    var fds: [Int32] = [-1, -1]
                    #if canImport(Glibc)
                    let streamType = Int32(SOCK_STREAM.rawValue)
                    #else
                    let streamType = SOCK_STREAM
                    #endif
                    guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else {
                        throw DaemonError("socketpair failed with errno \(errno)")
                    }
                    for fd in fds {
                        let fdFlags = fcntl(fd, F_GETFD, 0)
                        if fdFlags >= 0 { _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) }
                        let flFlags = fcntl(fd, F_GETFL, 0)
                        if flFlags >= 0 { _ = fcntl(fd, F_SETFL, flFlags | O_NONBLOCK) }
                    }
                    return Wake(readFD: fds[0], writeFD: fds[1])
                    #else
                    return Wake()
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#notify [status=implemented hash=672bbd604dc3]
                public func notify() {
                    memoryWake.notify()
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    var byte: UInt8 = 1
                    while true {
                        let n = DarwinOrPosix.writeBytes(writeFD, &byte, 1)
                        if n >= 0 { return }
                        let err = errno
                        if err == EINTR { continue }
                        if err == EAGAIN || err == EWOULDBLOCK { return }
                        return
                    }
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#drain [status=implemented hash=a0e8de2d9f79]
                public func drain() -> Bool {
                    var woken = memoryWake.drain()
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    var buf = [UInt8](repeating: 0, count: 64)
                    while true {
                        let n = buf.withUnsafeMutableBytes { ptr in
                            DarwinOrPosix.readBytes(readFD, ptr.baseAddress!, ptr.count)
                        }
                        if n > 0 {
                            woken = true
                            continue
                        }
                        if n == 0 { break }
                        let err = errno
                        if err == EINTR { continue }
                        break
                    }
                    #endif
                    return woken
                }

                // parity: process-daemon/src/transport/unix.rs#pending [status=implemented hash=2509ba85a1e0]
                public func pending() -> Bool {
                    if memoryWake.pending() { return true }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                    return poll(&pfd, 1, 0) > 0
                    #else
                    return false
                    #endif
                }
            }

            // parity: process-daemon/src/transport/unix.rs#Cancellation [status=implemented hash=9e280a403a28]
            public final class Cancellation: ConnectionCancellation, @unchecked Sendable {
                private let memory: InMemoryConnection?
                private let fd: Int32

                internal init(memory: InMemoryConnection) {
                    self.memory = memory
                    self.fd = -1
                }

                internal init(fd: Int32) {
                    self.memory = nil
                    self.fd = fd
                }

                deinit {
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if fd >= 0 { _ = close(fd) }
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#cancel [status=implemented hash=f101c484630b]
                public func cancel() {
                    if let memory {
                        memory.cancel()
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if fd >= 0 {
                        _ = shutdown(fd, Int32(SHUT_RDWR))
                    }
                    #endif
                }
            }

            // parity: process-daemon/src/transport/unix.rs#DisconnectMonitor [status=implemented hash=5070af6d997a]
            public final class DisconnectMonitor: ConnectionDisconnectMonitor, @unchecked Sendable {
                private let memory: InMemoryConnection?
                private let dupFD: Int32
                private let cond = PortableCondition()
                private var isDisconnected = false
                private var finished = false

                internal init(memory: InMemoryConnection) {
                    self.memory = memory
                    self.dupFD = -1
                    #if !os(WASI)
                    let cond = self.cond
                    Thread.detachNewThread { [weak self] in
                        _ = memory.waitForDisconnect()
                        cond.withLock {
                            self?.isDisconnected = true
                            cond.broadcast()
                        }
                    }
                    #endif
                }

                internal init(dupFD: Int32) {
                    self.memory = nil
                    self.dupFD = dupFD
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let cond = self.cond
                    let monitorFD = dup(dupFD)
                    Thread.detachNewThread { [weak self] in
                        if monitorFD >= 0 {
                            var byte: UInt8 = 0
                            _ = DarwinOrPosix.readBytes(monitorFD, &byte, 1)
                            _ = close(monitorFD)
                        }
                        cond.withLock {
                            self?.isDisconnected = true
                            cond.broadcast()
                        }
                    }
                    #endif
                }

                deinit {
                    finish()
                }

                // parity: process-daemon/src/transport/unix.rs#disconnected [status=implemented hash=374a051ea03e]
                public func disconnected() -> Bool {
                    if let memory, memory.isPeerClosed { return true }
                    return cond.withLock { isDisconnected }
                }

                // parity: process-daemon/src/transport/unix.rs#finish [status=implemented hash=3df6dabb4671]
                public func finish() {
                    let already = cond.withLock { () -> Bool in
                        if finished { return true }
                        finished = true
                        return false
                    }
                    if already { return }
                    if let memory {
                        memory.closeWrite()
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if dupFD >= 0 {
                        _ = shutdown(dupFD, Int32(SHUT_WR))
                        _ = close(dupFD)
                    }
                    #endif
                }
            }

            // parity: process-daemon/src/transport/unix.rs#Connection [status=implemented hash=f2a3741b7759]
            public final class Connection: StreamConnection, @unchecked Sendable {
                internal let memory: InMemoryConnection?
                private let fdLock = Mutex<Int32>(-1)

                internal init(memory: InMemoryConnection) {
                    self.memory = memory
                }

                internal init(fd: Int32) {
                    self.memory = nil
                    self.fdLock.withLock { $0 = fd }
                }

                deinit {
                    closeConnection()
                }

                public func closeConnection() {
                    if let memory {
                        memory.close()
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { current -> Int32 in
                        let old = current
                        current = -1
                        return old
                    }
                    if fd >= 0 {
                        _ = close(fd)
                    }
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#connect [status=implemented hash=19327768ea5e]
                public static func connect(_ endpoint: String) throws -> Connection {
                    if endpoint.hasPrefix("memory://") {
                        return Connection(memory: try InMemoryHub.shared.connect(endpoint: endpoint))
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    #if canImport(Glibc)
                    let streamType = Int32(SOCK_STREAM.rawValue)
                    #else
                    let streamType = SOCK_STREAM
                    #endif
                    let fd = socket(AF_UNIX, streamType, 0)
                    guard fd >= 0 else {
                        throw DaemonError("socket() failed with errno \(errno)")
                    }
                    var addr = try makeUnixSockAddr(path: endpoint)
                    let rc = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            DarwinOrPosix.connectSocket(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    if rc != 0 {
                        let err = errno
                        _ = close(fd)
                        throw DaemonError("connect(\(endpoint)) failed with errno \(err)")
                    }
                    let fdFlags = fcntl(fd, F_GETFD, 0)
                    if fdFlags >= 0 { _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) }
                    return Connection(fd: fd)
                    #else
                    return Connection(memory: try InMemoryHub.shared.connect(endpoint: endpoint))
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#set_read_timeout [status=implemented hash=0fc07decc867]
                public func set_read_timeout(_ timeoutMs: UInt64?) throws {
                    if let memory {
                        memory.setReadTimeoutMs(timeoutMs)
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    try setSocketTimeout(fd: fd, option: SO_RCVTIMEO, timeoutMs: timeoutMs)
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#set_write_timeout [status=implemented hash=361a5e7f4723]
                public func set_write_timeout(_ timeoutMs: UInt64?) throws {
                    if let memory {
                        memory.setWriteTimeoutMs(timeoutMs)
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    try setSocketTimeout(fd: fd, option: SO_SNDTIMEO, timeoutMs: timeoutMs)
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#cancellation [status=implemented hash=4e916dc8e3dc]
                public func cancellation() throws -> Cancellation {
                    if let memory {
                        return Cancellation(memory: memory)
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    let cloned = dup(fd)
                    guard cloned >= 0 else {
                        throw DaemonError("dup() failed with errno \(errno)")
                    }
                    return Cancellation(fd: cloned)
                    #else
                    throw DaemonError("socket is closed")
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#finish_response [status=implemented hash=28fc7228b318]
                public func finish_response() throws {
                    if let memory {
                        memory.closeWrite()
                    }
                }

                // parity: process-daemon/src/transport/unix.rs#monitor_disconnect [status=implemented hash=abdc727dfc24]
                public func monitor_disconnect() throws -> DisconnectMonitor {
                    if let memory {
                        return DisconnectMonitor(memory: memory)
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    let cloned = dup(fd)
                    guard cloned >= 0 else {
                        throw DaemonError("dup() failed with errno \(errno)")
                    }
                    return DisconnectMonitor(dupFD: cloned)
                    #else
                    throw DaemonError("socket is closed")
                    #endif
                }

                public func readExact(_ count: Int) throws -> [UInt8] {
                    if let memory {
                        return try memory.readExact(count)
                    }
                    if count == 0 { return [] }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    var buffer = [UInt8](repeating: 0, count: count)
                    var offset = 0
                    while offset < count {
                        let n = buffer.withUnsafeMutableBytes { ptr in
                            DarwinOrPosix.readBytes(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
                        }
                        if n == 0 {
                            throw DaemonError("unexpected EOF while reading \(count) byte(s)")
                        }
                        if n < 0 {
                            let err = errno
                            if err == EINTR { continue }
                            throw DaemonError("socket read failed with errno \(err)")
                        }
                        offset += n
                    }
                    return buffer
                    #else
                    throw DaemonError("socket is closed")
                    #endif
                }

                public func writeAll(_ bytes: [UInt8]) throws {
                    if let memory {
                        try memory.writeAll(bytes)
                        return
                    }
                    if bytes.isEmpty { return }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    guard fd >= 0 else { throw DaemonError("socket is closed") }
                    var offset = 0
                    while offset < bytes.count {
                        let n = bytes.withUnsafeBytes { ptr in
                            DarwinOrPosix.writeBytes(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
                        }
                        if n < 0 {
                            let err = errno
                            if err == EINTR { continue }
                            throw DaemonError("socket write failed with errno \(err)")
                        }
                        offset += n
                    }
                    #else
                    throw DaemonError("socket is closed")
                    #endif
                }

                public func flush() throws {
                    try memory?.flush()
                }

                public func makeCancellation() throws -> any ConnectionCancellation {
                    try cancellation()
                }

                public func makeDisconnectMonitor() throws -> any ConnectionDisconnectMonitor {
                    try monitor_disconnect()
                }
            }

            // parity: process-daemon/src/transport/unix.rs#Listener [status=implemented hash=b30e176ce446]
            public final class Listener: StreamListener, @unchecked Sendable {
                internal let memoryListener: InMemoryListener?
                private let fdLock = Mutex<Int32>(-1)

                internal init(memoryListener: InMemoryListener) {
                    self.memoryListener = memoryListener
                }

                internal init(fd: Int32) {
                    self.memoryListener = nil
                    self.fdLock.withLock { $0 = fd }
                }

                deinit {
                    stop()
                }

                // parity: process-daemon/src/transport/unix.rs#bind [status=implemented hash=273512b7d168]
                public static func bind(_ endpoint: String) throws -> Listener {
                    if endpoint.hasPrefix("memory://") {
                        return Listener(memoryListener: try InMemoryHub.shared.bind(endpoint: endpoint))
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    #if canImport(Glibc)
                    let streamType = Int32(SOCK_STREAM.rawValue)
                    #else
                    let streamType = SOCK_STREAM
                    #endif
                    let fd = socket(AF_UNIX, streamType, 0)
                    guard fd >= 0 else {
                        throw DaemonError("socket() failed with errno \(errno)")
                    }
                    var addr = try makeUnixSockAddr(path: endpoint)
                    let bindRC = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            DarwinOrPosix.bindSocket(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    if bindRC != 0 {
                        let err = errno
                        _ = close(fd)
                        throw DaemonError("bind(\(endpoint)) failed with errno \(err)")
                    }
                    if listen(fd, 128) != 0 {
                        let err = errno
                        _ = close(fd)
                        throw DaemonError("listen(\(endpoint)) failed with errno \(err)")
                    }
                    let fdFlags = fcntl(fd, F_GETFD, 0)
                    if fdFlags >= 0 { _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) }
                    let flFlags = fcntl(fd, F_GETFL, 0)
                    if flFlags >= 0 { _ = fcntl(fd, F_SETFL, flFlags | O_NONBLOCK) }
                    return Listener(fd: fd)
                    #else
                    return Listener(memoryListener: try InMemoryHub.shared.bind(endpoint: endpoint))
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#accept [status=implemented hash=3a1cba1790af]
                public func accept() throws -> Connection? {
                    if let memoryListener {
                        return memoryListener.accept().map(Connection.init(memory:))
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { $0 }
                    if fd < 0 { return nil }
                    let clientFD = DarwinOrPosix.acceptSocket(fd, nil, nil)
                    if clientFD < 0 {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK { return nil }
                        throw DaemonError("accept() failed with errno \(err)")
                    }
                    // macOS inherits O_NONBLOCK from the listener; clear it on accepted sockets.
                    let flFlags = fcntl(clientFD, F_GETFL, 0)
                    if flFlags >= 0 { _ = fcntl(clientFD, F_SETFL, flFlags & ~O_NONBLOCK) }
                    let fdFlags = fcntl(clientFD, F_GETFD, 0)
                    if fdFlags >= 0 { _ = fcntl(clientFD, F_SETFD, fdFlags | FD_CLOEXEC) }
                    return Connection(fd: clientFD)
                    #else
                    return nil
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#stop [status=implemented hash=71a2579ff89e]
                public func stop() {
                    if let memoryListener {
                        memoryListener.release()
                        return
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let fd = fdLock.withLock { current -> Int32 in
                        let old = current
                        current = -1
                        return old
                    }
                    if fd >= 0 {
                        _ = close(fd)
                    }
                    #endif
                }

                // parity: process-daemon/src/transport/unix.rs#wait [status=implemented hash=f419c0490089]
                public func wait(wake: Wake, listen: Bool, timeoutMs: UInt64) throws -> Readiness {
                    if let memoryListener {
                        let r = memoryListener.wait(wake: wake.memoryWake, listen: listen, timeoutMs: timeoutMs)
                        return Readiness(connection: r.connection, timedOut: r.timedOut)
                    }
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let listenerFD = fdLock.withLock { $0 }
                    var pfds = [pollfd(fd: wake.readFD, events: Int16(POLLIN), revents: 0)]
                    if listen && listenerFD >= 0 {
                        pfds.append(pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0))
                    }
                    let timeoutInt = Int32(min(timeoutMs, UInt64(Int32.max)))
                    let rc = pfds.withUnsafeMutableBufferPointer { buf in
                        poll(buf.baseAddress!, nfds_t(buf.count), timeoutInt)
                    }
                    if rc < 0 {
                        if errno == EINTR { return Readiness() }
                        throw DaemonError("poll() failed with errno \(errno)")
                    }
                    if rc == 0 {
                        return Readiness(connection: false, timedOut: true)
                    }
                    if pfds.contains(where: { ($0.revents & Int16(POLLNVAL)) != 0 }) {
                        throw DaemonError("poll reported a closed descriptor")
                    }
                    if (pfds[0].revents & Int16(POLLERR | POLLHUP)) != 0 {
                        throw DaemonError("wake channel failed")
                    }
                    let hasConn = pfds.count > 1 && (pfds[1].revents & Int16(POLLIN | POLLERR | POLLHUP)) != 0
                    return Readiness(connection: hasConn, timedOut: false)
                    #else
                    return Readiness(connection: false, timedOut: true)
                    #endif
                }

                public func acceptConnection() throws -> (any StreamConnection)? {
                    try accept()
                }

                public func waitForReadiness(
                    wake: any WakeChannel,
                    listen: Bool,
                    timeoutMs: UInt64
                ) throws -> Transport.Readiness {
                    guard let unixWake = wake as? Wake else {
                        throw DaemonError("Unix listener requires a Unix Wake channel")
                    }
                    let ready = try wait(wake: unixWake, listen: listen, timeoutMs: timeoutMs)
                    return Transport.Readiness(connection: ready.connection, timedOut: ready.timedOut)
                }
            }
        }

        // MARK: - Windows Named Pipe Security (`src/transport/windows/security.rs`)

        public enum WindowsSecurity {
            public struct SecurityAttributes: Equatable, Sendable {
                public let ownerSID: String
                public let protectedDACL: Bool
                public let inheritHandle: Bool

                public init(ownerSID: String, protectedDACL: Bool = true, inheritHandle: Bool = false) {
                    self.ownerSID = ownerSID
                    self.protectedDACL = protectedDACL
                    self.inheritHandle = inheritHandle
                }
            }

            // parity: process-daemon/src/transport/windows/security.rs#PrivateSecurity [status=implemented hash=2b382b90737d]
            public final class PrivateSecurity: Sendable {
                public let ownerSID: String
                #if os(Windows)
                internal let native: WindowsPrivateSecurity
                #else
                private let privateHandles = Mutex<Set<UInt64>>([])
                #endif

                #if os(Windows)
                internal init(native: WindowsPrivateSecurity) {
                    self.native = native
                    self.ownerSID = native.ownerSID
                }
                #else
                private init(ownerSID: String) {
                    self.ownerSID = ownerSID
                }
                #endif

                // parity: process-daemon/src/transport/windows/security.rs#new [status=implemented hash=ff1eb2825459]
                public static func new() throws -> PrivateSecurity {
                    #if os(Windows)
                    return PrivateSecurity(native: try WindowsPrivateSecurity.create())
                    #elseif canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    return PrivateSecurity(ownerSID: "S-1-5-21-\(geteuid())")
                    #else
                    return PrivateSecurity(ownerSID: "S-1-5-21-1000")
                    #endif
                }

                // parity: process-daemon/src/transport/windows/security.rs#attributes [status=adapted hash=b1ff5bcb9256]
                public func attributes() -> SecurityAttributes {
                    SecurityAttributes(ownerSID: ownerSID, protectedDACL: true, inheritHandle: false)
                }

                #if os(Windows)
                internal func win32SecurityAttributes(inherit: Bool = false) -> SECURITY_ATTRIBUTES {
                    native.securityAttributes(inherit: inherit)
                }

                internal func makePrivate(handle: HANDLE) throws {
                    try native.makePrivate(handle: handle)
                }

                internal func checkPrivate(handle: HANDLE) throws {
                    try native.checkPrivate(handle: handle)
                }
                #endif

                // parity: process-daemon/src/transport/windows/security.rs#make_private [status=implemented hash=e602734fd892]
                public func make_private(_ handle: UInt64) throws {
                    guard handle != 0 else {
                        throw DaemonError("invalid handle")
                    }
                    #if os(Windows)
                    guard let raw = HANDLE(bitPattern: UInt(truncatingIfNeeded: handle)) else {
                        throw DaemonError("invalid handle")
                    }
                    try native.makePrivate(handle: raw)
                    #else
                    privateHandles.withLock { _ = $0.insert(handle) }
                    #endif
                }

                // parity: process-daemon/src/transport/windows/security.rs#check_private [status=implemented hash=d91efaf4df25]
                public func check_private(_ handle: UInt64) throws {
                    guard handle != 0 else {
                        throw DaemonError("PTY storage is not owned by the current user")
                    }
                    #if os(Windows)
                    guard let raw = HANDLE(bitPattern: UInt(truncatingIfNeeded: handle)) else {
                        throw DaemonError("PTY storage is not owned by the current user")
                    }
                    try native.checkPrivate(handle: raw)
                    #else
                    let isPrivate = privateHandles.withLock { $0.contains(handle) }
                    if !isPrivate {
                        throw DaemonError("unprotected PTY storage DACL")
                    }
                    #endif
                }
            }
        }

        // MARK: - Windows Named Pipe Transport (`src/transport/windows.rs`)

        public enum Windows {
            /// RAII-owned Windows kernel handle (`CloseHandle` on `deinit` under `#if os(Windows)`).
            public final class OwnedHandle: Equatable, Hashable, @unchecked Sendable {
                public let rawValue: UInt64
                #if os(Windows)
                internal let native: OwnedWinHandle?
                #endif

                #if os(Windows)
                internal init(native: OwnedWinHandle) {
                    self.native = native
                    self.rawValue = UInt64(UInt(bitPattern: native.raw))
                }
                #endif

                public init(rawValue: UInt64) {
                    self.rawValue = rawValue
                    #if os(Windows)
                    self.native = nil
                    #endif
                }

                public static func == (lhs: OwnedHandle, rhs: OwnedHandle) -> Bool {
                    lhs.rawValue == rhs.rawValue
                }

                public func hash(into hasher: inout Hasher) {
                    hasher.combine(rawValue)
                }
            }

            // parity: process-daemon/src/transport/windows.rs#Readiness [status=implemented hash=d88bc660bae1]
            public struct Readiness: Equatable, Hashable, Sendable {
                public var connection: Bool
                public var timedOut: Bool

                public init(connection: Bool = false, timedOut: Bool = false) {
                    self.connection = connection
                    self.timedOut = timedOut
                }
            }

            // parity: process-daemon/src/transport/windows.rs#Wake [status=implemented hash=5879aaaaadfc]
            public struct Wake: WakeChannel, Sendable {
                #if !os(Windows)
                internal let inner = InMemoryWake()
                #endif

                public init() {}

                // parity: process-daemon/src/transport/windows.rs#new [status=implemented hash=736aa10cdfeb]
                public static func new() throws -> Wake {
                    Wake()
                }

                // parity: process-daemon/src/transport/windows.rs#notify [status=implemented hash=57abb45609c4]
                public func notify() {
                    #if !os(Windows)
                    inner.notify()
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#drain [status=implemented hash=96717229712d]
                public func drain() -> Bool {
                    #if os(Windows)
                    return false
                    #else
                    return inner.drain()
                    #endif
                }

                public func pending() -> Bool {
                    #if os(Windows)
                    return false
                    #else
                    return inner.pending()
                    #endif
                }
            }

            // parity: process-daemon/src/transport/windows.rs#Cancellation [status=implemented hash=099c8548a8b7]
            public final class Cancellation: ConnectionCancellation, Sendable {
                #if os(Windows)
                private let pipe: WindowsPipe

                internal init(pipe: WindowsPipe) {
                    self.pipe = pipe
                }
                #else
                private let connection: InMemoryConnection

                internal init(_ connection: InMemoryConnection) {
                    self.connection = connection
                }
                #endif

                // parity: process-daemon/src/transport/windows.rs#cancel [status=implemented hash=f52203769d33]
                public func cancel() {
                    #if os(Windows)
                    pipe.cancel()
                    #else
                    connection.cancel()
                    #endif
                }
            }

            // parity: process-daemon/src/transport/windows.rs#DisconnectMonitor [status=implemented hash=08f7320c73db]
            public final class DisconnectMonitor: ConnectionDisconnectMonitor, @unchecked Sendable {
                #if os(Windows)
                private final class MonitorState: @unchecked Sendable {
                    let cond = PortableCondition()
                    var isDisconnected = false
                    var threadExited = false
                    var finished = false
                }

                private let cancellation: Cancellation
                private let state = MonitorState()

                internal init(pipe: WindowsPipe, cancellation: Cancellation) {
                    self.cancellation = cancellation
                    let shared = self.state
                    Thread.detachNewThread {
                        _ = try? Connection.readChunk(pipe: pipe, maxCount: 1, timeoutMs: nil)
                        shared.cond.withLock {
                            shared.isDisconnected = true
                            shared.threadExited = true
                            shared.cond.broadcast()
                        }
                    }
                }

                deinit {
                    finish()
                }
                #else
                private let connection: InMemoryConnection
                private let cancellation: Cancellation

                internal init(connection: InMemoryConnection, cancellation: Cancellation) {
                    self.connection = connection
                    self.cancellation = cancellation
                }
                #endif

                // parity: process-daemon/src/transport/windows.rs#disconnected [status=implemented hash=374a051ea03e]
                public func disconnected() -> Bool {
                    #if os(Windows)
                    return state.cond.withLock { state.isDisconnected }
                    #else
                    return connection.isPeerClosed
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#finish [status=implemented hash=6cabad4407e2]
                public func finish() {
                    #if os(Windows)
                    let already = state.cond.withLock { () -> Bool in
                        if state.finished { return true }
                        state.finished = true
                        return false
                    }
                    if already { return }
                    let deadline = monotonicNowMs() &+ WindowsNamedPipeHelpers.completionTimeoutMs
                    let sawDisconnect = state.cond.withLock { () -> Bool in
                        while !state.isDisconnected {
                            let now = monotonicNowMs()
                            if now >= deadline { return false }
                            _ = state.cond.wait(timeoutMs: deadline - now)
                        }
                        return true
                    }
                    if !sawDisconnect {
                        cancellation.cancel()
                    }
                    state.cond.withLock {
                        while !state.threadExited {
                            _ = state.cond.wait(timeoutMs: 25)
                        }
                    }
                    #else
                    if !connection.waitForDisconnect(timeoutMs: WindowsNamedPipeHelpers.completionTimeoutMs) {
                        cancellation.cancel()
                    }
                    #endif
                }
            }

            // parity: process-daemon/src/transport/windows.rs#Connection [status=implemented hash=84dbd09c584c]
            public final class Connection: StreamConnection, @unchecked Sendable {
                #if os(Windows)
                private let pipeState: Mutex<WindowsPipe?>
                private let timeouts = Mutex<(readMs: UInt64?, writeMs: UInt64?)>((nil, nil))

                internal init(pipe: WindowsPipe) {
                    self.pipeState = Mutex(pipe)
                }

                deinit {
                    closeConnection()
                }

                private func requirePipe() throws -> WindowsPipe {
                    guard let pipe = pipeState.withLock({ $0 }) else {
                        throw DaemonError("named pipe connection is closed")
                    }
                    return pipe
                }

                internal static func readChunk(
                    pipe: WindowsPipe,
                    maxCount: Int,
                    timeoutMs: UInt64?
                ) throws -> [UInt8] {
                    let bounded = WindowsNamedPipeHelpers.chunkSize(remaining: maxCount)
                    if bounded == 0 { return [] }
                    var buffer = [UInt8](repeating: 0, count: bounded)
                    do {
                        let transferred: Int = try buffer.withUnsafeMutableBytes { rawBuf in
                            guard let base = rawBuf.baseAddress else { return 0 }
                            let operation = try WindowsPipeOperation(pipe: pipe)
                            defer { operation.reapIfPending() }
                            let ready = try operation.begin { handle, overlapped in
                                ReadFile(handle, base, DWORD(bounded), nil, overlapped)
                            }
                            let count: UInt32
                            if let ready {
                                count = ready
                            } else {
                                count = try operation.wait(timeoutMs: timeoutMs)
                            }
                            return Int(count)
                        }
                        if transferred == 0 { return [] }
                        if transferred == buffer.count { return buffer }
                        return Array(buffer[0..<transferred])
                    } catch let failure as WindowsOSFailure where WindowsNamedPipeHelpers.isPipeEofError(failure.code) {
                        return []
                    }
                }

                private static func writeChunk(
                    pipe: WindowsPipe,
                    bytes: [UInt8],
                    offset: Int,
                    count: Int,
                    timeoutMs: UInt64?
                ) throws -> Int {
                    let bounded = WindowsNamedPipeHelpers.chunkSize(remaining: count)
                    if bounded == 0 { return 0 }
                    return try bytes.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return 0 }
                        let operation = try WindowsPipeOperation(pipe: pipe)
                        defer { operation.reapIfPending() }
                        let ready = try operation.begin { handle, overlapped in
                            WriteFile(handle, base.advanced(by: offset), DWORD(bounded), nil, overlapped)
                        }
                        let written: UInt32
                        if let ready {
                            written = ready
                        } else {
                            written = try operation.wait(timeoutMs: timeoutMs)
                        }
                        return Int(written)
                    }
                }
                #else
                internal let inner: InMemoryConnection

                internal init(inner: InMemoryConnection) {
                    self.inner = inner
                }
                #endif

                public func closeConnection() {
                    #if os(Windows)
                    pipeState.withLock { $0 = nil }
                    #else
                    inner.close()
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#connect [status=implemented hash=39b1366ece1a]
                public static func connect(_ endpoint: String) throws -> Connection {
                    let wideEndpoint = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(endpoint)
                    #if os(Windows)
                    let handle: OwnedWinHandle = try WindowsNamedPipeHelpers.connectWithBusyRetry(
                        timeoutMs: WindowsNamedPipeHelpers.connectTimeoutMs,
                        waitStepMs: WindowsNamedPipeHelpers.waitNamedPipeStepMs,
                        nowMs: { monotonicNowMs() },
                        attemptOpen: {
                            let raw: HANDLE? = wideEndpoint.withUnsafeBufferPointer { ptr in
                                CreateFileW(
                                    ptr.baseAddress,
                                    DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                                    0,
                                    nil,
                                    DWORD(OPEN_EXISTING),
                                    DWORD(WindowsNamedPipeHelpers.clientFlagsAndAttributes()),
                                    nil
                                )
                            }
                            if let raw, raw != INVALID_HANDLE_VALUE {
                                return .connected(OwnedWinHandle(raw))
                            }
                            let err = GetLastError()
                            if WindowsNamedPipeHelpers.isPipeBusyError(UInt32(err)) {
                                return .busy
                            }
                            return .failed(WindowsOSFailure("CreateFileW(\(endpoint))", code: err))
                        },
                        waitPipe: { stepMs in
                            wideEndpoint.withUnsafeBufferPointer { ptr in
                                _ = WaitNamedPipeW(ptr.baseAddress, DWORD(stepMs))
                            }
                        }
                    )
                    return Connection(pipe: try WindowsPipe(handle: handle))
                    #else
                    _ = wideEndpoint
                    let conn = try InMemoryHub.shared.connect(endpoint: endpoint)
                    return Connection(inner: conn)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#connect_to [status=implemented hash=4cc557475acc]
                public static func connect_to(_ endpoint: String, serverPid: UInt32) throws -> Connection {
                    #if os(Windows)
                    let conn = try connect(endpoint)
                    let pipe = try conn.requirePipe()
                    var pid: ULONG = 0
                    guard GetNamedPipeServerProcessId(pipe.handle.raw, &pid) else {
                        let err = WindowsOSFailure("GetNamedPipeServerProcessId")
                        conn.closeConnection()
                        throw err
                    }
                    do {
                        try WindowsNamedPipeHelpers.verifyServerPid(actual: UInt32(pid), expected: serverPid)
                    } catch {
                        conn.closeConnection()
                        throw error
                    }
                    return conn
                    #else
                    _ = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(endpoint)
                    let conn = try InMemoryHub.shared.connect(endpoint: endpoint, expectedServerPid: serverPid)
                    return Connection(inner: conn)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#set_read_timeout [status=implemented hash=27a95d2e9f7e]
                public func set_read_timeout(_ timeoutMs: UInt64?) {
                    #if os(Windows)
                    timeouts.withLock { $0.readMs = timeoutMs }
                    #else
                    inner.setReadTimeoutMs(timeoutMs)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#set_write_timeout [status=implemented hash=bd2eb22aab7b]
                public func set_write_timeout(_ timeoutMs: UInt64?) {
                    #if os(Windows)
                    timeouts.withLock { $0.writeMs = timeoutMs }
                    #else
                    inner.setWriteTimeoutMs(timeoutMs)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#cancellation [status=implemented hash=cd2d7022052a]
                public func cancellation() throws -> Cancellation {
                    #if os(Windows)
                    return Cancellation(pipe: try requirePipe())
                    #else
                    return Cancellation(inner)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#finish_response [status=implemented hash=8d05440b3b4e]
                public func finish_response() throws {
                    #if os(Windows)
                    let pipe = try requirePipe()
                    let chunk: [UInt8]
                    do {
                        chunk = try Self.readChunk(
                            pipe: pipe,
                            maxCount: 1,
                            timeoutMs: WindowsNamedPipeHelpers.completionTimeoutMs
                        )
                    } catch {
                        pipe.cancel()
                        throw error
                    }
                    if !chunk.isEmpty {
                        throw DaemonError("unexpected data after request")
                    }
                    #else
                    inner.closeWrite()
                    if !inner.waitForDisconnect(timeoutMs: WindowsNamedPipeHelpers.completionTimeoutMs) {
                        inner.cancel()
                        throw DaemonError("named pipe response completion timed out")
                    }
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#monitor_disconnect [status=implemented hash=803aef4aac99]
                public func monitor_disconnect() throws -> DisconnectMonitor {
                    #if os(Windows)
                    let pipe = try requirePipe()
                    return DisconnectMonitor(pipe: pipe, cancellation: Cancellation(pipe: pipe))
                    #else
                    return DisconnectMonitor(connection: inner, cancellation: try cancellation())
                    #endif
                }

                public func readSome(maxCount: Int) throws -> [UInt8] {
                    #if os(Windows)
                    let pipe = try requirePipe()
                    let timeout = timeouts.withLock { $0.readMs }
                    return try Self.readChunk(pipe: pipe, maxCount: maxCount, timeoutMs: timeout)
                    #else
                    return try inner.readSome(maxCount: maxCount)
                    #endif
                }

                public func readExact(_ count: Int) throws -> [UInt8] {
                    #if os(Windows)
                    let pipe = try requirePipe()
                    let timeout = timeouts.withLock { $0.readMs }
                    return try WindowsNamedPipeHelpers.readExactLoop(count: count) { step in
                        try Self.readChunk(pipe: pipe, maxCount: step, timeoutMs: timeout)
                    }
                    #else
                    return try inner.readExact(count)
                    #endif
                }

                public func writeAll(_ bytes: [UInt8]) throws {
                    #if os(Windows)
                    let pipe = try requirePipe()
                    let timeout = timeouts.withLock { $0.writeMs }
                    try WindowsNamedPipeHelpers.writeAllLoop(bytes: bytes) { offset, step in
                        try Self.writeChunk(
                            pipe: pipe,
                            bytes: bytes,
                            offset: offset,
                            count: step,
                            timeoutMs: timeout
                        )
                    }
                    #else
                    try inner.writeAll(bytes)
                    #endif
                }

                public func flush() throws {
                    #if !os(Windows)
                    try inner.flush()
                    #endif
                }

                public func makeCancellation() throws -> any ConnectionCancellation {
                    try cancellation()
                }

                public func makeDisconnectMonitor() throws -> any ConnectionDisconnectMonitor {
                    try monitor_disconnect()
                }
            }

            // parity: process-daemon/src/transport/windows.rs#Listener [status=implemented hash=1ca0b9a93a30]
            public final class Listener: StreamListener, @unchecked Sendable {
                public let endpoint: String
                private let security: WindowsSecurity.PrivateSecurity
                #if os(Windows)
                private struct State: Sendable {
                    var pending: WindowsPendingConnection
                    var stopped: Bool
                }
                private let endpointWide: [UInt16]
                private let state: Mutex<State>

                private init(
                    endpoint: String,
                    endpointWide: [UInt16],
                    security: WindowsSecurity.PrivateSecurity,
                    pending: WindowsPendingConnection
                ) {
                    self.endpoint = endpoint
                    self.endpointWide = endpointWide
                    self.security = security
                    self.state = Mutex(State(pending: pending, stopped: false))
                }
                #else
                private let inner: InMemoryListener

                private init(endpoint: String, security: WindowsSecurity.PrivateSecurity, inner: InMemoryListener) {
                    self.endpoint = endpoint
                    self.security = security
                    self.inner = inner
                }

                deinit {
                    inner.release()
                }
                #endif

                // parity: process-daemon/src/transport/windows.rs#bind [status=implemented hash=801308c5b63d]
                public static func bind(_ endpoint: String) throws -> Listener {
                    let wideEndpoint = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(endpoint)
                    let security = try WindowsSecurity.PrivateSecurity.new()
                    #if os(Windows)
                    // Fail closed if anyone already owns this name (FILE_FLAG_FIRST_PIPE_INSTANCE).
                    let pending = try WindowsPendingConnection(
                        endpointWide: wideEndpoint,
                        security: security.native,
                        first: true
                    )
                    return Listener(
                        endpoint: endpoint,
                        endpointWide: wideEndpoint,
                        security: security,
                        pending: pending
                    )
                    #else
                    _ = wideEndpoint
                    let inner = try InMemoryHub.shared.bind(endpoint: endpoint)
                    return Listener(endpoint: endpoint, security: security, inner: inner)
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#accept [status=implemented hash=1ce9d74527ac]
                public func accept() throws -> Connection? {
                    #if os(Windows)
                    return try state.withLock { s -> Connection? in
                        if s.stopped || !(try s.pending.ready()) {
                            return nil
                        }
                        // Create the next instance BEFORE handing off the connected one so the
                        // registered pipe name stays continuously owned even between short requests.
                        let next = try WindowsPendingConnection(
                            endpointWide: endpointWide,
                            security: security.native,
                            first: false
                        )
                        let previous = s.pending
                        s.pending = next
                        return Connection(pipe: previous.operation.pipe)
                    }
                    #else
                    return inner.accept().map(Connection.init(inner:))
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#stop [status=implemented hash=c443d236cf59]
                public func stop() {
                    #if os(Windows)
                    // Stop accepting without releasing the pipe namespace; Listener stays alive
                    // until registration removal finishes in Daemon.Server.serve.
                    state.withLock { s in
                        s.stopped = true
                        s.pending.cancel()
                    }
                    #else
                    inner.stop()
                    #endif
                }

                // parity: process-daemon/src/transport/windows.rs#wait [status=implemented hash=45d7c5a51d4d]
                public func wait(wake: Wake, listen: Bool, timeoutMs: UInt64) throws -> Readiness {
                    let pollMs = WindowsNamedPipeHelpers.listenerPollSleepMs(timeoutMs)
                    #if os(Windows)
                    _ = wake
                    if pollMs > 0 {
                        Sleep(DWORD(pollMs))
                    }
                    // `timedOut` stays false on Windows so the Unix missed-wake detector stays off.
                    return Readiness(connection: listen, timedOut: false)
                    #else
                    let r = inner.wait(wake: wake.inner, listen: listen, timeoutMs: pollMs)
                    return Readiness(connection: r.connection || listen, timedOut: false)
                    #endif
                }

                public func acceptConnection() throws -> (any StreamConnection)? {
                    try accept()
                }

                public func waitForReadiness(
                    wake: any WakeChannel,
                    listen: Bool,
                    timeoutMs: UInt64
                ) throws -> Transport.Readiness {
                    let winWake = (wake as? Wake) ?? Wake()
                    let ready = try wait(wake: winWake, listen: listen, timeoutMs: timeoutMs)
                    return Transport.Readiness(connection: ready.connection, timedOut: ready.timedOut)
                }
            }

            #if !os(Windows)
            private static let nextSyntheticHandle = Mutex<UInt64>(1)
            #endif

            // parity: process-daemon/src/transport/windows.rs#event [status=implemented hash=d643fd9625c9]
            public static func event() throws -> OwnedHandle {
                #if os(Windows)
                let ev = try OwnedWinHandle.makeManualResetEvent()
                return OwnedHandle(native: ev)
                #else
                let id = nextSyntheticHandle.withLock { n -> UInt64 in
                    let cur = n
                    n &+= 1
                    return cur
                }
                return OwnedHandle(rawValue: id)
                #endif
            }

            /// Returns a NUL-terminated UTF-16 copy of `value`, refusing embedded NULs.
            // parity: process-daemon/src/transport/windows.rs#wide [status=implemented hash=9c78dd4ea68b]
            public static func wide(_ value: String) throws -> [UInt16] {
                try WindowsNamedPipeHelpers.encodeWide(value)
            }

            // parity: process-daemon/src/transport/windows.rs#owned_handle [status=implemented hash=6a7e3e050344]
            public static func owned_handle(_ rawHandle: UInt64) throws -> OwnedHandle {
                guard rawHandle != 0 && rawHandle != UInt64.max else {
                    throw DaemonError("invalid Windows handle")
                }
                #if os(Windows)
                let ptr = HANDLE(bitPattern: UInt(truncatingIfNeeded: rawHandle))
                let owned = try OwnedWinHandle.adopt(ptr, operation: "owned_handle")
                return OwnedHandle(native: owned)
                #else
                return OwnedHandle(rawValue: rawHandle)
                #endif
            }

            internal static func validateNamedPipeEndpoint(_ endpoint: String) throws -> String {
                _ = try WindowsNamedPipeHelpers.validateAndEncodeEndpoint(endpoint)
                return endpoint
            }
        }
    }

    // MARK: - Daemon Registration, Control, Sweep & Runtime (`src/daemon.rs`, `src/daemon/*`)

    // parity: process-daemon/src/daemon.rs#REGISTRATION_FILE [status=implemented hash=c6de11b7035e]
    public static let REGISTRATION_FILE = "service.json"

    // parity: process-daemon/src/daemon.rs#LOCK_FILE [status=implemented hash=6bd71d0188a0]
    public static let LOCK_FILE = "service.lock"

    // parity: process-daemon/src/daemon.rs#Registration [status=implemented hash=b2f6487593fe]
    public struct Registration: Equatable, Hashable, Sendable, Codable {
        public let instanceId: String
        public let pid: UInt32
        public let protocolVersion: UInt32
        public let socket: String
        public let token: String
        public let features: [String]

        private enum CodingKeys: String, CodingKey {
            case instanceId = "instance_id"
            case pid
            case protocolVersion = "protocol"
            case socket
            case token
            case features
        }

        public init(
            instanceId: String,
            pid: UInt32,
            protocolVersion: UInt32 = ProcessDaemon.PROTOCOL_VERSION,
            socket: String,
            token: String,
            features: [String] = ProcessDaemon.features()
        ) {
            self.instanceId = instanceId
            self.pid = pid
            self.protocolVersion = protocolVersion
            self.socket = socket
            self.token = token
            self.features = features
        }
    }

    public enum Daemon {
        // parity: process-daemon/src/daemon.rs#default_runtime_root [status=implemented hash=a04bc1c544c7]
        public static func default_runtime_root(
            environment: any EnvironmentProviding = SystemEnvironment()
        ) -> String {
            if let state = environment.variable("XDG_STATE_HOME"), isAbsolutePath(state) {
                return joinPath(state, "opencode", "pty")
            }
            if let home = environment.homeDirectory {
                return joinPath(home, ".local", "state", "opencode", "pty")
            }
            return joinPath(environment.temporaryDirectory, "opencode", "pty")
        }

        // parity: process-daemon/src/daemon.rs#runtime_dir [status=implemented hash=af3c529ee11c]
        public static func runtime_dir(
            root: String? = nil,
            name: String,
            environment: any EnvironmentProviding = SystemEnvironment()
        ) throws -> String {
            let valid = !name.isEmpty
                && name != "."
                && name != ".."
                && name.utf8.allSatisfy { byte in
                    (byte >= 0x30 && byte <= 0x39)
                        || (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A)
                        || byte == UInt8(ascii: ".")
                        || byte == UInt8(ascii: "_")
                        || byte == UInt8(ascii: "-")
                }
            if !valid {
                throw DaemonError("invalid runtime name \"\(name)\"; use letters, digits, '.', '_', or '-'")
            }
            let base = root ?? default_runtime_root(environment: environment)
            return joinPath(base, name)
        }

        // parity: process-daemon/src/daemon.rs#registration_path [status=implemented hash=792b3a9db28b]
        public static func registration_path(_ directory: String) -> String {
            #if os(Windows)
            return WindowsNamedPipeHelpers.joinWindowsPath(directory, ProcessDaemon.REGISTRATION_FILE)
            #else
            return joinPath(directory, ProcessDaemon.REGISTRATION_FILE)
            #endif
        }

        // parity: process-daemon/src/daemon.rs#read_registration [status=implemented hash=82cea8a4bcdf]
        public static func read_registration(_ directory: String) throws -> Registration {
            #if os(Windows)
            return try WindowsRuntime.read_registration(directory)
            #elseif os(WASI)
            throw DaemonError("opencode-pty registration is unavailable on WASI")
            #else
            let path = registration_path(directory)
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw DaemonError("opencode-pty registration is unavailable: \(error)")
            }
            do {
                return try JSONDecoder().decode(Registration.self, from: data)
            } catch {
                throw DaemonError("invalid opencode-pty registration: \(error)")
            }
            #endif
        }

        // parity: process-daemon/src/daemon.rs#run [status=implemented hash=4500b50129ed]
        public static func run(_ directory: String) throws {
            try Server.run(directory)
        }

        /// Platform-neutral handle to a bound daemon runtime (`UnixRuntime.Runtime` or `WindowsRuntime.Runtime`).
        public protocol RuntimeHandle: Sendable {
            var registration: Registration { get }
            func finish() throws
        }

        // MARK: - Daemon Control (`src/daemon/control.rs`)

        // parity: process-daemon/src/daemon/control.rs#Stats [status=implemented hash=7d26bc0cd529]
        public final class Stats: Sendable {
            private let state = Mutex<(iterations: UInt64, missedWakes: UInt64)>((0, 0))

            public init() {}

            public var iterations: UInt64 {
                state.withLock { $0.iterations }
            }

            public var missedWakes: UInt64 {
                state.withLock { $0.missedWakes }
            }

            public func incrementIterations() {
                state.withLock { $0.iterations &+= 1 }
            }

            public func incrementMissedWakes() {
                state.withLock { $0.missedWakes &+= 1 }
            }
        }

        // parity: process-daemon/src/daemon/control.rs#Tick [status=implemented hash=023bca84adf1]
        public struct Tick: Equatable, Hashable, Sendable {
            public let stopped: Bool
            public let deadlineMs: UInt64?

            public init(stopped: Bool, deadlineMs: UInt64?) {
                self.stopped = stopped
                self.deadlineMs = deadlineMs
            }
        }

        // parity: process-daemon/src/daemon/control.rs#Control [status=implemented hash=695f70e4f1c9]
        public final class Control: Sendable {
            private struct State: Sendable {
                var stop: Bool = false
                var ownership: Ownership
            }

            private let state: Mutex<State>
            private let wakeChannel: any Transport.WakeChannel
            public let stats = Stats()

            private init(wake: any Transport.WakeChannel, ownership: Ownership) {
                self.state = Mutex(State(ownership: ownership))
                self.wakeChannel = wake
            }

            // parity: process-daemon/src/daemon/control.rs#new [status=implemented hash=0dda8aa1628b]
            public static func new(wake: any Transport.WakeChannel, ownership: Ownership) -> Control {
                Control(wake: wake, ownership: ownership)
            }

            // parity: process-daemon/src/daemon/control.rs#request_stop [status=implemented hash=cb7f621b5f0f]
            public func request_stop() {
                state.withLock { s in
                    s.stop = true
                    wakeChannel.notify()
                }
            }

            // parity: process-daemon/src/daemon/control.rs#stopping [status=implemented hash=93944e313102]
            public func stopping() -> Bool {
                state.withLock { $0.stop }
            }

            // parity: process-daemon/src/daemon/control.rs#update_ownership [status=implemented hash=95a0ee7aab6c]
            public func update_ownership<T>(_ body: (inout Ownership) throws -> T) throws -> T {
                try state.withLock { s in
                    let value = try body(&s.ownership)
                    wakeChannel.notify()
                    return value
                }
            }

            // parity: process-daemon/src/daemon/control.rs#is_owner [status=implemented hash=d7f6ac22f856]
            public func is_owner(_ generation: UInt64) -> Bool {
                state.withLock { $0.ownership.is_owner(generation) }
            }

            // parity: process-daemon/src/daemon/control.rs#notify [status=implemented hash=d5b83a29f235]
            public func notify() {
                wakeChannel.notify()
            }

            // parity: process-daemon/src/daemon/control.rs#wake [status=implemented hash=65daed4d3a19]
            public func wake() -> any Transport.WakeChannel {
                wakeChannel
            }

            // parity: process-daemon/src/daemon/control.rs#tick [status=implemented hash=aca9961ce523]
            public func tick(
                nowMs: UInt64,
                last: inout OwnershipSnapshot,
                timedOut: Bool,
                failOnMissedWake: Bool = false
            ) throws -> Tick {
                let (stopped, deadline, missed) = state.withLock { s -> (Bool, UInt64?, Bool) in
                    let woken = wakeChannel.drain()
                    let observed = s.ownership.snapshot()
                    let missed = timedOut && !woken && (s.stop || observed != last)
                    if missed {
                        stats.incrementMissedWakes()
                    }
                    let stopped = s.stop || s.ownership.tick(nowMs: nowMs)
                    last = s.ownership.snapshot()
                    return (stopped, s.ownership.deadline(), missed)
                }
                if missed && failOnMissedWake {
                    throw DaemonError("missed wake detected")
                }
                return Tick(stopped: stopped, deadlineMs: deadline)
            }

            // parity: process-daemon/src/daemon/control.rs#set_stop_without_wake [status=implemented hash=0a2453a2c6e0]
            public func set_stop_without_wake() -> Bool {
                state.withLock { s in
                    if wakeChannel.pending() { return false }
                    s.stop = true
                    return true
                }
            }

            // parity: process-daemon/src/daemon/control.rs#update_ownership_without_wake [status=implemented hash=a85048a73a5d]
            public func update_ownership_without_wake(_ body: (inout Ownership) -> Void) -> Bool {
                state.withLock { s in
                    if wakeChannel.pending() { return false }
                    body(&s.ownership)
                    return true
                }
            }
        }

        // MARK: - Stale Runtime Sweeper (`src/daemon/sweep.rs`)

        public enum Sweep {
            // parity: process-daemon/src/daemon/sweep.rs#STALE_RUNTIME_AGE [status=implemented hash=00a5b023abda]
            public static let STALE_RUNTIME_AGE: UInt64 = 10 * 60 * 1_000

            // parity: process-daemon/src/daemon/sweep.rs#stale_runtimes [status=implemented hash=de9e93b74f7b]
            public static func stale_runtimes(_ directory: String) {
                #if !os(WASI)
                let dirURL = URL(fileURLWithPath: directory).standardizedFileURL
                let parentURL = dirURL.deletingLastPathComponent()
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parentURL.path) else {
                    return
                }
                let nowMs = currentUnixMs()
                for entry in entries {
                    let candidate = parentURL.appendingPathComponent(entry).standardizedFileURL.path
                    if candidate == dirURL.path { continue }
                    try? runtime(candidate, nowMs: nowMs)
                }
                #endif
            }

            // parity: process-daemon/src/daemon/sweep.rs#runtime [status=implemented hash=878601ba94a5]
            public static func runtime(_ directory: String, nowMs: UInt64? = nil) throws {
                let effectiveNowMs = nowMs ?? currentUnixMs()
                #if !os(WASI)
                let fm = FileManager.default
                #if os(Windows)
                // Symlinks and Windows junctions are never followed or removed.
                if WindowsRuntimePrimitives.isReparsePoint(path: directory) {
                    return
                }
                #endif
                let attrs = try fm.attributesOfItem(atPath: directory)
                let fileType = attrs[.type] as? FileAttributeType
                guard fileType == .typeDirectory else { return }
                if let modDate = attrs[.modificationDate] as? Date {
                    let modMs = UInt64(max(0, Int64((modDate.timeIntervalSince1970 * 1_000.0).rounded())))
                    if effectiveNowMs < modMs || (effectiveNowMs - modMs) < STALE_RUNTIME_AGE {
                        return
                    }
                }
                let names = try fm.contentsOfDirectory(atPath: directory)
                var files: [String] = []
                for name in names {
                    let known = name == ProcessDaemon.LOCK_FILE
                        || name == ProcessDaemon.REGISTRATION_FILE
                        || (name.hasPrefix("service.") && name.hasSuffix(".tmp"))
                    if !known { return }
                    #if os(Windows)
                    let childPath = WindowsNamedPipeHelpers.joinWindowsPath(directory, name)
                    if WindowsRuntimePrimitives.isReparsePoint(path: childPath) { return }
                    #else
                    let childPath = joinPath(directory, name)
                    #endif
                    let childAttrs = try fm.attributesOfItem(atPath: childPath)
                    if (childAttrs[.type] as? FileAttributeType) != .typeRegular {
                        return
                    }
                    files.append(childPath)
                }

                #if os(Windows)
                let lockPath = WindowsNamedPipeHelpers.joinWindowsPath(directory, ProcessDaemon.LOCK_FILE)
                var sweepLockHandle: OwnedWinHandle? = nil
                switch WindowsRuntimePrimitives.tryAcquireSweepLock(lockPath: lockPath) {
                case .acquired(let handle):
                    sweepLockHandle = handle
                case .missing:
                    sweepLockHandle = nil
                case .lockedByLiveDaemon:
                    return
                }
                let hasLock = sweepLockHandle != nil
                #else
                let lockPath = joinPath(directory, ProcessDaemon.LOCK_FILE)
                let hasLock = fm.fileExists(atPath: lockPath)
                #endif
                let registration = try? Daemon.read_registration(directory)
                if !hasLock {
                    #if os(Windows)
                    guard let registration, !WindowsRuntime.process_exists(registration.pid) else {
                        return
                    }
                    #else
                    guard let registration, !UnixRuntime.process_exists(registration.pid) else {
                        return
                    }
                    #endif
                }
                #if os(Windows)
                try WindowsRuntime.remove_stale_endpoint(
                    canonicalDirectory: URL(fileURLWithPath: directory).resolvingSymlinksInPath().path,
                    registration: registration
                )
                #else
                try UnixRuntime.remove_stale_endpoint(
                    canonicalDirectory: URL(fileURLWithPath: directory).resolvingSymlinksInPath().path,
                    registration: registration
                )
                #endif
                files.sort { lhs, rhs in
                    let lIsLock = lhs.hasSuffix(ProcessDaemon.LOCK_FILE)
                    let rIsLock = rhs.hasSuffix(ProcessDaemon.LOCK_FILE)
                    return !lIsLock && rIsLock
                }
                for file in files {
                    #if os(Windows)
                    try withExtendedLifetime(sweepLockHandle) {
                        try fm.removeItem(atPath: file)
                    }
                    #else
                    try fm.removeItem(atPath: file)
                    #endif
                }
                #if os(Windows)
                // Windows deletes an open lock file only after its last handle closes.
                sweepLockHandle = nil
                #endif
                try fm.removeItem(atPath: directory)
                #endif
            }
        }

        // MARK: - Unix Daemon Runtime (`src/daemon/unix.rs`)

        public enum UnixRuntime {
            // parity: process-daemon/src/daemon/unix.rs#Cleanup [status=implemented hash=2ae18448fb38]
            public struct Cleanup: Sendable {
                public let directory: String
                public let registration: Registration
                public let socketPath: String

                public init(directory: String, registration: Registration, socketPath: String) {
                    self.directory = directory
                    self.registration = registration
                    self.socketPath = socketPath
                }

                // parity: process-daemon/src/daemon/unix.rs#run [status=implemented hash=d7ceec0cc9c7]
                public func run() throws {
                    #if !os(WASI)
                    let fm = FileManager.default
                    if let current = try? Daemon.read_registration(directory),
                       current.instanceId == registration.instanceId {
                        try? fm.removeItem(atPath: Daemon.registration_path(directory))
                    }
                    if !socketPath.hasPrefix("memory://") && fm.fileExists(atPath: socketPath) {
                        try? fm.removeItem(atPath: socketPath)
                    }
                    try? fm.removeItem(atPath: joinPath(directory, ProcessDaemon.LOCK_FILE))
                    try? fm.removeItem(atPath: directory)
                    #endif
                }
            }

            // parity: process-daemon/src/daemon/unix.rs#Runtime [status=implemented hash=c3d3d2a97989]
            public final class Runtime: RuntimeHandle, @unchecked Sendable {
                public let registration: Registration
                public let cleanup: Cleanup
                private let lockFD: Int32

                private init(registration: Registration, cleanup: Cleanup, lockFD: Int32) {
                    self.registration = registration
                    self.cleanup = cleanup
                    self.lockFD = lockFD
                }

                // parity: process-daemon/src/daemon/unix.rs#bind [status=implemented hash=040ea424da4f]
                public static func bind(
                    _ directory: String,
                    useInMemoryEndpoint: Bool = false
                ) throws -> (Runtime, Transport.Unix.Listener) {
                    let instanceId = ProcessDaemon.randomHex32()
                    let token = ProcessDaemon.randomHex32()

                    if useInMemoryEndpoint || directory.hasPrefix("memory://") {
                        let endpoint = "memory://opencode-pty-\(instanceId)"
                        let listener = try Transport.Unix.Listener.bind(endpoint)
                        let reg = Registration(
                            instanceId: instanceId,
                            pid: currentProcessID(),
                            protocolVersion: ProcessDaemon.PROTOCOL_VERSION,
                            socket: endpoint,
                            token: token,
                            features: ProcessDaemon.features()
                        )
                        let cleanup = Cleanup(directory: directory, registration: reg, socketPath: endpoint)
                        return (Runtime(registration: reg, cleanup: cleanup, lockFD: -1), listener)
                    }

                    #if !os(WASI)
                    let fm = FileManager.default
                    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

                    var lockFD: Int32 = -1
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    let lockPath = joinPath(directory, ProcessDaemon.LOCK_FILE)
                    lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
                    guard lockFD >= 0 else {
                        throw DaemonError("failed to open service lock \(lockPath)")
                    }
                    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                        _ = close(lockFD)
                        throw DaemonError("another opencode-pty process already owns the service lock")
                    }
                    #endif

                    let canonicalDir = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
                    let socketPath = try resolveSocketPath(canonicalDirectory: canonicalDir)
                    if fm.fileExists(atPath: socketPath) {
                        try? fm.removeItem(atPath: socketPath)
                    }
                    let listener = try Transport.Unix.Listener.bind(socketPath)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)

                    let reg = Registration(
                        instanceId: instanceId,
                        pid: currentProcessID(),
                        protocolVersion: ProcessDaemon.PROTOCOL_VERSION,
                        socket: socketPath,
                        token: token,
                        features: ProcessDaemon.features()
                    )
                    try writeRegistrationAtomically(directory: directory, registration: reg)
                    let cleanup = Cleanup(directory: directory, registration: reg, socketPath: socketPath)
                    return (Runtime(registration: reg, cleanup: cleanup, lockFD: lockFD), listener)
                    #else
                    throw DaemonError("filesystem daemon runtime is unavailable on WASI")
                    #endif
                }

                // parity: process-daemon/src/daemon/unix.rs#finish [status=implemented hash=b1003f2134e3]
                public func finish() throws {
                    try cleanup.run()
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if lockFD >= 0 {
                        _ = close(lockFD)
                    }
                    #endif
                }
            }

            // parity: process-daemon/src/daemon/unix.rs#process_exists [status=implemented hash=a413ad0ab6a0]
            public static func process_exists(_ pid: UInt32) -> Bool {
                guard let signedPid = Int32(exactly: pid), signedPid > 0 else { return false }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if kill(signedPid, 0) == 0 { return true }
                return errno == EPERM
                #else
                return signedPid == Int32(currentProcessID())
                #endif
            }

            // parity: process-daemon/src/daemon/unix.rs#remove_stale_endpoint [status=implemented hash=3811df799975]
            public static func remove_stale_endpoint(
                canonicalDirectory: String,
                registration: Registration?
            ) throws {
                #if !os(WASI)
                let socket = try registration?.socket ?? resolveSocketPath(canonicalDirectory: canonicalDirectory)
                guard !socket.hasPrefix("memory://") else { return }
                let fm = FileManager.default
                guard fm.fileExists(atPath: socket) else { return }
                let attrs = try fm.attributesOfItem(atPath: socket)
                if (attrs[.type] as? FileAttributeType) == .typeSocket {
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if let ownerID = attrs[.ownerAccountID] as? NSNumber, ownerID.uint32Value != geteuid() {
                        return
                    }
                    #endif
                    try fm.removeItem(atPath: socket)
                }
                #endif
            }

            internal static func resolveSocketPath(
                canonicalDirectory: String,
                environment: any EnvironmentProviding = SystemEnvironment()
            ) throws -> String {
                let base: String
                if let custom = environment.variable("OPENCODE_PTY_SOCKET_DIR") {
                    guard isAbsolutePath(custom) else {
                        throw DaemonError("OPENCODE_PTY_SOCKET_DIR must be an absolute path")
                    }
                    let comps = custom.split(separator: "/")
                    if comps.contains("..") {
                        throw DaemonError("OPENCODE_PTY_SOCKET_DIR must not contain '..'")
                    }
                    base = custom
                } else {
                    base = "/tmp"
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                let uid = geteuid()
                #else
                let uid: UInt32 = 0
                #endif
                let root = joinPath(base, "opencode-pty-\(uid)")
                #if !os(WASI)
                try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
                #endif
                let digest = String(Hash.sha256(canonicalDirectory).prefix(32))
                return joinPath(root, "\(digest).sock")
            }

            internal static func writeRegistrationAtomically(directory: String, registration: Registration) throws {
                #if !os(WASI)
                let tempPath = joinPath(directory, "service.\(registration.instanceId).tmp")
                let finalPath = Daemon.registration_path(directory)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(registration)
                try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath)
                let fm = FileManager.default
                if fm.fileExists(atPath: finalPath) {
                    try fm.removeItem(atPath: finalPath)
                }
                try fm.moveItem(atPath: tempPath, toPath: finalPath)
                #endif
            }
        }

        // MARK: - Windows Daemon Runtime (`src/daemon/windows.rs`)

        public enum WindowsRuntime {
            // parity: process-daemon/src/daemon/windows.rs#read_registration [status=implemented hash=962325816f53]
            public static func read_registration(_ directory: String) throws -> Registration {
                #if os(Windows)
                let security = try WindowsPrivateSecurity.create()
                let file: OwnedWinHandle
                do {
                    file = try WindowsRuntimePrimitives.openStorageHandle(
                        path: Daemon.registration_path(directory),
                        access: DWORD(GENERIC_READ) | DWORD(READ_CONTROL),
                        creation: DWORD(OPEN_EXISTING),
                        sharing: DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_DELETE),
                        security: security
                    )
                } catch {
                    throw DaemonError("opencode-pty registration is unavailable: \(error)")
                }
                try WindowsRuntimePrimitives.checkStorageKind(file, expectDirectory: false)
                try security.checkPrivate(handle: file.raw)
                let bytes = try WindowsRuntimePrimitives.readFileBounded(
                    file,
                    maxBytes: WindowsNamedPipeHelpers.maxRegistrationBytes
                )
                try WindowsNamedPipeHelpers.validateRegistrationSize(bytes.count)
                do {
                    return try JSONDecoder().decode(Registration.self, from: Data(bytes))
                } catch {
                    throw DaemonError("invalid opencode-pty registration: \(error)")
                }
                #elseif os(WASI)
                throw DaemonError("opencode-pty registration is unavailable")
                #else
                let path = Daemon.registration_path(directory)
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: path))
                } catch {
                    throw DaemonError("opencode-pty registration is unavailable: \(error)")
                }
                try WindowsNamedPipeHelpers.validateRegistrationSize(data.count)
                do {
                    return try JSONDecoder().decode(Registration.self, from: data)
                } catch {
                    throw DaemonError("invalid opencode-pty registration: \(error)")
                }
                #endif
            }

            // parity: process-daemon/src/daemon/windows.rs#Cleanup [status=implemented hash=35f689406968]
            public struct Cleanup: Sendable {
                public let directory: String
                public let instanceId: String

                public init(directory: String, instanceId: String) {
                    self.directory = directory
                    self.instanceId = instanceId
                }

                // parity: process-daemon/src/daemon/windows.rs#run [status=implemented hash=19e1bd2871b1]
                public func run() throws {
                    #if !os(WASI)
                    let current = try? read_registration(directory)
                    if WindowsNamedPipeHelpers.shouldRemoveRegistrationOnCleanup(
                        currentInstanceId: current?.instanceId,
                        expectedInstanceId: instanceId
                    ) {
                        try FileManager.default.removeItem(atPath: Daemon.registration_path(directory))
                    }
                    #endif
                }
            }

            // parity: process-daemon/src/daemon/windows.rs#Runtime [status=implemented hash=1fdcc9c32d10]
            public final class Runtime: RuntimeHandle, @unchecked Sendable {
                public let registration: Registration
                public let cleanup: Cleanup
                #if os(Windows)
                private struct HeldState: Sendable {
                    var lock: OwnedWinHandle?
                    var directory: OwnedWinHandle?
                }
                private final class SweeperState: @unchecked Sendable {
                    let cond = PortableCondition()
                    var done = false
                }
                private let held: Mutex<HeldState>
                private let sweeper = SweeperState()

                private init(
                    registration: Registration,
                    cleanup: Cleanup,
                    lock: OwnedWinHandle,
                    directory: OwnedWinHandle
                ) {
                    self.registration = registration
                    self.cleanup = cleanup
                    self.held = Mutex(HeldState(lock: lock, directory: directory))
                    let sweeper = self.sweeper
                    let sweepDir = cleanup.directory
                    Thread.detachNewThread {
                        Sweep.stale_runtimes(sweepDir)
                        sweeper.cond.withLock {
                            sweeper.done = true
                            sweeper.cond.broadcast()
                        }
                    }
                }
                #else
                private init(registration: Registration, cleanup: Cleanup) {
                    self.registration = registration
                    self.cleanup = cleanup
                }
                #endif

                // parity: process-daemon/src/daemon/windows.rs#bind [status=implemented hash=fc116fa71b29]
                public static func bind(_ directory: String) throws -> (Runtime, Transport.Windows.Listener) {
                    guard isAbsolutePath(directory) else {
                        throw DaemonError("PTY runtime directory must be an absolute path")
                    }
                    #if os(Windows)
                    let security = try WindowsPrivateSecurity.create()
                    if let parent = WindowsNamedPipeHelpers.parentDirectory(of: directory) {
                        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    }
                    try WindowsRuntimePrimitives.createPrivateDirectory(path: directory, security: security)
                    let directoryHandle = try WindowsRuntimePrimitives.openStorageHandle(
                        path: directory,
                        access: DWORD(FILE_READ_ATTRIBUTES) | DWORD(FILE_TRAVERSE) | DWORD(READ_CONTROL) | DWORD(WRITE_DAC),
                        creation: DWORD(OPEN_EXISTING),
                        sharing: DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                        security: security
                    )
                    try WindowsRuntimePrimitives.checkStorageKind(directoryHandle, expectDirectory: true)
                    try security.makePrivate(handle: directoryHandle.raw)
                    // All later paths come from the held handle, never the caller's path.
                    let heldDir = try WindowsRuntimePrimitives.heldDirectoryPath(directoryHandle)
                    let lockPath = WindowsNamedPipeHelpers.joinWindowsPath(heldDir, ProcessDaemon.LOCK_FILE)
                    let lockHandle = try WindowsRuntimePrimitives.openStorageHandle(
                        path: lockPath,
                        access: DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE) | DWORD(READ_CONTROL) | DWORD(WRITE_DAC),
                        creation: DWORD(OPEN_ALWAYS),
                        sharing: DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                        security: security
                    )
                    try WindowsRuntimePrimitives.checkStorageKind(lockHandle, expectDirectory: false)
                    try security.makePrivate(handle: lockHandle.raw)
                    guard WindowsRuntimePrimitives.tryLockFileExclusive(lockHandle) else {
                        throw DaemonError("another opencode-pty process already owns the service lock")
                    }

                    let instanceId = ProcessDaemon.randomHex32()
                    let pipeName = WindowsNamedPipeHelpers.makeEndpoint(instanceId: instanceId)
                    let registration = Registration(
                        instanceId: instanceId,
                        pid: currentProcessID(),
                        protocolVersion: ProcessDaemon.PROTOCOL_VERSION,
                        socket: pipeName,
                        token: ProcessDaemon.randomHex32(),
                        features: ProcessDaemon.features()
                    )
                    let listener = try Transport.Windows.Listener.bind(pipeName)
                    try WindowsRuntimePrimitives.writeRegistrationAtomically(
                        directory: heldDir,
                        directoryHandle: directoryHandle,
                        registration: registration,
                        security: security
                    )
                    let cleanup = Cleanup(directory: heldDir, instanceId: instanceId)
                    let runtime = Runtime(
                        registration: registration,
                        cleanup: cleanup,
                        lock: lockHandle,
                        directory: directoryHandle
                    )
                    return (runtime, listener)
                    #else
                    let instanceId = ProcessDaemon.randomHex32()
                    let pipeName = WindowsNamedPipeHelpers.makeEndpoint(instanceId: instanceId)
                    let registration = Registration(
                        instanceId: instanceId,
                        pid: currentProcessID(),
                        protocolVersion: ProcessDaemon.PROTOCOL_VERSION,
                        socket: pipeName,
                        token: ProcessDaemon.randomHex32(),
                        features: ProcessDaemon.features()
                    )
                    let listener = try Transport.Windows.Listener.bind(pipeName)
                    #if !os(WASI)
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try UnixRuntime.writeRegistrationAtomically(directory: directory, registration: registration)
                    #endif
                    let cleanup = Cleanup(directory: directory, instanceId: instanceId)
                    return (Runtime(registration: registration, cleanup: cleanup), listener)
                    #endif
                }

                // parity: process-daemon/src/daemon/windows.rs#finish [status=implemented hash=241f92b01637]
                public func finish() throws {
                    #if os(Windows)
                    sweeper.cond.withLock {
                        while !sweeper.done {
                            _ = sweeper.cond.wait(timeoutMs: 25)
                        }
                    }
                    var cleanupError: (any Error)? = nil
                    do {
                        try cleanup.run()
                    } catch {
                        cleanupError = error
                    }
                    // Release protected handles denying delete access before removing lock and directory.
                    held.withLock { s in
                        s.lock = nil
                        s.directory = nil
                    }
                    let lockPath = WindowsNamedPipeHelpers.joinWindowsPath(cleanup.directory, ProcessDaemon.LOCK_FILE)
                    try? FileManager.default.removeItem(atPath: lockPath)
                    try? FileManager.default.removeItem(atPath: cleanup.directory)
                    if let cleanupError {
                        throw cleanupError
                    }
                    #else
                    try cleanup.run()
                    #if !os(WASI)
                    try? FileManager.default.removeItem(atPath: joinPath(cleanup.directory, ProcessDaemon.LOCK_FILE))
                    try? FileManager.default.removeItem(atPath: cleanup.directory)
                    #endif
                    #endif
                }
            }

            // parity: process-daemon/src/daemon/windows.rs#process_exists [status=implemented hash=9afe7f8a2791]
            public static func process_exists(_ pid: UInt32) -> Bool {
                #if os(Windows)
                return WindowsProcessPrimitives.processExists(pid: pid)
                #else
                return UnixRuntime.process_exists(pid)
                #endif
            }

            // parity: process-daemon/src/daemon/windows.rs#remove_stale_endpoint [status=implemented hash=c5339f929225]
            public static func remove_stale_endpoint(
                canonicalDirectory: String,
                registration: Registration?
            ) throws {
                _ = (canonicalDirectory, registration)
            }
        }

        // MARK: - Daemon Server Loop & Protocol Dispatcher (`src/daemon/server.rs`)

        public enum Server {
            // parity: process-daemon/src/daemon/server.rs#Blocked [status=adapted hash=e56e34a68adb]
            public struct Blocked: Equatable, Hashable, Sendable {
                public let signals: [Int32]

                public init(signals: [Int32] = []) {
                    self.signals = signals
                }
            }

            // parity: process-daemon/src/daemon/server.rs#block [status=adapted hash=81f947206352]
            public static func block() throws -> Blocked {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                return Blocked(signals: [SIGTERM, SIGINT])
                #else
                return Blocked(signals: [])
                #endif
            }

            // parity: process-daemon/src/daemon/server.rs#stop_on [status=adapted hash=57eda98949ed]
            public static func stop_on(_ signals: Blocked, control: Control) throws {
                _ = (signals, control)
            }

            // parity: process-daemon/src/daemon/server.rs#run [status=implemented hash=92a43ce86240]
            public static func run(_ directory: String) throws {
                #if os(Windows)
                let wake = try Transport.Windows.Wake.new()
                let (runtime, listener) = try WindowsRuntime.Runtime.bind(directory)
                let control = Control.new(wake: wake, ownership: Ownership.new(nowMs: monotonicNowMs()))
                try serve(
                    runtime: runtime,
                    listener: listener,
                    control: control,
                    service: TerminalService.new(),
                    safetyNetMs: 2_000
                )
                #else
                let blocked = try block()
                let wake = try Transport.Unix.Wake.new()
                let (runtime, listener) = try UnixRuntime.Runtime.bind(directory)
                let control = Control.new(wake: wake, ownership: Ownership.new(nowMs: monotonicNowMs()))
                try stop_on(blocked, control: control)
                try serve(
                    runtime: runtime,
                    listener: listener,
                    control: control,
                    service: TerminalService.new(),
                    safetyNetMs: 2_000
                )
                #endif
            }

            /// Handle for a running background daemon server (Unix socket, Windows named pipe, or in-memory transport)
            /// used for deterministic cross-platform client/server integration tests.
            public final class RunningInstance: @unchecked Sendable {
                public let registration: Registration
                public let control: Control
                public let service: TerminalService
                private let doneCond = PortableCondition()
                private var stopped = false

                internal init(
                    registration: Registration,
                    control: Control,
                    service: TerminalService,
                    runtime: any RuntimeHandle,
                    listener: any Transport.StreamListener,
                    safetyNetMs: UInt64
                ) {
                    self.registration = registration
                    self.control = control
                    self.service = service
                    let cond = self.doneCond
                    #if !os(WASI)
                    Thread.detachNewThread { [weak self] in
                        _ = try? Server.serve(
                            runtime: runtime,
                            listener: listener,
                            control: control,
                            service: service,
                            safetyNetMs: safetyNetMs
                        )
                        cond.withLock {
                            self?.stopped = true
                            cond.broadcast()
                        }
                    }
                    #endif
                }

                public func stopAndWait(timeoutMs: UInt64 = 3_000) {
                    control.request_stop()
                    waitUntilStopped(timeoutMs: timeoutMs)
                }

                @discardableResult
                public func waitUntilStopped(timeoutMs: UInt64 = 3_000) -> Bool {
                    let deadline = monotonicNowMs() &+ timeoutMs
                    return doneCond.withLock {
                        while !stopped {
                            let now = monotonicNowMs()
                            if now >= deadline { return false }
                            _ = doneCond.wait(timeoutMs: deadline - now)
                        }
                        return true
                    }
                }
            }

            /// Starts a live daemon server on an in-memory endpoint (cross-platform),
            /// a real Unix domain socket directory (macOS/Linux), or a real Windows named pipe (Windows).
            public static func startBackground(
                directory: String? = nil,
                useInMemoryEndpoint: Bool = true,
                acquireTimeoutMs: UInt64 = 60_000,
                handoffTimeoutMs: UInt64 = 60_000,
                safetyNetMs: UInt64 = 50,
                service: TerminalService = TerminalService.new()
            ) throws -> RunningInstance {
                let effectiveDirectory = directory ?? "memory://test-\(ProcessDaemon.randomHex32())"
                let forceInMemory = useInMemoryEndpoint || effectiveDirectory.hasPrefix("memory://")
                let ownership = Ownership.with_timeouts(
                    nowMs: monotonicNowMs(),
                    acquireMs: acquireTimeoutMs,
                    handoffMs: handoffTimeoutMs
                )
                #if os(Windows)
                if !forceInMemory {
                    let wake = try Transport.Windows.Wake.new()
                    let (runtime, listener) = try WindowsRuntime.Runtime.bind(effectiveDirectory)
                    let control = Control.new(wake: wake, ownership: ownership)
                    return RunningInstance(
                        registration: runtime.registration,
                        control: control,
                        service: service,
                        runtime: runtime,
                        listener: listener,
                        safetyNetMs: safetyNetMs
                    )
                }
                #endif
                let wake = try Transport.Unix.Wake.new()
                let (runtime, listener) = try UnixRuntime.Runtime.bind(
                    effectiveDirectory,
                    useInMemoryEndpoint: forceInMemory
                )
                let control = Control.new(wake: wake, ownership: ownership)
                return RunningInstance(
                    registration: runtime.registration,
                    control: control,
                    service: service,
                    runtime: runtime,
                    listener: listener,
                    safetyNetMs: safetyNetMs
                )
            }

            /// Starts a live background daemon server bound to a supplied `RuntimeHandle` and `StreamListener`
            /// (allowing shared server/client transport contract tests on any host OS).
            public static func startBackgroundWithTransport(
                runtime: any RuntimeHandle,
                listener: any Transport.StreamListener,
                wake: any Transport.WakeChannel,
                acquireTimeoutMs: UInt64 = 60_000,
                handoffTimeoutMs: UInt64 = 60_000,
                safetyNetMs: UInt64 = 50,
                service: TerminalService = TerminalService.new()
            ) -> RunningInstance {
                let ownership = Ownership.with_timeouts(
                    nowMs: monotonicNowMs(),
                    acquireMs: acquireTimeoutMs,
                    handoffMs: handoffTimeoutMs
                )
                let control = Control.new(wake: wake, ownership: ownership)
                return RunningInstance(
                    registration: runtime.registration,
                    control: control,
                    service: service,
                    runtime: runtime,
                    listener: listener,
                    safetyNetMs: safetyNetMs
                )
            }

            internal static func serve(
                runtime: any RuntimeHandle,
                listener: any Transport.StreamListener,
                control: Control,
                service: TerminalService,
                safetyNetMs: UInt64
            ) throws {
                let registration = runtime.registration
                struct HandlerRegistry: Sendable {
                    var nextID: UInt64 = 1
                    var active: [UInt64: any Transport.ConnectionCancellation] = [:]
                }
                let handlers = Mutex(HandlerRegistry())
                let handlerCond = PortableCondition()

                var ready = Transport.Readiness()
                var last = OwnershipSnapshot()

                do {
                    while true {
                        let tick = try control.tick(
                            nowMs: monotonicNowMs(),
                            last: &last,
                            timedOut: ready.timedOut
                        )
                        if tick.stopped { break }

                        if ready.connection {
                            for _ in 0..<64 {
                                guard let conn = try listener.acceptConnection() else { break }
                                let cancel = try conn.makeCancellation()
                                let handlerID = handlers.withLock { reg -> UInt64 in
                                    let id = reg.nextID
                                    reg.nextID &+= 1
                                    reg.active[id] = cancel
                                    return id
                                }
                                #if !os(WASI)
                                Thread.detachNewThread {
                                    defer {
                                        conn.closeConnection()
                                        handlers.withLock { _ = $0.active.removeValue(forKey: handlerID) }
                                        handlerCond.withLock { handlerCond.broadcast() }
                                        control.notify()
                                    }
                                    _ = try? handleConnection(
                                        stream: conn,
                                        service: service,
                                        registration: registration,
                                        control: control
                                    )
                                }
                                #else
                                defer {
                                    conn.closeConnection()
                                    handlers.withLock { _ = $0.active.removeValue(forKey: handlerID) }
                                }
                                _ = try? handleConnection(
                                    stream: conn,
                                    service: service,
                                    registration: registration,
                                    control: control
                                )
                                #endif
                            }
                        }

                        let now = monotonicNowMs()
                        var timeout = safetyNetMs
                        if let deadline = tick.deadlineMs {
                            timeout = min(timeout, deadline > now ? (deadline - now) : 0)
                        }
                        ready = try listener.waitForReadiness(wake: control.wake(), listen: true, timeoutMs: timeout)
                        control.stats.incrementIterations()
                    }
                } catch {
                    control.request_stop()
                    listener.stop()
                    for c in handlers.withLock({ Array($0.active.values) }) { c.cancel() }
                    service.shutdown()
                    // Keep listener alive until runtime.finish() removes service.json so the Windows
                    // named-pipe namespace remains owned throughout registration cleanup.
                    withExtendedLifetime(listener) {
                        try? runtime.finish()
                    }
                    throw error
                }

                control.request_stop()
                listener.stop()
                for c in handlers.withLock({ Array($0.active.values) }) { c.cancel() }
                service.shutdown()
                // Wait briefly for handler threads to exit cleanly
                let joinDeadline = monotonicNowMs() &+ 2_000
                handlerCond.withLock {
                    while !handlers.withLock({ $0.active.isEmpty }) && monotonicNowMs() < joinDeadline {
                        _ = handlerCond.wait(timeoutMs: 25)
                    }
                }
                // Keep listener alive until runtime.finish() removes service.json so the Windows
                // named-pipe namespace remains owned throughout registration cleanup.
                try withExtendedLifetime(listener) {
                    try runtime.finish()
                }
            }

            /// Handles one protocol v9 client connection (request/response, owner, wait, or subscribe).
            public static func handleConnection(
                stream: any Transport.StreamConnection,
                service: TerminalService,
                registration: Registration,
                control: Control
            ) throws {
                let (token, parsed) = try ProcessDaemon.read_envelope(stream)
                if token != registration.token {
                    try sendResponse(stream, .error(message: "authentication failed"))
                    return
                }
                let request: Request
                switch parsed {
                case .success(let req):
                    request = req
                case .failure(let err):
                    try sendResponse(stream, .error(message: err.message))
                    return
                }

                if case let .own(instanceId, ticket) = request {
                    let generation: UInt64
                    do {
                        if instanceId != registration.instanceId {
                            throw DaemonError("daemon instance_id mismatch")
                        }
                        if control.stopping() {
                            throw DaemonError("daemon is stopping")
                        }
                        generation = try control.update_ownership { ownership in
                            try ownership.claim(ticket: ticket, nowMs: monotonicNowMs())
                        }
                    } catch {
                        try sendResponse(stream, .error(message: String(describing: error)))
                        return
                    }
                    defer {
                        _ = try? control.update_ownership { ownership in
                            ownership.disconnect(generation: generation, nowMs: monotonicNowMs())
                        }
                    }
                    try ownerConnection(
                        stream: stream,
                        registration: registration,
                        control: control,
                        generation: generation
                    )
                    return
                }

                if case .wait(let id) = request {
                    try waitForExit(stream: stream, service: service, control: control, id: id)
                    return
                }

                if case let .subscribe(id, offset, attachmentId, role, takeover) = request {
                    try streamSubscription(
                        stream: stream,
                        service: service,
                        control: control,
                        id: id,
                        offset: offset,
                        attachmentId: attachmentId,
                        role: role,
                        takeover: takeover
                    )
                    return
                }

                let isShutdown: Bool
                if case .shutdown = request { isShutdown = true } else { isShutdown = false }

                let response: Response
                do {
                    response = try dispatch(request: request, service: service, registration: registration)
                } catch {
                    response = .error(message: String(describing: error))
                }
                try sendResponse(stream, response)
                if isShutdown {
                    control.request_stop()
                }
            }

            private static func ownerConnection(
                stream: any Transport.StreamConnection,
                registration: Registration,
                control: Control,
                generation: UInt64
            ) throws {
                try ProcessDaemon.write_frame(stream, value: Response.owned)
                while !control.stopping() {
                    let (token, parsed) = try ProcessDaemon.read_envelope(stream)
                    if !control.is_owner(generation) {
                        try sendResponse(stream, .error(message: "owner connection has been superseded"))
                        return
                    }
                    if token != registration.token {
                        try ProcessDaemon.write_frame(stream, value: Response.error(message: "authentication failed"))
                        continue
                    }
                    switch parsed {
                    case .failure(let err):
                        try ProcessDaemon.write_frame(stream, value: Response.error(message: err.message))
                    case .success(.prepareHandoff):
                        let handoff = try control.update_ownership { ownership in
                            try ownership.prepare(
                                generation: generation,
                                nowMs: monotonicNowMs(),
                                unixMs: currentUnixMs()
                            )
                        }
                        try ProcessDaemon.write_frame(
                            stream,
                            value: Response.handoff(ticket: handoff.ticket, expiresAt: handoff.expiresAt)
                        )
                    case .success(.shutdown):
                        try sendResponse(stream, .ok)
                        if control.is_owner(generation) {
                            control.request_stop()
                        }
                        return
                    case .success:
                        try ProcessDaemon.write_frame(
                            stream,
                            value: Response.error(message: "owner connection only accepts prepare_handoff or shutdown")
                        )
                    }
                }
            }

            private static func streamSubscription(
                stream: any Transport.StreamConnection,
                service: TerminalService,
                control: Control,
                id: TerminalId,
                offset: UInt64,
                attachmentId: String,
                role: AttachmentRole,
                takeover: Bool
            ) throws {
                let attachment: TerminalAttachment
                do {
                    attachment = try service.attach(
                        id: id,
                        offset: offset,
                        attachmentId: attachmentId,
                        role: role,
                        takeover: takeover
                    )
                } catch {
                    try sendResponse(stream, .error(message: String(describing: error)))
                    return
                }
                defer { attachment.detach() }

                try ProcessDaemon.write_frame(
                    stream,
                    value: Response.attached(
                        process: attachment.process,
                        role: attachment.role,
                        generation: attachment.generation,
                        requestedOffset: attachment.replay.requestedOffset,
                        availableOffset: attachment.replay.availableOffset,
                        endOffset: attachment.replay.endOffset,
                        truncated: attachment.replay.truncated,
                        replayBase64: bytesToBase64(attachment.replay.bytes)
                    )
                )

                let monitor = try stream.makeDisconnectMonitor()
                defer { monitor.finish() }

                while !control.stopping() && !monitor.disconnected() {
                    guard let event = attachment.nextEvent(timeoutMs: 25) else {
                        if attachment.isClosed { break }
                        continue
                    }
                    switch event {
                    case let .output(start, end, bytes):
                        try ProcessDaemon.write_output_frame(stream, start: start, end: end, bytes: bytes)
                    case let .resized(cols, rows, generation, checkpoint):
                        try ProcessDaemon.write_frame(
                            stream,
                            value: Response.resized(
                                cols: cols,
                                rows: rows,
                                generation: generation,
                                checkpointBase64: bytesToBase64(checkpoint)
                            )
                        )
                    case .exited(let exit):
                        try ProcessDaemon.write_frame(stream, value: Response.from(exit))
                        return
                    case let .controllerChanged(attId, generation):
                        try ProcessDaemon.write_frame(
                            stream,
                            value: Response.controllerChanged(attachmentId: attId, generation: generation)
                        )
                    case .titleChanged(let title):
                        try ProcessDaemon.write_frame(stream, value: Response.titleChanged(title: title))
                    case .foregroundProcessChanged(let process):
                        try ProcessDaemon.write_frame(
                            stream,
                            value: Response.foregroundProcessChanged(process: process)
                        )
                    }
                }
            }

            private static func waitForExit(
                stream: any Transport.StreamConnection,
                service: TerminalService,
                control: Control,
                id: TerminalId
            ) throws {
                let wait: ProcessWait
                do {
                    wait = try service.wait(id)
                } catch {
                    try sendResponse(stream, .error(message: String(describing: error)))
                    return
                }
                let monitor = try stream.makeDisconnectMonitor()
                defer { monitor.finish() }

                while !control.stopping() && !monitor.disconnected() {
                    switch wait.poll(timeoutMs: 25) {
                    case .exited(let exit):
                        try ProcessDaemon.write_frame(stream, value: Response.from(exit))
                        return
                    case .terminated:
                        if !control.stopping() {
                            try ProcessDaemon.write_frame(stream, value: Response.error(message: "terminated"))
                        }
                        return
                    case .pending:
                        continue
                    }
                }
            }

            private static func sendResponse(_ stream: any Transport.StreamConnection, _ response: Response) throws {
                try ProcessDaemon.write_frame(stream, value: response)
                try stream.finish_response()
            }

            public static func dispatch(
                request: Request,
                service: TerminalService,
                registration: Registration
            ) throws -> Response {
                switch request {
                case .ping:
                    return .pong(
                        instanceId: registration.instanceId,
                        pid: registration.pid,
                        protocolVersion: registration.protocolVersion,
                        features: registration.features
                    )
                case let .createPty(program, args, cwd, env, groupId, title, cols, rows):
                    let info = try service.create_pty(CreatePty(
                        program: program,
                        args: args,
                        cwd: cwd,
                        env: env,
                        groupId: groupId,
                        title: title,
                        cols: cols,
                        rows: rows
                    ))
                    return .created(process: info)
                case let .createPipe(program, args, cwd, env, groupId, outputPath, metadata):
                    let info = try service.create_pipe(CreatePipe(
                        program: program,
                        args: args,
                        cwd: cwd,
                        env: env,
                        groupId: groupId,
                        outputPath: outputPath,
                        metadata: metadata
                    ))
                    return .created(process: info)
                case .list(let mode):
                    return .processes(processes: try service.list(mode))
                case .get(let id):
                    return .process(process: try service.get(id))
                case let .signal(id, signal):
                    try service.signal(id: id, signal: signal)
                    return .ok
                case let .setMetadata(id, metadata):
                    try service.set_metadata(id: id, metadata: metadata)
                    return .ok
                case let .write(id, attachmentId, dataBase64):
                    let bytes: [UInt8]
                    do {
                        bytes = try base64ToBytes(dataBase64)
                    } catch {
                        throw DaemonError("invalid input base64: \(error)")
                    }
                    try service.write_for(id: id, attachmentId: attachmentId, bytes: bytes)
                    return .ok
                case let .resize(id, attachmentId, cols, rows):
                    try service.resize_for(id: id, attachmentId: attachmentId, cols: cols, rows: rows)
                    return .ok
                case let .control(id, attachmentId, cols, rows):
                    try service.control(id: id, attachmentId: attachmentId, cols: cols, rows: rows)
                    return .ok
                case let .input(id, attachmentId, cols, rows, dataBase64):
                    let bytes: [UInt8]
                    do {
                        bytes = try base64ToBytes(dataBase64)
                    } catch {
                        throw DaemonError("invalid input base64: \(error)")
                    }
                    try service.input(id: id, attachmentId: attachmentId, cols: cols, rows: rows, bytes: bytes)
                    return .ok
                case .snapshot(let id):
                    let snap = try service.snapshot(id)
                    return .snapshot(
                        process: snap.info,
                        text: snap.text,
                        checkpointBase64: bytesToBase64(snap.checkpoint),
                        cursorX: snap.cursorX,
                        cursorY: snap.cursorY
                    )
                case let .readRows(id, rows):
                    let result = try service.read_rows(id: id, rows: rows)
                    return .rows(
                        process: result.process,
                        lines: result.lines,
                        cursorX: result.cursorX,
                        cursorY: result.cursorY
                    )
                case let .rename(id, title):
                    try service.rename(id: id, title: title)
                    return .ok
                case let .replay(id, offset):
                    let rep = try service.replay(id: id, offset: offset)
                    return .replay(
                        requestedOffset: rep.requestedOffset,
                        availableOffset: rep.availableOffset,
                        endOffset: rep.endOffset,
                        truncated: rep.truncated,
                        dataBase64: bytesToBase64(rep.bytes)
                    )
                case .terminate(let id):
                    try service.terminate(id)
                    return .ok
                case .shutdown:
                    return .ok
                case .prepareHandoff:
                    return .error(message: "handoff requires the owner connection")
                case .own, .subscribe, .wait:
                    return .error(message: "streaming/ownership request must be handled directly")
                }
            }
        }
    }
}

// MARK: - Path & POSIX Socket Helpers

internal func isAbsolutePath(_ path: String) -> Bool {
    if path.hasPrefix("/") { return true }
    let chars = Array(path)
    if chars.count >= 3, chars[1] == ":", (chars[2] == "\\" || chars[2] == "/") {
        return true
    }
    if path.hasPrefix(#"\\"#) { return true }
    return false
}

internal func joinPath(_ parts: String...) -> String {
    var result = ""
    for part in parts where !part.isEmpty {
        if result.isEmpty {
            result = part
        } else {
            let lhs = result.hasSuffix("/") ? String(result.dropLast()) : result
            let rhs = part.hasPrefix("/") ? String(part.dropFirst()) : part
            result = "\(lhs)/\(rhs)"
        }
    }
    return result
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
private enum DarwinOrPosix {
    static func bindSocket(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(fd, addr, len)
        #elseif canImport(Glibc)
        return Glibc.bind(fd, addr, len)
        #else
        return Musl.bind(fd, addr, len)
        #endif
    }

    static func connectSocket(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, addr, len)
        #elseif canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #else
        return Musl.connect(fd, addr, len)
        #endif
    }

    static func acceptSocket(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(fd, addr, len)
        #elseif canImport(Glibc)
        return Glibc.accept(fd, addr, len)
        #else
        return Musl.accept(fd, addr, len)
        #endif
    }

    static func readBytes(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buf, count)
        #elseif canImport(Glibc)
        return Glibc.read(fd, buf, count)
        #else
        return Musl.read(fd, buf, count)
        #endif
    }

    static func writeBytes(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buf, count)
        #elseif canImport(Glibc)
        return Glibc.write(fd, buf, count)
        #else
        return Musl.write(fd, buf, count)
        #endif
    }
}

private func makeUnixSockAddr(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let utf8 = Array(path.utf8)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard utf8.count < maxLen else {
        throw ProcessDaemon.DaemonError("Unix socket path exceeds sun_path limit (\(maxLen - 1) bytes): \(path)")
    }
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
        for i in 0..<utf8.count {
            rawBuf[i] = utf8[i]
        }
        rawBuf[utf8.count] = 0
    }
    return addr
}

private func setSocketTimeout(fd: Int32, option: Int32, timeoutMs: UInt64?) throws {
    var tv = timeval()
    if let timeoutMs {
        tv.tv_sec = Int(timeoutMs / 1_000)
        #if canImport(Darwin)
        tv.tv_usec = Int32((timeoutMs % 1_000) * 1_000)
        #else
        tv.tv_usec = Int((timeoutMs % 1_000) * 1_000)
        #endif
    }
    let rc = withUnsafePointer(to: &tv) { ptr in
        setsockopt(fd, SOL_SOCKET, option, ptr, socklen_t(MemoryLayout<timeval>.size))
    }
    if rc != 0 {
        throw ProcessDaemon.DaemonError("setsockopt(\(option)) failed with errno \(errno)")
    }
}
#endif
