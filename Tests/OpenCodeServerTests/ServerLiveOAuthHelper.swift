#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Helper fixtures and programmable mock `HTTPTransport` for `ServerLiveOAuthAndModelsTests`.
/// Kept free of `import Testing` to obey the macOS Command Line Tools cross-import rule.
enum LiveOAuthFixture {

    struct RecordedRequest: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let bodyText: String

        func header(_ name: String) -> String? {
            ServerHeaders.value(in: headers, for: name)
        }
    }

    enum MockResult: Sendable {
        case json(status: Int = 200, headers: [String: String] = [:], body: String)
        case sse(status: Int = 200, chunks: [String])
        case failure(String)
    }

    /// Programmable `HTTPTransport` routing outbound requests via user-supplied handler closure
    /// while recording every request thread-safely (zero real internet required!).
    final class MockTransport: HTTPTransport, Sendable {
        private let handlerBox: Mutex<@Sendable (RecordedRequest) async -> MockResult>
        private let recordedBox = Mutex<[RecordedRequest]>([])

        init(handler: @escaping @Sendable (RecordedRequest) async -> MockResult) {
            self.handlerBox = Mutex(handler)
        }

        func setHandler(_ handler: @escaping @Sendable (RecordedRequest) async -> MockResult) {
            handlerBox.withLock { $0 = handler }
        }

        var recordedRequests: [RecordedRequest] {
            recordedBox.withLock { $0 }
        }

        func clearRecorded() {
            recordedBox.withLock { $0.removeAll() }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let rec = RecordedRequest(
                method: request.method,
                url: request.url,
                headers: request.headers,
                bodyText: String(decoding: request.body ?? [], as: UTF8.self)
            )
            recordedBox.withLock { $0.append(rec) }
            let handler = handlerBox.withLock { $0 }
            switch await handler(rec) {
            case .json(let status, let extraHeaders, let body):
                var headers = extraHeaders
                if ServerHeaders.value(in: headers, for: "content-type") == nil {
                    headers["content-type"] = "application/json"
                }
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: status, headers: headers),
                    body: Array(body.utf8)
                )
            case .sse(let status, let chunks):
                let joined = chunks.joined()
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: status, headers: ["content-type": "text/event-stream"]),
                    body: Array(joined.utf8)
                )
            case .failure(let message):
                throw HTTPTransportError.networkFailure(message)
            }
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let rec = RecordedRequest(
                method: request.method,
                url: request.url,
                headers: request.headers,
                bodyText: String(decoding: request.body ?? [], as: UTF8.self)
            )
            recordedBox.withLock { $0.append(rec) }
            let handler = handlerBox.withLock { $0 }
            switch await handler(rec) {
            case .sse(let status, let chunks):
                let stream = AsyncThrowingStream<[UInt8], Error> { cont in
                    for chunk in chunks {
                        cont.yield(Array(chunk.utf8))
                    }
                    cont.finish()
                }
                return HTTPStreamingResponse(
                    head: HTTPResponseHead(statusCode: status, headers: ["content-type": "text/event-stream"]),
                    chunks: stream
                )
            case .json(let status, let extraHeaders, let body):
                var headers = extraHeaders
                if ServerHeaders.value(in: headers, for: "content-type") == nil {
                    headers["content-type"] = "application/json"
                }
                let stream = AsyncThrowingStream<[UInt8], Error> { cont in
                    cont.yield(Array(body.utf8))
                    cont.finish()
                }
                return HTTPStreamingResponse(
                    head: HTTPResponseHead(statusCode: status, headers: headers),
                    chunks: stream
                )
            case .failure(let message):
                throw HTTPTransportError.networkFailure(message)
            }
        }
    }

    struct Harness: Sendable {
        let handle: ServerFetch.Handle
        let client: OpenCodeClient
        let fileSystem: InMemoryFileSystem
        let mockTransport: MockTransport
        let rootDir: String
        let globalCache: String

        var runtime: ServerAppRuntime { handle.runtime }

        func close() async {
            await handle.close()
        }
    }

    static func makeHarness(
        env: [String: String] = [:],
        configContent: String? = nil,
        modelsFetch: Bool? = true,
        modelsURL: String? = nil,
        initialFiles: [String: [UInt8]] = [:],
        handler: @escaping @Sendable (RecordedRequest) async -> MockResult = { _ in .json(status: 404, body: "{}") }
    ) async throws -> Harness {
        let fs = InMemoryFileSystem()
        let rootDir = "/workspace"
        let stateBase = "/tmp/opencode-oauth-test"
        let globalCache = "\(stateBase)/cache"
        try await fs.makeDirectory(at: rootDir, recursive: true)
        try await fs.makeDirectory(at: "\(stateBase)/config", recursive: true)
        try await fs.makeDirectory(at: "\(stateBase)/data", recursive: true)
        try await fs.makeDirectory(at: globalCache, recursive: true)
        try await fs.makeDirectory(at: "\(stateBase)/log", recursive: true)
        try await fs.makeDirectory(at: "\(stateBase)/home", recursive: true)
        for (path, bytes) in initialFiles {
            try await fs.writeFile(bytes, to: path, createDirectories: true)
        }

        let globalOverrides = Global.Overrides(
            home: "\(stateBase)/home",
            data: "\(stateBase)/data",
            cache: globalCache,
            config: "\(stateBase)/config",
            state: "\(stateBase)/state",
            tmp: "\(stateBase)/tmp",
            bin: "\(stateBase)/bin",
            log: "\(stateBase)/log",
            repos: "\(stateBase)/repos"
        )
        let options = ServerOptions(
            app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-oauth-test", channel: "local"),
            events: ServerOptions.EventsOptions(persist: true),
            models: CoreModel.ModelsDev.Options(url: modelsURL, fetch: modelsFetch),
            config: ServerOptions.ConfigOptions(
                directory: "\(stateBase)/config",
                project: false,
                claude: false,
                content: configContent
            )
        )
        let mockTransport = MockTransport(handler: handler)
        let handle = try await ServerFetch.make(
            options: options,
            boot: ServerFetch.BootOptions(
                fileSystem: fs,
                httpTransport: mockTransport,
                environment: DictionaryEnvironment(
                    variables: env,
                    homeDirectory: "\(stateBase)/home",
                    temporaryDirectory: "\(stateBase)/tmp"
                ),
                globalOverrides: globalOverrides,
                defaultDirectory: rootDir
            )
        )
        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: handle.transport
        ))
        return Harness(
            handle: handle,
            client: client,
            fileSystem: fs,
            mockTransport: mockTransport,
            rootDir: rootDir,
            globalCache: globalCache
        )
    }

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func utf8(_ data: [UInt8]) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Performs a real loopback HTTP GET request against an ephemeral local `POSIXHTTPServer`.
    static func sendRealLoopbackGET(_ url: String) async throws -> (status: Int, contentType: String?, body: String) {
        let transport = URLSessionHTTPTransport(configuration: .init(
            timeoutIntervalForRequest: 5,
            timeoutIntervalForResource: 5
        ))
        defer { transport.invalidateAndCancel() }
        let resp = try await transport.send(HTTPRequest(method: "GET", url: url, headers: ["accept": "text/html"]))
        return (
            status: resp.head.statusCode,
            contentType: ServerHeaders.value(in: resp.head.headers, for: "content-type"),
            body: String(decoding: resp.body, as: UTF8.self)
        )
    }

    /// Parses form-urlencoded key/value pairs from a request body.
    static func parseFormParams(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&", omittingEmptySubsequences: true) {
            if let eq = pair.firstIndex(of: "=") {
                let k = ServerParsedURL.decodeFormComponent(String(pair[..<eq]))
                let v = ServerParsedURL.decodeFormComponent(String(pair[pair.index(after: eq)...]))
                out[k] = v
            }
        }
        return out
    }

    /// Builds a mock unsigned JWT with a JSON payload for testing OpenAI `id_token` claim extraction & nonce check.
    static func makeJWT(payload: [String: JSONValue]) -> String {
        let header = ServerCrypto.base64URLEncode(Array(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payloadBytes = (try? ServerCodec.encode(JSONValue.object(payload))) ?? []
        let payloadB64 = ServerCrypto.base64URLEncode(payloadBytes)
        return "\(header).\(payloadB64).mock_signature"
    }

    /// Computes S256 PKCE challenge for a verifier to assert real cryptographic PKCE parity.
    static func s256Challenge(for verifier: String) -> String {
        ServerCrypto.base64URLEncode(ServerCrypto.sha256Bytes(Array(verifier.utf8)))
    }

    /// Polls until `condition()` returns true or timeout elapses (in ms).
    static func waitUntil(
        timeoutMs: Int64 = 3_000,
        pollMs: Int64 = 10,
        condition: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Flock.currentEpochMs() + timeoutMs
        while Flock.currentEpochMs() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(pollMs))
        }
        return try await condition()
    }

    /// OpenAI Chat Completions SSE response chunks for testing live LLM calls after OAuth refresh.
    static func openAIChatSSE(text: String) -> [String] {
        let escaped = text.replacing("\"", with: "\\\"")
        return [
            "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"chatcmpl_1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\n",
            "data: [DONE]\n\n",
        ]
    }

    /// OpenAI Responses SSE response chunks for testing live OpenAI / ChatGPT OAuth LLM calls.
    static func openAIResponsesSSE(text: String) -> [String] {
        let escaped = text.replacing("\"", with: "\\\"")
        return [
            "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_oauth_1\",\"status\":\"in_progress\"}}\n\n",
            "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\n",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"\(escaped)\"}\n\n",
            "event: response.output_text.done\ndata: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"\(escaped)\"}\n\n",
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_oauth_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"total_tokens\":16}}}\n\n",
        ]
    }

    /// Sample ModelsDev v2 JSON catalog containing:
    /// - `opencode` provider with a FREE model (`big-pickle`, input=0) and PAID model (`claude-sonnet-4-6`, input=3.0)
    /// - `anthropic` provider with an additional live model (`claude-4-7-live`)
    /// - net-new `cohere` provider (`command-a-live`)
    static func sampleModelsDevCatalogJSON(extraCohereModelID: String? = nil) -> String {
        let extraModelBlock: String
        if let extraID = extraCohereModelID {
            extraModelBlock = """
            ,
            "\(extraID)": {
              "id": "\(extraID)",
              "name": "Live Reloaded Model",
              "family": "command",
              "type": "chat",
              "release_date": "2026-06-01",
              "status": "active",
              "limit": { "context": 256000, "output": 16384 },
              "modalities": { "input": ["text"], "output": ["text"] },
              "capabilities": { "tools": { "supported": true }, "temperature": true },
              "cost": { "text": { "input": { "price": 1.0 }, "output": { "price": 4.0 } } },
              "api": {
                "chat-completions": {
                  "base_url": "https://api.cohere.com/v2",
                  "sdk": { "opencodeai": "@opencode/ai/providers/openai-compatible" }
                }
              }
            }
            """
        } else {
            extraModelBlock = ""
        }
        return """
        {
          "opencode": {
            "id": "opencode",
            "name": "OpenCode",
            "env": ["OPENCODE_API_KEY"],
            "models": {
              "big-pickle": {
                "id": "big-pickle",
                "name": "Big Pickle (Free)",
                "family": "big-pickle",
                "type": "chat",
                "release_date": "2026-03-01",
                "status": "active",
                "limit": { "context": 200000, "output": 32768 },
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "temperature": true },
                "cost": { "text": { "input": { "price": 0 }, "output": { "price": 0 } } },
                "api": {
                  "chat-completions": {
                    "base_url": "https://opencode.ai/zen/v1",
                    "sdk": { "opencodeai": "@opencode/ai/providers/openai-compatible" }
                  }
                }
              },
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "name": "Claude Sonnet 4.6",
                "family": "claude-sonnet",
                "type": "chat",
                "release_date": "2026-02-17",
                "status": "active",
                "limit": { "context": 200000, "output": 64000 },
                "modalities": { "input": ["text", "image"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "temperature": true },
                "cost": { "text": { "input": { "price": 3.0 }, "output": { "price": 15.0 } } },
                "api": {
                  "messages": {
                    "base_url": "https://opencode.ai/zen/v1",
                    "sdk": { "opencodeai": "@opencode/ai/providers/anthropic" }
                  }
                }
              }
            }
          },
          "cohere": {
            "id": "cohere",
            "name": "Cohere Live",
            "env": ["COHERE_API_KEY"],
            "models": {
              "command-a-live": {
                "id": "command-a-live",
                "name": "Command A Live",
                "family": "command",
                "type": "chat",
                "release_date": "2026-04-01",
                "status": "active",
                "limit": { "context": 256000, "output": 8192 },
                "modalities": { "input": ["text"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "temperature": true },
                "cost": { "text": { "input": { "price": 2.5 }, "output": { "price": 10.0 } } },
                "api": {
                  "chat-completions": {
                    "base_url": "https://api.cohere.com/v2",
                    "sdk": { "opencodeai": "@opencode/ai/providers/openai-compatible" }
                  }
                }
              }\(extraModelBlock)
            }
          },
          "anthropic": {
            "id": "anthropic",
            "name": "Anthropic Catalog",
            "env": ["ANTHROPIC_API_KEY"],
            "models": {
              "claude-4-7-live": {
                "id": "claude-4-7-live",
                "name": "Claude 4.7 Live",
                "family": "claude-sonnet",
                "type": "chat",
                "release_date": "2026-05-01",
                "status": "active",
                "limit": { "context": 300000, "output": 64000 },
                "modalities": { "input": ["text", "image"], "output": ["text"] },
                "capabilities": { "tools": { "supported": true }, "temperature": true },
                "cost": { "text": { "input": { "price": 3.0 }, "output": { "price": 15.0 } } },
                "api": {
                  "messages": {
                    "base_url": "https://api.anthropic.com/v1",
                    "sdk": { "opencodeai": "@opencode/ai/providers/anthropic" }
                  }
                }
              }
            }
          }
        }
        """
    }
}
