#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema

/// Foundation JSON / mock HTTP transport helpers for `OpenCodeAITests`.
/// Kept separate from `AICoreAndLoopTests.swift` so test files importing `Testing`
/// never import `Foundation` or `FoundationEssentials` (macOS CLT cross-import rule).
enum AICoreTestHelper {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let json = try encodeJSON(value)
        return try decodeJSON(T.self, from: json)
    }

    static func makeURL(_ string: String) -> URL {
        URL(string: string)!
    }

    static func makeByteStream(_ chunks: [[UInt8]]) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    /// Programmable in-memory `HTTPTransport` for portable, network-free testing.
    final class MockHTTPTransport: HTTPTransport, Sendable {
        struct ScriptedReply: Sendable {
            let status: Int
            let headers: [String: String]
            let chunks: [[UInt8]]

            init(status: Int = 200, headers: [String: String] = [:], body: String) {
                self.status = status
                self.headers = headers
                self.chunks = [Array(body.utf8)]
            }

            init(status: Int = 200, headers: [String: String] = [:], chunks: [[UInt8]]) {
                self.status = status
                self.headers = headers
                self.chunks = chunks
            }
        }

        private struct State: Sendable {
            var requests: [HTTPRequest] = []
            var queue: [ScriptedReply] = []
            var handler: (@Sendable (HTTPRequest) async throws -> ScriptedReply)?
        }

        private let state = Mutex(State())

        init(
            replies: [ScriptedReply] = [],
            handler: (@Sendable (HTTPRequest) async throws -> ScriptedReply)? = nil
        ) {
            state.withLock { s in
                s.queue = replies
                s.handler = handler
            }
        }

        var recordedRequests: [HTTPRequest] {
            state.withLock { $0.requests }
        }

        func enqueue(_ reply: ScriptedReply) {
            state.withLock { $0.queue.append(reply) }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let reply = try await nextReply(for: request)
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: reply.status, headers: reply.headers),
                body: AIUtils.concatBytes(reply.chunks)
            )
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let reply = try await nextReply(for: request)
            return HTTPStreamingResponse(
                head: HTTPResponseHead(statusCode: reply.status, headers: reply.headers),
                chunks: AICoreTestHelper.makeByteStream(reply.chunks)
            )
        }

        private func nextReply(for request: HTTPRequest) async throws -> ScriptedReply {
            let (queued, handler): (ScriptedReply?, (@Sendable (HTTPRequest) async throws -> ScriptedReply)?) = state.withLock { s in
                s.requests.append(request)
                if !s.queue.isEmpty {
                    return (s.queue.removeFirst(), nil)
                }
                return (nil, s.handler)
            }
            if let queued { return queued }
            if let handler { return try await handler(request) }
            throw AIRequestExecutor.ClientTransportError(
                request: request,
                message: "MockHTTPTransport has no reply for \(request.method) \(request.url)",
                code: "ECONNREFUSED"
            )
        }
    }

    /// Creates a minimal test `LanguageModel` on a dummy route with configurable route ID, capabilities, and compatibility.
    static func makeTestModel(
        id: String = "claude-sonnet-4",
        provider: String = "anthropic",
        routeID: String = "anthropic-messages",
        baseURL: String = "https://api.example.test",
        options: AISchema.RequestOptions? = nil,
        capabilities: AISchema.Capabilities? = nil,
        compatibility: AISchema.LanguageModelCompatibility? = nil,
        supportsEffortUpdates: (@Sendable (AISchema.LLMRequest) -> Bool)? = nil,
        toolUpdates: AIToolUpdates.ToolUpdateEncoding? = nil,
        compact: AIRoute.CompactionOperations? = nil
    ) -> AISchema.LanguageModel {
        let route = AIRoute.AnyRoute(
            compact: compact,
            id: routeID,
            provider: AISchema.ProviderID.make(provider),
            protocolID: routeID,
            baseURL: baseURL,
            options: options,
            supportsEffortUpdates: supportsEffortUpdates,
            toolUpdates: toolUpdates,
            buildBody: { req in
                .object(["model": .string(req.model.id.rawValue), "messageCount": .int(Int64(req.messages.count))])
            },
            executeStream: { _, _, _ in
                AsyncThrowingStream { $0.finish() }
            }
        )
        return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
            id: id,
            provider: provider,
            route: route,
            options: options,
            capabilities: capabilities,
            compatibility: compatibility
        ))
    }
}
