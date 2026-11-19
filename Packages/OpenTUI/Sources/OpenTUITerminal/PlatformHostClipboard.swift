import OpenTUICore
import Synchronization

#if os(macOS)
import Darwin
#elseif os(Linux) || os(FreeBSD)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(Android)
#if canImport(Android)
import Android
#endif
#elseif os(Windows)
import WinSDK
#endif

// ============================================================================
// MARK: - 1. Monotonic Clock (`src/clipboard/clock.zig`)
// ============================================================================

/// Monotonic clock utilities for clipboard operation deadlines and polling.
public enum ClipboardMonotonicClock {
    private static let clock = ContinuousClock()
    private static let epoch = clock.now

    // parity: native/src/clipboard/clock.zig#init [status=implemented hash=ceb1cd199d0a]
    public static func initialize() {}

    // parity: native/src/clipboard/clock.zig#nowNs [status=implemented hash=d989797ee775]
    public static func nowNanoseconds() -> Int64 {
        let elapsed = epoch.duration(to: clock.now)
        let components = elapsed.components
        let secNs = components.seconds &* 1_000_000_000
        let attoNs = components.attoseconds / 1_000_000_000
        return secNs &+ attoNs
    }

    // parity: native/src/clipboard/clock.zig#sleep [status=implemented hash=b1010e98b650]
    public static func sleep(nanoseconds: UInt64) {
        ClipboardSync.sleep(nanoseconds: nanoseconds)
    }
}

// ============================================================================
// MARK: - 2. Synchronization Primitives (`src/clipboard/sync.zig`)
// ============================================================================

/// Lightweight thread-safe mutex matching `native/src/clipboard/sync.zig#Mutex`.
// parity: native/src/clipboard/sync.zig#Mutex [status=implemented hash=e794d0730f71]
public final class ClipboardSyncMutex: Sendable {
    private let inner = Mutex<Void>(())

    public init() {}

    @discardableResult
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try inner.withLock { _ in try body() }
    }
}

/// Thread-safe condition/latch primitive matching `native/src/clipboard/sync.zig#Condition`.
/// Supports both async suspension (`wait()`) and synchronous non-blocking state inspection.
// parity: native/src/clipboard/sync.zig#Condition [status=implemented hash=057348e687ba]
public final class ClipboardSyncLatch: Sendable {
    private struct State: Sendable {
        var signaled: Bool = false
        var generation: UInt64 = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(signaled: Bool = false) {
        if signaled {
            self.state.withLock { $0.signaled = true }
        }
    }

    public var isSignaled: Bool {
        state.withLock { $0.signaled }
    }

    public var generation: UInt64 {
        state.withLock { $0.generation }
    }

    public func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.signaled = true
            s.generation &+= 1
            let pending = s.waiters
            s.waiters.removeAll()
            return pending
        }
        for continuation in waiters {
            continuation.resume()
        }
    }

    public func reset() {
        state.withLock { s in
            s.signaled = false
        }
    }

    public func wait() async {
        let alreadySignaled = state.withLock { $0.signaled }
        if alreadySignaled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.signaled { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    public func wait(timeoutNanoseconds: UInt64) async -> Bool {
        if isSignaled { return true }
        if timeoutNanoseconds == 0 { return false }
        let start = ClipboardMonotonicClock.nowNanoseconds()
        let (sum, overflow) = start.addingReportingOverflow(Int64(clamping: timeoutNanoseconds))
        let deadline = overflow ? Int64.max : sum
        while !isSignaled {
            let now = ClipboardMonotonicClock.nowNanoseconds()
            if now >= deadline {
                return isSignaled
            }
            let remaining = UInt64(max(0, deadline - now))
            let step = min(remaining, 1_000_000) // 1ms poll step
            try? await Task.sleep(nanoseconds: step)
        }
        return true
    }
}

/// Sync namespace helpers (`sleep`, `nowNs`).
public enum ClipboardSync {
    // parity: native/src/clipboard/sync.zig#sleep [status=implemented hash=52eda30a4119]
    public static func sleep(nanoseconds: UInt64) {
        if nanoseconds == 0 { return }
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))
        var req = timespec(
            tv_sec: Int(nanoseconds / 1_000_000_000),
            tv_nsec: Int(nanoseconds % 1_000_000_000)
        )
        var rem = timespec(tv_sec: 0, tv_nsec: 0)
        while nanosleep(&req, &rem) != 0 {
            if errno != EINTR { break }
            req = rem
        }
        #elseif os(Windows)
        let ms = DWORD(min(UInt64(DWORD.max), (nanoseconds + 999_999) / 1_000_000))
        Sleep(ms)
        #else
        let start = ClipboardMonotonicClock.nowNanoseconds()
        let (sum, overflow) = start.addingReportingOverflow(Int64(clamping: nanoseconds))
        let target = overflow ? Int64.max : sum
        while ClipboardMonotonicClock.nowNanoseconds() < target {}
        #endif
    }

    // parity: native/src/clipboard/sync.zig#nowNs [status=implemented hash=26ce72f8f9d6]
    public static func nowNanoseconds() -> Int64 {
        ClipboardMonotonicClock.nowNanoseconds()
    }
}

// ============================================================================
// MARK: - 3. POSIX Descriptor & Pipe I/O (`src/clipboard/posix-io.zig`)
// ============================================================================

/// Error surfaced by `PosixClipboardIO` operations.
public enum PosixClipboardIOError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case unsupportedPlatform
    case invalidArgument(String)
    case systemError(operation: String, errno: Int32)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "POSIX clipboard I/O is not supported on this platform"
        case .invalidArgument(let msg):
            return "Invalid POSIX clipboard I/O argument: \(msg)"
        case .systemError(let op, let code):
            return "POSIX clipboard '\(op)' failed with errno \(code)"
        }
    }
}

/// File status summary returned by `PosixClipboardIO.stat`.
public struct PosixClipboardFileStat: Equatable, Hashable, Sendable {
    public let mode: UInt32
    public let size: Int64
    public let isSocket: Bool

    public init(mode: UInt32, size: Int64, isSocket: Bool) {
        self.mode = mode
        self.size = size
        self.isSocket = isSocket
    }
}

/// Cross-platform POSIX descriptor, pipe, socket, and environment helpers matching `src/clipboard/posix-io.zig`.
public enum PosixClipboardIO {
    // parity: native/src/clipboard/posix-io.zig#close [status=implemented hash=7d81b20914d7]
    public static func close(_ fd: Int32) {
        #if os(macOS)
        _ = Darwin.close(fd)
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #endif
        #elseif os(Android)
        _ = Android.close(fd)
        #else
        _ = fd
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#pipe [status=implemented hash=c62c9ad90cfe]
    public static func pipe() throws(PosixClipboardIOError) -> (readFD: Int32, writeFD: Int32) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        var fds: [Int32] = [-1, -1]
        #if os(macOS)
        let rc = Darwin.pipe(&fds)
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.pipe(&fds)
        #elseif canImport(Musl)
        let rc = Musl.pipe(&fds)
        #endif
        #elseif os(Android)
        let rc = Android.pipe(&fds)
        #endif
        guard rc == 0 else {
            throw .systemError(operation: "pipe", errno: errno)
        }
        return (fds[0], fds[1])
        #else
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#socket [status=implemented hash=4d30fcdce7fd]
    public static func socket(domain: Int32, type: Int32, protocol proto: Int32 = 0) throws(PosixClipboardIOError) -> Int32 {
        #if os(macOS)
        let fd = Darwin.socket(domain, type, proto)
        guard fd >= 0 else { throw .systemError(operation: "socket", errno: errno) }
        return fd
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let fd = Glibc.socket(domain, type, proto)
        #elseif canImport(Musl)
        let fd = Musl.socket(domain, type, proto)
        #endif
        guard fd >= 0 else { throw .systemError(operation: "socket", errno: errno) }
        return fd
        #elseif os(Android)
        let fd = Android.socket(domain, type, proto)
        guard fd >= 0 else { throw .systemError(operation: "socket", errno: errno) }
        return fd
        #else
        _ = (domain, type, proto)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#connect [status=implemented hash=a232b675953e]
    public static func connect(fd: Int32, unixPath: String) throws(PosixClipboardIOError) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(unixPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            throw .invalidArgument("Unix socket path exceeds maximum length")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                #if os(macOS)
                return Darwin.connect(fd, sockPtr, addrLen)
                #elseif os(Linux) || os(FreeBSD)
                #if canImport(Glibc)
                return Glibc.connect(fd, sockPtr, addrLen)
                #elseif canImport(Musl)
                return Musl.connect(fd, sockPtr, addrLen)
                #endif
                #elseif os(Android)
                return Android.connect(fd, sockPtr, addrLen)
                #endif
            }
        }
        guard rc == 0 else { throw .systemError(operation: "connect", errno: errno) }
        #else
        _ = (fd, unixPath)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#bind [status=implemented hash=2fcbfc28cf30]
    public static func bind(fd: Int32, unixPath: String) throws(PosixClipboardIOError) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(unixPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            throw .invalidArgument("Unix socket path exceeds maximum length")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                #if os(macOS)
                return Darwin.bind(fd, sockPtr, addrLen)
                #elseif os(Linux) || os(FreeBSD)
                #if canImport(Glibc)
                return Glibc.bind(fd, sockPtr, addrLen)
                #elseif canImport(Musl)
                return Musl.bind(fd, sockPtr, addrLen)
                #endif
                #elseif os(Android)
                return Android.bind(fd, sockPtr, addrLen)
                #endif
            }
        }
        guard rc == 0 else { throw .systemError(operation: "bind", errno: errno) }
        #else
        _ = (fd, unixPath)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#stat [status=implemented hash=4766cfb5b1ce]
    public static func stat(path: String) throws(PosixClipboardIOError) -> PosixClipboardFileStat {
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))
        var st = stat_struct_compat()
        let rc = path.withCString { cPath -> Int32 in
            posixStatSyscall(cPath, &st)
        }
        guard rc == 0 else { throw .systemError(operation: "stat", errno: errno) }
        let mode = UInt32(st.st_mode)
        let isSock = (mode & UInt32(S_IFMT)) == UInt32(S_IFSOCK)
        return PosixClipboardFileStat(mode: mode, size: Int64(st.st_size), isSocket: isSock)
        #else
        _ = path
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#duplicate [status=implemented hash=90a9d0d72b32]
    public static func duplicate(_ fd: Int32) throws(PosixClipboardIOError) -> Int32 {
        #if os(macOS)
        let dupFD = Darwin.dup(fd)
        guard dupFD >= 0 else { throw .systemError(operation: "dup", errno: errno) }
        return dupFD
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let dupFD = Glibc.dup(fd)
        #elseif canImport(Musl)
        let dupFD = Musl.dup(fd)
        #endif
        guard dupFD >= 0 else { throw .systemError(operation: "dup", errno: errno) }
        return dupFD
        #elseif os(Android)
        let dupFD = Android.dup(fd)
        guard dupFD >= 0 else { throw .systemError(operation: "dup", errno: errno) }
        return dupFD
        #else
        _ = fd
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#unlink [status=implemented hash=41a6d967b1ca]
    public static func unlink(path: String) throws(PosixClipboardIOError) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let rc = path.withCString { cPath -> Int32 in
            #if os(macOS)
            return Darwin.unlink(cPath)
            #elseif os(Linux) || os(FreeBSD)
            #if canImport(Glibc)
            return Glibc.unlink(cPath)
            #elseif canImport(Musl)
            return Musl.unlink(cPath)
            #endif
            #elseif os(Android)
            return Android.unlink(cPath)
            #endif
        }
        guard rc == 0 else { throw .systemError(operation: "unlink", errno: errno) }
        #else
        _ = path
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#checkSocketError [status=implemented hash=49e0ab00abb9]
    public static func checkSocketError(_ fd: Int32) throws(PosixClipboardIOError) -> Int32 {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        var errCode: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        #if os(macOS)
        let rc = Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &errCode, &len)
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.getsockopt(fd, SOL_SOCKET, SO_ERROR, &errCode, &len)
        #elseif canImport(Musl)
        let rc = Musl.getsockopt(fd, SOL_SOCKET, SO_ERROR, &errCode, &len)
        #endif
        #elseif os(Android)
        let rc = Android.getsockopt(fd, SOL_SOCKET, SO_ERROR, &errCode, &len)
        #endif
        guard rc == 0 else { throw .systemError(operation: "getsockopt", errno: errno) }
        return errCode
        #else
        _ = fd
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#listen [status=implemented hash=8e5c0d70e30e]
    public static func listen(fd: Int32, backlog: Int32 = 16) throws(PosixClipboardIOError) {
        #if os(macOS)
        let rc = Darwin.listen(fd, backlog)
        guard rc == 0 else { throw .systemError(operation: "listen", errno: errno) }
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.listen(fd, backlog)
        #elseif canImport(Musl)
        let rc = Musl.listen(fd, backlog)
        #endif
        guard rc == 0 else { throw .systemError(operation: "listen", errno: errno) }
        #elseif os(Android)
        let rc = Android.listen(fd, backlog)
        guard rc == 0 else { throw .systemError(operation: "listen", errno: errno) }
        #else
        _ = (fd, backlog)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#truncate [status=implemented hash=d702acad9dc8]
    public static func truncate(fd: Int32, length: Int64) throws(PosixClipboardIOError) {
        #if os(macOS)
        let rc = Darwin.ftruncate(fd, off_t(length))
        guard rc == 0 else { throw .systemError(operation: "ftruncate", errno: errno) }
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.ftruncate(fd, off_t(length))
        #elseif canImport(Musl)
        let rc = Musl.ftruncate(fd, off_t(length))
        #endif
        guard rc == 0 else { throw .systemError(operation: "ftruncate", errno: errno) }
        #elseif os(Android)
        let rc = Android.ftruncate(fd, off_t(length))
        guard rc == 0 else { throw .systemError(operation: "ftruncate", errno: errno) }
        #else
        _ = (fd, length)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#write [status=implemented hash=307d64ae3071]
    public static func write(fd: Int32, bytes: [UInt8]) throws(PosixClipboardIOError) -> Int {
        if bytes.isEmpty { return 0 }
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl))) || (os(Android) && canImport(Android))
        var writeError: PosixClipboardIOError? = nil
        let totalWritten: Int = bytes.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let ptr = base.advanced(by: total)
                let remaining = bytes.count - total
                #if os(macOS)
                let written = Darwin.write(fd, ptr, remaining)
                #elseif os(Linux) || os(FreeBSD)
                #if canImport(Glibc)
                let written = Glibc.write(fd, ptr, remaining)
                #elseif canImport(Musl)
                let written = Musl.write(fd, ptr, remaining)
                #endif
                #elseif os(Android) && canImport(Android)
                let written = Android.write(fd, ptr, remaining)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    writeError = .systemError(operation: "write", errno: errno)
                    return total
                }
                if written == 0 { break }
                total += written
            }
            return total
        }
        if let writeError {
            throw writeError
        }
        return totalWritten
        #else
        _ = (fd, bytes)
        throw .unsupportedPlatform
        #endif
    }

    /// Reads all available bytes from a POSIX file descriptor up to `maxBytes + 1` (so caller can detect overflow).
    public static func readAll(fd: Int32, maxBytes: Int) throws(PosixClipboardIOError) -> (bytes: [UInt8], exceeded: Bool) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let limit = max(0, maxBytes)
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n: Int = chunk.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return 0 }
                #if os(macOS)
                return Darwin.read(fd, base, buf.count)
                #elseif os(Linux) || os(FreeBSD)
                #if canImport(Glibc)
                return Glibc.read(fd, base, buf.count)
                #elseif canImport(Musl)
                return Musl.read(fd, base, buf.count)
                #endif
                #elseif os(Android)
                return Android.read(fd, base, buf.count)
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw .systemError(operation: "read", errno: errno)
            }
            if n == 0 { break }
            if result.count + n > limit {
                return (result, true)
            }
            result.append(contentsOf: chunk[0..<n])
        }
        return (result, false)
        #else
        _ = (fd, maxBytes)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#getFlags [status=implemented hash=d1698c5b105a]
    public static func getFlags(_ fd: Int32) throws(PosixClipboardIOError) -> Int32 {
        #if os(macOS)
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw .systemError(operation: "fcntl(F_GETFL)", errno: errno) }
        return flags
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let flags = Glibc.fcntl(fd, F_GETFL)
        #elseif canImport(Musl)
        let flags = Musl.fcntl(fd, F_GETFL)
        #endif
        guard flags >= 0 else { throw .systemError(operation: "fcntl(F_GETFL)", errno: errno) }
        return flags
        #elseif os(Android)
        let flags = Android.fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw .systemError(operation: "fcntl(F_GETFL)", errno: errno) }
        return flags
        #else
        _ = fd
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#setFlags [status=implemented hash=f82337bd71d8]
    public static func setFlags(_ fd: Int32, flags: Int32) throws(PosixClipboardIOError) {
        #if os(macOS)
        let rc = Darwin.fcntl(fd, F_SETFL, flags)
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFL)", errno: errno) }
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.fcntl(fd, F_SETFL, flags)
        #elseif canImport(Musl)
        let rc = Musl.fcntl(fd, F_SETFL, flags)
        #endif
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFL)", errno: errno) }
        #elseif os(Android)
        let rc = Android.fcntl(fd, F_SETFL, flags)
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFL)", errno: errno) }
        #else
        _ = (fd, flags)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#setDescriptorFlags [status=implemented hash=82a3d1e2eaf2]
    public static func setDescriptorFlags(_ fd: Int32, flags: Int32) throws(PosixClipboardIOError) {
        #if os(macOS)
        let rc = Darwin.fcntl(fd, F_SETFD, flags)
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFD)", errno: errno) }
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.fcntl(fd, F_SETFD, flags)
        #elseif canImport(Musl)
        let rc = Musl.fcntl(fd, F_SETFD, flags)
        #endif
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFD)", errno: errno) }
        #elseif os(Android)
        let rc = Android.fcntl(fd, F_SETFD, flags)
        guard rc >= 0 else { throw .systemError(operation: "fcntl(F_SETFD)", errno: errno) }
        #else
        _ = (fd, flags)
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#shutdownRead [status=implemented hash=93a898e6532b]
    public static func shutdownRead(_ fd: Int32) throws(PosixClipboardIOError) {
        #if os(macOS)
        let rc = Darwin.shutdown(fd, SHUT_RD)
        guard rc == 0 else { throw .systemError(operation: "shutdown", errno: errno) }
        #elseif os(Linux) || os(FreeBSD)
        #if canImport(Glibc)
        let rc = Glibc.shutdown(fd, Int32(SHUT_RD))
        #elseif canImport(Musl)
        let rc = Musl.shutdown(fd, Int32(SHUT_RD))
        #endif
        guard rc == 0 else { throw .systemError(operation: "shutdown", errno: errno) }
        #elseif os(Android)
        let rc = Android.shutdown(fd, Int32(SHUT_RD))
        guard rc == 0 else { throw .systemError(operation: "shutdown", errno: errno) }
        #else
        _ = fd
        throw .unsupportedPlatform
        #endif
    }

    // parity: native/src/clipboard/posix-io.zig#getEnv [status=implemented hash=c64cff1d9bb6]
    public static func getEnv(_ name: String) -> String? {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        return name.withCString { cName in
            guard let raw = getenv(cName) else { return nil }
            return String(cString: raw)
        }
        #else
        _ = name
        return nil
        #endif
    }

    /// Runs an executable with piped stdin/stdout using `posix_spawn` (no Foundation dependency).
    public static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinBytes: [UInt8]? = nil,
        maxOutputBytes: Int = Int(defaultClipboardMaxBytes),
        extraEnv: [String: String] = [:]
    ) throws(PosixClipboardIOError) -> (exitCode: Int32, stdout: [UInt8], exceededOutputLimit: Bool) {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let inPipe = try pipe()
        let outPipe: (readFD: Int32, writeFD: Int32)
        do {
            outPipe = try pipe()
        } catch {
            close(inPipe.readFD)
            close(inPipe.writeFD)
            throw error
        }

        #if os(macOS)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_adddup2(&actions, inPipe.readFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe.writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, inPipe.readFD)
        posix_spawn_file_actions_addclose(&actions, inPipe.writeFD)
        posix_spawn_file_actions_addclose(&actions, outPipe.readFD)
        posix_spawn_file_actions_addclose(&actions, outPipe.writeFD)

        let argvStrings = [executablePath] + arguments
        let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgv {
                if let ptr { free(ptr) }
            }
        }

        let inheritedKeys = [
            "PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE",
            "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DISPLAY", "XAUTHORITY", "TMPDIR",
        ]
        var envPairs: [String: String] = [:]
        for key in inheritedKeys {
            if let value = getEnv(key) {
                envPairs[key] = value
            }
        }
        if envPairs["LC_CTYPE"] == nil && envPairs["LANG"] == nil {
            envPairs["LC_CTYPE"] = "UTF-8"
        }
        for (k, v) in extraEnv {
            envPairs[k] = v
        }
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for ptr in cEnvp {
                if let ptr { free(ptr) }
            }
        }

        var pid: pid_t = 0
        let spawnRC: Int32 = executablePath.withCString { cPath in
            cArgv.withUnsafeBufferPointer { argvBuf in
                cEnvp.withUnsafeBufferPointer { envpBuf in
                    posix_spawn(
                        &pid,
                        cPath,
                        &actions,
                        nil,
                        argvBuf.baseAddress,
                        envpBuf.baseAddress
                    )
                }
            }
        }

        close(inPipe.readFD)
        close(outPipe.writeFD)

        if spawnRC != 0 {
            close(inPipe.writeFD)
            close(outPipe.readFD)
            throw .systemError(operation: "posix_spawn(\(executablePath))", errno: spawnRC)
        }

        if let stdinBytes, !stdinBytes.isEmpty {
            _ = try? write(fd: inPipe.writeFD, bytes: stdinBytes)
        }
        close(inPipe.writeFD)

        let readResult = try readAll(fd: outPipe.readFD, maxBytes: maxOutputBytes)
        close(outPipe.readFD)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { break }
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : -1
        return (exitCode, readResult.bytes, readResult.exceeded)
        #else
        _ = (executablePath, arguments, stdinBytes, maxOutputBytes, extraEnv)
        throw .unsupportedPlatform
        #endif
    }
}

#if os(macOS)
private typealias stat_struct_compat = Darwin.stat
private func posixStatSyscall(_ cPath: UnsafePointer<CChar>, _ st: inout stat_struct_compat) -> Int32 {
    stat(cPath, &st)
}
#elseif os(Linux) || os(FreeBSD)
#if canImport(Glibc)
private typealias stat_struct_compat = Glibc.stat
private func posixStatSyscall(_ cPath: UnsafePointer<CChar>, _ st: inout stat_struct_compat) -> Int32 {
    stat(cPath, &st)
}
#elseif canImport(Musl)
private typealias stat_struct_compat = Musl.stat
private func posixStatSyscall(_ cPath: UnsafePointer<CChar>, _ st: inout stat_struct_compat) -> Int32 {
    stat(cPath, &st)
}
#endif
#elseif os(Android) && canImport(Android)
private typealias stat_struct_compat = Android.stat
private func posixStatSyscall(_ cPath: UnsafePointer<CChar>, _ st: inout stat_struct_compat) -> Int32 {
    stat(cPath, &st)
}
#endif

// ============================================================================
// MARK: - 4. Pure-Swift Windows DIB / BMP <-> RGBA / PNG Codec (`src/clipboard/windows-dib.zig`)
// ============================================================================

/// Error raised during Windows DIB / BMP decoding or PNG conversion.
// parity: native/src/clipboard/windows-dib.zig#ConvertError [status=implemented hash=b9d141d1f399]
public enum WindowsDIBConvertError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidData
    case unsupported
    case limitExceeded
    case outOfMemory
    case cancelled
    case timedOut

    public var description: String {
        switch self {
        case .invalidData: return "Invalid Windows DIB/BMP image data"
        case .unsupported: return "Unsupported Windows DIB compression or pixel format"
        case .limitExceeded: return "Windows DIB conversion exceeded configured byte or pixel limits"
        case .outOfMemory: return "Out of memory during Windows DIB conversion"
        case .cancelled: return "Windows DIB conversion was cancelled"
        case .timedOut: return "Windows DIB conversion timed out"
        }
    }
}

/// Options bounding Windows DIB/BMP decoding and PNG encoding.
// parity: native/src/clipboard/windows-dib.zig#ConvertOptions [status=implemented hash=ee71c74c974c]
public struct WindowsDIBConvertOptions: Equatable, Hashable, Sendable {
    public var maxOutputBytes: UInt32
    public var maxImagePixels: UInt32
    public var maxConversionBytes: UInt32
    public var deadlineNs: Int64

    public init(
        maxOutputBytes: UInt32 = defaultClipboardMaxBytes,
        maxImagePixels: UInt32 = defaultClipboardMaxImagePixels,
        maxConversionBytes: UInt32 = defaultClipboardMaxConversionBytes,
        deadlineNs: Int64 = Int64.max
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.maxImagePixels = maxImagePixels
        self.maxConversionBytes = maxConversionBytes
        self.deadlineNs = deadlineNs
    }
}

/// Decoded RGBA pixel buffer from a Windows DIB or BMP payload.
public struct WindowsDIBDecodedImage: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let hasAlpha: Bool
    public let topDown: Bool

    public init(width: Int, height: Int, rgba: [UInt8], hasAlpha: Bool, topDown: Bool) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.hasAlpha = hasAlpha
        self.topDown = topDown
    }
}

/// Pure-Swift Windows DIB (`CF_DIB` / `CF_DIBV5`) and BMP (`BM`) codec — compiled on ALL platforms.
public enum WindowsDIBCodec {
    private static let biRGB: UInt32 = 0
    private static let biBitfields: UInt32 = 3
    private static let biAlphaBitfields: UInt32 = 6

    private struct ChannelMask {
        let mask: UInt32
        let shift: UInt32
        let maximum: UInt32

        init?(mask: UInt32) {
            guard mask != 0 else { return nil }
            let shift = UInt32(mask.trailingZeroBitCount)
            let shifted = mask >> shift
            // Contiguous bits check: shifted & (shifted + 1) == 0
            guard (shifted & (shifted &+ 1)) == 0 else { return nil }
            self.mask = mask
            self.shift = shift
            self.maximum = shifted
        }

        func extract(_ pixel: UInt32) -> UInt8 {
            let v = (pixel & mask) >> shift
            if maximum == 255 { return UInt8(v) }
            if maximum == 0 { return 0 }
            return UInt8((UInt64(v) * 255 + UInt64(maximum / 2)) / UInt64(maximum))
        }
    }

    private static func readU16LE(_ data: [UInt8], at offset: Int) throws(WindowsDIBConvertError) -> UInt16 {
        guard offset >= 0 && offset + 2 <= data.count else { throw .invalidData }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32LE(_ data: [UInt8], at offset: Int) throws(WindowsDIBConvertError) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else { throw .invalidData }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readI32LE(_ data: [UInt8], at offset: Int) throws(WindowsDIBConvertError) -> Int32 {
        Int32(bitPattern: try readU32LE(data, at: offset))
    }

    private static func appendU16LE(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendU32LE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendI32LE(_ out: inout [UInt8], _ value: Int32) {
        appendU32LE(&out, UInt32(bitPattern: value))
    }

    /// Encodes straight RGBA8 pixels into a 32-bit BGRA Windows DIB (`BITMAPINFOHEADER` + pixels).
    public static func rgbaToDib(
        rgba: [UInt8],
        width: Int,
        height: Int,
        topDown: Bool = false
    ) throws(WindowsDIBConvertError) -> [UInt8] {
        guard width > 0 && height > 0 else { throw .invalidData }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (expected, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow && !byteOverflow && rgba.count == expected else { throw .invalidData }

        let headerSize: UInt32 = 40
        let imageSize = UInt32(expected)
        var dib: [UInt8] = []
        dib.reserveCapacity(Int(headerSize) + expected)

        appendU32LE(&dib, headerSize)                              // biSize
        appendI32LE(&dib, Int32(width))                            // biWidth
        appendI32LE(&dib, topDown ? -Int32(height) : Int32(height)) // biHeight
        appendU16LE(&dib, 1)                                       // biPlanes
        appendU16LE(&dib, 32)                                      // biBitCount (BGRA)
        appendU32LE(&dib, biRGB)                                   // biCompression
        appendU32LE(&dib, imageSize)                               // biSizeImage
        appendI32LE(&dib, 2835)                                    // biXPelsPerMeter (72 DPI)
        appendI32LE(&dib, 2835)                                    // biYPelsPerMeter (72 DPI)
        appendU32LE(&dib, 0)                                       // biClrUsed
        appendU32LE(&dib, 0)                                       // biClrImportant

        for dstRow in 0..<height {
            let srcRow = topDown ? dstRow : (height - 1 - dstRow)
            let rowBase = srcRow * width * 4
            for x in 0..<width {
                let idx = rowBase + x * 4
                let r = rgba[idx]
                let g = rgba[idx + 1]
                let b = rgba[idx + 2]
                let a = rgba[idx + 3]
                dib.append(b)
                dib.append(g)
                dib.append(r)
                dib.append(a)
            }
        }
        return dib
    }

    /// Encodes straight RGBA8 pixels into a complete Windows BMP file (`BM` 14-byte header + DIB).
    public static func rgbaToBmp(
        rgba: [UInt8],
        width: Int,
        height: Int,
        topDown: Bool = false
    ) throws(WindowsDIBConvertError) -> [UInt8] {
        let dib = try rgbaToDib(rgba: rgba, width: width, height: height, topDown: topDown)
        let fileSize = UInt32(14 + dib.count)
        let pixelOffset: UInt32 = 14 + 40
        var bmp: [UInt8] = []
        bmp.reserveCapacity(Int(fileSize))
        bmp.append(UInt8(ascii: "B"))
        bmp.append(UInt8(ascii: "M"))
        appendU32LE(&bmp, fileSize)
        appendU16LE(&bmp, 0)
        appendU16LE(&bmp, 0)
        appendU32LE(&bmp, pixelOffset)
        bmp.append(contentsOf: dib)
        return bmp
    }

    /// Decodes a Windows DIB (`BITMAPINFOHEADER` / V4 / V5, 24-bit or 32-bit, BI_RGB or BI_BITFIELDS) into straight RGBA8.
    public static func dibToRgba(
        _ dib: [UInt8],
        pixelOffsetOverride: Int? = nil,
        options: WindowsDIBConvertOptions = WindowsDIBConvertOptions(),
        cancelSignal: ClipboardAbortSignal? = nil
    ) throws(WindowsDIBConvertError) -> WindowsDIBDecodedImage {
        if cancelSignal?.isAborted == true { throw .cancelled }
        if ClipboardMonotonicClock.nowNanoseconds() > options.deadlineNs { throw .timedOut }
        guard dib.count >= 40 else { throw .invalidData }

        let headerSize = Int(try readU32LE(dib, at: 0))
        guard headerSize >= 40 && headerSize <= dib.count else { throw .invalidData }

        let rawWidth = try readI32LE(dib, at: 4)
        let rawHeight = try readI32LE(dib, at: 8)
        let planes = try readU16LE(dib, at: 12)
        let bpp = try readU16LE(dib, at: 14)
        let compression = try readU32LE(dib, at: 16)
        let colorsUsed = Int(try readU32LE(dib, at: 32))

        guard rawWidth > 0 && rawHeight != 0 && rawHeight != Int32.min else { throw .invalidData }
        guard planes == 1 else { throw .invalidData }
        guard bpp == 24 || bpp == 32 else { throw .unsupported }

        let width = Int(rawWidth)
        let topDown = rawHeight < 0
        let height = topDown ? Int(-rawHeight) : Int(rawHeight)

        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        if pixelOverflow || pixelCount > Int(options.maxImagePixels) {
            throw .limitExceeded
        }
        let (rgbaCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        if byteOverflow || rgbaCount > Int(options.maxConversionBytes) {
            throw .limitExceeded
        }

        let rowStride = ((width * Int(bpp) + 31) / 32) * 4
        var redMask: ChannelMask? = nil
        var greenMask: ChannelMask? = nil
        var blueMask: ChannelMask? = nil
        var alphaMask: ChannelMask? = nil
        var extraMaskBytes = 0

        switch compression {
        case biRGB:
            if bpp == 32 {
                redMask = ChannelMask(mask: 0x00FF_0000)
                greenMask = ChannelMask(mask: 0x0000_FF00)
                blueMask = ChannelMask(mask: 0x0000_00FF)
                alphaMask = ChannelMask(mask: 0xFF00_0000)
            }
        case biBitfields, biAlphaBitfields:
            guard bpp == 32 else { throw .unsupported }
            let maskOffset: Int
            if headerSize >= 56 {
                maskOffset = 40
            } else if headerSize == 40 {
                maskOffset = 40
                extraMaskBytes = compression == biAlphaBitfields ? 16 : 12
            } else {
                throw .invalidData
            }
            let r = try readU32LE(dib, at: maskOffset)
            let g = try readU32LE(dib, at: maskOffset + 4)
            let b = try readU32LE(dib, at: maskOffset + 8)
            let a: UInt32 = (headerSize >= 56 || compression == biAlphaBitfields)
                ? (try readU32LE(dib, at: maskOffset + 12))
                : 0
            redMask = ChannelMask(mask: r)
            greenMask = ChannelMask(mask: g)
            blueMask = ChannelMask(mask: b)
            alphaMask = a != 0 ? ChannelMask(mask: a) : nil
            guard redMask != nil, greenMask != nil, blueMask != nil else { throw .invalidData }
        default:
            throw .unsupported
        }

        let paletteBytes = colorsUsed * 4
        let computedPixelOffset = headerSize + extraMaskBytes + paletteBytes
        let pixelOffset = pixelOffsetOverride ?? computedPixelOffset
        let (pixelDataBytes, strideOverflow) = rowStride.multipliedReportingOverflow(by: height)
        let (pixelDataEnd, endOverflow) = pixelOffset.addingReportingOverflow(pixelDataBytes)
        guard !strideOverflow && !endOverflow && pixelOffset >= headerSize && pixelDataEnd <= dib.count else {
            throw .invalidData
        }

        var rgba = [UInt8](repeating: 0, count: rgbaCount)
        var anyNonZeroAlpha = false

        for y in 0..<height {
            if (y & 63) == 0 {
                if cancelSignal?.isAborted == true { throw .cancelled }
                if ClipboardMonotonicClock.nowNanoseconds() > options.deadlineNs { throw .timedOut }
            }
            let srcRow = topDown ? y : (height - 1 - y)
            let srcBase = pixelOffset + srcRow * rowStride
            let dstBase = y * width * 4

            if bpp == 24 {
                for x in 0..<width {
                    let s = srcBase + x * 3
                    let d = dstBase + x * 4
                    rgba[d] = dib[s + 2]
                    rgba[d + 1] = dib[s + 1]
                    rgba[d + 2] = dib[s]
                    rgba[d + 3] = 255
                }
            } else if compression == biRGB {
                for x in 0..<width {
                    let s = srcBase + x * 4
                    let d = dstBase + x * 4
                    rgba[d] = dib[s + 2]
                    rgba[d + 1] = dib[s + 1]
                    rgba[d + 2] = dib[s]
                    let a = dib[s + 3]
                    if a != 0 { anyNonZeroAlpha = true }
                    rgba[d + 3] = a
                }
            } else {
                guard let rm = redMask, let gm = greenMask, let bm = blueMask else { throw .invalidData }
                for x in 0..<width {
                    let s = srcBase + x * 4
                    let pixel = UInt32(dib[s])
                        | (UInt32(dib[s + 1]) << 8)
                        | (UInt32(dib[s + 2]) << 16)
                        | (UInt32(dib[s + 3]) << 24)
                    let d = dstBase + x * 4
                    rgba[d] = rm.extract(pixel)
                    rgba[d + 1] = gm.extract(pixel)
                    rgba[d + 2] = bm.extract(pixel)
                    if let am = alphaMask {
                        let a = am.extract(pixel)
                        if a != 0 { anyNonZeroAlpha = true }
                        rgba[d + 3] = a
                    } else {
                        rgba[d + 3] = 255
                    }
                }
            }
        }

        // Standard Windows BI_RGB 32-bit DIBs sometimes leave alpha bytes all 0 when opaque.
        if bpp == 32 && compression == biRGB && !anyNonZeroAlpha {
            for i in stride(from: 3, to: rgba.count, by: 4) {
                rgba[i] = 255
            }
        }

        return WindowsDIBDecodedImage(
            width: width,
            height: height,
            rgba: rgba,
            hasAlpha: bpp == 32 && anyNonZeroAlpha,
            topDown: topDown
        )
    }

    /// Decodes a Windows BMP file (`BM` 14-byte header + DIB) into straight RGBA8.
    public static func bmpToRgba(
        _ bmp: [UInt8],
        options: WindowsDIBConvertOptions = WindowsDIBConvertOptions(),
        cancelSignal: ClipboardAbortSignal? = nil
    ) throws(WindowsDIBConvertError) -> WindowsDIBDecodedImage {
        guard bmp.count >= 14 else { throw .invalidData }
        guard bmp[0] == UInt8(ascii: "B"), bmp[1] == UInt8(ascii: "M") else { throw .invalidData }
        let reserved1 = try readU16LE(bmp, at: 6)
        let reserved2 = try readU16LE(bmp, at: 8)
        guard reserved1 == 0 && reserved2 == 0 else { throw .invalidData }
        let fileSize = Int(try readU32LE(bmp, at: 2))
        guard fileSize == bmp.count else { throw .invalidData }
        let pixelOffset = Int(try readU32LE(bmp, at: 10))
        guard pixelOffset >= 14 && pixelOffset <= fileSize else { throw .invalidData }
        let dib = Array(bmp[14...])
        return try dibToRgba(dib, pixelOffsetOverride: pixelOffset - 14, options: options, cancelSignal: cancelSignal)
    }

    /// Converts a raw Windows DIB payload to PNG bytes.
    // parity: native/src/clipboard/windows-dib.zig#convertToPng [status=implemented hash=5b37bef61d1e]
    public static func convertToPng(
        _ dib: [UInt8],
        options: WindowsDIBConvertOptions = WindowsDIBConvertOptions(),
        cancelSignal: ClipboardAbortSignal? = nil
    ) throws(WindowsDIBConvertError) -> [UInt8] {
        let decoded = try dibToRgba(dib, options: options, cancelSignal: cancelSignal)
        return try encodeRgbaToPng(decoded, maxOutputBytes: Int(options.maxOutputBytes))
    }

    /// Converts a complete Windows BMP file (`BM` header + DIB) to PNG bytes.
    // parity: native/src/clipboard/windows-dib.zig#convertBmpToPng [status=implemented hash=ae89f592232f]
    public static func convertBmpToPng(
        _ bmp: [UInt8],
        options: WindowsDIBConvertOptions = WindowsDIBConvertOptions(),
        cancelSignal: ClipboardAbortSignal? = nil
    ) throws(WindowsDIBConvertError) -> [UInt8] {
        let decoded = try bmpToRgba(bmp, options: options, cancelSignal: cancelSignal)
        return try encodeRgbaToPng(decoded, maxOutputBytes: Int(options.maxOutputBytes))
    }

    private static func encodeRgbaToPng(
        _ decoded: WindowsDIBDecodedImage,
        maxOutputBytes: Int
    ) throws(WindowsDIBConvertError) -> [UInt8] {
        do {
            let image = try NativeImage.fromRgba(decoded.rgba, width: decoded.width, height: decoded.height)
            let png = try image.encodePNG()
            guard png.count <= maxOutputBytes else { throw WindowsDIBConvertError.limitExceeded }
            return png
        } catch let err as WindowsDIBConvertError {
            throw err
        } catch {
            throw .invalidData
        }
    }
}

// ============================================================================
// MARK: - 5. Wayland Wire Protocol & Data-Control Metadata (`src/clipboard/wayland-protocol.zig`, `wayland.zig`)
// ============================================================================

/// Wayland data-control protocol variant (`ext_data_control_manager_v1` vs `zwlr_data_control_manager_v1`).
// parity: native/src/clipboard/wayland-protocol.zig#Kind [status=implemented hash=3a9c77222667]
public enum WaylandDataControlKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case ext
    case wlr
}

/// Wayland message signature descriptor matching `WlMessage` in `linux.zig`.
// parity: native/src/clipboard/linux.zig#WlMessage [status=implemented hash=75ee7d0c9e51]
public struct WaylandMessageDescriptor: Equatable, Hashable, Sendable {
    public let name: String
    public let signature: String
    public let typeNames: [String?]

    public init(name: String, signature: String, typeNames: [String?] = []) {
        self.name = name
        self.signature = signature
        self.typeNames = typeNames
    }
}

/// Wayland interface descriptor matching `WlInterface` in `linux.zig`.
// parity: native/src/clipboard/linux.zig#WlInterface [status=implemented hash=d1270fdc6d65]
public struct WaylandInterfaceDescriptor: Equatable, Hashable, Sendable {
    public let name: String
    public let version: Int32
    public let requests: [WaylandMessageDescriptor]
    public let events: [WaylandMessageDescriptor]

    public init(
        name: String,
        version: Int32,
        requests: [WaylandMessageDescriptor] = [],
        events: [WaylandMessageDescriptor] = []
    ) {
        self.name = name
        self.version = version
        self.requests = requests
        self.events = events
    }
}

/// Wayland data-control protocol metadata matching `native/src/clipboard/wayland-protocol.zig#Metadata`.
// parity: native/src/clipboard/wayland-protocol.zig#Metadata [status=implemented hash=fc840cc715ae]
public struct WaylandDataControlMetadata: Equatable, Hashable, Sendable {
    public let kind: WaylandDataControlKind
    public let manager: WaylandInterfaceDescriptor
    public let device: WaylandInterfaceDescriptor
    public let source: WaylandInterfaceDescriptor
    public let offer: WaylandInterfaceDescriptor

    public init(kind: WaylandDataControlKind, seatInterfaceName: String = "wl_seat") {
        self.kind = kind
        let managerName: String
        let deviceName: String
        let sourceName: String
        let offerName: String
        let version: Int32
        let primarySignature: String

        switch kind {
        case .ext:
            managerName = "ext_data_control_manager_v1"
            deviceName = "ext_data_control_device_v1"
            sourceName = "ext_data_control_source_v1"
            offerName = "ext_data_control_offer_v1"
            version = 1
            primarySignature = "?o"
        case .wlr:
            managerName = "zwlr_data_control_manager_v1"
            deviceName = "zwlr_data_control_device_v1"
            sourceName = "zwlr_data_control_source_v1"
            offerName = "zwlr_data_control_offer_v1"
            version = 2
            primarySignature = "2?o"
        }

        self.manager = WaylandInterfaceDescriptor(
            name: managerName,
            version: version,
            requests: [
                WaylandMessageDescriptor(name: "create_data_source", signature: "n", typeNames: [sourceName]),
                WaylandMessageDescriptor(name: "get_data_device", signature: "no", typeNames: [deviceName, seatInterfaceName]),
                WaylandMessageDescriptor(name: "destroy", signature: ""),
            ]
        )
        self.device = WaylandInterfaceDescriptor(
            name: deviceName,
            version: version,
            requests: [
                WaylandMessageDescriptor(name: "set_selection", signature: "?o", typeNames: [sourceName]),
                WaylandMessageDescriptor(name: "destroy", signature: ""),
                WaylandMessageDescriptor(name: "set_primary_selection", signature: primarySignature, typeNames: [sourceName]),
            ],
            events: [
                WaylandMessageDescriptor(name: "data_offer", signature: "n", typeNames: [offerName]),
                WaylandMessageDescriptor(name: "selection", signature: "?o", typeNames: [offerName]),
                WaylandMessageDescriptor(name: "finished", signature: ""),
                WaylandMessageDescriptor(name: "primary_selection", signature: primarySignature, typeNames: [offerName]),
            ]
        )
        self.source = WaylandInterfaceDescriptor(
            name: sourceName,
            version: 1,
            requests: [
                WaylandMessageDescriptor(name: "offer", signature: "s"),
                WaylandMessageDescriptor(name: "destroy", signature: ""),
            ],
            events: [
                WaylandMessageDescriptor(name: "send", signature: "sh"),
                WaylandMessageDescriptor(name: "cancelled", signature: ""),
            ]
        )
        self.offer = WaylandInterfaceDescriptor(
            name: offerName,
            version: 1,
            requests: [
                WaylandMessageDescriptor(name: "receive", signature: "sh"),
                WaylandMessageDescriptor(name: "destroy", signature: ""),
            ],
            events: [
                WaylandMessageDescriptor(name: "offer", signature: "s"),
            ]
        )
    }
}

/// Wayland wire-format argument value matching `WlArgument`.
// parity: native/src/clipboard/linux.zig#WlArgument [status=implemented hash=a054d6677a1b]
public enum WaylandWireArgument: Equatable, Hashable, Sendable {
    case int32(Int32)
    case uint32(UInt32)
    case objectId(UInt32)
    case newId(UInt32)
    case string(String)
    case array([UInt8])
    case fd(Int32)
}

/// Decoded Wayland wire message header (object ID + 16-bit opcode + 16-bit total byte length).
public struct WaylandWireHeader: Equatable, Hashable, Sendable {
    public let objectId: UInt32
    public let opcode: UInt16
    public let length: UInt16

    public init(objectId: UInt32, opcode: UInt16, length: UInt16) {
        self.objectId = objectId
        self.opcode = opcode
        self.length = length
    }
}

/// Errors raised when framing or decoding Wayland wire-protocol messages.
public enum WaylandWireError: Error, Equatable, Hashable, Sendable {
    case truncatedHeader
    case truncatedPayload
    case invalidLength
    case invalidStringEncoding
    case messageTooLarge
}

/// Pure-Swift Wayland wire-protocol framing helpers (little-endian, 32-bit word aligned).
public enum WaylandWireProtocol {
    public static let headerSize: Int = 8

    private static func appendU32LE(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }

    private static func readU32LE(_ bytes: [UInt8], at offset: Int) throws(WaylandWireError) -> UInt32 {
        guard offset >= 0 && offset + 4 <= bytes.count else { throw .truncatedPayload }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Encodes a Wayland wire message with 8-byte header and 32-bit padded payload arguments.
    public static func encodeMessage(
        objectId: UInt32,
        opcode: UInt16,
        arguments: [WaylandWireArgument]
    ) throws(WaylandWireError) -> [UInt8] {
        var payload: [UInt8] = []
        for arg in arguments {
            switch arg {
            case .int32(let v):
                appendU32LE(&payload, UInt32(bitPattern: v))
            case .uint32(let v), .objectId(let v), .newId(let v):
                appendU32LE(&payload, v)
            case .string(let s):
                let utf8 = Array(s.utf8)
                let lenWithNul = UInt32(utf8.count + 1)
                appendU32LE(&payload, lenWithNul)
                payload.append(contentsOf: utf8)
                payload.append(0)
                let pad = (4 - (Int(lenWithNul) % 4)) % 4
                for _ in 0..<pad { payload.append(0) }
            case .array(let bytes):
                let len = UInt32(bytes.count)
                appendU32LE(&payload, len)
                payload.append(contentsOf: bytes)
                let pad = (4 - (bytes.count % 4)) % 4
                for _ in 0..<pad { payload.append(0) }
            case .fd:
                // File descriptors are transferred out-of-band via SCM_RIGHTS ancillary data.
                break
            }
        }
        let totalLength = headerSize + payload.count
        guard totalLength <= Int(UInt16.max) else { throw .messageTooLarge }
        let sizeAndOpcode = (UInt32(totalLength) << 16) | UInt32(opcode)
        var message: [UInt8] = []
        message.reserveCapacity(totalLength)
        appendU32LE(&message, objectId)
        appendU32LE(&message, sizeAndOpcode)
        message.append(contentsOf: payload)
        return message
    }

    /// Decodes a Wayland 8-byte wire header from `bytes` starting at `offset`.
    public static func decodeHeader(_ bytes: [UInt8], offset: Int = 0) throws(WaylandWireError) -> WaylandWireHeader {
        guard offset >= 0 && offset + headerSize <= bytes.count else { throw .truncatedHeader }
        let objectId = try readU32LE(bytes, at: offset)
        let word1 = try readU32LE(bytes, at: offset + 4)
        let opcode = UInt16(word1 & 0xFFFF)
        let length = UInt16((word1 >> 16) & 0xFFFF)
        guard Int(length) >= headerSize && (Int(length) % 4) == 0 else { throw .invalidLength }
        return WaylandWireHeader(objectId: objectId, opcode: opcode, length: length)
    }

    /// Decodes a 32-bit aligned NUL-terminated Wayland string at `offset`, returning `(string, nextOffset)`.
    public static func decodeString(_ bytes: [UInt8], offset: Int) throws(WaylandWireError) -> (value: String, nextOffset: Int) {
        let rawLenU32 = try readU32LE(bytes, at: offset)
        let start = offset + 4
        guard start <= bytes.count else { throw .truncatedPayload }
        let remaining = bytes.count - start
        guard rawLenU32 <= UInt32(clamping: remaining) else { throw .truncatedPayload }
        let rawLen = Int(rawLenU32)
        if rawLen == 0 {
            return ("", start)
        }
        let (paddedSum, padOverflow) = rawLen.addingReportingOverflow(3)
        guard !padOverflow else { throw .truncatedPayload }
        let paddedLen = paddedSum & ~3
        guard paddedLen <= remaining else { throw .truncatedPayload }
        guard bytes[start + rawLen - 1] == 0 else {
            throw .invalidStringEncoding
        }
        let strSlice = bytes[start..<(start + rawLen - 1)]
        guard let decoded = String(validating: strSlice, as: UTF8.self) else {
            throw .invalidStringEncoding
        }
        return (decoded, start + paddedLen)
    }

    /// Decodes a 32-bit aligned Wayland byte array at `offset`, returning `(bytes, nextOffset)`.
    public static func decodeArray(_ bytes: [UInt8], offset: Int) throws(WaylandWireError) -> (value: [UInt8], nextOffset: Int) {
        let rawLenU32 = try readU32LE(bytes, at: offset)
        let start = offset + 4
        guard start <= bytes.count else { throw .truncatedPayload }
        let remaining = bytes.count - start
        guard rawLenU32 <= UInt32(clamping: remaining) else { throw .truncatedPayload }
        let rawLen = Int(rawLenU32)
        let (paddedSum, padOverflow) = rawLen.addingReportingOverflow(3)
        guard !padOverflow else { throw .truncatedPayload }
        let paddedLen = paddedSum & ~3
        guard paddedLen <= remaining else { throw .truncatedPayload }
        return (Array(bytes[start..<(start + rawLen)]), start + paddedLen)
    }
}

private func trimAsciiWhitespace(_ s: Substring) -> Substring {
    var start = s.startIndex
    var end = s.endIndex
    while start < end {
        let ch = s[start]
        if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
            start = s.index(after: start)
        } else {
            break
        }
    }
    while end > start {
        let prev = s.index(before: end)
        let ch = s[prev]
        if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
            end = prev
        } else {
            break
        }
    }
    return s[start..<end]
}

/// Canonicalizes a Wayland MIME offer type into its lowercase essence without parameters,
/// matching `native/src/clipboard/wayland.zig#canonicalMimeEssence`.
// parity: native/src/clipboard/wayland.zig#canonicalMimeEssence [status=implemented hash=5b64fff0386e]
public func canonicalWaylandMimeEssence(_ rawMime: String) -> String? {
    let parts = rawMime.split(separator: ";", omittingEmptySubsequences: false)
    guard let rawEssence = parts.first else { return nil }
    let lowered = String(trimAsciiWhitespace(rawEssence)).lowercased()
    let essence: String
    switch lowered {
    case "text/plain", "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp":
        essence = lowered
    default:
        return nil
    }

    if parts.count > 1 {
        for rawParam in parts.dropFirst() {
            let param = trimAsciiWhitespace(rawParam)
            if param.isEmpty { continue }
            guard let eqIdx = param.firstIndex(of: "=") else { continue }
            let name = String(trimAsciiWhitespace(param[..<eqIdx])).lowercased()
            guard name == "charset", essence == "text/plain" else { continue }
            var value = trimAsciiWhitespace(param[param.index(after: eqIdx)...])
            if value.count >= 2 && value.first == "\"" && value.last == "\"" {
                value = trimAsciiWhitespace(value.dropFirst().dropLast())
            }
            if String(value).lowercased() != "utf-8" {
                return nil
            }
        }
    }
    return essence
}

// parity: native/src/clipboard/wayland.zig#Progress [status=implemented hash=75baa47f684a]
public enum WaylandClipboardProgress: String, Equatable, Hashable, Sendable {
    case pending
    case ready
    case completed
    case failed
}

// parity: native/src/clipboard/wayland.zig#Failure [status=implemented hash=0076f0c7a572]
public struct WaylandClipboardFailure: Equatable, Hashable, Sendable {
    public let code: UInt32
    public let message: String

    public init(code: UInt32, message: String) {
        self.code = code
        self.message = message
    }
}

// parity: native/src/clipboard/wayland.zig#SelectionResult [status=implemented hash=2bf69682c642]
public enum WaylandClipboardSelectionResult: Equatable, Hashable, Sendable {
    case ready
    case empty
    case unsupported
    case failed(WaylandClipboardFailure)
}

// parity: native/src/clipboard/wayland.zig#Offer [status=implemented hash=11fce5a2b376]
public struct WaylandClipboardOffer: Equatable, Hashable, Sendable {
    public let objectId: UInt32
    public var mimeTypes: [String]

    public init(objectId: UInt32, mimeTypes: [String] = []) {
        self.objectId = objectId
        self.mimeTypes = mimeTypes
    }

    public func bestMatch(preferredTypes: [String]) -> WaylandClipboardMimeMatch? {
        for preferred in preferredTypes {
            let target = preferred.lowercased()
            for offered in mimeTypes {
                if canonicalWaylandMimeEssence(offered) == target {
                    return WaylandClipboardMimeMatch(requestedMime: target, offeredMime: offered, needsBmpToPng: false)
                }
            }
            if target == "image/png" {
                for offered in mimeTypes {
                    if canonicalWaylandMimeEssence(offered) == "image/bmp" {
                        return WaylandClipboardMimeMatch(requestedMime: target, offeredMime: offered, needsBmpToPng: true)
                    }
                }
            }
        }
        return nil
    }
}

// parity: native/src/clipboard/wayland.zig#MimeMatch [status=implemented hash=c93db34a4283]
public struct WaylandClipboardMimeMatch: Equatable, Hashable, Sendable {
    public let requestedMime: String
    public let offeredMime: String
    public let needsBmpToPng: Bool

    public init(requestedMime: String, offeredMime: String, needsBmpToPng: Bool = false) {
        self.requestedMime = requestedMime
        self.offeredMime = offeredMime
        self.needsBmpToPng = needsBmpToPng
    }
}

// parity: native/src/clipboard/wayland.zig#Connection [status=implemented hash=82249276d183]
public final class WaylandClipboardConnection: Sendable {
    private struct State: Sendable {
        var protocolKind: WaylandDataControlKind
        var seatName: String?
        var ready: Bool
        var currentOffer: WaylandClipboardOffer?
        var primaryOffer: WaylandClipboardOffer?
    }

    private let state: Mutex<State>

    public init(protocolKind: WaylandDataControlKind = .ext, seatName: String? = nil, ready: Bool = false) {
        self.state = Mutex(State(protocolKind: protocolKind, seatName: seatName, ready: ready, currentOffer: nil, primaryOffer: nil))
    }

    public var isReady: Bool { state.withLock { $0.ready } }
    public var protocolKind: WaylandDataControlKind { state.withLock { $0.protocolKind } }
    public var seatName: String? { state.withLock { $0.seatName } }

    public func setOffer(_ offer: WaylandClipboardOffer?, selection: ClipboardSelection = .clipboard) {
        state.withLock { s in
            switch selection {
            case .clipboard: s.currentOffer = offer
            case .primary: s.primaryOffer = offer
            }
        }
    }

    public func offer(for selection: ClipboardSelection = .clipboard) -> WaylandClipboardOffer? {
        state.withLock { s in
            switch selection {
            case .clipboard: return s.currentOffer
            case .primary: return s.primaryOffer
            }
        }
    }

    // parity: native/src/clipboard/wayland.zig#testSymbols [status=adapted hash=49036f89c0c2]
    public static func testSymbols() -> LinuxWaylandSymbols {
        LinuxWaylandSymbols(available: true, libraryName: "libwayland-client.so.0")
    }

    // parity: native/src/clipboard/wayland.zig#testReadyConnection [status=adapted hash=25dd6e9b35df]
    public static func testReadyConnection(seatName: String? = "seat0") -> WaylandClipboardConnection {
        WaylandClipboardConnection(protocolKind: .ext, seatName: seatName, ready: true)
    }
}

// ============================================================================
// MARK: - 6. X11 Clipboard Protocol Types (`src/clipboard/x11.zig`)
// ============================================================================

// parity: native/src/clipboard/x11.zig#Progress [status=implemented hash=75baa47f684a]
public enum X11ClipboardProgress: String, Equatable, Hashable, Sendable {
    case pending
    case ready
    case completed
    case failed
}

// parity: native/src/clipboard/x11.zig#Failure [status=implemented hash=e399d2670b89]
public struct X11ClipboardFailure: Equatable, Hashable, Sendable {
    public let code: UInt32
    public let message: String

    public init(code: UInt32, message: String) {
        self.code = code
        self.message = message
    }
}

// parity: native/src/clipboard/x11.zig#SelectionResult [status=implemented hash=2bf69682c642]
public enum X11ClipboardSelectionResult: Equatable, Hashable, Sendable {
    case ready
    case empty
    case unsupported
    case failed(X11ClipboardFailure)
}

// parity: native/src/clipboard/x11.zig#ReadResult [status=implemented hash=a4cbccf61e4e]
public enum X11ClipboardReadResult: Equatable, Hashable, Sendable {
    case read(mimeType: String, bytes: [UInt8])
    case empty
    case limitExceeded
    case timedOut
    case cancelled
    case failed(X11ClipboardFailure)
}

// parity: native/src/clipboard/x11.zig#ReadState [status=implemented hash=7a7784719f00]
public struct X11ClipboardReadState: Equatable, Hashable, Sendable {
    public var incremental: Bool
    public var buffer: [UInt8]
    public var targetAtom: UInt32

    public init(incremental: Bool = false, buffer: [UInt8] = [], targetAtom: UInt32 = 0) {
        self.incremental = incremental
        self.buffer = buffer
        self.targetAtom = targetAtom
    }
}

// parity: native/src/clipboard/x11.zig#WriteState [status=implemented hash=917373572bf5]
public struct X11ClipboardWriteState: Equatable, Hashable, Sendable {
    public var selection: ClipboardSelection
    public var payload: [UInt8]
    public var ownsSelection: Bool

    public init(selection: ClipboardSelection = .clipboard, payload: [UInt8] = [], ownsSelection: Bool = false) {
        self.selection = selection
        self.payload = payload
        self.ownsSelection = ownsSelection
    }
}

// parity: native/src/clipboard/x11.zig#Provider [status=implemented hash=8af022f2bddf]
public struct X11ClipboardProvider: Equatable, Hashable, Sendable {
    public var activeTransfers: Int
    public var maxTransfers: Int

    public init(activeTransfers: Int = 0, maxTransfers: Int = Int(defaultClipboardMaxProviderTransfers)) {
        self.activeTransfers = activeTransfers
        self.maxTransfers = maxTransfers
    }
}

// parity: native/src/clipboard/x11.zig#Atoms [status=implemented hash=7ea4f2e03601]
public struct X11ClipboardAtoms: Equatable, Hashable, Sendable {
    public let clipboard: UInt32
    public let primary: UInt32
    public let targets: UInt32
    public let utf8String: UInt32
    public let incr: UInt32
    public let property: UInt32

    public init(
        clipboard: UInt32 = 1,
        primary: UInt32 = 2,
        targets: UInt32 = 3,
        utf8String: UInt32 = 4,
        incr: UInt32 = 5,
        property: UInt32 = 6
    ) {
        self.clipboard = clipboard
        self.primary = primary
        self.targets = targets
        self.utf8String = utf8String
        self.incr = incr
        self.property = property
    }
}

// parity: native/src/clipboard/x11.zig#Connection [status=implemented hash=a72003a9e9df]
public final class X11ClipboardConnection: Sendable {
    public let displayName: String?
    public let atoms: X11ClipboardAtoms
    private let connected: Mutex<Bool>

    public init(displayName: String? = nil, atoms: X11ClipboardAtoms = X11ClipboardAtoms(), connected: Bool = false) {
        self.displayName = displayName
        self.atoms = atoms
        self.connected = Mutex(connected)
    }

    public var isConnected: Bool { connected.withLock { $0 } }
}

// ============================================================================
// MARK: - 7. Linux Clipboard Environment & Symbol Descriptors (`src/clipboard/linux.zig`)
// ============================================================================

// parity: native/src/clipboard/linux.zig#Environment [status=implemented hash=810346d32c57]
public struct LinuxClipboardEnvironment: Equatable, Hashable, Sendable {
    public let waylandDisplay: String?
    public let display: String?
    public let xdgRuntimeDir: String?
    public let waylandSeat: String?

    public init(
        waylandDisplay: String? = PosixClipboardIO.getEnv("WAYLAND_DISPLAY"),
        display: String? = PosixClipboardIO.getEnv("DISPLAY"),
        xdgRuntimeDir: String? = PosixClipboardIO.getEnv("XDG_RUNTIME_DIR"),
        waylandSeat: String? = nil
    ) {
        self.waylandDisplay = waylandDisplay?.isEmpty == true ? nil : waylandDisplay
        self.display = display?.isEmpty == true ? nil : display
        self.xdgRuntimeDir = xdgRuntimeDir?.isEmpty == true ? nil : xdgRuntimeDir
        self.waylandSeat = waylandSeat
    }

    public var preferredMechanism: LinuxClipboardMechanism {
        if waylandDisplay != nil { return .wayland }
        if display != nil { return .x11 }
        return .unavailable
    }
}

// parity: native/src/clipboard/linux.zig#Mechanism [status=implemented hash=10b93bec1329]
public enum LinuxClipboardMechanism: String, Equatable, Hashable, Sendable {
    case wayland
    case x11
    case unavailable
}

// parity: native/src/clipboard/linux.zig#WlDisplay [status=adapted hash=680aa9813a57]
public struct WaylandDisplayHandle: Equatable, Hashable, Sendable {
    public let rawHandle: UInt64
    public init(rawHandle: UInt64 = 0) { self.rawHandle = rawHandle }
}

// parity: native/src/clipboard/linux.zig#WlProxy [status=adapted hash=d460334cdaf1]
public struct WaylandProxyHandle: Equatable, Hashable, Sendable {
    public let rawHandle: UInt64
    public init(rawHandle: UInt64 = 0) { self.rawHandle = rawHandle }
}

// parity: native/src/clipboard/linux.zig#XcbConnection [status=adapted hash=984dd3b119e3]
public struct XcbConnectionHandle: Equatable, Hashable, Sendable {
    public let rawHandle: UInt64
    public init(rawHandle: UInt64 = 0) { self.rawHandle = rawHandle }
}

// parity: native/src/clipboard/linux.zig#XcbAuthInfo [status=adapted hash=9307172de640]
public struct XcbAuthInfoRecord: Equatable, Hashable, Sendable {
    public let name: String
    public let data: [UInt8]
    public init(name: String = "", data: [UInt8] = []) { self.name = name; self.data = data }
}

// parity: native/src/clipboard/linux.zig#XcbGenericEvent [status=adapted hash=d66c1bc294fe]
public struct XcbGenericEventRecord: Equatable, Hashable, Sendable {
    public let responseType: UInt8
    public let sequence: UInt16
    public init(responseType: UInt8 = 0, sequence: UInt16 = 0) { self.responseType = responseType; self.sequence = sequence }
}

// parity: native/src/clipboard/linux.zig#XcbGenericError [status=adapted hash=075ab50b576d]
public struct XcbGenericErrorRecord: Equatable, Hashable, Sendable {
    public let errorCode: UInt8
    public let sequence: UInt16
    public init(errorCode: UInt8 = 0, sequence: UInt16 = 0) { self.errorCode = errorCode; self.sequence = sequence }
}

// parity: native/src/clipboard/linux.zig#XcbCookie [status=adapted hash=8e20d5393c9b]
public struct XcbCookieValue: Equatable, Hashable, Sendable {
    public let sequence: UInt32
    public init(sequence: UInt32 = 0) { self.sequence = sequence }
}

// parity: native/src/clipboard/linux.zig#XcbInternAtomReply [status=adapted hash=79712b8dd67f]
public struct XcbInternAtomReplyRecord: Equatable, Hashable, Sendable {
    public let atom: UInt32
    public init(atom: UInt32 = 0) { self.atom = atom }
}

// parity: native/src/clipboard/linux.zig#XcbGetSelectionOwnerReply [status=adapted hash=12654c96d650]
public struct XcbGetSelectionOwnerReplyRecord: Equatable, Hashable, Sendable {
    public let owner: UInt32
    public init(owner: UInt32 = 0) { self.owner = owner }
}

// parity: native/src/clipboard/linux.zig#XcbGetPropertyReply [status=adapted hash=ae4a8f4d3d8f]
public struct XcbGetPropertyReplyRecord: Equatable, Hashable, Sendable {
    public let format: UInt8
    public let type: UInt32
    public let bytesAfter: UInt32
    public let valueLen: UInt32
    public init(format: UInt8 = 8, type: UInt32 = 0, bytesAfter: UInt32 = 0, valueLen: UInt32 = 0) {
        self.format = format; self.type = type; self.bytesAfter = bytesAfter; self.valueLen = valueLen
    }
}

// parity: native/src/clipboard/linux.zig#XcbSetup [status=adapted hash=68fc014c1382]
public struct XcbSetupRecord: Equatable, Hashable, Sendable {
    public let status: UInt8
    public let protocolMajorVersion: UInt16
    public init(status: UInt8 = 1, protocolMajorVersion: UInt16 = 11) {
        self.status = status; self.protocolMajorVersion = protocolMajorVersion
    }
}

// parity: native/src/clipboard/linux.zig#XcbScreen [status=adapted hash=daebfbad2d07]
public struct XcbScreenRecord: Equatable, Hashable, Sendable {
    public let root: UInt32
    public init(root: UInt32 = 0) { self.root = root }
}

// parity: native/src/clipboard/linux.zig#XcbScreenIterator [status=adapted hash=39cccfa948a1]
public struct XcbScreenIteratorRecord: Equatable, Hashable, Sendable {
    public let rem: Int32
    public init(rem: Int32 = 0) { self.rem = rem }
}

// parity: native/src/clipboard/linux.zig#XcbPropertyNotifyEvent [status=adapted hash=ebce737f00c6]
public struct XcbPropertyNotifyEventRecord: Equatable, Hashable, Sendable {
    public let window: UInt32
    public let atom: UInt32
    public let state: UInt8
    public init(window: UInt32 = 0, atom: UInt32 = 0, state: UInt8 = 0) {
        self.window = window; self.atom = atom; self.state = state
    }
}

// parity: native/src/clipboard/linux.zig#XcbSelectionClearEvent [status=adapted hash=47d4542a3b24]
public struct XcbSelectionClearEventRecord: Equatable, Hashable, Sendable {
    public let owner: UInt32
    public let selection: UInt32
    public init(owner: UInt32 = 0, selection: UInt32 = 0) { self.owner = owner; self.selection = selection }
}

// parity: native/src/clipboard/linux.zig#XcbSelectionRequestEvent [status=adapted hash=94fd4ef5f3d1]
public struct XcbSelectionRequestEventRecord: Equatable, Hashable, Sendable {
    public let requestor: UInt32
    public let selection: UInt32
    public let target: UInt32
    public let property: UInt32
    public init(requestor: UInt32 = 0, selection: UInt32 = 0, target: UInt32 = 0, property: UInt32 = 0) {
        self.requestor = requestor; self.selection = selection; self.target = target; self.property = property
    }
}

// parity: native/src/clipboard/linux.zig#XcbSelectionNotifyEvent [status=adapted hash=afb573cbd441]
public struct XcbSelectionNotifyEventRecord: Equatable, Hashable, Sendable {
    public let requestor: UInt32
    public let selection: UInt32
    public let target: UInt32
    public let property: UInt32
    public init(requestor: UInt32 = 0, selection: UInt32 = 0, target: UInt32 = 0, property: UInt32 = 0) {
        self.requestor = requestor; self.selection = selection; self.target = target; self.property = property
    }
}

// parity: native/src/clipboard/linux.zig#WaylandSymbols [status=implemented hash=f7d05927de70]
public struct LinuxWaylandSymbols: Equatable, Hashable, Sendable {
    public let available: Bool
    public let libraryName: String
    public init(available: Bool = false, libraryName: String = "libwayland-client.so.0") {
        self.available = available
        self.libraryName = libraryName
    }
}

// parity: native/src/clipboard/linux.zig#XcbSymbols [status=implemented hash=120d624822d2]
public struct LinuxXcbSymbols: Equatable, Hashable, Sendable {
    public let available: Bool
    public let libraryName: String
    public init(available: Bool = false, libraryName: String = "libxcb.so.1") {
        self.available = available
        self.libraryName = libraryName
    }
}

// parity: native/src/clipboard/linux.zig#Libraries [status=implemented hash=eb6f015fa3e5]
public struct LinuxClipboardLibraries: Equatable, Hashable, Sendable {
    public let wayland: LinuxWaylandSymbols
    public let xcb: LinuxXcbSymbols
    public init(wayland: LinuxWaylandSymbols = LinuxWaylandSymbols(), xcb: LinuxXcbSymbols = LinuxXcbSymbols()) {
        self.wayland = wayland
        self.xcb = xcb
    }
}

// parity: native/src/clipboard/linux.zig#Report [status=implemented hash=c71bb56c4797]
public struct LinuxClipboardReport: Equatable, Hashable, Sendable {
    public let mechanism: LinuxClipboardMechanism
    public let cause: String?
    public init(mechanism: LinuxClipboardMechanism, cause: String? = nil) {
        self.mechanism = mechanism
        self.cause = cause
    }
}

/// Runtime state and diagnostics for Linux Wayland/X11 clipboard probing.
public enum LinuxClipboardRuntime {
    private struct State: Sendable {
        var lastCause: String? = nil
        var waylandOverride: LinuxWaylandSymbols? = nil
        var logEntries: [String] = []
    }

    private static let state = Mutex(State())

    // parity: native/src/clipboard/linux.zig#test_log [status=adapted hash=25831e1bffba]
    public static var testLog: [String] {
        state.withLock { $0.logEntries }
    }

    // parity: native/src/clipboard/linux.zig#initialize [status=implemented hash=f21a0b9074e7]
    public static func initialize(environment: LinuxClipboardEnvironment = LinuxClipboardEnvironment()) -> LinuxClipboardReport {
        let mechanism = environment.preferredMechanism
        if mechanism == .unavailable {
            let reason = "Neither WAYLAND_DISPLAY nor DISPLAY is set"
            recordCause(reason)
            return LinuxClipboardReport(mechanism: .unavailable, cause: reason)
        }
        clearCause()
        return LinuxClipboardReport(mechanism: mechanism, cause: nil)
    }

    // parity: native/src/clipboard/linux.zig#bounded [status=implemented hash=e1715594a68b]
    public static func bounded(_ message: String, maxBytes: Int = 256) -> String {
        let bytes = Array(message.utf8)
        if bytes.count <= maxBytes { return message }
        return String(decoding: bytes.prefix(maxBytes), as: UTF8.self)
    }

    // parity: native/src/clipboard/linux.zig#clearCause [status=implemented hash=ba734666444a]
    public static func clearCause() {
        state.withLock { $0.lastCause = nil }
    }

    // parity: native/src/clipboard/linux.zig#recordCause [status=implemented hash=7fdb29f44ee6]
    public static func recordCause(_ cause: String) {
        let trimmed = bounded(cause)
        state.withLock { s in
            s.lastCause = trimmed
            s.logEntries.append(trimmed)
        }
    }

    // parity: native/src/clipboard/linux.zig#reportUnavailable [status=implemented hash=aa99400c85ac]
    public static func reportUnavailable(_ reason: String) -> LinuxClipboardReport {
        recordCause(reason)
        return LinuxClipboardReport(mechanism: .unavailable, cause: bounded(reason))
    }

    // parity: native/src/clipboard/linux.zig#waylandSymbols [status=implemented hash=11004102ab4a]
    public static func waylandSymbols() -> LinuxWaylandSymbols {
        state.withLock { $0.waylandOverride ?? LinuxWaylandSymbols(available: PosixClipboardIO.getEnv("WAYLAND_DISPLAY") != nil) }
    }

    // parity: native/src/clipboard/linux.zig#xcbSymbols [status=implemented hash=4452ff31e078]
    public static func xcbSymbols() -> LinuxXcbSymbols {
        LinuxXcbSymbols(available: PosixClipboardIO.getEnv("DISPLAY") != nil)
    }

    // parity: native/src/clipboard/linux.zig#testCauseReport [status=adapted hash=38d9161d333d]
    public static func testCauseReport() -> String? {
        state.withLock { $0.lastCause }
    }

    // parity: native/src/clipboard/linux.zig#testSwapWaylandSymbols [status=adapted hash=587ac7f1216d]
    public static func testSwapWaylandSymbols(_ symbols: LinuxWaylandSymbols?) -> LinuxWaylandSymbols? {
        state.withLock { s in
            let prev = s.waylandOverride
            s.waylandOverride = symbols
            return prev
        }
    }
}

// ============================================================================
// MARK: - 8. macOS & Windows Job Models (`src/clipboard/macos.zig`, `windows.zig`)
// ============================================================================

// parity: native/src/clipboard/macos.zig#MimeType [status=implemented hash=40e52ee59d0f]
public enum MacOSClipboardMimeType: String, Equatable, Hashable, Sendable {
    case textPlain = "text/plain"
    case imagePng = "image/png"
    case imageJpeg = "image/jpeg"
    case imageTiff = "image/tiff"
}

// parity: native/src/clipboard/macos.zig#ReadJob [status=implemented hash=e9f1bf1b7281]
public struct MacOSClipboardReadJob: Equatable, Hashable, Sendable {
    public let preferredTypes: [String]
    public let maxBytes: Int
    public init(preferredTypes: [String], maxBytes: Int = Int(defaultClipboardMaxBytes)) {
        self.preferredTypes = preferredTypes
        self.maxBytes = maxBytes
    }
}

// parity: native/src/clipboard/macos.zig#WriteTextJob [status=implemented hash=d2b55d192152]
public struct MacOSClipboardWriteTextJob: Equatable, Hashable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

// parity: native/src/clipboard/macos.zig#Job [status=implemented hash=d23150bb254b]
public enum MacOSClipboardJob: Equatable, Hashable, Sendable {
    case read(MacOSClipboardReadJob)
    case writeText(MacOSClipboardWriteTextJob)
    case clear
}

// parity: native/src/clipboard/macos.zig#ReadResult [status=implemented hash=1bea1fd0c426]
public struct MacOSClipboardReadResult: Equatable, Hashable, Sendable {
    public let mimeType: String
    public let bytes: [UInt8]
    public init(mimeType: String, bytes: [UInt8]) { self.mimeType = mimeType; self.bytes = bytes }
}

// parity: native/src/clipboard/macos.zig#Status [status=implemented hash=b2205ed45273]
public enum MacOSClipboardStatus: UInt8, Equatable, Hashable, Sendable {
    case read = 1
    case empty = 2
    case written = 3
    case cleared = 4
    case unsupported = 5
    case cancelled = 6
    case timedOut = 7
    case limitExceeded = 8
    case failed = 9
}

// parity: native/src/clipboard/macos.zig#Result [status=implemented hash=f8491edaf0d6]
public struct MacOSClipboardResult: Equatable, Hashable, Sendable {
    public let status: MacOSClipboardStatus
    public let readResult: MacOSClipboardReadResult?
    public let diagnostic: String?
    public init(status: MacOSClipboardStatus, readResult: MacOSClipboardReadResult? = nil, diagnostic: String? = nil) {
        self.status = status
        self.readResult = readResult
        self.diagnostic = diagnostic
    }
}

// parity: native/src/clipboard/macos.zig#JobError [status=implemented hash=4b76a91295a3]
public enum MacOSClipboardJobError: Error, Equatable, Hashable, Sendable {
    case unsupportedPlatform
    case pasteboardUnavailable
    case executionFailed(String)
}

// parity: native/src/clipboard/macos.zig#ExecuteOptions [status=implemented hash=22610d194937]
public struct MacOSClipboardExecuteOptions: Sendable {
    public let timeoutMs: Int
    public let signal: ClipboardAbortSignal?
    public init(timeoutMs: Int = Int(defaultClipboardTimeoutMs), signal: ClipboardAbortSignal? = nil) {
        self.timeoutMs = timeoutMs
        self.signal = signal
    }
}

/// Executes a macOS clipboard job via `/usr/bin/pbpaste` and `/usr/bin/pbcopy` when running on macOS.
// parity: native/src/clipboard/macos.zig#runJob [status=implemented hash=11f3b6404445]
public func runMacOSClipboardJob(
    _ job: MacOSClipboardJob,
    options: MacOSClipboardExecuteOptions = MacOSClipboardExecuteOptions()
) -> MacOSClipboardResult {
    if options.signal?.isAborted == true {
        return MacOSClipboardResult(status: .cancelled)
    }
    #if os(macOS)
    switch job {
    case .read(let readJob):
        let wantsPlain = readJob.preferredTypes.contains { $0.lowercased() == "text/plain" }
        guard wantsPlain else {
            return MacOSClipboardResult(status: .empty)
        }
        do {
            let output = try PosixClipboardIO.runProcess(
                executablePath: "/usr/bin/pbpaste",
                arguments: ["-Prefer", "txt"],
                maxOutputBytes: readJob.maxBytes
            )
            if output.exceededOutputLimit {
                return MacOSClipboardResult(status: .limitExceeded)
            }
            guard output.exitCode == 0 else {
                return MacOSClipboardResult(status: .failed, diagnostic: "pbpaste exited with \(output.exitCode)")
            }
            if output.stdout.isEmpty {
                return MacOSClipboardResult(status: .empty)
            }
            return MacOSClipboardResult(
                status: .read,
                readResult: MacOSClipboardReadResult(mimeType: "text/plain", bytes: output.stdout)
            )
        } catch {
            return MacOSClipboardResult(status: .failed, diagnostic: error.description)
        }

    case .writeText(let writeJob):
        do {
            let output = try PosixClipboardIO.runProcess(
                executablePath: "/usr/bin/pbcopy",
                arguments: [],
                stdinBytes: Array(writeJob.text.utf8),
                maxOutputBytes: 4096
            )
            guard output.exitCode == 0 else {
                return MacOSClipboardResult(status: .failed, diagnostic: "pbcopy exited with \(output.exitCode)")
            }
            return MacOSClipboardResult(status: .written)
        } catch {
            return MacOSClipboardResult(status: .failed, diagnostic: error.description)
        }

    case .clear:
        do {
            let output = try PosixClipboardIO.runProcess(
                executablePath: "/usr/bin/pbcopy",
                arguments: [],
                stdinBytes: [],
                maxOutputBytes: 4096
            )
            guard output.exitCode == 0 else {
                return MacOSClipboardResult(status: .failed, diagnostic: "pbcopy clear exited with \(output.exitCode)")
            }
            return MacOSClipboardResult(status: .cleared)
        } catch {
            return MacOSClipboardResult(status: .failed, diagnostic: error.description)
        }
    }
    #else
    _ = job
    return MacOSClipboardResult(status: .unsupported, diagnostic: "macOS pasteboard is unavailable on this platform")
    #endif
}

// parity: native/src/clipboard/windows.zig#Status [status=implemented hash=5d8bf5656fb8]
public enum WindowsClipboardStatus: UInt8, Equatable, Hashable, Sendable {
    case read = 1
    case empty = 2
    case written = 3
    case cleared = 4
    case unsupported = 5
    case cancelled = 6
    case timedOut = 7
    case limitExceeded = 8
    case failed = 9
}

// parity: native/src/clipboard/windows.zig#Result [status=implemented hash=c46c96911ef8]
public struct WindowsClipboardResult: Equatable, Hashable, Sendable {
    public let status: WindowsClipboardStatus
    public let mimeType: String?
    public let bytes: [UInt8]
    public let diagnostic: String?
    public init(status: WindowsClipboardStatus, mimeType: String? = nil, bytes: [UInt8] = [], diagnostic: String? = nil) {
        self.status = status
        self.mimeType = mimeType
        self.bytes = bytes
        self.diagnostic = diagnostic
    }
}

// parity: native/src/clipboard/windows.zig#ReadJob [status=implemented hash=11bd54c34298]
public struct WindowsClipboardReadJob: Equatable, Hashable, Sendable {
    public let preferredTypes: [String]
    public let maxBytes: Int
    public let maxImagePixels: UInt32
    public let maxConversionBytes: UInt32
    public init(
        preferredTypes: [String],
        maxBytes: Int = Int(defaultClipboardMaxBytes),
        maxImagePixels: UInt32 = defaultClipboardMaxImagePixels,
        maxConversionBytes: UInt32 = defaultClipboardMaxConversionBytes
    ) {
        self.preferredTypes = preferredTypes
        self.maxBytes = maxBytes
        self.maxImagePixels = maxImagePixels
        self.maxConversionBytes = maxConversionBytes
    }
}

// parity: native/src/clipboard/windows.zig#Job [status=implemented hash=ca321a9d3c1a]
public enum WindowsClipboardJob: Equatable, Hashable, Sendable {
    case read(WindowsClipboardReadJob)
    case writeText(String)
    case clear
}

// parity: native/src/clipboard/windows.zig#ExecuteOptions [status=implemented hash=22610d194937]
public struct WindowsClipboardExecuteOptions: Sendable {
    public let timeoutMs: Int
    public let signal: ClipboardAbortSignal?
    public init(timeoutMs: Int = Int(defaultClipboardTimeoutMs), signal: ClipboardAbortSignal? = nil) {
        self.timeoutMs = timeoutMs
        self.signal = signal
    }
}

// parity: native/src/clipboard/windows.zig#InitError [status=implemented hash=8e4c3947b97b]
public enum WindowsClipboardInitError: Error, Equatable, Hashable, Sendable {
    case unsupportedPlatform
    case windowCreationFailed
    case workerUnavailable
}

// parity: native/src/clipboard/windows.zig#Worker [status=implemented hash=2b9edf0d4672]
public final class WindowsClipboardWorker: Sendable {
    private let disposed = Mutex<Bool>(false)

    public init() {}

    public func execute(_ job: WindowsClipboardJob, options: WindowsClipboardExecuteOptions = WindowsClipboardExecuteOptions()) -> WindowsClipboardResult {
        if disposed.withLock({ $0 }) {
            return WindowsClipboardResult(status: .failed, diagnostic: "Windows clipboard worker disposed")
        }
        if options.signal?.isAborted == true {
            return WindowsClipboardResult(status: .cancelled)
        }
        #if os(Windows)
        guard OpenClipboard(nil) else {
            return WindowsClipboardResult(status: .failed, diagnostic: "OpenClipboard failed: \(GetLastError())")
        }
        defer { CloseClipboard() }
        switch job {
        case .clear:
            return EmptyClipboard()
                ? WindowsClipboardResult(status: .cleared)
                : WindowsClipboardResult(status: .failed, diagnostic: "EmptyClipboard failed")
        case .writeText(let text):
            guard EmptyClipboard() else {
                return WindowsClipboardResult(status: .failed, diagnostic: "EmptyClipboard failed")
            }
            let utf16 = Array(text.utf16) + [0]
            let byteCount = SIZE_T(utf16.count * MemoryLayout<UInt16>.size)
            guard let hMem = GlobalAlloc(UINT(GMEM_MOVEABLE), byteCount) else {
                return WindowsClipboardResult(status: .failed, diagnostic: "GlobalAlloc failed")
            }
            guard let locked = GlobalLock(hMem) else {
                GlobalFree(hMem)
                return WindowsClipboardResult(status: .failed, diagnostic: "GlobalLock failed")
            }
            utf16.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    locked.copyMemory(from: src, byteCount: Int(byteCount))
                }
            }
            GlobalUnlock(hMem)
            if SetClipboardData(UINT(CF_UNICODETEXT), hMem) == nil {
                GlobalFree(hMem)
                return WindowsClipboardResult(status: .failed, diagnostic: "SetClipboardData failed")
            }
            return WindowsClipboardResult(status: .written)
        case .read(let readJob):
            for preferred in readJob.preferredTypes {
                let mime = preferred.lowercased()
                if mime == "text/plain", let handle = GetClipboardData(UINT(CF_UNICODETEXT)) {
                    guard let locked = GlobalLock(handle) else { continue }
                    defer { GlobalUnlock(handle) }
                    let u16Ptr = locked.assumingMemoryBound(to: UInt16.self)
                    var units: [UInt16] = []
                    var idx = 0
                    while u16Ptr[idx] != 0 {
                        units.append(u16Ptr[idx])
                        idx += 1
                    }
                    let decoded = String(decoding: units, as: UTF16.self)
                    let bytes = Array(decoded.utf8)
                    if bytes.count > readJob.maxBytes {
                        return WindowsClipboardResult(status: .limitExceeded)
                    }
                    return WindowsClipboardResult(status: .read, mimeType: "text/plain", bytes: bytes)
                }
                if mime == "image/png", let handle = GetClipboardData(UINT(CF_DIB)) {
                    let size = Int(GlobalSize(handle))
                    guard size > 0, let locked = GlobalLock(handle) else { continue }
                    defer { GlobalUnlock(handle) }
                    let dibBytes = Array(UnsafeBufferPointer(start: locked.assumingMemoryBound(to: UInt8.self), count: size))
                    let convOpts = WindowsDIBConvertOptions(
                        maxOutputBytes: UInt32(min(readJob.maxBytes, Int(UInt32.max))),
                        maxImagePixels: readJob.maxImagePixels,
                        maxConversionBytes: readJob.maxConversionBytes
                    )
                    if let png = try? WindowsDIBCodec.convertToPng(dibBytes, options: convOpts, cancelSignal: options.signal) {
                        return WindowsClipboardResult(status: .read, mimeType: "image/png", bytes: png)
                    }
                }
            }
            return WindowsClipboardResult(status: .empty)
        }
        #else
        _ = job
        return WindowsClipboardResult(status: .unsupported, diagnostic: "Win32 clipboard unavailable on this platform")
        #endif
    }

    public func dispose() {
        disposed.withLock { $0 = true }
    }
}

// ============================================================================
// MARK: - 9. Platform `HostClipboardBackend` Implementations
// ============================================================================

#if os(macOS)
/// Native macOS `HostClipboardBackend` using guarded POSIX `posix_spawn` + pipe I/O (`pbcopy`/`pbpaste`).
public final class MacOSHostClipboardBackend: HostClipboardBackend, Sendable {
    private let disposed = Mutex<Bool>(false)
    private let executor: @Sendable (MacOSClipboardJob, MacOSClipboardExecuteOptions) -> MacOSClipboardResult

    public init(
        executor: @escaping @Sendable (MacOSClipboardJob, MacOSClipboardExecuteOptions) -> MacOSClipboardResult = runMacOSClipboardJob
    ) {
        self.executor = executor
    }

    public func read(_ options: HostClipboardReadOptions) async throws -> ClipboardReadResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("MacOSHostClipboardBackend is disposed")
        }
        guard options.selection == .clipboard else {
            return .unsupported
        }
        if options.signal.isAborted { return .cancelled }
        let res = executor(
            .read(MacOSClipboardReadJob(preferredTypes: options.preferredTypes, maxBytes: options.maxBytes)),
            MacOSClipboardExecuteOptions(timeoutMs: options.timeoutMs, signal: options.signal)
        )
        switch res.status {
        case .read:
            if let read = res.readResult {
                return .read(ClipboardRepresentation(mimeType: read.mimeType, bytes: read.bytes))
            }
            return .empty
        case .empty: return .empty
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .limitExceeded: return .limitExceeded
        case .failed, .written, .cleared:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "macOS clipboard read failed"))
        }
    }

    public func writeText(_ text: String, options: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("MacOSHostClipboardBackend is disposed")
        }
        guard options.selection == .clipboard else {
            return .unsupported
        }
        if options.signal.isAborted { return .cancelled }
        let res = executor(
            .writeText(MacOSClipboardWriteTextJob(text: text)),
            MacOSClipboardExecuteOptions(timeoutMs: options.timeoutMs, signal: options.signal)
        )
        switch res.status {
        case .written: return .written
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "macOS clipboard write failed"))
        }
    }

    public func clear(_ options: HostClipboardWriteOptions) async throws -> HostClipboardClearResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("MacOSHostClipboardBackend is disposed")
        }
        guard options.selection == .clipboard else {
            return .unsupported
        }
        if options.signal.isAborted { return .cancelled }
        let res = executor(
            .clear,
            MacOSClipboardExecuteOptions(timeoutMs: options.timeoutMs, signal: options.signal)
        )
        switch res.status {
        case .cleared: return .cleared
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "macOS clipboard clear failed"))
        }
    }

    public func dispose() async throws {
        disposed.withLock { $0 = true }
    }
}
#endif

#if os(Linux) || os(FreeBSD) || os(Android)
/// Native Linux / FreeBSD / Android `HostClipboardBackend` with Wayland (`wl-copy`/`wl-paste`)
/// and X11 (`xclip`/`xsel`) detection & POSIX pipe I/O.
public final class LinuxHostClipboardBackend: HostClipboardBackend, Sendable {
    public let environment: LinuxClipboardEnvironment
    private let disposed = Mutex<Bool>(false)

    public init(environment: LinuxClipboardEnvironment = LinuxClipboardEnvironment()) {
        self.environment = environment
    }

    private func resolveExecutable(_ candidates: [String]) -> String? {
        for path in candidates {
            if (try? PosixClipboardIO.stat(path: path)) != nil {
                return path
            }
        }
        return nil
    }

    public func read(_ options: HostClipboardReadOptions) async throws -> ClipboardReadResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("LinuxHostClipboardBackend is disposed")
        }
        if options.signal.isAborted { return .cancelled }
        let mechanism = environment.preferredMechanism
        switch mechanism {
        case .wayland:
            guard let wlPaste = resolveExecutable(["/usr/bin/wl-paste", "/bin/wl-paste", "/usr/local/bin/wl-paste"]) else {
                return .unsupported
            }
            var args = ["--no-newline"]
            if options.selection == .primary { args.append("--primary") }
            if let seat = environment.waylandSeat { args.append(contentsOf: ["--seat", seat]) }
            let mime = options.preferredTypes.first ?? "text/plain"
            args.append(contentsOf: ["--type", mime])
            do {
                let res = try PosixClipboardIO.runProcess(executablePath: wlPaste, arguments: args, maxOutputBytes: options.maxBytes)
                if res.exceededOutputLimit { return .limitExceeded }
                if res.exitCode != 0 || res.stdout.isEmpty { return .empty }
                return .read(ClipboardRepresentation(mimeType: mime, bytes: res.stdout))
            } catch {
                return .failed(ClipboardFailure(message: error.description))
            }
        case .x11:
            if let xclip = resolveExecutable(["/usr/bin/xclip", "/bin/xclip", "/usr/local/bin/xclip"]) {
                let sel = options.selection == .primary ? "primary" : "clipboard"
                let mime = options.preferredTypes.first ?? "text/plain"
                let args = ["-o", "-selection", sel, "-t", mime == "text/plain" ? "UTF8_STRING" : mime]
                do {
                    let res = try PosixClipboardIO.runProcess(executablePath: xclip, arguments: args, maxOutputBytes: options.maxBytes)
                    if res.exceededOutputLimit { return .limitExceeded }
                    if res.exitCode != 0 || res.stdout.isEmpty { return .empty }
                    return .read(ClipboardRepresentation(mimeType: mime, bytes: res.stdout))
                } catch {
                    return .failed(ClipboardFailure(message: error.description))
                }
            }
            if let xsel = resolveExecutable(["/usr/bin/xsel", "/bin/xsel", "/usr/local/bin/xsel"]) {
                let selFlag = options.selection == .primary ? "--primary" : "--clipboard"
                do {
                    let res = try PosixClipboardIO.runProcess(executablePath: xsel, arguments: ["--output", selFlag], maxOutputBytes: options.maxBytes)
                    if res.exceededOutputLimit { return .limitExceeded }
                    if res.exitCode != 0 || res.stdout.isEmpty { return .empty }
                    return .read(ClipboardRepresentation(mimeType: "text/plain", bytes: res.stdout))
                } catch {
                    return .failed(ClipboardFailure(message: error.description))
                }
            }
            return .unsupported
        case .unavailable:
            return .unsupported
        }
    }

    public func writeText(_ text: String, options: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("LinuxHostClipboardBackend is disposed")
        }
        if options.signal.isAborted { return .cancelled }
        let bytes = Array(text.utf8)
        switch environment.preferredMechanism {
        case .wayland:
            guard let wlCopy = resolveExecutable(["/usr/bin/wl-copy", "/bin/wl-copy", "/usr/local/bin/wl-copy"]) else {
                return .unsupported
            }
            var args: [String] = []
            if options.selection == .primary { args.append("--primary") }
            if let seat = environment.waylandSeat { args.append(contentsOf: ["--seat", seat]) }
            do {
                let res = try PosixClipboardIO.runProcess(executablePath: wlCopy, arguments: args, stdinBytes: bytes, maxOutputBytes: 4096)
                return res.exitCode == 0 ? .written : .failed(ClipboardFailure(message: "wl-copy exited \(res.exitCode)"))
            } catch {
                return .failed(ClipboardFailure(message: error.description))
            }
        case .x11:
            if let xclip = resolveExecutable(["/usr/bin/xclip", "/bin/xclip", "/usr/local/bin/xclip"]) {
                let sel = options.selection == .primary ? "primary" : "clipboard"
                do {
                    let res = try PosixClipboardIO.runProcess(executablePath: xclip, arguments: ["-i", "-selection", sel], stdinBytes: bytes, maxOutputBytes: 4096)
                    return res.exitCode == 0 ? .written : .failed(ClipboardFailure(message: "xclip exited \(res.exitCode)"))
                } catch {
                    return .failed(ClipboardFailure(message: error.description))
                }
            }
            if let xsel = resolveExecutable(["/usr/bin/xsel", "/bin/xsel", "/usr/local/bin/xsel"]) {
                let selFlag = options.selection == .primary ? "--primary" : "--clipboard"
                do {
                    let res = try PosixClipboardIO.runProcess(executablePath: xsel, arguments: ["--input", selFlag], stdinBytes: bytes, maxOutputBytes: 4096)
                    return res.exitCode == 0 ? .written : .failed(ClipboardFailure(message: "xsel exited \(res.exitCode)"))
                } catch {
                    return .failed(ClipboardFailure(message: error.description))
                }
            }
            return .unsupported
        case .unavailable:
            return .unsupported
        }
    }

    public func clear(_ options: HostClipboardWriteOptions) async throws -> HostClipboardClearResult {
        if disposed.withLock({ $0 }) {
            throw HostClipboardError.disposed("LinuxHostClipboardBackend is disposed")
        }
        if options.signal.isAborted { return .cancelled }
        switch environment.preferredMechanism {
        case .wayland:
            guard let wlCopy = resolveExecutable(["/usr/bin/wl-copy", "/bin/wl-copy", "/usr/local/bin/wl-copy"]) else {
                return .unsupported
            }
            var args = ["--clear"]
            if options.selection == .primary { args.append("--primary") }
            if let seat = environment.waylandSeat { args.append(contentsOf: ["--seat", seat]) }
            do {
                let res = try PosixClipboardIO.runProcess(executablePath: wlCopy, arguments: args, maxOutputBytes: 4096)
                return res.exitCode == 0 ? .cleared : .failed(ClipboardFailure(message: "wl-copy --clear exited \(res.exitCode)"))
            } catch {
                return .failed(ClipboardFailure(message: error.description))
            }
        case .x11:
            let res = try await writeText("", options: options)
            switch res {
            case .written: return .cleared
            case .unsupported: return .unsupported
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .failed(let err): return .failed(err)
            }
        case .unavailable:
            return .unsupported
        }
    }

    public func dispose() async throws {
        disposed.withLock { $0 = true }
    }
}
#endif

#if os(Windows)
/// Native Windows `HostClipboardBackend` backed by `WindowsClipboardWorker` and `WindowsDIBCodec`.
public final class WindowsHostClipboardBackend: HostClipboardBackend, Sendable {
    private let worker = WindowsClipboardWorker()
    private let options: NormalizedHostClipboardOptions

    public init(options: NormalizedHostClipboardOptions = NormalizedHostClipboardOptions()) {
        self.options = options
    }

    public func read(_ readOptions: HostClipboardReadOptions) async throws -> ClipboardReadResult {
        guard readOptions.selection == .clipboard else { return .unsupported }
        let res = worker.execute(
            .read(WindowsClipboardReadJob(
                preferredTypes: readOptions.preferredTypes,
                maxBytes: readOptions.maxBytes,
                maxImagePixels: options.maxImagePixels,
                maxConversionBytes: options.maxConversionBytes
            )),
            options: WindowsClipboardExecuteOptions(timeoutMs: readOptions.timeoutMs, signal: readOptions.signal)
        )
        switch res.status {
        case .read:
            return .read(ClipboardRepresentation(mimeType: res.mimeType ?? "text/plain", bytes: res.bytes))
        case .empty: return .empty
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .limitExceeded: return .limitExceeded
        default:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "Windows clipboard read failed"))
        }
    }

    public func writeText(_ text: String, options writeOptions: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult {
        guard writeOptions.selection == .clipboard else { return .unsupported }
        let res = worker.execute(
            .writeText(text),
            options: WindowsClipboardExecuteOptions(timeoutMs: writeOptions.timeoutMs, signal: writeOptions.signal)
        )
        switch res.status {
        case .written: return .written
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "Windows clipboard write failed"))
        }
    }

    public func clear(_ writeOptions: HostClipboardWriteOptions) async throws -> HostClipboardClearResult {
        guard writeOptions.selection == .clipboard else { return .unsupported }
        let res = worker.execute(
            .clear,
            options: WindowsClipboardExecuteOptions(timeoutMs: writeOptions.timeoutMs, signal: writeOptions.signal)
        )
        switch res.status {
        case .cleared: return .cleared
        case .unsupported: return .unsupported
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default:
            return .failed(ClipboardFailure(message: res.diagnostic ?? "Windows clipboard clear failed"))
        }
    }

    public func dispose() async throws {
        worker.dispose()
    }
}
#endif

// ============================================================================
// MARK: - 10. Platform Host Clipboard Factory & Registry Installation
// ============================================================================

/// Creates the native OS `HostClipboardBackend` for the current compilation target,
/// falling back to `InMemoryHostClipboardBackend` on headless/embedded targets (iOS/WASI).
public enum PlatformHostClipboardFactory {
    public static func createPlatformHostClipboardBackend(
        _ options: NormalizedHostClipboardOptions = NormalizedHostClipboardOptions()
    ) -> any HostClipboardBackend {
        #if os(macOS)
        _ = options
        return MacOSHostClipboardBackend()
        #elseif os(Linux) || os(FreeBSD) || os(Android)
        let env = LinuxClipboardEnvironment(waylandSeat: options.waylandSeat)
        return LinuxHostClipboardBackend(environment: env)
        #elseif os(Windows)
        return WindowsHostClipboardBackend(options: options)
        #else
        _ = options
        return InMemoryHostClipboardBackend()
        #endif
    }
}

/// Registers the platform OS clipboard backend factory into `NativeHostClipboardBackendRegistry`.
public func installPlatformHostClipboard(
    factory: HostClipboardBackendFactory? = nil
) {
    if let factory {
        NativeHostClipboardBackendRegistry.register(factory)
    } else {
        NativeHostClipboardBackendRegistry.register { options in
            PlatformHostClipboardFactory.createPlatformHostClipboardBackend(options)
        }
    }
}

/// Removes any registered platform host clipboard factory, restoring default fallback behavior.
public func uninstallPlatformHostClipboard() {
    NativeHostClipboardBackendRegistry.register(nil)
}

// ============================================================================
// MARK: - 11. Host Clipboard Service & ABI Layer (`src/clipboard/host.zig`, `src/clipboard-abi.zig`)
// ============================================================================

// parity: native/src/clipboard/host.zig#Handle [status=implemented hash=60613aa7ce8b]
public struct HostClipboardHandle: Equatable, Hashable, Sendable, Codable {
    public let contextId: UInt64
    public let slot: UInt32
    public let generation: UInt32

    public static let invalid = HostClipboardHandle(contextId: 0, slot: 0, generation: 0)

    public init(contextId: UInt64, slot: UInt32, generation: UInt32) {
        self.contextId = contextId
        self.slot = slot
        self.generation = generation
    }
}

// parity: native/src/clipboard/host.zig#OperationStatus [status=implemented hash=4ac25c4f4ea4]
public enum HostClipboardOperationStatus: UInt8, Equatable, Hashable, Sendable {
    case pending = 0
    case read = 1
    case empty = 2
    case written = 3
    case cleared = 4
    case unsupported = 5
    case cancelled = 6
    case timedOut = 7
    case limitExceeded = 8
    case failed = 9
    case invalidHandle = 10
}

// parity: native/src/clipboard/host.zig#StartStatus [status=implemented hash=93458efb1d7b]
public enum HostClipboardStartStatus: UInt8, Equatable, Hashable, Sendable {
    case ok = 0
    case invalidService = 1
    case shuttingDown = 2
    case limitExceeded = 3
    case invalidArgument = 4
    case outOfMemory = 5
}

// parity: native/src/clipboard/host.zig#CancelStatus [status=implemented hash=dc57dbeffbf9]
public enum HostClipboardCancelStatus: UInt8, Equatable, Hashable, Sendable {
    case requested = 0
    case alreadyTerminal = 1
    case invalidHandle = 2
}

// parity: native/src/clipboard/host.zig#CopyStatus [status=implemented hash=bea99216ef48]
public enum HostClipboardCopyStatus: UInt8, Equatable, Hashable, Sendable {
    case ok = 0
    case bufferTooSmall = 1
    case invalidHandle = 2
    case invalidState = 3
    case invalidArgument = 4
}

// parity: native/src/clipboard/host.zig#DestroyStatus [status=implemented hash=763a7e795ae7]
public enum HostClipboardDestroyStatus: UInt8, Equatable, Hashable, Sendable {
    case destroyed = 0
    case notReady = 1
    case invalidHandle = 2
}

// parity: native/src/clipboard/host.zig#ShutdownStatus [status=implemented hash=581b084c8284]
public enum HostClipboardShutdownStatus: UInt8, Equatable, Hashable, Sendable {
    case pending = 0
    case ready = 1
    case invalidHandle = 2
}

/// Stateful handle-addressed clipboard operation record matching `src/clipboard/host.zig#Operation`.
// parity: native/src/clipboard/host.zig#Operation [status=implemented hash=c974886b2992]
public final class HostClipboardOperation: Sendable {
    private struct State: Sendable {
        var status: HostClipboardOperationStatus = .pending
        var mime: [UInt8] = []
        var data: [UInt8] = []
        var diagnostic: [UInt8] = []
        var errorCode: UInt32 = 0
    }

    public let handle: HostClipboardHandle
    public let abortController = ClipboardAbortController()
    private let state = Mutex(State())

    public init(handle: HostClipboardHandle) {
        self.handle = handle
    }

    public var status: HostClipboardOperationStatus {
        state.withLock { $0.status }
    }

    public var isTerminal: Bool {
        status != .pending
    }

    public func complete(
        status: HostClipboardOperationStatus,
        mime: String = "",
        data: [UInt8] = [],
        errorCode: UInt32 = 0,
        diagnostic: String = ""
    ) {
        state.withLock { s in
            guard s.status == .pending else { return }
            s.status = status
            s.mime = Array(mime.utf8)
            s.data = data
            s.errorCode = errorCode
            s.diagnostic = Array(diagnostic.utf8)
        }
    }

    public func cancel() -> HostClipboardCancelStatus {
        abortController.abort(reason: "Cancelled")
        return state.withLock { s in
            if s.status != .pending {
                return .alreadyTerminal
            }
            s.status = .cancelled
            return .requested
        }
    }

    public var mimeBytes: [UInt8] { state.withLock { $0.mime } }
    public var dataBytes: [UInt8] { state.withLock { $0.data } }
    public var diagnosticBytes: [UInt8] { state.withLock { $0.diagnostic } }
    public var errorCode: UInt32 { state.withLock { $0.errorCode } }
}

/// Handle-table-managed native clipboard service matching `src/clipboard/host.zig#Service`.
// parity: native/src/clipboard/host.zig#Service [status=implemented hash=d07762b3d171]
public final class HostClipboardNativeService: Sendable {
    private struct State: Sendable {
        var shuttingDown: Bool = false
        var destroyed: Bool = false
        var nextSlot: UInt32 = 1
        var operations: [HostClipboardHandle: HostClipboardOperation] = [:]
    }

    public let contextId: UInt64
    public let handle: HostClipboardHandle
    public let maxOperations: UInt32
    public let maxProviderTransfers: UInt32
    public let waylandSeat: String?
    public let backend: any HostClipboardBackend
    private let state = Mutex(State())

    public init(
        contextId: UInt64,
        slot: UInt32 = 1,
        maxOperations: UInt32 = defaultClipboardMaxConcurrentOperations,
        maxProviderTransfers: UInt32 = defaultClipboardMaxProviderTransfers,
        waylandSeat: String? = nil,
        backend: (any HostClipboardBackend)? = nil
    ) {
        self.contextId = contextId
        self.handle = HostClipboardHandle(contextId: contextId, slot: slot, generation: 1)
        self.maxOperations = max(1, maxOperations)
        self.maxProviderTransfers = max(1, maxProviderTransfers)
        self.waylandSeat = waylandSeat
        self.backend = backend ?? InMemoryHostClipboardBackend()
    }

    fileprivate enum OperationAllocation {
        case success(HostClipboardOperation)
        case failure(HostClipboardStartStatus)
    }

    fileprivate func allocateOperation() -> OperationAllocation {
        state.withLock { s in
            if s.destroyed { return .failure(.invalidService) }
            if s.shuttingDown { return .failure(.shuttingDown) }
            if s.operations.count >= Int(maxOperations) { return .failure(.limitExceeded) }
            let slot = s.nextSlot
            s.nextSlot &+= 1
            let opHandle = HostClipboardHandle(contextId: contextId, slot: slot, generation: 1)
            let op = HostClipboardOperation(handle: opHandle)
            s.operations[opHandle] = op
            return .success(op)
        }
    }

    fileprivate func operation(for opHandle: HostClipboardHandle) -> HostClipboardOperation? {
        state.withLock { $0.operations[opHandle] }
    }

    fileprivate func removeOperation(_ opHandle: HostClipboardHandle) -> HostClipboardDestroyStatus {
        state.withLock { s in
            guard let op = s.operations[opHandle] else { return .invalidHandle }
            if !op.isTerminal { return .notReady }
            s.operations.removeValue(forKey: opHandle)
            return .destroyed
        }
    }

    fileprivate func beginShutdown() -> HostClipboardShutdownStatus {
        let ops: [HostClipboardOperation] = state.withLock { s in
            s.shuttingDown = true
            return Array(s.operations.values)
        }
        for op in ops {
            _ = op.cancel()
        }
        return pollShutdown()
    }

    fileprivate func pollShutdown() -> HostClipboardShutdownStatus {
        state.withLock { s in
            if s.destroyed { return .invalidHandle }
            let allDone = s.operations.values.allSatisfy(\.isTerminal)
            return allDone ? .ready : .pending
        }
    }

    fileprivate func drain() -> UInt8 {
        let ops: [HostClipboardOperation] = state.withLock { Array($0.operations.values) }
        for op in ops {
            _ = op.cancel()
        }
        state.withLock { s in
            s.operations.removeAll()
        }
        return 0
    }

    fileprivate func destroy() -> HostClipboardDestroyStatus {
        state.withLock { s in
            if s.destroyed { return .invalidHandle }
            if !s.operations.isEmpty { return .notReady }
            s.destroyed = true
            return .destroyed
        }
    }
}

/// Complete host clipboard service + C-ABI dispatcher matching `src/clipboard/host.zig` and `src/clipboard-abi.zig`.
public final class HostClipboardNativeABI: Sendable {
    private struct RegistryState: Sendable {
        var servicesByContext: [UInt64: HostClipboardNativeService] = [:]
    }

    private let registry = Mutex(RegistryState())
    private let backendFactory: @Sendable (NormalizedHostClipboardOptions) -> any HostClipboardBackend

    public init(
        backendFactory: @escaping @Sendable (NormalizedHostClipboardOptions) -> any HostClipboardBackend = { opts in
            (try? createNativeHostClipboardBackend(opts)) ?? InMemoryHostClipboardBackend()
        }
    ) {
        self.backendFactory = backendFactory
    }

    private func service(for contextId: UInt64) -> HostClipboardNativeService? {
        registry.withLock { $0.servicesByContext[contextId] }
    }

    private func parseSelection(_ raw: UInt8) -> ClipboardSelection? {
        switch raw {
        case 0: return .clipboard
        case 1: return .primary
        default: return nil
        }
    }

    // MARK: - Core `host.zig` functions

    // parity: native/src/clipboard/host.zig#createService [status=implemented hash=4a8149d43f5e]
    public func createService(
        contextId: UInt64,
        maxOperations: UInt32 = defaultClipboardMaxConcurrentOperations,
        maxProviderTransfers: UInt32 = defaultClipboardMaxProviderTransfers,
        waylandSeat: String? = nil
    ) -> HostClipboardHandle? {
        let opts = NormalizedHostClipboardOptions(
            maxConcurrentOperations: max(1, maxOperations),
            maxProviderTransfers: max(1, maxProviderTransfers),
            waylandSeat: waylandSeat
        )
        let backend = backendFactory(opts)
        return registry.withLock { s -> HostClipboardHandle? in
            if s.servicesByContext[contextId] != nil { return nil }
            let svc = HostClipboardNativeService(
                contextId: contextId,
                maxOperations: maxOperations,
                maxProviderTransfers: maxProviderTransfers,
                waylandSeat: waylandSeat,
                backend: backend
            )
            s.servicesByContext[contextId] = svc
            return svc.handle
        }
    }

    // parity: native/src/clipboard/host.zig#startReadOperation [status=implemented hash=4a8ca5072a47]
    public func startReadOperation(
        contextId: UInt64,
        preferredTypes: [String],
        selection rawSelection: UInt8,
        maxBytes: UInt32,
        maxImagePixels: UInt32 = defaultClipboardMaxImagePixels,
        maxConversionBytes: UInt32 = defaultClipboardMaxConversionBytes,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs
    ) -> (status: HostClipboardStartStatus, handle: HostClipboardHandle?) {
        _ = (maxImagePixels, maxConversionBytes)
        guard let svc = service(for: contextId) else { return (.invalidService, nil) }
        guard let selection = parseSelection(rawSelection), !preferredTypes.isEmpty else {
            return (.invalidArgument, nil)
        }
        switch svc.allocateOperation() {
        case .failure(let err):
            return (err, nil)
        case .success(let op):
            let backend = svc.backend
            let signal = op.abortController.signal
            if let mem = backend as? InMemoryHostClipboardBackend {
                // Fast synchronous path for deterministic in-memory backends.
                for mime in preferredTypes {
                    if let rep = mem.storedRepresentation(mimeType: mime, selection: selection) {
                        if rep.bytes.count > Int(maxBytes) {
                            op.complete(status: .limitExceeded)
                        } else {
                            op.complete(status: .read, mime: rep.mimeType, data: rep.bytes)
                        }
                        return (.ok, op.handle)
                    }
                }
                op.complete(status: .empty)
                return (.ok, op.handle)
            }
            Task {
                do {
                    let result = try await backend.read(HostClipboardReadOptions(
                        preferredTypes: preferredTypes,
                        selection: selection,
                        maxBytes: Int(maxBytes),
                        timeoutMs: Int(timeoutMs),
                        signal: signal
                    ))
                    switch result {
                    case .read(let rep):
                        op.complete(status: .read, mime: rep.mimeType, data: rep.bytes)
                    case .empty: op.complete(status: .empty)
                    case .unsupported: op.complete(status: .unsupported)
                    case .cancelled: op.complete(status: .cancelled)
                    case .timedOut: op.complete(status: .timedOut)
                    case .limitExceeded: op.complete(status: .limitExceeded)
                    case .failed(let err):
                        op.complete(status: .failed, errorCode: UInt32(bitPattern: err.code ?? 1), diagnostic: err.message)
                    }
                } catch {
                    op.complete(status: .failed, errorCode: 1, diagnostic: String(describing: error))
                }
            }
            return (.ok, op.handle)
        }
    }

    // parity: native/src/clipboard/host.zig#startWriteOperation [status=implemented hash=1166e6a96d65]
    public func startWriteOperation(
        contextId: UInt64,
        text: String,
        selection rawSelection: UInt8,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs
    ) -> (status: HostClipboardStartStatus, handle: HostClipboardHandle?) {
        guard let svc = service(for: contextId) else { return (.invalidService, nil) }
        guard let selection = parseSelection(rawSelection), !text.isEmpty else {
            return (.invalidArgument, nil)
        }
        switch svc.allocateOperation() {
        case .failure(let err):
            return (err, nil)
        case .success(let op):
            let backend = svc.backend
            let signal = op.abortController.signal
            if let mem = backend as? InMemoryHostClipboardBackend {
                mem.setRepresentation(ClipboardRepresentation(mimeType: "text/plain", bytes: Array(text.utf8)), selection: selection)
                op.complete(status: .written)
                return (.ok, op.handle)
            }
            Task {
                do {
                    let res = try await backend.writeText(
                        text,
                        options: HostClipboardWriteOptions(selection: selection, timeoutMs: Int(timeoutMs), signal: signal)
                    )
                    switch res {
                    case .written: op.complete(status: .written)
                    case .unsupported: op.complete(status: .unsupported)
                    case .cancelled: op.complete(status: .cancelled)
                    case .timedOut: op.complete(status: .timedOut)
                    case .failed(let err):
                        op.complete(status: .failed, errorCode: UInt32(bitPattern: err.code ?? 1), diagnostic: err.message)
                    }
                } catch {
                    op.complete(status: .failed, errorCode: 1, diagnostic: String(describing: error))
                }
            }
            return (.ok, op.handle)
        }
    }

    // parity: native/src/clipboard/host.zig#startClearOperation [status=implemented hash=c39d35f72c4b]
    public func startClearOperation(
        contextId: UInt64,
        selection rawSelection: UInt8,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs
    ) -> (status: HostClipboardStartStatus, handle: HostClipboardHandle?) {
        guard let svc = service(for: contextId) else { return (.invalidService, nil) }
        guard let selection = parseSelection(rawSelection) else {
            return (.invalidArgument, nil)
        }
        switch svc.allocateOperation() {
        case .failure(let err):
            return (err, nil)
        case .success(let op):
            let backend = svc.backend
            let signal = op.abortController.signal
            Task {
                do {
                    let res = try await backend.clear(
                        HostClipboardWriteOptions(selection: selection, timeoutMs: Int(timeoutMs), signal: signal)
                    )
                    switch res {
                    case .cleared: op.complete(status: .cleared)
                    case .unsupported: op.complete(status: .unsupported)
                    case .cancelled: op.complete(status: .cancelled)
                    case .timedOut: op.complete(status: .timedOut)
                    case .failed(let err):
                        op.complete(status: .failed, errorCode: UInt32(bitPattern: err.code ?? 1), diagnostic: err.message)
                    }
                } catch {
                    op.complete(status: .failed, errorCode: 1, diagnostic: String(describing: error))
                }
            }
            return (.ok, op.handle)
        }
    }

    // parity: native/src/clipboard/host.zig#pollOperation [status=implemented hash=72ce058ea451]
    public func pollOperation(_ handle: HostClipboardHandle) -> HostClipboardOperationStatus {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return .invalidHandle
        }
        return op.status
    }

    // parity: native/src/clipboard/host.zig#cancelOperation [status=implemented hash=920affbfa934]
    public func cancelOperation(_ handle: HostClipboardHandle) -> HostClipboardCancelStatus {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return .invalidHandle
        }
        return op.cancel()
    }

    // parity: native/src/clipboard/host.zig#resultMimeLength [status=implemented hash=c563b30922c3]
    public func resultMimeLength(_ handle: HostClipboardHandle) -> (status: HostClipboardCopyStatus, length: UInt32) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, 0)
        }
        guard op.status == .read else { return (.invalidState, 0) }
        return (.ok, UInt32(op.mimeBytes.count))
    }

    // parity: native/src/clipboard/host.zig#resultMimeCopy [status=implemented hash=644ffd44d0d4]
    public func resultMimeCopy(_ handle: HostClipboardHandle, capacity: Int) -> (status: HostClipboardCopyStatus, bytes: [UInt8]) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, [])
        }
        guard op.status == .read else { return (.invalidState, []) }
        let bytes = op.mimeBytes
        guard capacity >= bytes.count else { return (.bufferTooSmall, []) }
        return (.ok, bytes)
    }

    // parity: native/src/clipboard/host.zig#resultDataLength [status=implemented hash=4d45dd55eaab]
    public func resultDataLength(_ handle: HostClipboardHandle) -> (status: HostClipboardCopyStatus, length: UInt32) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, 0)
        }
        guard op.status == .read else { return (.invalidState, 0) }
        return (.ok, UInt32(op.dataBytes.count))
    }

    // parity: native/src/clipboard/host.zig#resultDataCopy [status=implemented hash=49542bc3a4a9]
    public func resultDataCopy(_ handle: HostClipboardHandle, capacity: Int) -> (status: HostClipboardCopyStatus, bytes: [UInt8]) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, [])
        }
        guard op.status == .read else { return (.invalidState, []) }
        let bytes = op.dataBytes
        guard capacity >= bytes.count else { return (.bufferTooSmall, []) }
        return (.ok, bytes)
    }

    // parity: native/src/clipboard/host.zig#resultErrorCode [status=implemented hash=b6a7d5bad9e6]
    public func resultErrorCode(_ handle: HostClipboardHandle) -> (status: HostClipboardCopyStatus, code: UInt32) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, 0)
        }
        guard op.status == .failed else { return (.invalidState, 0) }
        return (.ok, op.errorCode)
    }

    // parity: native/src/clipboard/host.zig#resultDiagnosticLength [status=implemented hash=ee0c0669ab4a]
    public func resultDiagnosticLength(_ handle: HostClipboardHandle) -> (status: HostClipboardCopyStatus, length: UInt32) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, 0)
        }
        guard op.status == .failed else { return (.invalidState, 0) }
        return (.ok, UInt32(op.diagnosticBytes.count))
    }

    // parity: native/src/clipboard/host.zig#resultDiagnosticCopy [status=implemented hash=7adc88d78876]
    public func resultDiagnosticCopy(_ handle: HostClipboardHandle, capacity: Int) -> (status: HostClipboardCopyStatus, bytes: [UInt8]) {
        guard let svc = service(for: handle.contextId), let op = svc.operation(for: handle) else {
            return (.invalidHandle, [])
        }
        guard op.status == .failed else { return (.invalidState, []) }
        let bytes = op.diagnosticBytes
        guard capacity >= bytes.count else { return (.bufferTooSmall, []) }
        return (.ok, bytes)
    }

    // parity: native/src/clipboard/host.zig#destroyOperation [status=implemented hash=a14541ae697e]
    public func destroyOperation(_ handle: HostClipboardHandle) -> HostClipboardDestroyStatus {
        guard let svc = service(for: handle.contextId) else { return .invalidHandle }
        return svc.removeOperation(handle)
    }

    // parity: native/src/clipboard/host.zig#beginServiceShutdown [status=implemented hash=bccf1f2b7143]
    public func beginServiceShutdown(contextId: UInt64) -> HostClipboardShutdownStatus {
        guard let svc = service(for: contextId) else { return .invalidHandle }
        return svc.beginShutdown()
    }

    // parity: native/src/clipboard/host.zig#pollServiceShutdown [status=implemented hash=2a03c5a376ab]
    public func pollServiceShutdown(contextId: UInt64) -> HostClipboardShutdownStatus {
        guard let svc = service(for: contextId) else { return .invalidHandle }
        return svc.pollShutdown()
    }

    // parity: native/src/clipboard/host.zig#destroyService [status=implemented hash=47feed366224]
    public func destroyService(contextId: UInt64) -> HostClipboardDestroyStatus {
        registry.withLock { s in
            guard let svc = s.servicesByContext[contextId] else { return .invalidHandle }
            let status = svc.destroy()
            if status == .destroyed {
                s.servicesByContext.removeValue(forKey: contextId)
            }
            return status
        }
    }

    // parity: native/src/clipboard/host.zig#drainService [status=implemented hash=2c7674e50969]
    public func drainService(contextId: UInt64) -> UInt8 {
        guard let svc = service(for: contextId) else { return 2 }
        return svc.drain()
    }

    // MARK: - C-ABI Surface (`src/clipboard-abi.zig`)

    // parity: native/src/clipboard-abi.zig#ot_clipboard_service_create [status=implemented hash=ba96a9a3ff38]
    public func ot_clipboard_service_create(
        contextId: UInt64,
        maxOperations: UInt32 = defaultClipboardMaxConcurrentOperations,
        maxProviderTransfers: UInt32 = defaultClipboardMaxProviderTransfers,
        waylandSeat: String? = nil
    ) -> Int32 {
        createService(
            contextId: contextId,
            maxOperations: maxOperations,
            maxProviderTransfers: maxProviderTransfers,
            waylandSeat: waylandSeat
        ) != nil ? 0 : -1
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_service_begin_shutdown [status=implemented hash=0da9d1e41e8a]
    public func ot_clipboard_service_begin_shutdown(contextId: UInt64) -> UInt8 {
        beginServiceShutdown(contextId: contextId).rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_service_poll_shutdown [status=implemented hash=0db190974346]
    public func ot_clipboard_service_poll_shutdown(contextId: UInt64) -> UInt8 {
        pollServiceShutdown(contextId: contextId).rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_service_destroy [status=implemented hash=42bb5e187620]
    public func ot_clipboard_service_destroy(contextId: UInt64) -> UInt8 {
        destroyService(contextId: contextId).rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_service_drain [status=implemented hash=5534f7729df0]
    public func ot_clipboard_service_drain(contextId: UInt64) -> UInt8 {
        drainService(contextId: contextId)
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_read_operation_start [status=implemented hash=2cbbdbd7fe4b]
    public func ot_clipboard_read_operation_start(
        contextId: UInt64,
        preferredTypes: [String],
        selection: UInt8,
        maxBytes: UInt32,
        maxImagePixels: UInt32 = defaultClipboardMaxImagePixels,
        maxConversionBytes: UInt32 = defaultClipboardMaxConversionBytes,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs,
        outOperation: inout HostClipboardHandle
    ) -> UInt8 {
        let res = startReadOperation(
            contextId: contextId,
            preferredTypes: preferredTypes,
            selection: selection,
            maxBytes: maxBytes,
            maxImagePixels: maxImagePixels,
            maxConversionBytes: maxConversionBytes,
            timeoutMs: timeoutMs
        )
        if let h = res.handle { outOperation = h }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_write_operation_start [status=implemented hash=40d5190958ac]
    public func ot_clipboard_write_operation_start(
        contextId: UInt64,
        text: String,
        selection: UInt8,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs,
        outOperation: inout HostClipboardHandle
    ) -> UInt8 {
        let res = startWriteOperation(contextId: contextId, text: text, selection: selection, timeoutMs: timeoutMs)
        if let h = res.handle { outOperation = h }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_clear_operation_start [status=implemented hash=cacdbda31df1]
    public func ot_clipboard_clear_operation_start(
        contextId: UInt64,
        selection: UInt8,
        timeoutMs: UInt32 = defaultClipboardTimeoutMs,
        outOperation: inout HostClipboardHandle
    ) -> UInt8 {
        let res = startClearOperation(contextId: contextId, selection: selection, timeoutMs: timeoutMs)
        if let h = res.handle { outOperation = h }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_poll [status=implemented hash=2ffa59e2d128]
    public func ot_clipboard_operation_poll(_ operation: HostClipboardHandle) -> UInt8 {
        pollOperation(operation).rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_cancel [status=implemented hash=3cf69c12da17]
    public func ot_clipboard_operation_cancel(_ operation: HostClipboardHandle) -> UInt8 {
        cancelOperation(operation).rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_mime_length [status=implemented hash=04a5350b82bf]
    public func ot_clipboard_operation_result_mime_length(_ operation: HostClipboardHandle, outLength: inout UInt32) -> UInt8 {
        let res = resultMimeLength(operation)
        outLength = res.length
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_mime_copy [status=implemented hash=05bf649df45b]
    public func ot_clipboard_operation_result_mime_copy(_ operation: HostClipboardHandle, capacity: Int, outBytes: inout [UInt8]) -> UInt8 {
        let res = resultMimeCopy(operation, capacity: capacity)
        if res.status == .ok { outBytes = res.bytes }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_data_length [status=implemented hash=6db5989f98fc]
    public func ot_clipboard_operation_result_data_length(_ operation: HostClipboardHandle, outLength: inout UInt32) -> UInt8 {
        let res = resultDataLength(operation)
        outLength = res.length
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_data_copy [status=implemented hash=d1906e661a17]
    public func ot_clipboard_operation_result_data_copy(_ operation: HostClipboardHandle, capacity: Int, outBytes: inout [UInt8]) -> UInt8 {
        let res = resultDataCopy(operation, capacity: capacity)
        if res.status == .ok { outBytes = res.bytes }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_error_code [status=implemented hash=6b8b45b72df4]
    public func ot_clipboard_operation_result_error_code(_ operation: HostClipboardHandle, outCode: inout UInt32) -> UInt8 {
        let res = resultErrorCode(operation)
        outCode = res.code
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_diagnostic_length [status=implemented hash=43a995d9f756]
    public func ot_clipboard_operation_result_diagnostic_length(_ operation: HostClipboardHandle, outLength: inout UInt32) -> UInt8 {
        let res = resultDiagnosticLength(operation)
        outLength = res.length
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_result_diagnostic_copy [status=implemented hash=7834f3dd065e]
    public func ot_clipboard_operation_result_diagnostic_copy(_ operation: HostClipboardHandle, capacity: Int, outBytes: inout [UInt8]) -> UInt8 {
        let res = resultDiagnosticCopy(operation, capacity: capacity)
        if res.status == .ok { outBytes = res.bytes }
        return res.status.rawValue
    }

    // parity: native/src/clipboard-abi.zig#ot_clipboard_operation_destroy [status=implemented hash=836e69722bc3]
    public func ot_clipboard_operation_destroy(_ operation: HostClipboardHandle) -> UInt8 {
        destroyOperation(operation).rawValue
    }
}
