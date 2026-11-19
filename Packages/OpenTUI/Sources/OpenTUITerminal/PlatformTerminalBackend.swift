import OpenTUICore
import OpenTUIKeymap

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
///   and `write(2)` output.
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

    public init(
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)
    ) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.defaultSize = defaultSize
    }
    #elseif os(Windows)
    private var savedInputMode: DWORD?
    private var savedOutputMode: DWORD?

    public init(defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.defaultSize = defaultSize
    }
    #else
    public init(defaultSize: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.defaultSize = defaultSize
    }
    #endif

    public var size: TerminalSize {
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        var ws = winsize()
        #if os(macOS) || os(FreeBSD)
        let request = UInt(TIOCGWINSZ)
        #elseif os(Linux)
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

    /// Polls `inputFD` for up to `timeoutMs` milliseconds and returns any immediately available bytes
    /// without blocking the `PlatformTerminalBackend` actor's `write(_:)` / `size` methods.
    public nonisolated func pollRead(maxBytes: Int = 4096, timeoutMs: Int32 = 16) throws -> [UInt8] {
        guard inputFD >= 0 else {
            throw PlatformTerminalError.systemCallFailed(operation: "poll", code: EBADF)
        }
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
