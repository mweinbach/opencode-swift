#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
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
#elseif canImport(WinSDK)
import WinSDK
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Non-Testing helper module for `CronAndConsoleWatchTests.swift` (isolates `Foundation` and POSIX sockets
/// from files that `import Testing`, per the macOS CLT cross-import rule in AGENTS.md).
enum CronAndConsoleWatchHelper {
    final class MutableClock: Sendable {
        private let current: Mutex<Int64>
        init(_ initial: Int64) { self.current = Mutex(initial) }
        func now() -> Int64 { current.withLock { $0 } }
        func set(_ value: Int64) { current.withLock { $0 = value } }
        func advance(by deltaMs: Int64) { current.withLock { $0 += deltaMs } }
    }

    static func jsonResponse(
        status: Int = 200,
        headers: [String: String] = [:],
        body: JSONValue
    ) throws -> HTTPResponse {
        var merged = headers
        if !merged.keys.contains(where: { $0.lowercased() == "content-type" }) {
            merged["Content-Type"] = "application/json"
        }
        let data = try JSONEncoder().encode(body)
        return HTTPResponse(head: HTTPResponseHead(statusCode: status, headers: merged), body: Array(data))
    }

    static func textResponse(
        status: Int = 200,
        headers: [String: String] = [:],
        text: String
    ) -> HTTPResponse {
        HTTPResponse(head: HTTPResponseHead(statusCode: status, headers: headers), body: Array(text.utf8))
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func encodeUTF8(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func decodeUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Polls `predicate` every 5ms until true or `timeoutMs` elapses.
    @discardableResult
    static func waitUntil(
        timeoutMs: Int64 = 4_000,
        _ predicate: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !predicate() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    static func makeLocationInfo(directory: String = "/tmp/opencode-test") -> LocationSchema.Info {
        let path = SchemaPrimitive.AbsolutePath(rawValue: directory)
        return LocationSchema.Info(
            directory: path,
            workspaceID: nil,
            project: LocationSchema.ProjectRef(
                id: ProjectID.global,
                directory: path,
                canonical: path
            )
        )
    }

    static func makeSessionInfo(
        id: SessionID = SessionID.create(),
        directory: String = "/tmp/opencode-test"
    ) -> SessionSchema.Info {
        return SessionSchema.Info(
            id: id,
            parentID: nil,
            fork: nil,
            projectID: ProjectID.global,
            agent: "build",
            model: nil,
            cost: 0,
            tokens: .zero,
            outcome: nil,
            time: SessionSchema.Info.Time(created: 1_700_000_000_000, updated: 1_700_000_000_000),
            title: "Watch Test Session",
            location: OpenCodeLocation(directory: directory),
            subpath: nil,
            metadata: nil,
            permissions: nil,
            revert: nil
        )
    }

    /// `CoreConfig.Interface` wrapper that simulates managed `integration.use: deny` by stripping
    /// non-policy fields from integration documents layered via `integration(_:document:)`.
    final class PolicyFilteringConfig: CoreConfig.Interface, Sendable {
        private struct State: Sendable {
            var baseEntries: [CoreConfigEntry]
            var integrations: [IntegrationID: CoreConfigIntegration.Document] = [:]
            var denyIntegrationUse: Bool
        }

        private let state: Mutex<State>

        init(initialEntries: [CoreConfigEntry] = [], denyIntegrationUse: Bool = false) {
            self.state = Mutex(State(baseEntries: initialEntries, denyIntegrationUse: denyIntegrationUse))
        }

        func setDenyIntegrationUse(_ deny: Bool) {
            state.withLock { $0.denyIntegrationUse = deny }
        }

        func entries() async -> [CoreConfigEntry] {
            state.withLock { s in
                let docs = s.integrations.values.map { CoreConfigEntry.integration($0) }
                return docs + s.baseEntries
            }
        }

        func compatibility() async -> CoreConfig.CompatibilityRoots {
            CoreConfig.CompatibilityRoots()
        }

        func changes() -> AsyncStream<CoreConfig.WatchUpdate> {
            AsyncStream { $0.finish() }
        }

        func update(_ patch: ConfigSchema.Patch) async throws {
            _ = patch
        }

        func integration(_ integrationID: IntegrationID, document: CoreConfigIntegration.Document?) async {
            state.withLock { s in
                guard let document else {
                    s.integrations.removeValue(forKey: integrationID)
                    return
                }
                if s.denyIntegrationUse {
                    // Matches upstream managed `integration.use: deny`: layers a policies-only copy.
                    let stripped = CoreConfigIntegration.Document(
                        path: document.path,
                        info: ConfigSchema.Info(policies: document.info.policies),
                        integrationID: document.integrationID,
                        connection: document.connection,
                        organization: document.organization
                    )
                    s.integrations[integrationID] = stripped
                } else {
                    s.integrations[integrationID] = document
                }
            }
        }
    }

    /// Creates a `CoreFlag.Service` with explicit `console_watches` state (independent of host env).
    static func makeFlagService(consoleWatches: Bool) -> CoreFlag.Service {
        let cfg = CoreConfig.Test(initial: [
            .document(ConfigSchema.Document(
                path: nil,
                info: ConfigSchema.Info(
                    experimental: ConfigExperimentalSchema.Info(consoleWatches: consoleWatches)
                )
            )),
        ])
        return CoreFlag.Service(
            config: cfg,
            channel: "local",
            overrides: CoreFlag.Overrides.fromEnvironment(DictionaryEnvironment())
        )
    }

    struct AutomationTestHarness: Sendable {
        let service: CoreAutomation.Service
        let owner: SessionSchema.Info
        let directory: String
        let invocation: CoreAutomation.Author.Invocation
    }

    /// Builds a `CoreAutomation.Service` wired to an in-memory SQLite DB, bus, and default allow-all agent
    /// for cron validation and tick tests.
    static func makeAutomationService(
        clock: MutableClock,
        timezone: String? = "UTC"
    ) async throws -> AutomationTestHarness {
        let harness = try await SessionDatabaseHelper.makeHarness()
        let dir = "/tmp/opencode-cron-test"
        let owner = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: dir),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))
        let agents = CoreAgent.Agent.Service()
        _ = try await agents.transform { editor in
            editor.update(CoreAgent.Agent.defaultID) { info in
                AgentSchema.Info(
                    id: info.id,
                    name: info.name,
                    model: info.model,
                    request: info.request,
                    system: info.system,
                    description: info.description,
                    mode: .primary,
                    hidden: false,
                    color: info.color,
                    steps: info.steps,
                    permissions: [PermissionSchema.Rule(action: "*", resource: "*", effect: .allow)]
                )
            }
        }
        let permission = CorePermission.Service()
        let tools = CoreTool.Service()
        let service = try CoreAutomation.Service(
            database: harness.db,
            clock: { clock.now() },
            sessions: harness.session,
            execution: harness.session.execution,
            bus: harness.bus,
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    mcpEventsEnabled: true,
                    timezone: timezone,
                    projectID: owner.projectID,
                    agents: agents,
                    permission: permission,
                    tools: tools
                )
            },
            maxSleepMs: 25
        )
        let invocation = CoreAutomation.Author.Invocation(sessionID: owner.id, agent: CoreAgent.Agent.defaultID)
        return AutomationTestHarness(service: service, owner: owner, directory: dir, invocation: invocation)
    }

    static func openInMemoryDatabase() throws -> any SQLiteDatabase {
        try SQLiteDatabaseFactory.open(path: ":memory:")
    }

    // MARK: - Minimal In-Process Loopback RFC 6455 WebSocket + HTTP Server

    /// Pure-Swift RFC 3174 SHA-1 used for RFC 6455 `Sec-WebSocket-Accept` computation.
    private static func sha1(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> shift) & 0xFF))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        @inline(__always) func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        var w = [UInt32](repeating: 0, count: 80)
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let b = offset + i * 4
                w[i] = (UInt32(bytes[b]) << 24) | (UInt32(bytes[b + 1]) << 16)
                    | (UInt32(bytes[b + 2]) << 8) | UInt32(bytes[b + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d); k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d; h4 &+= e
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(20)
        for h in [h0, h1, h2, h3, h4] {
            digest.append(UInt8((h >> 24) & 0xFF))
            digest.append(UInt8((h >> 16) & 0xFF))
            digest.append(UInt8((h >> 8) & 0xFF))
            digest.append(UInt8(h & 0xFF))
        }
        return digest
    }

    /// Real POSIX / Winsock2 TCP loopback server implementing RFC 6455 WebSocket upgrade/framing alongside HTTP responses.
    /// Allows testing `URLSessionWebSocketTransport` + `URLSessionHTTPTransport` over real loopback sockets.
    final class LoopbackConsoleServer: @unchecked Sendable {
        #if canImport(WinSDK)
        typealias NativeSocket = SOCKET
        private static let winsockReady: Bool = {
            var data = WSADATA()
            return WSAStartup(WORD(0x0202), &data) == 0
        }()
        #else
        typealias NativeSocket = Int32
        #endif

        struct HTTPRequestRecord: Sendable {
            let method: String
            let path: String
            let headers: [String: String]
            let body: String
        }

        struct WSConnectionContext: @unchecked Sendable {
            let fd: NativeSocket
            let path: String
            let headers: [String: String]

            func sendText(_ text: String) {
                sendFrame(opcode: 0x1, payload: Array(text.utf8))
            }

            func sendBinary(_ bytes: [UInt8]) {
                sendFrame(opcode: 0x2, payload: bytes)
            }

            func sendClose(code: Int, reason: String = "") {
                var payload: [UInt8] = [UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
                payload.append(contentsOf: reason.utf8)
                sendFrame(opcode: 0x8, payload: payload)
            }

            func sendFrame(opcode: UInt8, payload: [UInt8]) {
                var frame: [UInt8] = [0x80 | (opcode & 0x0F)]
                if payload.count < 126 {
                    frame.append(UInt8(payload.count))
                } else if payload.count <= 0xFFFF {
                    frame.append(126)
                    frame.append(UInt8((payload.count >> 8) & 0xFF))
                    frame.append(UInt8(payload.count & 0xFF))
                } else {
                    frame.append(127)
                    let len = UInt64(payload.count)
                    for shift in stride(from: 56, through: 0, by: -8) {
                        frame.append(UInt8((len >> shift) & 0xFF))
                    }
                }
                frame.append(contentsOf: payload)
                LoopbackConsoleServer.writeAll(fd: fd, bytes: frame)
            }

            /// Reads the next masked client text/binary frame (answers pings automatically; returns nil on close/EOF).
            func readClientText(timeoutSeconds: Int = 5) -> String? {
                #if os(macOS) || os(Linux) || os(Windows)
                #if canImport(WinSDK)
                var timeoutMs: DWORD = DWORD(timeoutSeconds * 1000)
                _ = withUnsafePointer(to: &timeoutMs) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { cPtr in
                        WinSDK.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, cPtr, Int32(MemoryLayout<DWORD>.size))
                    }
                }
                #else
                var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                #endif
                while true {
                    guard let h = LoopbackConsoleServer.readExact(fd: fd, count: 2) else { return nil }
                    let opcode = h[0] & 0x0F
                    let masked = (h[1] & 0x80) != 0
                    var len = Int(h[1] & 0x7F)
                    if len == 126 {
                        guard let ext = LoopbackConsoleServer.readExact(fd: fd, count: 2) else { return nil }
                        len = (Int(ext[0]) << 8) | Int(ext[1])
                    } else if len == 127 {
                        guard let ext = LoopbackConsoleServer.readExact(fd: fd, count: 8) else { return nil }
                        var n: UInt64 = 0
                        for b in ext { n = (n << 8) | UInt64(b) }
                        len = Int(n)
                    }
                    var maskKey: [UInt8] = []
                    if masked {
                        guard let mk = LoopbackConsoleServer.readExact(fd: fd, count: 4) else { return nil }
                        maskKey = mk
                    }
                    var payload = len > 0 ? (LoopbackConsoleServer.readExact(fd: fd, count: len) ?? []) : []
                    if payload.count != len { return nil }
                    if masked {
                        for i in 0..<payload.count { payload[i] ^= maskKey[i & 3] }
                    }
                    switch opcode {
                    case 0x1, 0x2:
                        return String(decoding: payload, as: UTF8.self)
                    case 0x8:
                        return nil
                    case 0x9:
                        sendFrame(opcode: 0xA, payload: payload)
                    default:
                        continue
                    }
                }
                #else
                return nil
                #endif
            }
        }

        enum UpgradeDecision: Sendable {
            case accept(@Sendable (WSConnectionContext) -> Void)
            case reject(status: Int, body: String)
        }

        private let listenFD: NativeSocket
        public let port: UInt16
        public var baseURL: String { "http://127.0.0.1:\(port)" }
        private let stopped = Mutex(false)
        private let onUpgrade: @Sendable (String, [String: String]) -> UpgradeDecision
        private let onHTTP: @Sendable (HTTPRequestRecord) -> (status: Int, headers: [String: String], body: String)

        init(
            onUpgrade: @escaping @Sendable (String, [String: String]) -> UpgradeDecision,
            onHTTP: @escaping @Sendable (HTTPRequestRecord) -> (status: Int, headers: [String: String], body: String)
        ) throws {
            self.onUpgrade = onUpgrade
            self.onHTTP = onHTTP
            #if os(macOS) || os(Linux) || os(Windows)
            #if canImport(WinSDK)
            _ = Self.winsockReady
            let fd = WinSDK.socket(AF_INET, SOCK_STREAM, 0)
            guard fd != INVALID_SOCKET else { throw PlatformError.ioFailure("socket() failed") }
            var one: Int32 = 1
            _ = withUnsafePointer(to: &one) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { cPtr in
                    WinSDK.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, cPtr, Int32(MemoryLayout<Int32>.size))
                }
            }
            var addr = sockaddr_in()
            addr.sin_family = ADDRESS_FAMILY(AF_INET)
            _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            addr.sin_port = 0
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    WinSDK.bind(fd, sa, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                _ = WinSDK.closesocket(fd)
                throw PlatformError.ioFailure("bind() failed")
            }
            guard WinSDK.listen(fd, 16) == 0 else {
                _ = WinSDK.closesocket(fd)
                throw PlatformError.ioFailure("listen() failed")
            }
            var bound = sockaddr_in()
            var boundLen = Int32(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    WinSDK.getsockname(fd, sa, &boundLen)
                }
            }
            #else
            #if canImport(Darwin)
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            #elseif canImport(Glibc)
            let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
            let fd = Musl.socket(AF_INET, Int32(SOCK_STREAM), 0)
            #endif
            guard fd >= 0 else { throw PlatformError.ioFailure("socket() failed") }
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            addr.sin_port = 0
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                close(fd)
                throw PlatformError.ioFailure("bind() failed")
            }
            guard listen(fd, 16) == 0 else {
                close(fd)
                throw PlatformError.ioFailure("listen() failed")
            }
            var bound = sockaddr_in()
            var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &boundLen)
                }
            }
            #endif
            self.listenFD = fd
            self.port = UInt16(bigEndian: bound.sin_port)
            Thread.detachNewThread { [self] in
                self.acceptLoop()
            }
            #else
            throw PlatformError.ioFailure("LoopbackConsoleServer unsupported on this platform")
            #endif
        }

        func stop() {
            let already = stopped.withLock { s -> Bool in
                if s { return true }
                s = true
                return false
            }
            if !already {
                #if canImport(WinSDK)
                _ = WinSDK.shutdown(listenFD, SD_BOTH)
                _ = WinSDK.closesocket(listenFD)
                #elseif os(macOS) || os(Linux)
                _ = shutdown(listenFD, Int32(SHUT_RDWR))
                _ = close(listenFD)
                #endif
            }
        }

        private func acceptLoop() {
            #if os(macOS) || os(Linux) || os(Windows)
            while !stopped.withLock({ $0 }) {
                var clientAddr = sockaddr_storage()
                #if canImport(WinSDK)
                var clientLen = Int32(MemoryLayout<sockaddr_storage>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        WinSDK.accept(listenFD, sa, &clientLen)
                    }
                }
                if clientFD == INVALID_SOCKET { break }
                #else
                var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(listenFD, sa, &clientLen)
                    }
                }
                if clientFD < 0 { break }
                #if canImport(Darwin)
                var noSigPipe: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                #endif
                #endif
                Thread.detachNewThread { [self] in
                    self.handleClient(fd: clientFD)
                }
            }
            #endif
        }

        private func handleClient(fd: NativeSocket) {
            #if os(macOS) || os(Linux) || os(Windows)
            #if canImport(WinSDK)
            defer { _ = WinSDK.closesocket(fd) }
            #else
            defer { _ = close(fd) }
            #endif
            var headerBytes: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 1)
            let crlfcrlf: [UInt8] = [13, 10, 13, 10]
            while headerBytes.count < 32_768 {
                let n: Int = buf.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return -1 }
                    #if canImport(WinSDK)
                    return Int(WinSDK.recv(fd, base.assumingMemoryBound(to: CChar.self), 1, 0))
                    #else
                    return recv(fd, base, 1, 0)
                    #endif
                }
                if n <= 0 { return }
                headerBytes.append(buf[0])
                if headerBytes.count >= 4 && Array(headerBytes.suffix(4)) == crlfcrlf {
                    break
                }
            }
            let headerText = String(decoding: headerBytes, as: UTF8.self)
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return }
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { return }
            let method = String(parts[0])
            let path = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                if let colon = line.firstIndex(of: ":") {
                    let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[k] = v
                }
            }

            if headers["upgrade"]?.lowercased() == "websocket",
               let wsKey = headers["sec-websocket-key"]
            {
                let decision = onUpgrade(path, headers)
                switch decision {
                case .reject(let status, let body):
                    let bodyBytes = Array(body.utf8)
                    let resp = "HTTP/1.1 \(status) Upgrade Required\r\nContent-Type: text/plain\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n\(body)"
                    Self.writeAll(fd: fd, bytes: Array(resp.utf8))
                    return
                case .accept(let handler):
                    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                    let acceptVal = Data(CronAndConsoleWatchHelper.sha1(Array((wsKey + magic).utf8))).base64EncodedString()
                    let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptVal)\r\n\r\n"
                    Self.writeAll(fd: fd, bytes: Array(resp.utf8))
                    handler(WSConnectionContext(fd: fd, path: path, headers: headers))
                    return
                }
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodyBytes = contentLength > 0 ? (Self.readExact(fd: fd, count: contentLength) ?? []) : []
            let bodyText = String(decoding: bodyBytes, as: UTF8.self)
            let result = onHTTP(HTTPRequestRecord(method: method, path: path, headers: headers, body: bodyText))
            let respBodyBytes = Array(result.body.utf8)
            var resp = "HTTP/1.1 \(result.status) OK\r\nContent-Length: \(respBodyBytes.count)\r\nConnection: close\r\n"
            for (k, v) in result.headers {
                resp += "\(k): \(v)\r\n"
            }
            resp += "\r\n"
            Self.writeAll(fd: fd, bytes: Array(resp.utf8) + respBodyBytes)
            #endif
        }

        private static func readExact(fd: NativeSocket, count: Int) -> [UInt8]? {
            #if os(macOS) || os(Linux) || os(Windows)
            var out = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let n = out.withUnsafeMutableBytes { raw -> Int in
                    let base = raw.baseAddress!.advanced(by: offset)
                    #if canImport(WinSDK)
                    let remaining = Int32(min(count - offset, Int(Int32.max)))
                    return Int(WinSDK.recv(fd, base.assumingMemoryBound(to: CChar.self), remaining, 0))
                    #else
                    return recv(fd, base, count - offset, 0)
                    #endif
                }
                if n <= 0 { return nil }
                offset += n
            }
            return out
            #else
            return nil
            #endif
        }

        private static func writeAll(fd: NativeSocket, bytes: [UInt8]) {
            #if os(macOS) || os(Linux) || os(Windows)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { raw -> Int in
                    let base = raw.baseAddress!.advanced(by: offset)
                    #if canImport(WinSDK)
                    let remaining = Int32(min(bytes.count - offset, Int(Int32.max)))
                    return Int(WinSDK.send(fd, base.assumingMemoryBound(to: CChar.self), remaining, 0))
                    #elseif canImport(Darwin)
                    return send(fd, base, bytes.count - offset, 0)
                    #else
                    return send(fd, base, bytes.count - offset, Int32(MSG_NOSIGNAL))
                    #endif
                }
                if n <= 0 { break }
                offset += n
            }
            #endif
        }
    }
}
