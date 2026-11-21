import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Fixtures

enum CoreToolsSyncFixture {
    static func model(
        id: String,
        modelID: String? = nil,
        providerID: String = "test",
        canonical: String? = nil,
        family: String? = nil
    ) -> ModelSchema.Info {
        ModelSchema.Info(
            id: ModelSchema.ID(rawValue: id),
            modelID: ModelSchema.ID(rawValue: modelID ?? id),
            providerID: ProviderSchema.ID(rawValue: providerID),
            canonical: canonical.map { ProviderSchema.ID(rawValue: $0) },
            family: family.map { ModelSchema.Family(rawValue: $0) },
            name: id,
            capabilities: ModelSchema.Capabilities(tools: true, input: ["text"], output: ["text"]),
            variants: [],
            time: ModelSchema.Info.Time(released: 0),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 1_000, input: nil, output: 1_000)
        )
    }

    static func context() -> ToolSchema.Context {
        ToolSchema.Context(
            sessionID: SessionID(rawValue: "ses_sync_001")!,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_001",
            id: ToolSchema.CallID(rawValue: "call_001"),
            progress: { _ in }
        )
    }

    static func tool(
        _ name: String,
        options: ToolSchema.Options? = nil,
        codemode: CoreTool.CodeModeOverrides? = nil
    ) -> CoreTool.RegisteredTool {
        CoreTool.RegisteredTool(
            name: name,
            description: "\(name) tool",
            outputSchema: ["type": .string("string")],
            options: options,
            codemode: codemode
        ) { _, _ in
            ToolSchema.Result(output: .string(CoreTool.Runtime.inCodeMode ? "codemode" : "direct"))
        }
    }

    static let transport = LayerNodePlatform.FetchTransport { _ in
        throw PlatformError.ioFailure("no network in tests")
    }
}

final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

// MARK: - Model tool policy

@Suite("Core tool model policy (tool/model-policy.ts)")
struct CoreToolModelPolicyTests {
    @Test("GPT-5 edits with patch; Claude and GPT-4 edit with edit and write")
    func editMode() {
        let gpt5 = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "gpt-5"), websearch: true, fullCodeMode: false)
        #expect(gpt5.hidden == ["edit", "write"])
        #expect(gpt5.direct.isEmpty)

        let claude = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "claude-sonnet-5"), websearch: true, fullCodeMode: false)
        #expect(claude.hidden == ["patch"])

        let gpt4 = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "gpt-4o"), websearch: true, fullCodeMode: false)
        #expect(gpt4.hidden == ["patch"])

        let oss = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "gpt-oss-120b"), websearch: true, fullCodeMode: false)
        #expect(oss.hidden == ["patch"])

        let unresolved = CoreTool.ModelPolicy.modelTools(model: nil, websearch: false, fullCodeMode: false)
        #expect(unresolved.hidden == ["websearch"])
    }

    @Test("full Code Mode hides search tools and places built-ins in Code Mode for all models")
    func fullCodeMode() {
        let weak = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "llama-4"), websearch: true, fullCodeMode: true)
        #expect(weak.hidden == ["glob", "grep", "webfetch", "patch"])
        #expect(weak.direct.isEmpty)

        let strong = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "gpt-5.1"), websearch: false, fullCodeMode: true)
        #expect(strong.direct.isEmpty)
        #expect(strong.hidden == ["glob", "grep", "webfetch", "websearch", "edit", "write"])

        let unresolved = CoreTool.ModelPolicy.modelTools(model: nil, websearch: true, fullCodeMode: true)
        #expect(unresolved.direct.isEmpty)
        #expect(unresolved.hidden == ["glob", "grep", "webfetch"])
    }
}

// MARK: - Registry placement & runtime

@Suite("Core tool registry placement (tool.ts, tool/runtime.ts)")
struct CoreToolPlacementTests {
    @Test("defaultCodeMode, codeModeAvailable and Code Mode overrides in definitions")
    func runtimeHelpers() {
        #expect(CoreTool.Runtime.defaultCodeMode(nil))
        #expect(CoreTool.Runtime.defaultCodeMode(ToolSchema.Options(codemode: true)))
        #expect(!CoreTool.Runtime.defaultCodeMode(ToolSchema.Options(codemode: false)))
        #expect(CoreTool.codeModeAvailable([]))
        #expect(!CoreTool.codeModeAvailable([PermissionSchema.Rule(action: "execute", resource: "*", effect: .deny)]))

        let tool = CoreToolsSyncFixture.tool(
            "shell",
            options: ToolSchema.Options(codemode: true, pinned: true),
            codemode: CoreTool.CodeModeOverrides(description: "inside", input: ["type": .string("object"), "required": .array([.string("command")])])
        )
        #expect(CoreTool.Runtime.definition(tool).description == "shell tool")
        #expect(CoreTool.Runtime.definition(tool, codemode: true).description == "inside")
        #expect(CoreTool.Runtime.definition(tool, codemode: true).inputSchema["required"] == .array([.string("command")]))
    }

    @Test("execute validates against the Code Mode input and marks the call as inside Code Mode")
    func executeInCodeMode() async throws {
        let tool = CoreToolsSyncFixture.tool(
            "shell",
            options: ToolSchema.Options(codemode: true),
            codemode: CoreTool.CodeModeOverrides(input: ["type": .string("object"), "required": .array([.string("command")])])
        )
        let direct = try await CoreTool.Runtime.execute(tool, input: .object([:]), context: CoreToolsSyncFixture.context())
        #expect(direct.output == .string("direct"))
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await CoreTool.Runtime.execute(tool, input: .object([:]), context: CoreToolsSyncFixture.context(), codemode: true)
        }
        let inside = try await CoreTool.Runtime.execute(
            tool,
            input: .object(["command": .string("ls")]),
            context: CoreToolsSyncFixture.context(),
            codemode: true
        )
        #expect(inside.output == .string("codemode"))
    }

    @Test("the policy hides tools and, without a Code Mode host, every visible tool stays direct")
    func policyWithoutCodeMode() async {
        let registry = CoreTool.Service()
        _ = await registry.transform { editor in
            editor.add(CoreToolsSyncFixture.tool("read", options: ToolSchema.Options(codemode: true)))
            editor.add(CoreToolsSyncFixture.tool("patch", options: ToolSchema.Options(codemode: false)))
            editor.add(CoreToolsSyncFixture.tool("edit", options: ToolSchema.Options(codemode: false)))
        }
        let policy = CoreTool.ModelPolicy.modelTools(model: CoreToolsSyncFixture.model(id: "gpt-5"), websearch: true, fullCodeMode: false).policy
        let snapshot = await registry.snapshot(permissions: nil, options: CoreTool.SnapshotOptions(tools: policy))
        #expect(snapshot.definitions.map(\.name) == ["patch", "read"])
    }

    @Test("with a Code Mode host, tools that allow it move behind execute unless kept direct")
    func placementWithCodeMode() async throws {
        let registry = CoreTool.Service(codeMode: CoreTool.CodeModeHost(transport: CoreToolsSyncFixture.transport))
        _ = await registry.transform { editor in
            editor.add(CoreToolsSyncFixture.tool("read", options: ToolSchema.Options(codemode: true)))
            editor.add(CoreToolsSyncFixture.tool("shell", options: ToolSchema.Options(codemode: true)))
            editor.add(CoreToolsSyncFixture.tool("glob", options: ToolSchema.Options(codemode: false)))
        }
        let placed = await registry.snapshot(
            permissions: nil,
            options: CoreTool.SnapshotOptions(tools: CoreTool.Policy(direct: ["shell"]))
        )
        #expect(placed.definitions.map(\.name) == ["glob", "shell", "execute"])

        let shell = try await placed.execute(CoreTool.ExecuteCallInput(
            sessionID: SessionID(rawValue: "ses_sync_001")!,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_001",
            callID: ToolSchema.CallID(rawValue: "call_002"),
            name: "shell",
            input: .object([:])
        ))
        #expect(shell.output == .string("direct"))

        // Denying execute makes Code Mode unreachable, so its tools come back as direct tools.
        let denied = await registry.snapshot(
            permissions: [PermissionSchema.Rule(action: "execute", resource: "*", effect: .deny)],
            options: nil
        )
        #expect(denied.definitions.map(\.name) == ["glob", "read", "shell"])
    }

    @Test("a Code Mode-only override is dropped from a tool that refuses Code Mode")
    func overridesNeedCodeMode() async {
        let registry = CoreTool.Service()
        _ = await registry.transform { editor in
            editor.add(CoreToolsSyncFixture.tool(
                "write",
                options: ToolSchema.Options(codemode: false),
                codemode: CoreTool.CodeModeOverrides(description: "inside")
            ))
        }
        let listed = await registry.list()
        #expect(listed.first?.codemode == nil)
    }
}

// MARK: - Plugin auto-update

@Suite("Plugin update intervals and @latest auto-update (plugin/update.ts, plugin/supervisor.ts)")
struct PluginAutoUpdateTests {
    @Test("a check result stays fresh for its whole interval and is re-read in the next")
    func intervalFreshness() async {
        let checks = CallLog()
        let service = CorePlugin.Update.Service(
            checker: { target in checks.append(target); return true },
            intervalMs: nil
        )
        let stream = await service.intervals()
        #expect(await service.check("pkg@latest", refresh: false))
        #expect(await service.check("pkg@latest", refresh: false))
        #expect(checks.all == ["pkg@latest"])
        _ = await service.check("pkg@latest", refresh: true)
        #expect(checks.all.count == 2)

        await service.advance()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        _ = await service.check("pkg@latest", refresh: false)
        #expect(checks.all.count == 3)
        #expect(CorePlugin.Update.interval == 24 * 60 * 60 * 1_000)
    }

    @Test("only name@latest plugins update on their own, once per interval")
    func autoUpdateLatest() async {
        let updated = CallLog()
        let updates = CorePlugin.Update.Service(updater: { updated.append($0) }, intervalMs: nil)
        let policy = CorePlugin.Supervisor.Updates()
        let checked: [(target: String, available: Bool)] = [
            ("alpha@latest", true),
            ("beta", true),
            ("gamma@latest", false),
        ]
        await policy.autoUpdate(checked: checked, updates: updates)
        #expect(updated.all == ["alpha@latest"])
        await policy.autoUpdate(checked: checked, updates: updates)
        #expect(updated.all == ["alpha@latest"])
        await policy.enter(cycle: 1)
        await policy.autoUpdate(checked: checked, updates: updates)
        #expect(updated.all == ["alpha@latest", "alpha@latest"])
    }

    @Test("a newer version that fails to load is rejected so a restart keeps the working one")
    func rejectFailedVersion() async {
        let generation = CorePlugin.Generation(
            plugin: PluginEffect.Plugin(id: "demo") { _ in },
            revision: "1",
            source: .package(target: "demo@latest", version: "1.0.0")
        )
        let resolution = CorePlugin.Supervisor.Resolution(
            plugins: [generation],
            failures: [CorePlugin.Failure(source: .package(target: "demo@latest"), error: "boom")],
            pending: []
        )
        let rejected = CallLog()
        let targets = await CorePlugin.Supervisor.rejectFailedVersions(
            resolution,
            installed: { _ in "2.0.0" },
            reject: { target, version in rejected.append("\(target)=\(version)"); return true }
        )
        #expect(targets == ["demo@latest"])
        #expect(rejected.all == ["demo@latest=2.0.0"])
    }
}

// MARK: - Claude accounts & usage limits

@Suite("Claude Code accounts, limits and config folders (claude-agent/*)")
struct ClaudeAccountsTests {
    typealias Claude = CorePlugin.ClaudeAgent

    @Test("a subscription limit is reported with its window and reset, and marked limited")
    func limitFailure() {
        let failure = Claude.ErrorMapper.make()
        #expect(failure(.rateLimitEvent(.init(status: "rejected", rateLimitType: "five_hour", resetsAt: 0))) == nil)
        let result = failure(.result(.init(subtype: "success", isError: true, apiErrorStatus: 429, result: "")))
        #expect(result?.limited == true)
        #expect(result?.message == "Claude Code subscription limit reached (five hour). Resets at 1970-01-01T00:00:00.000Z.")

        let plain = Claude.ErrorMapper.make()
        let other = plain(.result(.init(subtype: "error_during_execution", errors: ["Please run /login"])))
        #expect(other == Claude.ErrorMapper.Failure("Run `claude auth login` in a terminal", limited: false))
        #expect(plain(.result(.init(subtype: "success"))) == nil)
    }

    final class MemoryStorage: Sendable {
        let values = Mutex<[String: String]>([:])
        var storage: Claude.Accounts.Storage {
            Claude.Accounts.Storage(
                get: { key in self.values.withLock { $0[key].map(JSONValue.string) } },
                set: { key, value in self.values.withLock { $0[key] = value } }
            )
        }
    }

    @Test("a limited account rotates to the next folder and the chat remembers where it ran")
    func rotation() async throws {
        let store = MemoryStorage()
        let attempts = CallLog()
        let delivered = CallLog()
        let accounts = Claude.Accounts.make(
            sessions: { request in
                let dir = request.connection?["CLAUDE_CONFIG_DIR"] ?? ""
                attempts.append(dir)
                if dir == "/work" {
                    request.emit(.assistant(parentToolUseID: nil, error: "rate_limit"))
                    request.emit(.result(.init(subtype: "success", isError: true, result: "")))
                } else {
                    request.emit(.streamEvent)
                    request.emit(.result(.init(subtype: "success")))
                }
            },
            storage: store.storage
        )
        let request = Claude.Sessions.RunRequest(sessionID: "ses_1", model: "opus") { message in
            delivered.append(String(describing: message))
        }
        try await accounts.run(request, configDirs: ["/work", "/home"])
        #expect(attempts.all == ["/work", "/home"])
        #expect(store.values.withLock { $0 } == ["accounts/ses_1": "/home", "last-account": "/home"])
        // The refused attempt's messages were held back; only the successful one reached the model.
        #expect(delivered.all.count == 2)

        // The next turn starts on the chat's own account.
        try await accounts.run(request, configDirs: ["/work", "/home"])
        #expect(attempts.all == ["/work", "/home", "/home"])
    }

    @Test("an API key never rotates, and output already shown is never retried")
    func noRotation() async throws {
        let store = MemoryStorage()
        let attempts = CallLog()
        let accounts = Claude.Accounts.make(
            sessions: { request in
                attempts.append(request.connection?["CLAUDE_CONFIG_DIR"] ?? "none")
                request.emit(.streamEvent)
                request.emit(.assistant(parentToolUseID: nil, error: "rate_limit"))
                request.emit(.result(.init(subtype: "success", isError: true)))
            },
            storage: store.storage
        )
        try await accounts.run(
            Claude.Sessions.RunRequest(sessionID: "ses_2", model: "opus", connection: ["ANTHROPIC_API_KEY": "k"]) { _ in },
            configDirs: ["/a", "/b"]
        )
        #expect(attempts.all == ["none"])
        try await accounts.run(Claude.Sessions.RunRequest(sessionID: "ses_2", model: "opus") { _ in }, configDirs: ["/a", "/b"])
        #expect(attempts.all == ["none", "/a"])
        #expect(Claude.Accounts.key("ses_2") == "accounts/ses_2")
    }

    @Test("config folders resolve to absolute paths and the default folder goes unnamed")
    func configFolders() {
        #expect(Claude.QueryOptions.configDirs(.string("~/.claude-work"), home: "/Users/me", cwd: "/repo") == ["/Users/me/.claude-work"])
        #expect(Claude.QueryOptions.configDirs(.array([.string("rel"), .int(1), .string("/abs")]), home: nil, cwd: "/repo") == ["/repo/rel", "/abs"])
        #expect(Claude.QueryOptions.configDirs(nil, home: "/h", cwd: "/") == [])

        let io = Claude.IO.Interface(env: { [:] })
        #expect(Claude.QueryOptions.withoutDefaultFolder(["CLAUDE_CONFIG_DIR": "/Users/me/.claude", "X": "1"], io: io, home: "/Users/me") == ["X": "1"])
        #expect(Claude.QueryOptions.withoutDefaultFolder(["CLAUDE_CONFIG_DIR": "/other"], io: io, home: "/Users/me") == ["CLAUDE_CONFIG_DIR": "/other"])
        let pinned = Claude.IO.Interface(env: { ["CLAUDE_CONFIG_DIR": "/pinned"] })
        #expect(Claude.QueryOptions.withoutDefaultFolder(["CLAUDE_CONFIG_DIR": "/Users/me/.claude"], io: pinned, home: "/Users/me") == ["CLAUDE_CONFIG_DIR": "/Users/me/.claude"])

        #expect(Claude.Probe.loginMessage(nil) == "Claude Code is not logged in. Run `claude auth login` in a terminal.")
        #expect(Claude.Probe.loginMessage("/w").contains("CLAUDE_CONFIG_DIR"))
        #expect(Claude.Sync.recordKey("ses_1") == "sessions/ses_1")
        #expect(Claude.Sync.recordKey("ses_1", configDir: "/w") == "sessions/ses_1:/w")
    }

    @Test("a model listed under a new ID keeps the offered ID, and dropped IDs stay hidden")
    func catalogMerge() {
        let saved = [
            Claude.CatalogModel(id: "opus", name: "Opus", efforts: [], contextWindow: 200_000, resolvedModel: "claude-opus-5"),
            Claude.CatalogModel(id: "legacy", name: "Legacy", efforts: []),
        ]
        let merged = Claude.fromClaude(
            [
                Claude.ListedModel(value: "default", displayName: "Default"),
                Claude.ListedModel(value: "fable", displayName: "Fable", resolvedModel: "claude-opus-5"),
            ],
            saved: saved
        )
        #expect(merged.map(\.id) == ["opus", "fable", "legacy"])
        #expect(merged[0].hidden == nil && merged[0].name == "Fable" && merged[0].contextWindow == 200_000)
        #expect(merged[1].hidden == true)
        #expect(merged[2].hidden == true)
        #expect(Claude.uncheckedModels(merged, checked: []).isEmpty)
    }
}

// MARK: - Tool input repair, video helpers, websearch availability

@Suite("Tool input repair, video generation and websearch availability")
struct CoreToolsSyncMiscTests {
    @Test("schema-driven repair fixes stringified and loosely typed input")
    func repair() {
        let schema: [String: JSONValue] = [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "limit": .object(["type": .string("integer")]),
                "enabled": .object(["type": .string("boolean")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "note": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("limit")]),
        ]
        let repaired = CorePlugin.ToolInputRepairPlugin.repair(
            .string("{\"limit\":\"20\",\"enabled\":\"false\",\"tags\":\"x\",\"note\":null,\"extra\":1}"),
            schema: schema,
            root: schema,
            depth: 0
        )
        #expect(repaired == .object([
            "limit": .int(20),
            "enabled": .bool(false),
            "tags": .array([.string("x")]),
        ]))
    }

    @Test("video paths, notices and inline media")
    func videoHelpers() throws {
        #expect(CoreTool.VideoGenerateTool.videoPath("/w/cat.mp4", index: 0) == "/w/cat.mp4")
        #expect(CoreTool.VideoGenerateTool.videoPath("/w/cat.mp4", index: 2) == "/w/cat-2.mp4")
        #expect(CoreTool.VideoGenerateTool.videoPath("/w/.hidden", index: 1) == "/w/.hidden-1")
        #expect(CoreTool.VideoGenerateTool.notice(id: "video_1", state: "completed", body: "done")
            == "<background-result kind=\"video\" id=\"video_1\" state=\"completed\">\ndone\n</background-result>")

        let input = try CoreIntegration.Generate.videoInput(GenerateSchema.VideoRequest(
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "veo"), providerID: ProviderSchema.ID(rawValue: "google")),
            prompt: "a cat",
            start: GenerateSchema.ImageFile(data: "AAAA", mime: "image/png"),
            references: [GenerateSchema.File(data: "BBBB", mime: "audio/mpeg")],
            duration: SchemaPrimitive.PositiveInt(rawValue: 8),
            aspect: .auto,
            resolution: .p720
        ))
        #expect(input.start?.asset.mediaType == "image/png")
        #expect(input.references?.first?.kind == .audio)
        #expect(input.duration == 8 && input.resolution == "720p" && input.aspect == .auto)
    }

    @Test("unsupported video generation fails every call as not found")
    func unsupportedVideo() async {
        let service = CoreIntegration.VideoGeneration.Service(
            start: { _, _ in throw CoreIntegration.Generate.UnavailableError(message: "no") },
            get: { id in throw CoreIntegration.VideoGeneration.NotFoundError(id: id.rawValue) }
        )
        let id = GenerateSchema.VideoID.create()
        await #expect(throws: CoreIntegration.VideoGeneration.NotFoundError.self) { try await service.wait(id) }
        await #expect(throws: CoreIntegration.VideoGeneration.NotFoundError.self) { try await service.cancel(id) }
        #expect(CoreIntegration.VideoGeneration.NotFoundError(id: "v").message == "Video not found: v")
    }

    @Test("websearch is available only with a provider and a selection that isn't disabled")
    func websearchAvailable() async throws {
        let service = CoreIntegration.WebSearch.Service(kv: try CoreKV.Service.inMemory())
        #expect(await service.available() == false)
        try await service.transform { editor in
            editor.add(CoreIntegration.WebSearch.ProviderImplementation(id: CoreIntegration.WebSearch.ID(rawValue: "exa"), name: "Exa") { _ in [] })
        }
        #expect(await service.available() == true)
        try await service.select(.disabled)
        #expect(await service.available() == false)
    }

    @Test("the session-move hint follows how the model reaches session.move")
    func sessionMoveHint() {
        #expect(CoreTool.OpenCodeTools.sessionMoveHint(tools: ["execute"])?.contains("tools.opencode.session.move") == true)
        #expect(CoreTool.OpenCodeTools.sessionMoveHint(tools: ["opencode_session_move"])?.contains("`opencode_session_move`") == true)
        #expect(CoreTool.OpenCodeTools.sessionMoveHint(tools: []) == nil)
    }

    @Test("watch wakes honour the window, the prompt limit and unattended watches")
    func watchWakes() {
        typealias W = CorePlugin.OpencodeWatches
        let busy = W.Streak(count: 19, at: [], last: 0)
        let last = W.decideWake(stored: busy, now: 1_000, own: false, unattended: false, allCI: false)
        #expect(last.resume && last.paused && last.next.count == 20)
        let blocked = W.decideWake(stored: W.Streak(count: 20, at: [], last: 0), now: 1_000, own: false, unattended: false, allCI: false)
        #expect(!blocked.resume && blocked.next.count == 20 && blocked.next.last == 1_000)
        let unattended = W.decideWake(stored: W.Streak(count: 20, at: [], last: 0), now: 1_000, own: false, unattended: true, allCI: false)
        #expect(unattended.resume)
        // Thirty quiet minutes reset the streak, like the member's own words.
        let quiet = W.decideWake(stored: W.Streak(count: 20, at: [], last: 0), now: 30 * 60 * 1_000, own: false, unattended: false, allCI: false)
        #expect(quiet.resume && quiet.next.count == 1)
        #expect(W.unattendedKey("w1") == "watch-unattended:w1")
    }

    @Test("the goal reminder and plan notes use system-update, and videos count as own background work")
    func goalReminder() {
        #expect(CorePlugin.GoalPlugin.reminder(objective: "ship").hasPrefix("<system-update>"))
        #expect(CorePlugin.PlanPlugin.leaveReminder.hasPrefix("<system-update>"))
        #expect(CorePlugin.GoalPlugin.waitsOnOwnWork([(kind: "video", sessionID: "s1")], sessionID: "s1"))
        #expect(!CorePlugin.GoalPlugin.waitsOnOwnWork([(kind: "shell", sessionID: "s1")], sessionID: "s1"))
    }
}

// MARK: - models.dev recommended API & ChatGPT revoke

@Suite("models.dev recommended API and ChatGPT token revocation")
struct CoreProvidersSyncTests {
    static func catalog(provider: String) -> String {
        """
        {"\(provider)":{"id":"\(provider)","name":"Acme","env":[],"models":{"m1":{"id":"m1","name":"M1","type":"chat","recommended_api":"responses","api":{"chat-completions":{"sdk":{"opencodeai":"pkg-chat"}},"responses":{"sdk":{"opencodeai":"pkg-responses"}}}}}}}
        """
    }

    @Test("recommended_api routes a model through its recommended API, except on Vertex")
    func recommendedRoute() throws {
        let first = try CoreModel.ModelsDev.decodeSnapshot(Self.catalog(provider: "acme"))
        #expect(first.first?.info.package == "pkg-chat")
        let recommended = try CoreModel.ModelsDev.decodeSnapshot(Self.catalog(provider: "acme"), recommended: true)
        #expect(recommended.first?.info.package == "pkg-responses")
        let vertex = try CoreModel.ModelsDev.decodeSnapshot(Self.catalog(provider: "google-vertex"), recommended: true)
        #expect(vertex.first?.info.package == "pkg-chat")
    }

    @Test("revoking a ChatGPT login posts the refresh token with the registered client ID")
    func revoke() async throws {
        let seen = Mutex<HTTPRequest?>(nil)
        let transport = LayerNodePlatform.FetchTransport { request in
            seen.withLock { $0 = request }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: [:]), body: [])
        }
        let credential = CredentialSchema.OAuth(
            methodID: IntegrationMethodID(rawValue: "chatgpt"),
            refresh: "r t",
            access: "a",
            expires: SchemaPrimitive.NonNegativeInt.zero,
            metadata: ["clientID": .string("client_1")]
        )
        try await CorePlugin.ChatGPTProvider.revoke(
            credential,
            app: PluginContract.App(name: "opencode", version: "1.0.0", channel: "local"),
            transport: transport
        )
        let request = try #require(seen.withLock { $0 })
        #expect(request.url == CorePlugin.ChatGPTProvider.revokeURL)
        #expect(request.body.map { String(decoding: $0, as: UTF8.self) } == "token=r+t&token_type_hint=refresh_token&client_id=client_1")

        let missing = CredentialSchema.OAuth(
            methodID: IntegrationMethodID(rawValue: "chatgpt"),
            refresh: "r",
            access: "a",
            expires: SchemaPrimitive.NonNegativeInt.zero,
            metadata: nil
        )
        await #expect(throws: CorePlugin.ChatGPTProvider.RevokeError.self) {
            try await CorePlugin.ChatGPTProvider.revoke(missing, app: PluginContract.App(name: "o", version: "1", channel: "local"), transport: transport)
        }
    }
}

// MARK: - Home folder memory

@Suite("Home folder memory (plugin/home-memory.ts)")
struct HomeMemoryPluginTests {
    @Test("the workspace description and maintenance prompt name the memory folders")
    func prompts() {
        let description = CorePlugin.HomeMemoryPlugin.description("/data/memory/prj")
        #expect(description.contains("- /data/memory/prj/memory: what you know about the user"))
        #expect(description.contains("- /data/memory/prj/scripts: reusable scripts"))
        let maintenance = CorePlugin.HomeMemoryPlugin.maintenance("/data/memory/prj", transcripts: "<conversation title=\"a\">\nuser: hi\n</conversation>")
        #expect(maintenance.hasPrefix("Daily memory maintenance. Nobody is watching; don't ask questions."))
        #expect(maintenance.hasSuffix("<conversations>\n<conversation title=\"a\">\nuser: hi\n</conversation>\n</conversations>"))
    }

    @Test("a transcript keeps user and assistant text and needs a user turn")
    func transcripts() {
        #expect(CorePlugin.HomeMemoryPlugin.transcript(title: "t", messages: []) == "")
    }

    @Test("a flag this schema doesn't know yet reads as off")
    func unknownFlag() async {
        #expect(await CorePlugin.Host.flagEnabled("no_such_flag") == false)
    }
}
