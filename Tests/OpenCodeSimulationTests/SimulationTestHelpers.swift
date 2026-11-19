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
import OpenCodeServer
import OpenCodeSimulation
import OpenCodeUtil

/// Temporary directory & filesystem utilities for tests (kept out of `import Testing` files for macOS CLT).
enum SimTestFS {
    static func makeTempDir(prefix: String = "opencode-sim-test-") throws -> String {
        let base = SystemEnvironment.shared.temporaryDirectory
        let path = "\(base)/\(prefix)\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func readText(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return String(decoding: data, as: UTF8.self)
    }

    static func writeText(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

/// JSON encoding/decoding helpers for tests (no `import Testing`).
enum SimTestJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        try ServerCodec.encodeString(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try ServerCodec.decode(type, from: text)
    }

    static func parseValue(_ text: String) throws -> JSONValue {
        try ServerCodec.decode(JSONValue.self, from: text)
    }

    static func encodeValue(_ value: JSONValue) throws -> String {
        try ServerCodec.encodeString(value)
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }
}

/// Deterministic advancing clock for recording timeline tests.
final class SimTestClock: Sendable {
    private let currentMs: Mutex<Double>

    init(startMs: Double = 1_000) {
        self.currentMs = Mutex(startMs)
    }

    func now() -> Double {
        currentMs.withLock { $0 }
    }

    func advance(by ms: Double) {
        currentMs.withLock { $0 += ms }
    }
}

/// Async message queue collector wrapping an `InMemoryServerWebSocket` client endpoint.
final class SimTestInMemorySocket: Sendable {
    let client: InMemoryServerWebSocket
    let server: InMemoryServerWebSocket

    private actor Inbox {
        var buffer: [ServerWebSocketFrame] = []
        var waiter: CheckedContinuation<ServerWebSocketFrame?, Never>? = nil
        var ended = false

        func push(_ frame: ServerWebSocketFrame) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: frame)
            } else {
                buffer.append(frame)
            }
        }

        func finish() {
            ended = true
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: nil)
            }
        }

        func next() async -> ServerWebSocketFrame? {
            if !buffer.isEmpty {
                return buffer.removeFirst()
            }
            if ended { return nil }
            return await withCheckedContinuation { cont in
                if !buffer.isEmpty {
                    cont.resume(returning: buffer.removeFirst())
                } else if ended {
                    cont.resume(returning: nil)
                } else {
                    waiter = cont
                }
            }
        }

        func bufferedCount() -> Int {
            buffer.count
        }
    }

    private let inbox = Inbox()
    private let readerTask: Task<Void, Never>

    init() {
        let pair = InMemoryServerWebSocket.makePair()
        self.client = pair.client
        self.server = pair.server
        let inbox = self.inbox
        let incoming = pair.client.incoming
        self.readerTask = Task {
            for await frame in incoming {
                await inbox.push(frame)
                if case .close = frame {
                    break
                }
            }
            await inbox.finish()
        }
    }

    func sendText(_ text: String) async throws {
        try await client.send(.text(text))
    }

    func sendJSON(_ value: JSONValue) async throws {
        try await sendText(try SimTestJSON.encodeValue(value))
    }

    func nextFrame() async -> ServerWebSocketFrame? {
        await inbox.next()
    }

    func nextJSON() async throws -> JSONValue {
        while let frame = await inbox.next() {
            switch frame {
            case .text(let s):
                return try SimTestJSON.parseValue(s)
            case .binary(let b):
                return try SimTestJSON.parseValue(String(decoding: b, as: UTF8.self))
            case .close:
                throw SimulationControlServer.ControlError("WebSocket closed before next JSON message")
            }
        }
        throw SimulationControlServer.ControlError("WebSocket stream ended before next JSON message")
    }

    func bufferedCount() async -> Int {
        await inbox.bufferedCount()
    }

    func close() async {
        await client.close(code: 1000, reason: "")
        readerTask.cancel()
    }
}

/// Real RFC 6455 loopback TCP WebSocket client for testing `POSIXHTTPServer`-backed control servers.
final class SimTestTCPWebSocket: Sendable {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private let fd: Int32
    private let buffer = Mutex<[UInt8]>([])
    private let closed = Mutex(false)

    private init(fd: Int32, initialBuffer: [UInt8]) {
        self.fd = fd
        self.buffer.withLock { $0 = initialBuffer }
    }

    static func connect(url: String) async throws -> SimTestTCPWebSocket {
        guard url.hasPrefix("ws://") else {
            throw SimulationControlServer.ControlError("Expected ws:// URL, got \(url)")
        }
        let rest = url.dropFirst(5)
        let pathIdx = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<pathIdx])
        let path = pathIdx == rest.endIndex ? "/" : String(rest[pathIdx...])
        guard let colon = authority.lastIndex(of: ":"),
              let port = Int(authority[authority.index(after: colon)...])
        else {
            throw SimulationControlServer.ControlError("Invalid ws:// authority: \(authority)")
        }
        let host = String(authority[..<colon])

        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, sockType, 0)
        guard fd >= 0 else {
            throw SimulationControlServer.ControlError("socket() failed with errno \(errno)")
        }

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        let pton = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard pton == 1 else {
            closeFD(fd)
            throw SimulationControlServer.ControlError("inet_pton failed for \(host)")
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                DarwinOrPosixConnect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let err = errno
            closeFD(fd)
            throw SimulationControlServer.ControlError("connect(\(host):\(port)) failed with errno \(err)")
        }

        let key = bytesToBase64(ServerCrypto.randomBytes(16))
        let handshake = "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host):\(port)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        guard try writeAll(fd: fd, bytes: Array(handshake.utf8)) else {
            closeFD(fd)
            throw SimulationControlServer.ControlError("Failed writing WebSocket upgrade request")
        }

        var buf: [UInt8] = []
        var headerEnd: Int? = nil
        while headerEnd == nil {
            let chunk = try await readSome(fd: fd, timeoutMs: 5_000)
            guard !chunk.isEmpty else {
                closeFD(fd)
                throw SimulationControlServer.ControlError("Connection closed during WebSocket handshake")
            }
            buf.append(contentsOf: chunk)
            if buf.count >= 4 {
                for i in 0...(buf.count - 4) {
                    if buf[i] == 0x0D && buf[i + 1] == 0x0A && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A {
                        headerEnd = i
                        break
                    }
                }
            }
        }
        guard let end = headerEnd else {
            closeFD(fd)
            throw SimulationControlServer.ControlError("Incomplete handshake response")
        }
        let headerText = String(decoding: buf[..<end], as: UTF8.self)
        guard headerText.contains("101") else {
            closeFD(fd)
            throw SimulationControlServer.ControlError("Expected 101 Switching Protocols, got: \(headerText)")
        }
        let remaining = Array(buf[(end + 4)...])
        return SimTestTCPWebSocket(fd: fd, initialBuffer: remaining)
    }

    func sendText(_ text: String) throws {
        let payload = Array(text.utf8)
        let mask = ServerCrypto.randomBytes(4)
        var frame: [UInt8] = [0x81] // FIN + text
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
        for i in 0..<payload.count {
            frame.append(payload[i] ^ mask[i % 4])
        }
        guard try Self.writeAll(fd: fd, bytes: frame) else {
            throw SimulationControlServer.ControlError("Failed sending masked WebSocket text frame")
        }
    }

    func sendJSON(_ value: JSONValue) throws {
        try sendText(try SimTestJSON.encodeValue(value))
    }

    func readFrame(timeoutMs: Int = 5_000) async throws -> ServerWebSocketFrame? {
        while true {
            guard try await ensureBytes(2, timeoutMs: timeoutMs) else { return nil }
            let header = buffer.withLock { b -> (UInt8, UInt8) in
                let pair = (b[0], b[1])
                b.removeFirst(2)
                return pair
            }
            let opcode = header.0 & 0x0F
            let masked = (header.1 & 0x80) != 0
            var length = Int(header.1 & 0x7F)
            if length == 126 {
                guard try await ensureBytes(2, timeoutMs: timeoutMs) else { return nil }
                length = buffer.withLock { b -> Int in
                    let len = (Int(b[0]) << 8) | Int(b[1])
                    b.removeFirst(2)
                    return len
                }
            } else if length == 127 {
                guard try await ensureBytes(8, timeoutMs: timeoutMs) else { return nil }
                length = buffer.withLock { b -> Int in
                    var len64: UInt64 = 0
                    for i in 0..<8 { len64 = (len64 << 8) | UInt64(b[i]) }
                    b.removeFirst(8)
                    return Int(len64)
                }
            }
            var maskKey: [UInt8] = []
            if masked {
                guard try await ensureBytes(4, timeoutMs: timeoutMs) else { return nil }
                maskKey = buffer.withLock { b -> [UInt8] in
                    let key = Array(b.prefix(4))
                    b.removeFirst(4)
                    return key
                }
            }
            guard try await ensureBytes(length, timeoutMs: timeoutMs) else { return nil }
            var payload = buffer.withLock { b -> [UInt8] in
                let data = Array(b.prefix(length))
                b.removeFirst(length)
                return data
            }
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            switch opcode {
            case 0x1:
                return .text(String(decoding: payload, as: UTF8.self))
            case 0x2:
                return .binary(payload)
            case 0x8:
                let code = payload.count >= 2 ? (Int(payload[0]) << 8) | Int(payload[1]) : 1000
                let reason = payload.count > 2 ? String(decoding: payload.dropFirst(2), as: UTF8.self) : ""
                return .close(ServerWebSocketCloseEvent(code: code, reason: reason))
            case 0x9, 0xA:
                continue
            default:
                continue
            }
        }
    }

    func readJSON(timeoutMs: Int = 5_000) async throws -> JSONValue {
        guard let frame = try await readFrame(timeoutMs: timeoutMs) else {
            throw SimulationControlServer.ControlError("TCP WebSocket closed before JSON frame")
        }
        switch frame {
        case .text(let s): return try SimTestJSON.parseValue(s)
        case .binary(let b): return try SimTestJSON.parseValue(String(decoding: b, as: UTF8.self))
        case .close: throw SimulationControlServer.ControlError("TCP WebSocket received close frame")
        }
    }

    func close() {
        let already = closed.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !already else { return }
        // Send masked close frame (1000) before shutting down socket.
        let mask = ServerCrypto.randomBytes(4)
        let payload: [UInt8] = [0x03, 0xE8]
        let frame: [UInt8] = [0x88, 0x82, mask[0], mask[1], mask[2], mask[3], payload[0] ^ mask[0], payload[1] ^ mask[1]]
        _ = try? Self.writeAll(fd: fd, bytes: frame)
        Self.closeFD(fd)
    }

    deinit {
        close()
    }

    private func ensureBytes(_ count: Int, timeoutMs: Int) async throws -> Bool {
        while buffer.withLock({ $0.count }) < count {
            let chunk = try await Self.readSome(fd: fd, timeoutMs: timeoutMs)
            if chunk.isEmpty { return false }
            buffer.withLock { $0.append(contentsOf: chunk) }
        }
        return true
    }

    private static func readSome(fd: Int32, timeoutMs: Int) async throws -> [UInt8] {
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return []
            }
            if ready == 0 {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            if (pfd.revents & Int16(POLLERR | POLLNVAL)) != 0 { return [] }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, 8192, 0)
            }
            if n <= 0 { return [] }
            return Array(buf.prefix(n))
        }
        throw SimulationControlServer.ControlError("Timed out reading from test WebSocket")
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) throws -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if n <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }

    private static func DarwinOrPosixConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, addr, len)
        #elseif canImport(Glibc)
        return Glibc.connect(fd, addr, len)
        #elseif canImport(Musl)
        return Musl.connect(fd, addr, len)
        #endif
    }

    private static func closeFD(_ fd: Int32) {
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
    #endif
}

/// Allocates a free ephemeral loopback port and immediately releases it so a control server can bind to it.
enum SimTestNet {
    static func availableLoopbackPort() throws -> Int {
        let probe = try POSIXHTTPServer.start(hostname: "127.0.0.1", port: 0) { _ in
            ServerHTTPResponse.empty()
        }
        let port = probe.address.port
        probe.stop()
        return port
    }

    static func canBindLoopbackPort(_ port: Int) -> Bool {
        guard let probe = try? POSIXHTTPServer.start(hostname: "127.0.0.1", port: port, handler: { _ in
            ServerHTTPResponse.empty()
        }) else {
            return false
        }
        probe.stop()
        return true
    }
}
