#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeRecorder
import OpenCodeUtil
import Synchronization

// NOTE: This helper file intentionally does NOT `import Testing` to uphold the macOS CLT
// cross-import rule (never import Foundation/FoundationEssentials in the same file as Testing).

/// Temporary directory helper for disk-backed cassette tests.
struct TempRecorderDirectory: Sendable {
    let path: String

    init(prefix: String = "opencode-recorder-test-") throws {
        let base = SystemEnvironment.shared.temporaryDirectory
        let dir = "\(base)/\(prefix)\(uuid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = dir
    }

    func writeRaw(relativePath: String, text: String) throws {
        let full = "\(path)/\(relativePath)"
        let url = URL(fileURLWithPath: full)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/\(relativePath)")
    }

    func listDirectoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    func readCassette(relativePath: String) throws -> Cassette {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(path)/\(relativePath)"))
        return try decodeCassette(fromBytes: Array(data))
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Deterministic async gate used to coordinate concurrent request/socket test ordering.
actor AsyncTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Thread-safe event log for concurrency ordering assertions.
actor TestEventLog<Element: Sendable> {
    private var items: [Element] = []

    func append(_ item: Element) {
        items.append(item)
    }

    func snapshot() -> [Element] {
        items
    }
}

/// Unavailable `RecorderSocket` that fails if live upstream is ever touched during replay.
struct UnavailableRecorderSocket: RecorderSocket, Sendable {
    func run<T: Sendable>(
        _ body: @Sendable (any RecorderSocketReader, any RecorderSocketWriter) async throws -> T
    ) async throws -> T {
        throw WebSocketRecorderError("unexpected live WebSocket run")
    }
}

/// Scripted in-memory `RecorderSocket` for deterministic recording tests.
final class ScriptedRecorderSocket: RecorderSocket, Sendable {
    enum Step: Sendable {
        case frames([WebSocketFrame])
        case close(code: Int, reason: String = "")
        case fail(any Error)
        case waitForever
    }

    private final class Reader: RecorderSocketReader, Sendable {
        private actor Queue {
            var steps: [Step]
            init(steps: [Step]) { self.steps = steps }
            func next() -> Step {
                if steps.isEmpty { return .close(code: 1000, reason: "") }
                return steps.removeFirst()
            }
        }

        private let queue: Queue

        init(steps: [Step]) {
            self.queue = Queue(steps: steps)
        }

        func pull() async throws -> [WebSocketFrame] {
            switch await queue.next() {
            case .frames(let frames):
                return frames
            case let .close(code, reason):
                throw WebSocketCloseError(code: code, reason: reason)
            case .fail(let error):
                throw error
            case .waitForever:
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw WebSocketCloseError(code: 1000, reason: "")
            }
        }
    }

    private final class Writer: RecorderSocketWriter, Sendable {
        private let onWrite: (@Sendable (WebSocketWriteMessage) async throws -> Void)?

        init(onWrite: (@Sendable (WebSocketWriteMessage) async throws -> Void)?) {
            self.onWrite = onWrite
        }

        func write(_ message: WebSocketWriteMessage) async throws {
            try await onWrite?(message)
        }
    }

    private let steps: [Step]
    private let openError: (any Error)?
    private let onWrite: (@Sendable (WebSocketWriteMessage) async throws -> Void)?

    init(
        steps: [Step] = [],
        openError: (any Error)? = nil,
        onWrite: (@Sendable (WebSocketWriteMessage) async throws -> Void)? = nil
    ) {
        self.steps = steps
        self.openError = openError
        self.onWrite = onWrite
    }

    func run<T: Sendable>(
        _ body: @Sendable (any RecorderSocketReader, any RecorderSocketWriter) async throws -> T
    ) async throws -> T {
        if let openError {
            throw openError
        }
        return try await body(Reader(steps: steps), Writer(onWrite: onWrite))
    }
}

/// In-memory echo `RecorderWebSocketConnection` for deterministic constructor recording tests.
final class EchoWebSocketConnection: RecorderWebSocketConnection, Sendable {
    private actor State {
        var readyState: WebSocketReadyState = .connecting
        var inbox: [WebSocketFrame] = []
        var closed: WebSocketClose?
        var waiters: [CheckedContinuation<WebSocketFrame?, Never>] = []

        func markOpen() {
            readyState = .open
        }

        func enqueueEcho(_ frame: WebSocketFrame) {
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume(returning: frame)
            } else {
                inbox.append(frame)
            }
        }

        func nextFrame() async -> WebSocketFrame? {
            if !inbox.isEmpty {
                return inbox.removeFirst()
            }
            if closed != nil {
                return nil
            }
            return await withCheckedContinuation { continuation in
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                } else if closed != nil {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func close(code: Int, reason: String) {
            if closed != nil { return }
            let close = WebSocketClose(code: code, reason: reason)
            closed = close
            readyState = .closed
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: nil)
            }
        }
    }

    let url: String
    let protocols: [String]

    private let state = State()
    private let cachedReadyState = Mutex<WebSocketReadyState>(.connecting)
    private let cachedClose = Mutex<WebSocketClose?>(nil)

    init(url: String, protocols: [String] = []) {
        self.url = url
        self.protocols = protocols
    }

    var readyState: WebSocketReadyState {
        cachedReadyState.withLock { $0 }
    }

    var terminalClose: WebSocketClose? {
        cachedClose.withLock { $0 }
    }

    func open() async throws {
        await state.markOpen()
        cachedReadyState.withLock { $0 = .open }
    }

    func send(_ frame: WebSocketFrame) async throws {
        await state.enqueueEcho(frame)
    }

    func receive() async throws -> WebSocketFrame? {
        await state.nextFrame()
    }

    func close(code: Int, reason: String) async throws {
        await state.close(code: code, reason: reason)
        cachedClose.withLock { $0 = WebSocketClose(code: code, reason: reason) }
        cachedReadyState.withLock { $0 = .closed }
    }
}
