import OpenCodeUtil

/// Application-wide dependency graph scope tags (`global` and `location`) matching `util/src/effect/app-node.ts`.
public enum AppNode {
    // parity: util/src/effect/app-node.ts#tags [status=implemented hash=6a871c2dae29]
    public static let tags: LayerNode.Tags = LayerNode.tags([
        "location": ["global"],
        "global": [],
    ])

    // parity: util/src/effect/app-node.ts#GlobalGraph [status=implemented hash=013e5a80c592]
    public typealias GlobalGraph = LayerNode.Graph

    // parity: util/src/effect/app-node.ts#LocationGraph [status=implemented hash=4520717f3b49]
    public typealias LocationGraph = LayerNode.Graph

    // parity: util/src/effect/app-node.ts#makeGlobalNode [status=implemented hash=60799060bb87]
    public static let makeGlobalNode: LayerNode.TagMaker = tags.make("global")

    // parity: util/src/effect/app-node.ts#makeLocationNode [status=implemented hash=a64547cb2bc9]
    public static let makeLocationNode: LayerNode.TagMaker = tags.make("location")
}

/// Default platform dependency graph providers matching `util/src/effect/app-node-platform.ts`.
public enum LayerNodePlatform {
    public static let fileSystemKey = "@opencode/FileSystem"
    public static let pathKey = "@opencode/Path"
    public static let fetchKey = "@opencode/Fetch"
    public static let httpClientKey = "@opencode/HttpClient"
    private static let nativeTransportKey = "@opencode/NativeHttpTransport"

    // parity: util/src/effect/app-node-platform.ts#Fetch [status=implemented hash=3a8c3b0953ee]
    public typealias Fetch = @Sendable (HTTPRequest) async throws -> HTTPResponse

    // parity: util/src/effect/app-node-platform.ts#filesystem [status=implemented hash=921a9aff3b5d]
    public static let filesystem: LayerNode.Provider = AppNode.makeGlobalNode(
        fileSystemKey,
        LayerNode.ExecutableLayer.succeed(key: fileSystemKey, value: LocalFileSystem.shared as any OpenCodeFileSystem),
        []
    )

    // parity: util/src/effect/app-node-platform.ts#path [status=implemented hash=8ff101037155]
    public static let path: LayerNode.Provider = AppNode.makeGlobalNode(
        pathKey,
        LayerNode.ExecutableLayer.succeed(key: pathKey, value: String(Platform.current.pathSeparator)),
        []
    )

    // parity: util/src/effect/app-node-platform.ts#fetchLayer [status=implemented hash=2c74eeee95e0]
    public static func fetchLayer(_ fetch: Fetch? = nil) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, _ in
            if let fetch {
                return LayerNode.Output([fetchKey: fetch])
            }
            if let existing = deps.get(fetchKey, as: Fetch.self) {
                if let native = deps.get(nativeTransportKey, as: (any HTTPTransport).self) {
                    return LayerNode.Output([fetchKey: existing, nativeTransportKey: native])
                }
                return LayerNode.Output([fetchKey: existing])
            }
            #if !os(WASI)
            let defaultFetch: Fetch = { request in
                try await URLSessionHTTPTransport.shared.send(request)
            }
            return LayerNode.Output([
                fetchKey: defaultFetch,
                nativeTransportKey: URLSessionHTTPTransport.shared as any HTTPTransport,
            ])
            #else
            let fallback: Fetch = { _ in
                throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "HTTPTransport.defaultFetch")
            }
            return LayerNode.Output([fetchKey: fallback])
            #endif
        }
    }

    // parity: util/src/effect/app-node-platform.ts#httpFetch [status=implemented hash=5d8a3678d43f]
    public static let httpFetch: LayerNode.Provider = AppNode.makeGlobalNode(
        fetchKey,
        fetchLayer(),
        []
    )

    /// HTTP transport adapter backed by a `Fetch` function.
    public struct FetchTransport: HTTPTransport, Sendable {
        private let fetch: Fetch

        public init(_ fetch: @escaping Fetch) {
            self.fetch = fetch
        }

        public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await fetch(request)
        }

        public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let response = try await fetch(request)
            let body = response.body
            let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
                if !body.isEmpty { continuation.yield(body) }
                continuation.finish()
            }
            return HTTPStreamingResponse(head: response.head, chunks: stream)
        }
    }

    // parity: util/src/effect/app-node-platform.ts#httpClient [status=implemented hash=8ef0b2f985dd]
    public static let httpClient: LayerNode.Provider = AppNode.makeGlobalNode(
        httpClientKey,
        LayerNode.ExecutableLayer { deps, _ in
            if let nativeTransport = deps.get(nativeTransportKey, as: (any HTTPTransport).self) {
                return LayerNode.Output([httpClientKey: nativeTransport])
            }
            if let fetch = deps.get(fetchKey, as: Fetch.self) {
                let transport: any HTTPTransport = FetchTransport(fetch)
                return LayerNode.Output([httpClientKey: transport])
            }
            #if !os(WASI)
            return LayerNode.Output([httpClientKey: URLSessionHTTPTransport.shared as any HTTPTransport])
            #else
            let fallback: Fetch = { _ in
                throw PlatformError.unsupportedOnPlatform(Platform.current, operation: "HTTPTransport.httpClient")
            }
            let transport: any HTTPTransport = FetchTransport(fallback)
            return LayerNode.Output([httpClientKey: transport])
            #endif
        },
        [httpFetch]
    )
}

/// Long-lived HTTP fetch helper opting out of default idle timeouts (`util/src/no-timeout-fetch.ts`).
public enum NoTimeoutFetch {
    // parity: util/src/no-timeout-fetch.ts#noTimeoutFetch [status=implemented hash=3e28e1459f8e]
    public static func noTimeoutFetch(
        _ request: HTTPRequest,
        transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        var headers = request.headers
        if headers["X-OpenCode-No-Timeout"] == nil {
            headers["X-OpenCode-No-Timeout"] = "1"
        }
        return try await transport.send(HTTPRequest(
            method: request.method,
            url: request.url,
            headers: headers,
            body: request.body
        ))
    }
}
