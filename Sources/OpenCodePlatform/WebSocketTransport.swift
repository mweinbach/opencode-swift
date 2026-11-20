#if !os(WASI)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeUtil

// MARK: - Cross-Platform WebSocket Client Transport Primitives

/// RFC 6455 close code and UTF-8 reason reported when a WebSocket closes.
public struct WebSocketCloseEvent: Equatable, Hashable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

/// Application message carried over a `WebSocketConnection`.
public enum WebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// Errors surfaced by cross-platform `WebSocketTransport` implementations.
public enum WebSocketTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidURL(String)
    case upgradeFailed(statusCode: Int?, detail: String)
    case closed(WebSocketCloseEvent)
    case networkFailure(String)
    case cancelled
    case unsupportedPlatform(PlatformOS)

    public var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid WebSocket URL: \(url)"
        case let .upgradeFailed(statusCode, detail):
            if let statusCode {
                return "WebSocket upgrade failed (HTTP \(statusCode)): \(detail)"
            }
            return "WebSocket upgrade failed: \(detail)"
        case .closed(let event):
            return event.reason.isEmpty
                ? "WebSocket closed with code \(event.code)"
                : "WebSocket closed with code \(event.code): \(event.reason)"
        case .networkFailure(let detail):
            return "WebSocket network failure: \(detail)"
        case .cancelled:
            return "WebSocket connection cancelled"
        case .unsupportedPlatform(let os):
            return "Native WebSocket transport is unsupported on \(os.rawValue)"
        }
    }
}

/// Full-duplex client WebSocket connection whose incoming stream throws `WebSocketTransportError.closed`
/// when the peer closes with a close frame (preserving custom application codes such as `4401`).
public protocol WebSocketConnection: Sendable {
    var messages: AsyncThrowingStream<WebSocketMessage, any Error> { get }
    func send(_ message: WebSocketMessage) async throws
    func close(code: Int, reason: String) async
}

public extension WebSocketConnection {
    func send(text: String) async throws {
        try await send(.text(text))
    }

    func send(binary: [UInt8]) async throws {
        try await send(.binary(binary))
    }

    func close(code: Int = 1000) async {
        await close(code: code, reason: "")
    }
}

/// Injectable cross-platform WebSocket client transport decoupling higher layers from OS networking stacks.
public protocol WebSocketTransport: Sendable {
    func connect(
        url: String,
        headers: [String: String],
        protocols: [String]
    ) async throws -> any WebSocketConnection
}

public extension WebSocketTransport {
    func connect(url: String, headers: [String: String] = [:]) async throws -> any WebSocketConnection {
        try await connect(url: url, headers: headers, protocols: [])
    }
}

// MARK: - Native URLSession / POSIX WebSocket Transport

/// Live cross-platform `WebSocketTransport`:
/// - On Apple platforms (`Darwin`), uses `URLSessionWebSocketTask` with `URLSessionWebSocketDelegate`
///   to distinguish handshake/upgrade refusal from post-open close codes (including custom codes such as `4401`)
///   and to reject HTTP redirects so auth headers never cross origin boundaries.
/// - On Linux (`Glibc`/`Musl`), implements RFC 6455 client framing over POSIX TCP sockets for `ws://` URLs.
/// - On WASI and unsupported targets, throws `WebSocketTransportError.unsupportedPlatform`.
public final class URLSessionWebSocketTransport: WebSocketTransport, Sendable {
    public struct Configuration: Equatable, Sendable {
        public let maximumMessageSize: Int
        public let connectTimeoutSeconds: Double
        public let defaultHeaders: [String: String]

        public init(
            maximumMessageSize: Int = 16 * 1024 * 1024,
            connectTimeoutSeconds: Double = 30,
            defaultHeaders: [String: String] = [:]
        ) {
            self.maximumMessageSize = maximumMessageSize
            self.connectTimeoutSeconds = connectTimeoutSeconds
            self.defaultHeaders = defaultHeaders
        }
    }

    public static let shared = URLSessionWebSocketTransport()

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func connect(
        url: String,
        headers: [String: String] = [:],
        protocols: [String] = []
    ) async throws -> any WebSocketConnection {
        #if os(WASI)
        _ = (url, headers, protocols)
        throw WebSocketTransportError.unsupportedPlatform(.wasi)
        #elseif canImport(Darwin)
        return try await connectDarwin(url: url, headers: headers, protocols: protocols)
        #elseif canImport(Glibc) || canImport(Musl)
        return try await connectPOSIX(url: url, headers: headers, protocols: protocols)
        #else
        _ = (url, headers, protocols)
        throw WebSocketTransportError.unsupportedPlatform(Platform.current)
        #endif
    }

    #if canImport(Darwin)
    private func connectDarwin(
        url: String,
        headers: [String: String],
        protocols: [String]
    ) async throws -> any WebSocketConnection {
        guard let parsedURL = URL(string: url),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw WebSocketTransportError.invalidURL(url)
        }

        var request = URLRequest(url: parsedURL)
        request.timeoutInterval = configuration.connectTimeoutSeconds
        for (key, value) in configuration.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.connectTimeoutSeconds
        sessionConfig.timeoutIntervalForResource = 0

        let delegate = DarwinWebSocketDelegate()
        let queue = OperationQueue()
        queue.name = "opencode.websocket.transport"
        queue.maxConcurrentOperationCount = 1

        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: queue)
        let wsTask = session.webSocketTask(with: request)
        wsTask.maximumMessageSize = configuration.maximumMessageSize

        let cancelBox = DarwinWSCancelBox(session: session, task: wsTask)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    delegate.setOpenContinuation(cont)
                    wsTask.resume()
                }
            } onCancel: {
                cancelBox.cancel()
            }
        } catch {
            session.invalidateAndCancel()
            throw error
        }

        return DarwinWebSocketConnection(
            session: session,
            task: wsTask,
            delegate: delegate,
            delegateQueue: queue
        )
    }
    #endif

    #if !canImport(Darwin) && (canImport(Glibc) || canImport(Musl))
    private func connectPOSIX(
        url: String,
        headers: [String: String],
        protocols: [String]
    ) async throws -> any WebSocketConnection {
        guard let parsedURL = URL(string: url),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = parsedURL.host, !host.isEmpty
        else {
            throw WebSocketTransportError.invalidURL(url)
        }
        if scheme == "wss" {
            throw WebSocketTransportError.unsupportedPlatform(Platform.current)
        }
        let port = parsedURL.port ?? 80
        var path = parsedURL.path.isEmpty ? "/" : parsedURL.path
        if let query = parsedURL.query, !query.isEmpty {
            path += "?\(query)"
        }
        var mergedHeaders = configuration.defaultHeaders
        for (k, v) in headers {
            mergedHeaders[k] = v
        }
        if !protocols.isEmpty {
            mergedHeaders["Sec-WebSocket-Protocol"] = protocols.joined(separator: ", ")
        }
        return try await POSIXClientWebSocketConnection.connect(
            host: host,
            port: port,
            path: path,
            headers: mergedHeaders
        )
    }
    #endif
}

// MARK: - Darwin URLSessionWebSocketTask Implementation

#if canImport(Darwin)
private final class DarwinWSCancelBox: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
    }
}

private final class DarwinWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct State {
        var openContinuation: CheckedContinuation<Void, any Error>?
        var opened: Bool = false
        var closedByClient: Bool = false
        var closeEvent: WebSocketCloseEvent?
        var streamContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation?
        var pendingTerminalError: (any Error)?
        var streamFinished: Bool = false
    }

    private let state = Mutex(State())

    func setOpenContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.openContinuation = continuation }
    }

    func attachStream(_ continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation) {
        let terminal: (finished: Bool, error: (any Error)?) = state.withLock { s in
            s.streamContinuation = continuation
            if s.streamFinished {
                return (true, s.pendingTerminalError)
            }
            if let closeEvent = s.closeEvent {
                s.streamFinished = true
                return (true, WebSocketTransportError.closed(closeEvent))
            }
            if let err = s.pendingTerminalError {
                s.streamFinished = true
                return (true, err)
            }
            return (false, nil)
        }
        if terminal.finished {
            if let error = terminal.error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func markClientClosed() {
        let cont: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation? = state.withLock { s in
            s.closedByClient = true
            if s.streamFinished { return nil }
            s.streamFinished = true
            return s.streamContinuation
        }
        cont?.finish()
    }

    func finishStream(withFallbackError error: any Error, taskCloseCode: Int, taskCloseReason: String) {
        let (cont, resolvedError): (AsyncThrowingStream<WebSocketMessage, any Error>.Continuation?, (any Error)?) = state.withLock { s in
            if s.streamFinished { return (nil, nil) }
            s.streamFinished = true
            if s.closedByClient {
                return (s.streamContinuation, nil)
            }
            if let closeEvent = s.closeEvent {
                return (s.streamContinuation, WebSocketTransportError.closed(closeEvent))
            }
            if taskCloseCode > 0 {
                let ev = WebSocketCloseEvent(code: taskCloseCode, reason: taskCloseReason)
                s.closeEvent = ev
                return (s.streamContinuation, WebSocketTransportError.closed(ev))
            }
            return (s.streamContinuation, error)
        }
        guard let cont else { return }
        if let resolvedError {
            cont.finish(throwing: resolvedError)
        } else {
            cont.finish()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Reject redirects before auth headers can cross an origin boundary (matching upstream followRedirects: false).
        _ = (session, task, response, request)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        _ = (session, webSocketTask, `protocol`)
        let cont: CheckedContinuation<Void, any Error>? = state.withLock { s in
            s.opened = true
            let c = s.openContinuation
            s.openContinuation = nil
            return c
        }
        cont?.resume(returning: ())
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = (session, webSocketTask)
        let reasonText = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let event = WebSocketCloseEvent(code: closeCode.rawValue, reason: reasonText)
        let cont: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation? = state.withLock { s in
            s.closeEvent = event
            if s.streamFinished { return nil }
            s.streamFinished = true
            if s.closedByClient { return s.streamContinuation }
            return s.streamContinuation
        }
        if state.withLock({ $0.closedByClient }) {
            cont?.finish()
        } else {
            cont?.finish(throwing: WebSocketTransportError.closed(event))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        _ = session
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let wsCloseCode = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
        let wsCloseReason = (task as? URLSessionWebSocketTask)?.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""

        let openCont: CheckedContinuation<Void, any Error>? = state.withLock { s in
            let c = s.openContinuation
            s.openContinuation = nil
            return c
        }
        if let openCont {
            let detail = error?.localizedDescription ?? "WebSocket handshake failed"
            openCont.resume(throwing: WebSocketTransportError.upgradeFailed(statusCode: statusCode, detail: detail))
            return
        }

        let (streamCont, terminalError): (AsyncThrowingStream<WebSocketMessage, any Error>.Continuation?, (any Error)?) = state.withLock { s in
            if s.streamFinished { return (nil, nil) }
            s.streamFinished = true
            if s.closedByClient {
                return (s.streamContinuation, nil)
            }
            if let closeEvent = s.closeEvent {
                return (s.streamContinuation, WebSocketTransportError.closed(closeEvent))
            }
            if wsCloseCode > 0 {
                let ev = WebSocketCloseEvent(code: wsCloseCode, reason: wsCloseReason)
                s.closeEvent = ev
                return (s.streamContinuation, WebSocketTransportError.closed(ev))
            }
            if let error {
                let nsError = error as NSError
                let mapped: any Error
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    mapped = WebSocketTransportError.cancelled
                } else {
                    mapped = WebSocketTransportError.networkFailure(error.localizedDescription)
                }
                s.pendingTerminalError = mapped
                return (s.streamContinuation, mapped)
            }
            return (s.streamContinuation, nil)
        }
        guard let streamCont else { return }
        if let terminalError {
            streamCont.finish(throwing: terminalError)
        } else {
            streamCont.finish()
        }
    }
}

private final class DarwinWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    let messages: AsyncThrowingStream<WebSocketMessage, any Error>
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: DarwinWebSocketDelegate
    private let delegateQueue: OperationQueue
    private let closed = Mutex(false)
    private let receiveTask = Mutex<Task<Void, Never>?>(nil)

    init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        delegate: DarwinWebSocketDelegate,
        delegateQueue: OperationQueue
    ) {
        self.session = session
        self.task = task
        self.delegate = delegate
        self.delegateQueue = delegateQueue

        let (stream, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
        self.messages = stream
        delegate.attachStream(continuation)

        let loop = Task { [weak self] in
            while let self, !Task.isCancelled, !self.closed.withLock({ $0 }) {
                do {
                    let message = try await self.task.receive()
                    switch message {
                    case .string(let text):
                        continuation.yield(.text(text))
                    case .data(let data):
                        continuation.yield(.binary(Array(data)))
                    @unknown default:
                        break
                    }
                } catch {
                    let closeCode = self.task.closeCode.rawValue
                    let closeReason = self.task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let mapped: any Error
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                        mapped = WebSocketTransportError.cancelled
                    } else {
                        mapped = WebSocketTransportError.networkFailure(error.localizedDescription)
                    }
                    // Synchronize on the serial delegateQueue so any already-enqueued `didCloseWith`
                    // callback delivers its exact RFC 6455 close code (e.g. 4401) before fallback runs.
                    let delegateRef = self.delegate
                    let taskRef = self.task
                    self.delegateQueue.addOperation {
                        let latestCode = taskRef.closeCode.rawValue
                        let latestReason = taskRef.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? closeReason
                        delegateRef.finishStream(
                            withFallbackError: mapped,
                            taskCloseCode: latestCode > 0 ? latestCode : closeCode,
                            taskCloseReason: latestReason
                        )
                    }
                    return
                }
            }
            continuation.finish()
        }
        receiveTask.withLock { $0 = loop }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard !closed.withLock({ $0 }) else {
            throw WebSocketTransportError.closed(WebSocketCloseEvent(code: 1000, reason: "closed"))
        }
        switch message {
        case .text(let text):
            try await task.send(.string(text))
        case .binary(let bytes):
            try await task.send(.data(Data(bytes)))
        }
    }

    func close(code: Int, reason: String) async {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        delegate.markClientClosed()
        let loop = receiveTask.withLock { t -> Task<Void, Never>? in
            let prev = t
            t = nil
            return prev
        }
        loop?.cancel()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.isEmpty ? nil : Data(reason.utf8))
        session.finishTasksAndInvalidate()
    }

    deinit {
        let loop = receiveTask.withLock { t -> Task<Void, Never>? in
            let prev = t
            t = nil
            return prev
        }
        loop?.cancel()
        session.invalidateAndCancel()
    }
}
#endif

// MARK: - Linux / Non-Darwin POSIX RFC 6455 Client WebSocket Implementation

#if !canImport(Darwin) && (canImport(Glibc) || canImport(Musl))
private enum POSIXSocketLibC {
    @inline(__always) static func close(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.close(fd)
        #else
        return Musl.close(fd)
        #endif
    }

    @inline(__always) static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #else
        return Musl.connect(fd, addr, len)
        #endif
    }

    @inline(__always) static func send(_ fd: Int32, _ buf: UnsafeRawPointer!, _ n: Int, _ flags: Int32) -> Int {
        #if canImport(Glibc)
        return Glibc.send(fd, buf, n, flags)
        #else
        return Musl.send(fd, buf, n, flags)
        #endif
    }

    @inline(__always) static func recv(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ n: Int, _ flags: Int32) -> Int {
        #if canImport(Glibc)
        return Glibc.recv(fd, buf, n, flags)
        #else
        return Musl.recv(fd, buf, n, flags)
        #endif
    }
}

private final class POSIXClientWebSocketConnection: WebSocketConnection, Sendable {
    let messages: AsyncThrowingStream<WebSocketMessage, any Error>
    private let fd: Int32
    private let closed = Mutex(false)
    private let writeLock = Mutex(())
    private let readTask = Mutex<Task<Void, Never>?>(nil)

    static func connect(
        host: String,
        port: Int,
        path: String,
        headers: [String: String]
    ) async throws -> POSIXClientWebSocketConnection {
        let fd = try openTCP(host: host, port: port)
        do {
            var keyBytes: [UInt8] = []
            keyBytes.reserveCapacity(16)
            for _ in 0..<16 {
                keyBytes.append(UInt8.random(in: 0...255))
            }
            let wsKey = Data(keyBytes).base64EncodedString()

            var req = "GET \(path) HTTP/1.1\r\n"
            let hostHeader = (port == 80) ? host : "\(host):\(port)"
            var hasHost = false
            for (k, v) in headers {
                if k.lowercased() == "host" { hasHost = true }
                req += "\(k): \(v)\r\n"
            }
            if !hasHost {
                req += "Host: \(hostHeader)\r\n"
            }
            req += "Upgrade: websocket\r\n"
            req += "Connection: Upgrade\r\n"
            req += "Sec-WebSocket-Key: \(wsKey)\r\n"
            req += "Sec-WebSocket-Version: 13\r\n\r\n"

            guard writeAll(fd: fd, bytes: Array(req.utf8)) else {
                throw WebSocketTransportError.networkFailure("Failed to write WebSocket upgrade request")
            }

            var buf: [UInt8] = []
            var headerEnd: Int?
            while headerEnd == nil {
                guard let chunk = readChunk(fd: fd, maxBytes: 4096), !chunk.isEmpty else {
                    throw WebSocketTransportError.upgradeFailed(statusCode: nil, detail: "EOF during handshake")
                }
                buf.append(contentsOf: chunk)
                if buf.count >= 4 {
                    for i in 0...(buf.count - 4) {
                        if buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 {
                            headerEnd = i + 4
                            break
                        }
                    }
                }
                if buf.count > 64 * 1024 {
                    throw WebSocketTransportError.upgradeFailed(statusCode: nil, detail: "Response headers too large")
                }
            }
            let endIdx = headerEnd!
            let headerStr = String(decoding: buf[0..<endIdx], as: UTF8.self)
            let leftover = Array(buf[endIdx...])
            let firstLine = headerStr.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let statusCode = parts.count >= 2 ? Int(parts[1]) : nil
            guard statusCode == 101 else {
                throw WebSocketTransportError.upgradeFailed(statusCode: statusCode, detail: firstLine)
            }
            return POSIXClientWebSocketConnection(fd: fd, initialBuffer: leftover)
        } catch {
            _ = POSIXSocketLibC.close(fd)
            throw error
        }
    }

    private init(fd: Int32, initialBuffer: [UInt8]) {
        self.fd = fd
        let (stream, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
        self.messages = stream

        let fdCopy = fd
        let initial = initialBuffer
        let task = Task.detached { [weak self] in
            var buffer = initial
            while let self, !Task.isCancelled, !self.closed.withLock({ $0 }) {
                guard let frame = Self.readFrame(fd: fdCopy, buffer: &buffer) else {
                    if self.closed.withLock({ $0 }) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: WebSocketTransportError.networkFailure("WebSocket stream ended"))
                    }
                    return
                }
                switch frame.opcode {
                case 0x1:
                    continuation.yield(.text(String(decoding: frame.payload, as: UTF8.self)))
                case 0x2:
                    continuation.yield(.binary(frame.payload))
                case 0x8:
                    let code: Int
                    let reason: String
                    if frame.payload.count >= 2 {
                        code = (Int(frame.payload[0]) << 8) | Int(frame.payload[1])
                        reason = String(decoding: frame.payload.dropFirst(2), as: UTF8.self)
                    } else {
                        code = 1000
                        reason = ""
                    }
                    let event = WebSocketCloseEvent(code: code, reason: reason)
                    await self.sendCloseFrame(code: code, reason: reason)
                    continuation.finish(throwing: WebSocketTransportError.closed(event))
                    return
                case 0x9:
                    self.writeMaskedFrame(opcode: 0xA, payload: frame.payload)
                default:
                    continue
                }
            }
            continuation.finish()
        }
        readTask.withLock { $0 = task }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard !closed.withLock({ $0 }) else {
            throw WebSocketTransportError.closed(WebSocketCloseEvent(code: 1000, reason: "closed"))
        }
        let ok: Bool
        switch message {
        case .text(let s):
            ok = writeMaskedFrame(opcode: 0x1, payload: Array(s.utf8))
        case .binary(let b):
            ok = writeMaskedFrame(opcode: 0x2, payload: b)
        }
        if !ok {
            throw WebSocketTransportError.networkFailure("Failed to write WebSocket frame")
        }
    }

    func close(code: Int, reason: String) async {
        await sendCloseFrame(code: code, reason: reason)
        let task = readTask.withLock { t -> Task<Void, Never>? in
            let old = t
            t = nil
            return old
        }
        task?.cancel()
    }

    private func sendCloseFrame(code: Int, reason: String) async {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
        var payload: [UInt8] = [UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        payload.append(contentsOf: reason.utf8)
        _ = writeMaskedFrame(opcode: 0x8, payload: payload)
        _ = shutdown(fd, Int32(SHUT_RDWR))
        _ = POSIXSocketLibC.close(fd)
    }

    @discardableResult
    private func writeMaskedFrame(opcode: UInt8, payload: [UInt8]) -> Bool {
        var mask: [UInt8] = [
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
        ]
        var frame: [UInt8] = [0x80 | (opcode & 0x0F)]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let len64 = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len64 >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        frame.reserveCapacity(frame.count + payload.count)
        for i in 0..<payload.count {
            frame.append(payload[i] ^ mask[i & 3])
        }
        return writeLock.withLock { Self.writeAll(fd: fd, bytes: frame) }
    }

    private struct RawFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private static func openTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw WebSocketTransportError.networkFailure("DNS resolution failed for \(host):\(port)")
        }
        defer { freeaddrinfo(first) }
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let addr = cur {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                if POSIXSocketLibC.connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return fd
                }
                _ = POSIXSocketLibC.close(fd)
            }
            cur = addr.pointee.ai_next
        }
        throw WebSocketTransportError.networkFailure("Unable to connect to \(host):\(port)")
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = POSIXSocketLibC.send(fd, base.advanced(by: sent), raw.count - sent, Int32(MSG_NOSIGNAL))
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func readChunk(fd: Int32, maxBytes: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBytes { raw in
            POSIXSocketLibC.recv(fd, raw.baseAddress, maxBytes, 0)
        }
        if n <= 0 { return nil }
        return Array(buf.prefix(n))
    }

    private static func ensureBytes(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        while buffer.count < count {
            guard let chunk = readChunk(fd: fd, maxBytes: 8192), !chunk.isEmpty else { return false }
            buffer.append(contentsOf: chunk)
        }
        return true
    }

    private static func readFrame(fd: Int32, buffer: inout [UInt8]) -> RawFrame? {
        guard ensureBytes(fd: fd, buffer: &buffer, count: 2) else { return nil }
        let b0 = buffer[0]
        let b1 = buffer[1]
        buffer.removeFirst(2)
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var length = Int(b1 & 0x7F)
        if length == 126 {
            guard ensureBytes(fd: fd, buffer: &buffer, count: 2) else { return nil }
            length = (Int(buffer[0]) << 8) | Int(buffer[1])
            buffer.removeFirst(2)
        } else if length == 127 {
            guard ensureBytes(fd: fd, buffer: &buffer, count: 8) else { return nil }
            var len64: UInt64 = 0
            for i in 0..<8 { len64 = (len64 << 8) | UInt64(buffer[i]) }
            buffer.removeFirst(8)
            guard len64 <= UInt64(16 * 1024 * 1024) else { return nil }
            length = Int(len64)
        }
        var maskKey: [UInt8] = []
        if masked {
            guard ensureBytes(fd: fd, buffer: &buffer, count: 4) else { return nil }
            maskKey = Array(buffer.prefix(4))
            buffer.removeFirst(4)
        }
        guard ensureBytes(fd: fd, buffer: &buffer, count: length) else { return nil }
        var payload = Array(buffer.prefix(length))
        buffer.removeFirst(length)
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i & 3] }
        }
        return RawFrame(opcode: opcode, payload: payload)
    }
}
#endif

// MARK: - Deterministic Cross-Platform In-Memory WebSocket Pair & Mock Transport

/// Full-duplex in-memory `WebSocketConnection` pair usable on every Swift platform (including WASI).
public final class InMemoryWebSocketConnection: WebSocketConnection, Sendable {
    public let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    private struct State: Sendable {
        var closed: Bool = false
        var closeEvent: WebSocketCloseEvent?
        var sentMessages: [WebSocketMessage] = []
    }

    private let state = Mutex(State())
    private let ownContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
    private let peerContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation

    private init(
        messages: AsyncThrowingStream<WebSocketMessage, any Error>,
        ownContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation,
        peerContinuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
    ) {
        self.messages = messages
        self.ownContinuation = ownContinuation
        self.peerContinuation = peerContinuation
    }

    public static func makePair() -> (client: InMemoryWebSocketConnection, server: InMemoryWebSocketConnection) {
        let (clientStream, clientCont) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
        let (serverStream, serverCont) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
        let client = InMemoryWebSocketConnection(
            messages: clientStream,
            ownContinuation: clientCont,
            peerContinuation: serverCont
        )
        let server = InMemoryWebSocketConnection(
            messages: serverStream,
            ownContinuation: serverCont,
            peerContinuation: clientCont
        )
        return (client, server)
    }

    public var isClosed: Bool { state.withLock { $0.closed } }
    public var closeEvent: WebSocketCloseEvent? { state.withLock { $0.closeEvent } }
    public var sentMessages: [WebSocketMessage] { state.withLock { $0.sentMessages } }

    public func send(_ message: WebSocketMessage) async throws {
        let isClosed = state.withLock { s -> Bool in
            if s.closed { return true }
            s.sentMessages.append(message)
            return false
        }
        if isClosed {
            throw WebSocketTransportError.closed(WebSocketCloseEvent(code: 1000, reason: "closed"))
        }
        peerContinuation.yield(message)
    }

    public func close(code: Int = 1000, reason: String = "") async {
        let shouldClose = state.withLock { s -> Bool in
            if s.closed { return false }
            s.closed = true
            s.closeEvent = WebSocketCloseEvent(code: code, reason: reason)
            return true
        }
        guard shouldClose else { return }
        ownContinuation.finish()
        peerContinuation.finish(throwing: WebSocketTransportError.closed(WebSocketCloseEvent(code: code, reason: reason)))
    }
}

/// Programmable mock `WebSocketTransport` recording every connection attempt and delegating to a handler.
public final class MockWebSocketTransport: WebSocketTransport, Sendable {
    public struct RecordedConnect: Equatable, Sendable {
        public let url: String
        public let headers: [String: String]
        public let protocols: [String]

        public init(url: String, headers: [String: String], protocols: [String]) {
            self.url = url
            self.headers = headers
            self.protocols = protocols
        }
    }

    private struct State: Sendable {
        var attempts: [RecordedConnect] = []
        var handler: @Sendable (RecordedConnect) async throws -> any WebSocketConnection
    }

    private let state: Mutex<State>

    public init(
        handler: @escaping @Sendable (RecordedConnect) async throws -> any WebSocketConnection
    ) {
        self.state = Mutex(State(handler: handler))
    }

    public var recordedConnects: [RecordedConnect] {
        state.withLock { $0.attempts }
    }

    public func setHandler(_ handler: @escaping @Sendable (RecordedConnect) async throws -> any WebSocketConnection) {
        state.withLock { $0.handler = handler }
    }

    public func connect(
        url: String,
        headers: [String: String] = [:],
        protocols: [String] = []
    ) async throws -> any WebSocketConnection {
        let attempt = RecordedConnect(url: url, headers: headers, protocols: protocols)
        let handler = state.withLock { s -> (@Sendable (RecordedConnect) async throws -> any WebSocketConnection) in
            s.attempts.append(attempt)
            return s.handler
        }
        return try await handler(attempt)
    }
}
