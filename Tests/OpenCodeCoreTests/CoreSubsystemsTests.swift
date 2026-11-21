import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("OpenCodeCore Subsystems")
struct CoreSubsystemsTests {

    // MARK: - 1. Providers, Models, Variants, Resolution & Retry

    @Test("AISDKNative rewriting, header merge, and native provider mapping")
    func aisdkNativeMapping() {
        #expect(CoreProvider.AISDKNative.isAISDK("aisdk:@ai-sdk/openai"))
        #expect(!CoreProvider.AISDKNative.isAISDK("@opencode/ai/providers/openai"))
        #expect(CoreProvider.AISDKNative.aisdk("@ai-sdk/openai") == "aisdk:@ai-sdk/openai")
        #expect(CoreProvider.AISDKNative.aisdk("aisdk:@ai-sdk/openai") == "aisdk:@ai-sdk/openai")
        #expect(CoreProvider.AISDKNative.packageName("aisdk:@ai-sdk/openai") == "@ai-sdk/openai")
        #expect(CoreProvider.AISDKNative.packageName("@opencode-ai/ai/providers/openai") == "@opencode/ai/providers/openai")

        let headers = CoreProvider.AISDKNative.mergeHeaders(
            ["Authorization": "Bearer old", "X-Custom": "1"],
            ["authorization": "Bearer new"]
        )
        #expect(headers?.count == 2)
        #expect(headers?["authorization"] == "Bearer new")
        #expect(headers?["X-Custom"] == "1")

        let merged = CoreProvider.AISDKNative.mergeOverlay(
            ["a": .object(["x": .int(1), "y": .int(2)])],
            ["a": .object(["y": .int(99), "z": .bool(true)])]
        )
        #expect(merged == ["a": .object(["x": .int(1), "y": .int(99), "z": .bool(true)])])

        #expect(CoreProvider.AISDKNative.native(npm: "@ai-sdk/azure", providerID: "azure", useCompletionUrls: true) == "@opencode/ai/providers/azure/chat")
        #expect(CoreProvider.AISDKNative.native(npm: "@ai-sdk/amazon-bedrock/mantle", providerID: "bedrock", modelID: "anthropic.claude-4") == "@opencode/ai/providers/amazon-bedrock/mantle/messages")
        #expect(CoreProvider.AISDKNative.native(npm: "@ai-sdk/openai-compatible", providerID: "deepseek") == "@opencode/ai/providers/deepseek")

        let rewritten = CoreProvider.AISDKNative.rewrite(
            specifier: "aisdk:@ai-sdk/openai-compatible",
            providerID: "custom-host",
            settings: ["baseURL": .string("https://api.example.com")]
        )
        #expect(rewritten.package == "@opencode/ai/providers/openai-compatible")
        #expect(rewritten.settings?["provider"] == .string("custom-host"))
    }

    @Test("Model variant resolution across OpenAI Responses, Anthropic, Gemini, and Bedrock")
    func variantResolution() {
        let reasoning = ConfigProviderSchema.Reasoning.supported(
            toggle: true,
            effort: ["default", "low", "high"],
            budget: nil
        )
        let supports = CoreModel.Variant.supports(reasoning)
        #expect(supports.contains(.toggle))
        #expect(supports.contains(.effort(values: ["low", "high"])))

        let claude = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "claude-opus-4-6"),
            modelID: ModelSchema.ID(rawValue: "claude-opus-4-6"),
            providerID: ProviderSchema.ID.anthropic,
            name: "Claude Opus",
            package: "@opencode/ai/providers/anthropic",
            capabilities: ModelSchema.Capabilities.default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 1),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 200_000, output: 16_000)
        )
        let claudeVariants = CoreModel.Variant.resolve(claude, supports: supports)
        #expect(claudeVariants.map(\.id.rawValue) == ["none", "low", "high"])

        let openai = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5"),
            modelID: ModelSchema.ID(rawValue: "gpt-5"),
            providerID: ProviderSchema.ID.openai,
            name: "GPT-5",
            package: "@opencode/ai/providers/openai",
            capabilities: ModelSchema.Capabilities.default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 2),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 200_000, output: 16_000)
        )
        let openaiVariants = CoreModel.Variant.resolve(openai, supports: [.effort(values: nil)])
        #expect(openaiVariants.map(\.id.rawValue) == ["none", "minimal", "low", "medium", "high", "xhigh"])
    }

    @Test("Model resolution with variant overlays, env substitution, credentials, and fallback")
    func modelResolutionAndFallback() async throws {
        let providers = CoreProvider.Provider.Service()
        let variants = [
            ModelSchema.Variant(
                id: ModelSchema.VariantID(rawValue: "high"),
                settings: ModelSchema.VariantSettings(extra: ["reasoningEffort": .string("high"), "cache": .string("ignored")]),
                headers: ["x-variant": "high"],
                body: ["temperature": .double(0.2)]
            ),
        ]
        let modelA = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5"),
            modelID: ModelSchema.ID(rawValue: "gpt-5-2026"),
            providerID: ProviderSchema.ID.openai,
            family: ModelSchema.Family(rawValue: "gpt-5"),
            name: "GPT-5",
            package: "@opencode/ai/providers/openai",
            settings: ModelSchema.Settings(extra: ["baseURL": .string("https://${CUSTOM_HOST}/v1")]),
            headers: ["x-base": "1"],
            capabilities: ModelSchema.Capabilities.default(),
            variants: variants,
            time: ModelSchema.Info.Time(released: 100),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 128_000, output: 16_000)
        )
        let smallModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-luna-mini"),
            modelID: ModelSchema.ID(rawValue: "gpt-luna-mini"),
            providerID: ProviderSchema.ID.openai,
            family: ModelSchema.Family(rawValue: "gpt-luna"),
            name: "GPT Luna",
            package: "@opencode/ai/providers/openai",
            capabilities: ModelSchema.Capabilities.default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 50),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 64_000, output: 8_000)
        )

        _ = try await providers.transform { editor in
            editor.add(
                info: ProviderSchema.Info(id: .openai, name: "OpenAI", activation: .enabled, package: "@opencode/ai/providers/openai"),
                models: [modelA, smallModel]
            )
        }
        let models = CoreModel.Model.Service(providers: providers)
        let small = try await models.small(providerID: .openai)
        #expect(small?.id.rawValue == "gpt-luna-mini")

        // Unresolved variable throws typed UnresolvedProviderVariablesError
        #expect(throws: CoreModel.Resolver.UnresolvedProviderVariablesError.self) {
            _ = try CoreModel.Resolver.resolveModel(
                modelA,
                variant: ModelSchema.VariantID(rawValue: "high"),
                dependencies: CoreModel.Resolver.Dependencies(environment: MockSubsystemsEnv())
            )
        }

        // Unknown variant throws VariantUnavailableError
        #expect(throws: CoreModel.Resolver.VariantUnavailableError.self) {
            _ = try CoreModel.Resolver.withVariant(modelA, variantID: ModelSchema.VariantID(rawValue: "nonexistent"))
        }

        // Resolved with env + credential + variant overlay (and cache stripped from variant)
        let env = MockSubsystemsEnv(vars: ["CUSTOM_HOST": "api.openai.internal"])
        let resolver = CoreModel.Resolver.Service(
            providers: providers,
            models: models,
            dependencies: CoreModel.Resolver.Dependencies(environment: env)
        )
        let resolved = try #require(try await resolver.resolve(
            ModelSchema.Ref(id: modelA.id, providerID: .openai, variant: ModelSchema.VariantID(rawValue: "high"))
        ))
        #expect(resolved.model.id == "gpt-5-2026")
        #expect(resolved.model.baseURL == "https://api.openai.internal/v1")
        #expect(resolved.model.headers["x-variant"] == "high")
        #expect(resolved.model.headers["x-base"] == "1")
        #expect(resolved.model.settings["reasoningEffort"] == .string("high"))
        #expect(resolved.model.settings["cache"] == nil)

        // Fallback picks highest-released enabled chat model when no default configured
        let fallback = try await resolver.fallback()
        #expect(fallback?.id == modelA.id)
    }

    @Test("ModelRetry exponential backoff, Retry-After floor, timeout cap, and one-shot filter")
    func modelRetryPolicies() async throws {
        let unreachErr = AISchema.AIError(
            reason: .transport(AISchema.TransportError(
                message: "host unreachable",
                transport: .http,
                operation: .request,
                code: "ENOTFOUND"
            ))
        )
        #expect(CoreModel.Retry.isUnreachable(unreachErr))

        let rateLimitErr = AISchema.AIError(
            reason: .rateLimit(AISchema.RateLimitError(message: "429", retryAfterMs: 12_000))
        )
        let policy = CoreModel.Retry.policy(jitter: { 1.0 })
        let d1 = try #require(policy.next(cause: rateLimitErr, retry: true))
        #expect(d1.retry)
        #expect(d1.delayMs == 12_000)

        // Retry succeeds on 3rd attempt
        let attempts = AtomicCounter()
        let sleeps = AtomicBox<[Int]>([])
        let result = try await CoreModel.Retry.retry(
            policy: CoreModel.Retry.policy(jitter: { 1.0 }),
            sleep: { ms in sleeps.modify { $0.append(ms) } }
        ) {
            let n = attempts.increment()
            if n < 3 { throw rateLimitErr }
            return "ok-\(n)"
        }
        #expect(result == "ok-3")
        #expect(sleeps.get() == [12_000, 12_000])

        // One-shot does NOT retry a non-overload 500 internal error
        let internal500 = AISchema.AIError(
            reason: .providerInternal(AISchema.ProviderInternalError(
                message: "boom",
                http: AISchema.HttpContext(url: "https://api.example.com", status: 500, headers: [:])
            ))
        )
        let oneShotAttempts = AtomicCounter()
        await #expect(throws: AISchema.AIError.self) {
            _ = try await CoreModel.Retry.retryOneShot(sleep: { _ in }) {
                oneShotAttempts.increment()
                throw internal500
            }
        }
        #expect(oneShotAttempts.value == 1)
    }

    @Test("ModelsDev v1->v2 catalog conversion and Copilot routeFor / autoModel")
    func modelsDevAndCopilot() throws {
        let v1JSON = """
        {
          "openai": {
            "id": "openai",
            "name": "OpenAI",
            "env": ["OPENAI_API_KEY"],
            "npm": "@ai-sdk/openai",
            "models": {
              "gpt-5": {
                "id": "gpt-5",
                "name": "GPT-5",
                "release_date": "2026-01-01",
                "tool_call": true,
                "reasoning": true,
                "limit": { "context": 200000, "output": 32000 }
              }
            }
          }
        }
        """
        let raw = try CoreSubsystemsTestJSON.decode([String: JSONValue].self, from: Array(v1JSON.utf8))
        #expect(CoreModel.ModelsDev.V1.isV1(raw))
        let snaps = try CoreModel.ModelsDev.decodeSnapshot(v1JSON)
        #expect(snaps.count == 1)
        #expect(snaps[0].info.package == "@opencode/ai/providers/openai")
        #expect(snaps[0].models.first?.id.rawValue == "gpt-5")

        let gpt5Route = CoreModel.CopilotModels.routeFor(modelID: "gpt-5.2", advertised: nil, root: "https://api.githubcopilot.com")
        #expect(gpt5Route.endpoint == .responses)
        #expect(gpt5Route.baseURL == "https://api.githubcopilot.com")

        let miniRoute = CoreModel.CopilotModels.routeFor(modelID: "gpt-5-mini", advertised: nil, root: "https://api.githubcopilot.com")
        #expect(miniRoute.endpoint == .chat)

        let claudeRoute = CoreModel.CopilotModels.routeFor(modelID: "claude-sonnet-4", advertised: .messages, root: "https://api.githubcopilot.com")
        #expect(claudeRoute.baseURL == "https://api.githubcopilot.com/v1")
        #expect(claudeRoute.package == "@opencode/ai/providers/anthropic")

        let remoteSnap: CoreModel.CopilotModels.Snapshot = [
            "gpt-5": CoreModel.CopilotModels.RemoteModel(
                modelPickerEnabled: true,
                id: "gpt-5",
                name: "GPT-5",
                version: "gpt-5-2026-01-01",
                billing: .init(autoDiscount: 0.9),
                capabilities: .init(
                    family: "gpt-5",
                    limits: .init(maxContextWindowTokens: 128_000, maxOutputTokens: 16_000, maxPromptTokens: 100_000),
                    supports: .init(toolCalls: true, vision: true)
                )
            ),
        ]
        let auto = try #require(CoreModel.CopilotModels.autoModel(baseURL: "https://api.githubcopilot.com", remote: remoteSnap))
        #expect(auto.id == CoreModel.CopilotModels.auto)
        #expect(auto.limit.context == 128_000)
    }

    @Test("Credential store lifecycle, ConsoleAccess legacy rewrite, and OAuth page/redirect")
    func credentialsConsoleAndOAuth() async throws {
        let store = try CoreProvider.Credential.Service.inMemory()
        let intID = IntegrationID(rawValue: "opencode")
        let c1 = try await store.create(
            integrationID: intID,
            value: .key(CredentialSchema.Key(key: "sk-1", metadata: ["server": .string("https://console.opencode.ai/team"), "orgID": .string("org_42")])),
            label: "first"
        )
        let c2 = try await store.create(
            integrationID: intID,
            value: .oauth(CredentialSchema.OAuth(
                methodID: IntegrationMethodID(rawValue: "oauth"),
                refresh: "r-1",
                access: "a-1",
                expires: SchemaPrimitive.NonNegativeInt(rawValue: 1_000)!
            )),
            label: "second"
        )
        #expect(try await store.list(intID).count == 2)
        #expect(CoreProvider.ConsoleAccess.server(c1.value) == "https://opencode.ai/console/team")
        #expect(CoreProvider.ConsoleAccess.headers(c1.value) == ["authorization": "Bearer sk-1", "x-org-id": "org_42"])
        #expect(CoreProvider.Credential.expiring(
            CredentialSchema.OAuth(methodID: IntegrationMethodID(rawValue: "m"), refresh: "r", access: "a", expires: SchemaPrimitive.NonNegativeInt(rawValue: 10_000)!),
            now: 9_000
        ))

        // Refresh updates stored OAuth token
        let updated = try await store.refresh(
            c2.id,
            stale: { _, _ in true },
            refresh: { cur in
                CredentialSchema.OAuth(methodID: cur.methodID, refresh: "r-2", access: "a-2", expires: SchemaPrimitive.NonNegativeInt(rawValue: 99_999)!)
            }
        )
        #expect(updated?.access == "a-2")
        try await store.remove(c2.id)
        #expect(try await store.list(intID).count == 1)

        let html = CoreProvider.OAuthPage.success(.init(provider: "Acme <Test>"))
        #expect(html.contains("Acme &lt;Test&gt;"))
        #expect(html.contains("data-status=\"success\""))

        let pasted = try CoreProvider.OAuthRedirect.pasted(
            text: "http://127.0.0.1:4321/callback?code=abc123&state=st_1",
            state: "st_1"
        )
        if case .code(let code, _) = pasted {
            #expect(code == "abc123")
        } else {
            Issue.record("Expected .code result")
        }
    }

    // MARK: - 2. Agents, Skills, and Instruction Discovery

    @Test("Agent registry default selection ignores hidden and subagent entries")
    func agentDiscoveryAndSelection() async throws {
        let service = CoreAgent.Agent.Service()
        _ = try await service.transform { editor in
            editor.update(CoreAgent.Agent.ID(rawValue: "helper")) { base in
                AgentSchema.Info(
                    id: base.id, name: .init(rawValue: "Helper"), request: base.request,
                    mode: .subagent, hidden: false, permissions: []
                )
            }
            editor.update(CoreAgent.Agent.ID(rawValue: "secret")) { base in
                AgentSchema.Info(
                    id: base.id, name: .init(rawValue: "Secret"), request: base.request,
                    mode: .primary, hidden: true, permissions: []
                )
            }
            editor.update(CoreAgent.Agent.defaultID) { base in
                AgentSchema.Info(
                    id: base.id, name: .init(rawValue: "Build"), request: base.request,
                    mode: .primary, hidden: false, permissions: []
                )
            }
            editor.setDefault(CoreAgent.Agent.ID(rawValue: "helper"))
        }
        let selected = await service.select(nil)
        #expect(selected.id == CoreAgent.Agent.defaultID)
        #expect(selected.info?.name.rawValue == "Build")
        let ordered = await service.list()
        #expect(ordered.first?.id == CoreAgent.Agent.defaultID)
    }

    @Test("Instruction discovery, preferAgents shadowing, diffing, and delta updates")
    func instructionDiscoveryAndDiffing() async throws {
        #expect(CoreInstruction.Discovery.filenames(claude: true) == ["AGENTS.md", "CLAUDE.md"])
        #expect(CoreInstruction.Discovery.filenames(claude: false) == ["AGENTS.md"])

        let filtered = CoreInstruction.Discovery.preferAgents([
            "/repo/AGENTS.md",
            "/repo/CLAUDE.md",
            "/repo/sub/CLAUDE.md",
        ])
        #expect(filtered == ["/repo/AGENTS.md", "/repo/sub/CLAUDE.md"])

        let memFS = InMemoryFileSystem(initialFiles: [
            "/repo/AGENTS.md": Array("Root rules".utf8),
            "/repo/CLAUDE.md": Array("Shadowed".utf8),
            "/repo/sub/CLAUDE.md": Array("Sub rules".utf8),
        ])
        let discovery = CoreInstruction.Discovery.Service()
        let found = await discovery.discoverFiles(directory: "/repo/sub", stopDirectory: "/repo", fileSystem: memFS)
        #expect(found.map(\.path) == ["/repo/sub/CLAUDE.md", "/repo/AGENTS.md"])

        // Instructions make / combine / read / diff / renderInitial / renderUpdate
        let keyA = try #require(CoreInstruction.Instructions.Key(rawValue: "core/a"))
        let listA = CoreInstruction.Instructions.make(CoreInstruction.Instructions.Source.Definition<String>(
            key: keyA,
            read: { .value("v1") },
            renderInitial: { "Init: \($0)" },
            renderChanged: { prev, curr in "Changed: \(prev) -> \(curr)" },
            renderRemoved: { prev in "Removed: \(prev)" }
        ))
        // Duplicate keys rejected
        #expect(throws: CoreInstruction.Instructions.DuplicateKeyError.self) {
            _ = try CoreInstruction.Instructions.combine([listA, listA])
        }

        let obs = await CoreInstruction.Instructions.read(listA)
        let admission = try CoreInstruction.Instructions.diff(observed: obs)
        let hashes = CoreInstruction.Instructions.applyHashDelta(CoreInstruction.Instructions.Values(), delta: admission.delta)
        #expect(hashes.entries[keyA.rawValue] != nil)

        let rendered = CoreInstruction.Instructions.renderInitial(listA, values: [keyA.rawValue: .string("v1")])
        #expect(CoreInstruction.Instructions.join(rendered) == "Init: v1")

        let updateText = CoreInstruction.Instructions.renderUpdate(
            listA,
            previous: [keyA.rawValue: .string("v1")],
            delta: [keyA.rawValue: .string("v2")]
        )
        #expect(updateText == "Changed: v1 -> v2")
    }

    @Test("Skill registry, path traversal safety, remote pull, and SkillInstructions XML")
    func skillRegistryAndDiscovery() async throws {
        #expect(CoreSkill.Discovery.isSafeSegment("my-skill"))
        #expect(!CoreSkill.Discovery.isSafeSegment(".."))
        #expect(!CoreSkill.Discovery.isSafeSegment("a/b"))
        #expect(CoreSkill.Discovery.isSafeRelativePath("scripts/run.sh"))
        #expect(!CoreSkill.Discovery.isSafeRelativePath("../escape.txt"))
        #expect(!CoreSkill.Discovery.isSafeRelativePath("https://evil.test/x"))
        #expect(!CoreSkill.Discovery.isSafeRelativePath("C:/Windows/win.ini"))
        #expect(!CoreSkill.Discovery.isSafeRelativePath("%2e%2e/secret"))

        let memFS = InMemoryFileSystem()
        let http = MockSubsystemsHTTPTransport { req in
            if req.url.hasSuffix("/index.json") {
                return try CoreSubsystemsTestJSON.jsonResponse(body: .object([
                    "skills": .array([
                        .object([
                            "name": .string("swift-helper"),
                            "version": .string("1.0.0"),
                            "files": .array([.string("SKILL.md"), .string("ref.md")]),
                        ]),
                        .object([
                            "name": .string("../bad"),
                            "files": .array([.string("SKILL.md")]),
                        ]),
                    ]),
                ]))
            }
            return CoreSubsystemsTestJSON.textResponse(body: "# Skill body for \(req.url)")
        }
        let disc = CoreSkill.Discovery.Service(fileSystem: memFS, transport: http, cacheRoot: "/cache")
        let pulled = await disc.pull(url: "https://skills.example.com/registry")
        #expect(pulled.count == 1)
        #expect(await memFS.exists(at: "\(pulled[0].rawValue)/SKILL.md"))
        #expect(await memFS.exists(at: "\(pulled[0].rawValue)/.opencode-version"))

        let skills = CoreSkill.Service()
        let s1 = SkillSchema.Info(
            id: .init(rawValue: "s1"),
            name: .init(rawValue: "Build Skill"),
            description: "Helps build Swift projects",
            path: SchemaPrimitive.AbsolutePath(rawValue: "skill://s1"),
            content: "Run swift build"
        )
        let s2 = SkillSchema.Info(
            id: .init(rawValue: "s2"),
            name: .init(rawValue: "Denied Skill"),
            description: "Should be hidden by permission",
            path: SchemaPrimitive.AbsolutePath(rawValue: "/skills/s2/SKILL.md"),
            content: "Secret"
        )
        _ = try await skills.transform { editor in
            editor.add(s1, files: ["scripts/build.sh": "swift build"])
            editor.add(s2)
        }
        let prepared = await CoreSkill.prepare(skill: s1, virtualFiles: ["scripts/build.sh": "swift build", "SKILL.md": "ignored"])
        #expect(prepared.directory == "skill://s1")
        #expect(prepared.output.contains("<file>skill://s1/scripts/build.sh</file>"))

        let skillInstr = CoreSkill.SkillInstructions.Service(skills: skills)
        let sources = await skillInstr.load(permissions: [
            PermissionSchema.Rule(action: "skill", resource: "s2", effect: .deny),
        ])
        let obs = await CoreInstruction.Instructions.read(sources)
        guard case .value(let jsonVal) = obs.first?.value else {
            Issue.record("Expected skill guidance value")
            return
        }
        let rendered = CoreInstruction.Instructions.renderInitial(sources, values: ["core/skill-guidance": jsonVal])
        let text = CoreInstruction.Instructions.join(rendered)
        #expect(text.contains("<id>s1</id>"))
        #expect(!text.contains("<id>s2</id>"))
    }

    // MARK: - 3. MCP Client, JSON-RPC Framing, Transports & Integrations

    @Test("MCP JSON-RPC 2.0 framing, Stdio chunk parsing, and SocketClient buffering")
    func mcpFramingStdioAndSocket() async throws {
        // Round-trip request & notification line framing
        let req = CoreMCP.JSONRPCMessage.request(CoreMCP.JSONRPCRequest(
            id: .int(7),
            method: "tools/call",
            params: .object(["name": .string("echo")])
        ))
        let encoded = try CoreMCP.JSONRPCMessage.encodeLine(req)
        #expect(encoded.hasSuffix("\n"))
        let decoded = try CoreMCP.JSONRPCMessage.decodeLine(encoded)
        #expect(decoded == req)

        // Stdio resolveCwd & incremental CRLF chunk feeding
        #expect(CoreMCP.Stdio.resolveCwd(directory: "/work", cwd: "~/mcp", homeDirectory: "/Users/dev") == "/Users/dev/mcp")
        #expect(CoreMCP.Stdio.resolveCwd(directory: "/work/app", cwd: "../tools", homeDirectory: "/Users/dev") == "/work/tools")

        let received = AtomicBox<[CoreMCP.JSONRPCMessage]>([])
        let errors = AtomicBox<[String]>([])
        let stdio = CoreMCP.Stdio.make(CoreMCP.Stdio.Options(server: "local-mcp", command: "", cwd: "/work"))
        stdio.setHandlers(
            onMessage: { msg in received.modify { $0.append(msg) } },
            onError: { err in errors.modify { $0.append(String(describing: err)) } },
            onClose: nil
        )
        try await stdio.start()
        let noteLine = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\r\nnot-json\n"
        let bytes = Array(noteLine.utf8)
        stdio.feedStdout(Array(bytes.prefix(15)))
        stdio.feedStdout(Array(bytes.dropFirst(15)))
        #expect(received.get().count == 1)
        #expect(errors.get().count == 1)
        try await stdio.close()

        // SocketClient pre-start FIFO buffering and single-fire onclose
        let sock = MockSubsystemsSocket()
        let sockTransport = CoreMCP.SocketClient.make(sock)
        let sockMsgs = AtomicBox<[CoreMCP.JSONRPCMessage]>([])
        let closeCount = AtomicCounter()
        sockTransport.setHandlers(
            onMessage: { m in sockMsgs.modify { $0.append(m) } },
            onError: nil,
            onClose: { closeCount.increment() }
        )
        sockTransport.deliver("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\"}")
        #expect(sockMsgs.get().isEmpty) // buffered until start()
        try await sockTransport.start()
        #expect(sockMsgs.get().count == 1)
        try await sockTransport.send(req)
        #expect(sock.sentFrames.count == 1)
        try await sockTransport.close()
        sockTransport.ended()
        #expect(closeCount.value == 1)
    }

    @Test("MCP Streamable HTTP client handshake, session header, tools/list, tools/call, and SSE")
    func mcpStreamableHTTPClient() async throws {
        let http = MockSubsystemsHTTPTransport { req in
            let msg = try CoreSubsystemsTestJSON.decode(CoreMCP.JSONRPCMessage.self, from: req.body ?? [])
            switch msg {
            case .request(let r) where r.method == "initialize":
                return try CoreSubsystemsTestJSON.jsonResponse(
                    headers: ["Mcp-Session-Id": "sess-xyz"],
                    body: .object([
                        "jsonrpc": .string("2.0"),
                        "id": .int(1),
                        "result": .object([
                            "protocolVersion": .string("2026-07-28"),
                            "serverInfo": .object(["name": .string("demo"), "title": .string("Demo MCP")]),
                            "instructions": .string("Use demo tools carefully."),
                        ]),
                    ])
                )
            case .notification(let n) where n.method == "notifications/initialized":
                return CoreSubsystemsTestJSON.textResponse(202, body: "")
            case .request(let r) where r.method == "tools/list":
                // Reply via text/event-stream SSE!
                let sse = """
                event: message
                data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ping","description":"Ping server","inputSchema":{"type":"object"}}]}}

                """
                return CoreSubsystemsTestJSON.textResponse(200, headers: ["content-type": "text/event-stream"], body: sse)
            case .request(let r) where r.method == "tools/call":
                return try CoreSubsystemsTestJSON.jsonResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(3),
                    "result": .object([
                        "isError": .bool(false),
                        "content": .array([.object(["type": .string("text"), "text": .string("pong!")])]),
                    ]),
                ]))
            default:
                return CoreSubsystemsTestJSON.textResponse(404, body: "not found")
            }
        }

        let remoteCfg = McpSchema.ServerConfig.remote(McpSchema.RemoteConfig(
            url: "https://mcp.example.com/rpc",
            headers: ["x-api": "1"]
        ))
        let client = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "demo",
            config: remoteCfg,
            http: http
        ))
        #expect(client.modern)
        #expect(client.title == "Demo MCP")
        #expect(client.instructions == "Use demo tools carefully.")

        let tools = try await client.tools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "ping")

        let callResult = try await client.callTool(name: "ping", args: [:], sessionID: nil, perRequest: nil)
        #expect(!callResult.isError)
        #expect(callResult.content == [.text("pong!")])

        // Verify Mcp-Session-Id was propagated on subsequent requests
        let reqs = http.requests
        #expect(reqs.count >= 4)
        #expect(reqs[2].headers["mcp-session-id"] == "sess-xyz")

        // Pool key fingerprints secrets rather than exposing raw values
        let keyA = CoreMCP.Pool.key(config: McpSchema.ServerConfig.remote(
            McpSchema.RemoteConfig(url: "https://mcp.example.com/rpc", headers: ["Authorization": "super-secret-token"])
        ))
        #expect(!keyA.contains("super-secret-token"))
    }

    @Test("Form validation (when cascading conditions), async ask/reply, WellKnown, WebSearch, and RPC")
    func formWellKnownWebSearchAndRpc() async throws {
        let fields = FormSchema.Fields(
            first: .string(FormSchema.StringField(
                key: "mode",
                title: "Mode",
                required: true,
                options: [FormSchema.Option(value: "local", label: "Local"), FormSchema.Option(value: "remote", label: "Remote")]
            )),
            rest: [
                .string(FormSchema.StringField(
                    key: "url",
                    title: "Remote URL",
                    required: true,
                    when: [FormSchema.When(key: "mode", op: .eq, value: .string("remote"))],
                    format: .uri
                )),
            ]
        )
        #expect(CoreIntegration.Form.validateFields(fields.elements) == nil)
        #expect(CoreIntegration.Form.validateAnswer(form: fields.elements, answer: ["mode": .string("local")]) == nil)
        #expect(CoreIntegration.Form.validateAnswer(form: fields.elements, answer: ["mode": .string("remote")]) != nil)
        #expect(CoreIntegration.Form.validateAnswer(form: fields.elements, answer: ["mode": .string("remote"), "url": .string("https://example.com")]) == nil)
        #expect(CoreIntegration.Form.validateAnswer(form: fields.elements, answer: ["mode": .string("local"), "url": .string("https://example.com")]) != nil)

        let formSvc = CoreIntegration.Form.Service()
        let formID = FormSchema.ID.create()
        let askTask = Task {
            try await formSvc.ask(CoreIntegration.Form.CreateInput(id: formID, sessionID: "ses_1", title: "Setup", fields: fields))
        }
        try await Task.sleep(for: .milliseconds(20))
        try await formSvc.reply(CoreIntegration.Form.ReplyInput(id: formID, answer: ["mode": .string("local")]))
        let settled = try await askTask.value
        #expect(settled == .answered(answer: ["mode": .string("local")]))

        // WellKnown inspect + resolve with {env:TOKEN}
        let wkHTTP = MockSubsystemsHTTPTransport { req in
            if req.url.hasSuffix("/.well-known/opencode") {
                return try CoreSubsystemsTestJSON.jsonResponse(body: .object([
                    "auth": .object(["command": .array([.string("gh"), .string("auth")]), "env": .string("WK_TOKEN")]),
                    "config": .object(["localKey": .bool(true)]),
                    "remote_config": .object([
                        "url": .string("https://corp.example.com/cfg"),
                        "headers": .object(["Authorization": .string("Bearer {env:WK_TOKEN}")]),
                    ]),
                ]))
            }
            #expect(req.headers["Authorization"] == "Bearer secret-wk")
            return try CoreSubsystemsTestJSON.jsonResponse(body: .object(["remoteKey": .string("loaded")]))
        }
        let configs = try await CoreIntegration.WellKnown.resolve(
            CoreIntegration.WellKnown.ResolveInput(origin: "https://corp.example.com/", variables: ["WK_TOKEN": "secret-wk"]),
            transport: wkHTTP
        )
        #expect(configs.count == 2)
        #expect(configs[1]["remoteKey"] == .string("loaded"))

        // WebSearch & RPC
        let kv = try CoreKV.Service.inMemory()
        let ws = CoreIntegration.WebSearch.Service(kv: kv)
        _ = try await ws.transform { ed in
            ed.add(CoreIntegration.WebSearch.ProviderImplementation(id: .init(rawValue: "exa"), name: "Exa") { input in
                [WebSearchSchema.Result(url: "https://exa.ai/q", title: input.query)]
            })
            ed.defaultSelection = .provider(.init(rawValue: "exa"))
        }
        let resp = try await ws.query(WebSearchSchema.Input(query: "swift 6.2"))
        #expect(resp.providerID.rawValue == "exa")
        #expect(resp.results.first?.title == "swift 6.2")

        let rpc = CoreIntegration.Rpc.Service()
        let reg = await rpc.register(rpcID: "math", handlers: [
            "add": { input in
                if case .object(let o) = input, case .int(let a) = o["a"], case .int(let b) = o["b"] {
                    return .int(a + b)
                }
                return .int(0)
            },
        ])
        let sum = try await rpc.call(rpcID: "math", method: "add", input: .object(["a": .int(19), "b": .int(23)]))
        #expect(sum == .int(42))
        await reg.dispose()
        await #expect(throws: RpcSchema.Failure<JSONValue>.self) {
            _ = try await rpc.call(rpcID: "math", method: "add", input: .null)
        }
    }

    // MARK: - 4. KV, SharedCache, Reactive CoreState & Utilities

    @Test("KV SQLite CRUD, prefixEnd range scan, cursor pagination, and SharedCache coalescing")
    func kvAndSharedCache() async throws {
        let kv = try CoreKV.Service.inMemory()
        try await kv.set("user:1", value: .string("alice"))
        try await kv.set("user:2", value: .string("bob"))
        try await kv.set("user:3", value: .string("carol"))
        try await kv.set("other:1", value: .string("ignored"))

        #expect(try await kv.get("user:2") == .string("bob"))
        let page1 = try await kv.scan(CoreKV.ScanOptions(prefix: "user:", limit: 2))
        #expect(page1.entries.map(\.key) == ["user:1", "user:2"])
        #expect(page1.next == "user:2")

        let page2 = try await kv.scan(CoreKV.ScanOptions(prefix: "user:", after: page1.next, limit: 2))
        #expect(page2.entries.map(\.key) == ["user:3"])
        #expect(page2.next == nil)

        try await kv.remove("user:2")
        #expect(try await kv.get("user:2") == nil)

        // SharedCache coalesces concurrent callers and preserves last-good value on transient failure
        let nowMs = AtomicBox<Int64>(1_000)
        let cache = CoreKV.SharedCache.Service(clock: { nowMs.get() }, retryDelayMs: 1)
        let loadCalls = AtomicCounter()
        let loadStarted = AtomicBox<Bool>(false)
        let releaseFirstLoad = AtomicBox<Bool>(false)
        let v1Task = Task {
            try await cache.get(CoreKV.SharedCache.Input(key: "k1", intervalMs: 500) {
                loadCalls.increment()
                loadStarted.set(true)
                while !releaseFirstLoad.get() {
                    try await Task.sleep(for: .milliseconds(2))
                }
                return "fresh-1"
            })
        }
        while !loadStarted.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
        let v2Task = Task {
            try await cache.get(CoreKV.SharedCache.Input(key: "k1", intervalMs: 500) {
                loadCalls.increment()
                return "fresh-2"
            })
        }
        try await Task.sleep(for: .milliseconds(10))
        releaseFirstLoad.set(true)
        let r1 = try await v1Task.value
        let r2 = try await v2Task.value
        #expect(r1 == "fresh-1")
        #expect(r2 == "fresh-1")
        #expect(loadCalls.value == 1)

        // Advance past interval and return error -> keeps last good value "fresh-1"
        nowMs.set(2_000)
        let r3 = try await cache.get(CoreKV.SharedCache.Input(key: "k1", intervalMs: 500) { () -> String in
            throw PlatformError.ioFailure("non-transient failure")
        })
        #expect(r3 == "fresh-1")
    }

    @Test("CoreState batch coalescing, shutdown closure, KeyedMutex, and core utilities")
    func coreStateAndUtilities() async throws {
        let notifyCount = AtomicCounter()
        final class BoxEd: @unchecked Sendable {
            var values: [String]
            init(_ v: [String]) { self.values = v }
        }
        let store = CoreState.create(CoreState.Options<[String], BoxEd>(
            name: "test-state",
            initial: { [] },
            makeEditor: { BoxEd($0) },
            commitEditor: { $0.values },
            notify: { _ in notifyCount.increment() }
        ))
        try await CoreState.batch {
            _ = try await store.transform { $0.values.append("a") }
            _ = try await store.transform { $0.values.append("b") }
            #expect(store.get() == ["a", "b"])
            #expect(notifyCount.value == 0)
        }
        #expect(notifyCount.value == 1)

        await CoreState.shutdown {
            await store.reload()
        }
        await store.reload()
        #expect(notifyCount.value == 1) // permanently closed

        // KeyedMutex evicts locks when idle
        let mutex = CoreSubsystems.Effect.KeyedMutex<String>.makeUnsafe()
        let out = await mutex.withLock("alpha") { 123 }
        #expect(out == 123)
        #expect(mutex.size == 0)

        // Utilities: canonicalJson, Token.estimate, Wildcard, Slug, WebSocket proxy
        let canon = CoreSubsystems.Util.canonicalJson(.object(["z": .int(1), "a": .int(2)]))
        #expect(canon == "{\"a\":2,\"z\":1}")
        #expect(CoreSubsystems.Util.Token.estimate("12345678") == 2)
        #expect(CoreSubsystems.Util.Wildcard.match("git status --short", pattern: "git status *"))
        #expect(CoreSubsystems.Util.Wildcard.match("git status", pattern: "git status *"))
        #expect(CoreSubsystems.Util.Slug.create().contains("-"))
        #expect(CoreSubsystems.Effect.WebSocketConstructor.proxy(
            for: "wss://api.example.com/ws",
            environment: ["WSS_PROXY": "http://proxy:8080", "NO_PROXY": ".internal"]
        ) == "http://proxy:8080")
        #expect(CoreSubsystems.Effect.WebSocketConstructor.proxy(
            for: "wss://127.0.0.1:9000/ws",
            environment: ["WSS_PROXY": "http://proxy:8080"]
        ) == nil)
    }

    // MARK: - 5. LocationServiceMap, Environment, Project, VCS & Worktrees

    @Test("LocationServiceMap canonical keys, lifecycle retain/shutdown, reload, and Activity sweep")
    func locationServiceMapAndActivity() async throws {
        let refA = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/tmp/proj//sub/../"))
        let refB = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/tmp/proj"))
        #expect(CoreLocation.ServiceMap.canonical(refA) == CoreLocation.ServiceMap.canonical(refB))

        let buildCount = AtomicCounter()
        let map = CoreLocation.ServiceMap.Service { ref, _ in
            let n = buildCount.increment()
            let lc = CoreLocation.Lifecycle.Service()
            return LayerNode.Output([
                CoreLocation.Lifecycle.Service.serviceKey: lc,
                "buildIndex": n,
                "dir": ref.directory.rawValue,
            ])
        }
        let s1 = try await map.get(refA)
        let s2 = try await map.get(refB)
        #expect(s1.get("buildIndex", as: Int.self) == 1)
        #expect(s2.get("buildIndex", as: Int.self) == 1)
        #expect(map.has(refB))

        let lc = try #require(s1.get(CoreLocation.Lifecycle.Service.serviceKey, as: CoreLocation.Lifecycle.Service.self))
        let release = lc.retain()
        let nowMs = AtomicBox<Int64>(1_000)
        let activity = CoreLocation.Activity.Service(timeToLiveMs: 500, clock: { nowMs.get() })
        activity.touch(refB)
        nowMs.set(2_000)
        // Retained -> NOT evicted!
        let evictedWhileRetained = await activity.sweep(locations: map)
        #expect(evictedWhileRetained.isEmpty)
        #expect(map.has(refB))

        // Release retain -> evicted on next expired sweep and lifecycle shut down!
        release()
        nowMs.set(3_000)
        let evicted = await activity.sweep(locations: map)
        #expect(evicted.count == 1)
        #expect(!map.has(refB))
        #expect(lc.isClosed())

        // Reload rebuilds live locations
        _ = try await map.get(refB)
        try await CoreLocation.ServiceMap.reload(map)
        #expect(buildCount.value == 3)
    }

    @Test("Environment MemoryDriver symlinks, Repository parser, VCS Patch, and Worktree lifecycle")
    func environmentRepositoryPatchAndWorktree() async throws {
        // MemoryDriver symlink & cycle handling
        let mem = CoreLocation.Environment.makeMemoryDriver()
        try await mem.write("/dir/hello.txt", bytes: Array("hello world".utf8))
        try await mem.symlink(target: "hello.txt", at: "/dir/link.txt")
        #expect(try await mem.stat("/dir/link.txt").type == .symlink)
        #expect(try await CoreLocation.Environment.Files.typeFollowing(mem, path: "/dir/link.txt") == .file)
        let slice = try await mem.read("/dir/link.txt", range: .init(offset: 6, length: 5))
        #expect(String(decoding: slice.bytes, as: UTF8.self) == "world")

        // Repository parser & branch validation
        let gh = try CoreProject.Repository.parseRemote("anomalyco/opencode")
        #expect(gh.host == "github.com")
        #expect(gh.owner == "anomalyco")
        #expect(gh.repo == "opencode")
        #expect(CoreProject.Repository.cachePath(root: "/repos", reference: .remote(gh), branch: "feat/swift") == "/repos/github.com/anomalyco/opencode@feat%2Fswift")
        #expect(throws: CoreProject.Repository.InvalidBranchError.self) {
            try CoreProject.Repository.validateBranch("-bad")
        }
        #expect(throws: CoreProject.Repository.InvalidBranchError.self) {
            try CoreProject.Repository.validateBranch("a..b")
        }

        // VCS Patch split, file extraction, and counts
        let multiPatch = """
        diff --git a/src/a.swift b/src/a.swift
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,1 +1,2 @@
        -old
        +new1
        +new2
        diff --git a/src/b.swift b/src/b.swift
        --- a/src/b.swift
        +++ b/src/b.swift
        @@ -0,0 +1,1 @@
        +added
        """
        let chunks = CoreVcs.Patch.splitGitPatch(.init(text: multiPatch, truncated: false))
        #expect(chunks.count == 2)
        let byFile = CoreVcs.Patch.chunksByFile(.init(text: multiPatch, truncated: false))
        #expect(byFile.keys.sorted() == ["src/a.swift", "src/b.swift"])
        let counts = CoreVcs.Patch.countPatch(byFile["src/a.swift"] ?? "")
        #expect(counts.additions == 2)
        #expect(counts.deletions == 1)
        // Truncated drops trailing partial chunk
        #expect(CoreVcs.Patch.splitGitPatch(.init(text: multiPatch, truncated: true)).count == 1)

        // Project + Worktree lifecycle with in-memory SQLite + InMemoryFileSystem
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let fs = InMemoryFileSystem(initialFiles: ["/repo/.git/HEAD": Array("ref: refs/heads/main\n".utf8)])
        let projectSvc = try CoreProject.Project.Service(database: db, fileSystem: fs)
        let resolved = try await projectSvc.resolve(SchemaPrimitive.AbsolutePath(rawValue: "/repo"))
        #expect(resolved.vcs?.type.rawValue == "git")

        let customStrat = CoreWorktree.Strategies.Strategy(
            id: WorktreeSchema.StrategyID(rawValue: "mock")!,
            create: { _, dir, _ in
                try await fs.makeDirectory(at: dir.rawValue, recursive: true)
                return WorktreeSchema.Info(directory: dir)
            },
            remove: { dir, _ in try await fs.remove(at: dir.rawValue) },
            list: { _ in [] }
        )
        let stratSvc = CoreWorktree.Strategies.Service(
            locationDirectory: SchemaPrimitive.AbsolutePath(rawValue: "/repo"),
            defaultWorktreeRoot: SchemaPrimitive.AbsolutePath(rawValue: "/worktrees"),
            gitStrategy: customStrat
        )
        let wtSvc = try CoreWorktree.Service(database: db, fileSystem: fs, defaultStrategies: stratSvc)
        try wtSvc.registerRoot(projectID: resolved.id, directory: resolved.canonical)
        let wt1 = try await wtSvc.create(WorktreeSchema.CreateInput(projectID: resolved.id, name: "feature"))
        let wt2 = try await wtSvc.create(WorktreeSchema.CreateInput(projectID: resolved.id, name: "feature"))
        #expect(wt1.directory.rawValue == "/worktrees/feature")
        #expect(wt2.directory.rawValue == "/worktrees/feature-2")
        #expect(try await wtSvc.list(projectID: resolved.id).count == 3)
        try await wtSvc.remove(WorktreeSchema.RemoveInput(projectID: resolved.id, directory: wt1.directory, force: true))
        #expect(try await wtSvc.list(projectID: resolved.id).count == 2)
    }

    // MARK: - 6. Jobs & Automations Lifecycle

    @Test("Job lifecycle: start, wait, background SQLite persistence, cancel, and subagent report")
    func jobLifecycle() async throws {
        let jobs = try CoreJob.Service.inMemory()
        let sessionID = SessionID.create()
        let childID = SessionID.create()

        // Completed job wait
        _ = try await jobs.start(CoreJob.StartInput(id: "j1", type: "shell", title: "Echo") {
            "hello"
        })
        let waited = await jobs.wait(CoreJob.WaitInput(id: "j1", timeoutMs: 2_000))
        #expect(!waited.timedOut)
        #expect(waited.info?.status == .completed)
        #expect(waited.info?.output == "hello")

        // Backgrounded subagent job persisted to SQLite & cancellable
        let cancelCalled = AtomicCounter()
        _ = try await jobs.start(CoreJob.StartInput(
            id: "j2",
            type: "subagent",
            title: "Long task",
            recovery: .subagent(parentSessionID: sessionID, childSessionID: childID, agent: "explore", description: "Explore repo"),
            background: true,
            run: {
                try await Task.sleep(for: .seconds(10))
                return "never"
            },
            cancel: { cancelCalled.increment() }
        ))
        let running = try await jobs.runningBackground()
        #expect(running.count == 1)
        let listed = try await jobs.backgroundJobs()
        #expect(listed.count == 1)

        let reportState = await jobs.prepareSubagentReport(id: "j2", boundGeneration: nil)
        if case .background(let notifID, _, _) = reportState {
            #expect(!notifID.isEmpty)
        } else {
            Issue.record("Expected background subagent report state")
        }

        let cancelled = await jobs.cancelSession(sessionID)
        #expect(cancelled.count == 1)
        #expect(await jobs.isCancelled("j2"))
        #expect(cancelCalled.value == 1)
    }

    @Test("Automation lifecycle: create, forbidden-tool rejection, pause/resume, tick execution, and event prompt")
    func automationLifecycle() async throws {
        let nowMs = AtomicBox<Int64>(1_700_000_000_000)
        let firedNames = AtomicBox<[String]>([])
        let svc = try CoreAutomation.Service.inMemory(
            clock: { nowMs.get() },
            onFire: { info in
                firedNames.modify { $0.append(info.name) }
                return (.fired, "ran \(info.name)", .object(["count": .int(1)]), false)
            }
        )
        let projectID = ProjectID(rawValue: "proj_1")
        let sessionID = SessionID.create()

        // Forbidden tool rejected (shell is now permitted in Code Mode automations; automation.create stays forbidden)
        await #expect(throws: CoreAutomation.InvalidError.self) {
            _ = try await svc.create(
                AutomationSchema.CreateInput(
                    sessionID: sessionID,
                    name: "Bad Code",
                    trigger: .every(.init(every: "60 seconds")),
                    action: .code(.init(code: "await tools.automation.create({ name: 'loop' })"))
                ),
                projectID: projectID,
                directory: "/repo"
            )
        }

        // Valid recurring prompt automation
        let created = try await svc.create(
            AutomationSchema.CreateInput(
                sessionID: sessionID,
                name: "Hourly Check",
                trigger: .every(.init(every: "5 minutes")),
                action: .prompt(.init(prompt: "Check CI status"))
            ),
            projectID: projectID,
            directory: "/repo"
        )
        #expect(created.status == .active)
        #expect(try await svc.list(.init(projectID: projectID)).count == 1)

        // Pause prevents tick execution
        let paused = try await svc.pause(created.id)
        #expect(paused.status == .paused)
        nowMs.set(nowMs.get() + 6 * 60 * 1_000)
        try await svc.tick()
        #expect(firedNames.get().isEmpty)

        // Resume + advance clock -> tick fires and increments runCount
        _ = try await svc.resume(created.id)
        nowMs.set(nowMs.get() + 6 * 60 * 1_000)
        try await svc.tick()
        #expect(firedNames.get() == ["Hourly Check"])
        let afterTick = try await svc.get(created.id)
        #expect(afterTick.runCount.rawValue == 1)
        #expect(afterTick.lastOutcome == .fired)
        #expect(afterTick.state == .object(["count": .int(1)]))

        // Event prompt escapes U+2028/U+2029 safely
        let eventPrompt = CoreAutomation.Event.prompt(
            text: "Handle webhook",
            message: CoreAutomation.Event.Message(
                eventId: "ev_1",
                name: "push",
                timestamp: "2026-01-01T00:00:00Z",
                data: .string("line1\u{2028}line2")
            )
        )
        #expect(eventPrompt.contains("\\u2028"))
        #expect(!eventPrompt.contains("\u{2028}"))

        try await svc.remove(created.id)
        await #expect(throws: CoreAutomation.NotFoundError.self) {
            _ = try await svc.get(created.id)
        }
    }
}
