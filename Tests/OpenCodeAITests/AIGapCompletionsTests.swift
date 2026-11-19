import Testing
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

private struct TestEnv: EnvironmentProviding {
    let values: [String: String]

    func variable(_ name: String) -> String? {
        values[name]
    }

    var allVariables: [String: String] { values }
    var homeDirectory: String? { "/tmp" }
    var temporaryDirectory: String { "/tmp" }
}

@Suite("Wave 2 R1 AI Provider Gap Completions")
struct AIProviderGapCompletionsTests {
    @Test("Alibaba routes, configure, model/messages/responses, image/embedding models, and hosted tools")
    func alibabaProviderCompletions() throws {
        #expect(AIProviders.Alibaba.provider.id == "alibaba")
        #expect(AIProviders.Alibaba.routes.map(\.id) == ["alibaba-chat", "alibaba-messages", "alibaba-responses"])

        let env = TestEnv(values: ["DASHSCOPE_API_KEY": "sk-dash-test"])

        let chatModel = try AIProviders.Alibaba.chat(
            "qwen3-max",
            settings: .init(region: "ap-southeast-1"),
            environment: env
        )
        #expect(chatModel.descriptor.id == "qwen3-max")
        #expect(chatModel.descriptor.routeID == "alibaba-chat")
        #expect(chatModel.descriptor.baseURL == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")

        let workspaceModel = try AIProviders.Alibaba.model(
            "qwen-plus",
            settings: .init(region: "eu-central-1", workspaceID: "ws-42"),
            environment: env
        )
        #expect(workspaceModel.descriptor.baseURL == "https://ws-42.eu-central-1.maas.aliyuncs.com/compatible-mode/v1")

        let msgModel = try AIProviders.Alibaba.messages(
            "qwen3-coder",
            settings: .init(region: "cn-beijing"),
            environment: env
        )
        #expect(msgModel.descriptor.routeID == "alibaba-messages")
        #expect(msgModel.descriptor.baseURL == "https://dashscope.aliyuncs.com/apps/anthropic/v1")
        #expect(msgModel.descriptor.compatibility?.requireSignature == false)

        let respModel = try AIProviders.Alibaba.responses(
            "qwen3-max",
            settings: .init(region: "us-east-1"),
            environment: env
        )
        #expect(respModel.descriptor.routeID == "alibaba-responses")
        #expect(respModel.descriptor.baseURL == "https://dashscope-us.aliyuncs.com/compatible-mode/v1")

        let imgHandle = try AIProviders.Alibaba.imageModel("wan2.6-t2i", settings: .init(region: "cn-hongkong"))
        #expect(imgHandle.provider == "alibaba")
        #expect(imgHandle.baseURL == "https://cn-hongkong.dashscope.aliyuncs.com/api/v1")
        #expect(imgHandle.path == AIProtocols.AlibabaImages.PATH)

        let embHandle = try AIProviders.Alibaba.embeddingModel("text-embedding-v3", settings: .init(region: "ap-southeast-1"))
        #expect(embHandle.protocolID == "openai-embeddings")
        #expect(embHandle.baseURL == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        #expect(embHandle.path == "/embeddings")

        #expect(throws: AIProviders.ProviderConfigurationError.self) {
            _ = try AIProviders.Alibaba.configure(.init())
        }
        #expect(throws: AIProviders.ProviderConfigurationError.self) {
            _ = try AIProviders.Alibaba.configure(.init(region: "eu-central-1"))
        }

        let search = AIProviders.Alibaba.webSearch()
        let extractor = AIProviders.Alibaba.webExtractor()
        let interpreter = AIProviders.Alibaba.codeInterpreter()
        #expect(search.name == "web_search")
        #expect(search.native?["alibaba"] == .object(["type": .string("web_search")]))
        #expect(extractor.name == "web_extractor")
        #expect(extractor.native?["alibaba"] == .object(["type": .string("web_extractor")]))
        #expect(interpreter.name == "code_interpreter")
        #expect(interpreter.native?["alibaba"] == .object(["type": .string("code_interpreter")]))
    }

    @Test("MiniMax routes, configure, reasoning_split chat protocol, messages/responses, and video URL stripping")
    func minimaxProviderCompletions() throws {
        #expect(AIProviders.MiniMax.provider.id == "minimax")
        #expect(AIProviders.MiniMax.routes.map(\.id) == ["minimax-messages", "minimax-chat", "minimax-responses"])

        let defaultModel = AIProviders.MiniMax.model("MiniMax-M2.5")
        #expect(defaultModel.descriptor.routeID == "minimax-messages")
        #expect(defaultModel.descriptor.baseURL == "https://api.minimax.io/anthropic/v1")
        #expect(defaultModel.descriptor.compatibility?.requireSignature == false)

        let msgModel = AIProviders.MiniMax.messages("MiniMax-M2.5")
        #expect(msgModel.descriptor.routeID == "minimax-messages")

        let chatModel = AIProviders.MiniMax.chat("MiniMax-M2.5")
        #expect(chatModel.descriptor.routeID == "minimax-chat")
        #expect(chatModel.descriptor.baseURL == "https://api.minimax.io/v1")
        #expect(chatModel.descriptor.capabilities?.strictTools == false)

        let reqWithDefaultSplit = AIProtocolUtils.LLMRequest(
            model: chatModel.descriptor,
            messages: [.user("Hello")]
        )
        let bodyDefault = try AIProviders.MiniMax.chatProtocol.buildBody(reqWithDefaultSplit)
        #expect(bodyDefault["reasoning_split"] == .bool(true))

        let reqWithDisabledSplit = AIProtocolUtils.LLMRequest(
            model: chatModel.descriptor,
            messages: [.user("Hello")],
            providerOptions: [
                "reasoningSplit": .bool(false),
                "thinking": .object(["type": .string("adaptive")]),
            ]
        )
        let bodyCustom = try AIProviders.MiniMax.chatProtocol.buildBody(reqWithDisabledSplit)
        #expect(bodyCustom["reasoning_split"] == .bool(false))
        #expect(bodyCustom["thinking"] == .object(["type": .string("adaptive")]))

        let respModel = AIProviders.MiniMax.responses("MiniMax-M2.5")
        #expect(respModel.descriptor.routeID == "minimax-responses")
        #expect(respModel.descriptor.baseURL == "https://api.minimax.io/v1")

        let imgHandle = AIProviders.MiniMax.image("image-01")
        #expect(imgHandle.provider == "minimax")
        #expect(imgHandle.path == AIProtocols.MiniMaxImages.PATH)

        let vidDefault = AIProviders.MiniMax.video("MiniMax-Hailuo-02")
        #expect(vidDefault.provider == "minimax")
        #expect(vidDefault.baseURL == "https://api.minimax.io")

        let vidStripped = AIProviders.MiniMax.videoModel(
            "MiniMax-Hailuo-02",
            settings: .init(baseURL: "https://proxy.example.com/v1/")
        )
        #expect(vidStripped.baseURL == "https://proxy.example.com")
    }

    @Test("Moonshot routes, configure, chat protocol thinking, messages, and responses")
    func moonshotProviderCompletions() throws {
        #expect(AIProviders.Moonshot.provider.id == "moonshotai")
        #expect(AIProviders.Moonshot.routes.map(\.id) == ["moonshot-chat", "moonshot-messages", "moonshot-responses"])

        let env = TestEnv(values: ["MOONSHOTAI_API_KEY": "sk-moon-test"])
        let configured = AIProviders.Moonshot.configure(.init(), environment: env)
        if case .bearer(let token) = configured.auth {
            #expect(token == "sk-moon-test")
        } else {
            Issue.record("Expected bearer auth from MOONSHOTAI_API_KEY")
        }

        let chatModel = AIProviders.Moonshot.model("kimi-k2.5", settings: .init(), environment: env)
        #expect(chatModel.descriptor.routeID == "moonshot-chat")
        #expect(chatModel.descriptor.baseURL == "https://api.moonshot.ai/v1")
        #expect(chatModel.descriptor.compatibility?.maxTokensField == "max_tokens")
        #expect(chatModel.descriptor.compatibility?.sanitizer == "moonshot")
        #expect(chatModel.descriptor.compatibility?.reasoningField == "reasoning_content")
        #expect(chatModel.descriptor.capabilities?.strictTools == false)
        #expect(chatModel.descriptor.capabilities?.promptCacheKey == true)

        let body = try AIProviders.Moonshot.chatProtocol.buildBody(
            AIProtocolUtils.LLMRequest(
                model: chatModel.descriptor,
                messages: [.user("Hi")],
                providerOptions: ["thinking": .object(["type": .string("enabled"), "keep": .string("all")])]
            )
        )
        #expect(body["thinking"] == .object(["type": .string("enabled"), "keep": .string("all")]))

        let msgModel = AIProviders.Moonshot.messages("kimi-k2.5")
        #expect(msgModel.descriptor.routeID == "moonshot-messages")
        #expect(msgModel.descriptor.baseURL == "https://api.moonshot.ai/anthropic/v1")
        #expect(msgModel.descriptor.compatibility?.requireSignature == false)
        #expect(msgModel.descriptor.compatibility?.sanitizer == "moonshot")

        let respModel = AIProviders.Moonshot.responses("kimi-k2.5")
        #expect(respModel.descriptor.routeID == "moonshot-responses")
        #expect(respModel.descriptor.compatibility?.sanitizer == "moonshot")
    }

    @Test("ZAI and ZAICodingPlan routes, configure, models, and imageModel")
    func zaiAndZaiCodingPlanCompletions() {
        #expect(AIProviders.ZAI.provider.id == "zai")
        #expect(AIProviders.ZAI.routes.map(\.id) == ["zai-chat"])

        let zaiChat = AIProviders.ZAI.chat("glm-5")
        #expect(zaiChat.descriptor.routeID == "zai-chat")
        #expect(zaiChat.descriptor.baseURL == "https://api.z.ai/api/paas/v4")

        let zaiModel = AIProviders.ZAI.model("glm-5", settings: .init(baseURL: "https://custom.z.ai/v4"))
        #expect(zaiModel.descriptor.baseURL == "https://custom.z.ai/v4")

        let zaiImg = AIProviders.ZAI.image("cogview-4")
        #expect(zaiImg.provider == "zai")
        #expect(zaiImg.path == AIProtocols.ZAIImages.PATH)

        let zaiImgCustom = AIProviders.ZAI.imageModel("cogview-4", settings: .init(baseURL: "https://img.z.ai/v4"))
        #expect(zaiImgCustom.baseURL == "https://img.z.ai/v4")

        #expect(AIProviders.ZAICodingPlan.provider.id == "zai-coding-plan")
        #expect(AIProviders.ZAICodingPlan.routes.map(\.id) == ["zai-coding-chat", "zai-coding-messages", "zai-coding-responses"])

        let codingChat = AIProviders.ZAICodingPlan.chat("glm-5")
        #expect(codingChat.descriptor.baseURL == "https://api.z.ai/api/coding/paas/v4")

        let codingMsg = AIProviders.ZAICodingPlan.messages("glm-5")
        #expect(codingMsg.descriptor.baseURL == "https://api.z.ai/api/anthropic/v1")
        #expect(codingMsg.descriptor.compatibility?.requireSignature == false)

        let codingResp = AIProviders.ZAICodingPlan.responses("glm-5")
        #expect(codingResp.descriptor.baseURL == "https://api.z.ai/api/v1")
    }

    @Test("CloudflareAIGateway passthrough routing, ID normalization, cf-aig-authorization, and decisionModel")
    func cloudflareAIGatewayCompletions() throws {
        #expect(AIProviders.CloudflareAIGateway.provider.id == "cloudflare-ai-gateway")
        #expect(AIProviders.CloudflareAIGateway.routes.map(\.id) == [
            "cloudflare-ai-gateway-responses",
            "cloudflare-ai-gateway-messages",
            "cloudflare-ai-gateway-chat",
        ])

        let settings = AIProviders.ProviderConfig(
            accountId: "acct-123",
            gatewayId: "my-gw",
            gatewayApiKey: "cf-secret"
        )

        let openaiModel = try AIProviders.CloudflareAIGateway.model("openai/gpt-5", settings: settings)
        #expect(openaiModel.descriptor.id == "gpt-5")
        #expect(openaiModel.descriptor.routeID == "cloudflare-ai-gateway-responses")
        #expect(openaiModel.descriptor.baseURL == "https://gateway.ai.cloudflare.com/v1/acct-123/my-gw/openai")
        let openaiReq = try openaiModel.prepareRequest(messages: [.user("hi")])
        #expect(openaiReq.headers["cf-aig-authorization"] == "Bearer cf-secret")

        let anthropicModel = try AIProviders.CloudflareAIGateway.model("anthropic/claude-sonnet-4.5", settings: settings)
        #expect(anthropicModel.descriptor.id == "claude-sonnet-4-5")
        #expect(anthropicModel.descriptor.routeID == "cloudflare-ai-gateway-messages")
        #expect(anthropicModel.descriptor.baseURL == "https://gateway.ai.cloudflare.com/v1/acct-123/my-gw/anthropic/v1")
        let anthropicReq = try anthropicModel.prepareRequest(messages: [.user("hi")])
        #expect(anthropicReq.headers["cf-aig-authorization"] == "Bearer cf-secret")

        let workersModel = try AIProviders.CloudflareAIGateway.model("workers-ai/@cf/meta/llama-3.3", settings: settings)
        #expect(workersModel.descriptor.id == "@cf/meta/llama-3.3")
        #expect(workersModel.descriptor.routeID == "cloudflare-ai-gateway-chat")
        #expect(workersModel.descriptor.baseURL == "https://api.cloudflare.com/client/v4/accounts/acct-123/ai/v1")
        let workersReq = try workersModel.prepareRequest(messages: [.user("hi")])
        #expect(workersReq.headers["cf-aig-gateway-id"] == "my-gw")
        #expect(workersReq.headers["authorization"] == "Bearer cf-secret")

        // Custom baseURL preserves provider-prefixed model IDs verbatim
        let customBase = AIProviders.ProviderConfig(apiKey: .explicit("tok"), baseURL: "https://custom.cf.dev/ai/v1")
        let customAnthropic = try AIProviders.CloudflareAIGateway.messages("anthropic/claude-sonnet-4.5", settings: customBase)
        #expect(customAnthropic.descriptor.id == "anthropic/claude-sonnet-4.5")
        #expect(customAnthropic.descriptor.baseURL == "https://custom.cf.dev/ai/v1")

        let decision = try AIProviders.CloudflareAIGateway.decisionModel("@cf/baai/bge-reranker", settings: settings)
        #expect(decision.protocolID == "cloudflare-run-decisions")
        #expect(decision.baseURL == "https://api.cloudflare.com/client/v4/accounts/acct-123/ai/run")
        #expect(decision.path == "/@cf/baai/bge-reranker")
    }

    @Test("OpenAICompatible imageModel defaults response_format to b64_json except for gpt-image/chatgpt-image")
    func openAICompatibleImageModelDefaults() {
        let base = AIProviders.ProviderConfig(baseURL: "https://compat.example/v1")
        let flux = AIProviders.OpenAICompatible.imageModel("flux-pro", settings: base)
        #expect(flux.providerOptions?["response_format"] == .string("b64_json"))

        let gptImage = AIProviders.OpenAICompatible.imageModel("gpt-image-1", settings: base)
        #expect(gptImage.providerOptions?["response_format"] == nil)

        let chatgptImage = AIProviders.OpenAICompatible.imageModel("chatgpt-image-latest", settings: base)
        #expect(chatgptImage.providerOptions?["response_format"] == nil)

        let dropped = AIProviders.OpenAICompatible.imageModel(
            "custom-proxy-image",
            settings: .init(baseURL: "https://compat.example/v1", providerOptions: ["response_format": .null])
        )
        #expect(dropped.providerOptions?["response_format"] == nil)
    }
}

@Suite("Wave 2 R1 Protocols, Freeform Streaming, Partial JSON & Runtime Completions")
struct AIProtocolAndRuntimeGapCompletionsTests {
    @Test("OpenAIFreeform streamStart, streamDelta, close, metadata, and keepsItemID")
    func openAIFreeformStreaming() {
        let custom = AIProtocols.OpenAIFreeform.Custom(field: "patch", format: .text)
        #expect(AIProtocols.OpenAIFreeform.streamDelta("line1\n\"quoted\"") == #"line1\n\"quoted\""#)
        #expect(AIProtocols.OpenAIFreeform.streamStart(custom, raw: "abc") == #"{"patch":"abc"#)
        #expect(AIProtocols.OpenAIFreeform.streamStart(nil, raw: "") == #"{"input":""#)

        let customMeta = AIProtocols.OpenAIFreeform.metadata(itemId: "ctc_1", custom: true)
        #expect(customMeta == ["itemId": .string("ctc_1"), "custom": .bool(true)])
        let fnMeta = AIProtocols.OpenAIFreeform.metadata(itemId: "fc_1", custom: false)
        #expect(fnMeta == ["itemId": .string("fc_1")])

        #expect(AIProtocols.OpenAIFreeform.keepsItemID(providerMetadata: ["openai": customMeta], key: "openai", custom: true))
        #expect(!AIProtocols.OpenAIFreeform.keepsItemID(providerMetadata: ["openai": customMeta], key: "openai", custom: false))
        #expect(AIProtocols.OpenAIFreeform.keepsItemID(providerMetadata: ["openai": fnMeta], key: "openai", custom: false))

        let startedTools = AIProtocolUtils.ToolStream.start(
            [:],
            key: 0,
            tool: .init(
                id: "call_1",
                name: "apply_patch",
                input: AIProtocols.OpenAIFreeform.streamStart(custom, raw: "hello")
            )
        )
        let mismatch = AIProtocols.OpenAIFreeform.close(
            tools: startedTools,
            keys: [0],
            final: (custom: custom, raw: "different")
        )
        #expect(mismatch.events.isEmpty)

        let matched = AIProtocols.OpenAIFreeform.close(
            tools: startedTools,
            keys: [0],
            final: (custom: custom, raw: "hello")
        )
        #expect(matched.events.count == 1)
        #expect(matched.tools[0]?.input == #"{"patch":"hello"}"#)
    }

    @Test("PartialJSONOptions bitmask flags and Allow struct match upstream exactly")
    func partialJSONOptionsFlags() {
        typealias Opts = AIProtocolUtils.PartialJSONOptions
        #expect(Opts.STR == 0b000000001)
        #expect(Opts.NUM == 0b000000010)
        #expect(Opts.ARR == 0b000000100)
        #expect(Opts.OBJ == 0b000001000)
        #expect(Opts.NULL == 0b000010000)
        #expect(Opts.BOOL == 0b000100000)
        #expect(Opts.NAN == 0b001000000)
        #expect(Opts.INFINITY == 0b010000000)
        #expect(Opts._INFINITY == 0b100000000)
        #expect(Opts.INF == (Opts.INFINITY | Opts._INFINITY))
        #expect(Opts.SPECIAL == (Opts.NULL | Opts.BOOL | Opts.INF | Opts.NAN))
        #expect(Opts.ATOM == (Opts.STR | Opts.NUM | Opts.SPECIAL))
        #expect(Opts.COLLECTION == (Opts.ARR | Opts.OBJ))
        #expect(Opts.ALL == (Opts.ATOM | Opts.COLLECTION))
        #expect(Opts.ALL == 0b111111111)

        let allow = Opts.Allow
        #expect(allow.STR == Opts.STR)
        #expect(allow.OBJ == Opts.OBJ)
        #expect(allow.SPECIAL == Opts.SPECIAL)
        #expect(allow.COLLECTION == Opts.COLLECTION)
        #expect(allow.ALL == Opts.ALL)
    }

    @Test("SeedanceVideo registry, ProviderShared, OpenResponsesOptions, ToolFailure, and AILLM.canCompact")
    func protocolExportsAndCanCompact() throws {
        let volc = AIProtocols.SeedanceVideo.SeedanceVideo.volcengine.model(.init(id: "seedance-1-pro"))
        #expect(volc.provider == "volcengine")
        #expect(volc.baseURL == AIProtocols.SeedanceVideo.VOLCENGINE_BASE_URL)
        #expect(volc.path == AIProtocols.SeedanceVideo.PATH)

        let bp = AIProtocols.SeedanceVideo.SeedanceVideo.byteplus.model(.init(id: "seedance-1-lite"))
        #expect(bp.provider == "byteplus")
        #expect(bp.baseURL == AIProtocols.SeedanceVideo.BYTEPLUS_BASE_URL)

        let encoded = try AIProtocolUtils.ProviderShared.encodeJson(.object(["ok": .bool(true)]))
        let decoded = try AIProtocolUtils.ProviderShared.decodeJson(encoded)
        #expect(AIProtocolUtils.ProviderShared.isRecord(decoded))
        #expect(!AIProtocolUtils.ProviderShared.isRecord(.array([])))
        let jsonCodec = AIProtocolUtils.ProviderShared.Json()
        #expect(try jsonCodec.decode(encoded) == decoded)

        #expect(AIProtocolUtils.OpenResponsesOptions.ReasoningEfforts == ["none", "minimal", "low", "medium", "high", "xhigh", "max"])
        let effort: AIProtocolUtils.OpenResponsesOptions.ReasoningEffort = .high
        #expect(effort.rawValue == "high")

        let failure = AITool.ToolFailure(message: "boom")
        #expect(failure.message == "boom")

        let dummyRoute = AIRoute.AnyRoute(
            id: "test-route",
            provider: AISchema.ProviderID.make("test"),
            protocolID: "test-proto",
            buildBody: { _ in .object([:]) },
            executeStream: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )
        let nonCompactModel = AISchema.LanguageModel.make(.init(id: "m1", provider: "test", route: dummyRoute))
        #expect(!AILLM.canCompact(nonCompactModel))

        let compactableRoute = AIRoute.AnyRoute(
            compact: AIRoute.CompactionOperations(
                endpoint: { _, _, _ in
                    AISchema.CompactionResponse(replacement: [])
                }
            ),
            id: "test-compact-route",
            provider: AISchema.ProviderID.make("test"),
            protocolID: "test-proto",
            buildBody: { _ in .object([:]) },
            executeStream: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )
        let compactModel = AISchema.LanguageModel.make(.init(id: "m2", provider: "test", route: compactableRoute))
        #expect(AILLM.canCompact(compactModel))
        #expect(AILLM.canCompact(compactModel, mechanism: "endpoint"))
        #expect(!AILLM.canCompact(compactModel, mechanism: "trigger"))
    }

    @Test("Schema, Asset, VideoResponse, Util errors, and ProcessDaemon gap completions")
    func classMethodsAndCrossPackageCompletions() async throws {
        let usage = AISchema.Usage(outputTokens: 100, reasoningTokens: 40)
        #expect(usage.visibleOutputTokens == 60)
        let clampedUsage = AISchema.Usage(outputTokens: 10, reasoningTokens: 25)
        #expect(clampedUsage.visibleOutputTokens == 0)

        let rateLimitErr = AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
            message: "slow down",
            http: AISchema.HttpContext(url: "https://api.example.com/v1/chat", status: 429, headers: [:]),
            retryAfterMs: 1500
        )))
        #expect(rateLimitErr.message == "slow down")
        #expect(rateLimitErr.status == 429)
        #expect(rateLimitErr.retryAfterMs == 1500)
        #expect(rateLimitErr.isRetryable)

        let asset = AIMedia.bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(asset.inline()?.mime == "image/png")
        #expect(try await asset.dataUrl().hasPrefix("data:image/png;base64,"))
        #expect(asset.toJSON().source == asset.source)
        #expect(try await asset.materialize() == asset)

        let videoResp = AIVideo.VideoResponse(videos: [asset])
        #expect(videoResp.video == asset)

        #expect(FSPathUtil.FileSystemError(method: "readFile", detail: "ENOENT").message == "Filesystem operation failed: readFile: ENOENT")
        #expect(NpmSpec.InstallFailedError(add: ["foo"], dir: "/d", causeMessage: "bad").message == "Failed to install foo: bad")
        #expect(Patch.BoundaryError(boundary: .first).message.contains("*** Begin Patch"))
        #expect(Patch.InvalidHunkError(line: "??", lineNumber: 3).message.contains("line 3"))
        #expect(AppProcess.AppProcessError(command: "ls", exitCode: 2, stderr: "nope").message == "Command failed (exit 2): ls: nope")

        #expect(EventManifestSchema.Durable.isEmpty == false)
        #expect(SessionEventSchema.Tool.Input.Started.type == "session.tool.input.started")
        #expect(SessionEventSchema.Tool.Input.Delta.type == "session.tool.input.delta")
        #expect(SessionEventSchema.Tool.Input.Ended.type == "session.tool.input.ended")

        let effects = ProcessDaemon.Ghostty.Effects()
        ProcessDaemon.Ghostty.Effects.write_pty(nil, userdata: effects, data: [0x41, 0x42])
        ProcessDaemon.Ghostty.Effects.title_changed(nil, userdata: effects)
        #expect(effects.take_writes() == [[0x41, 0x42]])
        #expect(effects.take_title_changed())
        #expect(!effects.take_title_changed())

        #expect(throws: ProcessDaemon.DaemonError.self) {
            _ = try ProcessDaemon.TerminalClient.startNonUnix("/tmp/nonunix")
        }
        #expect(ProcessDaemon.MuslCompat.statx(path: "/") == 0)
        #expect(ProcessDaemon.MuslCompat.statx(path: "/opencode-pty-definitely-missing-path") == -1)
    }
}
