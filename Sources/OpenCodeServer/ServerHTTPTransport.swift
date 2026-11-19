#if canImport(FoundationEssentials)
import FoundationEssentials
#else
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
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Cross-Platform HTTP Server Request / Response / WebSocket Primitives

public struct ServerWebSocketCloseEvent: Equatable, Hashable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int = 1000, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

public enum ServerWebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
    case close(ServerWebSocketCloseEvent)
}

public protocol ServerWebSocketConnection: Sendable {
    var incoming: AsyncStream<ServerWebSocketFrame> { get }
    func send(_ frame: ServerWebSocketFrame) async throws
    func close(code: Int, reason: String) async
}

/// Full-duplex in-memory WebSocket pair usable on every Swift platform (including WASI and iOS).
public final class InMemoryServerWebSocket: ServerWebSocketConnection, Sendable {
    public let incoming: AsyncStream<ServerWebSocketFrame>
    private let peerContinuation: AsyncStream<ServerWebSocketFrame>.Continuation
    private let closed = Mutex(false)

    private init(
        incoming: AsyncStream<ServerWebSocketFrame>,
        peerContinuation: AsyncStream<ServerWebSocketFrame>.Continuation
    ) {
        self.incoming = incoming
        self.peerContinuation = peerContinuation
    }

    public static func makePair() -> (client: InMemoryServerWebSocket, server: InMemoryServerWebSocket) {
        let (clientIn, clientCont) = AsyncStream<ServerWebSocketFrame>.makeStream()
        let (serverIn, serverCont) = AsyncStream<ServerWebSocketFrame>.makeStream()
        let client = InMemoryServerWebSocket(incoming: clientIn, peerContinuation: serverCont)
        let server = InMemoryServerWebSocket(incoming: serverIn, peerContinuation: clientCont)
        return (client, server)
    }

    public func send(_ frame: ServerWebSocketFrame) async throws {
        let isClosed = closed.withLock { $0 }
        guard !isClosed else { return }
        peerContinuation.yield(frame)
        if case .close = frame {
            closed.withLock { $0 = true }
            peerContinuation.finish()
        }
    }

    public func close(code: Int = 1000, reason: String = "") async {
        let already = closed.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        if !already {
            peerContinuation.yield(.close(ServerWebSocketCloseEvent(code: code, reason: reason)))
            peerContinuation.finish()
        }
    }
}

public struct ServerHTTPRequest: Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: [UInt8]
    public let parsedURL: ServerParsedURL
    public let cookies: [String: String]
    public let upgradeWebSocket: (@Sendable () async throws -> any ServerWebSocketConnection)?

    public init(
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: [UInt8] = [],
        upgradeWebSocket: (@Sendable () async throws -> any ServerWebSocketConnection)? = nil
    ) {
        self.method = method.uppercased()
        self.url = url
        self.headers = headers
        self.body = body
        self.parsedURL = ServerParsedURL(url)
        self.cookies = ServerHeaders.parseCookies(from: headers)
        self.upgradeWebSocket = upgradeWebSocket
    }

    public func header(_ name: String) -> String? {
        ServerHeaders.value(in: headers, for: name)
    }

    public var pathname: String {
        parsedURL.pathname
    }

    public func query(_ name: String) -> String? {
        parsedURL.queryValue(for: name)
    }

    public func queryAll(_ name: String) -> [String] {
        parsedURL.queryValues(for: name)
    }
}

public enum ServerHTTPBody: Sendable {
    case empty
    case bytes([UInt8])
    case stream(AsyncThrowingStream<[UInt8], any Error>)
}

public struct ServerHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var setCookies: [String]
    public var body: ServerHTTPBody
    /// True when the response represents a completed WebSocket upgrade handled directly on the socket.
    public var webSocketUpgraded: Bool

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        setCookies: [String] = [],
        body: ServerHTTPBody = .empty,
        webSocketUpgraded: Bool = false
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.setCookies = setCookies
        self.body = body
        self.webSocketUpgraded = webSocketUpgraded
    }

    public static func empty(
        statusCode: Int = 204,
        headers: [String: String] = [:],
        setCookies: [String] = []
    ) -> ServerHTTPResponse {
        ServerHTTPResponse(statusCode: statusCode, headers: headers, setCookies: setCookies, body: .empty)
    }

    public static func bytes(
        _ data: [UInt8],
        statusCode: Int = 200,
        contentType: String = "application/octet-stream",
        headers: [String: String] = [:]
    ) -> ServerHTTPResponse {
        var merged = headers
        if ServerHeaders.value(in: merged, for: "content-type") == nil {
            merged["content-type"] = contentType
        }
        return ServerHTTPResponse(statusCode: statusCode, headers: merged, body: .bytes(data))
    }

    public static func text(
        _ value: String,
        statusCode: Int = 200,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) -> ServerHTTPResponse {
        bytes(Array(value.utf8), statusCode: statusCode, contentType: contentType, headers: headers)
    }

    public static func json<T: Encodable>(
        _ value: T,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> ServerHTTPResponse {
        do {
            let encoded = try ServerCodec.encode(value)
            return bytes(encoded, statusCode: statusCode, contentType: "application/json", headers: headers)
        } catch {
            let ref = "err_\(uuid().prefix(8))"
            let fallback = UnknownError(
                message: "Server failed to encode its response. Check server logs for details.",
                ref: ref
            )
            let fallbackBytes = (try? ServerCodec.encode(fallback))
                ?? Array("{\"_tag\":\"UnknownError\",\"message\":\"Encoding failed\"}".utf8)
            return bytes(fallbackBytes, statusCode: 500, contentType: "application/json", headers: headers)
        }
    }

    public static func stream(
        _ chunks: AsyncThrowingStream<[UInt8], any Error>,
        statusCode: Int = 200,
        contentType: String = "application/octet-stream",
        contentLength: Int? = nil,
        headers: [String: String] = [:]
    ) -> ServerHTTPResponse {
        var merged = headers
        if ServerHeaders.value(in: merged, for: "content-type") == nil {
            merged["content-type"] = contentType
        }
        if let contentLength {
            ServerHeaders.set("content-length", value: String(contentLength), in: &merged)
        }
        return ServerHTTPResponse(statusCode: statusCode, headers: merged, body: .stream(chunks))
    }

    public static func redirect(
        to location: String,
        statusCode: Int = 302,
        headers: [String: String] = [:],
        setCookies: [String] = []
    ) -> ServerHTTPResponse {
        var merged = headers
        ServerHeaders.set("location", value: location, in: &merged)
        return ServerHTTPResponse(statusCode: statusCode, headers: merged, setCookies: setCookies, body: .empty)
    }

    public func withHeader(_ name: String, value: String) -> ServerHTTPResponse {
        var copy = self
        ServerHeaders.set(name, value: value, in: &copy.headers)
        return copy
    }

    public func withCookie(
        name: String,
        value: String,
        path: String = "/",
        httpOnly: Bool = true,
        sameSite: String = "Lax",
        maxAgeSeconds: Int? = nil
    ) -> ServerHTTPResponse {
        var parts = ["\(name)=\(value)", "Path=\(path)"]
        if let maxAgeSeconds {
            parts.append("Max-Age=\(maxAgeSeconds)")
        }
        if httpOnly {
            parts.append("HttpOnly")
        }
        if !sameSite.isEmpty {
            parts.append("SameSite=\(sameSite)")
        }
        var copy = self
        copy.setCookies.append(parts.joined(separator: "; "))
        return copy
    }

    public func collectBytes() async throws -> [UInt8] {
        switch body {
        case .empty:
            return []
        case .bytes(let data):
            return data
        case .stream(let stream):
            var out: [UInt8] = []
            for try await chunk in stream {
                out.append(contentsOf: chunk)
            }
            return out
        }
    }
}

public typealias ServerHTTPHandler = @Sendable (ServerHTTPRequest) async -> ServerHTTPResponse

// MARK: - Portable In-Process HTTPTransport Adapter (Works on Every Platform Incl. WASI & iOS)

/// In-process `OpenCodePlatform.HTTPTransport` adapter routing `OpenCodeClient` requests directly
/// into an `OpenCodeServer` handler with full unary and live SSE streaming support.
public final class ServerInProcessTransport: HTTPTransport, Sendable {
    private let handler: ServerHTTPHandler

    public init(handler: @escaping ServerHTTPHandler) {
        self.handler = handler
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let serverReq = makeServerRequest(from: request)
        let serverResp = await handler(serverReq)
        let body = try await serverResp.collectBytes()
        return HTTPResponse(head: makeHead(from: serverResp), body: body)
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let serverReq = makeServerRequest(from: request)
        let serverResp = await handler(serverReq)
        let head = makeHead(from: serverResp)
        switch serverResp.body {
        case .empty:
            let stream = AsyncThrowingStream<[UInt8], Error> { $0.finish() }
            return HTTPStreamingResponse(head: head, chunks: stream)
        case .bytes(let data):
            let stream = AsyncThrowingStream<[UInt8], Error> { cont in
                if !data.isEmpty { cont.yield(data) }
                cont.finish()
            }
            return HTTPStreamingResponse(head: head, chunks: stream)
        case .stream(let chunks):
            return HTTPStreamingResponse(head: head, chunks: chunks)
        }
    }

    private func makeServerRequest(from request: HTTPRequest) -> ServerHTTPRequest {
        let parsed = ServerParsedURL(request.url)
        var headers = request.headers
        if ServerHeaders.value(in: headers, for: "host") == nil, let host = parsed.host {
            headers["host"] = host
        }
        let target = parsed.pathname + parsed.search
        return ServerHTTPRequest(
            method: request.method,
            url: target,
            headers: headers,
            body: request.body ?? []
        )
    }

    private func makeHead(from response: ServerHTTPResponse) -> HTTPResponseHead {
        var headers = response.headers
        if !response.setCookies.isEmpty {
            headers["set-cookie"] = response.setCookies.joined(separator: ", ")
        }
        return HTTPResponseHead(statusCode: response.statusCode, headers: headers)
    }
}

// MARK: - Socket Address Descriptor

public struct ServerSocketAddress: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let isIPv6: Bool

    public init(host: String, port: Int, isIPv6: Bool = false) {
        self.host = host
        self.port = port
        self.isIPv6 = isIPv6
    }

    public var urlString: String {
        let formattedHost = isIPv6 ? "[\(host)]" : host
        return "http://\(formattedHost):\(port)"
    }
}

// MARK: - Server Network Errors

public enum ServerTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case addressInUse(host: String, port: Int)
    case bindFailed(host: String, port: Int, errno: Int32)
    case socketFailed(errno: Int32)
    case unsupportedPlatform(PlatformOS)
    case invalidRequest(String)
    case webSocketUpgradeFailed(String)

    public var description: String {
        switch self {
        case let .addressInUse(host, port):
            return "Address already in use: \(host):\(port)"
        case let .bindFailed(host, port, err):
            return "Failed to bind \(host):\(port) (errno \(err))"
        case .socketFailed(let err):
            return "Socket creation failed (errno \(err))"
        case .unsupportedPlatform(let os):
            return "POSIX TCP server is unsupported on \(os.rawValue)"
        case .invalidRequest(let detail):
            return "Invalid HTTP request: \(detail)"
        case .webSocketUpgradeFailed(let detail):
            return "WebSocket upgrade failed: \(detail)"
        }
    }
}

// MARK: - Cross-Platform HTTP/1.1 + SSE + WebSocket Loopback TCP Server

/// Cross-platform POSIX HTTP/1.1 + SSE + WebSocket TCP server.
/// Uses BSD/POSIX sockets behind `#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)`.
/// On platforms without POSIX sockets (e.g. WASI), `start(...)` throws `ServerTransportError.unsupportedPlatform`.
public final class POSIXHTTPServer: Sendable {
    public let address: ServerSocketAddress
    private let handlerBox: Mutex<ServerHTTPHandler>
    private let stopped = Mutex(false)
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private let listenFD: Int32
    private let activeFDs = Mutex<Set<Int32>>([])
    private let acceptTask = Mutex<Task<Void, Never>?>(nil)
    #endif

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private init(address: ServerSocketAddress, listenFD: Int32, handler: @escaping ServerHTTPHandler) {
        self.address = address
        self.listenFD = listenFD
        self.handlerBox = Mutex(handler)
    }
    #else
    private init(address: ServerSocketAddress, handler: @escaping ServerHTTPHandler) {
        self.address = address
        self.handlerBox = Mutex(handler)
    }
    #endif

    /// Replaces the active request handler atomically (used during server startup transition to ready).
    public func setHandler(_ handler: @escaping ServerHTTPHandler) {
        handlerBox.withLock { $0 = handler }
    }

    /// Binds and starts listening on `hostname` and `port` (pass `port: 0` for ephemeral port,
    /// or `port: nil` to scan `4096...65535` on `EADDRINUSE` matching upstream `ServerProcess.listen`).
    public static func start(
        hostname: String = "127.0.0.1",
        port: Int? = nil,
        handler: @escaping ServerHTTPHandler
    ) throws -> POSIXHTTPServer {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if let explicitPort = port {
            return try bindAndStart(hostname: hostname, port: explicitPort, handler: handler)
        }
        var candidate = 4096
        while candidate <= 65_535 {
            do {
                return try bindAndStart(hostname: hostname, port: candidate, handler: handler)
            } catch ServerTransportError.addressInUse {
                if candidate == 65_535 {
                    throw ServerTransportError.addressInUse(host: hostname, port: candidate)
                }
                candidate += 1
            }
        }
        throw ServerTransportError.addressInUse(host: hostname, port: 65_535)
        #else
        _ = (hostname, port, handler)
        throw ServerTransportError.unsupportedPlatform(Platform.current)
        #endif
    }

    /// Stops accepting new connections and closes all active client sockets.
    public func stop() {
        let alreadyStopped = stopped.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !alreadyStopped else { return }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        acceptTask.withLock { task in
            task?.cancel()
            task = nil
        }
        #if canImport(Darwin)
        _ = Darwin.shutdown(listenFD, SHUT_RDWR)
        _ = Darwin.close(listenFD)
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
        _ = Glibc.close(listenFD)
        #elseif canImport(Musl)
        _ = Musl.shutdown(listenFD, Int32(SHUT_RDWR))
        _ = Musl.close(listenFD)
        #endif
        closeAllConnections()
        #endif
    }

    /// Closes all currently active client connections (matching Node's `server.closeAllConnections()`).
    public func closeAllConnections() {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let fds = activeFDs.withLock { set -> [Int32] in
            let list = Array(set)
            set.removeAll()
            return list
        }
        for fd in fds {
            Self.closeFD(fd)
        }
        #endif
    }

    deinit {
        stop()
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private static func bindAndStart(
        hostname: String,
        port: Int,
        handler: @escaping ServerHTTPHandler
    ) throws -> POSIXHTTPServer {
        let normalizedHost = hostname == "localhost" ? "127.0.0.1" : hostname
        let strippedHost = normalizedHost.hasPrefix("[") && normalizedHost.hasSuffix("]")
            ? String(normalizedHost.dropFirst().dropLast())
            : normalizedHost
        let isIPv6 = strippedHost.contains(":")

        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif
        let family = isIPv6 ? AF_INET6 : AF_INET
        let fd = socket(family, sockType, 0)
        guard fd >= 0 else {
            throw ServerTransportError.socketFailed(errno: errno)
        }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        // Make listening socket non-blocking so accept loop responds cleanly to stop().
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let bindResult: Int32
        if isIPv6 {
            var addr6 = sockaddr_in6()
            #if canImport(Darwin)
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = UInt16(port).bigEndian
            let pton = strippedHost.withCString { inet_pton(AF_INET6, $0, &addr6.sin6_addr) }
            if pton != 1 {
                closeFD(fd)
                throw ServerTransportError.bindFailed(host: hostname, port: port, errno: EINVAL)
            }
            bindResult = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr4 = sockaddr_in()
            #if canImport(Darwin)
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = UInt16(port).bigEndian
            let pton = strippedHost.withCString { inet_pton(AF_INET, $0, &addr4.sin_addr) }
            if pton != 1 {
                closeFD(fd)
                throw ServerTransportError.bindFailed(host: hostname, port: port, errno: EINVAL)
            }
            bindResult = withUnsafePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if bindResult != 0 {
            let err = errno
            closeFD(fd)
            if err == EADDRINUSE {
                throw ServerTransportError.addressInUse(host: hostname, port: port)
            }
            throw ServerTransportError.bindFailed(host: hostname, port: port, errno: err)
        }

        if listen(fd, 128) != 0 {
            let err = errno
            closeFD(fd)
            throw ServerTransportError.bindFailed(host: hostname, port: port, errno: err)
        }

        let boundAddress = queryBoundAddress(fd: fd, isIPv6: isIPv6, fallbackHost: strippedHost, fallbackPort: port)
        let server = POSIXHTTPServer(address: boundAddress, listenFD: fd, handler: handler)
        server.startAcceptLoop()
        return server
    }

    private static func queryBoundAddress(
        fd: Int32,
        isIPv6: Bool,
        fallbackHost: String,
        fallbackPort: Int
    ) -> ServerSocketAddress {
        if isIPv6 {
            var addr = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let res = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getsockname(fd, saPtr, &len)
                }
            }
            if res == 0 {
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var sin6Addr = addr.sin6_addr
                let hostStr: String
                if inet_ntop(AF_INET6, &sin6Addr, &buf, socklen_t(buf.count)) != nil {
                    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    hostStr = String(decoding: bytes, as: UTF8.self)
                } else {
                    hostStr = fallbackHost
                }
                return ServerSocketAddress(host: hostStr, port: Int(UInt16(bigEndian: addr.sin6_port)), isIPv6: true)
            }
            return ServerSocketAddress(host: fallbackHost, port: fallbackPort, isIPv6: true)
        } else {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let res = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getsockname(fd, saPtr, &len)
                }
            }
            if res == 0 {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = addr.sin_addr
                let hostStr: String
                if inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(buf.count)) != nil {
                    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    hostStr = String(decoding: bytes, as: UTF8.self)
                } else {
                    hostStr = fallbackHost
                }
                return ServerSocketAddress(host: hostStr, port: Int(UInt16(bigEndian: addr.sin_port)), isIPv6: false)
            }
            return ServerSocketAddress(host: fallbackHost, port: fallbackPort, isIPv6: false)
        }
    }

    private func startAcceptLoop() {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            while let self, !Task.isCancelled, !self.stopped.withLock({ $0 }) {
                var pfd = pollfd(fd: self.listenFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 0)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    try? await Task.sleep(for: .milliseconds(2))
                    continue
                }
                if (pfd.revents & Int16(POLLNVAL | POLLERR)) != 0 { break }

                var storage = sockaddr_storage()
                var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let clientFD = withUnsafeMutablePointer(to: &storage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        accept(self.listenFD, saPtr, &addrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        try? await Task.sleep(for: .milliseconds(2))
                        continue
                    }
                    break
                }

                #if canImport(Darwin)
                var noSigPipe: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                #endif
                let cflags = fcntl(clientFD, F_GETFL, 0)
                if cflags >= 0 {
                    _ = fcntl(clientFD, F_SETFL, cflags | O_NONBLOCK)
                }

                self.activeFDs.withLock { _ = $0.insert(clientFD) }
                Task.detached { [weak self] in
                    await self?.serveConnection(clientFD)
                }
            }
        }
        acceptTask.withLock { $0 = task }
    }

    private func serveConnection(_ fd: Int32) async {
        defer {
            activeFDs.withLock { _ = $0.remove(fd) }
            Self.closeFD(fd)
        }

        var buffer: [UInt8] = []
        guard let parsed = await readHTTPRequest(fd: fd, buffer: &buffer) else {
            return
        }

        let wsKey = ServerHeaders.value(in: parsed.headers, for: "sec-websocket-key")
        let upgradeHeader = ServerHeaders.value(in: parsed.headers, for: "upgrade")?.lowercased()
        let isWebSocket = upgradeHeader == "websocket" && wsKey != nil
        let upgradedFlag = Mutex(false)

        let initialSnapshot = buffer
        let upgradeClosure: (@Sendable () async throws -> any ServerWebSocketConnection)? = isWebSocket ? { @Sendable () async throws -> any ServerWebSocketConnection in
            guard let key = wsKey else {
                throw ServerTransportError.webSocketUpgradeFailed("Missing Sec-WebSocket-Key")
            }
            let acceptKey = POSIXWebSocketConnection.computeAcceptKey(for: key)
            let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            guard await Self.writeAll(fd: fd, bytes: Array(handshake.utf8)) else {
                throw ServerTransportError.webSocketUpgradeFailed("Failed to send 101 Switching Protocols")
            }
            upgradedFlag.withLock { $0 = true }
            return POSIXWebSocketConnection(fd: fd, initialBuffer: initialSnapshot)
        } : nil

        let request = ServerHTTPRequest(
            method: parsed.method,
            url: parsed.target,
            headers: parsed.headers,
            body: parsed.body,
            upgradeWebSocket: upgradeClosure
        )

        let handler = handlerBox.withLock { $0 }
        let response = await handler(request)

        if upgradedFlag.withLock({ $0 }) || response.webSocketUpgraded {
            return
        }

        await writeHTTPResponse(fd: fd, method: request.method, response: response)
        // Perform graceful TCP half-close (FIN) before close(fd) so macOS/Linux URLSession
        // never sees a premature TCP RST (-1005 NSURLErrorNetworkConnectionLost) while reading.
        #if canImport(Darwin)
        _ = Darwin.shutdown(fd, SHUT_WR)
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_WR))
        #elseif canImport(Musl)
        _ = Musl.shutdown(fd, Int32(SHUT_WR))
        #endif
        _ = await Self.readChunk(fd: fd, maxBytes: 1024, timeoutMs: 25)
    }

    private struct ParsedRawHTTP {
        let method: String
        let target: String
        let headers: [String: String]
        let body: [UInt8]
    }

    private func readHTTPRequest(fd: Int32, buffer: inout [UInt8]) async -> ParsedRawHTTP? {
        let maxHeaderBytes = 64 * 1024
        var headerEndIndex: Int? = nil

        while headerEndIndex == nil {
            if let idx = findCRLFCRLF(in: buffer) {
                headerEndIndex = idx
                break
            }
            if buffer.count > maxHeaderBytes { return nil }
            guard let chunk = await Self.readChunk(fd: fd, maxBytes: 8192, timeoutMs: 5_000) else {
                return nil
            }
            if chunk.isEmpty { return nil }
            buffer.append(contentsOf: chunk)
        }

        guard let headerEnd = headerEndIndex else { return nil }
        let headerBytes = Array(buffer[..<headerEnd])
        let bodyStart = headerEnd + 4
        if bodyStart <= buffer.count {
            buffer.removeFirst(bodyStart)
        } else {
            buffer.removeAll()
        }

        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[name], name == "cookie" {
                headers[name] = "\(existing); \(value)"
            } else if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        if headers["expect"]?.lowercased() == "100-continue" {
            _ = await Self.writeAll(fd: fd, bytes: Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        var body: [UInt8] = []
        if let te = headers["transfer-encoding"]?.lowercased(), te.contains("chunked") {
            guard let decoded = await readChunkedBody(fd: fd, buffer: &buffer) else { return nil }
            body = decoded
        } else if let clStr = headers["content-length"], let contentLength = Int(clStr), contentLength > 0 {
            let maxBody = 64 * 1024 * 1024
            if contentLength > maxBody { return nil }
            body.reserveCapacity(contentLength)
            while buffer.count < contentLength {
                guard let chunk = await Self.readChunk(fd: fd, maxBytes: min(65_536, contentLength - buffer.count), timeoutMs: 10_000),
                      !chunk.isEmpty else {
                    return nil
                }
                buffer.append(contentsOf: chunk)
            }
            body = Array(buffer.prefix(contentLength))
            buffer.removeFirst(contentLength)
        }

        return ParsedRawHTTP(method: method, target: target, headers: headers, body: body)
    }

    private func readChunkedBody(fd: Int32, buffer: inout [UInt8]) async -> [UInt8]? {
        var out: [UInt8] = []
        while true {
            var lineEnd: Int? = nil
            while lineEnd == nil {
                if let idx = findCRLF(in: buffer) {
                    lineEnd = idx
                    break
                }
                guard let chunk = await Self.readChunk(fd: fd, maxBytes: 8192, timeoutMs: 5_000), !chunk.isEmpty else {
                    return nil
                }
                buffer.append(contentsOf: chunk)
            }
            guard let endIdx = lineEnd else { return nil }
            let sizeLine = String(decoding: buffer[..<endIdx], as: UTF8.self)
                .split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            buffer.removeFirst(endIdx + 2)
            guard let chunkSize = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16), chunkSize >= 0 else {
                return nil
            }
            if chunkSize == 0 {
                // Consume trailing CRLF
                while buffer.count < 2 {
                    guard let chunk = await Self.readChunk(fd: fd, maxBytes: 1024, timeoutMs: 2_000), !chunk.isEmpty else {
                        break
                    }
                    buffer.append(contentsOf: chunk)
                }
                if buffer.count >= 2 { buffer.removeFirst(2) }
                return out
            }
            while buffer.count < chunkSize + 2 {
                guard let chunk = await Self.readChunk(fd: fd, maxBytes: 65_536, timeoutMs: 10_000), !chunk.isEmpty else {
                    return nil
                }
                buffer.append(contentsOf: chunk)
            }
            out.append(contentsOf: buffer.prefix(chunkSize))
            buffer.removeFirst(chunkSize + 2)
        }
    }

    private func writeHTTPResponse(fd: Int32, method: String, response: ServerHTTPResponse) async {
        let reason = Self.reasonPhrase(for: response.statusCode)
        var headLines: [String] = ["HTTP/1.1 \(response.statusCode) \(reason)"]
        var normalizedHeaders = response.headers

        let isNoBodyStatus = response.statusCode == 204 || response.statusCode == 304 || (response.statusCode >= 100 && response.statusCode < 200)
        let isHead = method == "HEAD"

        switch response.body {
        case .empty:
            if !isNoBodyStatus && ServerHeaders.value(in: normalizedHeaders, for: "content-length") == nil {
                normalizedHeaders["content-length"] = "0"
            }
            ServerHeaders.set("connection", value: "close", in: &normalizedHeaders)
            for (k, v) in normalizedHeaders.sorted(by: { $0.key < $1.key }) {
                headLines.append("\(k): \(v)")
            }
            for cookie in response.setCookies {
                headLines.append("set-cookie: \(cookie)")
            }
            let headBytes = Array((headLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            _ = await Self.writeAll(fd: fd, bytes: headBytes)

        case .bytes(let data):
            if !isNoBodyStatus {
                ServerHeaders.set("content-length", value: String(data.count), in: &normalizedHeaders)
            }
            ServerHeaders.set("connection", value: "close", in: &normalizedHeaders)
            for (k, v) in normalizedHeaders.sorted(by: { $0.key < $1.key }) {
                headLines.append("\(k): \(v)")
            }
            for cookie in response.setCookies {
                headLines.append("set-cookie: \(cookie)")
            }
            var payload = Array((headLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            if !isNoBodyStatus && !isHead {
                payload.append(contentsOf: data)
            }
            _ = await Self.writeAll(fd: fd, bytes: payload)

        case .stream(let stream):
            let hasExplicitLength = ServerHeaders.value(in: normalizedHeaders, for: "content-length") != nil
            if !hasExplicitLength && !isNoBodyStatus {
                ServerHeaders.set("transfer-encoding", value: "chunked", in: &normalizedHeaders)
            }
            ServerHeaders.set("connection", value: "close", in: &normalizedHeaders)
            for (k, v) in normalizedHeaders.sorted(by: { $0.key < $1.key }) {
                headLines.append("\(k): \(v)")
            }
            for cookie in response.setCookies {
                headLines.append("set-cookie: \(cookie)")
            }
            let headBytes = Array((headLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            guard await Self.writeAll(fd: fd, bytes: headBytes) else { return }
            if isNoBodyStatus || isHead { return }

            do {
                for try await chunk in stream {
                    if stopped.withLock({ $0 }) { break }
                    if chunk.isEmpty { continue }
                    if hasExplicitLength {
                        guard await Self.writeAll(fd: fd, bytes: chunk) else { break }
                    } else {
                        let prefix = "\(String(chunk.count, radix: 16))\r\n"
                        var frame = Array(prefix.utf8)
                        frame.append(contentsOf: chunk)
                        frame.append(contentsOf: [0x0D, 0x0A])
                        guard await Self.writeAll(fd: fd, bytes: frame) else { break }
                    }
                }
                if !hasExplicitLength {
                    _ = await Self.writeAll(fd: fd, bytes: Array("0\r\n\r\n".utf8))
                }
            } catch {
                // Stream failed or client disconnected; closing socket terminates stream.
            }
        }
    }

    private func findCRLFCRLF(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
                return i
            }
        }
        return nil
    }

    private func findCRLF(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        for i in 0...(bytes.count - 2) {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
                return i
            }
        }
        return nil
    }

    fileprivate static func readChunk(fd: Int32, maxBytes: Int, timeoutMs: Int) async -> [UInt8]? {
        let deadlineMs = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadlineMs {
            if Task.isCancelled { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            if (pfd.revents & Int16(POLLERR | POLLNVAL)) != 0 { return nil }
            var buf = [UInt8](repeating: 0, count: maxBytes)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, maxBytes, 0)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    try? await Task.sleep(for: .milliseconds(2))
                    continue
                }
                return nil
            }
            if n == 0 { return [] }
            return Array(buf.prefix(n))
        }
        return nil
    }

    fileprivate static func writeAll(fd: Int32, bytes: [UInt8]) async -> Bool {
        guard !bytes.isEmpty else { return true }
        var written = 0
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags: Int32 = Int32(MSG_NOSIGNAL)
        #endif
        while written < bytes.count {
            if Task.isCancelled { return false }
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: written), bytes.count - written, flags)
            }
            if n > 0 {
                written += n
                continue
            }
            if n == 0 { return false }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, 0)
                if ready < 0 && errno != EINTR { return false }
                if (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 { return false }
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            return false
        }
        return true
    }

    fileprivate static func closeFD(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.shutdown(fd, Int32(SHUT_RDWR))
        _ = Musl.close(fd)
        #endif
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
    #endif
}

// MARK: - RFC 6455 POSIX WebSocket Connection

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
internal final class POSIXWebSocketConnection: ServerWebSocketConnection, Sendable {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    let incoming: AsyncStream<ServerWebSocketFrame>
    private let fd: Int32
    private let closed = Mutex(false)

    static func computeAcceptKey(for clientKey: String) -> String {
        let digest = ServerCrypto.sha1Bytes(Array((clientKey.trimmingCharacters(in: .whitespaces) + guid).utf8))
        return bytesToBase64(digest)
    }

    init(fd: Int32, initialBuffer: [UInt8]) {
        self.fd = fd
        let (stream, continuation) = AsyncStream<ServerWebSocketFrame>.makeStream()
        self.incoming = stream
        let fdCopy = fd
        let initial = initialBuffer
        Task.detached { [weak self] in
            var buf = initial
            while let self, !Task.isCancelled, !self.closed.withLock({ $0 }) {
                guard let frame = await Self.readFrame(fd: fdCopy, buffer: &buf) else {
                    break
                }
                switch frame.opcode {
                case 0x1: // text
                    continuation.yield(.text(String(decoding: frame.payload, as: UTF8.self)))
                case 0x2: // binary
                    continuation.yield(.binary(frame.payload))
                case 0x8: // close
                    let code: Int
                    let reason: String
                    if frame.payload.count >= 2 {
                        code = (Int(frame.payload[0]) << 8) | Int(frame.payload[1])
                        reason = String(decoding: frame.payload.dropFirst(2), as: UTF8.self)
                    } else {
                        code = 1000
                        reason = ""
                    }
                    continuation.yield(.close(ServerWebSocketCloseEvent(code: code, reason: reason)))
                    await self.close(code: code, reason: reason)
                    continuation.finish()
                    return
                case 0x9: // ping -> send pong
                    _ = await Self.writeRawFrame(fd: fdCopy, opcode: 0xA, payload: frame.payload)
                case 0xA: // pong
                    continue
                default:
                    continue
                }
            }
            continuation.finish()
        }
    }

    func send(_ frame: ServerWebSocketFrame) async throws {
        if closed.withLock({ $0 }) { return }
        switch frame {
        case .text(let s):
            _ = await Self.writeRawFrame(fd: fd, opcode: 0x1, payload: Array(s.utf8))
        case .binary(let b):
            _ = await Self.writeRawFrame(fd: fd, opcode: 0x2, payload: b)
        case .close(let ev):
            await close(code: ev.code, reason: ev.reason)
        }
    }

    func close(code: Int, reason: String) async {
        let already = closed.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !already else { return }
        var payload: [UInt8] = [UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        payload.append(contentsOf: reason.utf8)
        _ = await Self.writeRawFrame(fd: fd, opcode: 0x8, payload: payload)
    }

    private struct RawFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private static func ensureBytes(fd: Int32, buffer: inout [UInt8], count: Int) async -> Bool {
        while buffer.count < count {
            guard let chunk = await POSIXHTTPServer.readChunk(fd: fd, maxBytes: 8192, timeoutMs: 30_000),
                  !chunk.isEmpty else {
                return false
            }
            buffer.append(contentsOf: chunk)
        }
        return true
    }

    private static func readFrame(fd: Int32, buffer: inout [UInt8]) async -> RawFrame? {
        guard await ensureBytes(fd: fd, buffer: &buffer, count: 2) else { return nil }
        let b0 = buffer[0]
        let b1 = buffer[1]
        buffer.removeFirst(2)
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var length = Int(b1 & 0x7F)
        if length == 126 {
            guard await ensureBytes(fd: fd, buffer: &buffer, count: 2) else { return nil }
            length = (Int(buffer[0]) << 8) | Int(buffer[1])
            buffer.removeFirst(2)
        } else if length == 127 {
            guard await ensureBytes(fd: fd, buffer: &buffer, count: 8) else { return nil }
            var len64: UInt64 = 0
            for i in 0..<8 {
                len64 = (len64 << 8) | UInt64(buffer[i])
            }
            buffer.removeFirst(8)
            guard len64 <= UInt64(16 * 1024 * 1024) else { return nil }
            length = Int(len64)
        }
        var maskKey: [UInt8] = []
        if masked {
            guard await ensureBytes(fd: fd, buffer: &buffer, count: 4) else { return nil }
            maskKey = Array(buffer.prefix(4))
            buffer.removeFirst(4)
        }
        guard await ensureBytes(fd: fd, buffer: &buffer, count: length) else { return nil }
        var payload = Array(buffer.prefix(length))
        buffer.removeFirst(length)
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        return RawFrame(opcode: opcode, payload: payload)
    }

    private static func writeRawFrame(fd: Int32, opcode: UInt8, payload: [UInt8]) async -> Bool {
        var frame: [UInt8] = [0x80 | (opcode & 0x0F)]
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            let len64 = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len64 >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return await POSIXHTTPServer.writeAll(fd: fd, bytes: frame)
    }
}
#endif
