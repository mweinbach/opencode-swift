#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Scripted `HTTPTransport` and JSON helpers for `AIVideoProtocolsTests`
/// (kept separate from `import Testing` per macOS CLT cross-import rule).
final class VideoProtocolMockTransport: HTTPTransport, Sendable {
    typealias Handler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse

    private struct State: Sendable {
        var requests: [HTTPRequest] = []
    }

    private let state = Mutex(State())
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let idx = state.withLock { s -> Int in
            let current = s.requests.count
            s.requests.append(request)
            return current
        }
        return try await handler(request, idx)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let resp = try await send(request)
        let body = resp.body
        let s = AsyncThrowingStream<[UInt8], Error> { cont in
            if !body.isEmpty { cont.yield(body) }
            cont.finish()
        }
        return HTTPStreamingResponse(head: resp.head, chunks: s)
    }
}

enum VideoProtocolFixture {
    static func jsonResponse(
        _ value: JSONValue,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        var h = headers
        h["content-type"] = "application/json"
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: h),
            body: Array(data)
        )
    }

    static func bytesResponse(
        _ bytes: [UInt8],
        contentType: String = "video/mp4",
        statusCode: Int = 200
    ) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": contentType]),
            body: bytes
        )
    }

    static func decodeBody(_ request: HTTPRequest) throws -> [String: JSONValue] {
        guard let bytes = request.body else { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(bytes))
    }

    static func headerValue(_ request: HTTPRequest, _ name: String) -> String? {
        let lower = name.lowercased()
        return request.headers.first { $0.key.lowercased() == lower }?.value
    }

    /// Minimal valid ISO-BMFF MP4 header (`ftypisom`) recognized by both `AIUtils.detectMediaType` and `CoreFilesystem.Mime.detectMedia`.
    static func sampleMP4Bytes() -> [UInt8] {
        [
            0x00, 0x00, 0x00, 0x18, // box size 24
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // "isom"
            0x00, 0x00, 0x02, 0x00, // minor version
            0x69, 0x73, 0x6F, 0x6D, // compatible brand "isom"
            0x6D, 0x70, 0x34, 0x31, // compatible brand "mp41"
        ]
    }

    static func samplePNGBytes() -> [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
    }

    static func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    static func fastRetry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await AIRoute.MediaRoute.$readRetryConfig.withValue(
            AIRoute.MediaRoute.ReadRetryConfig(maxRetries: 4, initialDelayMs: 1, maxDelayMs: 5, jitter: false)
        ) {
            try await body()
        }
    }
}
