/// Pure-Swift stdout/stderr output capture ring buffer and listener dispatch,
/// matching `packages/core/src/lib/output.capture.ts`.

/// Output stream identifier captured by `OutputCapture`.
public enum CaptureStream: String, Equatable, Hashable, Sendable, Codable {
    case stdout
    case stderr
}

/// A single captured write chunk with its originating stream.
// parity: core/src/lib/output.capture.ts#CapturedOutput [status=implemented hash=73917ef6a6ed]
public struct CapturedOutput: Equatable, Hashable, Sendable, Codable {
    public let stream: CaptureStream
    public let output: String

    public init(stream: CaptureStream, output: String) {
        self.stream = stream
        self.output = output
    }
}

/// Opaque registration handle returned when subscribing to `OutputCapture` write events.
public struct OutputCaptureToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Bounded FIFO buffer capturing stdout and stderr writes with event notification,
/// matching `Capture` in `packages/core/src/lib/output.capture.ts`.
// parity: core/src/lib/output.capture.ts#Capture [status=implemented hash=e008595f18ca]
public final class OutputCapture {
    private struct ListenerEntry {
        let id: UInt64
        let handler: (CaptureStream, String) -> Void
    }

    public let maxEntries: Int
    private var buffer: [CapturedOutput] = []
    private var listeners: [ListenerEntry] = []
    private var nextListenerId: UInt64 = 1

    public init(maxEntries: Int = 1000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Number of currently buffered write entries.
    // parity: core/src/lib/output.capture.ts#Capture.size [status=implemented hash=97d655e87398]
    public var size: Int {
        buffer.count
    }

    /// Read-only snapshot of the currently buffered entries in chronological order.
    public var entries: [CapturedOutput] {
        buffer
    }

    /// Appends a write to the capture buffer (evicting the oldest entry if full) and notifies subscribers.
    // parity: core/src/lib/output.capture.ts#Capture.write [status=implemented hash=0d24d0baf800]
    public func write(_ stream: CaptureStream, _ data: String) {
        if buffer.count >= maxEntries {
            buffer.removeFirst()
        }
        buffer.append(CapturedOutput(stream: stream, output: data))

        let snapshot = listeners
        for entry in snapshot {
            entry.handler(stream, data)
        }
    }

    /// Concatenates all buffered outputs in order and clears the buffer.
    // parity: core/src/lib/output.capture.ts#Capture.claimOutput [status=implemented hash=2d42a961c32e]
    public func claimOutput() -> String {
        let combined = buffer.map(\.output).joined()
        clear()
        return combined
    }

    /// Returns all buffered entries and clears the buffer.
    public func claimEntries() -> [CapturedOutput] {
        let claimed = buffer
        clear()
        return claimed
    }

    /// Clears all buffered output entries without removing event listeners.
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Subscribes to `"write"` events emitted whenever `write(_:_:)` is called.
    @discardableResult
    public func onWrite(_ handler: @escaping (CaptureStream, String) -> Void) -> OutputCaptureToken {
        let id = nextListenerId
        nextListenerId &+= 1
        listeners.append(ListenerEntry(id: id, handler: handler))
        return OutputCaptureToken(id: id)
    }

    /// Unsubscribes a previously registered write listener.
    public func off(_ token: OutputCaptureToken) {
        listeners.removeAll { $0.id == token.id }
    }

    /// Removes all registered write listeners.
    public func removeAllListeners() {
        listeners.removeAll()
    }
}

/// Alias matching upstream's `Capture` class name.
public typealias Capture = OutputCapture

/// Pure-Swift writable stream proxy forwarding writes into an `OutputCapture` instance,
/// matching `CapturedWritableStream` in `packages/core/src/lib/output.capture.ts`.
// parity: core/src/lib/output.capture.ts#CapturedWritableStream [status=implemented hash=70a995733b8a]
public final class CapturedWritableStream {
    public var isTTY: Bool
    public var columns: Int
    public var rows: Int
    public var colorDepth: Int
    public let stream: CaptureStream
    private let capture: OutputCapture

    public init(
        stream: CaptureStream,
        capture: OutputCapture,
        isTTY: Bool = true,
        columns: Int = 80,
        rows: Int = 24,
        colorDepth: Int = 8
    ) {
        self.stream = stream
        self.capture = capture
        self.isTTY = isTTY
        self.columns = columns
        self.rows = rows
        self.colorDepth = colorDepth
    }

    public func write(_ data: String) {
        capture.write(stream, data)
    }

    public func write(_ bytes: [UInt8]) {
        capture.write(stream, String(decoding: bytes, as: UTF8.self))
    }

    // parity: core/src/lib/output.capture.ts#CapturedWritableStream.getColorDepth [status=implemented hash=793ef4196ee3]
    public func getColorDepth() -> Int {
        colorDepth
    }
}
