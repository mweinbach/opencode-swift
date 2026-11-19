import Testing
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Live Provider Bridge & Incremental Streaming")
struct AILiveBridgeTests {

    @Test("AIProviders.makeLanguageModel streams Anthropic SSE chunks incrementally before stream ends")
    func incrementalAnthropicStreaming() async throws {
        let transport = ControlledStreamTransport()
        let model = try AIProviders.makeLanguageModel(
            package: "@opencode/ai/providers/anthropic",
            modelID: "claude-sonnet-4-5",
            options: .init(apiKey: .explicit("sk-ant-live-key")),
            transport: transport
        )
        let client = AIRoute.layer(executor: AIRequestExecutor.layer(transport: transport))
        let stream = AILLM.stream(
            AILLM.LLMRequestInput(
                model: model,
                system: .text("Be concise."),
                input: .promptText("Greet me"),
                maxTokens: 128
            ),
            client: client
        )

        let firstDeltaLatch = FirstDeltaLatch()
        let consumer = Task<(deltas: [String], finish: AISchema.Finish?), Error> {
            var deltas: [String] = []
            var finishEvent: AISchema.Finish? = nil
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    deltas.append(delta.text)
                    firstDeltaLatch.signal(delta.text)
                case .finish(let f):
                    finishEvent = f
                default:
                    break
                }
            }
            return (deltas, finishEvent)
        }

        await transport.waitUntilStreamOpened()

        // Push ONLY chunk 1 (stream remains open and unfinished!)
        transport.pushSSE(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12}}}\n\n"
                + "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
                + "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}\n\n"
        )

        // Consumer MUST receive chunk 1's textDelta BEFORE chunk 2 is ever sent!
        let firstDelta = await firstDeltaLatch.wait()
        #expect(firstDelta == "Hello ")

        // Now push chunk 2 and complete the stream
        transport.pushSSE(
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world!\"}}\n\n"
                + "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                + "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n"
                + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        )
        transport.finishStream()

        let result = try await consumer.value
        #expect(result.deltas == ["Hello ", "world!"])
        let fin = try #require(result.finish)
        #expect(fin.reason.normalized == .stop)
        #expect(fin.usage?.inputTokens == 12)
        #expect(fin.usage?.outputTokens == 5)
        #expect(fin.message?.content.contains { if case .text(let t) = $0 { return t.text == "Hello world!" }; return false } == true)

        let captured = try #require(transport.recordedRequests.first)
        #expect(captured.url == "https://api.anthropic.com/v1/messages")
        #expect(captured.headers["x-api-key"] == "sk-ant-live-key")
        #expect(captured.headers["anthropic-version"] == "2023-06-01")
    }

    @Test("AIProviders.makeLanguageModel streams OpenAI Responses & Chat chunks incrementally across mid-frame splits")
    func incrementalOpenAIResponsesAndChatStreaming() async throws {
        // 1. OpenAI Responses incremental delivery
        let respTransport = ControlledStreamTransport()
        let respModel = try AIProviders.makeLanguageModel(
            package: "@opencode/ai/providers/openai",
            modelID: "gpt-5.4",
            options: .init(apiKey: .explicit("sk-oai-live")),
            transport: respTransport
        )
        let respClient = AIRoute.layer(executor: AIRequestExecutor.layer(transport: respTransport))
        let respStream = AILLM.stream(
            AILLM.LLMRequestInput(model: respModel, input: .promptText("Ping")),
            client: respClient
        )
        let respLatch = FirstDeltaLatch()
        let respConsumer = Task<AISchema.Finish?, Error> {
            var fin: AISchema.Finish? = nil
            for try await ev in respStream {
                if case .textDelta(let d) = ev { respLatch.signal(d.text) }
                if case .finish(let f) = ev { fin = f }
            }
            return fin
        }

        await respTransport.waitUntilStreamOpened()
        respTransport.pushSSE(
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"phase\":\"final_answer\"}}\n\n"
                + "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"Pong\"}\n\n"
        )
        #expect(await respLatch.wait() == "Pong")

        respTransport.pushSSE(
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Pong\"}]}}\n\n"
                + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_99\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12}}}\n\n"
        )
        respTransport.finishStream()

        let respFinish = try await respConsumer.value
        #expect(respFinish?.reason.normalized == .stop)
        #expect(respFinish?.usage?.totalTokens == 12)
        #expect(respTransport.recordedRequests.first?.url == "https://api.openai.com/v1/responses")
        #expect(respTransport.recordedRequests.first?.headers["authorization"] == "Bearer sk-oai-live")

        // 2. OpenAI Chat split across arbitrary byte chunk boundaries
        let chatChunks = [
            Array("data: {\"choices\":[{\"delta\":{\"content\":\"Hel".utf8),
            Array("lo\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8),
            Array("data: [DONE]\n\n".utf8),
        ]
        let chatTransport = CapturingStreamTransport(chunks: chatChunks)
        let chatModel = try AIProviders.makeLanguageModel(
            package: "@opencode/ai/providers/openai/chat",
            modelID: "gpt-4o",
            options: .init(apiKey: .explicit("sk-chat")),
            transport: chatTransport
        )
        let chatClient = AIRoute.layer(executor: AIRequestExecutor.layer(transport: chatTransport))
        let response = try await AILLM.generate(
            AILLM.LLMRequestInput(model: chatModel, input: .promptText("Say hi")),
            client: chatClient
        )
        #expect(response.text == "Hello")
        #expect(response.finishReason.normalized == .stop)
        #expect(chatTransport.recordedRequests.first?.url == "https://api.openai.com/v1/chat/completions")
    }

    @Test("AIProviders.makeLanguageModel streams AWS Bedrock binary EventStream chunks incrementally")
    func incrementalBedrockEventStreamStreaming() async throws {
        let transport = ControlledStreamTransport(headers: ["content-type": "application/vnd.amazon.eventstream"])
        let creds = AIProtocolUtils.BedrockAuth.Credentials(
            region: "us-west-2",
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        )
        let model = try AIProviders.makeLanguageModel(
            package: "@opencode/ai/providers/amazon-bedrock",
            modelID: "anthropic.claude-sonnet-4-6-v1:0",
            options: .init(region: "us-west-2", credentials: creds),
            transport: transport
        )
        let client = AIRoute.layer(executor: AIRequestExecutor.layer(transport: transport))
        let stream = AILLM.stream(
            AILLM.LLMRequestInput(model: model, input: .promptText("Hello Bedrock")),
            client: client
        )
        let bedrockLatch = FirstDeltaLatch()
        let bedrockConsumer = Task<AISchema.Finish?, Error> {
            var fin: AISchema.Finish? = nil
            for try await ev in stream {
                if case .textDelta(let d) = ev { bedrockLatch.signal(d.text) }
                if case .finish(let f) = ev { fin = f }
            }
            return fin
        }

        await transport.waitUntilStreamOpened()

        // Push binary EventStream frame 1 only
        let frame1 = AITestHelpers.encodeBedrockEventFrame(
            eventType: "contentBlockDelta",
            payload: ["contentBlockIndex": .int(0), "delta": .object(["text": .string("Live Bedrock")])]
        )
        transport.pushChunk(frame1)
        #expect(await bedrockLatch.wait() == "Live Bedrock")

        // Push closing binary frames
        let tail =
            AITestHelpers.encodeBedrockEventFrame(eventType: "contentBlockStop", payload: ["contentBlockIndex": .int(0)])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "messageStop", payload: ["stopReason": .string("end_turn")])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "metadata", payload: ["usage": .object(["inputTokens": .int(15), "outputTokens": .int(4)])])
        transport.pushChunk(tail)
        transport.finishStream()

        let finish = try await bedrockConsumer.value
        #expect(finish?.reason.normalized == .stop)
        #expect(finish?.usage?.inputTokens == 15)
        #expect(finish?.usage?.outputTokens == 4)

        let req = try #require(transport.recordedRequests.first)
        #expect(req.url.contains("bedrock-runtime.us-west-2.amazonaws.com"))
        #expect(req.headers["authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
        #expect(req.headers["x-amz-date"] != "20231114T221320Z")
    }

    @Test("ChatRouteSpec.asLanguageModel bridges any ChatRouteSpec directly to AILLM.generate")
    func chatRouteSpecAsLanguageModel() async throws {
        let sse = AITestHelpers.sseBytes([
            (nil, #"{"candidates":[{"content":{"parts":[{"text":"Gemini live!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3,"totalTokenCount":11}}"#),
        ])
        let transport = CapturingStreamTransport(chunks: [sse])
        let model = AIProtocols.Gemini.route.asLanguageModel(
            modelID: "gemini-2.5-pro",
            config: .init(apiKey: .explicit("goog-live-key")),
            transport: transport
        )
        let client = AIRoute.layer(executor: AIRequestExecutor.layer(transport: transport))
        let res = try await AILLM.generate(
            AILLM.LLMRequestInput(model: model, input: .promptText("Test Gemini")),
            client: client
        )
        #expect(res.text == "Gemini live!")
        #expect(res.usage?.totalTokens == 11)
        let req = try #require(transport.recordedRequests.first)
        #expect(req.url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse")
        #expect(req.headers["x-goog-api-key"] == "goog-live-key")
    }

    @Test("AIProviders.makeLanguageModel supports all priority provider packages and compiles wire bodies")
    func allPriorityProviderPackagesResolve() async throws {
        let specs: [(pkg: String, model: String, opts: AIProviders.ProviderConfig, expectedRoutePrefix: String)] = [
            ("@opencode/ai/providers/anthropic", "claude-sonnet-4-5", .init(apiKey: .explicit("k")), "anthropic-messages"),
            ("@opencode/ai/providers/anthropic-compatible", "claude-custom", .init(apiKey: .explicit("k"), baseURL: "https://proxy.example/v1"), "anthropic-compatible-messages"),
            ("@opencode/ai/providers/openai", "gpt-5.4", .init(apiKey: .explicit("k")), "openai-responses"),
            ("@opencode/ai/providers/openai/chat", "gpt-4o", .init(apiKey: .explicit("k")), "openai-chat"),
            ("@opencode/ai/providers/openai-compatible", "llama-3", .init(apiKey: .explicit("k"), baseURL: "https://local.example/v1"), "openai-compatible-chat"),
            ("@opencode/ai/providers/google", "gemini-2.5-pro", .init(apiKey: .explicit("k")), "gemini"),
            ("@opencode/ai/providers/google-vertex", "gemini-2.5-pro", .init(apiKey: .explicit("k")), "google-vertex-gemini"),
            ("@opencode/ai/providers/amazon-bedrock", "anthropic.claude-sonnet-4-6", .init(apiKey: .explicit("k"), region: "us-east-1"), "bedrock-converse"),
            ("@opencode/ai/providers/openrouter", "openai/gpt-5", .init(apiKey: .explicit("k")), "openrouter"),
            ("@opencode/ai/providers/xai", "grok-4", .init(apiKey: .explicit("k")), "xai-responses"),
            ("@opencode/ai/providers/groq", "llama-3.3-70b", .init(apiKey: .explicit("k")), "groq-chat"),
            ("@opencode/ai/providers/deepseek", "deepseek-chat", .init(apiKey: .explicit("k")), "deepseek"),
            ("@opencode/ai/providers/mistral", "mistral-large", .init(apiKey: .explicit("k")), "mistral-chat"),
            ("@opencode/ai/providers/cerebras", "llama-3.3-70b", .init(apiKey: .explicit("k")), "cerebras"),
            ("@opencode/ai/providers/togetherai", "meta-llama/Llama-4", .init(apiKey: .explicit("k")), "togetherai"),
            ("@opencode/ai/providers/fireworks", "accounts/fireworks/models/llama", .init(apiKey: .explicit("k")), "fireworks"),
            ("@opencode/ai/providers/cohere", "command-a", .init(apiKey: .explicit("k")), "cohere-chat"),
            ("@opencode/ai/providers/azure", "gpt-5", .init(apiKey: .explicit("k"), resourceName: "myres", apiVersion: "2025-04-01"), "azure-openai-responses"),
            ("@opencode/ai/providers/opencode", "big-pickle", .init(apiKey: .explicit("k")), "opencode"),
            ("openai", "gpt-5", .init(apiKey: .explicit("k")), "openai-responses"),
            ("anthropic", "claude-sonnet-4-5", .init(apiKey: .explicit("k")), "anthropic-messages"),
        ]

        for entry in specs {
            let model = try AIProviders.makeLanguageModel(
                package: entry.pkg,
                modelID: entry.model,
                options: entry.opts
            )
            #expect(model.id.rawValue == entry.model)
            #expect(model.route.id == entry.expectedRoutePrefix)
            let compiled = try await AIRoute.compileRequest(
                AISchema.LLMRequest(model: model, messages: [.user("Hello")])
            )
            guard case .object(let bodyObj) = compiled.body else {
                Issue.record("Expected JSON object body for \(entry.pkg)")
                continue
            }
            #expect(!bodyObj.isEmpty)
        }

        // Unknown package throws ProviderConfigurationError
        #expect(throws: AIProviders.ProviderConfigurationError.self) {
            _ = try AIProviders.makeLanguageModel(package: "@unknown/provider", modelID: "m1")
        }
    }
}

@Suite("Real Wall-Clock SigV4 Signing")
struct SigV4TimestampTests {

    @Test("Default SigV4 signing uses current wall-clock epoch seconds, while explicit override remains deterministic")
    func wallClockDefaultVsDeterministicOverride() throws {
        let creds = AIProtocolUtils.BedrockAuth.Credentials(
            region: "us-west-2",
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        )
        let model = AIProviders.AmazonBedrock.configure(.init(region: "us-west-2", credentials: creds))
            .model("anthropic.claude-sonnet-4-6-v1:0")

        // 1. Default uses current wall-clock UTC date (NOT hardcoded 20231114 / 1_700_000_000!)
        let beforeStamp = LiveBridgeTimeHelper.utcDateStamp(epochSeconds: LiveBridgeTimeHelper.currentEpochSeconds())
        let liveReq = try model.prepareRequest(messages: [.user("Hello")])
        let afterStamp = LiveBridgeTimeHelper.utcDateStamp(epochSeconds: LiveBridgeTimeHelper.currentEpochSeconds())

        let liveDate = try #require(liveReq.headers["x-amz-date"])
        #expect(liveDate != "20231114T221320Z")
        #expect(liveDate.hasPrefix(beforeStamp) || liveDate.hasPrefix(afterStamp))
        let liveAuth = try #require(liveReq.headers["authorization"])
        #expect(liveAuth.contains("/\(beforeStamp)/us-west-2/bedrock/aws4_request") || liveAuth.contains("/\(afterStamp)/us-west-2/bedrock/aws4_request"))

        // 2. Explicit timestampEpochSeconds override stays 100% deterministic
        let deterministicReq = try model.prepareRequest(
            messages: [.user("Hello")],
            timestampEpochSeconds: 1_700_000_000
        )
        #expect(deterministicReq.headers["x-amz-date"] == "20231114T221320Z")
        #expect(deterministicReq.headers["authorization"]?.contains("/20231114/us-west-2/bedrock/aws4_request") == true)

        // 3. Injectable clock closure works on ChatRouteSpec.prepareHTTPRequest
        let protoReq = AIProtocolUtils.LLMRequest(model: model.descriptor, messages: [.user("Clock test")])
        let injectedReq = try model.route.prepareHTTPRequest(for: protoReq, clock: { 1_735_689_600 }) // 2025-01-01T00:00:00Z
        #expect(injectedReq.headers["x-amz-date"] == "20250101T000000Z")
    }
}

@Suite("AIRequestExecutor Timeout Enforcement")
struct AIRequestExecutorTimeoutTests {

    @Test("Headers timeout cancels stalled transport and throws Timeout TransportError")
    func headersTimeoutCancelsRequest() async {
        let transport = DelayedTimeoutTransport(headersDelayMs: 5_000)
        let executor = AIRequestExecutor.layer(transport: transport)
        let timed = AIRequestExecutor.withTimeout(
            { req, mw in try await executor.execute(req, middleware: mw) },
            timeout: .phases(AISchema.TimeoutConfig(headers: .milliseconds(50)))
        )

        do {
            _ = try await timed(HTTPRequest(method: "POST", url: "https://api.example.com/v1/chat"), nil)
            Issue.record("Expected headers timeout error")
        } catch let err as AISchema.AIError {
            if case .transport(let t) = err.reason {
                #expect(t.code == "Timeout")
                #expect(t.operation == .request)
                #expect(t.message.contains("headers"))
            } else {
                Issue.record("Expected transport timeout error, got \(err)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Chunk idle timeout fires when stream stalls mid-response")
    func chunkIdleTimeoutCancelsStream() async throws {
        let transport = DelayedTimeoutTransport(
            headersDelayMs: 0,
            chunkSchedule: [(delayMs: 5, bytes: Array("chunk-1".utf8))],
            stallAfterChunks: true
        )
        let executor = AIRequestExecutor.layer(transport: transport)
        let timed = AIRequestExecutor.withTimeout(
            { req, mw in try await executor.execute(req, middleware: mw) },
            timeout: .phases(AISchema.TimeoutConfig(chunk: .milliseconds(60)))
        )

        let resp = try await timed(HTTPRequest(method: "POST", url: "https://api.example.com/v1/stream"), nil)
        var received: [String] = []
        do {
            for try await chunk in AIRequestExecutor.responseStream(resp) {
                received.append(String(decoding: chunk, as: UTF8.self))
            }
            Issue.record("Expected chunk idle timeout")
        } catch let err as AISchema.AIError {
            #expect(received == ["chunk-1"])
            if case .transport(let t) = err.reason {
                #expect(t.code == "Timeout")
                #expect(t.operation == .read)
            } else {
                Issue.record("Expected transport timeout, got \(err)")
            }
        }
    }

    @Test("Total request timeout caps entire streaming duration")
    func totalTimeoutCapsStreamDuration() async throws {
        let transport = DelayedTimeoutTransport(
            headersDelayMs: 5,
            chunkSchedule: [
                (delayMs: 25, bytes: Array("a".utf8)),
                (delayMs: 25, bytes: Array("b".utf8)),
                (delayMs: 25, bytes: Array("c".utf8)),
                (delayMs: 25, bytes: Array("d".utf8)),
                (delayMs: 25, bytes: Array("e".utf8)),
            ]
        )
        let executor = AIRequestExecutor.layer(transport: transport)
        let timed = AIRequestExecutor.withTimeout(
            { req, mw in try await executor.execute(req, middleware: mw) },
            timeout: .single(.milliseconds(65))
        )

        let resp = try await timed(HTTPRequest(method: "POST", url: "https://api.example.com/v1/slow"), nil)
        var count = 0
        do {
            for try await _ in AIRequestExecutor.responseStream(resp) {
                count += 1
            }
            Issue.record("Expected total request timeout")
        } catch let err as AISchema.AIError {
            #expect(count < 5)
            if case .transport(let t) = err.reason {
                #expect(t.code == "Timeout")
                #expect(t.operation == .read)
            } else {
                Issue.record("Expected transport timeout, got \(err)")
            }
        }
    }

    @Test("Disabled timeouts permit slow response to complete normally")
    func disabledTimeoutCompletes() async throws {
        let transport = DelayedTimeoutTransport(
            headersDelayMs: 15,
            chunkSchedule: [(delayMs: 15, bytes: Array("ok".utf8))]
        )
        let executor = AIRequestExecutor.layer(transport: transport)
        let timed = AIRequestExecutor.withTimeout(
            { req, mw in try await executor.execute(req, middleware: mw) },
            timeout: .phases(AISchema.TimeoutConfig(total: .disabled, headers: .disabled, chunk: .disabled))
        )
        let resp = try await timed(HTTPRequest(method: "POST", url: "https://api.example.com/v1/ok"), nil)
        let body = try await AIRequestExecutor.responseText(resp)
        #expect(body == "ok")
    }
}

@Suite("Primary Media Protocol Codecs")
struct MediaProtocolCodecTests {

    @Test("OpenAIImages builds sized/streaming JSON bodies and decodes base64 responses with usage")
    func openAIImagesCodec() throws {
        let req = AIProtocols.OpenAIImages.Request(
            modelID: "gpt-image-1",
            prompt: "A red panda coding Swift",
            n: 1,
            aspect: "16:9",
            resolution: "1K",
            providerOptions: ["outputFormat": .string("png"), "quality": .string("high")]
        )
        let body = try AIProtocols.OpenAIImages.fromRequest(req, streaming: true)
        #expect(body["model"] == .string("gpt-image-1"))
        #expect(body["size"] == .string("1536x1024"))
        #expect(body["output_format"] == .string("png"))
        #expect(body["stream"] == .bool(true))
        #expect(body["partial_images"] == .int(2))

        // Rejects conflicting size + aspect
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try AIProtocols.OpenAIImages.fromRequest(.init(
                modelID: "gpt-image-1",
                prompt: "test",
                aspect: "1:1",
                providerOptions: ["size": .string("1024x1024")]
            ))
        }

        let pngB64 = bytesToBase64([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let respJSON = """
        {"data":[{"b64_json":"\(pngB64)"}],"output_format":"png","size":"1536x1024","quality":"high","usage":{"input_tokens":15,"output_tokens":50,"total_tokens":65}}
        """
        let decoded = try AIProtocols.OpenAIImages.decodeResponse(respJSON)
        #expect(decoded.images.count == 1)
        #expect(decoded.images[0].mediaType == "image/png")
        #expect(decoded.images[0].info?["width"] == .int(1536))
        #expect(decoded.images[0].info?["height"] == .int(1024))
        if case .tokens(let i, let o, let t, _) = decoded.usage {
            #expect(i == 15)
            #expect(o == 50)
            #expect(t == 65)
        } else {
            Issue.record("Expected token usage")
        }
    }

    @Test("OpenAISpeech builds SSE speech body and decodes audio delta + done SSE stream")
    func openAISpeechCodec() throws {
        let req = AIProtocols.OpenAISpeech.Request(
            modelID: "gpt-4o-mini-tts",
            text: "Hello world",
            voice: "alloy",
            format: "pcm",
            speed: 1.1,
            streaming: true
        )
        let body = try AIProtocols.OpenAISpeech.fromRequest(req)
        #expect(body["model"] == .string("gpt-4o-mini-tts"))
        #expect(body["input"] == .string("Hello world"))
        #expect(body["response_format"] == .string("pcm"))
        #expect(body["stream_format"] == .string("sse"))

        // tts-1 does not set stream_format: sse
        let legacyBody = try AIProtocols.OpenAISpeech.fromRequest(.init(modelID: "tts-1", text: "Hi", streaming: true))
        #expect(legacyBody["stream_format"] == nil)

        // Rejects timestamps
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try AIProtocols.OpenAISpeech.fromRequest(.init(modelID: "gpt-4o-mini-tts", text: "Hi", timestamps: true))
        }

        let audioB64 = bytesToBase64([1, 2, 3, 4])
        let sse = AITestHelpers.sseBytes([
            (nil, #"{"type":"speech.audio.delta","audio":"\#(audioB64)"}"#),
            (nil, #"{"type":"speech.audio.done","usage":{"input_tokens":5,"output_tokens":20,"total_tokens":25}}"#),
        ])
        let events = try AIProtocols.OpenAISpeech.decodeSSEStream(sse, format: "pcm")
        #expect(events.contains { if case .audioDelta(let b) = $0 { return b == [1, 2, 3, 4] }; return false })
        if case .finish(let asset, let usage, _) = events.last {
            #expect(asset.mediaType == "audio/pcm")
            #expect(asset.info?["sampleRate"] == .int(24_000))
            if case .tokens(_, _, let total, _) = usage { #expect(total == 25) }
            else { Issue.record("Expected token usage") }
        } else {
            Issue.record("Expected finish event")
        }
    }

    @Test("OpenAITranscription validates model capabilities, builds multipart upload, and decodes JSON + SSE")
    func openAITranscriptionCodec() throws {
        let wav = AIProtocolUtils.MediaAsset.bytes([0x52, 0x49, 0x46, 0x46], mediaType: "audio/wav")
        let req = AIProtocols.OpenAITranscription.Request(
            modelID: "whisper-1",
            audio: wav,
            language: "en",
            timestamps: "word"
        )
        let body = try AIProtocols.OpenAITranscription.fromRequest(req)
        #expect(body["response_format"] == .string("verbose_json"))
        #expect(body["timestamp_granularities"] == .array([.string("word")]))

        let multipart = try AIProtocols.OpenAITranscription.buildMultipart(req)
        let encoded = multipart.encode()
        #expect(encoded.contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(String(decoding: encoded.body, as: UTF8.self).contains("filename=\"audio.wav\""))

        // Rejects diarize on whisper-1
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try AIProtocols.OpenAITranscription.fromRequest(.init(modelID: "whisper-1", audio: wav, diarize: true))
        }

        let respJSON = #"{"text":"Hello Swift","language":"EN","duration":2.5,"segments":[{"text":" Hello Swift ","start":0,"end":2.5}],"usage":{"type":"duration","seconds":2.5}}"#
        let decoded = try AIProtocols.OpenAITranscription.decodeResponse(respJSON)
        #expect(decoded.text == "Hello Swift")
        #expect(decoded.language == "en")
        #expect(decoded.segments.first?.text == "Hello Swift")
        #expect(decoded.usage == .seconds(2.5))
    }

    @Test("GoogleImages maps 0.5K resolution to 512, filters thought drafts, and detects safety blocks")
    func googleImagesCodec() throws {
        let body = try AIProtocols.GoogleImages.fromRequest(.init(
            modelID: "gemini-2.5-flash-image",
            prompt: "Sunset",
            aspect: "16:9",
            resolution: "0.5K"
        ))
        let genCfg = AIProtocolUtils.JSONCodec.objectValue(body["generationConfig"])
        let imgCfg = AIProtocolUtils.JSONCodec.objectValue(genCfg?["imageConfig"])
        #expect(imgCfg?["imageSize"] == .string("512"))
        #expect(imgCfg?["aspectRatio"] == .string("16:9"))

        let draftB64 = bytesToBase64([1, 2, 3])
        let finalB64 = bytesToBase64([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let respJSON = """
        {"candidates":[{"index":0,"finishReason":"STOP","content":{"parts":[
          {"thought":true,"inlineData":{"mimeType":"image/png","data":"\(draftB64)"}},
          {"inlineData":{"mimeType":"image/png","data":"\(finalB64)"}}
        ]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":20,"thoughtsTokenCount":5,"totalTokenCount":35}}
        """
        let decoded = try AIProtocols.GoogleImages.decodeResponse(respJSON)
        #expect(decoded.images.count == 1)
        #expect(decoded.images[0].mediaType == "image/png")
        if case .tokens(let i, let o, let t, _) = decoded.usage {
            #expect(i == 10)
            #expect(o == 25)
            #expect(t == 35)
        } else {
            Issue.record("Expected token usage")
        }

        // Content safety block throws .contentPolicy
        do {
            _ = try AIProtocols.GoogleImages.decodeResponse(#"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#)
            Issue.record("Expected contentPolicy error")
        } catch {
            #expect(error.kind == .contentPolicy)
        }
    }

    @Test("XAIImages builds image/images fields and decodes revised_prompt metadata")
    func xaiImagesCodec() throws {
        let refImg = AIProtocolUtils.MediaAsset.url("https://example.com/in.png", mediaType: "image/png")
        let body = try AIProtocols.XAIImages.fromRequest(.init(
            modelID: "grok-2-image",
            prompt: "Stylize",
            aspect: "4:3",
            resolution: "4K",
            images: [refImg]
        ))
        #expect(body["aspect_ratio"] == .string("4:3"))
        #expect(body["resolution"] == .string("2k"))
        #expect(body["response_format"] == .string("b64_json"))
        #expect(AIProtocolUtils.JSONCodec.objectValue(body["image"])?["url"] == .string("https://example.com/in.png"))

        let imgB64 = bytesToBase64([0xFF, 0xD8, 0xFF, 0xE0])
        let decoded = try AIProtocols.XAIImages.decodeResponse(
            #"{"data":[{"b64_json":"\#(imgB64)","mime_type":"image/jpeg","revised_prompt":"Stylized art"}],"usage":{"cost_in_usd_ticks":100}}"#
        )
        #expect(decoded.images.count == 1)
        #expect(decoded.images[0].providerMetadata?["xai"]?["revisedPrompt"] == .string("Stylized art"))
    }

    @Test("ElevenLabsSpeech builds voice path + JSON body and decodes alignment timestamps")
    func elevenLabsSpeechCodec() throws {
        let req = AIProtocols.ElevenLabsSpeech.Request(
            modelID: "eleven_flash_v2_5",
            text: "Hi",
            voice: "voice_abc",
            format: "pcm",
            speed: 1.0,
            timestamps: true,
            streaming: true
        )
        #expect(AIProtocols.ElevenLabsSpeech.requestPath(for: req) == "/v1/text-to-speech/voice_abc/stream/with-timestamps")
        let body = try AIProtocols.ElevenLabsSpeech.fromRequest(req)
        #expect(body["model_id"] == .string("eleven_flash_v2_5"))
        #expect(AIProtocolUtils.JSONCodec.objectValue(body["voice_settings"])?["speed"] == .double(1.0))

        // Rejects streaming WAV
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try AIProtocols.ElevenLabsSpeech.fromRequest(.init(modelID: "m", text: "Hi", voice: "v", format: "wav", streaming: true))
        }

        let audioB64 = bytesToBase64([10, 20, 30])
        let ndjson = #"{"audio_base64":"\#(audioB64)","alignment":{"characters":["H","i"],"character_start_times_seconds":[0.0,0.1],"character_end_times_seconds":[0.1,0.2]}}"#
        let events = try AIProtocols.ElevenLabsSpeech.decodeTimestampedResponse(
            ndjson,
            format: "pcm_24000",
            headers: ["character-cost": "3", "request-id": "req_el_1"]
        )
        #expect(events.contains { if case .timestamps(let items) = $0 { return items.count == 2 && items[0].text == "H" }; return false })
        if case .finish(_, let usage, let meta) = events.last {
            #expect(usage == .credits(3))
            #expect(meta?["elevenlabs"]?["requestId"] == .string("req_el_1"))
        } else {
            Issue.record("Expected finish event")
        }
    }

    @Test("DeepgramTranscription builds listen query and groups speaker-turn utterances")
    func deepgramTranscriptionCodec() throws {
        let urlAudio = AIProtocolUtils.MediaAsset.url("https://example.com/call.mp3", mediaType: "audio/mpeg")
        let req = AIProtocols.DeepgramTranscription.Request(
            modelID: "nova-3",
            audio: urlAudio,
            diarize: true
        )
        let query = try AIProtocols.DeepgramTranscription.buildQuery(req)
        #expect(query["model"] == ["nova-3"])
        #expect(query["smart_format"] == ["true"])
        #expect(query["detect_language"] == ["true"])
        #expect(query["diarize_model"] == ["latest"])
        #expect(query["utterances"] == ["true"])

        let body = try AIProtocols.DeepgramTranscription.fromRequest(req)
        #expect(body["url"] == .string("https://example.com/call.mp3"))

        let respJSON = """
        {
          "metadata": { "request_id": "dg_1", "duration": 4.2 },
          "results": {
            "channels": [{
              "detected_language": "EN",
              "alternatives": [{
                "transcript": "Hello there Hi back",
                "words": [
                  { "word": "hello", "punctuated_word": "Hello", "start": 0.0, "end": 0.5, "speaker": 0 },
                  { "word": "there", "start": 0.5, "end": 1.0, "speaker": 0 }
                ]
              }]
            }],
            "utterances": [{
              "start": 0.0,
              "end": 2.0,
              "transcript": "Hello there Hi back",
              "speaker": 0,
              "words": [
                { "word": "hello", "punctuated_word": "Hello", "start": 0.0, "end": 0.5, "speaker": 0 },
                { "word": "there", "start": 0.5, "end": 1.0, "speaker": 0 },
                { "word": "hi", "punctuated_word": "Hi", "start": 1.1, "end": 1.5, "speaker": 1 },
                { "word": "back", "start": 1.5, "end": 2.0, "speaker": 1 }
              ]
            }]
          }
        }
        """
        let decoded = try AIProtocols.DeepgramTranscription.decodeResponse(respJSON)
        #expect(decoded.text == "Hello there Hi back")
        #expect(decoded.language == "en")
        #expect(decoded.durationSeconds == 4.2)
        #expect(decoded.usage == .seconds(4.2))
        #expect(decoded.providerMetadata?["deepgram"]?["requestId"] == .string("dg_1"))
        // SpeakerTurns splits the single utterance into two speaker turns (speaker 0 and speaker 1)!
        #expect(decoded.segments.count == 2)
        #expect(decoded.segments[0].speaker == "0")
        #expect(decoded.segments[0].text == "Hello there")
        #expect(decoded.segments[1].speaker == "1")
        #expect(decoded.segments[1].text == "Hi back")
    }
}
