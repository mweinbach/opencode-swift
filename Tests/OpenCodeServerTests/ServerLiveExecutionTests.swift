import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

@Suite("OpenCodeServer Live Execution, Catalog, VCS, MCP & Streaming LLM")
struct ServerLiveExecutionTests {

    @Test("Default agents, env/auth.json/config provider & model discovery, and MCP config seeding")
    func defaultAgentsProvidersModelsAuthJsonAndMcpDiscovery() async throws {
        let authJSON = """
        {
          "groq": { "type": "api", "key": "gsk_from_legacy_auth_json" }
        }
        """
        let configJSON = """
        {
          "model": "openai/gpt-5.4",
          "providers": {
            "local-llm": {
              "name": "Local LLM",
              "settings": { "baseURL": "http://127.0.0.1:11434/v1" },
              "models": {
                "qwen3-coder": {
                  "name": "Qwen 3 Coder",
                  "limit": { "context": 131072, "output": 16384 }
                }
              }
            }
          },
          "mcp": {
            "servers": {
              "docs": {
                "type": "remote",
                "url": "https://mcp.example.com/sse"
              },
              "disabled-mcp": {
                "type": "local",
                "command": ["echo", "noop"],
                "disabled": true
              }
            }
          }
        }
        """

        let harness = try await LiveExecutionFixture.makeHarness(
            env: [
                "ANTHROPIC_API_KEY": "sk-ant-env-key",
                "OPENAI_API_KEY": "sk-openai-env-key",
                "GEMINI_API_KEY": "gemini-env-key",
            ],
            configContent: configJSON,
            initialFiles: [
                "/tmp/opencode-live-test/data/auth.json": LiveExecutionFixture.bytes(authJSON),
            ]
        )
        defer { Task { await harness.close() } }

        // 1. Default built-in agents matching upstream agent.ts & plan.ts
        let agentsRes = try await harness.client.agent.list()
        let agents = agentsRes.data
        let agentIDs = agents.map { $0.id.rawValue }
        #expect(agents.first?.id.rawValue == "build")
        #expect(agentIDs.contains("build"))
        #expect(agentIDs.contains("plan"))
        #expect(agentIDs.contains("general"))
        #expect(agentIDs.contains("explore"))

        let buildAgent = try #require(agents.first { $0.id.rawValue == "build" })
        #expect(buildAgent.name.rawValue == "Build")
        #expect(buildAgent.mode == .primary)
        #expect(buildAgent.description == "The default agent. Executes tools based on configured permissions.")

        let planAgent = try #require(agents.first { $0.id.rawValue == "plan" })
        #expect(planAgent.name.rawValue == "Plan")
        #expect(planAgent.mode == .primary)
        #expect(planAgent.permissions.contains { $0.action == "edit" && $0.resource == "*" && $0.effect == .deny })

        let generalAgent = try #require(agents.first { $0.id.rawValue == "general" })
        #expect(generalAgent.name.rawValue == "General")
        #expect(generalAgent.mode == .subagent)

        let exploreAgent = try #require(agents.first { $0.id.rawValue == "explore" })
        #expect(exploreAgent.name.rawValue == "Explore")
        #expect(exploreAgent.mode == .subagent)
        #expect(exploreAgent.system?.contains("file search specialist") == true)
        #expect(exploreAgent.permissions.contains { $0.action == "*" && $0.resource == "*" && $0.effect == .deny })
        #expect(exploreAgent.permissions.contains { $0.action == "read" && $0.resource == "*" && $0.effect == .allow })

        // 2. Providers discovered from env vars + legacy auth.json + config providers
        let providersRes = try await harness.client.provider.list()
        let providerIDs = Set(providersRes.data.map { $0.id.rawValue })
        #expect(providerIDs.contains("anthropic"))
        #expect(providerIDs.contains("openai"))
        #expect(providerIDs.contains("google"))
        #expect(providerIDs.contains("groq")) // imported from legacy auth.json!
        #expect(providerIDs.contains("local-llm")) // declared in config!
        #expect(!providerIDs.contains("xai")) // no key configured

        // 3. Real model catalog with limits, variants, and config default model selection
        let modelsRes = try await harness.client.model.list()
        let models = modelsRes.data
        let claude = try #require(models.first { $0.providerID == .anthropic && $0.id.rawValue == "claude-sonnet-4-6" })
        #expect(claude.limit.context == 200_000)
        #expect(claude.limit.output == 64_000)
        #expect(!claude.variants.isEmpty)
        #expect(!claude.cost.isEmpty)

        let qwen = try #require(models.first { $0.providerID.rawValue == "local-llm" && $0.id.rawValue == "qwen3-coder" })
        #expect(qwen.limit.context == 131_072)
        #expect(qwen.limit.output == 16_384)

        let defaultModelRes = try await harness.client.model.default()
        #expect(defaultModelRes.data?.providerID == .openai)
        #expect(defaultModelRes.data?.id.rawValue == "gpt-5.4")

        // 4. Configured MCP servers seeded into mcpService
        let mcpRes = try await harness.client.mcp.list()
        let docsServer = try #require(mcpRes.data.first { $0.name == "docs" })
        #expect(docsServer.status == .pending)
        let disabledServer = try #require(mcpRes.data.first { $0.name == "disabled-mcp" })
        #expect(disabledServer.status == .disabled)
    }

    @Test("Real Git VCS detection returns current branch, branch list, and working status on GET /api/vcs")
    func liveGitVcsDetection() async throws {
        let repo = try await LiveExecutionFixture.makeTemporaryGitRepo(branchName: "feature/live-vcs-check")
        let harness = try await LiveExecutionFixture.makeRealDiskHarness(directory: repo.directory)
        defer {
            Task {
                await harness.close()
                await repo.cleanup()
            }
        }

        let vcsRes = try await harness.client.vcs.get()
        #expect(vcsRes.data.provider == "git")
        #expect(vcsRes.data.branch.current == "feature/live-vcs-check")

        let branchesRes = try await harness.client.vcs.branch.list()
        #expect(branchesRes.data.contains("feature/live-vcs-check"))

        let statusRes = try await harness.client.vcs.status()
        let readmeStatus = try #require(statusRes.data.first { $0.file == "README.md" })
        #expect(readmeStatus.status == .modified)
        #expect(readmeStatus.additions.rawValue >= 1)
        let extraStatus = try #require(statusRes.data.first { $0.file == "extra.txt" })
        #expect(extraStatus.status == .added)
    }

    @Test("End-to-end Anthropic streaming prompt -> read tool call -> second LLM step -> SQLite persistence + live SSE")
    func anthropicStreamingMultiStepToolExecution() async throws {
        let step1SSE = LiveExecutionFixture.anthropicToolCallStepSSE(
            thinking: "Let me read notes.txt to answer the user.",
            toolCallID: "toolu_read_notes_1",
            toolName: "read",
            inputChunks: ["{\"path\":", "\"notes.txt\"}"]
        )
        let step2SSE = LiveExecutionFixture.anthropicTextStepSSE(
            chunks: ["The file says: ", "Alpha line and Beta line."]
        )

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                "/workspace/notes.txt": LiveExecutionFixture.bytes("Alpha line\nBeta line\n"),
            ],
            responses: [step1SSE, step2SSE]
        )
        defer { Task { await harness.close() } }

        // Subscribe to live CoreBus + live SSE `/api/event` BEFORE sending prompt
        let busRecorder = LiveExecutionFixture.EventRecorder(bus: harness.runtime.bus)
        defer { busRecorder.stop() }

        let sseCollector = LiveExecutionFixture.SSECollector()
        let sseStream = harness.client.event.subscribe()
        let sseTask = Task {
            do {
                for try await event in sseStream {
                    sseCollector.record(event.type)
                    if event.type == "session.execution.succeeded" {
                        break
                    }
                }
            } catch {
                // Stream closed on teardown
            }
        }
        await sseCollector.waitForConnected()

        let created = try await harness.client.session.create(SessionCreateInput(title: "Anthropic Live Tool Run"))
        let admitted = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: created.id.rawValue,
            text: "Read notes.txt and summarize it."
        ))
        #expect(admitted.id.rawValue.hasPrefix("msg_"))

        // Wait for the multi-step execution to settle cleanly
        await harness.runtime.sessionExecution.awaitIdle(created.id)
        let sawSucceededSSE = await sseCollector.waitUntil(contains: "session.execution.succeeded", timeoutMs: 5_000)
        sseTask.cancel()

        // 1. Verify exactly 2 explicit outbound Anthropic API requests (one per step)
        let requests = harness.mockTransport.recordedRequests
        #expect(requests.count == 2)

        let req1 = requests[0]
        #expect(req1.url == "https://api.anthropic.com/v1/messages")
        #expect(req1.headers["x-api-key"] == "sk-ant-live-secret")
        #expect(req1.headers["anthropic-version"] == "2023-06-01")
        let req1JSON = try LiveExecutionFixture.decodeJSON(req1.body ?? [])
        #expect(req1JSON["model"] == .string("claude-sonnet-4-6"))
        #expect(req1JSON["stream"] == .bool(true))
        if case .array(let tools) = req1JSON["tools"] {
            let toolNames: [String] = tools.compactMap { entry in
                if case .object(let obj) = entry, case .string(let name) = obj["name"] { return name }
                return nil
            }
            #expect(toolNames.contains("read"))
            #expect(toolNames.contains("edit"))
            #expect(toolNames.contains("grep"))
            #expect(toolNames.contains("glob"))
        } else {
            Issue.record("Expected built-in tools array in first Anthropic request")
        }

        // Second request must carry reloaded history including real `read` tool output
        let req2 = requests[1]
        let req2BodyText = LiveExecutionFixture.utf8(req2.body ?? [])
        #expect(req2BodyText.contains("toolu_read_notes_1"))
        #expect(req2BodyText.contains("1: Alpha line"))
        #expect(req2BodyText.contains("2: Beta line"))

        // 2. Verify persisted SQLite messages in chronological order via GET /api/session/:id/message?order=asc
        let messages = try await harness.client.message.list(
            MessageListInput(sessionID: created.id.rawValue, order: .asc)
        ).data
        #expect(messages.count == 4)

        if case .user(let u) = messages[0] {
            #expect(u.text == "Read notes.txt and summarize it.")
        } else {
            Issue.record("Expected message[0] to be user prompt")
        }

        if case .assistant(let step1) = messages[1] {
            #expect(step1.model.providerID == "anthropic")
            #expect(step1.model.id == "claude-sonnet-4-6")
            #expect(step1.tokens?.input == 120)
            #expect(step1.tokens?.output == 45)
            var sawReasoning = false
            var sawCompletedReadTool = false
            for part in step1.content {
                switch part {
                case .reasoning(let r):
                    if r.text.contains("Let me read notes.txt") { sawReasoning = true }
                case .tool(let t):
                    if t.name == "read", case .completed(let done) = t.state {
                        let rendered = done.content.compactMap { item -> String? in
                            if case .text(let s) = item { return s }
                            return nil
                        }.joined(separator: "\n")
                        if rendered.contains("1: Alpha line") && rendered.contains("2: Beta line") {
                            sawCompletedReadTool = true
                        }
                    }
                case .text:
                    break
                }
            }
            #expect(sawReasoning)
            #expect(sawCompletedReadTool)
        } else {
            Issue.record("Expected message[1] to be assistant step 1 with tool call")
        }

        if case .assistant(let step2) = messages[2] {
            let textContent = step2.content.compactMap { part -> String? in
                if case .text(let t) = part { return t.text }
                return nil
            }.joined()
            #expect(textContent == "The file says: Alpha line and Beta line.")
            #expect(step2.tokens?.input == 210)
            #expect(step2.tokens?.output == 32)
            #expect((step2.cost ?? 0) > 0)
        } else {
            Issue.record("Expected message[2] to be assistant step 2 final text")
        }

        if case .idle = messages[3] {
            // Terminal idle marker persisted on execution completion
        } else {
            Issue.record("Expected message[3] to be terminal idle marker")
        }

        // 3. Verify live CoreBus & SSE events delivered in real time
        let sseTypes = sseCollector.snapshot()
        #expect(sawSucceededSSE)
        #expect(sseTypes.contains("server.connected"))
        #expect(sseTypes.contains("session.execution.started"))
        #expect(sseTypes.contains("session.inbox.delivered"))
        #expect(sseTypes.contains("session.step.started"))
        #expect(sseTypes.contains("session.reasoning.delta"))
        #expect(sseTypes.contains("session.tool.called"))
        #expect(sseTypes.contains("session.tool.success"))
        #expect(sseTypes.contains("session.text.delta"))
        #expect(sseTypes.contains("session.step.ended"))
        #expect(sseTypes.contains("session.execution.succeeded"))

        // 4. Verify write-ahead claim & active execution released cleanly
        let activeAfter = try await harness.client.session.active()
        #expect(activeAfter.isEmpty)
        let inboxAfter = try await harness.client.session.inbox.list(SessionInboxListInput(sessionID: created.id.rawValue))
        #expect(inboxAfter.isEmpty)
    }

    @Test("OpenAI Responses, Google Gemini, and OpenRouter OpenAI-compatible streaming wire protocols")
    func multiProviderStreamingProtocols() async throws {
        // 1. OpenAI Responses API
        let openaiHarness = try await LiveExecutionFixture.makeHarness(
            env: ["OPENAI_API_KEY": "sk-openai-test-key"],
            responses: [LiveExecutionFixture.openAIResponsesTextSSE(chunks: ["Hello ", "from GPT-5.4!"])]
        )
        defer { Task { await openaiHarness.close() } }

        let oaiSession = try await openaiHarness.client.session.create(SessionCreateInput(title: "OpenAI Test"))
        _ = try await openaiHarness.client.session.prompt(SessionPromptInput(
            sessionID: oaiSession.id.rawValue,
            text: "Say hi"
        ))
        await openaiHarness.runtime.sessionExecution.awaitIdle(oaiSession.id)

        let oaiReqs = openaiHarness.mockTransport.recordedRequests
        #expect(oaiReqs.count == 1)
        #expect(oaiReqs[0].url == "https://api.openai.com/v1/responses")
        #expect(oaiReqs[0].headers["authorization"] == "Bearer sk-openai-test-key")
        let oaiMsgs = try await openaiHarness.client.message.list(
            MessageListInput(sessionID: oaiSession.id.rawValue, order: .asc)
        ).data
        #expect(oaiMsgs.count == 3)
        if case .assistant(let a) = oaiMsgs[1] {
            let text = a.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            #expect(text == "Hello from GPT-5.4!")
        } else {
            Issue.record("Expected assistant message from OpenAI Responses")
        }

        // 2. Google Gemini API
        let geminiHarness = try await LiveExecutionFixture.makeHarness(
            env: ["GEMINI_API_KEY": "gemini-live-key"],
            responses: [LiveExecutionFixture.geminiTextSSE(chunks: ["Hello ", "from Gemini!"])]
        )
        defer { Task { await geminiHarness.close() } }

        let gemSession = try await geminiHarness.client.session.create(SessionCreateInput(title: "Gemini Test"))
        _ = try await geminiHarness.client.session.prompt(SessionPromptInput(
            sessionID: gemSession.id.rawValue,
            text: "Say hi"
        ))
        await geminiHarness.runtime.sessionExecution.awaitIdle(gemSession.id)

        let gemReqs = geminiHarness.mockTransport.recordedRequests
        #expect(gemReqs.count == 1)
        #expect(gemReqs[0].url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse")
        #expect(gemReqs[0].headers["x-goog-api-key"] == "gemini-live-key")
        let gemMsgs = try await geminiHarness.client.message.list(
            MessageListInput(sessionID: gemSession.id.rawValue, order: .asc)
        ).data
        #expect(gemMsgs.count == 3)
        if case .assistant(let a) = gemMsgs[1] {
            let text = a.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            #expect(text == "Hello from Gemini!")
        } else {
            Issue.record("Expected assistant message from Google Gemini")
        }

        // 3. OpenRouter (OpenAI-compatible Chat Completions SSE)
        let orHarness = try await LiveExecutionFixture.makeHarness(
            env: ["OPENROUTER_API_KEY": "sk-or-live-key"],
            responses: [LiveExecutionFixture.openAIChatTextSSE(chunks: ["Hello ", "from OpenRouter!"])]
        )
        defer { Task { await orHarness.close() } }

        let orSession = try await orHarness.client.session.create(SessionCreateInput(title: "OpenRouter Test"))
        _ = try await orHarness.client.session.prompt(SessionPromptInput(
            sessionID: orSession.id.rawValue,
            text: "Say hi"
        ))
        await orHarness.runtime.sessionExecution.awaitIdle(orSession.id)

        let orReqs = orHarness.mockTransport.recordedRequests
        #expect(orReqs.count == 1)
        #expect(orReqs[0].url == "https://openrouter.ai/api/v1/chat/completions")
        #expect(orReqs[0].headers["authorization"] == "Bearer sk-or-live-key")
        let orMsgs = try await orHarness.client.message.list(
            MessageListInput(sessionID: orSession.id.rawValue, order: .asc)
        ).data
        #expect(orMsgs.count == 3)
        if case .assistant(let a) = orMsgs[1] {
            let text = a.content.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
            #expect(text == "Hello from OpenRouter!")
        } else {
            Issue.record("Expected assistant message from OpenRouter")
        }
    }

    @Test("Prompt without configured API key delivers user message to SQLite and emits clear assistant error step without HTTP calls")
    func missingApiKeyEmitsGracefulAssistantErrorStep() async throws {
        // Note: `responses: []` ensures any unexpected HTTP call would fail hard!
        let harness = try await LiveExecutionFixture.makeHarness(env: [:], responses: [])
        defer { Task { await harness.close() } }

        let busRecorder = LiveExecutionFixture.EventRecorder(bus: harness.runtime.bus)
        defer { busRecorder.stop() }

        let created = try await harness.client.session.create(SessionCreateInput(title: "No Key Session"))
        _ = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: created.id.rawValue,
            text: "Hello without any API key"
        ))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        // Zero outbound HTTP calls attempted
        #expect(harness.mockTransport.recordedRequests.isEmpty)

        // Inbox consumed; user message AND assistant error step persisted in SQLite
        let inbox = try await harness.client.session.inbox.list(SessionInboxListInput(sessionID: created.id.rawValue))
        #expect(inbox.isEmpty)

        let messages = try await harness.client.message.list(
            MessageListInput(sessionID: created.id.rawValue, order: .asc)
        ).data
        #expect(messages.count == 3)

        if case .user(let u) = messages[0] {
            #expect(u.text == "Hello without any API key")
        } else {
            Issue.record("Expected user message persisted in SQLite")
        }

        if case .assistant(let a) = messages[1] {
            let err = try #require(a.error)
            #expect(err.type == "provider.auth")
            #expect(err.message.contains("ANTHROPIC_API_KEY"))
            #expect(err.message.contains("OPENAI_API_KEY"))
            #expect(err.message.contains("GEMINI_API_KEY"))
            #expect(err.message.contains("opencode auth"))
        } else {
            Issue.record("Expected assistant error message persisted in SQLite")
        }

        if case .idle = messages[2] {
            // Terminal idle marker persisted after failed execution
        } else {
            Issue.record("Expected terminal idle marker")
        }

        // Verify live bus emitted step.failed + execution.failed and session is cleanly idle
        let types = busRecorder.types()
        #expect(types.contains("session.inbox.delivered"))
        #expect(types.contains("session.step.started"))
        #expect(types.contains("session.step.failed"))
        #expect(types.contains("session.execution.failed"))
        #expect(try await harness.client.session.active().isEmpty)
    }

    @Test("Plan agent denies file writes outside plan directory while permitting read-only exploration")
    func planAgentEnforcesReadOnlyPermissions() async throws {
        let step1SSE = LiveExecutionFixture.anthropicToolCallStepSSE(
            thinking: "Trying to write a workspace file in plan mode.",
            toolCallID: "toolu_write_blocked",
            toolName: "write",
            inputChunks: ["{\"path\":\"blocked.txt\",\"content\":\"should not write\"}"]
        )
        let step2SSE = LiveExecutionFixture.anthropicTextStepSSE(
            chunks: ["Understood, I cannot edit files in Plan mode."]
        )

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-plan-test"],
            responses: [step1SSE, step2SSE]
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Plan Mode Session"))
        try await harness.client.session.switchAgent(SessionSwitchAgentInput(
            sessionID: created.id.rawValue,
            agent: "plan"
        ))
        _ = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: created.id.rawValue,
            text: "Create blocked.txt"
        ))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        // Verify blocked.txt was NOT created on the workspace filesystem
        let exists = await harness.fileSystem.exists(at: "/workspace/blocked.txt")
        #expect(!exists)

        // Verify step 1 recorded a tool error for the blocked write
        let messages = try await harness.client.message.list(
            MessageListInput(sessionID: created.id.rawValue, order: .asc)
        ).data
        let assistantSteps = messages.compactMap { msg -> SessionMessageSchema.Assistant? in
            if case .assistant(let a) = msg { return a }
            return nil
        }
        #expect(assistantSteps.count == 2)
        let writeToolFailed = assistantSteps[0].content.contains { part in
            if case .tool(let t) = part, t.name == "write", case .error = t.state {
                return true
            }
            return false
        }
        #expect(writeToolFailed)
    }
}
