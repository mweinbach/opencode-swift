import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization

// MARK: - HTTP Request / Response Primitives

public struct OpenTunnelHTTPRequest: Equatable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: [UInt8]?
    public let proxy: OpenTunnelProxyConfig?

    public init(
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: [UInt8]? = nil,
        proxy: OpenTunnelProxyConfig? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.proxy = proxy
    }
}

public struct OpenTunnelHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: [UInt8]

    public init(statusCode: Int, headers: [String: String] = [:], body: [UInt8] = []) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }

    public var bodyString: String {
        String(decoding: body, as: UTF8.self)
    }
}

// MARK: - WebSocket Primitives

public enum OpenTunnelWebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
    case close(code: Int, reason: String)
}

public protocol OpenTunnelWebSocket: Sendable {
    var incoming: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error> { get }
    func send(_ frame: OpenTunnelWebSocketFrame) async throws
    func close(code: Int, reason: String) async
}

public extension OpenTunnelWebSocket {
    func close() async {
        await close(code: 1000, reason: "")
    }
}

// MARK: - Local Target Full-Duplex Byte Stream (HTTP / SSE / WebSocket)

public protocol OpenTunnelByteStream: Sendable {
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func write(_ bytes: [UInt8]) async throws
    func finishWriting() async
    func close() async
}

// MARK: - Optional Server-Side TLS Termination Adapter

public protocol OpenTunnelTLSSession: Sendable {
    func feedEncrypted(_ bytes: [UInt8]) async throws
    func writePlaintext(_ bytes: [UInt8]) async throws
    func finishInbound() async
    func finishOutbound() async
    func close() async
}

public protocol OpenTunnelTLSAdapter: Sendable {
    func createServerSession(
        identity: OpenTunnelIdentity,
        sni: String,
        sendEncrypted: @escaping @Sendable ([UInt8]) async throws -> Void,
        onPlaintext: @escaping @Sendable ([UInt8]) async throws -> Void,
        onClosed: @escaping @Sendable (String?) async -> Void
    ) async throws -> any OpenTunnelTLSSession
}

// MARK: - OpenTunnelTransport Protocol

/// Pluggable network transport for OpenTunnel REST API calls, bridge WebSocket sessions,
/// and local reverse-proxy connections (`127.0.0.1:<port>`).
public protocol OpenTunnelTransport: Sendable {
    func sendHTTP(_ request: OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse
    func openWebSocket(
        url: String,
        protocols: [String],
        headers: [String: String],
        proxy: OpenTunnelProxyConfig?
    ) async throws -> any OpenTunnelWebSocket
    func openLocalConnection(target: OpenTunnelTarget) async throws -> any OpenTunnelByteStream
}

// MARK: - In-Memory Test & Embedding Primitives

/// Full-duplex in-memory WebSocket pair usable on every Swift platform (including iOS and WASI).
public final class InMemoryOpenTunnelWebSocket: OpenTunnelWebSocket, Sendable {
    public let incoming: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>
    private let peerContinuation: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation
    private let ownContinuation: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation
    private let closed = Mutex(false)

    private init(
        incoming: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>,
        ownContinuation: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation,
        peerContinuation: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation
    ) {
        self.incoming = incoming
        self.ownContinuation = ownContinuation
        self.peerContinuation = peerContinuation
    }

    public static func makePair() -> (client: InMemoryOpenTunnelWebSocket, server: InMemoryOpenTunnelWebSocket) {
        var clientContStorage: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation?
        var serverContStorage: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation?
        let clientIn = AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error> { clientContStorage = $0 }
        let serverIn = AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error> { serverContStorage = $0 }
        let clientCont = clientContStorage!
        let serverCont = serverContStorage!
        let client = InMemoryOpenTunnelWebSocket(incoming: clientIn, ownContinuation: clientCont, peerContinuation: serverCont)
        let server = InMemoryOpenTunnelWebSocket(incoming: serverIn, ownContinuation: serverCont, peerContinuation: clientCont)
        return (client, server)
    }

    public func send(_ frame: OpenTunnelWebSocketFrame) async throws {
        let isClosed = closed.withLock { $0 }
        guard !isClosed else {
            throw OpenTunnelClientError.transient("WebSocket is closed")
        }
        peerContinuation.yield(frame)
        if case .close = frame {
            closed.withLock { $0 = true }
            peerContinuation.finish()
        }
    }

    public func close(code: Int = 1000, reason: String = "") async {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldClose {
            peerContinuation.yield(.close(code: code, reason: reason))
            peerContinuation.finish()
            ownContinuation.finish()
        }
    }

    /// Terminates the peer's incoming stream abruptly with an error (simulating network EOF/reset).
    public func failPeer(with error: any Error & Sendable) {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldClose {
            peerContinuation.finish(throwing: error)
            ownContinuation.finish()
        }
    }
}

/// Full-duplex in-memory byte stream pair for testing HTTP/SSE/WS forwarding without sockets.
public final class InMemoryOpenTunnelByteStream: OpenTunnelByteStream, Sendable {
    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let ownContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let peerContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let writeClosed = Mutex(false)
    private let closed = Mutex(false)

    private init(
        incoming: AsyncThrowingStream<[UInt8], any Error>,
        ownContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation,
        peerContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    ) {
        self.incoming = incoming
        self.ownContinuation = ownContinuation
        self.peerContinuation = peerContinuation
    }

    public static func makePair() -> (client: InMemoryOpenTunnelByteStream, server: InMemoryOpenTunnelByteStream) {
        var clientContStorage: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        var serverContStorage: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        let clientIn = AsyncThrowingStream<[UInt8], any Error> { clientContStorage = $0 }
        let serverIn = AsyncThrowingStream<[UInt8], any Error> { serverContStorage = $0 }
        let clientCont = clientContStorage!
        let serverCont = serverContStorage!
        let client = InMemoryOpenTunnelByteStream(incoming: clientIn, ownContinuation: clientCont, peerContinuation: serverCont)
        let server = InMemoryOpenTunnelByteStream(incoming: serverIn, ownContinuation: serverCont, peerContinuation: clientCont)
        return (client, server)
    }

    public func write(_ bytes: [UInt8]) async throws {
        let isClosed = writeClosed.withLock { $0 } || closed.withLock { $0 }
        guard !isClosed else {
            throw OpenTunnelClientError.transient("Local byte stream is closed")
        }
        if !bytes.isEmpty {
            peerContinuation.yield(bytes)
        }
    }

    public func finishWriting() async {
        let shouldFinish = writeClosed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldFinish {
            peerContinuation.finish()
        }
    }

    public func close() async {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldClose {
            writeClosed.withLock { $0 = true }
            peerContinuation.finish()
            ownContinuation.finish()
        }
    }
}

// MARK: - Live Cross-Platform OpenTunnelTransport

/// Default live `OpenTunnelTransport` using `URLSession` for HTTP(S)/WebSocket control
/// and POSIX full-duplex TCP sockets for local HTTP/SSE/WebSocket reverse-proxy forwarding.
public final class LiveOpenTunnelTransport: OpenTunnelTransport, Sendable {
    public static let shared = LiveOpenTunnelTransport()

    public let requestTimeoutSeconds: Double

    public init(requestTimeoutSeconds: Double = 30) {
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public func sendHTTP(_ request: OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse {
        #if os(WASI)
        _ = request
        throw OpenTunnelClientError.transient("Live HTTP transport is unavailable on WASI")
        #else
        guard let url = URL(string: request.url) else {
            throw OpenTunnelClientError(message: "Invalid OpenTunnel API URL: \(request.url)")
        }

        let config = makeSessionConfiguration(proxy: request.proxy)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = requestTimeoutSeconds
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let auth = request.proxy?.basicAuthorizationHeader {
            urlRequest.setValue(auth, forHTTPHeaderField: "Proxy-Authorization")
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }

        #if canImport(Darwin)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return try buildHTTPResponse(data: data, response: response)
        } catch let err as OpenTunnelClientError {
            throw err
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenTunnelClientError.transient("HTTP request failed: \(error)", cause: error)
        }
        #else
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: OpenTunnelClientError.transient("HTTP request failed: \(error)", cause: error))
                    return
                }
                guard let response else {
                    continuation.resume(throwing: OpenTunnelClientError.transient("Missing HTTP response"))
                    return
                }
                do {
                    let built = try self.buildHTTPResponse(data: data ?? Data(), response: response)
                    continuation.resume(returning: built)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
        #endif
        #endif
    }

    public func openWebSocket(
        url: String,
        protocols: [String],
        headers: [String: String],
        proxy: OpenTunnelProxyConfig?
    ) async throws -> any OpenTunnelWebSocket {
        #if canImport(Darwin)
        guard let parsedURL = URL(string: url) else {
            throw OpenTunnelClientError(message: "Invalid OpenTunnel WebSocket URL: \(url)")
        }
        let config = makeSessionConfiguration(proxy: proxy)
        let session = URLSession(configuration: config)
        var urlRequest = URLRequest(url: parsedURL)
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if !protocols.isEmpty {
            urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        if let auth = proxy?.basicAuthorizationHeader {
            urlRequest.setValue(auth, forHTTPHeaderField: "Proxy-Authorization")
        }
        let wsTask = session.webSocketTask(with: urlRequest)
        wsTask.maximumMessageSize = 1024 * 1024
        wsTask.resume()
        return DarwinURLSessionWebSocket(session: session, task: wsTask)
        #else
        _ = (url, protocols, headers, proxy)
        throw OpenTunnelClientError.transient("Live WebSocket transport requires Darwin URLSessionWebSocketTask or an injected OpenTunnelTransport")
        #endif
    }

    public func openLocalConnection(target: OpenTunnelTarget) async throws -> any OpenTunnelByteStream {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return try await POSIXLocalTCPStream.connect(host: target.host, port: target.port)
        #else
        _ = target
        throw OpenTunnelClientError.transient("Live local TCP forwarding is unavailable on this platform")
        #endif
    }

    #if !os(WASI)
    private func makeSessionConfiguration(proxy: OpenTunnelProxyConfig?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = max(requestTimeoutSeconds * 4, 120)
        #if canImport(Darwin)
        if let proxy {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxy.host,
                "HTTPPort": proxy.port,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxy.host,
                "HTTPSPort": proxy.port,
            ]
        }
        #endif
        return config
    }

    private func buildHTTPResponse(data: Data, response: URLResponse) throws -> OpenTunnelHTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw OpenTunnelClientError.transient("Non-HTTP response received from OpenTunnel API")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return OpenTunnelHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: Array(data)
        )
    }
    #endif
}

// MARK: - Darwin URLSessionWebSocketTask Wrapper

#if canImport(Darwin)
internal final class DarwinURLSessionWebSocket: OpenTunnelWebSocket, Sendable {
    public let incoming: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let closed = Mutex(false)
    private let receiveTask: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task

        var contStorage: AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error>.Continuation?
        let stream = AsyncThrowingStream<OpenTunnelWebSocketFrame, any Error> { contStorage = $0 }
        let continuation = contStorage!
        self.incoming = stream

        let loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        continuation.yield(.text(text))
                    case .data(let data):
                        continuation.yield(.binary(Array(data)))
                    @unknown default:
                        break
                    }
                } catch {
                    let wasClosed = self?.closed.withLock { $0 } ?? true
                    if wasClosed || Task.isCancelled {
                        continuation.yield(.close(code: 1000, reason: ""))
                        continuation.finish()
                    } else {
                        let code = task.closeCode.rawValue
                        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? String(describing: error)
                        if code > 0 {
                            continuation.yield(.close(code: code, reason: reason))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: OpenTunnelClientError.transient("Bridge WebSocket closed: \(reason)", cause: error))
                        }
                    }
                    return
                }
            }
            continuation.finish()
        }
        self.receiveTask.withLock { $0 = loop }
    }

    func send(_ frame: OpenTunnelWebSocketFrame) async throws {
        guard !closed.withLock({ $0 }) else {
            throw OpenTunnelClientError.transient("Bridge WebSocket is closed")
        }
        switch frame {
        case .text(let text):
            try await task.send(.string(text))
        case .binary(let bytes):
            try await task.send(.data(Data(bytes)))
        case let .close(code, reason):
            await close(code: code, reason: reason)
        }
    }

    func close(code: Int, reason: String) async {
        let shouldClose = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldClose else { return }
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

// MARK: - POSIX Full-Duplex Local TCP Stream (HTTP / SSE / WebSocket)

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
internal final class POSIXLocalTCPStream: OpenTunnelByteStream, Sendable {
    private final class SocketHandle: Sendable {
        let fd: Mutex<Int32?>
        let writeLock = Mutex(())

        init(fd: Int32) {
            self.fd = Mutex(fd)
        }

        func closeIfOpen() {
            if let activeFD = fd.withLock({ f -> Int32? in
                let prev = f
                f = nil
                return prev
            }) {
                #if canImport(Darwin)
                _ = Darwin.shutdown(activeFD, SHUT_RDWR)
                _ = Darwin.close(activeFD)
                #elseif canImport(Glibc)
                _ = Glibc.shutdown(activeFD, Int32(SHUT_RDWR))
                _ = Glibc.close(activeFD)
                #elseif canImport(Musl)
                _ = Musl.shutdown(activeFD, Int32(SHUT_RDWR))
                _ = Musl.close(activeFD)
                #endif
            }
        }
    }

    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let handle: SocketHandle
    private let readTaskBox: Mutex<Task<Void, Never>?> = Mutex(nil)

    static func connect(host: String, port: Int) async throws -> POSIXLocalTCPStream {
        try await Task.detached {
            let fd = try openConnectedSocket(host: host, port: port)
            return POSIXLocalTCPStream(fd: fd)
        }.value
    }

    private init(fd: Int32) {
        let handle = SocketHandle(fd: fd)
        self.handle = handle
        var contStorage: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        let stream = AsyncThrowingStream<[UInt8], any Error> { contStorage = $0 }
        let continuation = contStorage!
        self.incoming = stream

        let reader = Task.detached {
            var buffer = [UInt8](repeating: 0, count: OpenTunnelBridgeProtocol.maxDataPayloadSize)
            while !Task.isCancelled {
                guard let activeFD = handle.fd.withLock({ $0 }) else {
                    continuation.finish()
                    return
                }
                var pfd = pollfd(fd: activeFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if ready == 0 {
                    continue
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    if handle.fd.withLock({ $0 }) == nil {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: OpenTunnelClientError.transient("Local target poll failed (errno \(errno))"))
                    }
                    return
                }
                if (pfd.revents & Int16(POLLNVAL)) != 0 {
                    continuation.finish()
                    return
                }
                let received: Int = buffer.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return 0 }
                    return Int(recv(activeFD, base, raw.count, 0))
                }
                if received > 0 {
                    continuation.yield(Array(buffer[0..<received]))
                } else if received == 0 {
                    continuation.finish()
                    return
                } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    if handle.fd.withLock({ $0 }) == nil {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: OpenTunnelClientError.transient("Local target read failed (errno \(errno))"))
                    }
                    return
                }
            }
            continuation.finish()
        }
        self.readTaskBox.withLock { $0 = reader }
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let handle = self.handle
        try await Task.detached {
            try handle.writeLock.withLock { _ in
                guard let activeFD = handle.fd.withLock({ $0 }) else {
                    throw OpenTunnelClientError.transient("Local target connection is closed")
                }
                var sent = 0
                while sent < bytes.count {
                    let n: Int = bytes.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return 0 }
                        #if canImport(Darwin)
                        return Int(Darwin.send(activeFD, base.advanced(by: sent), bytes.count - sent, 0))
                        #elseif canImport(Glibc)
                        return Int(Glibc.send(activeFD, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL)))
                        #elseif canImport(Musl)
                        return Int(Musl.send(activeFD, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL)))
                        #endif
                    }
                    if n > 0 {
                        sent += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        throw OpenTunnelClientError.transient("Local target write failed (errno \(errno))")
                    }
                }
            }
        }.value
    }

    func finishWriting() async {
        guard let activeFD = handle.fd.withLock({ $0 }) else { return }
        #if canImport(Darwin)
        _ = Darwin.shutdown(activeFD, SHUT_WR)
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(activeFD, Int32(SHUT_WR))
        #elseif canImport(Musl)
        _ = Musl.shutdown(activeFD, Int32(SHUT_WR))
        #endif
    }

    func close() async {
        let reader = readTaskBox.withLock { t -> Task<Void, Never>? in
            let prev = t
            t = nil
            return prev
        }
        reader?.cancel()
        handle.closeIfOpen()
    }

    deinit {
        let reader = readTaskBox.withLock { t -> Task<Void, Never>? in
            let prev = t
            t = nil
            return prev
        }
        reader?.cancel()
        handle.closeIfOpen()
    }

    private static func openConnectedSocket(host: String, port: Int) throws -> Int32 {
        let cleanHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var resPtr: UnsafeMutablePointer<addrinfo>? = nil
        let gaiStatus = cleanHost.withCString { hostC in
            String(port).withCString { portC in
                getaddrinfo(hostC, portC, &hints, &resPtr)
            }
        }
        guard gaiStatus == 0, let first = resPtr else {
            throw OpenTunnelClientError.transient("Failed to resolve local target \(host):\(port) (gai \(gaiStatus))")
        }
        defer { freeaddrinfo(first) }

        var lastErrno: Int32 = ECONNREFUSED
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                var one: Int32 = 1
                _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                #if canImport(Darwin)
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                let connected: Int32
                #if canImport(Darwin)
                connected = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
                #elseif canImport(Glibc)
                connected = Glibc.connect(fd, info.ai_addr, info.ai_addrlen)
                #elseif canImport(Musl)
                connected = Musl.connect(fd, info.ai_addr, info.ai_addrlen)
                #endif
                if connected == 0 {
                    return fd
                }
                lastErrno = errno
                #if canImport(Darwin)
                _ = Darwin.close(fd)
                #elseif canImport(Glibc)
                _ = Glibc.close(fd)
                #elseif canImport(Musl)
                _ = Musl.close(fd)
                #endif
            } else {
                lastErrno = errno
            }
            cursor = info.ai_next
        }
        throw OpenTunnelClientError.transient("Failed to connect to local target \(host):\(port) (errno \(lastErrno))")
    }
}
#endif
