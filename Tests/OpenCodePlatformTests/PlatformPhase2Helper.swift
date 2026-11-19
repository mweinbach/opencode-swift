#if !os(WASI)
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

/// Foundation / OS test helpers kept out of `PlatformPhase2Tests.swift` to obey
/// the macOS Command Line Tools rule (never import `Foundation` and `Testing` in the same file).
enum PlatformPhase2Helper {
    static func makeTempDirectory(prefix: String = "opencode-phase2") throws -> String {
        #if os(WASI)
        return "/tmp/\(prefix)-\(UInt64.random(in: 1...UInt64.max))"
        #else
        let base = NSTemporaryDirectory()
        let name = "\(prefix)-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
        #endif
    }

    static func removeItemIfExists(at path: String) {
        #if !os(WASI)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    static func fileExists(at path: String) -> Bool {
        #if os(WASI)
        return false
        #else
        return FileManager.default.fileExists(atPath: path)
        #endif
    }

    static func readTextFile(at path: String) throws -> String {
        #if os(WASI)
        return ""
        #else
        return try String(contentsOfFile: path, encoding: .utf8)
        #endif
    }

    static func writeTextFile(_ text: String, to path: String) throws {
        #if !os(WASI)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        #endif
    }

    static func createDirectory(at path: String) throws {
        #if !os(WASI)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #endif
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        #if os(WASI)
        return ""
        #else
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
        #endif
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        #if os(WASI)
        throw ProcessDaemon.DaemonError("JSON decoding helper unavailable on WASI")
        #else
        return try JSONDecoder().decode(type, from: Data(text.utf8))
        #endif
    }

    static func sleepMs(_ ms: UInt64) {
        #if !os(WASI)
        Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
        #endif
    }

    static func runInBackground(_ body: @escaping @Sendable () -> Void) {
        #if !os(WASI)
        Thread.detachNewThread {
            body()
        }
        #else
        body()
        #endif
    }

    /// Minimal ephemeral localhost HTTP/1.1 test server supporting both unary and chunked streaming
    /// responses so `URLSessionHTTPTransport` can be verified over a real loopback socket offline.
    final class LoopbackHTTPServer: @unchecked Sendable {
        let port: UInt16
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        private let listenFD: Int32
        #endif
        private let stopped = Mutex<Bool>(false)
        private let receivedRaw = Mutex<[String]>([])

        var capturedRequests: [String] {
            receivedRaw.withLock { $0 }
        }

        private init(port: UInt16, listenFD: Int32) {
            self.port = port
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            self.listenFD = listenFD
            #endif
        }

        deinit {
            stop()
        }

        func stop() {
            let wasStopped = stopped.withLock { s -> Bool in
                if s { return true }
                s = true
                return false
            }
            if wasStopped { return }
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            _ = shutdown(listenFD, Int32(SHUT_RDWR))
            _ = close(listenFD)
            #endif
        }

        static func start(
            handler: @escaping @Sendable (_ requestText: String, _ writeChunk: @Sendable ([UInt8]) -> Void) -> Void
        ) throws -> LoopbackHTTPServer? {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            #if canImport(Glibc)
            let streamType = Int32(SOCK_STREAM.rawValue)
            #else
            let streamType = SOCK_STREAM
            #endif
            let fd = socket(AF_INET, streamType, 0)
            guard fd >= 0 else { return nil }
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // ephemeral port
            addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif

            let bindRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    #if canImport(Darwin)
                    Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #elseif canImport(Glibc)
                    Glibc.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #else
                    Musl.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #endif
                }
            }
            guard bindRC == 0, listen(fd, 16) == 0 else {
                _ = close(fd)
                return nil
            }

            var boundAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameRC = withUnsafeMutablePointer(to: &boundAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getsockname(fd, sockPtr, &addrLen)
                }
            }
            guard nameRC == 0 else {
                _ = close(fd)
                return nil
            }
            let assignedPort = UInt16(bigEndian: boundAddr.sin_port)
            let server = LoopbackHTTPServer(port: assignedPort, listenFD: fd)

            Thread.detachNewThread {
                while !server.stopped.withLock({ $0 }) {
                    #if canImport(Darwin)
                    let clientFD = Darwin.accept(fd, nil, nil)
                    #elseif canImport(Glibc)
                    let clientFD = Glibc.accept(fd, nil, nil)
                    #else
                    let clientFD = Musl.accept(fd, nil, nil)
                    #endif
                    if clientFD < 0 { break }
                    Thread.detachNewThread {
                        defer { _ = close(clientFD) }
                        var buf = [UInt8](repeating: 0, count: 16_384)
                        let n = buf.withUnsafeMutableBytes { ptr in
                            #if canImport(Darwin)
                            Darwin.read(clientFD, ptr.baseAddress!, ptr.count)
                            #elseif canImport(Glibc)
                            Glibc.read(clientFD, ptr.baseAddress!, ptr.count)
                            #else
                            Musl.read(clientFD, ptr.baseAddress!, ptr.count)
                            #endif
                        }
                        guard n > 0 else { return }
                        let reqText = String(decoding: buf[0..<n], as: UTF8.self)
                        server.receivedRaw.withLock { $0.append(reqText) }
                        handler(reqText) { bytes in
                            var off = 0
                            while off < bytes.count {
                                let w = bytes.withUnsafeBytes { ptr in
                                    #if canImport(Darwin)
                                    Darwin.write(clientFD, ptr.baseAddress!.advanced(by: off), bytes.count - off)
                                    #elseif canImport(Glibc)
                                    Glibc.write(clientFD, ptr.baseAddress!.advanced(by: off), bytes.count - off)
                                    #else
                                    Musl.write(clientFD, ptr.baseAddress!.advanced(by: off), bytes.count - off)
                                    #endif
                                }
                                if w <= 0 { break }
                                off += w
                            }
                        }
                    }
                }
            }
            return server
            #else
            return nil
            #endif
        }
    }
}
