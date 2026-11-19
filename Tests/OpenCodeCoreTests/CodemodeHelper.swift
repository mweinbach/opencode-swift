import Foundation
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

/// Test helpers for `CodemodeTests.swift`.
/// Separated from `CodemodeTests.swift` per the macOS CLT cross-import rule
/// (never import `Foundation` in the same file as `Testing`).
enum CodemodeTestHelper {
    final class MockHTTPTransport: HTTPTransport, Sendable {
        struct RecordedRequest: Equatable, Sendable {
            let method: String
            let url: String
            let headers: [String: String]
            let bodyText: String?
        }

        private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
        private let requestsBox = Mutex<[RecordedRequest]>([])

        init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
            self.handler = handler
        }

        var recordedRequests: [RecordedRequest] {
            requestsBox.withLock { $0 }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requestsBox.withLock {
                $0.append(RecordedRequest(
                    method: request.method,
                    url: request.url,
                    headers: request.headers,
                    bodyText: request.body.map { String(decoding: $0, as: UTF8.self) }
                ))
            }
            return try await handler(request)
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let resp = try await send(request)
            let body = resp.body
            let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            return HTTPStreamingResponse(head: resp.head, chunks: stream)
        }
    }

    static func makeToolContext(
        progress: @escaping @Sendable (ToolSchema.Metadata) async -> Void = { _ in }
    ) -> ToolSchema.Context {
        ToolSchema.Context(
            sessionID: SessionID.create(),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_test_001",
            id: ToolSchema.CallID(rawValue: "call_test_001"),
            progress: progress,
            cancel: nil
        )
    }

    static func makeResponse(
        status: Int = 200,
        headers: [String: String] = ["content-type": "application/json"],
        body: String
    ) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: status, headers: headers),
            body: Array(body.utf8)
        )
    }

    static func utf8Bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func stringFromUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func sleepMs(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    static func makeSampleOpenAPISpec() -> CodemodeEngine.OpenAPI.Document {
        [
            "openapi": .string("3.1.0"),
            "info": .object(["title": .string("Issues API"), "version": .string("1.0.0")]),
            "servers": .array([.object(["url": .string("https://api.example.test/v1")])]),
            "components": .object([
                "securitySchemes": .object([
                    "bearerAuth": .object(["type": .string("http"), "scheme": .string("bearer")]),
                    "cookieAuth": .object(["type": .string("apiKey"), "in": .string("cookie"), "name": .string("sid")]),
                ]),
            ]),
            "paths": .object([
                "/repos/{owner}/issues": .object([
                    "get": .object([
                        "operationId": .string("issues.list"),
                        "summary": .string("List repository issues"),
                        "security": .array([.object(["bearerAuth": .array([])])]),
                        "parameters": .array([
                            .object([
                                "name": .string("owner"),
                                "in": .string("path"),
                                "required": .bool(true),
                                "schema": .object(["type": .string("string")]),
                            ]),
                            .object([
                                "name": .string("state"),
                                "in": .string("query"),
                                "schema": .object(["type": .string("string")]),
                            ]),
                        ]),
                        "responses": .object([
                            "200": .object([
                                "description": .string("OK"),
                                "content": .object([
                                    "application/json": .object([
                                        "schema": .object([
                                            "type": .string("array"),
                                            "items": .object([
                                                "type": .string("object"),
                                                "properties": .object([
                                                    "id": .object(["type": .string("integer")]),
                                                    "title": .object(["type": .string("string")]),
                                                ]),
                                            ]),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                "/events": .object([
                    "get": .object([
                        "operationId": .string("events.stream"),
                        "responses": .object([
                            "200": .object([
                                "content": .object([
                                    "text/event-stream": .object([:]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]
    }
}
