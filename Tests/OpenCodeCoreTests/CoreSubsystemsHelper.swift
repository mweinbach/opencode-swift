#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Mock HTTP transport for testing MCP Streamable HTTP, ModelsDev, CopilotModels, ModalModels, WellKnown, and SkillDiscovery.
final class MockSubsystemsHTTPTransport: HTTPTransport, Sendable {
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let recorded = Mutex<[HTTPRequest]>([])

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        recorded.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try await handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let resp = try await send(request)
        let bytes = resp.body
        let stream = AsyncThrowingStream<[UInt8], Error> { cont in
            if !bytes.isEmpty { cont.yield(bytes) }
            cont.finish()
        }
        return HTTPStreamingResponse(head: resp.head, chunks: stream)
    }
}

/// In-memory mock socket for testing `CoreMCP.SocketClient`.
final class MockSubsystemsSocket: CoreMCP.SocketClient.Socket, Sendable {
    private struct State: Sendable {
        var sent: [String] = []
        var closeCodes: [Int?] = []
    }

    private let state = Mutex(State())

    var sentFrames: [String] { state.withLock { $0.sent } }
    var closeCodes: [Int?] { state.withLock { $0.closeCodes } }

    func send(_ text: String) throws {
        state.withLock { $0.sent.append(text) }
    }

    func close(code: Int?, reason: String?) throws {
        _ = reason
        state.withLock { $0.closeCodes.append(code) }
    }
}

/// Deterministic mock environment provider for tests.
struct MockSubsystemsEnv: EnvironmentProviding, Sendable {
    let vars: [String: String]
    let homeDirectory: String?
    let temporaryDirectory: String

    init(
        vars: [String: String] = [:],
        homeDirectory: String? = "/home/tester",
        temporaryDirectory: String = "/tmp/opencode-test"
    ) {
        self.vars = vars
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    func variable(_ name: String) -> String? {
        vars[name]
    }
}

/// Mock process spawner for deterministic Git/Stdio tests.
final class MockSubsystemsSpawner: ProcessSpawner, Sendable {
    private let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput

    init(handler: @escaping @Sendable (ProcessSpec) async throws -> ProcessOutput) {
        self.handler = handler
    }

    func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        try await handler(spec)
    }
}

/// Thread-safe counter & collector helpers (isolated from Testing files).
final class AtomicCounter: Sendable {
    private let box = Mutex(0)
    init(_ initial: Int = 0) { box.withLock { $0 = initial } }
    @discardableResult
    func increment() -> Int {
        box.withLock { v in
            v += 1
            return v
        }
    }
    var value: Int { box.withLock { $0 } }
}

final class AtomicBox<T: Sendable>: Sendable {
    private let box: Mutex<T>
    init(_ initial: T) { self.box = Mutex(initial) }
    func get() -> T { box.withLock { $0 } }
    func set(_ next: T) { box.withLock { $0 = next } }
    func modify(_ fn: (inout T) -> Void) { box.withLock { value in fn(&value) } }
}

/// JSON helper for tests (keeps Foundation out of `CoreSubsystemsTests.swift`).
enum CoreSubsystemsTestJSON {
    static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        Array(try JSONEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes))
    }

    static func jsonResponse(_ status: Int = 200, headers: [String: String] = [:], body: JSONValue) throws -> HTTPResponse {
        var hdrs = headers
        if hdrs["content-type"] == nil {
            hdrs["content-type"] = "application/json"
        }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: hdrs),
            body: try encode(body)
        )
    }

    static func textResponse(_ status: Int = 200, headers: [String: String] = [:], body: String) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: headers),
            body: Array(body.utf8)
        )
    }
}
