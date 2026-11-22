import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Real Subsystems Wiring Tests")
struct RealSubsystemsWiringTests {

    // MARK: - 1. Persistent Bidirectional Subprocess for MCP StdioTransport (P0 #7)

    #if os(macOS) || os(Linux)
    @Test("CoreMCP StdioTransport maintains ONE persistent stateful subprocess across multiple JSON-RPC calls")
    func persistentStdioTransportStatefulSubprocess() async throws {
        // Stateful POSIX shell JSON-RPC 2.0 server that keeps an in-memory counter across calls
        // and reports its own PID ($$) + incrementing count on every message.
        let script = #"""
        c=0
        while IFS= read -r line; do
          c=$((c + 1))
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          if [ -z "$id" ]; then
            continue
          fi
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2026-07-28","serverInfo":{"name":"stateful-sh","title":"Stateful Shell MCP"},"instructions":"Persistent PID %s"}}\n' "$id" "$$"
              ;;
            *'"method":"tools/list"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"bump","description":"Increment persistent counter","inputSchema":{"type":"object"}}]}}\n' "$id"
              ;;
            *'"method":"tools/call"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":false,"content":[{"type":"text","text":"pid=%s count=%s"}]}}\n' "$id" "$$" "$c"
              ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"pid":%s,"count":%s}}\n' "$id" "$$" "$c"
              ;;
          esac
        done
        """#

        let transport = CoreMCP.Stdio.make(
            CoreMCP.Stdio.Options(
                server: "stateful-mcp",
                command: "/bin/sh",
                args: ["-c", script],
                cwd: "/tmp"
            )
        )
        let client = CoreMCP.Client.LiveConnection(server: "stateful-mcp", transport: transport)
        try await client.performHandshake(clientInfo: ("opencode-test", "1.0.0"))

        let firstPID = try #require(transport.pid)
        #expect(firstPID > 0)
        #expect(client.title == "Stateful Shell MCP")
        #expect(client.instructions == "Persistent PID \(firstPID)")

        let tools = try await client.tools()
        #expect(tools.map(\.name) == ["bump"])

        // Multiple calls hit the SAME live process (same PID, monotonically increasing shell variable $c).
        let call1 = try await client.callTool(name: "bump", args: [:], sessionID: nil, perRequest: nil)
        let call2 = try await client.callTool(name: "bump", args: [:], sessionID: nil, perRequest: nil)
        let call3 = try await client.callTool(name: "bump", args: [:], sessionID: nil, perRequest: nil)

        #expect(transport.pid == firstPID)
        // Line 1: initialize, Line 2: notifications/initialized, Line 3: tools/list, Lines 4,5,6: tools/call
        #expect(call1.content == [.text("pid=\(firstPID) count=4")])
        #expect(call2.content == [.text("pid=\(firstPID) count=5")])
        #expect(call3.content == [.text("pid=\(firstPID) count=6")])

        try await client.close()
        #expect(transport.pid == nil)
    }

    @Test("CoreMCP StdioTransport echoes multiple messages through persistent /bin/cat without respawning")
    func persistentStdioTransportCatEcho() async throws {
        let transport = CoreMCP.Stdio.make(
            CoreMCP.Stdio.Options(server: "cat-echo", command: "/bin/cat", args: [], cwd: "/tmp")
        )
        let received = Mutex<[CoreMCP.JSONRPCMessage]>([])
        let closedCount = Mutex(0)
        transport.setHandlers(
            onMessage: { msg in received.withLock { $0.append(msg) } },
            onError: nil,
            onClose: { closedCount.withLock { $0 += 1 } }
        )

        try await transport.start()
        let pidBefore = try #require(transport.pid)

        let m1 = CoreMCP.JSONRPCMessage.notification(CoreMCP.JSONRPCNotification(method: "notifications/tools/list_changed"))
        let m2 = CoreMCP.JSONRPCMessage.notification(CoreMCP.JSONRPCNotification(method: "notifications/prompts/list_changed"))
        try await transport.send(m1)
        try await transport.send(m2)
        #expect(transport.pid == pidBefore)

        // Wait up to 2s for async stdout reader thread to deliver both lines
        for _ in 0..<100 {
            if received.withLock({ $0.count }) >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(received.withLock { $0 } == [m1, m2])

        try await transport.close()
        #expect(closedCount.withLock { $0 } == 1)
    }
    #endif

    @Test("CoreMCP StdioTransport retains injectable ProcessSpawner fallback for mock/WASI harnesses")
    func stdioTransportInjectableSpawnerFallback() async throws {
        let spawner = RealSubsystemsWiringHelper.RecordingProcessSpawner { _ in
            ProcessOutput(
                exitCode: 0,
                stdout: RealSubsystemsWiringHelper.utf8("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n"),
                stderr: []
            )
        }
        let transport = CoreMCP.Stdio.make(
            CoreMCP.Stdio.Options(server: "mock-mcp", command: "fake-mcp", args: [], cwd: "/tmp"),
            spawner: spawner
        )
        let msgs = Mutex<[CoreMCP.JSONRPCMessage]>([])
        transport.setHandlers(onMessage: { m in msgs.withLock { $0.append(m) } }, onError: nil, onClose: nil)
        try await transport.start()
        #expect(transport.pid == nil)
        try await transport.send(.request(CoreMCP.JSONRPCRequest(id: .int(1), method: "ping")))
        #expect(spawner.recordedSpecs.count == 1)
        #expect(msgs.withLock { $0.count } == 1)
        try await transport.close()
    }

    // MARK: - 2. Persistent RPCBridge ProcessTransport (P1)

    #if os(macOS) || os(Linux)
    @Test("CorePlugin RPCBridge ProcessTransport uses ONE persistent subprocess across multiple RPC calls")
    func persistentRPCBridgeProcessTransport() async throws {
        let script = #"""
        n=0
        while IFS= read -r line; do
          n=$((n + 1))
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"plugin.initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"id":"sh.rpc","hooks":[],"tools":[{"name":"counter","description":"Returns PID and call count","inputSchema":{"type":"object"}}]}}\n' "$id"
              ;;
            *'"method":"plugin.shutdown"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":true}\n' "$id"
              exit 0
              ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"pid":%s,"seq":%s}}\n' "$id" "$$" "$n"
              ;;
          esac
        done
        """#

        let transport = CorePlugin.RPCBridge.ProcessTransport(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp"
        )
        let client = CorePlugin.RPCBridge.Client(transport: transport)

        let handshake = try await client.initialize(pluginID: "sh.rpc")
        #expect(handshake.id == "sh.rpc")
        #expect(handshake.tools.map(\.name) == ["counter"])
        let childPID = try #require(transport.pid)
        #expect(childPID > 0)

        let r1 = try await client.executeTool(name: "counter", input: .object([:]))
        let r2 = try await client.executeTool(name: "counter", input: .object([:]))
        #expect(transport.pid == childPID)
        #expect(r1.output == .object(["pid": .int(Int64(childPID)), "seq": .int(2)]))
        #expect(r2.output == .object(["pid": .int(Int64(childPID)), "seq": .int(3)]))

        await client.shutdown()
        #expect(transport.pid == nil)
    }
    #endif

    // MARK: - 3. Real VcsGitPlugin + CoreVcs.Vcs.Service on a Real Git Repo (P0 #3)

    #if os(macOS) || os(Linux)
    @Test("VcsGitPlugin + CoreVcs.Vcs.Service reads real git branch, status, and unified diff")
    func vcsGitPluginReadsRealGitRepo() async throws {
        let repoDir = try await RealSubsystemsWiringHelper.makeTempGitRepo(branch: "feat-real-vcs")
        defer { RealSubsystemsWiringHelper.removeTempDir(repoDir) }

        let absPath = SchemaPrimitive.AbsolutePath(rawValue: repoDir)
        let vcs = CoreVcs.Vcs.Service(projectDirectory: absPath, detectedVcsType: "git")
        let loc = LocationSchema.Info(
            directory: absPath,
            workspaceID: nil,
            project: LocationSchema.ProjectRef(id: ProjectID(rawValue: "proj_git"), directory: absPath, canonical: absPath)
        )
        let env = CorePlugin.Host.Environment(location: loc, vcsService: vcs)
        try await env.activatePlugin(CorePlugin.VcsGitPlugin.Plugin)

        // CoreVcs.Vcs.Service returns real git branch, branches list, status, and working diff!
        let info = await vcs.info()
        #expect(info.provider == "git")
        #expect(info.branch.current == "feat-real-vcs")

        let branches = await vcs.branches()
        #expect(branches.contains("feat-real-vcs"))

        let status = await vcs.status()
        #expect(status.map(\.file) == ["hello.txt", "notes.txt"])
        let helloStatus = try #require(status.first { $0.file == "hello.txt" })
        #expect(helloStatus.status == .modified)
        #expect(helloStatus.additions.rawValue == 2)
        #expect(helloStatus.deletions.rawValue == 1)
        let notesStatus = try #require(status.first { $0.file == "notes.txt" })
        #expect(notesStatus.status == .added)
        #expect(notesStatus.additions.rawValue >= 1)

        let diffs = try await vcs.diff(.working)
        #expect(diffs.map(\.file) == ["hello.txt", "notes.txt"])
        let helloDiff = try #require(diffs.first { $0.file == "hello.txt" })
        #expect(helloDiff.patch.contains("-line2"))
        #expect(helloDiff.patch.contains("+line2-edited"))
        #expect(helloDiff.patch.contains("+line3-added"))
        let notesDiff = try #require(diffs.first { $0.file == "notes.txt" })
        #expect(notesDiff.patch.contains("brand new untracked line"))

        // Also verify ctx.vcs domain on PluginHost.Environment returns real git data!
        let ctx = CorePlugin.Host.make(environment: env, pluginID: "verifier")
        let ctxInfo = try await ctx.vcs.get()
        #expect(ctxInfo.data?.branch.current == "feat-real-vcs")
        let ctxStatus = try await ctx.vcs.status()
        #expect(ctxStatus.data.map(\.file) == ["hello.txt", "notes.txt"])
    }
    #endif

    // MARK: - 4. Built-in Core Plugins (Agent, Command, ModelsDev, Cloud Providers) (P0 #3)

    @Test("AgentPlugin registers build, plan, general, explore, compaction, title, summary with default build")
    func agentPluginRegistersBuiltins() async throws {
        let env = CorePlugin.Host.Environment()
        try await env.activatePlugin(CorePlugin.AgentPlugin.Plugin)

        #expect(env.defaultAgentID() == "build")
        let agents = env.registeredAgents()
        let ids = Set(agents.map(\.id.rawValue))
        #expect(ids.contains("build"))
        #expect(ids.contains("plan"))
        #expect(ids.contains("general"))
        #expect(ids.contains("explore"))
        #expect(ids.contains("title"))
        #expect(ids.contains("summary"))

        let build = try #require(agents.first { $0.id.rawValue == "build" })
        #expect(build.mode == .primary)
        #expect(!build.hidden)
        #expect(build.name.rawValue == "Build")

        let explore = try #require(agents.first { $0.id.rawValue == "explore" })
        #expect(explore.mode == .subagent)
        #expect(explore.system?.contains("EXCLUSIVELY to search and analyze") == true)

        let general = try #require(agents.first { $0.id.rawValue == "general" })
        #expect(general.mode == .subagent)

        let title = try #require(agents.first { $0.id.rawValue == "title" })
        #expect(title.hidden == true)
        #expect(title.system != nil)
    }

    @Test("CommandPlugin renders real /init and /review prompt templates and dispatches to session.prompt")
    func commandPluginRendersPromptTemplates() async throws {
        let projectPath = SchemaPrimitive.AbsolutePath(rawValue: "/workspace/my-swift-app")
        let loc = LocationSchema.Info(
            directory: projectPath,
            workspaceID: nil,
            project: LocationSchema.ProjectRef(id: ProjectID(rawValue: "proj_cmd"), directory: projectPath, canonical: projectPath)
        )
        let env = CorePlugin.Host.Environment(location: loc)
        try await env.activatePlugin(CorePlugin.CommandPlugin.Plugin)

        let cmds = env.registeredCommands()
        let initCmd = try #require(cmds.first { $0.name == "init" })
        let reviewCmd = try #require(cmds.first { $0.name == "review" })

        let sesID = SessionID.create()
        try await initCmd.execute(PluginEffect.CommandInvocation(
            sessionID: sesID,
            prompt: PromptInputSchema.Prompt(text: "focus on Swift 6 rules"),
            delivery: .steer
        ))
        try await reviewCmd.execute(PluginEffect.CommandInvocation(
            sessionID: sesID,
            prompt: PromptInputSchema.Prompt(text: "HEAD~1"),
            delivery: .queue
        ))

        let recorded = env.recordedSessionPrompts()
        #expect(recorded.count == 2)
        #expect(recorded[0].prompt.text.contains("AGENTS.md"))
        #expect(recorded[0].prompt.text.contains("/workspace/my-swift-app"))
        #expect(recorded[0].prompt.text.contains("focus on Swift 6 rules"))
        #expect(recorded[1].prompt.text.contains("code reviewer"))
        #expect(recorded[1].prompt.text.contains("HEAD~1"))
    }

    @Test("ModelsDevPlugin and built-in cloud provider plugins register real metadata, base URLs, headers, and env auth")
    func modelsDevAndCloudProviderPlugins() async throws {
        let mockEnv = RealSubsystemsWiringHelper.MockEnv(vars: [
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "OPENAI_API_KEY": "sk-openai-test",
            "OPENROUTER_API_KEY": "sk-or-test",
            "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE",
            "AWS_REGION": "eu-west-2",
            "GOOGLE_VERTEX_PROJECT": "demo-gcp-proj",
            "GOOGLE_VERTEX_LOCATION": "us",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/adc.json",
            "CEREBRAS_API_KEY": "csk-test",
            "XAI_API_KEY": "xai-test",
            "GROQ_API_KEY": "gsk-test",
            "DEEPSEEK_API_KEY": "ds-test",
            "MISTRAL_API_KEY": "ms-test",
            "OPENCODE_API_KEY": "oc-test",
        ])
        let env = CorePlugin.Host.Environment(environment: mockEnv)
        let service = CorePlugin.Service(environment: env)

        let pluginsToActivate: [PluginEffect.Plugin] = [
            CorePlugin.ModelsDevPlugin,
            CorePlugin.AnthropicPlugin,
            CorePlugin.OpenAIPlugin,
            CorePlugin.GooglePlugin,
            CorePlugin.AmazonBedrockPlugin,
            CorePlugin.OpenRouterPlugin,
            CorePlugin.AzureProvider.AzurePlugin,
            CorePlugin.GoogleVertexPlugin,
            CorePlugin.XAIPlugin,
            CorePlugin.GroqPlugin,
            CorePlugin.DeepSeekPlugin,
            CorePlugin.MistralPlugin,
            CorePlugin.CerebrasPlugin,
            CorePlugin.OpencodePlugin,
            CorePlugin.OllamaProvider.OllamaPlugin,
        ]
        try await service.activate(pluginsToActivate.map {
            CorePlugin.Generation(plugin: $0, revision: "v1", source: .builtin)
        })

        let providers = Dictionary(uniqueKeysWithValues: env.registeredProviders().map { ($0.provider.id.rawValue, $0) })

        // ModelsDev loaded built-in models + providers and enabled those with env vars set
        let anthropic = try #require(providers["anthropic"])
        #expect(anthropic.provider.activation == .enabled)
        #expect(anthropic.provider.settings?.extra["baseURL"] == .string("https://api.anthropic.com/v1"))
        #expect(!anthropic.models.isEmpty)

        let openai = try #require(providers["openai"])
        #expect(openai.provider.activation == .enabled)
        #expect(openai.provider.settings?.extra["baseURL"] == .string("https://api.openai.com/v1"))
        #expect(openai.models["gpt-5"] != nil)

        // Google has no env key in mockEnv -> stays .auto
        let google = try #require(providers["google"])
        #expect(google.provider.activation == .auto)
        #expect(google.provider.settings?.extra["baseURL"] == .string("https://generativelanguage.googleapis.com/v1beta"))

        // Amazon Bedrock detects AWS_ACCESS_KEY_ID chain + region
        let bedrock = try #require(providers["amazon-bedrock"])
        #expect(bedrock.provider.activation == .enabled)
        #expect(bedrock.provider.settings?.extra["region"] == .string("eu-west-2"))

        // OpenRouter injects HTTP-Referer + X-Title headers
        let openrouter = try #require(providers["openrouter"])
        #expect(openrouter.provider.activation == .enabled)
        #expect(openrouter.provider.headers?["HTTP-Referer"] == "https://opencode.ai/")
        #expect(openrouter.provider.headers?["X-Title"] == "opencode")

        // Cerebras injects third-party integration header
        let cerebras = try #require(providers["cerebras"])
        #expect(cerebras.provider.activation == .enabled)
        #expect(cerebras.provider.headers?["X-Cerebras-3rd-Party-Integration"] == "opencode")

        // Google Vertex resolves regional multi-region endpoint and ADC ambient activation
        let vertex = try #require(providers["google-vertex"])
        #expect(vertex.provider.activation == .enabled)
        #expect(vertex.provider.settings?.extra["project"] == .string("demo-gcp-proj"))
        #expect(vertex.provider.settings?.extra["baseURL"] == .string("https://aiplatform.us.rep.googleapis.com/v1/projects/demo-gcp-proj/locations/us"))

        // Ollama local provider registered default base URL
        let ollama = try #require(providers["ollama"])
        #expect(ollama.provider.settings?.extra["baseURL"] == .string("http://127.0.0.1:11434/v1"))

        // Opencode, Groq, DeepSeek, Mistral, xAI all enabled via env
        #expect(providers["opencode"]?.provider.activation == .enabled)
        #expect(providers["groq"]?.provider.activation == .enabled)
        #expect(providers["deepseek"]?.provider.activation == .enabled)
        #expect(providers["mistral"]?.provider.activation == .enabled)
        #expect(providers["xai"]?.provider.activation == .enabled)

        await service.close()
    }

    // MARK: - 5. All 5 WebSearch Plugins Wired Over HTTPTransport (P0 #3)

    @Test("All 5 WebSearch plugins (Exa, Firecrawl, Parallel, Tavily, TinyFish) execute real HTTP requests over HTTPTransport")
    func allFiveWebSearchPluginsExecuteRealHTTP() async throws {
        let mockEnv = RealSubsystemsWiringHelper.MockEnv(vars: [
            "EXA_API_KEY": "exa-secret",
            "FIRECRAWL_API_KEY": "fc-secret",
            "PARALLEL_API_KEY": "par-secret",
            "TAVILY_API_KEY": "tav-secret",
            "TINYFISH_API_KEY": "tf-secret",
        ])
        let mockHTTP = RealSubsystemsWiringHelper.RecordingHTTPTransport { req in
            if req.url.hasPrefix(CorePlugin.WebSearchExa.endpoint) {
                let text = "Title: Swift 6.2 Guide\nURL: https://swift.org/6.2\nPublished: 2026-01-15T00:00:00Z\nHighlights: Strict concurrency\n\n---\n\nTitle: OpenCode\nURL: https://opencode.ai\nText: Agentic coding"
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
                ]))
            }
            if req.url == CorePlugin.WebSearchFirecrawl.endpoint {
                let inner = #"{"success":true,"data":{"web":[{"url":"https://firecrawl.dev/doc","title":"Firecrawl Docs","description":"Crawl fast"}]}}"#
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(inner)])])]),
                ]))
            }
            if req.url == CorePlugin.WebSearchParallel.endpoint {
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object([
                        "content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
                        "structuredContent": .object([
                            "search_id": .string("s1"),
                            "session_id": .string("ses1"),
                            "results": .array([
                                .object([
                                    "url": .string("https://parallel.ai/result"),
                                    "title": .string("Parallel Hit"),
                                    "publish_date": .string("2026-03-01"),
                                    "excerpts": .array([.string("Excerpt one"), .string("Excerpt two")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]))
            }
            if req.url == CorePlugin.WebSearchTavily.endpoint {
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "results": .array([
                        .object([
                            "title": .string("Tavily Hit"),
                            "url": .string("https://tavily.com/hit"),
                            "content": .string("Tavily snippet"),
                        ]),
                    ]),
                ]))
            }
            if req.url == CorePlugin.WebSearchTinyFish.endpoint {
                let decoded = try RealSubsystemsWiringHelper.decodeJSON(req.body ?? [])
                if case .object(let obj) = decoded, case .string(let method) = obj["method"] {
                    if method == "initialize" {
                        return try RealSubsystemsWiringHelper.jsonResponse(
                            headers: ["Mcp-Session-Id": "tf-sess-99"],
                            body: .object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object([:])])
                        )
                    }
                    if method == "notifications/initialized" {
                        return RealSubsystemsWiringHelper.textResponse(202, body: "")
                    }
                    if method == "tools/call" {
                        let inner = #"{"results":[{"url":"https://tinyfish.ai/hit","title":"TinyFish Hit","snippet":"Tiny snippet"}]}"#
                        return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                            "jsonrpc": .string("2.0"),
                            "id": .int(1),
                            "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(inner)])])]),
                        ]))
                    }
                }
            }
            return RealSubsystemsWiringHelper.textResponse(404, body: "unexpected \(req.url)")
        }

        let env = CorePlugin.Host.Environment(http: mockHTTP, environment: mockEnv)
        for plugin in CorePlugin.WebSearchPlugins {
            try await env.activatePlugin(plugin)
        }
        let ctx = CorePlugin.Host.make(environment: env, pluginID: "test")

        let exa = try await ctx.websearch.query(WebSearchSchema.Input(query: "swift 6.2", providerID: .init(rawValue: "exa"))).data
        #expect(exa.results.count == 2)
        #expect(exa.results[0].url == "https://swift.org/6.2")
        #expect(exa.results[0].title == "Swift 6.2 Guide")

        let firecrawl = try await ctx.websearch.query(WebSearchSchema.Input(query: "crawl", providerID: .init(rawValue: "firecrawl"))).data
        #expect(firecrawl.results.count == 1)
        #expect(firecrawl.results[0].url == "https://firecrawl.dev/doc")
        #expect(firecrawl.results[0].content == "Crawl fast")

        let parallel = try await ctx.websearch.query(WebSearchSchema.Input(query: "parallel", providerID: .init(rawValue: "parallel"))).data
        #expect(parallel.results.count == 1)
        #expect(parallel.results[0].url == "https://parallel.ai/result")
        #expect(parallel.results[0].content == "Excerpt one\n\nExcerpt two")

        let tavily = try await ctx.websearch.query(WebSearchSchema.Input(query: "tavily", providerID: .init(rawValue: "tavily"))).data
        #expect(tavily.results.count == 1)
        #expect(tavily.results[0].url == "https://tavily.com/hit")

        let tinyfish = try await ctx.websearch.query(WebSearchSchema.Input(query: "tiny", providerID: .init(rawValue: "tinyfish"))).data
        #expect(tinyfish.results.count == 1)
        #expect(tinyfish.results[0].url == "https://tinyfish.ai/hit")
        #expect(tinyfish.results[0].content == "Tiny snippet")

        // Verify auth credentials & TinyFish MCP session handshake were sent over the wire
        let reqs = mockHTTP.requests
        #expect(reqs.contains { $0.url.contains("exaApiKey=exa-secret") })
        #expect(reqs.contains { $0.url == CorePlugin.WebSearchFirecrawl.endpoint && $0.headers["Authorization"] == "Bearer fc-secret" })
        #expect(reqs.contains { $0.url == CorePlugin.WebSearchParallel.endpoint && $0.headers["Authorization"] == "Bearer par-secret" })
        #expect(reqs.contains { $0.url == CorePlugin.WebSearchTavily.endpoint && $0.headers["Authorization"] == "Bearer tav-secret" && $0.headers["X-Client-Name"] == "opencode2" })
        #expect(reqs.contains { $0.url == CorePlugin.WebSearchTinyFish.endpoint && $0.headers["X-API-Key"] == "tf-secret" && $0.headers["Mcp-Session-Id"] == "tf-sess-99" })
    }

    // MARK: - 6. Real Voice Service Calling AIExperimental.Realtime.connect (P0 #11)

    @Test("CoreIntegration.Voice.Service resolves credentials and calls real AIExperimental.Realtime.connect over HTTPTransport")
    func voiceServiceCallsRealRealtimeConnect() async throws {
        let creds = try CoreProvider.Credential.Service.inMemory()
        let mockEnv = RealSubsystemsWiringHelper.MockEnv(vars: ["XAI_API_KEY": "xai-live-key"])
        let integrations = CoreIntegration.Integration.Service(credentials: creds, environment: mockEnv)
        _ = try await integrations.transform { editor in
            editor.update(IntegrationID(rawValue: "xai")) { ref in
                CoreIntegration.Integration.Ref(id: ref.id, name: "xAI")
            }
            editor.updateMethod(.env(CoreIntegration.Integration.EnvImplementation(
                integrationID: IntegrationID(rawValue: "xai"),
                method: IntegrationSchema.EnvMethod(names: ["XAI_API_KEY"])
            )))
            editor.update(IntegrationID(rawValue: "opencode")) { ref in
                CoreIntegration.Integration.Ref(id: ref.id, name: "OpenCode")
            }
        }
        // Also connect OpenCode Console key with orgID to test hosted GPT-Live fallback!
        try await integrations.connectKey(
            integrationID: IntegrationID(rawValue: "opencode"),
            key: "oc-hosted-key",
            answer: ["orgID": .string("org_voice_42")],
            label: "Console"
        )

        let mockHTTP = RealSubsystemsWiringHelper.RecordingHTTPTransport { req in
            if req.url == "https://api.x.ai/v1/realtime/client_secrets" {
                #expect(req.headers["authorization"] == "Bearer xai-live-key")
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "value": .string("xai-ephemeral-token-123"),
                    "expires_at": .double(1_800_000_000),
                ]))
            }
            if req.url == "https://opencode.ai/inference/openai/v1/live/sessions" {
                #expect(req.headers["authorization"] == "Bearer oc-hosted-key")
                #expect(req.headers["x-opencode-org-id"] == "org_voice_42")
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "transport": .object([
                        "type": .string("webrtc"),
                        "sdp": .string("v=0\r\ns=answer-sdp"),
                    ]),
                ]))
            }
            return RealSubsystemsWiringHelper.textResponse(404, body: "unexpected \(req.url)")
        }

        let voice = CoreIntegration.Voice.Service(integrations: integrations, http: mockHTTP)

        let models = try await voice.models()
        let grokInfo = try #require(models.models.first { $0.model == "grok-voice-3.0" })
        #expect(grokInfo.name == "Grok Voice 3.0")
        #expect(grokInfo.engine == "xai-realtime")
        #expect(grokInfo.available == true)
        let liveInfo = try #require(models.models.first { $0.model == "gpt-live-1" })
        #expect(liveInfo.name == "GPT-Live 1")
        #expect(liveInfo.engine == "openai-live")
        #expect(liveInfo.provider == "opencode")
        #expect(liveInfo.available == true)
        // Because OpenCode only hosts gpt-live-1 (not gpt-live-1.1), gpt-live-1.1 is not listed when hosted via opencode.
        #expect(!models.models.contains { $0.model == "gpt-live-1.1" })
        #expect(models.models.first { $0.model == "gemini-3.8-live" }?.available == false)

        // Real WebSocket ephemeral token negotiation for xAI grok-voice-3.0
        let xaiSession = try await voice.session(CoreIntegration.Voice.SessionInput(
            model: "grok-voice-3.0",
            transport: "websocket"
        ))
        #expect(xaiSession["type"] == .string("websocket"))
        #expect(xaiSession["url"] == .string("wss://api.x.ai/v1/realtime?model=grok-voice-3.0"))
        #expect(xaiSession["token"] == .string("xai-ephemeral-token-123"))
        #expect(xaiSession["expiresAt"] == .double(1_800_000_000))

        // Real WebRTC SDP exchange for OpenCode-hosted gpt-live-1
        let liveSession = try await voice.session(CoreIntegration.Voice.SessionInput(
            model: "gpt-live-1",
            transport: "webrtc",
            sdp: "v=0\r\ns=offer-sdp"
        ))
        #expect(liveSession["type"] == .string("webrtc"))
        #expect(liveSession["sdp"] == .string("v=0\r\ns=answer-sdp"))

        // Missing Google API key throws UnavailableError; unknown/unlisted model throws InvalidRequestError listing server models
        await #expect(throws: CoreIntegration.Voice.UnavailableError.self) {
            _ = try await voice.session(CoreIntegration.Voice.SessionInput(model: "gemini-3.8-live", transport: "websocket"))
        }
        do {
            _ = try await voice.session(CoreIntegration.Voice.SessionInput(model: "gpt-live-1.1", transport: "webrtc", sdp: "v=0"))
            Issue.record("Expected InvalidRequestError for unlisted voice model")
        } catch let err as CoreIntegration.Voice.InvalidRequestError {
            #expect(err.message.hasPrefix("Unsupported voice model: gpt-live-1.1. This server lists "))
            #expect(err.message.contains("gpt-live-1"))
            #expect(err.message.contains("grok-voice-3.0"))
        }
    }

    @Test("CoreIntegration.Voice.Service sorts models.dev voice models newest-first per engine and picks first available default")
    func voiceServiceListsFromModelsDevCatalogNewestFirst() async throws {
        let creds = try CoreProvider.Credential.Service.inMemory()
        let integrations = CoreIntegration.Integration.Service(
            credentials: creds,
            environment: RealSubsystemsWiringHelper.MockEnv(vars: [:])
        )
        _ = try await integrations.transform { editor in
            editor.update(IntegrationID(rawValue: "openai")) { ref in
                CoreIntegration.Integration.Ref(id: ref.id, name: "OpenAI")
            }
            editor.update(IntegrationID(rawValue: "opencode")) { ref in
                CoreIntegration.Integration.Ref(id: ref.id, name: "OpenCode")
            }
        }
        try await integrations.connectKey(
            integrationID: IntegrationID(rawValue: "openai"),
            key: "sk-openai-voice",
            answer: nil,
            label: "Active"
        )

        func makeSnap(_ id: String, voices: [CoreModel.ModelsDev.VoiceModel]) -> CoreModel.ModelsDev.Snapshot {
            CoreModel.ModelsDev.Snapshot(
                info: ProviderSchema.Info(
                    id: ProviderSchema.ID(rawValue: id),
                    name: id,
                    activation: .auto,
                    package: "@opencode/ai/providers/openai"
                ),
                models: [],
                voices: voices,
                environment: []
            )
        }

        let catalog = CoreModel.ModelsDev.StaticService(snapshots: [
            makeSnap("openai", voices: [
                CoreModel.ModelsDev.VoiceModel(id: "gpt-live-1", name: "GPT-Live 1", api: "live", releaseDate: "2026-09-10"),
                CoreModel.ModelsDev.VoiceModel(id: "gpt-realtime-2.1", name: "GPT-Realtime-2.1", api: "realtime", releaseDate: "2026-07-06"),
                CoreModel.ModelsDev.VoiceModel(id: "gpt-live-1.1", name: "GPT-Live 1.1", api: "live", releaseDate: "2026-11-19"),
            ]),
            makeSnap("xai", voices: [
                CoreModel.ModelsDev.VoiceModel(id: "grok-voice-3.0", name: "Grok Voice 3.0", api: "realtime", releaseDate: "2026-10-14"),
            ]),
            makeSnap("google", voices: [
                CoreModel.ModelsDev.VoiceModel(id: "gemini-3.8-live", name: "Gemini 3.8 Live", api: "bidi-generate-content", releaseDate: "2026-09-15"),
            ]),
            makeSnap("opencode", voices: [
                CoreModel.ModelsDev.VoiceModel(id: "gpt-live-1", name: "GPT-Live 1", api: "live", releaseDate: "2026-09-10"),
            ]),
        ])

        let voice = CoreIntegration.Voice.Service(integrations: integrations, modelsDev: catalog)
        let listed = try await voice.models()
        #expect(listed.defaultModel == "gpt-live-1.1")
        #expect(listed.models == [
            CoreIntegration.Voice.ModelInfo(model: "gpt-live-1.1", name: "GPT-Live 1.1", engine: "openai-live", provider: "openai", transports: ["webrtc"], available: true),
            CoreIntegration.Voice.ModelInfo(model: "gpt-live-1", name: "GPT-Live 1", engine: "openai-live", provider: "openai", transports: ["webrtc"], available: true),
            CoreIntegration.Voice.ModelInfo(model: "gpt-realtime-2.1", name: "GPT-Realtime-2.1", engine: "openai-realtime", provider: "openai", transports: ["webrtc", "websocket"], available: true),
            CoreIntegration.Voice.ModelInfo(model: "grok-voice-3.0", name: "Grok Voice 3.0", engine: "xai-realtime", provider: "xai", transports: ["websocket"], available: false),
            CoreIntegration.Voice.ModelInfo(model: "gemini-3.8-live", name: "Gemini 3.8 Live", engine: "gemini-live", provider: "google", transports: ["websocket"], available: false),
        ])
    }

    // MARK: - 7. Real Generate Service (text, image, decisions over OpenCodeAI routes) (P0 #11)

    @Test("CoreIntegration.Generate.Service executes real text, image, and decision routes over HTTPTransport and throws clean typed errors when unconfigured")
    func generateServiceRealRoutesAndTypedErrors() async throws {
        let providers = CoreProvider.Provider.Service()
        let chatModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5"),
            modelID: ModelSchema.ID(rawValue: "gpt-5"),
            providerID: .openai,
            name: "GPT-5",
            package: "@opencode/ai/providers/openai/chat",
            settings: ModelSchema.Settings(extra: ["apiKey": .string("sk-gen-test")]),
            capabilities: ModelSchema.Capabilities.default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 1),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 128_000, output: 16_000)
        )
        let imageModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-image-1"),
            modelID: ModelSchema.ID(rawValue: "gpt-image-1"),
            providerID: .openai,
            type: .image,
            name: "GPT Image 1",
            package: "@opencode/ai/providers/openai/images",
            settings: ModelSchema.Settings(extra: ["apiKey": .string("sk-gen-test")]),
            capabilities: ModelSchema.Capabilities(tools: false, input: ["text"], output: ["image"]),
            variants: [],
            time: ModelSchema.Info.Time(released: 1),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 0, output: 0)
        )
        let decisionModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "decider-1"),
            modelID: ModelSchema.ID(rawValue: "decider-1"),
            providerID: .openai,
            type: .decision,
            name: "Decider 1",
            package: "@opencode/ai/providers/openai-compatible/decisions",
            settings: ModelSchema.Settings(extra: ["apiKey": .string("sk-gen-test")]),
            capabilities: ModelSchema.Capabilities(tools: false, input: ["text"], output: ["decision"]),
            variants: [],
            time: ModelSchema.Info.Time(released: 1),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 0, output: 0)
        )
        _ = try await providers.transform { editor in
            editor.add(
                info: ProviderSchema.Info(id: .openai, name: "OpenAI", activation: .enabled, package: "@opencode/ai/providers/openai"),
                models: [chatModel, imageModel, decisionModel]
            )
        }
        let models = CoreModel.Model.Service(providers: providers)
        let resolver = CoreModel.Resolver.Service(providers: providers, models: models)

        // 1. Unconfigured transport throws clean typed UnavailableError
        let unconfigured = CoreIntegration.Generate.Service(resolver: resolver, models: models, http: nil)
        await #expect(throws: CoreIntegration.Generate.UnavailableError.self) {
            _ = try await unconfigured.text(.init(prompt: "hello", model: ModelSchema.Ref(id: chatModel.id, providerID: .openai)))
        }
        // Mismatched capability (calling image on a chat model) throws UnsupportedModelError
        await #expect(throws: CoreIntegration.Generate.UnsupportedModelError.self) {
            _ = try await unconfigured.image(GenerateSchema.ImageRequest(
                model: ModelSchema.Ref(id: chatModel.id, providerID: .openai),
                prompt: "draw a cat"
            ))
        }

        // 2. Configured transport executes real OpenCodeAI chat, image, and decision HTTP calls
        let sampleB64 = bytesToBase64(RealSubsystemsWiringHelper.makePNG(width: 64, height: 64))
        let mockHTTP = RealSubsystemsWiringHelper.RecordingHTTPTransport { req in
            let authHeader = req.headers.first { $0.key.lowercased() == "authorization" }?.value
            if req.url.hasSuffix("/chat/completions") {
                #expect(authHeader == "Bearer sk-gen-test")
                let sse = "data: {\"id\":\"cmpl_1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello \"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"cmpl_1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Swift!\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                return RealSubsystemsWiringHelper.textResponse(200, headers: ["content-type": "text/event-stream"], body: sse)
            }
            if req.url.hasSuffix("/images/generations") {
                #expect(authHeader == "Bearer sk-gen-test")
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "data": .array([.object(["b64_json": .string(sampleB64)])]),
                    "usage": .object(["input_tokens": .int(10), "output_tokens": .int(100)]),
                ]))
            }
            if req.url.hasSuffix("/decisions") {
                #expect(authHeader == "Bearer sk-gen-test")
                return try RealSubsystemsWiringHelper.jsonResponse(body: .object([
                    "model": .string("decider-1"),
                    "answers": .object([
                        "is_swift": .double(0.95),
                    ]),
                    "usage": .object(["input_tokens": .int(12), "output_tokens": .int(4), "cost": .double(0.001)]),
                ]))
            }
            return RealSubsystemsWiringHelper.textResponse(404, body: "unexpected \(req.url)")
        }

        let generate = CoreIntegration.Generate.Service(resolver: resolver, models: models, http: mockHTTP)

        let textOut = try await generate.text(.init(prompt: "Say hello", model: ModelSchema.Ref(id: chatModel.id, providerID: .openai)))
        #expect(textOut == "Hello Swift!")

        let imgOut = try await generate.image(GenerateSchema.ImageRequest(
            model: ModelSchema.Ref(id: imageModel.id, providerID: .openai),
            prompt: "A minimal logo",
            n: SchemaPrimitive.PositiveInt(rawValue: 1)
        ))
        #expect(imgOut.images.count == 1)
        #expect(imgOut.images[0].data == sampleB64)
        #expect(imgOut.images[0].mime == "image/png")
        #expect(imgOut.tokens?.input == 10)

        let decOut = try await generate.decisions(GenerateSchema.DecisionRequest(
            model: ModelSchema.Ref(id: decisionModel.id, providerID: .openai),
            input: [.text(.init(text: "actor MyStore: Sendable {}"))],
            questions: [.predicate(.init(name: "is_swift", instructions: "Is this Swift code?"))]
        ))
        #expect(decOut.answers == [.predicate(.init(name: "is_swift", probability: 0.95))])
        #expect(decOut.tokens?.input == 12)
        #expect(decOut.cost?.rawValue == 0.001)
    }

    // MARK: - 8. Pure-Swift Image Dimension Probing for PNG, GIF, JPEG (SOF0/SOF2), WebP (VP8/VP8L/VP8X) (P1)

    @Test("NativePhoton probes real dimensions for PNG, GIF, JPEG SOF0/SOF2, and WebP VP8/VP8L/VP8X")
    func nativePhotonImageDimensionProbing() async throws {
        let photon = CoreIntegration.Image.PhotonNormalize.NativePhoton()

        let png = photon.dimensions(of: RealSubsystemsWiringHelper.makePNG(width: 640, height: 480))
        #expect(png?.width == 640 && png?.height == 480)

        let gif = photon.dimensions(of: RealSubsystemsWiringHelper.makeGIF(width: 320, height: 240))
        #expect(gif?.width == 320 && gif?.height == 240)

        let jpegSOF0 = photon.dimensions(of: RealSubsystemsWiringHelper.makeJPEG(width: 1920, height: 1080, progressive: false))
        #expect(jpegSOF0?.width == 1920 && jpegSOF0?.height == 1080)

        let jpegSOF2 = photon.dimensions(of: RealSubsystemsWiringHelper.makeJPEG(width: 800, height: 600, progressive: true))
        #expect(jpegSOF2?.width == 800 && jpegSOF2?.height == 600)

        let webpVP8 = photon.dimensions(of: RealSubsystemsWiringHelper.makeWebPVP8(width: 1280, height: 720))
        #expect(webpVP8?.width == 1280 && webpVP8?.height == 720)

        let webpVP8L = photon.dimensions(of: RealSubsystemsWiringHelper.makeWebPVP8L(width: 512, height: 384))
        #expect(webpVP8L?.width == 512 && webpVP8L?.height == 384)

        let webpVP8X = photon.dimensions(of: RealSubsystemsWiringHelper.makeWebPVP8X(width: 3840, height: 2160))
        #expect(webpVP8X?.width == 3840 && webpVP8X?.height == 2160)

        // Corrupt / unknown bytes return nil cleanly without crashing
        #expect(photon.dimensions(of: [0x00, 0x01, 0x02, 0x03]) == nil)
        #expect(photon.dimensions(of: [0xFF, 0xD8, 0xFF, 0xE0, 0x00]) == nil)

        // End-to-end CoreIntegration.Image.Service.normalize enforces real JPEG/WebP dimensions!
        let imageService = CoreIntegration.Image.Service()
        let hugeWebP = bytesToBase64(RealSubsystemsWiringHelper.makeWebPVP8X(width: 3840, height: 2160))
        do {
            _ = try await imageService.normalize(
                resource: "banner.webp",
                content: .init(content: hugeWebP, mime: "image/webp")
            )
            Issue.record("Expected oversized WebP to throw SizeError")
        } catch let err as CoreIntegration.Image.SizeError {
            #expect(err.width == 3840)
            #expect(err.height == 2160)
        }

        let smallJPEG = bytesToBase64(RealSubsystemsWiringHelper.makeJPEG(width: 800, height: 600, progressive: true))
        let unchanged = try await imageService.normalize(
            resource: "thumb.jpg",
            content: .init(content: smallJPEG, mime: "image/jpeg")
        )
        #expect(unchanged.content == smallJPEG)
    }
}
