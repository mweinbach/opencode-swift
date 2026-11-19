import Testing
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Schema & Event Fold Tests

@Suite("OpenCodeAI Schema & Event Fold Tests")
struct AISchemaTests {
    @Test("Usage visibleOutputTokens clamps negative underflow to zero")
    func usageVisibleOutputTokens() {
        let normal = AISchema.Usage(inputTokens: 100, outputTokens: 80, reasoningTokens: 30)
        #expect(normal.visibleOutputTokens == 50)

        let overflow = AISchema.Usage(outputTokens: 20, reasoningTokens: 45)
        #expect(overflow.visibleOutputTokens == 0)

        #expect(AISchema.tokenUsage() == nil)
        #expect(AISchema.tokenUsage(input: 10, output: 5) == .tokens(input: 10, output: 5, total: nil, details: nil))
    }

    @Test("AIError retryability, code extraction, and x-should-retry overrides")
    func aiErrorSemantics() {
        let rateLimit = AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
            message: "Slow down",
            body: #"{"error":{"code":"rate_limit_exceeded"}}"#,
            http: AISchema.HttpContext(url: "https://api.test/v1", status: 429, headers: ["x-amzn-errortype": "ThrottlingException:http://aws"]),
            rateLimit: AISchema.HttpRateLimitDetails(retryAfterMs: 1500)
        )))
        #expect(rateLimit.isRetryable == true)
        #expect(rateLimit.status == 429)
        #expect(rateLimit.code == "rate_limit_exceeded")
        #expect(rateLimit.retryAfterMs == 1500)

        let forcedNoRetry = AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
            message: "No retry",
            http: AISchema.HttpContext(url: "https://api.test/v1", status: 429, headers: ["x-should-retry": "false"])
        )))
        #expect(forcedNoRetry.isRetryable == false)

        let forcedRetry = AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
            message: "Force retry",
            http: AISchema.HttpContext(url: "https://api.test/v1", status: 400, headers: ["x-should-retry": "true"])
        )))
        #expect(forcedRetry.isRetryable == true)

        let transportReadAccepted = AISchema.AIError(reason: .transport(AISchema.TransportError(
            message: "Dropped",
            transport: .websocket,
            operation: .read,
            code: "ECONNRESET",
            delivery: .accepted
        )))
        #expect(transportReadAccepted.isRetryable == true)
        #expect(transportReadAccepted.code == "ECONNRESET")

        let transportWriteAccepted = AISchema.AIError(reason: .transport(AISchema.TransportError(
            message: "Write after accepted",
            transport: .websocket,
            operation: .write,
            delivery: .accepted
        )))
        #expect(transportWriteAccepted.isRetryable == false)

        let transportRejected = AISchema.AIError(reason: .transport(AISchema.TransportError(
            message: "Rejected",
            transport: .http,
            operation: .request,
            delivery: .rejected
        )))
        #expect(transportRejected.isRetryable == false)

        let incompleteStream = AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
            message: "Cut off",
            classification: .incompleteStream
        )))
        #expect(incompleteStream.isRetryable == true)

        let malformedOutput = AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
            message: "Bad JSON"
        )))
        #expect(malformedOutput.isRetryable == false)

        let unknown = AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(message: "Mystery")))
        #expect(unknown.isRetryable == true)

        let auth = AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(message: "Bad key")))
        #expect(auth.isRetryable == false)
    }

    @Test("mergeJsonRecords, mergeTransport, mergeGeneration, and mergeRequestOptions")
    func optionsMerging() {
        let merged = AISchema.mergeJsonRecords(
            ["a": .int(1), "nested": .object(["x": .string("old"), "keep": .bool(true)])],
            ["b": .int(2), "nested": .object(["x": .string("new"), "added": .int(9)])]
        )
        #expect(merged?["a"] == .int(1))
        #expect(merged?["b"] == .int(2))
        #expect(merged?["nested"] == .object(["x": .string("new"), "keep": .bool(true), "added": .int(9)]))

        let opts = AISchema.mergeRequestOptions(
            AISchema.RequestOptions(
                headers: ["x-a": "1", "x-shared": "route"],
                timeout: .single(.milliseconds(5000)),
                http: AISchema.HttpOptions(query: ["api-version": "2025-01"], body: ["extra": .object(["a": .int(1)])]),
                maxTokens: 1024,
                temperature: 0.7,
                providerOptions: ["anthropic": .object(["beta": .bool(true)])]
            ),
            AISchema.RequestOptions(
                headers: ["x-shared": "req", "x-b": "2"],
                timeout: .phases(AISchema.TimeoutConfig(chunk: .milliseconds(30_000))),
                http: AISchema.HttpOptions(body: ["extra": .object(["b": .int(2)])], encoding: .gzip),
                maxTokens: 2048,
                providerOptions: ["anthropic": .object(["thinking": .string("on")])]
            )
        )
        #expect(opts?.headers?["x-a"] == "1")
        #expect(opts?.headers?["x-shared"] == "req")
        #expect(opts?.headers?["x-b"] == "2")
        #expect(opts?.maxTokens == 2048)
        #expect(opts?.temperature == 0.7)
        #expect(opts?.http?.encoding == .gzip)
        #expect(opts?.http?.query?["api-version"] == "2025-01")
        #expect(opts?.http?.body?["extra"] == .object(["a": .int(1), "b": .int(2)]))
        #expect(opts?.timeout == .phases(AISchema.TimeoutConfig(total: .milliseconds(5000), headers: nil, chunk: .milliseconds(30_000))))
    }

    @Test("CacheTTL, CompactionPart XOR Codable, ToolDefinition.freeformField, and ToolChoice.make")
    func schemaValidators() throws {
        #expect(AISchema.CacheTTL(rawValue: "5m")?.rawValue == "5m")
        #expect(AISchema.CacheTTL(rawValue: "500ms")?.rawValue == "500ms")
        #expect(AISchema.CacheTTL(rawValue: "24h")?.rawValue == "24h")
        #expect(AISchema.CacheTTL(rawValue: "bad") == nil)
        #expect(AISchema.CacheTTL(rawValue: "5w") == nil)

        let encrypted = AISchema.CompactionPart.make(provider: "anthropic", id: "cmp_1", encrypted: "cipher")
        let roundTripped = try AICoreTestHelper.roundTrip(encrypted)
        #expect(roundTripped == encrypted)

        let nullSummary = AISchema.CompactionPart.make(provider: "openai", text: nil)
        let roundTrippedNull = try AICoreTestHelper.roundTrip(nullSummary)
        #expect(roundTrippedNull == nullSummary)

        // Reject invalid CompactionPart having both encrypted and text
        let bothInvalid = #"{"type":"compaction","provider":"anthropic","encrypted":"x","text":"y"}"#
        #expect(throws: Error.self) {
            _ = try AICoreTestHelper.decodeJSON(AISchema.CompactionPart.self, from: bothInvalid)
        }

        // freeformField checks single required string property
        let validFreeform: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object(["patch": .object(["type": .string("string")])]),
            "required": .array([.string("patch")]),
        ]
        #expect(AISchema.ToolDefinition.freeformField(validFreeform) == "patch")

        let invalidFreeform: AISchema.JsonSchema = [
            "type": .string("object"),
            "properties": .object(["count": .object(["type": .string("number")])]),
            "required": .array([.string("count")]),
        ]
        #expect(AISchema.ToolDefinition.freeformField(invalidFreeform) == nil)

        #expect(AISchema.ToolChoice.make(.string("auto")).type == .auto)
        #expect(AISchema.ToolChoice.make(.string("required")).type == .required)
        let customChoice = AISchema.ToolChoice.make(.string("search"))
        #expect(customChoice.type == .tool)
        #expect(customChoice.name == "search")
    }

    @Test("ResponseFold accumulates deltas, honors authoritative end replacement, skips raw, and builds partial")
    func responseFoldLifecycle() {
        let events: [AISchema.LLMEvent] = [
            .stepStart(AISchema.StepStart(index: 0)),
            .raw(AISchema.RawEvent(data: .object(["frame": .int(1)]))),
            .reasoningStart(AISchema.ReasoningStart(id: "r1")),
            .reasoningDelta(AISchema.ReasoningDelta(id: "r1", text: "draft")),
            .reasoningEnd(AISchema.ReasoningEnd(id: "r1", text: "final thought")),
            .textStart(AISchema.TextStart(id: "t1")),
            .textDelta(AISchema.TextDelta(id: "t1", text: "Hello ")),
            .textDelta(AISchema.TextDelta(id: "t1", text: "world")),
            .textEnd(AISchema.TextEnd(id: "t1")),
            .toolInputStart(AISchema.ToolInputStart(id: "tc1", name: "lookup")),
            .toolInputDelta(AISchema.ToolInputDelta(id: "tc1", name: "lookup", text: #"{"q":"swift"}"#)),
            .toolInputEnd(AISchema.ToolInputEnd(id: "tc1", name: "lookup")),
            .toolCall(AISchema.ToolCall(id: "tc1", name: "lookup", input: .object(["q": .string("swift")]))),
            .stepFinish(AISchema.StepFinish(
                index: 0,
                reason: AISchema.FinishReasonDetails(normalized: .toolCalls),
                usage: AISchema.Usage(inputTokens: 12, outputTokens: 8)
            )),
            .finish(AISchema.Finish(reason: AISchema.FinishReasonDetails(normalized: .toolCalls))),
        ]

        let response = AISchema.LLMResponse.fromEvents(events)
        #expect(response != nil)
        #expect(response?.text == "Hello world")
        #expect(response?.reasoning == "final thought")
        #expect(response?.toolCalls.count == 1)
        #expect(response?.toolCalls[0].name == "lookup")
        #expect(response?.usage?.inputTokens == 12)
        #expect(response?.events.contains(where: \.isRaw) == false)
        #expect(response?.message.content.count == 3)

        // Partial output: only step-start yields nil; partial text yields error-finished response.
        var state = AISchema.ResponseFold.empty()
        state = AISchema.ResponseFold.reduce(state, .stepStart(AISchema.StepStart(index: 0)))
        #expect(AISchema.ResponseFold.partial(state) == nil)
        state = AISchema.ResponseFold.reduce(state, .textDelta(AISchema.TextDelta(id: "t1", text: "partial")))
        let partial = AISchema.ResponseFold.partial(state)
        #expect(partial?.text == "partial")
        #expect(partial?.finishReason.normalized == .error)
    }
}

// MARK: - SSE & NDJSON Streaming Framing Tests

@Suite("OpenCodeAI SSE & NDJSON Framing Tests")
struct AIFramingTests {
    @Test("SSE parser handles 1-byte chunks, UTF-8 multibyte splits, BOM, CRLF splits, comments, and multiline data")
    func sseIncrementalParser() async throws {
        // UTF-8 BOM + comment + CRLF + multi-line data + emoji (4-byte UTF-8) + keepalive + null + [DONE]
        let payload = "\u{FEFF}: proxy comment\r\nevent: message\r\ndata: {\"text\":\"hi \"}\r\n\r\n"
            + "data: line1\ndata: rocket 🚀\n\n"
            + "data: null\n\n"
            + "data: : keepalive\n\n"
            + "data: [DONE]\n\n"

        // Feed 1 byte at a time to stress both UTF-8 boundary reassembly and \r|\n splits!
        let oneByteChunks = Array(payload.utf8).map { [$0] }
        let stream = AIFraming.sse.frame(AICoreTestHelper.makeByteStream(oneByteChunks))

        var frames: [String] = []
        for try await frame in stream {
            frames.append(frame)
        }
        #expect(frames == [#"{"text":"hi "}"#, "line1\nrocket 🚀"])

        // sseWithDone retains [DONE]
        let streamWithDone = AIFraming.sseWithDone.frame(AICoreTestHelper.makeByteStream(oneByteChunks))
        var framesWithDone: [String] = []
        for try await frame in streamWithDone {
            framesWithDone.append(frame)
        }
        #expect(framesWithDone == [#"{"text":"hi "}"#, "line1\nrocket 🚀", "[DONE]"])
    }

    @Test("sseEvents filters named SSE events and keeps [DONE] for non-message event names")
    func sseEventFiltering() async throws {
        let payload =
            "event: ping\ndata: ignored\n\n"
            + "event: content_block_delta\ndata: {\"delta\":\"hello\"}\n\n"
            + "event: custom_end\ndata: [DONE]\n\n"
        let stream = AIFraming.sseEvents(["content_block_delta", "custom_end"]).frame(
            AICoreTestHelper.makeByteStream([Array(payload.utf8)])
        )
        var frames: [String] = []
        for try await frame in stream {
            frames.append(frame)
        }
        #expect(frames == [#"{"delta":"hello"}"#, "[DONE]"])
    }

    @Test("NDJSON line decoder splits arbitrary chunk boundaries and skips blank lines")
    func ndjsonLineFraming() async throws {
        let raw = "{\"a\":1}\r\n\r\n   \n{\"emoji\":\"🎉\"}\n{\"tail\":true}"
        // Split across arbitrary 3-byte chunks (splits 4-byte emoji and CRLF!)
        let allBytes = Array(raw.utf8)
        var chunks: [[UInt8]] = []
        var i = 0
        while i < allBytes.count {
            let end = min(i + 3, allBytes.count)
            chunks.append(Array(allBytes[i..<end]))
            i = end
        }
        var lines: [String] = []
        for try await line in AIFraming.lines.frame(AICoreTestHelper.makeByteStream(chunks)) {
            lines.append(line)
        }
        #expect(lines == [#"{"a":1}"#, #"{"emoji":"🎉"}"#, #"{"tail":true}"#])

        // Document framing joins everything into a single string frame
        var docs: [String] = []
        for try await doc in AIFraming.document.frame(AICoreTestHelper.makeByteStream(chunks)) {
            docs.append(doc)
        }
        #expect(docs == [raw])
    }
}

// MARK: - Auth, Endpoint, Executor, Transport & Route Tests

@Suite("OpenCodeAI Auth, Executor & Route Tests")
struct AIRouteAndTransportTests {
    @Test("AIAuth resolves credentials with fallback, bearer/header/scheme, and wraps missing into AuthenticationError")
    func authResolution() async throws {
        let env = DictionaryEnvironment(variables: ["TEST_API_KEY": "env-secret-123"])
        let authDef = AIAuthOptions.bearer(.apiKey(nil), envVars: ["MISSING_KEY", "TEST_API_KEY"], environment: env)
        let signed = try await AIAuth.toEffect(authDef)(AIAuth.AuthInput(
            method: .POST,
            url: "https://api.example.test/v1/chat",
            body: "{}",
            headers: ["x-custom": "yes"]
        ))
        #expect(signed["authorization"] == "Bearer env-secret-123")
        #expect(signed["x-custom"] == "yes")

        // Disabled API key skips env lookup and adds no auth header
        let disabledDef = AIAuthOptions.bearer(.apiKey(.disabled), envVar: "TEST_API_KEY", environment: env)
        let unsigned = try await AIAuth.toEffect(disabledDef)(AIAuth.AuthInput(
            method: .GET,
            url: "https://api.example.test",
            body: "",
            headers: [:]
        ))
        #expect(unsigned["authorization"] == nil)

        // Missing credential becomes AIError.authentication
        let missingDef = AIAuth.scheme("Token", AIAuth.config("NONEXISTENT_VAR", environment: env))
        do {
            _ = try await AIAuth.toEffect(missingDef)(AIAuth.AuthInput(method: .GET, url: "https://x", body: "", headers: [:]))
            Issue.record("Expected missing credential to throw AuthenticationError")
        } catch let err as AISchema.AIError {
            if case .authentication(let authErr) = err.reason {
                #expect(authErr.message.contains("NONEXISTENT_VAR"))
            } else {
                Issue.record("Expected authentication reason, got \(err.reason)")
            }
        }
    }

    @Test("AIRequestExecutor composes middleware in outer->inner order and classifies 429 rate-limit headers")
    func requestExecutorMiddlewareAndRateLimit() async throws {
        let log = Mutex<[String]>([])
        let transport = AICoreTestHelper.MockHTTPTransport(replies: [
            AICoreTestHelper.MockHTTPTransport.ScriptedReply(
                status: 429,
                headers: [
                    "Retry-After": "12",
                    "x-ratelimit-limit-requests": "100",
                    "x-ratelimit-remaining-requests": "0",
                    "anthropic-ratelimit-tokens-reset": "2026-01-01T00:00:00Z",
                ],
                body: #"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#
            )
        ])

        let baseExecutor = AIRequestExecutor.layer(transport: transport)
        let wrappedExecutor = AIRequestExecutor.middleware({ req, next in
            log.withLock { $0.append("outer:before") }
            var modified = req
            var headers = modified.headers
            headers["x-outer"] = "1"
            modified = HTTPRequest(method: req.method, url: req.url, headers: headers, body: req.body)
            let resp = try await next(modified)
            log.withLock { $0.append("outer:after") }
            return resp
        }, executor: baseExecutor)

        do {
            _ = try await AIRequestExecutor.withMiddleware({ req, next in
                log.withLock { $0.append("scoped:before") }
                let resp = try await next(req)
                log.withLock { $0.append("scoped:after") }
                return resp
            }) {
                try await wrappedExecutor.execute(HTTPRequest(method: "POST", url: "https://api.test/v1/messages"))
            }
            Issue.record("Expected 429 to throw AIError")
        } catch let err as AISchema.AIError {
            #expect(err.status == 429)
            #expect(err.isRetryable == true)
            #expect(err.retryAfterMs == 12_000)
            if case .rateLimit(let rl) = err.reason {
                #expect(rl.message == "Rate limit reached")
                #expect(rl.rateLimit?.limit?["requests"] == "100")
                #expect(rl.rateLimit?.remaining?["requests"] == "0")
                #expect(rl.rateLimit?.reset?["tokens"] == "2026-01-01T00:00:00Z")
            } else {
                Issue.record("Expected rateLimit error reason, got \(err.reason)")
            }
        }

        #expect(log.withLock { $0 } == ["outer:before", "scoped:before", "scoped:after", "outer:after"])
        #expect(transport.recordedRequests.first?.headers["x-outer"] == "1")

        // Verify IMF-fixdate Retry-After parsing
        let imf = AIRequestExecutor.parseRetryAfterMs(
            headers: ["retry-after": "Wed, 21 Oct 2015 07:28:10 GMT"],
            nowEpochMs: 1_445_412_480_000 // Wed, 21 Oct 2015 07:28:00 GMT
        )
        #expect(imf == 10_000)
    }

    @Test("End-to-end AIRoute.make over SSE HTTPTransport decodes events, emits raw frames, and rejects file: URLs")
    func endToEndRouteExecution() async throws {
        struct SimpleEvent: Decodable, Sendable {
            let delta: String?
            let done: Bool?
        }

        let wireProtocol = AIRoute.makeProtocol(AIRoute.WireProtocol<[String: JSONValue], String, SimpleEvent, Int>(
            id: "test-sse-proto",
            body: AIRoute.ProtocolBody(
                encode: { try AIUtils.encodeJson(.object($0)) },
                from: { req in ["model": .string(req.model.id.rawValue)] }
            ),
            stream: AIRoute.ProtocolStream(
                decodeEvent: AIRoute.jsonEvent(SimpleEvent.self),
                initial: { _ in 0 },
                step: { count, ev in
                    if ev.done == true {
                        return (count, [
                            .textEnd(AISchema.TextEnd(id: "t0")),
                            .finish(AISchema.Finish(reason: AISchema.FinishReasonDetails(normalized: .stop))),
                        ])
                    }
                    var emitted: [AISchema.LLMEvent] = []
                    if count == 0 { emitted.append(.textStart(AISchema.TextStart(id: "t0"))) }
                    if let d = ev.delta { emitted.append(.textDelta(AISchema.TextDelta(id: "t0", text: d))) }
                    return (count + 1, emitted)
                }
            )
        ))

        let route = AIRoute.make(AIRoute.MakeInput(
            id: "test-route",
            provider: "mock",
            wireProtocol: wireProtocol,
            endpoint: AIEndpoint.path("/v1/stream", baseURL: "https://mock.test/"),
            auth: AIAuth.bearer("secret-key"),
            framing: AIFraming.sse
        ))
        let model = try route.model(AIRoute.RouteLanguageModelInput(id: "mock-1"))

        let sseBody = "data: {\"delta\":\"Hello \"}\n\ndata: {\"delta\":\"Swift!\"}\n\ndata: {\"done\":true}\n\ndata: [DONE]\n\n"
        let transport = AICoreTestHelper.MockHTTPTransport(replies: [
            AICoreTestHelper.MockHTTPTransport.ScriptedReply(status: 200, headers: ["content-type": "text/event-stream"], body: sseBody)
        ])
        let client = AIRoute.LLMClient.layer(executor: AIRequestExecutor.layer(transport: transport))

        let req = try AILLM.request(AILLM.LLMRequestInput(
            model: model,
            input: .promptText("Say hi"),
            includeRaw: true
        ))
        let response = try await client.generate(req)
        #expect(response.text == "Hello Swift!")
        #expect(response.finishReason.normalized == .stop)
        #expect(transport.recordedRequests.first?.url == "https://mock.test/v1/stream")
        #expect(transport.recordedRequests.first?.headers["authorization"] == "Bearer secret-key")

        // Rejects local file: references before sending
        let fileReq = try AILLM.request(AILLM.LLMRequestInput(
            model: model,
            input: .messages([
                .message(.user(AISchema.UserMessage(content: [
                    .media(AISchema.MediaPart(media: AIMedia.url("file:///etc/passwd", mediaType: "text/plain")))
                ])))
            ])
        ))
        do {
            _ = try await client.generate(fileReq)
            Issue.record("Expected file: URL to fail with InvalidRequest")
        } catch let err as AISchema.AIError {
            if case .invalidRequest(let r) = err.reason {
                #expect(r.message.contains("Media.file"))
            } else {
                Issue.record("Expected invalidRequest, got \(err.reason)")
            }
        }
    }

    @Test("WebSocket URL conversion and direct channel execution")
    func websocketTransportHelpers() async throws {
        #expect(try AITransport.toWebSocketUrl("https://api.openai.com/v1/responses") == "wss://api.openai.com/v1/responses")
        #expect(try AITransport.toWebSocketUrl("http://localhost:8080/ws") == "ws://localhost:8080/ws")
        #expect(throws: AISchema.AIError.self) {
            _ = try AITransport.toWebSocketUrl("ftp://invalid.test")
        }

        let sent = Mutex<[String]>([])
        let connector = AITransport.WebSocketConnector { _ in
            AITransport.WebSocketConnection(
                sendText: { msg in sent.withLock { $0.append(msg) } },
                messages: AsyncThrowingStream { cont in
                    cont.yield(.text(#"{"seq":1}"#))
                    cont.yield(.binary(Array(#"{"seq":2,"done":true}"#.utf8)))
                    cont.finish()
                },
                close: {}
            )
        }
        let executor = AITransport.makeDirect(connector)
        let execution = try await executor.execute(AITransport.WebSocketChannelExchange(
            id: "ws-1",
            connect: AITransport.WebSocketChannelExchange.Connect(url: "wss://mock.test/ws"),
            fallback: { AsyncThrowingStream { $0.finish() } },
            driver: AITransport.WebSocketChannelDriver(
                create: { _ in AITransport.ChannelCreate(message: #"{"type":"start"}"#, mode: .full) },
                observe: { _, frame in
                    frame.contains("\"done\":true")
                        ? .completed(frame: frame, checkpoint: AITransport.ChannelCheckpoint(protocolID: "ws", value: .int(2)))
                        : .frame(frame)
                }
            )
        ))
        var frames: [String] = []
        for try await f in execution.frames { frames.append(f) }
        #expect(frames == [#"{"seq":1}"#, #"{"seq":2,"done":true}"#])
        #expect(sent.withLock { $0 } == [#"{"type":"start"}"#])
    }
}

// MARK: - Provider Error Classification & Utils Tests

@Suite("OpenCodeAI Error Classifier & Utils Tests")
struct AIErrorClassifierAndUtilsTests {
    @Test("Provider error classifier accurately classifies overflow, exclusions, policy, quota, auth, rate-limit, and server errors")
    func providerErrorClassification() {
        // Context overflow
        let overflow = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "prompt is too long: 210000 tokens > 200000 maximum",
            status: 400
        ))
        if case .invalidRequest(let e) = overflow {
            #expect(e.classification == .contextOverflow)
        } else {
            Issue.record("Expected contextOverflow, got \(overflow)")
        }
        #expect(AIErrorClassifier.isContextOverflowFailure(AISchema.AIError(reason: overflow)) == true)

        // Bedrock throttling phrasing must NOT be classified as context overflow
        #expect(AIErrorClassifier.isContextOverflow("Too many tokens, please wait before trying again") == false)
        #expect(AIErrorClassifier.isContextOverflow("max_tokens must be less than 4096") == false)

        // 429 Cerebras token_quota_exceeded stays RateLimit, NOT QuotaExceeded!
        let cerebrasThrottle = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "token_quota_exceeded: too many tokens processed",
            status: 429
        ))
        if case .rateLimit = cerebrasThrottle {} else {
            Issue.record("Expected rateLimit for Cerebras token_quota_exceeded, got \(cerebrasThrottle)")
        }

        // 429 insufficient_quota becomes QuotaExceeded
        let quota = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "You exceeded your current quota",
            status: 429,
            rawBody: #"{"error":{"code":"insufficient_quota"}}"#
        ))
        if case .quotaExceeded = quota {} else {
            Issue.record("Expected quotaExceeded, got \(quota)")
        }

        // Azure content policy innererror
        let policy = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "Blocked",
            status: 400,
            rawBody: #"{"error":{"code":"content_filter","innererror":{"code":"ResponsibleAIPolicyViolation"}}}"#
        ))
        if case .contentPolicy = policy {} else {
            Issue.record("Expected contentPolicy, got \(policy)")
        }

        // Google 400 API_KEY_INVALID becomes AuthenticationError
        let googleAuth = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "API key not valid",
            status: 400,
            rawBody: #"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#
        ))
        if case .authentication = googleAuth {} else {
            Issue.record("Expected authentication, got \(googleAuth)")
        }

        // 503 becomes ProviderInternalError
        let internalErr = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "Service unavailable",
            status: 503
        ))
        if case .providerInternal = internalErr {} else {
            Issue.record("Expected providerInternal, got \(internalErr)")
        }

        // Gateway rewriting a 400 with `server_error` code stays InvalidRequest
        let gateway400 = AIErrorClassifier.classifyProviderFailure(AIErrorClassifier.ProviderFailure(
            message: "Bad parameter",
            status: 400,
            rawBody: #"{"error":{"code":"server_error"}}"#
        ))
        if case .invalidRequest = gateway400 {} else {
            Issue.record("Expected invalidRequest for 400 with server_error, got \(gateway400)")
        }

        // providerErrorMessage layouts
        #expect(AIErrorClassifier.providerErrorMessage(#"{"error":{"message":"OpenAI err"}}"#) == "OpenAI err")
        #expect(AIErrorClassifier.providerErrorMessage(#"{"Message":"AWS err"}"#) == "AWS err")
        #expect(AIErrorClassifier.providerErrorMessage(#"{"detail":"Problem detail"}"#) == "Problem detail")
        #expect(AIErrorClassifier.providerErrorMessage(#"{"errors":[{"message":"First err"}]}"#) == "First err")
    }

    @Test("Media magic-byte detection, extension lookup, and lone UTF-16 surrogate sanitization")
    func utilsMediaTypeAndSanitize() {
        #expect(AIUtils.detectMediaType([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == "image/png")
        #expect(AIUtils.detectMediaType([0xFF, 0xD8, 0xFF, 0xE0]) == "image/jpeg")
        #expect(AIUtils.detectMediaType([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) == "image/gif")
        #expect(AIUtils.detectMediaType(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)) == "image/webp")
        #expect(AIUtils.detectMediaType(Array("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)) == "audio/wav")
        #expect(AIUtils.detectMediaType(Array("%PDF-1.7".utf8)) == "application/pdf")
        #expect(AIUtils.detectMediaType([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66]) == "image/avif")
        #expect(AIUtils.detectMediaType([0x4F, 0x67, 0x67, 0x53]) == "audio/ogg")
        #expect(AIUtils.detectMediaType([0x66, 0x4C, 0x61, 0x43]) == "audio/flac")
        #expect(AIUtils.fileMediaType([0x01, 0x02], path: "notes.md") == "text/markdown")
        #expect(AIUtils.mediaTypeExtension("audio/x-wav; charset=binary") == "wav")
        #expect(AIUtils.mediaTypeExtension("image/png") == "png")

        // Valid surrogate pair (😀 = D83D DE00) preserved; lone high (D800) and lone low (DC00) replaced with U+FFFD
        let units: [UInt16] = [0x0041, 0xD800, 0xD83D, 0xDE00, 0xDC00, 0x0042]
        #expect(AIUtils.sanitizeSurrogates(units) == "A\u{FFFD}😀\u{FFFD}B")
    }
}

// MARK: - Cache Policy, Effort Updates, Tool History & Tool Updates Tests

@Suite("OpenCodeAI Cache Policy & Reducers Tests")
struct AICacheAndReducersTests {
    @Test("CachePolicy auto places up to 4 breakpoints across tools, first/last system, and tail message skipping markers")
    func cachePolicyAutoAndBudget() {
        let model = AICoreTestHelper.makeTestModel(routeID: "anthropic-messages")
        let t1 = AISchema.ToolEntry.tool(AISchema.ToolDefinition(name: "t1", description: "d1", inputSchema: [:]))
        let t2 = AISchema.ToolEntry.tool(AISchema.ToolDefinition(name: "t2", description: "d2", inputSchema: [:]))
        let req = AISchema.LLMRequest(
            model: model,
            system: [
                AISchema.SystemPart.make("base"),
                AISchema.SystemPart.make("middle"),
                AISchema.SystemPart.make("project"),
            ],
            messages: [
                AISchema.Message.user("hello"),
                AISchema.Message.assistant("hi"),
                AISchema.Message.effort(effort: .high, previous: .medium),
            ],
            tools: [t1, t2],
            cache: .object(AISchema.CachePolicyObject(ttl: AISchema.CacheTTL(rawValue: "1h")))
        )

        #expect(AICachePolicy.placesMarkers(req) == true)
        #expect(AICachePolicy.requestTTL(req)?.rawValue == "1h")

        let applied = AICachePolicy.applyCachePolicy(req)
        // Last tool gets hint (slot 1)
        if case .tool(let d1) = applied.tools[0], case .tool(let d2) = applied.tools[1] {
            #expect(d1.cache == nil)
            #expect(d2.cache?.ttl?.rawValue == "1h")
        } else {
            Issue.record("Expected tool entries")
        }
        // First and last system parts get hints (slots 2 & 3), middle stays nil
        #expect(applied.system[0].cache?.type == .ephemeral)
        #expect(applied.system[1].cache == nil)
        #expect(applied.system[2].cache?.type == .ephemeral)
        // Tail message skips trailing effort marker and marks assistant message (slot 4)
        #expect(applied.messages[1].contentParts.last?.cache?.type == .ephemeral)
        #expect(applied.messages[2].contentParts.last?.cache == nil)

        // OpenAI responses ignores inline markers
        let openaiModel = AICoreTestHelper.makeTestModel(id: "gpt-5", provider: "openai", routeID: "openai-responses")
        let openaiReq = AISchema.LLMRequest(model: openaiModel, messages: [AISchema.Message.user("hi")])
        #expect(AICachePolicy.placesMarkers(openaiReq) == false)

        // OpenRouter Qwen uses Qwen policy (skips tools, marks system & tail)
        let qwenModel = AICoreTestHelper.makeTestModel(id: "qwen/qwen3-coder", provider: "openrouter", routeID: "openrouter")
        let qwenReq = AISchema.LLMRequest(model: qwenModel, system: [AISchema.SystemPart.make("sys")], messages: [AISchema.Message.user("hi")], tools: [t1])
        let qwenApplied = AICachePolicy.applyCachePolicy(qwenReq)
        if case .tool(let d) = qwenApplied.tools[0] { #expect(d.cache == nil) }
        #expect(qwenApplied.system[0].cache != nil)
        #expect(qwenApplied.messages[0].contentParts.last?.cache != nil)
    }

    @Test("Effort update reducers keep, strip, and resolve mismatched effort histories")
    func effortUpdateReducers() {
        let supportedModel = AICoreTestHelper.makeTestModel(supportsEffortUpdates: { _ in true })
        let unsupportedModel = AICoreTestHelper.makeTestModel(supportsEffortUpdates: { _ in false })

        let msgs: [AISchema.Message] = [
            AISchema.Message.user("step 1"),
            AISchema.Message.effort(effort: .high, previous: .low),
            AISchema.Message.user("step 2"),
        ]
        let reqSupported = AISchema.LLMRequest(model: supportedModel, messages: msgs)
        #expect(AIEffortUpdates.applyEffortUpdates(reqSupported).messages.count == 3)

        let reqUnsupported = AISchema.LLMRequest(model: unsupportedModel, messages: msgs)
        #expect(AIEffortUpdates.applyEffortUpdates(reqUnsupported).messages.count == 2)

        // Matching current effort returns initial previous effort
        let matched = AIEffortUpdates.resolveEffortUpdates(reqSupported, current: .high)
        #expect(matched.effort == .low)
        #expect(matched.request.messages.count == 3)

        // Mismatched current effort strips effort markers and keeps current
        let mismatched = AIEffortUpdates.resolveEffortUpdates(reqSupported, current: .medium)
        #expect(mismatched.effort == .medium)
        #expect(mismatched.request.messages.count == 2)
    }

    @Test("AIToolHistory synthesizes missing results, holds system messages across tool calls, and fixes empty results")
    func toolHistoryNormalization() {
        let messages: [AISchema.Message] = [
            AISchema.Message.user("run tools"),
            .assistant(AISchema.AssistantMessage(content: [
                .toolCall(AISchema.ToolCallPart.make(id: "c1", name: "read", input: .object([:]))),
                .toolCall(AISchema.ToolCallPart.make(id: "c2", name: "grep", input: .object([:]))),
            ])),
            // Mid-tool-call system update should be held until tool calls settle
            AISchema.Message.system("policy update"),
            // Only c1 answered, with empty text & wrong name
            .tool(AISchema.ToolMessage(content: [
                AISchema.ToolResultPart.make(id: "c1", name: "wrong_name", result: .text(.string("")))
            ])),
            AISchema.Message.user("next turn"),
        ]

        let normalized = AIToolHistory.normalizeToolHistory(messages)
        // Expected order: user -> assistant -> tool(c1 normalized) -> tool(c2 missing error) -> held system -> user
        #expect(normalized.count == 6)
        if case .tool(let t1) = normalized[2] {
            #expect(t1.content[0].name == "read")
            #expect(t1.content[0].result == .text(.string("(no tool output)")))
        } else {
            Issue.record("Expected normalized tool message at index 2")
        }
        if case .tool(let missing) = normalized[3] {
            #expect(missing.content[0].id == "c2")
            #expect(missing.content[0].result == .error(.string("Tool result missing")))
        } else {
            Issue.record("Expected synthesized missing tool result at index 3")
        }
        #expect(normalized[4].role == .system)
        #expect(normalized[5].role == .user)
    }

    @Test("AIToolUpdates plans native mid-conversation updates and folds unsupported ones into top-level tools")
    func toolUpdatesPlanningAndFolding() {
        let tA = AISchema.ToolEntry.tool(AISchema.ToolDefinition(name: "a", description: "A", inputSchema: [:]))
        let tB = AISchema.ToolEntry.tool(AISchema.ToolDefinition(name: "b", description: "B", inputSchema: [:]))
        let tC = AISchema.ToolEntry.tool(AISchema.ToolDefinition(name: "c", description: "C", inputSchema: [:]))

        let caps = AISchema.Capabilities(tools: AISchema.Capabilities.Tools(updates: [.add, .remove]))
        let model = AICoreTestHelper.makeTestModel(
            capabilities: caps,
            toolUpdates: AIToolUpdates.ToolUpdateEncoding(kinds: [.add, .remove])
        )

        let req = AISchema.LLMRequest(
            model: model,
            messages: [
                // Before first non-system turn -> must fold into top-level tools
                .system(AISchema.SystemMessage(content: [], tools: AISchema.ToolChanges(add: [tB]))),
                AISchema.Message.user("hello"),
                // After first turn -> supported add + remove stays in place!
                .system(AISchema.SystemMessage(content: [], tools: AISchema.ToolChanges(add: [tC], remove: ["a"]))),
            ],
            tools: [tA]
        )

        #expect(AIToolUpdates.addsTools(req) == true)
        let planned = AIToolUpdates.planToolUpdates(req)
        #expect(planned.tools.map(\.name) == ["a", "b"])
        #expect(planned.messages.count == 2)
        if case .system(let sys) = planned.messages[1] {
            #expect(sys.tools?.add.map(\.name) == ["c"])
            #expect(sys.tools?.remove == ["a"])
        } else {
            Issue.record("Expected native tool update marker preserved after first turn")
        }

        // foldToolUpdates folds everything into top-level tools
        let folded = AIToolUpdates.foldToolUpdates(req)
        #expect(folded.tools.map(\.name) == ["b", "c"])
        #expect(folded.messages.count == 1)
    }
}

// MARK: - Tool Runtime & Multi-Step Agent Loop Tests

@Suite("OpenCodeAI Tool Runtime & Agent Loop Tests")
struct AIToolAndLoopTests {
    @Test("AITool.dispatch handles success, ToolFailure, unknown tool, and concurrent runTools order preservation")
    func toolDispatchAndConcurrency() async throws {
        let addTool = try AITool.tool(AITool.ToolOptions(
            name: "add",
            description: "Add two numbers",
            input: .jsonSchema(["type": .string("object")]),
            execute: { input, _ in
                guard case .object(let obj) = input,
                      case .int(let a) = obj["a"],
                      case .int(let b) = obj["b"]
                else {
                    throw AISchema.ToolFailure(message: "Expected integer fields a and b")
                }
                return .object(["sum": .int(a + b)])
            }
        ))

        let echoTool = try AITool.tool(AITool.ToolOptions(
            name: "echo",
            description: "Echo string",
            execute: { input, _ in
                if case .object(let obj) = input, case .string(let s) = obj["text"] {
                    return .string("echo:\(s)")
                }
                return .string("")
            }
        ))

        let calls = [
            AITool.PendingCall(call: AISchema.ToolCallPart.make(id: "1", name: "add", input: .object(["a": .int(3), "b": .int(4)]))),
            AITool.PendingCall(call: AISchema.ToolCallPart.make(id: "2", name: "add", input: .object([:]))),
            AITool.PendingCall(call: AISchema.ToolCallPart.make(id: "3", name: "missing", input: .object([:]))),
            AITool.PendingCall(call: AISchema.ToolCallPart.make(id: "4", name: "echo", input: .object(["text": .string("hi")]))),
        ]

        let results = try await AITool.runTools([addTool, echoTool], calls: calls)
        #expect(results.count == 4)
        #expect(results[0].result == .json(.object(["sum": .int(7)])))
        #expect(results[1].result == .error(.string("Expected integer fields a and b")))
        if case .error(.string(let msg)) = results[2].result {
            #expect(msg.contains("No tool named \"missing\""))
        } else {
            Issue.record("Expected unknown tool error")
        }
        #expect(results[3].result == .text(.string("echo:hi")))
    }

    @Test("Multi-step AILLM.loop executes tools against mock TestLLM, sums usage, relaxes forced toolChoice, and collects steps")
    func multiStepToolLoopExecution() async throws {
        let mock = AITesting.testLayer()
        let model = AICoreTestHelper.makeTestModel()

        let weatherTool = try AITool.tool(AITool.ToolOptions(
            name: "get_weather",
            description: "Look up weather",
            execute: { input, _ in
                guard case .object(let obj) = input, case .string(let city) = obj["city"] else {
                    throw AISchema.ToolFailure(message: "Missing city")
                }
                return .object(["city": .string(city), "tempC": .int(21)])
            }
        ))

        // Step 0: model calls get_weather + emits a malformed tool-input-error
        await mock.push(
            .events(AITesting.complete(
                reason: AISchema.FinishReasonDetails(normalized: .toolCalls),
                usage: AISchema.Usage(contextTokens: 50, inputTokens: 50, outputTokens: 20, totalTokens: 70),
                events: [
                    .toolCall(AISchema.ToolCall(id: "call_1", name: "get_weather", input: .object(["city": .string("Tokyo")]))),
                    .toolInputError(AISchema.ToolInputError(id: "call_bad", name: "get_weather", raw: "{bad json")),
                ]
            )),
            // Step 1: model responds with final text
            .events(AITesting.complete(
                reason: AISchema.FinishReasonDetails(normalized: .stop),
                usage: AISchema.Usage(contextTokens: 120, inputTokens: 120, outputTokens: 30, totalTokens: 150),
                events: [
                    .textStart(AISchema.TextStart(id: "t1")),
                    .textDelta(AISchema.TextDelta(id: "t1", text: "It is 21°C in Tokyo.")),
                    .textEnd(AISchema.TextEnd(id: "t1")),
                ]
            ))
        )

        let stream = AILLM.loop(
            AILLM.LLMLoopInput(
                request: AILLM.LLMRequestInput(
                    model: model,
                    input: .promptText("Weather in Tokyo?"),
                    toolChoice: .string("required")
                ),
                tools: [weatherTool]
            ),
            client: mock
        )
        let collected = try await AILoop.collect(stream)

        #expect(collected.steps.count == 2)
        #expect(collected.text == "It is 21°C in Tokyo.")
        #expect(collected.finishReason.normalized == .stop)
        // Usage summed across steps, contextTokens takes latest call's value!
        #expect(collected.usage?.inputTokens == 170)
        #expect(collected.usage?.outputTokens == 50)
        #expect(collected.usage?.totalTokens == 220)
        #expect(collected.usage?.contextTokens == 120)

        // Verify mock recorded both requests and relaxed forced toolChoice on step 1
        let recorded = await mock.requests()
        #expect(recorded.count == 2)
        #expect(recorded[0].toolChoice?.type == .required)
        #expect(recorded[1].toolChoice?.type == .auto)
        // Step 1 messages include original user + assistant(with replayed call_bad) + 2 tool results
        #expect(recorded[1].messages.count == 4)
    }

    @Test("AILLM.loop with structured output schema decodes object via forced generate_object tool and respects until")
    func loopStructuredOutputAndUntil() async throws {
        let mock = AITesting.testLayer()
        let model = AICoreTestHelper.makeTestModel()

        await mock.push(.events(AITesting.toolCall(
            id: "obj_1",
            name: "generate_object",
            input: .object(["answer": .int(42), "confident": .bool(true)])
        )))

        let objResult = try await AILLM.generateObject(
            AILLM.LLMRequestInput(
                model: model,
                input: .promptText("Meaning of life?"),
                schema: .jsonSchema(["type": .string("object")])
            ),
            client: mock
        )
        #expect(objResult.object == .object(["answer": .int(42), "confident": .bool(true)]))

        // Test `until` stops after step 0 without running tools
        let invoked = Mutex<Bool>(false)
        let neverTool = try AITool.tool(AITool.ToolOptions(name: "boom", description: "Should not run") { _, _ in
            invoked.withLock { $0 = true }
            return .null
        })
        await mock.push(.events(AITesting.toolCall(id: "c1", name: "boom", input: .object([:]))))
        let stopped = try await AILoop.collect(AILLM.loop(
            AILLM.LLMLoopInput(
                request: AILLM.LLMRequestInput(model: model, input: .promptText("Stop early")),
                tools: [neverTool],
                until: { steps in steps.count >= 1 }
            ),
            client: mock
        ))
        #expect(stopped.steps.count == 1)
        #expect(invoked.withLock { $0 } == false)
    }
}

// MARK: - Media, Generation, Decision, Embedding & Experimental Tests

@Suite("OpenCodeAI Media, Modalities & Experimental Tests")
struct AIMediaAndModalitiesTests {
    @Test("AIMedia handles data URLs, magic-byte sniffing, InMemoryFileSystem read/write, and URL download caching")
    func mediaAssetLifecycle() async throws {
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]
        let pngAsset = try AIMedia.make(.bytes(pngBytes))
        #expect(pngAsset.mediaType == "image/png")
        #expect(pngAsset.kind == .image)
        #expect(pngAsset.inline()?.mime == "image/png")

        let dataUrl = try await pngAsset.dataUrl()
        let parsed = try AIMedia.fromDataUrl(dataUrl)
        #expect(try await parsed.bytes() == pngBytes)

        // ImageAsset rejects non-images
        let pdfAsset = AIMedia.bytes(Array("%PDF-1.7".utf8))
        #expect(throws: AISchema.AIError.self) {
            _ = try AIMedia.ImageAsset(validating: pdfAsset)
        }

        // Write & read back via InMemoryFileSystem
        let fs = InMemoryFileSystem()
        try await AIMedia.write(pngAsset, to: "/assets/sample.png", fileSystem: fs)
        let loaded = try await AIMedia.file("/assets/sample.png", fileSystem: fs)
        #expect(loaded.mediaType == "image/png")
        #expect(try await loaded.bytes() == pngBytes)

        // URL download caches bytes across repeated calls
        let transport = AICoreTestHelper.MockHTTPTransport(replies: [
            AICoreTestHelper.MockHTTPTransport.ScriptedReply(status: 200, chunks: [pngBytes])
        ])
        let executor = AIRequestExecutor.layer(transport: transport)
        let urlAsset = AIMedia.url("https://cdn.example.test/pic.png", mediaType: "image/png")
        let firstRead = try await urlAsset.bytes(executor: executor)
        let secondRead = try await urlAsset.bytes(executor: executor)
        #expect(firstRead == pngBytes)
        #expect(secondRead == pngBytes)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("AIGeneration polls status transitions to completion and fetches result")
    func generationPolling() async throws {
        let polls = Mutex<Int>(0)
        let route = AIGeneration.Route<String>(
            status: {
                let count = polls.withLock { c -> Int in c += 1; return c }
                if count == 1 {
                    return AIGeneration.Snapshot(id: "job_1", status: .running, progress: 0.5)
                }
                return AIGeneration.Snapshot(id: "job_1", status: .completed, progress: 1.0)
            },
            result: { "done-output" }
        )
        let gen = AIGeneration.Generation(
            route: route,
            token: .string("job_1"),
            snapshot: AIGeneration.Snapshot(id: "job_1", status: .running, progress: 0.0)
        )
        let output = try await gen.await(AIGeneration.AwaitOptions(poll: AIGeneration.Poll(intervalMs: 1, timeoutMs: 5_000)))
        #expect(output == "done-output")
        #expect(polls.withLock { $0 } == 2)
    }

    @Test("AIDecision.DecisionClient validates answers match requested questions and rejects invalid choices")
    func decisionAnswerValidation() {
        let questions: AIDecision.DecisionQuestions = [
            .predicate(AIDecision.PredicateQuestion(name: "safe", instructions: "Is it safe?")),
            .choice(AIDecision.ChoiceQuestion(
                name: "tier",
                instructions: "Pick tier",
                choices: [
                    AIDecision.ChoiceQuestion.Option(value: .string("low")),
                    AIDecision.ChoiceQuestion.Option(value: .string("high")),
                ]
            )),
            .score(AIDecision.ScoreQuestion(
                name: "quality",
                instructions: "Rate quality",
                levels: [
                    AIDecision.ScoreQuestion.Level(label: "bad"),
                    AIDecision.ScoreQuestion.Level(label: "good"),
                ]
            )),
        ]

        let validAnswers: [AIDecision.DecisionAnswer] = [
            .predicate(AIDecision.PredicateAnswer(name: "safe", probability: 0.95)),
            .choice(AIDecision.ChoiceAnswer(
                name: "tier",
                choice: .string("high"),
                probabilities: [
                    AIDecision.ChoiceAnswer.Entry(value: .string("low"), probability: 0.1),
                    AIDecision.ChoiceAnswer.Entry(value: .string("high"), probability: 0.9),
                ],
                confidence: 0.9
            )),
            .score(AIDecision.ScoreAnswer(
                name: "quality",
                score: 0.8,
                probabilities: [
                    AIDecision.ScoreAnswer.Entry(value: 0, label: "bad", probability: 0.2),
                    AIDecision.ScoreAnswer.Entry(value: 1, label: "good", probability: 0.8),
                ],
                confidence: 0.8
            )),
        ]
        #expect(AIDecision.DecisionClient.answersMatch(questions: questions, answers: validAnswers) == true)

        // Score out of bounds fails validation
        var badAnswers = validAnswers
        badAnswers[2] = .score(AIDecision.ScoreAnswer(
            name: "quality",
            score: 5.0,
            probabilities: [
                AIDecision.ScoreAnswer.Entry(value: 0, label: "bad", probability: 0.2),
                AIDecision.ScoreAnswer.Entry(value: 1, label: "good", probability: 0.8),
            ],
            confidence: 0.8
        ))
        #expect(AIDecision.DecisionClient.answersMatch(questions: questions, answers: badAnswers) == false)
    }

    @Test("EmbeddingRoute splits requests exceeding maxValues, sums token usage, and preserves vector order")
    func embeddingBatchSplitting() async throws {
        let transport = AICoreTestHelper.MockHTTPTransport { req in
            let bodyText = String(decoding: req.body ?? [], as: UTF8.self)
            let json = try AIUtils.decodeJson(bodyText)
            var vectors: [JSONValue] = []
            if case .object(let obj) = json, case .array(let inputs) = obj["input"] {
                for item in inputs {
                    if case .string(let s) = item {
                        vectors.append(.array([.double(Double(s.count))]))
                    }
                }
            }
            let reply = try AIUtils.encodeJson(.object([
                "embeddings": .array(vectors),
                "tokens": .int(Int64(vectors.count * 10)),
            ]))
            return AICoreTestHelper.MockHTTPTransport.ScriptedReply(status: 200, body: reply)
        }

        let proto = AIRoute.EmbeddingRoute.protocol(AIRoute.EmbeddingRoute.ProtocolSpec(
            id: "mock-embed",
            name: "Mock Embed",
            bodyFrom: { req in
                let strs = req.values.map { v -> JSONValue in
                    if case .text(let s) = v { return .string(s) }
                    return .string("")
                }
                return ["input": .array(strs)]
            },
            decodeResponse: { resp, ctx in
                let text = try await AIRequestExecutor.responseText(resp)
                let parsed = try AIUtils.decodeJson(text)
                guard case .object(let obj) = parsed, case .array(let arr) = obj["embeddings"] else {
                    throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(message: "Bad")))
                }
                let embeddings: [[Double]] = arr.map { row in
                    guard case .array(let nums) = row else { return [] }
                    return nums.compactMap {
                        if case .double(let d) = $0 { return d }
                        if case .int(let i) = $0 { return Double(i) }
                        return nil
                    }
                }
                let toks: Double? = if case .int(let t) = obj["tokens"] { Double(t) } else { nil }
                return AIEmbedding.EmbeddingResponse(
                    embeddings: embeddings,
                    usage: AIEmbedding.EmbeddingUsage(inputTokens: toks),
                    providerMetadata: [ctx.providerMetadataKey: ["batchSize": .int(Int64(embeddings.count))]]
                )
            }
        ))

        let route = AIRoute.EmbeddingRoute.make(AIRoute.EmbeddingRoute.MakeInput(
            id: "mock-embed",
            provider: "mock",
            protocol: proto,
            endpoint: AIEndpoint.path("/v1/embeddings", baseURL: "https://embed.test"),
            maxValues: 2
        ))
        let model = route.model(id: "embed-1")
        let client = AIEmbedding.EmbeddingClient.layer(executor: AIRequestExecutor.layer(transport: transport))

        let response = try await AIEmbedding.generate(
            AIEmbedding.EmbeddingRequestInput(
                model: model,
                values: [.text("a"), .text("bb"), .text("ccc"), .text("dddd"), .text("eeeee")]
            ),
            client: client
        )

        #expect(response.embeddings == [[1], [2], [3], [4], [5]])
        #expect(response.usage?.inputTokens == 50)
        #expect(transport.recordedRequests.count == 3)
        if case .array(let batchMeta) = response.providerMetadata?["mock"]?["responses"] {
            #expect(batchMeta.count == 3)
        } else {
            Issue.record("Expected chunked providerMetadata responses array")
        }
    }

    @Test("Experimental Realtime engine matching/connect and CloudflareRunExtraction p_null decoding")
    func experimentalRealtimeAndExtraction() async throws {
        #expect(AIExperimental.Realtime.engine("gpt-realtime-2.1")?.id == "openai-realtime")
        #expect(AIExperimental.Realtime.engine("grok-voice-3.0")?.provider == "xai")
        #expect(AIExperimental.Realtime.engine("gemini-3.8-live")?.id == "gemini-live")
        #expect(AIExperimental.Realtime.engine("unknown-voice") == nil)

        let transport = AICoreTestHelper.MockHTTPTransport(replies: [
            // 1. xAI realtime client_secrets
            AICoreTestHelper.MockHTTPTransport.ScriptedReply(status: 200, body: #"{"value":"ephemeral_tok","expires_at":1790000000}"#),
            // 2. Cloudflare Run extraction response
            AICoreTestHelper.MockHTTPTransport.ScriptedReply(status: 200, body: """
            {
              "result": {
                "model": "@cf/clairic",
                "answers": {
                  "vendor": { "value": "Acme", "p_null": 0.05, "confidence": 0.95, "span": [0, 4] }
                },
                "usage": { "input_tokens": 12, "output_tokens": 4 }
              }
            }
            """),
        ])
        let executor = AIRequestExecutor.layer(transport: transport)

        let ws = try await AIExperimental.Realtime.connect(
            AIExperimental.RealtimeConnectInput(
                model: "grok-voice-3.0",
                apiKey: AIAuth.RedactedSecret("xai-key"),
                transport: .websocket
            ),
            executor: executor
        )
        #expect(ws == .websocket(url: "wss://api.x.ai/v1/realtime?model=grok-voice-3.0", token: "ephemeral_tok", expiresAt: 1_790_000_000))

        let cfModel = AIExperimental.CloudflareRunExtraction.model(AIRoute.MediaRoute.ModelInput(
            id: "@cf/clairic",
            auth: AIAuth.bearer("cf-tok"),
            baseURL: "https://api.cloudflare.com/client/v4/accounts/acct/ai/run"
        ))
        let extracted = try await AIExperimental.Extraction.generate(
            AIExperimental.ExtractionRequest(
                model: cfModel,
                input: "Acme invoice #42",
                fields: ["vendor": AIExperimental.ExtractionField(type: "text", nullThreshold: 0.4)]
            ),
            executor: executor
        )
        #expect(extracted.answers["vendor"]?["value"] == .string("Acme"))
        #expect(extracted.answers["vendor"]?["nullProbability"] == .double(0.05))
        #expect(extracted.usage?.totalTokens == 16)
    }

    @Test("AIVideo.VideoDuration parses valid second strings and rejects malformed values")
    func videoDurationParsing() {
        #expect(AIVideo.VideoDuration(rawValue: "8 seconds").map(AIVideo.seconds) == 8.0)
        #expect(AIVideo.VideoDuration(rawValue: "1 second").map(AIVideo.seconds) == 1.0)
        #expect(AIVideo.VideoDuration(rawValue: "4.5 seconds").map(AIVideo.seconds) == 4.5)
        #expect(AIVideo.VideoDuration(rawValue: "8s") == nil)
        #expect(AIVideo.VideoDuration(rawValue: "-2 seconds") == nil)
    }
}
