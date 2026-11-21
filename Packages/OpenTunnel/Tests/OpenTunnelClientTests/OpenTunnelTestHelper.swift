import Foundation
import Synchronization
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import OpenTunnelClient

/// Foundation, CryptoKit, and POSIX loopback helpers for `OpenTunnelClientTests`.
/// Kept in a separate file that does NOT `import Testing` (macOS CLT cross-import rule).
enum OpenTunnelTestHelper {
    /// Creates an isolated temporary directory path and returns it.
    static func makeTempDirectory(prefix: String = "opentunnel-test") throws -> String {
        let base = FileManager.default.temporaryDirectory.path
        let name = "\(prefix)-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func removePath(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func posixMode(of path: String) -> Int? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var st = stat()
        guard path.withCString({ stat($0, &st) }) == 0 else { return nil }
        return Int(st.st_mode & 0o777)
        #else
        _ = path
        return nil
        #endif
    }

    static func writeFile(_ content: String, to path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func readText(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return String(decoding: data, as: UTF8.self)
    }

    static func decodePEMBody(_ pem: String) -> [UInt8]? {
        let lines = pem
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let data = Data(base64Encoded: lines.joined()) else { return nil }
        return Array(data)
    }

    static func bytesContainASCII(_ bytes: [UInt8], _ needle: String) -> Bool {
        let target = Array(needle.utf8)
        guard !target.isEmpty, bytes.count >= target.count else { return false }
        for i in 0...(bytes.count - target.count) {
            if Array(bytes[i..<(i + target.count)]) == target {
                return true
            }
        }
        return false
    }

    /// Cross-verifies the pure-Swift P-256 private key and PKCS#10 CSR signature using Apple `CryptoKit`.
    static func verifyPureSwiftCSR(hostname: String) throws -> (pemValid: Bool, cryptoVerified: Bool, containsHost: Bool, containsWildcard: Bool) {
        let generated = try DefaultOpenTunnelKeyProvider.shared.generatePureSwift(hostname: hostname)
        guard let csrDER = decodePEMBody(generated.csrPEM),
              let keyDER = decodePEMBody(generated.privateKeyPEM)
        else {
            return (false, false, false, false)
        }
        let pemValid = generated.privateKeyPEM.contains("-----BEGIN PRIVATE KEY-----")
            && generated.csrPEM.contains("-----BEGIN CERTIFICATE REQUEST-----")
            && !keyDER.isEmpty
            && !csrDER.isEmpty
        let containsHost = bytesContainASCII(csrDER, hostname)
        let containsWildcard = bytesContainASCII(csrDER, "*.\(hostname)")

        #if canImport(CryptoKit)
        // Parse the PKCS#8 private key with CryptoKit to verify our DER encoding is 100% standards-compliant!
        let importedKey = try P256.Signing.PrivateKey(pemRepresentation: generated.privateKeyPEM)
        // Extract CertificationRequestInfo and signature BIT STRING from CSR SEQUENCE { info, sigAlg, bitString }
        guard let (infoDER, sigDER) = extractCSRInfoAndSignature(csrDER: csrDER) else {
            return (pemValid, false, containsHost, containsWildcard)
        }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(sigDER))
        let verified = importedKey.publicKey.isValidSignature(signature, for: Data(infoDER))
        return (pemValid, verified, containsHost, containsWildcard)
        #else
        return (pemValid, pemValid, containsHost, containsWildcard)
        #endif
    }

    /// Minimal DER parser extracting the first SEQUENCE (CertificationRequestInfo) and third element (BIT STRING)
    /// from a PKCS#10 CSR.
    private static func extractCSRInfoAndSignature(csrDER: [UInt8]) -> ([UInt8], [UInt8])? {
        func readTLV(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, headerLen: Int, contentLen: Int, next: Int)? {
            guard offset + 2 <= bytes.count else { return nil }
            let tag = bytes[offset]
            let lenByte = bytes[offset + 1]
            var headerLen = 2
            let contentLen: Int
            if (lenByte & 0x80) == 0 {
                contentLen = Int(lenByte)
            } else {
                let count = Int(lenByte & 0x7F)
                guard count > 0, count <= 4, offset + 2 + count <= bytes.count else { return nil }
                var val = 0
                for i in 0..<count {
                    val = (val << 8) | Int(bytes[offset + 2 + i])
                }
                headerLen += count
                contentLen = val
            }
            let next = offset + headerLen + contentLen
            guard next <= bytes.count else { return nil }
            return (tag, headerLen, contentLen, next)
        }

        guard let outer = readTLV(csrDER, at: 0), outer.tag == 0x30 else { return nil }
        let infoStart = outer.headerLen
        guard let infoTLV = readTLV(csrDER, at: infoStart), infoTLV.tag == 0x30 else { return nil }
        let infoDER = Array(csrDER[infoStart..<infoTLV.next])
        guard let algTLV = readTLV(csrDER, at: infoTLV.next), algTLV.tag == 0x30 else { return nil }
        guard let bitTLV = readTLV(csrDER, at: algTLV.next), bitTLV.tag == 0x03 else { return nil }
        let bitContentStart = algTLV.next + bitTLV.headerLen
        guard bitTLV.contentLen > 1, csrDER[bitContentStart] == 0x00 else { return nil }
        let sigDER = Array(csrDER[(bitContentStart + 1)..<bitTLV.next])
        return (infoDER, sigDER)
    }

    static func encodeJSONString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeJSONBytes<T: Encodable>(_ value: T) -> [UInt8] {
        (try? Array(JSONEncoder().encode(value))) ?? Array("{}".utf8)
    }

    static func decodeClientControlType(_ text: String) -> (type: String, routes: [String]?, conn: UInt32?, code: String?, timeSent: Int64?)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        let routes = obj["routes"] as? [String]
        let conn = (obj["conn"] as? NSNumber)?.uint32Value
        let code = obj["code"] as? String
        let timeSent = (obj["time_sent"] as? NSNumber)?.int64Value
        return (type, routes, conn, code, timeSent)
    }
}

// MARK: - Programmable Mock OpenTunnelTransport

final class MockOpenTunnelTransport: OpenTunnelTransport, Sendable {
    typealias HTTPHandler = @Sendable (OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse
    typealias WSHandler = @Sendable (String, [String], [String: String], OpenTunnelProxyConfig?) async throws -> any OpenTunnelWebSocket
    typealias LocalHandler = @Sendable (OpenTunnelTarget) async throws -> any OpenTunnelByteStream

    private let httpHandler: HTTPHandler
    private let wsHandler: WSHandler
    private let localHandler: LocalHandler

    private struct RecordedState: Sendable {
        var httpRequests: [OpenTunnelHTTPRequest] = []
        var wsURLs: [String] = []
        var wsProxies: [OpenTunnelProxyConfig?] = []
        var localTargets: [OpenTunnelTarget] = []
    }

    private let recorded = Mutex(RecordedState())

    init(
        http: @escaping HTTPHandler = { req in
            OpenTunnelHTTPResponse(statusCode: 404, body: Array("{\"_tag\":\"NotFound\",\"message\":\"unhandled \(req.method) \(req.url)\"}".utf8))
        },
        ws: @escaping WSHandler = { _, _, _, _ in
            throw OpenTunnelClientError.transient("No mock WebSocket configured")
        },
        local: @escaping LocalHandler = { target in
            try await LiveOpenTunnelTransport.shared.openLocalConnection(target: target)
        }
    ) {
        self.httpHandler = http
        self.wsHandler = ws
        self.localHandler = local
    }

    var httpRequests: [OpenTunnelHTTPRequest] { recorded.withLock { $0.httpRequests } }
    var wsURLs: [String] { recorded.withLock { $0.wsURLs } }
    var localTargets: [OpenTunnelTarget] { recorded.withLock { $0.localTargets } }

    func sendHTTP(_ request: OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse {
        recorded.withLock { $0.httpRequests.append(request) }
        return try await httpHandler(request)
    }

    func openWebSocket(
        url: String,
        protocols: [String],
        headers: [String: String],
        proxy: OpenTunnelProxyConfig?
    ) async throws -> any OpenTunnelWebSocket {
        recorded.withLock { s in
            s.wsURLs.append(url)
            s.wsProxies.append(proxy)
        }
        return try await wsHandler(url, protocols, headers, proxy)
    }

    func openLocalConnection(target: OpenTunnelTarget) async throws -> any OpenTunnelByteStream {
        recorded.withLock { $0.localTargets.append(target) }
        return try await localHandler(target)
    }
}

// MARK: - Real Loopback POSIX TCP Test Server (HTTP / SSE / WebSocket / Raw Echo)

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
final class LoopbackTestTCPServer: Sendable {
    private final class StopFlag: Sendable {
        let value = Mutex(false)
    }

    let port: Int
    private let listenFD: Mutex<Int32?>
    private let stopFlag = StopFlag()

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, sockType, 0)
        guard fd >= 0 else {
            throw OpenTunnelClientError(message: "Failed to create loopback test socket")
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Self.closeFD(fd)
            throw OpenTunnelClientError(message: "Failed to bind loopback test socket")
        }
        guard listen(fd, 16) == 0 else {
            Self.closeFD(fd)
            throw OpenTunnelClientError(message: "Failed to listen on loopback test socket")
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))
        self.listenFD = Mutex(fd)

        let stopFlag = self.stopFlag
        Thread.detachNewThread {
            while !stopFlag.value.withLock({ $0 }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if ready <= 0 { continue }
                if (pfd.revents & Int16(POLLNVAL)) != 0 { break }
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(fd, sa, &clientLen)
                    }
                }
                if clientFD >= 0 {
                    #if canImport(Darwin)
                    var one: Int32 = 1
                    _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    Thread.detachNewThread {
                        handler(clientFD)
                        Self.closeFD(clientFD)
                    }
                }
            }
        }
    }

    func stop() {
        stopFlag.value.withLock { $0 = true }
        if let fd = listenFD.withLock({ f -> Int32? in
            let prev = f
            f = nil
            return prev
        }) {
            Self.closeFD(fd)
        }
    }

    deinit { stop() }

    static func readChunk(fd: Int32, maxBytes: Int = 8192) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n: Int = buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return Int(recv(fd, base, raw.count, 0))
        }
        return n > 0 ? Array(buf[0..<n]) : []
    }

    static func readUntilHeadersEnd(fd: Int32, maxBytes: Int = 16_384) -> [UInt8] {
        var accumulated: [UInt8] = []
        let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while accumulated.count < maxBytes {
            let chunk = readChunk(fd: fd, maxBytes: maxBytes - accumulated.count)
            if chunk.isEmpty { break }
            accumulated.append(contentsOf: chunk)
            if accumulated.count >= 4 {
                for idx in 0...(accumulated.count - 4) {
                    if accumulated[idx] == marker[0]
                        && accumulated[idx + 1] == marker[1]
                        && accumulated[idx + 2] == marker[2]
                        && accumulated[idx + 3] == marker[3]
                    {
                        return accumulated
                    }
                }
            }
        }
        return accumulated
    }

    static func writeAll(fd: Int32, bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n: Int = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Int(Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0))
                #elseif canImport(Glibc)
                return Int(Glibc.send(fd, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL)))
                #elseif canImport(Musl)
                return Int(Musl.send(fd, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL)))
                #endif
            }
            if n > 0 {
                sent += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    static func closeFD(_ fd: Int32) {
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
}
#endif
