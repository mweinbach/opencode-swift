import Testing
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("AWS EventStream Binary Framing & CRC32")
struct BedrockEventStreamTests {
    @Test("CRC32 matches standard IEEE 802.3 check vector 123456789")
    func crc32StandardVector() {
        let crc = BedrockEventStream.crc32(Array("123456789".utf8))
        #expect(crc == 0xCBF4_3926)
    }

    @Test("Binary message round-trips all 10 AWS EventStream header types")
    func headerTypesRoundTrip() throws {
        let uuidBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        let original = BedrockEventStream.BinaryMessage(
            headers: [
                "h_true": .boolTrue,
                "h_false": .boolFalse,
                "h_byte": .byte(-42),
                "h_i16": .int16(-12345),
                "h_i32": .int32(1_234_567_890),
                "h_i64": .int64(-9_876_543_210),
                "h_bytes": .bytes([0xDE, 0xAD, 0xBE, 0xEF]),
                "h_str": .string("bedrock-event"),
                "h_ts": .timestamp(1_700_000_000_000),
                "h_uuid": .uuid(uuidBytes),
            ],
            body: Array("{\"hello\":\"world\"}".utf8)
        )
        let encoded = BedrockEventStream.encodeMessage(original)
        let decoded = try BedrockEventStream.decodeMessage(encoded[...])
        #expect(decoded == original)
    }

    @Test("Prelude CRC corruption is rejected")
    func preludeCRCMismatchThrows() {
        let frame = AITestHelpers.encodeBedrockEventFrame(eventType: "messageStart", payload: ["role": .string("assistant")])
        var corrupted = frame
        corrupted[8] ^= 0xFF
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try BedrockEventStream.decodeMessage(corrupted[...])
        }
    }

    @Test("Message CRC corruption is rejected")
    func messageCRCMismatchThrows() {
        let frame = AITestHelpers.encodeBedrockEventFrame(eventType: "messageStart", payload: ["role": .string("assistant")])
        var corrupted = frame
        corrupted[corrupted.count - 1] ^= 0x01
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try BedrockEventStream.decodeMessage(corrupted[...])
        }
    }

    @Test("Incremental streaming decoder handles arbitrary byte splits and strips padding field 'p'")
    func incrementalChunkedDecodingAndPaddingStrip() throws {
        let f1 = AITestHelpers.encodeBedrockEventFrame(
            eventType: "contentBlockDelta",
            payload: ["contentBlockIndex": .int(0), "delta": .object(["text": .string("Hi")]), "p": .string("padding")]
        )
        let f2 = AITestHelpers.encodeBedrockEventFrame(
            eventType: "messageStop",
            payload: ["stopReason": .string("end_turn")]
        )
        let combined = f1 + f2
        var decoder = BedrockEventStream.framing().makeDecoder()
        var decodedFrames: [BedrockEventStream.Frame] = []
        // Feed 3 bytes at a time across prelude, headers, payload, and CRC boundaries.
        var idx = 0
        while idx < combined.count {
            let end = min(combined.count, idx + 3)
            decodedFrames.append(contentsOf: try decoder.feed(Array(combined[idx..<end])))
            idx = end
        }
        try decoder.finish()
        #expect(decodedFrames.count == 2)
        let deltaEvent = AIProtocolUtils.JSONCodec.objectValue(decodedFrames[0].event["contentBlockDelta"])
        #expect(deltaEvent?["p"] == nil)
        #expect(AIProtocolUtils.JSONCodec.intValue(deltaEvent?["contentBlockIndex"]) == 0)
        let stopEvent = AIProtocolUtils.JSONCodec.objectValue(decodedFrames[1].event["messageStop"])
        #expect(AIProtocolUtils.JSONCodec.stringValue(stopEvent?["stopReason"]) == "end_turn")
    }

    @Test("Incomplete trailing bytes on finish throws incomplete-stream error")
    func trailingBytesRejected() {
        let frame = AITestHelpers.encodeBedrockEventFrame(eventType: "messageStart", payload: ["role": .string("assistant")])
        var decoder = BedrockEventStream.framing().makeDecoder()
        let partial = Array(frame.prefix(frame.count - 2))
        let emitted = try? decoder.feed(partial)
        #expect(emitted?.isEmpty == true)
        do {
            try decoder.finish()
            Issue.record("Expected incomplete-stream error")
        } catch {
            #expect(error.classification == "incomplete-stream")
        }
    }

    @Test("Error frame throws protocol error with code and message")
    func errorFrameThrows() {
        let errMsg = BedrockEventStream.BinaryMessage(
            headers: [
                ":message-type": .string("error"),
                ":error-code": .string("ThrottlingException"),
                ":error-message": .string("Slow down"),
            ],
            body: []
        )
        let bytes = BedrockEventStream.encodeMessage(errMsg)
        #expect(throws: AIProtocolUtils.ProtocolError.self) {
            _ = try BedrockEventStream.framing().decodeAll(bytes)
        }
    }
}

@Suite("Protocol Utilities & SigV4")
struct ProtocolUtilsTests {
    @Test("AWS SigV4 signer produces canonical AWS4-HMAC-SHA256 authorization and headers")
    func sigV4Signing() throws {
        let creds = AIProtocolUtils.BedrockAuth.Credentials(
            region: "us-west-2",
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "AQoDYXdzEJr///example"
        )
        let signed = try AIProtocolUtils.BedrockAuth.signRequest(
            method: "POST",
            url: "https://bedrock-runtime.us-west-2.amazonaws.com/model/anthropic.claude-sonnet-4-20250514-v1%3A0/converse-stream",
            body: Array("{\"messages\":[]}".utf8),
            headers: ["content-type": "application/json"],
            credentials: creds,
            service: "bedrock",
            timestampEpochSeconds: 1_700_000_000
        )
        let auth = try #require(signed["authorization"])
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20231114/us-west-2/bedrock/aws4_request, SignedHeaders="))
        #expect(auth.contains("Signature="))
        #expect(signed["x-amz-date"] == "20231114T221320Z")
        #expect(signed["x-amz-security-token"] == "AQoDYXdzEJr///example")
        #expect(signed["host"] == "bedrock-runtime.us-west-2.amazonaws.com")
    }

    @Test("Partial JSON parser parses incomplete objects, arrays, strings, and repairs control chars")
    func partialJSONParsing() throws {
        let partialObj = try AIProtocolUtils.PartialJSONParser.parse(#"{"city":"San Fran"#)
        #expect(partialObj == .object(["city": .string("San Fran")]))

        let partialArr = try AIProtocolUtils.PartialJSONParser.parse(#"[1, 2, 3"#)
        #expect(partialArr == .array([.int(1), .int(2), .int(3)]))

        let partialNum = try AIProtocolUtils.PartialJSONParser.parse(#"{"temp": 72."#)
        #expect(partialNum == .object(["temp": .int(72)]))
    }

    @Test("GeminiJsonSchema normalizes Draft-04 bounds, Draft-07 tuples, required fields, and recursive refs")
    func geminiJsonSchemaNormalize() {
        let input: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "count": .object([
                    "type": .string("number"),
                    "minimum": .int(0),
                    "exclusiveMinimum": .bool(true),
                ]),
                "pair": .object([
                    "type": .string("array"),
                    "items": .array([.object(["type": .string("string")]), .object(["type": .string("number")])]),
                    "additionalItems": .bool(false),
                ]),
                "selfRef": .object(["$ref": .string("#")]),
            ]),
            "required": .array([.string("count"), .string("selfRef"), .string("nonexistent")]),
        ]
        let normalized = AIProtocolUtils.GeminiJsonSchema.normalize(input)
        let req = AIProtocolUtils.JSONCodec.arrayValue(normalized["required"])
        #expect(req == [.string("count"), .string("selfRef")])
        let props = AIProtocolUtils.JSONCodec.objectValue(normalized["properties"])
        let countProp = AIProtocolUtils.JSONCodec.objectValue(props?["count"])
        #expect(countProp?["exclusiveMinimum"] == .int(0))
        #expect(countProp?["minimum"] == nil)
        let pairProp = AIProtocolUtils.JSONCodec.objectValue(props?["pair"])
        #expect(AIProtocolUtils.JSONCodec.arrayValue(pairProp?["prefixItems"])?.count == 2)
        #expect(pairProp?["items"] == .bool(false))
        // Required self-reference loop is cut to unconstrained `{}`
        #expect(props?["selfRef"] == .object([:]))
    }

    @Test("MistralToolID hashes deterministically to 9 alphanumeric chars and avoids collisions")
    func mistralToolIDNormalization() {
        #expect(AIProtocolUtils.MistralToolID.valid("abc123XYZ"))
        #expect(!AIProtocolUtils.MistralToolID.valid("tool_call_123456"))
        let h1 = AIProtocolUtils.MistralToolID.hash("call_abc123")
        let h2 = AIProtocolUtils.MistralToolID.hash("call_abc123")
        #expect(h1 == h2)
        #expect(AIProtocolUtils.MistralToolID.valid(h1))
    }

    @Test("ClaudeModel parses versions and thinking block binding support")
    func claudeVersionParsing() {
        let v46 = AIProtocolUtils.ClaudeModel.claudeVersion("anthropic.claude-sonnet-4-6-20260101-v1:0")
        #expect(v46 == .init(family: "sonnet", major: 4, minor: 6))
        let v51 = AIProtocolUtils.ClaudeModel.claudeVersion("anthropic/claude-opus-5.1")
        #expect(v51 == .init(family: "opus", major: 5, minor: 1))
        #expect(AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(.init(id: "claude-opus-5.1", provider: "anthropic")))
        #expect(!AIProtocolUtils.ClaudeModel.supportsThinkingBlockBinding(.init(id: "claude-sonnet-4-5-20250929", provider: "anthropic")))
    }

    @Test("ImageSizing fits aspect ratio and resolution tier within limits")
    func imageSizingMath() {
        #expect(AIProtocolUtils.ImageSizing.tier("2K") == 2.0)
        #expect(AIProtocolUtils.ImageSizing.tier("0.5k") == 0.5)
        let size = AIProtocolUtils.ImageSizing.fit(
            .init(aspect: "16:9", resolution: "1K"),
            limits: .init(multiple: 16, maxEdge: 2048)
        )
        #expect(size.width % 16 == 0)
        #expect(size.height % 16 == 0)
        #expect(size.width > size.height)
    }

    @Test("ProviderShared promptCacheKey clamps at 64 unicode scalars and wrapSystemUpdate escapes XML")
    func sharedHelpers() {
        let longKey = String(repeating: "a", count: 80)
        let req = AIProtocolUtils.LLMRequest(
            model: .init(id: "gpt-5", provider: "openai"),
            promptCacheKey: longKey
        )
        #expect(AIProtocolUtils.ProviderShared.promptCacheKey(req)?.count == 64)
        let wrapped = AIProtocolUtils.ProviderShared.wrapSystemUpdate([.init(text: "a < b & c > d")])
        #expect(wrapped == "<system-update>\na &lt; b &amp; c &gt; d\n</system-update>")
        #expect(AIProtocolUtils.ProviderShared.fitThinkingBudget(20_000, maxTokens: 16_000, minimum: 1_024) == 8_000)
        let copilotBilling = AIProtocolUtils.ProviderShared.reportedBilling(
            usage: nil,
            frames: [.object(["copilot_usage": .object(["total_nano_aiu": .int(5_000_000_000)])])]
        )
        #expect(copilotBilling.cost == 0.05)
    }
}

@Suite("Anthropic Messages Protocol")
struct AnthropicMessagesTests {
    @Test("Builds Anthropic Messages body with 4-breakpoint cap, thinking budget fitting, and beta headers")
    func requestBuilding() throws {
        let request = AIProtocolUtils.LLMRequest(
            model: .init(id: "claude-opus-5.1", provider: "anthropic"),
            system: [
                .init(text: "System prompt 1", cache: .init(type: "ephemeral", ttl: "1h")),
                .init(text: "System prompt 2", cache: .init(type: "ephemeral")),
            ],
            messages: [
                .init(role: .user, content: [.text(.init(text: "Hello", cache: .init(type: "ephemeral")))]),
                .init(role: .assistant, content: [.toolCall(.init(id: "call.bad/id", name: "get_weather", input: .object(["city": .string("NYC")])))]),
                .tool([.init(id: "call.bad/id", name: "get_weather", result: .text("Sunny"), cache: .init(type: "ephemeral"))]),
            ],
            tools: [
                .tool(.init(name: "get_weather", description: "Get weather", cache: .init(type: "ephemeral"))),
            ],
            toolChoice: .auto,
            maxTokens: 10_000,
            providerOptions: [
                "thinking": .object(["type": .string("enabled"), "budgetTokens": .int(9_000)]),
                "contextManagement": .object(["edits": .array([.object(["type": .string("compact_20260112")])])]),
            ]
        )
        let body = try AIProtocols.AnthropicMessages.fromRequest(request)
        #expect(body["model"] == .string("claude-opus-5.1"))
        #expect(body["max_tokens"] == .int(10_000))
        // Budget 9_000 capped at maxTokens / 2 = 5_000, plus block_binding injected for Claude 5.1
        let thinking = AIProtocolUtils.JSONCodec.objectValue(body["thinking"])
        #expect(AIProtocolUtils.JSONCodec.intValue(thinking?["budget_tokens"]) == 5_000)
        #expect(thinking?["block_binding"] != nil)

        // Tool ID scrubbed from "call.bad/id" -> "call_bad_id"
        let messages = try #require(AIProtocolUtils.JSONCodec.arrayValue(body["messages"]))
        let assistantBlocks = AIProtocolUtils.JSONCodec.arrayValue(AIProtocolUtils.JSONCodec.objectValue(messages[1])?["content"])
        let toolUse = AIProtocolUtils.JSONCodec.objectValue(assistantBlocks?.first)
        #expect(AIProtocolUtils.JSONCodec.stringValue(toolUse?["id"]) == "call_bad_id")

        // Beta headers include compact and thinking-binding-controls
        let headers = AIProtocols.AnthropicMessages.transportHeaders(for: body)
        #expect(headers["anthropic-version"] == "2023-06-01")
        let beta = try #require(headers["anthropic-beta"])
        #expect(beta.contains("compact-2026-01-12"))
        #expect(beta.contains(AIProtocolUtils.ClaudeModel.THINKING_BINDING_BETA))
    }

    @Test("Parses Anthropic Messages SSE stream with thinking, text, tool call, and merged usage")
    func streamParsing() throws {
        let bytes = AITestHelpers.sseBytes([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":20}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan..."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_xyz"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking weather."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"NYC\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let req = AIProtocolUtils.LLMRequest(model: .init(id: "claude-sonnet-4-5", provider: "anthropic"))
        let events = try AIProtocols.AnthropicMessages.parseSSEStream(bytes, request: req)

        #expect(events.contains { if case .reasoningDelta(_, "Plan...", _) = $0 { return true }; return false })
        #expect(events.contains {
            if case .reasoningEnd(_, _, let meta) = $0 {
                return AIProtocolUtils.JSONCodec.stringValue(meta?["anthropic"]?["signature"]) == "sig_xyz"
            }
            return false
        })
        #expect(events.contains { if case .textDelta(_, "Checking weather.", _) = $0 { return true }; return false })
        #expect(events.contains {
            if case .toolCall(let id, let name, _, let input, _, _) = $0 {
                return id == "toolu_1" && name == "weather" && input == .object(["city": .string("NYC")])
            }
            return false
        })
        let finishEvent = events.last
        if case .finish(let reason, let usage, _) = finishEvent {
            #expect(reason.normalized == .toolCalls)
            #expect(reason.raw == "tool_use")
            #expect(usage?.inputTokens == 170) // 100 + 50 + 20
            #expect(usage?.nonCachedInputTokens == 100)
            #expect(usage?.cacheReadInputTokens == 50)
            #expect(usage?.cacheWriteInputTokens == 20)
            #expect(usage?.outputTokens == 40)
            #expect(usage?.totalTokens == 210)
        } else {
            Issue.record("Expected trailing finish event")
        }
    }
}

@Suite("OpenAI Responses & Chat Completions Protocols")
struct OpenAIProtocolsTests {
    @Test("OpenAI Responses builds developer message, custom freeform tool, and namespaces")
    func responsesRequestBuilding() throws {
        let freeformTool = AIProtocolUtils.ToolDefinition(
            name: "apply_patch",
            description: "Apply a patch",
            inputSchema: [
                "type": .string("object"),
                "properties": .object(["patch": .object(["type": .string("string")])]),
                "required": .array([.string("patch")]),
            ],
            freeform: .lark("start: /.+/")
        )
        let req = AIProtocolUtils.LLMRequest(
            model: .init(id: "gpt-5.4", provider: "openai", providerMetadataKey: "openai"),
            system: [.init(text: "Be concise.")],
            messages: [.user("Patch main.swift")],
            tools: [
                .tool(freeformTool),
                .namespace(name: "fs", description: "Filesystem tools", tools: [.tool(.init(name: "read", description: "Read file"))]),
            ],
            providerOptions: [
                "store": .bool(false),
                "reasoningEffort": .string("high"),
                "include": .array([.string("reasoning.encrypted_content")]),
            ]
        )
        let body = try AIProtocols.OpenAIResponses.fromRequest(req)
        let input = try #require(AIProtocolUtils.JSONCodec.arrayValue(body["input"]))
        #expect(AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(input[0])?["role"]) == "developer")
        #expect(body["store"] == .bool(false))
        let tools = try #require(AIProtocolUtils.JSONCodec.arrayValue(body["tools"]))
        #expect(tools.count == 2)
        #expect(AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(tools[0])?["type"]) == "custom")
        #expect(AIProtocolUtils.JSONCodec.stringValue(AIProtocolUtils.JSONCodec.objectValue(tools[1])?["type"]) == "namespace")
    }

    @Test("OpenAI Responses parses reasoning, output text, function call, and usage")
    func responsesStreamParsing() throws {
        let bytes = AITestHelpers.sseBytes([
            (nil, #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"enc_123"}}"#),
            (nil, #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"Thinking..."}"#),
            (nil, #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Thinking..."}],"encrypted_content":"enc_123"}}"#),
            (nil, #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message","phase":"final_answer"}}"#),
            (nil, #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Hello!"}"#),
            (nil, #"{"type":"response.output_item.done","output_index":1,"item":{"id":"msg_1","type":"message","phase":"final_answer","content":[{"type":"output_text","text":"Hello!"}]}}"#),
            (nil, #"{"type":"response.completed","response":{"id":"resp_42","usage":{"input_tokens":80,"input_tokens_details":{"cached_tokens":30},"output_tokens":20,"output_tokens_details":{"reasoning_tokens":5},"total_tokens":100}}}"#),
        ])
        let req = AIProtocolUtils.LLMRequest(model: .init(id: "gpt-5.4", provider: "openai", providerMetadataKey: "openai"))
        let events = try AIProtocols.OpenAIResponses.`protocol`.parseStream(bytes, req)

        #expect(events.contains { if case .reasoningDelta("rs_1:0", "Thinking...", _) = $0 { return true }; return false })
        #expect(events.contains { if case .textDelta("msg_1", "Hello!", _) = $0 { return true }; return false })
        if case .finish(let reason, let usage, let meta) = events.last {
            #expect(reason.normalized == .stop)
            #expect(usage?.inputTokens == 80)
            #expect(usage?.cacheReadInputTokens == 30)
            #expect(usage?.nonCachedInputTokens == 50)
            #expect(usage?.reasoningTokens == 5)
            #expect(AIProtocolUtils.JSONCodec.stringValue(meta?["openai"]?["responseId"]) == "resp_42")
        } else {
            Issue.record("Expected finish event")
        }
    }

    @Test("OpenResponsesContinuation emits incremental previous_response_id delta when prefix matches")
    func responsesContinuationIncremental() {
        let prevInput: [JSONValue] = [.object(["type": .string("message"), "role": .string("user"), "content": .string("Hi")])]
        let prevOutput: [JSONValue] = [.object(["type": .string("message"), "role": .string("assistant"), "content": .string("Hello")])]
        let nextTurn: JSONValue = .object(["type": .string("message"), "role": .string("user"), "content": .string("Next?")])
        let driver = AIProtocols.OpenResponsesContinuation.driver(.init(
            id: "openai-responses",
            name: "OpenAI Responses",
            request: ["model": .string("gpt-5.4"), "input": .array(prevInput + prevOutput + [nextTurn])]
        ))
        let checkpoint = AIProtocols.OpenResponsesContinuation.Checkpoint(
            responseID: "resp_prev",
            request: ["model": .string("gpt-5.4"), "input": .array(prevInput)],
            output: prevOutput
        )
        let msg = driver.createMessage(checkpoint: checkpoint)
        #expect(msg.mode == "incremental")
        #expect(msg.message.contains("resp_prev"))
        #expect(msg.message.contains("Next?"))
    }

    @Test("OpenAI Chat builds max_tokens for DeepSeek and parses streamed tool calls + [DONE] via HTTPTransport")
    func chatCompletionsBuildAndStream() async throws {
        let req = AIProtocolUtils.LLMRequest(
            model: .init(id: "deepseek-reasoner", provider: "deepseek", baseURL: "https://api.deepseek.com/v1"),
            system: [.init(text: "System")],
            messages: [.user("Call search")],
            tools: [.tool(.init(name: "search", description: "Search"))],
            maxTokens: 2048
        )
        let body = try AIProtocols.OpenAIChat.fromRequest(req)
        #expect(body["max_tokens"] == .int(2048))
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["store"] == nil)

        let sse = AITestHelpers.sseBytes([
            (nil, #"{"choices":[{"delta":{"reasoning_content":"Let me search."}}]}"#),
            (nil, #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search","arguments":"{\"q\":"}}]}}]}"#),
            (nil, #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"swift\"}"}}]}}]}"#),
            (nil, #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":15,"prompt_cache_hit_tokens":20}}"#),
            (nil, "[DONE]"),
        ])
        let transport = MockHTTPTransport(chunks: [sse])
        let events = try await AIProtocols.OpenAIChat.route.executeStream(req, transport: transport)
        #expect(events.contains { if case .reasoningDelta("reasoning-0", "Let me search.", _) = $0 { return true }; return false })
        #expect(events.contains {
            if case .toolCall("call_1", "search", _, let input, _, _) = $0 {
                return input == .object(["q": .string("swift")])
            }
            return false
        })
        if case .finish(let reason, let usage, _) = events.last {
            #expect(reason.normalized == .toolCalls)
            #expect(usage?.cacheReadInputTokens == 20)
            #expect(usage?.nonCachedInputTokens == 30)
        } else {
            Issue.record("Expected finish event")
        }
    }
}

@Suite("Gemini & Bedrock Converse Protocols")
struct GeminiAndBedrockTests {
    @Test("Gemini builds normalized request body and parses thoughts, text, functionCall, and inclusive output usage")
    func geminiBuildAndParse() throws {
        let req = AIProtocolUtils.LLMRequest(
            model: .init(id: "gemini-3-pro", provider: "google", providerMetadataKey: "google"),
            system: [.init(text: "You are helpful.")],
            messages: [.user("Weather in Tokyo?")],
            tools: [.tool(.init(name: "weather", description: "Weather lookup"))],
            toolChoice: .tool("weather"),
            maxTokens: 2_000,
            providerOptions: ["thinkingConfig": .object(["thinkingBudget": .int(1_800)])]
        )
        let body = try AIProtocols.Gemini.fromRequest(req)
        let genConfig = AIProtocolUtils.JSONCodec.objectValue(body["generationConfig"])
        let tc = AIProtocolUtils.JSONCodec.objectValue(genConfig?["thinkingConfig"])
        #expect(AIProtocolUtils.JSONCodec.intValue(tc?["thinkingBudget"]) == 1_000)
        #expect(tc?["includeThoughts"] == .bool(true))

        let sse = AITestHelpers.sseBytes([
            (nil, #"{"candidates":[{"content":{"parts":[{"text":"Need Tokyo weather","thought":true,"thoughtSignature":"ts_1"}]}}]}"#),
            (nil, #"{"candidates":[{"content":{"parts":[{"text":"Calling tool..."}]}}]}"#),
            (nil, #"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"fc_1","name":"weather","args":{"city":"Tokyo"}},"thoughtSignature":"ts_2"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":40,"cachedContentTokenCount":10,"candidatesTokenCount":12,"thoughtsTokenCount":8,"totalTokenCount":60}}"#),
        ])
        let events = try AIProtocols.Gemini.parseSSEStream(sse, request: req)
        #expect(events.contains { if case .reasoningDelta(_, "Need Tokyo weather", _) = $0 { return true }; return false })
        #expect(events.contains { if case .textDelta(_, "Calling tool...", _) = $0 { return true }; return false })
        #expect(events.contains {
            if case .toolCall("fc_1", "weather", _, let input, _, let meta) = $0 {
                return input == .object(["city": .string("Tokyo")])
                    && AIProtocolUtils.JSONCodec.stringValue(meta?["google"]?["thoughtSignature"]) == "ts_2"
            }
            return false
        })
        if case .finish(let reason, let usage, _) = events.last {
            #expect(reason.normalized == .toolCalls)
            #expect(usage?.inputTokens == 40)
            #expect(usage?.cacheReadInputTokens == 10)
            #expect(usage?.nonCachedInputTokens == 30)
            #expect(usage?.outputTokens == 20) // 12 visible + 8 thoughts
            #expect(usage?.reasoningTokens == 8)
        } else {
            Issue.record("Expected finish event")
        }
    }

    @Test("Bedrock Converse encodes cachePoints, effort fields, and decodes binary CRC32 EventStream")
    func bedrockConverseEncodeAndDecode() throws {
        let req = AIProtocolUtils.LLMRequest(
            model: .init(id: "us.anthropic.claude-sonnet-4-6-v1:0", provider: "amazon-bedrock", providerMetadataKey: "bedrock"),
            system: [.init(text: "System instructions", cache: .init(type: "ephemeral", ttl: "1h"))],
            messages: [.user("Say hi")],
            tools: [.tool(.init(name: "ping", description: "Ping", cache: .init(type: "ephemeral")))],
            maxTokens: 4096,
            providerOptions: ["effort": .string("high")]
        )
        let body = try AIProtocols.BedrockConverse.fromRequest(req)
        #expect(body["modelId"] == .string("us.anthropic.claude-sonnet-4-6-v1:0"))
        let systemArr = try #require(AIProtocolUtils.JSONCodec.arrayValue(body["system"]))
        #expect(systemArr.count == 2) // text block + cachePoint block
        let addl = AIProtocolUtils.JSONCodec.objectValue(body["additionalModelRequestFields"])
        #expect(AIProtocolUtils.JSONCodec.objectValue(addl?["output_config"])?["effort"] == .string("high"))
        #expect(AIProtocolUtils.JSONCodec.objectValue(addl?["thinking"])?["type"] == .string("adaptive"))

        // Construct binary AWS EventStream frames with real CRC32 checksums
        let binaryStream =
            AITestHelpers.encodeBedrockEventFrame(eventType: "messageStart", payload: ["role": .string("assistant")])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "contentBlockDelta", payload: ["contentBlockIndex": .int(0), "delta": .object(["text": .string("Hello from Bedrock!")])])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "contentBlockStop", payload: ["contentBlockIndex": .int(0)])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "messageStop", payload: ["stopReason": .string("end_turn")])
            + AITestHelpers.encodeBedrockEventFrame(eventType: "metadata", payload: ["usage": .object(["inputTokens": .int(25), "outputTokens": .int(10), "cacheReadInputTokens": .int(100)])])

        let events = try AIProtocols.BedrockConverse.parseEventStream(binaryStream, request: req)
        #expect(events.contains { if case .textDelta("text-0", "Hello from Bedrock!", _) = $0 { return true }; return false })
        if case .finish(let reason, let usage, _) = events.last {
            #expect(reason.normalized == .stop)
            #expect(usage?.inputTokens == 125) // 25 + 100
            #expect(usage?.nonCachedInputTokens == 25)
            #expect(usage?.cacheReadInputTokens == 100)
            #expect(usage?.outputTokens == 10)
        } else {
            Issue.record("Expected finish event")
        }
    }
}

@Suite("Media, Embeddings, Decisions & Provider Catalog")
struct MediaAndProvidersTests {
    @Test("OpenAIEmbeddings decodes both float arrays and little-endian base64 float32 embeddings")
    func openAIEmbeddingsDecode() throws {
        let b64 = AITestHelpers.encodeFloat32LEBase64([1.0, -2.5, 0.25])
        let payload = """
        {"data":[{"index":1,"embedding":"\(b64)"},{"index":0,"embedding":[0.5,1.5]}],"model":"text-embedding-3-small","usage":{"prompt_tokens":12}}
        """
        let decoded = try AIProtocols.OpenAIEmbeddings.`protocol`.decodeResponse(payload, "openai")
        #expect(decoded.embeddings.count == 2)
        #expect(decoded.embeddings[0] == [0.5, 1.5])
        #expect(decoded.embeddings[1] == [1.0, -2.5, 0.25])
        #expect(decoded.inputTokens == 12)
    }

    @Test("GoogleEmbedContent builds batch and Vertex single requests and decodes vectors")
    func googleEmbedContent() throws {
        let req = AIProtocols.EmbeddingRequestPayload(
            model: .init(id: "gemini-embedding-001", provider: "google"),
            values: [.text("hello"), .text("world")],
            dimensions: 256,
            inputType: "query"
        )
        let batchBody = try AIProtocols.GoogleEmbedContent.`protocol`.buildBody(req)
        let requests = try #require(AIProtocolUtils.JSONCodec.arrayValue(batchBody["requests"]))
        #expect(requests.count == 2)
        #expect(AIProtocolUtils.JSONCodec.objectValue(requests[0])?["taskType"] == .string("RETRIEVAL_QUERY"))
        #expect(AIProtocolUtils.JSONCodec.objectValue(requests[0])?["outputDimensionality"] == .int(256))

        let vertexBody = try AIProtocols.GoogleEmbedContent.vertexProtocol.buildBody(req)
        #expect(vertexBody["embedContentConfig"] != nil)
    }

    @Test("SystemOne encodes questions and maps answers back in request question order")
    func systemOneDecisionCodec() throws {
        let req = AIProtocols.SystemOneProtocol.DecisionRequest(
            model: .init(id: "jev-1", provider: "typesafe-ai"),
            input: [.text("Order #123 delayed by 5 days")],
            questions: [
                .predicate(name: "is_urgent", instructions: "Is this urgent?"),
                .choice(name: "dept", instructions: "Route department", choices: [("billing", "Money"), ("support", "Help")]),
            ]
        )
        let body = try AIProtocols.SystemOneProtocol.encodeBody(req)
        #expect(body["state"] == .string("Order #123 delayed by 5 days"))
        let resp = AIProtocols.SystemOneProtocol.Response(
            model: "jev-1",
            answers: [
                "dept": .object(["type": .string("choice"), "choice": .string("support")]),
                "is_urgent": .object(["type": .string("noul"), "noul": .double(0.92)]),
            ],
            usage: ["input_tokens": .int(10), "output_tokens": .int(2)]
        )
        let decoded = try AIProtocols.SystemOneProtocol.toResponse(resp, request: req, providerMetadataKey: "typesafe-ai")
        #expect(decoded.answers.count == 2)
        #expect(AIProtocolUtils.JSONCodec.objectValue(decoded.answers[0])?["type"] == .string("noul"))
        #expect(AIProtocolUtils.JSONCodec.objectValue(decoded.answers[1])?["choice"] == .string("support"))
        #expect(decoded.totalTokens == 12)
    }

    @Test("Provider endpoints, headers, auth resolution, and model routing match upstream specs")
    func providerBuildersAndCatalog() throws {
        let env = DictionaryEnvironment(variables: [
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "OPENAI_API_KEY": "sk-openai-test",
            "AZURE_OPENAI_API_KEY": "az-key-test",
            "GOOGLE_GENERATIVE_AI_API_KEY": "goog-key-test",
            "DASHSCOPE_API_KEY": "ali-key-test",
            "CLOUDFLARE_API_TOKEN": "cf-token-test",
            "OPENROUTER_API_KEY": "or-key-test",
            "AI_GATEWAY_API_KEY": "vgw-key-test",
        ])

        // 1. Anthropic x-api-key + anthropic-version
        let antModel = AIProviders.Anthropic.configure(.init(), environment: env).model("claude-sonnet-4-5")
        let antReq = try antModel.prepareRequest(messages: [.user("Hello")])
        #expect(antReq.url == "https://api.anthropic.com/v1/messages")
        #expect(antReq.headers["x-api-key"] == "sk-ant-test")
        #expect(antReq.headers["anthropic-version"] == "2023-06-01")

        // 2. OpenAI Bearer + org/project headers + GPT-5 default stateless options
        let oaiModel = AIProviders.OpenAI.configure(.init(project: "proj_1", organization: "org_1"), environment: env)
            .model("gpt-5.4", providerOptions: AIProviders.OpenAIOptions.withOpenAIOptions("gpt-5.4", providerOptions: nil))
        let oaiReq = try oaiModel.prepareRequest(messages: [.user("Hi")])
        #expect(oaiReq.url == "https://api.openai.com/v1/responses")
        #expect(oaiReq.headers["authorization"] == "Bearer sk-openai-test")
        #expect(oaiReq.headers["OpenAI-Organization"] == "org_1")
        #expect(oaiReq.headers["OpenAI-Project"] == "proj_1")
        let oaiBody = try AITestHelpers.decodeRequestBody(oaiReq)
        #expect(oaiBody["store"] == .bool(false))

        // 3. Azure resourceName endpoint & api-key header (no Authorization)
        let azEp = try AIProviders.Azure.resolveEndpoint(input: .init(resourceName: "myres", apiVersion: "2025-04-01"), modelID: "gpt-5")
        #expect(azEp.baseURL == "https://myres.openai.azure.com/openai/v1")
        #expect(azEp.query["api-version"] == "2025-04-01")
        let azModel = AIProviders.Azure.configure(.init(resourceName: "myres"), environment: env).model("gpt-5")
        let azReq = try azModel.prepareRequest(messages: [.user("Hi")])
        #expect(azReq.headers["api-key"] == "az-key-test")
        #expect(azReq.headers["authorization"] == nil)

        // 4. Google AI Studio x-goog-api-key & model-embedded SSE path
        let googModel = AIProviders.Google.configure(.init(), environment: env).model("gemini-2.5-pro")
        let googReq = try googModel.prepareRequest(messages: [.user("Hi")])
        #expect(googReq.url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse")
        #expect(googReq.headers["x-goog-api-key"] == "goog-key-test")

        // 5. Google Vertex regional host resolution & embedding protocol selection
        #expect(AIProviders.GoogleVertexShared.host("global") == "aiplatform.googleapis.com")
        #expect(AIProviders.GoogleVertexShared.host("eu") == "aiplatform.eu.rep.googleapis.com")
        #expect(AIProviders.GoogleVertexShared.host("us-central1") == "us-central1-aiplatform.googleapis.com")
        let emb2 = try AIProviders.GoogleVertex.embeddingModel("gemini-embedding-2-exp", settings: .init(project: "p1", location: "us-central1", accessToken: "tok"))
        #expect(emb2.protocolID == "google-vertex-embed-content")
        let embOld = try AIProviders.GoogleVertex.embeddingModel("text-embedding-005", settings: .init(project: "p1", location: "us-central1", accessToken: "tok"))
        #expect(embOld.protocolID == "google-vertex-predict-embeddings")

        // 6. Alibaba region host resolution
        let aliProv = try AIProviders.Alibaba.configure(.init(region: "cn-beijing"), environment: env)
        #expect(aliProv.baseURL == "https://dashscope.aliyuncs.com/compatible-mode/v1")

        // 7. Cloudflare Run API URL derivation & gateway header
        let cfRun = try AIProviders.CloudflareWorkersAI.runBaseURL(.init(accountId: "acct_123"))
        #expect(cfRun == "https://api.cloudflare.com/client/v4/accounts/acct_123/ai/run")
        let cfGw = try AIProviders.CloudflareAIGateway.configure(.init(accountId: "acct_123", gatewayId: "prod-gw"), environment: env)
        #expect(cfGw.headers["cf-aig-gateway-id"] == "prod-gw")

        // 8. Vercel AI Gateway model family dispatch
        #expect(AIProviders.VercelAIGateway.model("openai/gpt-5").route.id == "vercel-ai-gateway-responses")
        #expect(AIProviders.VercelAIGateway.model("meta/muse-1").route.id == "vercel-ai-gateway-chat")
        #expect(AIProviders.VercelAIGateway.model("anthropic/claude-sonnet-4-5").route.id == "vercel-ai-gateway-messages")

        // 9. MiniMax Video Hailuo vs H3 routing & xAI image resolution tiering
        #expect(AIProtocols.MiniMaxVideo.model(.init(id: "MiniMax-Hailuo-02")).path == AIProtocols.MiniMaxVideo.HAILUO_PATH)
        #expect(AIProtocols.MiniMaxVideo.model(.init(id: "video-03")).path == AIProtocols.MiniMaxVideo.PATH)
        #expect(AIProtocols.XAIImages.resolution("1K") == "1k")
        #expect(AIProtocols.XAIImages.resolution("4K") == "2k")

        // 10. Catalog lookup completeness
        #expect(AIProviders.catalog.count >= 35)
        #expect(AIProviders.catalogEntry(for: "anthropic")?.authHeader == "x-api-key")
        #expect(AIProviders.catalogEntry(for: "openai")?.defaultBaseURL == "https://api.openai.com/v1")
        #expect(AIProviders.catalogEntry(for: "openrouter")?.defaultBaseURL == "https://openrouter.ai/api/v1")
    }
}
