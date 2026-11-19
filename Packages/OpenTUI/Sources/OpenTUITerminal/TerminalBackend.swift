import OpenTUICore
import OpenTUIKeymap

/// Cross-platform terminal I/O abstraction.
/// Host OS backends (POSIX `termios` on macOS/Linux/FreeBSD/Android, Windows VT console on Windows)
/// sit cleanly behind `#if os(...)` guards, while `MemoryTerminalBackend` runs headless on all
/// Swift platforms (including iOS, WASI, and automated `TestRenderer` suites).
public struct TerminalSize: Equatable, Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public protocol TerminalBackend: Sendable {
    var size: TerminalSize { get async }
    func write(_ bytes: [UInt8]) async throws
    func enterRawMode() async throws
    func exitRawMode() async throws
}

public actor MemoryTerminalBackend: TerminalBackend {
    public private(set) var size: TerminalSize
    public private(set) var outputLog: [[UInt8]] = []
    public private(set) var isRawMode = false

    public init(size: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.size = size
    }

    public func resize(to newSize: TerminalSize) {
        self.size = newSize
    }

    public func write(_ bytes: [UInt8]) async throws {
        outputLog.append(bytes)
    }

    public func enterRawMode() async throws {
        isRawMode = true
    }

    public func exitRawMode() async throws {
        isRawMode = false
    }

    public var renderedOutput: String {
        String(decoding: outputLog.flatMap { $0 }, as: UTF8.self)
    }
}
