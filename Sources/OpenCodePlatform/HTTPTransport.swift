/// Cross-platform HTTP transport abstraction decoupling `OpenCodeAI` and `OpenCodeClient`
/// from platform networking stacks (`URLSession`, `AsyncHTTPClient`, Wasm `fetch`, or mock transports).
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: [UInt8]?

    public init(
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: [UInt8]? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseHead: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let head: HTTPResponseHead
    public let body: [UInt8]

    public init(head: HTTPResponseHead, body: [UInt8]) {
        self.head = head
        self.body = body
    }
}

public struct HTTPStreamingResponse: Sendable {
    public let head: HTTPResponseHead
    public let chunks: AsyncThrowingStream<[UInt8], Error>

    public init(head: HTTPResponseHead, chunks: AsyncThrowingStream<[UInt8], Error>) {
        self.head = head
        self.chunks = chunks
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse
}
