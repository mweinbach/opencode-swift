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

/// Foundation-backed helpers for `ToolsConfigRuntimeTests.swift` (kept separate from `import Testing`
/// per the macOS Command Line Tools cross-import overlay rule).
enum ToolsConfigRuntimeHelper {
    static func makeTempDirectory(prefix: String = "opencode-core-test") throws -> String {
        #if os(WASI)
        return "/tmp/\(prefix)-\(uuid())"
        #else
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(uuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
        #endif
    }

    static func removeTempDirectory(_ path: String) {
        #if !os(WASI)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    static func utf8Bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func utf8String(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func samplePNGBytes() -> [UInt8] {
        // Minimal valid PNG magic signature + IHDR stub
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
    }

    static func sampleJPEGBytes() -> [UInt8] {
        [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
    }

    static func samplePDFBytes() -> [UInt8] {
        Array("%PDF-1.7\n".utf8)
    }

    static func sampleWebPBytes() -> [UInt8] {
        Array("RIFF".utf8) + [0x24, 0x00, 0x00, 0x00] + Array("WEBP".utf8)
    }

    static func sampleAVIFBytes() -> [UInt8] {
        [0x00, 0x00, 0x00, 0x18] + Array("ftypavif".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("mif1avif".utf8)
    }

    static func makeToolContext(
        sessionID: SessionID = SessionID(rawValue: "ses_test_001")!,
        agent: AgentSchema.ID = AgentSchema.ID(rawValue: "build"),
        messageID: String = "msg_001",
        callID: String = "call_001"
    ) -> ToolSchema.Context {
        ToolSchema.Context(
            sessionID: sessionID,
            agent: agent,
            messageID: messageID,
            id: ToolSchema.CallID(rawValue: callID),
            progress: { _ in }
        )
    }

    static func firstText(from result: CoreTool.NormalizedResult) -> String {
        for part in result.content {
            if case .text(let tc) = part { return tc.text }
        }
        return ""
    }

    static func allText(from result: CoreTool.NormalizedResult) -> String {
        result.content.compactMap { part -> String? in
            if case .text(let tc) = part { return tc.text }
            return nil
        }.joined(separator: "\n")
    }

    /// Mock `HTTPTransport` for deterministic `webfetch` and redirect tests.
    final class MockHTTPTransport: HTTPTransport, Sendable {
        private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
        private let recorded = Mutex<[HTTPRequest]>([])

        init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
            self.handler = handler
        }

        func requests() -> [HTTPRequest] {
            recorded.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.withLock { $0.append(request) }
            return try await handler(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let resp = try await send(request)
            let body = resp.body
            let stream = AsyncThrowingStream<[UInt8], Error> { cont in
                if !body.isEmpty { cont.yield(body) }
                cont.finish()
            }
            return HTTPStreamingResponse(head: resp.head, chunks: stream)
        }
    }

    /// Mock `ProcessSpawner` for deterministic shell and formatter tests.
    final class MockProcessSpawner: ProcessSpawner, Sendable {
        private let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput
        private let recorded = Mutex<[ProcessSpec]>([])

        init(_ handler: @escaping @Sendable (ProcessSpec) async throws -> ProcessOutput) {
            self.handler = handler
        }

        func specs() -> [ProcessSpec] {
            recorded.withLock { $0 }
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            recorded.withLock { $0.append(spec) }
            return try await handler(spec)
        }
    }

    /// Mock MCP tool bridge for testing `CoreTool.Mcp.Service`.
    final class MockMcpBridge: CoreTool.Mcp.ClientBridge, Sendable {
        private let descriptors: [CoreTool.Mcp.ToolDescriptor]
        private let callHandler: @Sendable (String, String, JSONValue, SessionID) async throws -> CoreTool.Mcp.ToolCallResult

        init(
            descriptors: [CoreTool.Mcp.ToolDescriptor],
            callHandler: @escaping @Sendable (String, String, JSONValue, SessionID) async throws -> CoreTool.Mcp.ToolCallResult
        ) {
            self.descriptors = descriptors
            self.callHandler = callHandler
        }

        func tools() async -> [CoreTool.Mcp.ToolDescriptor] {
            descriptors
        }

        func callTool(
            server: String,
            name: String,
            args: JSONValue,
            sessionID: SessionID
        ) async throws -> CoreTool.Mcp.ToolCallResult {
            try await callHandler(server, name, args, sessionID)
        }
    }

    /// Thread-safe accumulator for async callback assertions.
    final class Box<T: Sendable>: Sendable {
        private let storage: Mutex<T>

        init(_ initial: T) {
            self.storage = Mutex(initial)
        }

        func get() -> T {
            storage.withLock { $0 }
        }

        func update(_ body: (inout T) -> Void) {
            storage.withLock { body(&$0) }
        }
    }
}
