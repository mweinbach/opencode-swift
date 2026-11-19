import OpenTUICore
import OpenTUIKeymap
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

// MARK: - POSIX SIGWINCH Self-Pipe Coordinator

#if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))

/// Fixed lock-free atomic slots storing active `SIGWINCH` self-pipe write descriptors (`-1` when unused).
/// Value-type `Atomic<Int32>` globals require zero heap allocation, zero ARC traffic, and zero locking,
/// making them strictly async-signal-safe inside the `@convention(c)` POSIX signal handler.
private let sigwinchWriteSlot0 = Atomic<Int32>(-1)
private let sigwinchWriteSlot1 = Atomic<Int32>(-1)
private let sigwinchWriteSlot2 = Atomic<Int32>(-1)
private let sigwinchWriteSlot3 = Atomic<Int32>(-1)
private let sigwinchWriteSlot4 = Atomic<Int32>(-1)
private let sigwinchWriteSlot5 = Atomic<Int32>(-1)
private let sigwinchWriteSlot6 = Atomic<Int32>(-1)
private let sigwinchWriteSlot7 = Atomic<Int32>(-1)

private let sigwinchSlotCount = 8

private func storeSigwinchWriteSlot(_ index: Int, fd: Int32) {
    switch index {
    case 0: sigwinchWriteSlot0.store(fd, ordering: .releasing)
    case 1: sigwinchWriteSlot1.store(fd, ordering: .releasing)
    case 2: sigwinchWriteSlot2.store(fd, ordering: .releasing)
    case 3: sigwinchWriteSlot3.store(fd, ordering: .releasing)
    case 4: sigwinchWriteSlot4.store(fd, ordering: .releasing)
    case 5: sigwinchWriteSlot5.store(fd, ordering: .releasing)
    case 6: sigwinchWriteSlot6.store(fd, ordering: .releasing)
    case 7: sigwinchWriteSlot7.store(fd, ordering: .releasing)
    default: break
    }
}

private func writeSigwinchWakeByte(_ fd: Int32) {
    guard fd >= 0 else { return }
    var byte: UInt8 = 1
    #if os(macOS)
    _ = Darwin.write(fd, &byte, 1)
    #elseif canImport(Glibc)
    _ = Glibc.write(fd, &byte, 1)
    #elseif canImport(Musl)
    _ = Musl.write(fd, &byte, 1)
    #endif
}

private let sigwinchSignalHandler: @convention(c) (Int32) -> Void = { _ in
    let savedErrno = errno
    writeSigwinchWakeByte(sigwinchWriteSlot0.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot1.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot2.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot3.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot4.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot5.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot6.load(ordering: .acquiring))
    writeSigwinchWakeByte(sigwinchWriteSlot7.load(ordering: .acquiring))
    errno = savedErrno
}

private struct SavedSigAction: @unchecked Sendable {
    var value: sigaction
}

private final class SigwinchCoordinator: Sendable {
    static let shared = SigwinchCoordinator()

    private struct State: Sendable {
        var occupied: [Bool] = Array(repeating: false, count: sigwinchSlotCount)
        var activeCount: Int = 0
        var previousAction: SavedSigAction? = nil
    }

    private let state = Mutex(State())

    func register(writeFD: Int32) -> Int? {
        guard writeFD >= 0 else { return nil }
        return state.withLock { s in
            guard let slot = s.occupied.firstIndex(of: false) else {
                return nil
            }
            s.occupied[slot] = true
            storeSigwinchWriteSlot(slot, fd: writeFD)
            if s.activeCount == 0 {
                var oldAction = sigaction()
                #if os(macOS) || os(FreeBSD)
                var newAction = sigaction()
                newAction.__sigaction_u.__sa_handler = sigwinchSignalHandler
                sigemptyset(&newAction.sa_mask)
                newAction.sa_flags = SA_RESTART
                if sigaction(SIGWINCH, &newAction, &oldAction) == 0 {
                    s.previousAction = SavedSigAction(value: oldAction)
                }
                #elseif os(Linux)
                if sigaction(SIGWINCH, nil, &oldAction) == 0 {
                    s.previousAction = SavedSigAction(value: oldAction)
                }
                #if canImport(Glibc)
                _ = Glibc.signal(SIGWINCH, sigwinchSignalHandler)
                #elseif canImport(Musl)
                _ = Musl.signal(SIGWINCH, sigwinchSignalHandler)
                #endif
                #endif
            }
            s.activeCount += 1
            return slot
        }
    }

    func unregister(slot: Int) {
        guard slot >= 0 && slot < sigwinchSlotCount else { return }
        state.withLock { s in
            guard s.occupied[slot] else { return }
            storeSigwinchWriteSlot(slot, fd: -1)
            s.occupied[slot] = false
            s.activeCount = max(0, s.activeCount - 1)
            if s.activeCount == 0 {
                if var prev = s.previousAction?.value {
                    _ = sigaction(SIGWINCH, &prev, nil)
                }
                s.previousAction = nil
            }
        }
    }
}

private func posixCreatePipe(_ fds: inout [Int32]) -> Int32 {
    #if os(macOS)
    return Darwin.pipe(&fds)
    #elseif canImport(Glibc)
    return Glibc.pipe(&fds)
    #elseif canImport(Musl)
    return Musl.pipe(&fds)
    #else
    return -1
    #endif
}

private func posixCloseFD(_ fd: Int32) {
    guard fd >= 0 else { return }
    #if os(macOS)
    _ = Darwin.close(fd)
    #elseif canImport(Glibc)
    _ = Glibc.close(fd)
    #elseif canImport(Musl)
    _ = Musl.close(fd)
    #endif
}

private func configureNonBlockingCloexec(_ fd: Int32) -> Bool {
    guard fd >= 0 else { return false }
    let fdFlags = fcntl(fd, F_GETFD)
    if fdFlags < 0 || fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) < 0 {
        return false
    }
    let flFlags = fcntl(fd, F_GETFL)
    if flFlags < 0 || fcntl(fd, F_SETFL, flFlags | O_NONBLOCK) < 0 {
        return false
    }
    return true
}

private func drainSigwinchWakePipe(fd: Int32) -> Bool {
    guard fd >= 0 else { return false }
    var drainedAny = false
    var scratch = [UInt8](repeating: 0, count: 64)
    while true {
        let count: Int = scratch.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            #if os(macOS)
            return Darwin.read(fd, base, rawBuf.count)
            #elseif canImport(Glibc)
            return Glibc.read(fd, base, rawBuf.count)
            #elseif canImport(Musl)
            return Musl.read(fd, base, rawBuf.count)
            #else
            return -1
            #endif
        }
        if count > 0 {
            drainedAny = true
            continue
        }
        if count < 0 {
            let err = errno
            if err == EINTR { continue }
            break
        }
        // count == 0: EOF (write end closed during teardown)
        break
    }
    return drainedAny
}

/// Thread-safe owner of a single `PlatformTerminalBackend`'s POSIX `SIGWINCH` wake self-pipe.
/// Reference-counts active `pollRead` callers so `readFD` is never closed out from under an in-flight `poll(2)`.
private final class PosixSigwinchWatcher: Sendable {
    private struct State: Sendable {
        var readFD: Int32 = -1
        var writeFD: Int32 = -1
        var slotIndex: Int? = nil
        var activePollers: Int = 0
        var pendingCloseReadFDs: [Int32] = []
        var resizeDetected: Bool = false
        var cachedSize: TerminalSize
    }

    private let state: Mutex<State>

    init(initialSize: TerminalSize) {
        self.state = Mutex(State(cachedSize: initialSize))
    }

    deinit {
        uninstall()
    }

    var cachedSize: TerminalSize {
        state.withLock { $0.cachedSize }
    }

    func updateCachedSize(_ size: TerminalSize) {
        state.withLock { $0.cachedSize = size }
    }

    var didResizeSinceLastPoll: Bool {
        state.withLock { $0.resizeDetected }
    }

    func install(currentSize: TerminalSize) {
        let alreadyInstalled = state.withLock { s -> Bool in
            s.cachedSize = currentSize
            return s.readFD >= 0
        }
        if alreadyInstalled { return }

        var fds: [Int32] = [-1, -1]
        guard posixCreatePipe(&fds) == 0 else { return }
        let readFD = fds[0]
        let writeFD = fds[1]
        guard configureNonBlockingCloexec(readFD), configureNonBlockingCloexec(writeFD) else {
            posixCloseFD(readFD)
            posixCloseFD(writeFD)
            return
        }
        guard let slot = SigwinchCoordinator.shared.register(writeFD: writeFD) else {
            posixCloseFD(readFD)
            posixCloseFD(writeFD)
            return
        }

        let duplicate = state.withLock { s -> Bool in
            if s.readFD >= 0 {
                return true
            }
            s.readFD = readFD
            s.writeFD = writeFD
            s.slotIndex = slot
            s.resizeDetected = false
            s.cachedSize = currentSize
            return false
        }
        if duplicate {
            SigwinchCoordinator.shared.unregister(slot: slot)
            posixCloseFD(writeFD)
            posixCloseFD(readFD)
        }
    }

    func uninstall() {
        let teardown: (readFDToCloseNow: Int32, writeFD: Int32, slot: Int?) = state.withLock { s in
            let rfd = s.readFD
            let wfd = s.writeFD
            let slot = s.slotIndex
            s.readFD = -1
            s.writeFD = -1
            s.slotIndex = nil
            if rfd >= 0 && s.activePollers > 0 {
                s.pendingCloseReadFDs.append(rfd)
                return (-1, wfd, slot)
            }
            return (rfd, wfd, slot)
        }

        if let slot = teardown.slot {
            SigwinchCoordinator.shared.unregister(slot: slot)
        }
        // Closing the write end first wakes any blocked poll() immediately via POLLHUP.
        if teardown.writeFD >= 0 {
            posixCloseFD(teardown.writeFD)
        }
        if teardown.readFDToCloseNow >= 0 {
            posixCloseFD(teardown.readFDToCloseNow)
        }
    }

    func beginPoll() -> Int32 {
        state.withLock { s in
            s.resizeDetected = false
            if s.readFD >= 0 {
                s.activePollers += 1
                return s.readFD
            }
            return -1
        }
    }

    func endPoll() {
        let toClose: [Int32] = state.withLock { s in
            s.activePollers = max(0, s.activePollers - 1)
            if s.activePollers == 0 && !s.pendingCloseReadFDs.isEmpty {
                let fds = s.pendingCloseReadFDs
                s.pendingCloseReadFDs.removeAll()
                return fds
            }
            return []
        }
        for fd in toClose {
            posixCloseFD(fd)
        }
    }

    func recordResize(size: TerminalSize) {
        state.withLock { s in
            s.resizeDetected = true
            s.cachedSize = size
        }
    }

    func consumeResizeSignal(querySize: () -> TerminalSize) -> Bool {
        let initial: (alreadyFlagged: Bool, activeReadFD: Int32) = state.withLock { s in
            if s.resizeDetected {
                s.resizeDetected = false
                return (true, -1)
            }
            if s.readFD >= 0 {
                s.activePollers += 1
                return (false, s.readFD)
            }
            return (false, -1)
        }
        if initial.alreadyFlagged {
            return true
        }
        guard initial.activeReadFD >= 0 else {
            return false
        }
        defer { endPoll() }
        if drainSigwinchWakePipe(fd: initial.activeReadFD) {
            let measured = querySize()
            state.withLock { s in
                s.cachedSize = measured
                s.resizeDetected = false
            }
            return true
        }
        return false
    }
}

#endif

/// Errors surfaced by `PlatformTerminalBackend`.
public enum PlatformTerminalError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case unsupportedPlatform
    case notATerminal
    case systemCallFailed(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "Native terminal I/O is not supported on this platform"
        case .notATerminal:
            return "File descriptor is not attached to a terminal"
        case .systemCallFailed(let operation, let code):
            return "Terminal system call '\(operation)' failed with error code \(code)"
        }
    }
}

/// Cross-platform native `TerminalBackend` implementation:
/// - macOS / Linux / FreeBSD / Android: POSIX `termios` raw mode, `ioctl(TIOCGWINSZ)` size detection,
///   async-signal-safe `SIGWINCH` self-pipe wakeup for instant `pollRead` resize detection, and `write(2)` output.
/// - Windows: Win32 console mode (`ENABLE_VIRTUAL_TERMINAL_PROCESSING` / `ENABLE_VIRTUAL_TERMINAL_INPUT`),
///   `GetConsoleScreenBufferInfo` size detection, and `WriteFile` output via `WinSDK`.
/// - iOS / tvOS / watchOS / visionOS / WASI: safe fallback returning `defaultSize` and reporting
///   `PlatformTerminalError.unsupportedPlatform` for unsupported terminal mutations.
public actor PlatformTerminalBackend: TerminalBackend {
    public let defaultSize: TerminalSize
    public private(set) var isRawMode: Bool = false

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
    private let inputFD: Int32
    private let outputFD: Int32
    private var savedTermios: termios?
    #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
    private let resizeWake: PosixSigwinchWatcher
    #endif

    public init(
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)
    ) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.defaultSize = defaultSize
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        self.resizeWake = PosixSigwinchWatcher(
            initialSize: Self.measurePosixTerminalSize(
                inputFD: inputFD,
                outputFD: outputFD,
                defaultSize: defaultSize
            )
        )
        #endif
        ensurePlatformHostClipboardRegistered()
    }

    deinit {
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.uninstall()
        #endif
        if var original = savedTermios {
            _ = tcsetattr(inputFD, TCSAFLUSH, &original)
        }
    }

    private nonisolated static func measurePosixTerminalSize(
        inputFD: Int32,
        outputFD: Int32,
        defaultSize: TerminalSize
    ) -> TerminalSize {
        var ws = winsize()
        #if os(macOS) || os(FreeBSD) || os(Linux)
        let request = UInt(TIOCGWINSZ)
        #else
        let request = Int32(TIOCGWINSZ)
        #endif
        if outputFD >= 0, ioctl(outputFD, request, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return TerminalSize(width: Int(ws.ws_col), height: Int(ws.ws_row))
        }
        if inputFD >= 0, inputFD != outputFD, ioctl(inputFD, request, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return TerminalSize(width: Int(ws.ws_col), height: Int(ws.ws_row))
        }
        return defaultSize
    }

    private nonisolated func queryTerminalSize() -> TerminalSize {
        Self.measurePosixTerminalSize(inputFD: inputFD, outputFD: outputFD, defaultSize: defaultSize)
    }
    #elseif os(Windows)
    private var savedInputMode: DWORD?
    private var savedOutputMode: DWORD?

    public init(defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.defaultSize = defaultSize
        ensurePlatformHostClipboardRegistered()
    }
    #else
    public init(defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.defaultSize = defaultSize
        ensurePlatformHostClipboardRegistered()
    }
    #endif

    public var size: TerminalSize {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let measured = queryTerminalSize()
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.updateCachedSize(measured)
        #endif
        return measured
        #elseif os(Windows)
        let handle = GetStdHandle(STD_OUTPUT_HANDLE)
        if let handle, handle != INVALID_HANDLE_VALUE {
            var info = CONSOLE_SCREEN_BUFFER_INFO()
            if GetConsoleScreenBufferInfo(handle, &info) {
                let width = Int(info.srWindow.Right - info.srWindow.Left) + 1
                let height = Int(info.srWindow.Bottom - info.srWindow.Top) + 1
                if width > 0 && height > 0 {
                    return TerminalSize(width: width, height: height)
                }
            }
        }
        return defaultSize
        #else
        return defaultSize
        #endif
    }

    /// Most recently observed terminal size (automatically refreshed on `size` reads and `SIGWINCH` wakeups).
    public nonisolated var cachedSize: TerminalSize {
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.cachedSize
        #else
        defaultSize
        #endif
    }

    /// `true` if a POSIX `SIGWINCH` resize wakeup was observed during the most recent `pollRead` call
    /// and has not yet been cleared by `consumeResizeSignal()` or a subsequent poll.
    public nonisolated var didResizeSinceLastPoll: Bool {
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.didResizeSinceLastPoll
        #else
        false
        #endif
    }

    /// Returns `true` and clears the resize flag if a POSIX `SIGWINCH` signal fired since the last
    /// check (also draining any unread wake byte from the self-pipe and updating `cachedSize`).
    public nonisolated func consumeResizeSignal() -> Bool {
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.consumeResizeSignal {
            queryTerminalSize()
        }
        #else
        false
        #endif
    }

    public func write(_ bytes: [UInt8]) async throws {
        if bytes.isEmpty { return }
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        guard outputFD >= 0 else {
            throw PlatformTerminalError.systemCallFailed(operation: "write", code: EBADF)
        }
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < bytes.count {
                let ptr = baseAddress.advanced(by: totalWritten)
                let remaining = bytes.count - totalWritten
                #if os(macOS)
                let written = Darwin.write(outputFD, ptr, remaining)
                #elseif os(Linux) || os(FreeBSD)
                #if canImport(Glibc)
                let written = Glibc.write(outputFD, ptr, remaining)
                #elseif canImport(Musl)
                let written = Musl.write(outputFD, ptr, remaining)
                #endif
                #elseif os(Android)
                let written = Android.write(outputFD, ptr, remaining)
                #endif
                if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw PlatformTerminalError.systemCallFailed(operation: "write", code: err)
                }
                if written == 0 {
                    throw PlatformTerminalError.systemCallFailed(operation: "write", code: EIO)
                }
                totalWritten += written
            }
        }
        #elseif os(Windows)
        let handle = GetStdHandle(STD_OUTPUT_HANDLE)
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw PlatformTerminalError.systemCallFailed(operation: "GetStdHandle", code: Int32(GetLastError()))
        }
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < bytes.count {
                var written: DWORD = 0
                let remaining = DWORD(min(bytes.count - totalWritten, Int(DWORD.max)))
                let ok = WriteFile(handle, baseAddress.advanced(by: totalWritten), remaining, &written, nil)
                if !ok {
                    throw PlatformTerminalError.systemCallFailed(operation: "WriteFile", code: Int32(GetLastError()))
                }
                if written == 0 {
                    throw PlatformTerminalError.systemCallFailed(operation: "WriteFile", code: 0)
                }
                totalWritten += Int(written)
            }
        }
        #else
        throw PlatformTerminalError.unsupportedPlatform
        #endif
    }

    public func enterRawMode() async throws {
        if isRawMode { return }
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        guard inputFD >= 0, isatty(inputFD) != 0 else {
            throw PlatformTerminalError.notATerminal
        }
        var original = termios()
        guard tcgetattr(inputFD, &original) == 0 else {
            throw PlatformTerminalError.systemCallFailed(operation: "tcgetattr", code: errno)
        }
        var raw = original
        cfmakeraw(&raw)
        // Configure blocking single-byte reads with zero inter-character timeout.
        withUnsafeMutableBytes(of: &raw.c_cc) { ccBuffer in
            let vminIndex = Int(VMIN)
            let vtimeIndex = Int(VTIME)
            if vminIndex < ccBuffer.count { ccBuffer[vminIndex] = 1 }
            if vtimeIndex < ccBuffer.count { ccBuffer[vtimeIndex] = 0 }
        }
        guard tcsetattr(inputFD, TCSAFLUSH, &raw) == 0 else {
            throw PlatformTerminalError.systemCallFailed(operation: "tcsetattr", code: errno)
        }
        savedTermios = original
        isRawMode = true
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.install(currentSize: queryTerminalSize())
        #endif
        #elseif os(Windows)
        let inHandle = GetStdHandle(STD_INPUT_HANDLE)
        let outHandle = GetStdHandle(STD_OUTPUT_HANDLE)
        guard let inHandle, inHandle != INVALID_HANDLE_VALUE,
              let outHandle, outHandle != INVALID_HANDLE_VALUE
        else {
            throw PlatformTerminalError.notATerminal
        }
        var origInMode: DWORD = 0
        var origOutMode: DWORD = 0
        guard GetConsoleMode(inHandle, &origInMode) else {
            throw PlatformTerminalError.notATerminal
        }
        guard GetConsoleMode(outHandle, &origOutMode) else {
            throw PlatformTerminalError.systemCallFailed(operation: "GetConsoleMode", code: Int32(GetLastError()))
        }
        var rawInMode = origInMode
        rawInMode &= ~DWORD(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
        rawInMode |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
        guard SetConsoleMode(inHandle, rawInMode) else {
            throw PlatformTerminalError.systemCallFailed(operation: "SetConsoleMode(in)", code: Int32(GetLastError()))
        }
        let rawOutMode = origOutMode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        if !SetConsoleMode(outHandle, rawOutMode) {
            _ = SetConsoleMode(inHandle, origInMode)
            throw PlatformTerminalError.systemCallFailed(operation: "SetConsoleMode(out)", code: Int32(GetLastError()))
        }
        savedInputMode = origInMode
        savedOutputMode = origOutMode
        isRawMode = true
        #else
        throw PlatformTerminalError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
    public nonisolated var isInteractiveTerminal: Bool {
        inputFD >= 0 && outputFD >= 0 && isatty(inputFD) != 0 && isatty(outputFD) != 0
    }

    /// Polls `inputFD` (and, when raw mode is active on POSIX, the `SIGWINCH` self-pipe read end)
    /// for up to `timeoutMs` milliseconds and returns any immediately available input bytes without
    /// blocking the `PlatformTerminalBackend` actor's `write(_:)` / `size` methods.
    ///
    /// When `SIGWINCH` arrives, `pollRead` wakes immediately, drains the self-pipe, updates `cachedSize`,
    /// sets `didResizeSinceLastPoll = true`, and returns `[]` (unless `inputFD` is also readable).
    public nonisolated func pollRead(maxBytes: Int = 4096, timeoutMs: Int32 = 16) throws -> [UInt8] {
        guard inputFD >= 0 else {
            throw PlatformTerminalError.systemCallFailed(operation: "poll", code: EBADF)
        }
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        let wakeFD = resizeWake.beginPoll()
        defer {
            if wakeFD >= 0 {
                resizeWake.endPoll()
            }
        }

        if wakeFD >= 0 {
            var pfds: [pollfd] = [
                pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = pfds.withUnsafeMutableBufferPointer { buf in
                poll(buf.baseAddress, nfds_t(buf.count), timeoutMs)
            }
            if ready < 0 {
                let err = errno
                if err == EINTR {
                    if drainSigwinchWakePipe(fd: wakeFD) {
                        resizeWake.recordResize(size: queryTerminalSize())
                    }
                    return []
                }
                throw PlatformTerminalError.systemCallFailed(operation: "poll", code: err)
            }
            if ready == 0 {
                return []
            }

            if (pfds[1].revents & Int16(POLLIN)) != 0 {
                if drainSigwinchWakePipe(fd: wakeFD) {
                    resizeWake.recordResize(size: queryTerminalSize())
                }
            }

            if (pfds[0].revents & Int16(POLLIN)) == 0 {
                return []
            }
        } else {
            var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, timeoutMs)
            if ready < 0 {
                let err = errno
                if err == EINTR { return [] }
                throw PlatformTerminalError.systemCallFailed(operation: "poll", code: err)
            }
            if ready == 0 || (pfd.revents & Int16(POLLIN)) == 0 {
                return []
            }
        }
        #else
        var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        if ready < 0 {
            let err = errno
            if err == EINTR { return [] }
            throw PlatformTerminalError.systemCallFailed(operation: "poll", code: err)
        }
        if ready == 0 || (pfd.revents & Int16(POLLIN)) == 0 {
            return []
        }
        #endif

        var buffer = [UInt8](repeating: 0, count: max(1, maxBytes))
        let count: Int = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return 0 }
            #if os(macOS)
            return Darwin.read(inputFD, base, rawBuf.count)
            #elseif os(Linux) || os(FreeBSD)
            #if canImport(Glibc)
            return Glibc.read(inputFD, base, rawBuf.count)
            #elseif canImport(Musl)
            return Musl.read(inputFD, base, rawBuf.count)
            #endif
            #elseif os(Android)
            return Android.read(inputFD, base, rawBuf.count)
            #endif
        }
        if count < 0 {
            let err = errno
            if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { return [] }
            throw PlatformTerminalError.systemCallFailed(operation: "read", code: err)
        }
        if count == 0 {
            return []
        }
        return Array(buffer.prefix(count))
    }
    #else
    public nonisolated var isInteractiveTerminal: Bool { false }

    public nonisolated func pollRead(maxBytes: Int = 4096, timeoutMs: Int32 = 16) throws -> [UInt8] {
        throw PlatformTerminalError.unsupportedPlatform
    }
    #endif

    public func exitRawMode() async throws {
        if !isRawMode { return }
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        #if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))
        resizeWake.uninstall()
        #endif
        if var original = savedTermios {
            let status = tcsetattr(inputFD, TCSAFLUSH, &original)
            savedTermios = nil
            isRawMode = false
            if status != 0 {
                throw PlatformTerminalError.systemCallFailed(operation: "tcsetattr", code: errno)
            }
        } else {
            isRawMode = false
        }
        #elseif os(Windows)
        var firstError: PlatformTerminalError? = nil
        if let origIn = savedInputMode,
           let inHandle = GetStdHandle(STD_INPUT_HANDLE),
           inHandle != INVALID_HANDLE_VALUE
        {
            if !SetConsoleMode(inHandle, origIn) {
                firstError = .systemCallFailed(operation: "SetConsoleMode(in)", code: Int32(GetLastError()))
            }
        }
        if let origOut = savedOutputMode,
           let outHandle = GetStdHandle(STD_OUTPUT_HANDLE),
           outHandle != INVALID_HANDLE_VALUE
        {
            if !SetConsoleMode(outHandle, origOut) && firstError == nil {
                firstError = .systemCallFailed(operation: "SetConsoleMode(out)", code: Int32(GetLastError()))
            }
        }
        savedInputMode = nil
        savedOutputMode = nil
        isRawMode = false
        if let err = firstError {
            throw err
        }
        #else
        isRawMode = false
        #endif
    }
}
