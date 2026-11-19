#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Foundation-backed JSON & in-memory mock transport/WS/process helpers for `OpenCodeClientTests`.
/// Kept separate from `OpenCodeClientTests.swift` so test files importing `Testing` never import `Foundation`
/// (macOS CLT cross-import overlay rule).
enum ClientTestHelper {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    static func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encodeJSON(value), as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static func jsonResponse<T: Encodable>(
        status: Int = 200,
        headers: [String: String] = [:],
        body: T
    ) throws -> HTTPResponse {
        var merged = headers
        if merged["content-type"] == nil && merged["Content-Type"] == nil {
            merged["content-type"] = "application/json"
        }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: merged),
            body: try encodeJSON(body)
        )
    }

    static func emptyResponse(status: Int = 204, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(head: HTTPResponseHead(statusCode: status, headers: headers), body: [])
    }

    static func binaryResponse(
        status: Int = 200,
        bytes: [UInt8],
        contentType: String = "application/octet-stream"
    ) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: ["content-type": contentType]),
            body: bytes
        )
    }

    static func sseResponse(
        status: Int = 200,
        contentType: String = "text/event-stream",
        chunks: [[UInt8]],
        chunkDelayMs: Int64 = 0,
        keepOpen: Bool = false
    ) -> HTTPStreamingResponse {
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            let task = Task {
                for chunk in chunks {
                    if Task.isCancelled { break }
                    if chunkDelayMs > 0 {
                        try? await Task.sleep(for: .milliseconds(chunkDelayMs))
                    }
                    continuation.yield(chunk)
                }
                if keepOpen {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: status, headers: ["content-type": contentType]),
            chunks: stream
        )
    }
}

/// Thread-safe, programmable in-memory `HTTPTransport` recording every request sent by `OpenCodeClient`.
final class MockHTTPTransport: HTTPTransport, Sendable {
    private struct State: Sendable {
        var recordedRequests: [HTTPRequest] = []
        var recordedStreamRequests: [HTTPRequest] = []
        var sendHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?
        var streamHandler: (@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)?
    }

    private let state = Mutex(State())

    init(
        sendHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)? = nil,
        streamHandler: (@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)? = nil
    ) {
        state.withLock { s in
            s.sendHandler = sendHandler
            s.streamHandler = streamHandler
        }
    }

    func setSendHandler(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        state.withLock { $0.sendHandler = handler }
    }

    func setStreamHandler(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPStreamingResponse) {
        state.withLock { $0.streamHandler = handler }
    }

    var requests: [HTTPRequest] {
        state.withLock { $0.recordedRequests }
    }

    var streamRequests: [HTTPRequest] {
        state.withLock { $0.recordedStreamRequests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler = state.withLock { s -> (@Sendable (HTTPRequest) async throws -> HTTPResponse)? in
            s.recordedRequests.append(request)
            return s.sendHandler
        }
        guard let handler else {
            return HTTPResponse(head: HTTPResponseHead(statusCode: 500), body: [])
        }
        return try await handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let handler = state.withLock { s -> (@Sendable (HTTPRequest) async throws -> HTTPStreamingResponse)? in
            s.recordedStreamRequests.append(request)
            return s.streamHandler
        }
        guard let handler else {
            return ClientTestHelper.sseResponse(chunks: [])
        }
        return try await handler(request)
    }
}

/// Controllable in-memory `ClientWebSocket` for testing `connectClientMcp` and `createPersistentPtyClient`.
final class MockClientWebSocket: ClientWebSocket, Sendable {
    private struct State: Sendable {
        var open: Bool = true
        var sentTexts: [String] = []
        var sentBinaries: [[UInt8]] = []
        var closedCode: Int? = nil
        var continuation: AsyncStream<ClientWebSocketMessage>.Continuation?
    }

    private let state = Mutex(State())
    let messages: AsyncStream<ClientWebSocketMessage>

    init() {
        var captured: AsyncStream<ClientWebSocketMessage>.Continuation?
        self.messages = AsyncStream { continuation in
            captured = continuation
        }
        state.withLock { $0.continuation = captured }
    }

    var isOpen: Bool { state.withLock { $0.open } }
    var sentTexts: [String] { state.withLock { $0.sentTexts } }
    var sentBinaries: [[UInt8]] { state.withLock { $0.sentBinaries } }
    var closedCode: Int? { state.withLock { $0.closedCode } }

    func send(text: String) async throws {
        state.withLock { $0.sentTexts.append(text) }
    }

    func send(binary: [UInt8]) async throws {
        state.withLock { $0.sentBinaries.append(binary) }
    }

    func close(code: Int) async {
        let cont = state.withLock { s -> AsyncStream<ClientWebSocketMessage>.Continuation? in
            s.open = false
            s.closedCode = code
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.yield(.closed(code: code))
        cont?.finish()
    }

    func pushServerText(_ text: String) {
        let cont = state.withLock { $0.continuation }
        cont?.yield(.text(text))
    }

    func pushServerClose(code: Int = 1006) {
        let cont = state.withLock { s -> AsyncStream<ClientWebSocketMessage>.Continuation? in
            s.open = false
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.yield(.closed(code: code))
        cont?.finish()
    }
}

final class MockWebSocketFactory: ClientWebSocketFactory, Sendable {
    private struct State: Sendable {
        var connectedURLs: [String] = []
        var connectedHeaders: [[String: String]] = []
        var sockets: [MockClientWebSocket] = []
        var onConnect: (@Sendable (String, [String: String], MockClientWebSocket) -> Void)?
    }

    private let state = Mutex(State())

    init(onConnect: (@Sendable (String, [String: String], MockClientWebSocket) -> Void)? = nil) {
        state.withLock { $0.onConnect = onConnect }
    }

    var connectedURLs: [String] { state.withLock { $0.connectedURLs } }
    var connectedHeaders: [[String: String]] { state.withLock { $0.connectedHeaders } }
    var sockets: [MockClientWebSocket] { state.withLock { $0.sockets } }

    func connect(url: String, headers: [String: String]) async throws -> any ClientWebSocket {
        let socket = MockClientWebSocket()
        let cb = state.withLock { s -> (@Sendable (String, [String: String], MockClientWebSocket) -> Void)? in
            s.connectedURLs.append(url)
            s.connectedHeaders.append(headers)
            s.sockets.append(socket)
            return s.onConnect
        }
        cb?(url, headers, socket)
        return socket
    }
}

/// Mock background child process handle for testing `ContenderPool` and `PromiseService.ensure`.
final class MockChildProcess: ServiceChildProcessHandle, Sendable {
    private struct State: Sendable {
        var pid: Int?
        var exitCode: Int32?
        var signalCode: String?
        var released: Bool = false
        var onStderr: (@Sendable ([UInt8]) -> Void)?
        var onError: (@Sendable (any Error & Sendable) -> Void)?
        var onClose: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>

    init(pid: Int? = 1234) {
        self.state = Mutex(State(pid: pid))
    }

    var pid: Int? { state.withLock { $0.pid } }
    var exitCode: Int32? { state.withLock { $0.exitCode } }
    var signalCode: String? { state.withLock { $0.signalCode } }
    var isReleased: Bool { state.withLock { $0.released } }

    func setHandlers(
        onStderr: @escaping @Sendable ([UInt8]) -> Void,
        onError: @escaping @Sendable (any Error & Sendable) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        state.withLock { s in
            s.onStderr = onStderr
            s.onError = onError
            s.onClose = onClose
        }
    }

    func releaseStderr() {
        state.withLock { s in
            s.released = true
            s.onStderr = nil
        }
    }

    func emitStderr(_ text: String) {
        let cb = state.withLock { $0.onStderr }
        cb?(Array(text.utf8))
    }

    func emitExit(code: Int32? = 0, signal: String? = nil) {
        let cb = state.withLock { s -> (@Sendable () -> Void)? in
            s.exitCode = code
            s.signalCode = signal
            return s.onClose
        }
        cb?()
    }

    func emitError(_ error: any Error & Sendable) {
        let cb = state.withLock { $0.onError }
        cb?(error)
    }
}

final class MockServiceLauncher: ServiceProcessLauncher, Sendable {
    struct SpawnRecord: Equatable, Sendable {
        let command: String
        let args: [String]
        let env: [String: String]
    }

    private struct State: Sendable {
        var records: [SpawnRecord] = []
        var factory: @Sendable (String, [String], [String: String]) throws -> any ServiceChildProcessHandle
    }

    private let state: Mutex<State>

    init(factory: @escaping @Sendable (String, [String], [String: String]) throws -> any ServiceChildProcessHandle) {
        self.state = Mutex(State(factory: factory))
    }

    var records: [SpawnRecord] { state.withLock { $0.records } }

    func spawn(command: String, args: [String], env: [String: String]) throws -> any ServiceChildProcessHandle {
        let fn = state.withLock { s -> (@Sendable (String, [String], [String: String]) throws -> any ServiceChildProcessHandle) in
            s.records.append(SpawnRecord(command: command, args: args, env: env))
            return s.factory
        }
        return try fn(command, args, env)
    }
}

final class MockServiceSignaler: ServiceProcessSignaler, Sendable {
    private struct State: Sendable {
        var runningPids: Set<Int>
        var signalsSent: [(pid: Int, signal: String)] = []
        var ignoreSigTermPids: Set<Int>
    }

    private let state: Mutex<State>

    init(runningPids: Set<Int> = [], ignoreSigTermPids: Set<Int> = []) {
        self.state = Mutex(State(runningPids: runningPids, ignoreSigTermPids: ignoreSigTermPids))
    }

    var signalsSent: [(pid: Int, signal: String)] {
        state.withLock { $0.signalsSent }
    }

    func markRunning(_ pid: Int) {
        state.withLock { _ = $0.runningPids.insert(pid) }
    }

    func sendSignal(pid: Int, signal: String) {
        state.withLock { s in
            s.signalsSent.append((pid: pid, signal: signal))
            if signal == "SIGTERM" && s.ignoreSigTermPids.contains(pid) {
                return
            }
            s.runningPids.remove(pid)
        }
    }

    func isRunning(pid: Int) -> Bool {
        state.withLock { $0.runningPids.contains(pid) }
    }
}

/// Deterministic virtual clock for contender pool and lifecycle tests.
final class MockClock: Sendable {
    private let currentMs: Mutex<Int64>

    init(_ startMs: Int64 = 1_700_000_000_000) {
        self.currentMs = Mutex(startMs)
    }

    func now() -> Int64 {
        currentMs.withLock { $0 }
    }

    func advance(by deltaMs: Int64) {
        currentMs.withLock { $0 += deltaMs }
    }
}
