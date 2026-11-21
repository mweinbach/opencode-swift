import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Real Wired Built-In Tools, Native POSIX PTY & Live Snapshot Bridge")
struct RealToolsAndPtyTests {
    private func call(
        _ snapshot: CoreTool.Snapshot,
        name: String,
        input: JSONValue,
        sessionID: SessionID = SessionID(rawValue: "ses_real_tools_001")!
    ) async throws -> CoreTool.NormalizedResult {
        try await snapshot.execute(CoreTool.ExecuteCallInput(
            sessionID: sessionID,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_1",
            callID: ToolSchema.CallID(rawValue: "call_1"),
            name: name,
            input: input
        ))
    }

    // MARK: - 1. Default HTTP Transport & Unconfigured Tool Guardrails

    @Test("BuiltinEnvironment defaults httpTransport to URLSessionHTTPTransport.shared and unconfigured tools fail cleanly")
    func defaultTransportAndUnconfiguredErrors() async throws {
        let defaultEnv = CoreTool.BuiltinEnvironment()
        #expect(RealToolsAndPtyHelper.isURLSessionTransport(defaultEnv.httpTransport))

        let registry = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: registry, environment: defaultEnv)
        let snap = await registry.snapshot()

        // websearch fails cleanly when unconfigured (no fake NO_RESULTS)
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "websearch", input: .object(["query": .string("swift 6")]))
        }

        // question fails cleanly when unconfigured (NEVER silently auto-answers!)
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "question", input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Pick one"),
                        "header": .string("Choice"),
                        "options": .array([
                            .object(["label": .string("Alpha"), "description": .string("First")]),
                            .object(["label": .string("Beta"), "description": .string("Second")]),
                        ]),
                    ]),
                ]),
            ]))
        }

        // experimental_image_generate fails cleanly when unconfigured (NEVER fabricates /tmp/images/...)
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "experimental_image_generate", input: .object([
                "prompt": .string("A mountain sunrise"),
            ]))
        }

        // subagent, skill, automations, mcp, worktree, models all fail cleanly when unconfigured
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "subagent", input: .object([
                "agent": .string("explore"),
                "description": .string("Find files"),
                "prompt": .string("Locate Swift files"),
            ]))
        }
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "skill", input: .object(["id": .string("swift-port")]))
        }
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "automation_list", input: .object([:]))
        }
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "opencode_list_mcp_resources", input: .object([:]))
        }
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "opencode_worktree_list", input: .object([:]))
        }
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "opencode_models", input: .object([:]))
        }
    }

    // MARK: - 2. websearch wired to CoreIntegration.WebSearch

    @Test("websearch tool queries real CoreIntegration.WebSearch provider and returns live results")
    func websearchWiredToRealService() async throws {
        let kv = try CoreKV.Service.inMemory()
        let webSearch = CoreIntegration.WebSearch.Service(kv: kv)
        _ = try await webSearch.transform { editor in
            editor.add(CoreIntegration.WebSearch.ProviderImplementation(
                id: WebSearchSchema.ID(rawValue: "tavily"),
                name: "Tavily",
                execute: { input in
                    [
                        WebSearchSchema.Result(
                            url: "https://swift.org/blog/swift-6-2",
                            title: "Swift 6.2 Released for \(input.query)",
                            content: "Swift 6.2 brings approachable concurrency.",
                            time: WebSearchSchema.Result.Time(published: 1_760_000_000_000)
                        ),
                    ]
                }
            ))
            editor.defaultSelection = .provider(WebSearchSchema.ID(rawValue: "tavily"))
        }

        let env = CoreTool.BuiltinEnvironment(directory: "/workspace", fileSystem: InMemoryFileSystem(), webSearch: webSearch)
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        let result = try await call(snap, name: "websearch", input: .object([
            "query": .string("Swift 6.2 concurrency"),
        ]))
        let text = ToolsConfigRuntimeHelper.firstText(from: result)
        #expect(text.contains("Swift 6.2 Released for Swift 6.2 concurrency"))
        #expect(text.contains("https://swift.org/blog/swift-6-2"))
        #expect(text.contains("Swift 6.2 brings approachable concurrency."))
        #expect(result.metadata?["provider"] == .string("tavily"))
        if case .array(let items) = result.output, items.count == 1, case .object(let first) = items[0] {
            #expect(first["url"] == .string("https://swift.org/blog/swift-6-2"))
            #expect(first["title"] == .string("Swift 6.2 Released for Swift 6.2 concurrency"))
        } else {
            Issue.record("Expected array of 1 search result object in websearch output")
        }
    }

    // MARK: - 3. question wired to interactive CoreIntegration.Form

    @Test("question tool creates a real CoreIntegration.Form request and returns the interactive user reply")
    func questionWiredToRealFormService() async throws {
        let formService = CoreIntegration.Form.Service()
        let env = CoreTool.BuiltinEnvironment(directory: "/workspace", fileSystem: InMemoryFileSystem(), form: formService)
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()
        let sid = SessionID(rawValue: "ses_question_live_1")!

        // Start question tool in background task — it MUST suspend awaiting a real user reply!
        let questionTask = Task {
            try await call(snap, name: "question", input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Which transport should we use?"),
                        "header": .string("Transport"),
                        "options": .array([
                            .object(["label": .string("HTTP"), "description": .string("Standard HTTP")]),
                            .object(["label": .string("WebSocket"), "description": .string("Bidirectional WS")]),
                        ]),
                    ]),
                    .object([
                        "question": .string("Which platforms should we target?"),
                        "header": .string("Platforms"),
                        "multiple": .bool(true),
                        "options": .array([
                            .object(["label": .string("macOS"), "description": .string("Apple macOS")]),
                            .object(["label": .string("Linux"), "description": .string("Linux glibc")]),
                        ]),
                    ]),
                ]),
            ]), sessionID: sid)
        }

        // Poll Form.Service until the pending form appears
        var pending: [FormSchema.Info] = []
        for _ in 0..<100 {
            pending = await formService.list(CoreIntegration.Form.ListInput(sessionID: sid.rawValue))
            if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pending.count == 1)
        let activeForm = try #require(pending.first)
        #expect(activeForm.fields.elements.count == 2)

        // Reply explicitly with the SECOND option ("WebSocket") and BOTH platforms (proving zero auto-answer!)
        try await formService.reply(CoreIntegration.Form.ReplyInput(
            id: activeForm.id,
            answer: [
                "q0": .string("WebSocket"),
                "q1": .strings(["macOS", "Linux"]),
            ]
        ))

        let res = try await questionTask.value
        let text = ToolsConfigRuntimeHelper.firstText(from: res)
        #expect(text.contains("\"Which transport should we use?\"=\"WebSocket\""))
        #expect(text.contains("\"Which platforms should we target?\"=\"macOS, Linux\""))
        if case .object(let obj) = res.output, case .array(let ans) = obj["answers"] {
            #expect(ans.count == 2)
            #expect(ans[0] == .array([.string("WebSocket")]))
            #expect(ans[1] == .array([.string("macOS"), .string("Linux")]))
        } else {
            Issue.record("Expected structured answers in question output")
        }
    }

    // MARK: - 4. subagent, session_rename, and session_move wired to real SQLite Session services

    @Test("subagent creates a real child session + inbox prompt in SQLite, and session_rename & session_move mutate SQLite state")
    func subagentSessionRenameAndSessionMoveWiredToSQLite() async throws {
        let tmpRoot = try RealToolsAndPtyHelper.makeTempDirectory(prefix: "opencode-session-tools")
        defer { RealToolsAndPtyHelper.removeTempDirectory(tmpRoot) }

        let dirA = "\(tmpRoot)/project-a"
        let dirB = "\(tmpRoot)/project-b"
        try await LocalFileSystem.shared.makeDirectory(at: dirA, recursive: true)
        try await LocalFileSystem.shared.makeDirectory(at: dirB, recursive: true)
        let canonA = RealToolsAndPtyHelper.realPath(dirA)
        let canonB = RealToolsAndPtyHelper.realPath(dirB)

        let harness = try await SessionDatabaseHelper.makeHarness(inMemory: true)
        let sessionMove = CoreSessionMove.Service(
            db: harness.db,
            bus: harness.bus,
            store: harness.store,
            inbox: harness.inbox,
            execution: CoreSessionExecution.NoopService(),
            fileSystem: LocalFileSystem.shared
        )

        let parentSession = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: canonA),
            title: "Original Title",
            agent: "build"
        ))

        let agentService = CoreAgent.Agent.Service()
        _ = try await agentService.transform { editor in
            editor.update(AgentSchema.ID(rawValue: "explore")) { info in
                AgentSchema.Info(
                    id: info.id,
                    name: AgentSchema.Name(rawValue: "Explore"),
                    model: nil,
                    request: info.request,
                    system: nil,
                    description: "Fast codebase explorer",
                    mode: .subagent,
                    hidden: false,
                    color: nil,
                    steps: nil,
                    permissions: []
                )
            }
        }

        let env = CoreTool.BuiltinEnvironment(
            directory: canonA,
            fileSystem: LocalFileSystem.shared,
            globalPaths: RealToolsAndPtyHelper.makeGlobalPaths(root: tmpRoot),
            session: harness.session,
            sessionMove: sessionMove,
            sessionStore: harness.store,
            agent: agentService
        )
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        // 1. subagent creates a REAL child session + admits a REAL prompt in SQLite!
        let subRes = try await call(snap, name: "subagent", input: .object([
            "agent": .string("explore"),
            "description": .string("Inspect core tools"),
            "prompt": .string("Find all wired tool plugins"),
        ]), sessionID: parentSession.id)

        guard case .object(let subObj) = subRes.output,
              case .string(let childIDRaw) = subObj["sessionID"],
              let childID = SessionID(rawValue: childIDRaw)
        else {
            Issue.record("Expected child sessionID in subagent output")
            return
        }
        let childRecord = try harness.session.get(childID)
        #expect(childRecord.parentID == parentSession.id)
        #expect(childRecord.title == "Inspect core tools")
        #expect(childRecord.agent == "explore")

        let childInbox = try harness.inbox.list(childID)
        #expect(childInbox.count == 1)
        if case .user(let userRecord) = childInbox[0] {
            #expect(userRecord.payload.text.contains("Find all wired tool plugins"))
        } else {
            Issue.record("Expected user prompt item admitted to child session inbox")
        }

        // Follow-up to the same child session appends a second inbox prompt!
        _ = try await call(snap, name: "subagent", input: .object([
            "agent": .string("explore"),
            "description": .string("Follow up"),
            "prompt": .string("Also check PTY tests"),
            "sessionID": .string(childID.rawValue),
        ]), sessionID: parentSession.id)
        let updatedInbox = try harness.inbox.list(childID)
        #expect(updatedInbox.count == 2)

        // 2. session_rename updates the real SQLite session_v2 row!
        let renameRes = try await call(snap, name: "opencode_session_rename", input: .object([
            "title": .string("Refactored Real Tools"),
        ]), sessionID: parentSession.id)
        #expect(ToolsConfigRuntimeHelper.firstText(from: renameRes).contains("Refactored Real Tools"))
        let renamedSession = try harness.session.get(parentSession.id)
        #expect(renamedSession.title == "Refactored Real Tools")

        // 3. session_move relocates the real SQLite session_v2 row to canonB!
        let moveRes = try await call(snap, name: "opencode_session_move", input: .object([
            "directory": .string(canonB),
        ]), sessionID: parentSession.id)
        #expect(ToolsConfigRuntimeHelper.firstText(from: moveRes).contains(canonB))
        let movedSession = try harness.session.get(parentSession.id)
        #expect(movedSession.location.directory == canonB)
    }

    // MARK: - 5. skill wired to CoreSkill

    @Test("skill tool loads real skill content and virtual files from CoreSkill.Service")
    func skillWiredToRealService() async throws {
        let skillService = CoreSkill.Service()
        _ = try await skillService.transform { editor in
            editor.add(
                SkillSchema.Info(
                    id: SkillSchema.ID(rawValue: "swift-concurrency"),
                    name: SkillSchema.Name(rawValue: "Swift Concurrency"),
                    description: "Strict Swift 6 concurrency patterns",
                    autoinvoke: true,
                    path: SchemaPrimitive.AbsolutePath(rawValue: "skill://swift-concurrency/SKILL.md"),
                    content: "# Swift 6 Rules\nPrefer actors and Synchronization.Mutex."
                ),
                files: [
                    "reference/mutex.md": "# Mutex guide",
                    "scripts/check.sh": "swift build -Xswiftc -warnings-as-errors",
                ]
            )
        }

        let env = CoreTool.BuiltinEnvironment(directory: "/workspace", fileSystem: InMemoryFileSystem(), skill: skillService)
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        let res = try await call(snap, name: "skill", input: .object([
            "id": .string("swift-concurrency"),
        ]))
        let text = ToolsConfigRuntimeHelper.firstText(from: res)
        #expect(text.contains("<skill_content name=\"Swift Concurrency\">"))
        #expect(text.contains("Prefer actors and Synchronization.Mutex."))
        #expect(text.contains("skill://swift-concurrency/reference/mutex.md"))
        #expect(res.metadata?["name"] == .string("Swift Concurrency"))

        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(snap, name: "skill", input: .object(["id": .string("missing-skill")]))
        }
    }

    // MARK: - 6. automation_* CRUD wired to CoreAutomation

    @Test("automation_create, automation_list, automation_pause, automation_resume, and automation_delete perform real SQLite CRUD")
    func automationToolsWiredToRealService() async throws {
        let projectID = ProjectID(rawValue: "proj_auto_real")
        let sid = SessionID(rawValue: "ses_auto_real_1")!
        let autoService = try CoreAutomation.Service.inMemory()
        let env = CoreTool.BuiltinEnvironment(
            directory: "/workspace",
            fileSystem: InMemoryFileSystem(),
            projectID: projectID,
            automation: autoService
        )
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        // Create
        let created = try await call(snap, name: "automation_create", input: .object([
            "name": .string("Nightly Audit"),
            "trigger": .object(["type": .string("every"), "every": .string("5 minutes")]),
            "action": .object([
                "type": .string("prompt"),
                "prompt": .string("Run parity check"),
            ]),
        ]), sessionID: sid)
        guard case .object(let createObj) = created.output,
              case .string(let autoIDRaw) = createObj["id"],
              let autoID = AutomationSchema.ID(rawValue: autoIDRaw)
        else {
            Issue.record("Expected automation id in automation_create output")
            return
        }
        #expect(createObj["status"] == .string("active"))
        #expect(ToolsConfigRuntimeHelper.firstText(from: created).contains("Created:"))

        // List
        let listed = try await call(snap, name: "automation_list", input: .object([:]), sessionID: sid)
        if case .object(let listObj) = listed.output, case .array(let items) = listObj["automations"] {
            #expect(items.count == 1)
        } else {
            Issue.record("Expected 1 automation in automation_list")
        }

        // Pause
        let paused = try await call(snap, name: "automation_pause", input: .object([
            "id": .string(autoID.rawValue),
        ]), sessionID: sid)
        if case .object(let pauseObj) = paused.output {
            #expect(pauseObj["status"] == .string("paused"))
        }
        #expect(try await autoService.get(autoID).status == .paused)

        // Resume
        let resumed = try await call(snap, name: "automation_resume", input: .object([
            "id": .string(autoID.rawValue),
        ]), sessionID: sid)
        if case .object(let resumeObj) = resumed.output {
            #expect(resumeObj["status"] == .string("active"))
        }
        #expect(try await autoService.get(autoID).status == .active)

        // Delete
        let deleted = try await call(snap, name: "automation_delete", input: .object([
            "id": .string(autoID.rawValue),
        ]), sessionID: sid)
        #expect(deleted.output == .object(["id": .string(autoID.rawValue), "removed": .bool(true)]))
        #expect(try await autoService.list(CoreAutomation.ListInput(projectID: projectID)).isEmpty)
    }

    // MARK: - 7. MCP resources & events wired to CoreMCP.Registry

    @Test("list_mcp_resources, read_mcp_resource, and list_mcp_events query real CoreMCP.Registry")
    func mcpResourcesAndEventsWiredToRealRegistry() async throws {
        let pngB64 = RealToolsAndPtyHelper.samplePNGBase64()
        let mcpHTTP = RealToolsAndPtyHelper.makeStreamableMCPServerTransport(
            resources: [
                CoreMCP.Client.Resource(
                    name: "Architecture Guide",
                    uri: "docs://arch",
                    description: "Core design doc",
                    mimeType: "text/markdown"
                ),
                CoreMCP.Client.Resource(
                    name: "Diagram",
                    uri: "docs://diagram.png",
                    description: "System diagram",
                    mimeType: "image/png"
                ),
            ],
            templates: [
                CoreMCP.Client.ResourceTemplate(
                    name: "Issue by ID",
                    uriTemplate: "docs://issues/{id}",
                    description: "Load issue record",
                    mimeType: "application/json"
                ),
            ],
            readHandler: { uri in
                if uri == "docs://diagram.png" {
                    return [.object([
                        "uri": .string(uri),
                        "mimeType": .string("image/png"),
                        "blob": .string(pngB64),
                    ])]
                }
                return [.object([
                    "uri": .string(uri),
                    "mimeType": .string("text/markdown"),
                    "text": .string("# OpenCode Architecture\nReal MCP resource payload."),
                ])]
            }
        )

        let baseMCP = CoreMCP.Registry.Service(directory: "/workspace", http: mcpHTTP)
        let remoteCfg = McpSchema.ServerConfig.remote(McpSchema.RemoteConfig(url: "https://mcp.local.test/rpc"))
        _ = try await baseMCP.transform { $0.set("docs", config: remoteCfg) }
        await baseMCP.add(server: "docs", config: remoteCfg)
        try await baseMCP.connect(server: "docs")

        let eventfulMCP = RealToolsAndPtyHelper.EventfulMCPRegistry(
            base: baseMCP,
            eventProviders: [
                "docs": RealToolsAndPtyHelper.StubMCPEvents(eventTypes: [
                    CoreMCP.Client.EventType(name: "doc.updated", description: "Doc changed", delivery: ["push"]),
                    CoreMCP.Client.EventType(name: "doc.polled", description: "Poll only", delivery: ["pull"]),
                ]),
            ]
        )

        let env = CoreTool.BuiltinEnvironment(directory: "/workspace", fileSystem: InMemoryFileSystem(), mcp: eventfulMCP)
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        // list_mcp_resources (all servers)
        let listAll = try await call(snap, name: "opencode_list_mcp_resources", input: .object([:]))
        if case .object(let obj) = listAll.output,
           case .array(let resArr) = obj["resources"],
           case .array(let tmplArr) = obj["templates"]
        {
            #expect(resArr.count == 2)
            #expect(tmplArr.count == 1)
        } else {
            Issue.record("Expected resources & templates arrays from list_mcp_resources")
        }

        // read_mcp_resource (text)
        let readText = try await call(snap, name: "opencode_read_mcp_resource", input: .object([
            "server": .string("docs"),
            "uri": .string("docs://arch"),
        ]))
        let readTextStr = ToolsConfigRuntimeHelper.firstText(from: readText)
        #expect(readTextStr.contains("Real MCP resource payload."))

        // read_mcp_resource (PNG blob produces inline file content part!)
        let readBlob = try await call(snap, name: "opencode_read_mcp_resource", input: .object([
            "server": .string("docs"),
            "uri": .string("docs://diagram.png"),
        ]))
        let hasImagePart = readBlob.content.contains { part in
            if case .file(let f) = part {
                return f.mime == "image/png" && f.uri.hasPrefix("data:image/png;base64,")
            }
            return false
        }
        #expect(hasImagePart)

        // list_mcp_events returns ONLY push events
        let evRes = try await call(snap, name: "opencode_list_mcp_events", input: .object([
            "server": .string("docs"),
        ]))
        if case .object(let evObj) = evRes.output, case .array(let events) = evObj["events"] {
            #expect(events.count == 1)
            if case .object(let first) = events[0] {
                #expect(first["server"] == .string("docs"))
                #expect(first["event"] == .string("doc.updated"))
            }
        } else {
            Issue.record("Expected filtered push events from list_mcp_events")
        }
    }

    // MARK: - 8. worktree_create, worktree_list, worktree_remove wired to CoreWorktree

    @Test("worktree_create, worktree_list, and worktree_remove execute real CoreWorktree CRUD")
    func worktreeToolsWiredToRealService() async throws {
        let tmpRoot = try RealToolsAndPtyHelper.makeTempDirectory(prefix: "opencode-worktree-tools")
        defer { RealToolsAndPtyHelper.removeTempDirectory(tmpRoot) }

        let repoRoot = "\(tmpRoot)/repo"
        let wtParent = "\(tmpRoot)/worktrees"
        try await LocalFileSystem.shared.makeDirectory(at: repoRoot, recursive: true)
        try await LocalFileSystem.shared.makeDirectory(at: wtParent, recursive: true)
        let canonRepo = RealToolsAndPtyHelper.realPath(repoRoot)
        let canonWtParent = RealToolsAndPtyHelper.realPath(wtParent)

        let projectID = ProjectID(rawValue: "proj_wt_real")
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let strategy = CoreWorktree.Strategies.Strategy(
            id: WorktreeSchema.StrategyID(rawValue: "local-fs")!,
            create: { _, destination, _ in
                try await LocalFileSystem.shared.makeDirectory(at: destination.rawValue, recursive: true)
                return WorktreeSchema.Info(directory: destination)
            },
            remove: { destination, _ in
                try await LocalFileSystem.shared.remove(at: destination.rawValue)
            },
            list: { _ in [] }
        )
        let stratService = CoreWorktree.Strategies.Service(
            locationDirectory: SchemaPrimitive.AbsolutePath(rawValue: canonRepo),
            defaultWorktreeRoot: SchemaPrimitive.AbsolutePath(rawValue: canonWtParent),
            gitStrategy: strategy
        )
        let worktreeService = try CoreWorktree.Service(
            database: db,
            fileSystem: LocalFileSystem.shared,
            defaultStrategies: stratService
        )
        try RealToolsAndPtyHelper.registerProject(db: db, projectID: projectID, worktreePath: canonRepo)

        let env = CoreTool.BuiltinEnvironment(
            directory: canonRepo,
            fileSystem: LocalFileSystem.shared,
            globalPaths: RealToolsAndPtyHelper.makeGlobalPaths(root: tmpRoot),
            projectID: projectID,
            worktree: worktreeService,
            worktreeStrategies: stratService
        )
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        // Create worktree
        let created = try await call(snap, name: "opencode_worktree_create", input: .object([
            "name": .string("feature-real"),
        ]))
        guard case .object(let createObj) = created.output,
              case .string(let createdDir) = createObj["directory"]
        else {
            Issue.record("Expected directory in worktree_create output")
            return
        }
        #expect(createdDir.hasSuffix("/feature-real"))
        #expect(await LocalFileSystem.shared.exists(at: createdDir))

        // List worktrees
        let listed = try await call(snap, name: "opencode_worktree_list", input: .object([:]))
        if case .object(let listObj) = listed.output, case .array(let wts) = listObj["worktrees"] {
            #expect(wts.count == 1)
            if case .object(let first) = wts[0] {
                #expect(first["directory"] == .string(createdDir))
            }
        } else {
            Issue.record("Expected 1 worktree from worktree_list")
        }

        // Remove worktree
        let removed = try await call(snap, name: "opencode_worktree_remove", input: .object([
            "directory": .string(createdDir),
            "force": .bool(true),
        ]))
        #expect(removed.output == .object(["directory": .string(createdDir), "removed": .bool(true)]))
        #expect(await LocalFileSystem.shared.exists(at: createdDir) == false)
        #expect(try await worktreeService.list(projectID: projectID).isEmpty)
    }

    // MARK: - 9. models & experimental_image_generate wired to CoreModel & CoreIntegration.Generate

    @Test("models tool filters, sorts, deduplicates families, and paginates real CoreModel catalog, and experimental_image_generate saves real generated bytes")
    func modelsAndImageGenerateWiredToRealServices() async throws {
        let providerSvc = CoreProvider.Provider.Service()
        let openaiID = ProviderSchema.ID(rawValue: "openai")
        let anthropicID = ProviderSchema.ID(rawValue: "anthropic")

        let gpt5Old = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5-2025"),
            modelID: ModelSchema.ID(rawValue: "gpt-5-2025"),
            providerID: openaiID,
            type: .chat,
            family: ModelSchema.Family(rawValue: "gpt-5"),
            name: "GPT-5 2025",
            capabilities: .default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_700_000_000_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 128_000, output: 16_384)
        )
        let gpt5New = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5.2"),
            modelID: ModelSchema.ID(rawValue: "gpt-5.2"),
            providerID: openaiID,
            type: .chat,
            family: ModelSchema.Family(rawValue: "gpt-5"),
            name: "GPT-5.2 Latest",
            capabilities: .default(),
            variants: [ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "high"))],
            time: ModelSchema.Info.Time(released: 1_760_000_000_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 256_000, output: 32_768)
        )
        let imageModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-image-1"),
            modelID: ModelSchema.ID(rawValue: "gpt-image-1"),
            providerID: openaiID,
            type: .image,
            family: ModelSchema.Family(rawValue: "gpt-image"),
            name: "GPT Image 1",
            capabilities: ModelSchema.Capabilities(tools: false, input: ["text", "image"], output: ["image"]),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_750_000_000_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 32_000, output: 4_096)
        )
        let claude = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "claude-sonnet-4"),
            modelID: ModelSchema.ID(rawValue: "claude-sonnet-4"),
            providerID: anthropicID,
            type: .chat,
            family: ModelSchema.Family(rawValue: "claude-sonnet"),
            name: "Claude Sonnet 4",
            capabilities: .default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_755_000_000_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 200_000, output: 16_384)
        )

        _ = try await providerSvc.transform { editor in
            editor.add(
                info: ProviderSchema.Info(
                    id: openaiID,
                    name: "OpenAI",
                    activation: .enabled,
                    package: "@opencode/ai/providers/openai"
                ),
                models: [gpt5Old, gpt5New, imageModel]
            )
            editor.add(
                info: ProviderSchema.Info(
                    id: anthropicID,
                    name: "Anthropic",
                    activation: .enabled,
                    package: "@opencode/ai/providers/anthropic"
                ),
                models: [claude]
            )
        }
        let modelSvc = CoreModel.Model.Service(providers: providerSvc)
        let generateSvc = RealToolsAndPtyHelper.RecordingGenerateService()
        let fs = InMemoryFileSystem()
        try await fs.makeDirectory(at: "/workspace", recursive: true)

        let env = CoreTool.BuiltinEnvironment(
            directory: "/workspace",
            fileSystem: fs,
            model: modelSvc,
            provider: providerSvc,
            generate: generateSvc
        )
        let reg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: reg, environment: env)
        let snap = await reg.snapshot()

        // Default chat listing deduplicates gpt-5 family to newest (2 total: claude-sonnet-4, gpt-5.2)
        let chatRes = try await call(snap, name: "opencode_models", input: .object([:]))
        if case .object(let obj) = chatRes.output {
            #expect(obj["total"] == .int(2))
            #expect(obj["next"] == .null)
        } else {
            Issue.record("Expected object output from models tool")
        }

        // With all: true and provider: "openai", both gpt-5 versions appear
        let allOpenAI = try await call(snap, name: "opencode_models", input: .object([
            "provider": .string("OpenAI"),
            "all": .bool(true),
        ]))
        if case .object(let obj) = allOpenAI.output {
            #expect(obj["total"] == .int(2))
        }

        // Image type filter finds gpt-image-1
        let imgModels = try await call(snap, name: "opencode_models", input: .object([
            "type": .string("image"),
        ]))
        if case .object(let obj) = imgModels.output {
            #expect(obj["total"] == .int(1))
        }

        // experimental_image_generate calls real Generate.image(...) and writes real PNG bytes!
        let imgRes = try await call(snap, name: "experimental_image_generate", input: .object([
            "prompt": .string("Minimalist Swift logo"),
            "path": .string("out/logo.jpg"),
        ]))
        #expect(generateSvc.recordedImageRequests().count == 1)
        #expect(generateSvc.recordedImageRequests()[0].model.id.rawValue == "gpt-image-1")
        if case .object(let imgObj) = imgRes.output, case .string(let savedPath) = imgObj["path"] {
            // Extension replaced with real detected PNG format (.png instead of .jpg)
            #expect(savedPath == "/workspace/out/logo.png")
            let writtenBytes = try await fs.readFile(at: savedPath)
            #expect(writtenBytes == RealToolsAndPtyHelper.samplePNGBytes())
        } else {
            Issue.record("Expected saved path in image generate output")
        }
    }

    // MARK: - 10. Default Native POSIX PTY Execution on macOS/Linux

    @Test("CorePty.Service() and CorePty.Persistent.Service() default to native POSIX PTY on macOS/Linux and execute real commands")
    func nativePosixPtyDefaultExecution() async throws {
        #if os(macOS) || os(Linux)
        #expect(RealToolsAndPtyHelper.isNativeBackend(CorePty.defaultBackend))

        let tmpDir = try RealToolsAndPtyHelper.makeTempDirectory(prefix: "opencode-native-pty")
        defer { RealToolsAndPtyHelper.removeTempDirectory(tmpDir) }
        let canonDir = RealToolsAndPtyHelper.realPath(tmpDir)

        // 1. Default CorePty.Service() (NO backend override!) executes real `/bin/echo hello-native-pty`
        let ptyService = CorePty.Service(directory: canonDir)
        let created = try await ptyService.create(PtySchema.CreateInput(
            command: "/bin/echo",
            args: ["hello-native-pty"],
            cwd: canonDir,
            title: "Native Echo"
        ))
        #expect(created.pid.rawValue > 0)

        var finalInfo = created
        for _ in 0..<200 {
            finalInfo = try await ptyService.get(created.id)
            if finalInfo.status == .exited { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(finalInfo.status == .exited)
        #expect(finalInfo.exitCode?.rawValue == 0)
        let capturedReplay = try await ptyService.replay(created.id)
        #expect(capturedReplay.contains("hello-native-pty"))
        try await ptyService.remove(created.id)

        // 2. Live subscriber streaming via attach() on native POSIX PTY
        let streamCreated = try await ptyService.create(PtySchema.CreateInput(
            command: "/bin/sh",
            args: ["-c", "sleep 0.05 && /bin/echo hello-native-pty"],
            cwd: canonDir,
            title: "Native Stream"
        ))
        let streamedBox = ToolsConfigRuntimeHelper.Box<String>("")
        let exitedBox = ToolsConfigRuntimeHelper.Box<Int?>(nil)
        let didEndBox = ToolsConfigRuntimeHelper.Box<Bool>(false)
        let att = try await ptyService.attach(streamCreated.id, input: CorePty.AttachInput(
            onData: { chunk in streamedBox.update { $0 += chunk } },
            onEnd: { code in
                exitedBox.update { $0 = code }
                didEndBox.update { $0 = true }
            }
        ))
        att.activate()

        for _ in 0..<200 {
            if didEndBox.get() { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(didEndBox.get() == true)
        #expect(exitedBox.get() == 0)
        let combinedStream = att.replay + streamedBox.get()
        #expect(combinedStream.contains("hello-native-pty"))
        att.detach()
        try await ptyService.remove(streamCreated.id)

        // 3. Default CorePty.Persistent.Service() (NO backend override!) runs real `/bin/echo hello-persistent-pty`
        let persistent = CorePty.Persistent.Service(options: CorePty.Persistent.Options(root: canonDir))
        let sid = SessionID(rawValue: "ses_native_persistent_pty")!
        let pInfo = try await persistent.create(sessionID: sid, input: CorePty.Persistent.CreateTerminalInput(
            command: "/bin/echo",
            args: ["hello-persistent-pty"],
            cwd: canonDir,
            title: "Persistent Native Echo"
        ))
        #expect(pInfo.pid.rawValue > 0)
        var snapshotText = ""
        for _ in 0..<200 {
            let snap = try await persistent.snapshot(pInfo.id)
            snapshotText = snap.text
            if snapshotText.contains("hello-persistent-pty") { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(snapshotText.contains("hello-persistent-pty"))
        try await persistent.remove(pInfo.id)
        try await persistent.shutdown()
        #endif
    }

    // MARK: - 11. CoreSessionLiveSnapshotBridge wired to CoreSnapshot.Service

    @Test("CoreSessionLiveSnapshotBridge captures real snapshots, computes diffs, and restores files via CoreSessionRevert")
    func liveSnapshotBridgeCapturesDiffsAndRestores() async throws {
        let tmpDir = try RealToolsAndPtyHelper.makeTempDirectory(prefix: "opencode-live-snap")
        defer { RealToolsAndPtyHelper.removeTempDirectory(tmpDir) }
        let canonDir = RealToolsAndPtyHelper.realPath(tmpDir)

        let fileA = "\(canonDir)/app.swift"
        let fileB = "\(canonDir)/added.swift"
        try await LocalFileSystem.shared.writeFile(
            ToolsConfigRuntimeHelper.utf8Bytes("let version = 1\n"),
            to: fileA,
            createDirectories: true
        )

        let snapshotService = CoreSnapshot.Service(directory: canonDir, fileSystem: LocalFileSystem.shared)
        let bridge = CoreSessionLiveSnapshotBridge(service: snapshotService)

        // Capture initial state (v1)
        let snap1 = try #require(try await bridge.capture())

        // Mutate app.swift and add added.swift
        try await LocalFileSystem.shared.writeFile(
            ToolsConfigRuntimeHelper.utf8Bytes("let version = 2\nlet extra = true\n"),
            to: fileA,
            createDirectories: true
        )
        try await LocalFileSystem.shared.writeFile(
            ToolsConfigRuntimeHelper.utf8Bytes("struct Added {}\n"),
            to: fileB,
            createDirectories: true
        )
        let snap2 = try #require(try await bridge.capture())

        // Verify bridge diff returns real SessionSchema.FileDiffInfo entries
        let directDiff = try await bridge.diff(from: snap1, to: snap2, paths: nil)
        #expect(directDiff.count == 2)
        #expect(directDiff.first(where: { $0.file == "app.swift" })?.status == .modified)
        #expect(directDiff.first(where: { $0.file == "added.swift" })?.status == .added)

        // Verify end-to-end CoreSessionRevert.stage + CoreSessionRevert.clear + CoreSessionDiff.turn with CoreSessionLiveSnapshotBridge
        let harness = try await SessionDatabaseHelper.makeHarness(inMemory: true)
        let session = try await harness.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: canonDir),
            title: "Revert Test"
        ))
        let userMsgID = SessionMessageSchema.ID.create()
        let assistantMsgID = SessionMessageSchema.ID.create()
        try RealToolsAndPtyHelper.insertSessionMessagesForRevert(
            db: harness.db,
            sessionID: session.id,
            userMessageID: userMsgID,
            assistantMessageID: assistantMsgID,
            startSnapshot: snap1,
            endSnapshot: snap2,
            files: ["app.swift", "added.swift"]
        )

        // Turn diff reads snapshots from SQLite and delegates to bridge
        let turnDiffs = try await CoreSessionDiff.turn(
            db: harness.db,
            session: session,
            from: userMsgID,
            to: assistantMsgID,
            snapshot: bridge
        )
        #expect(turnDiffs.count == 2)

        // Staging revert to userMsgID restores app.swift to v1 and deletes added.swift!
        let revert = try await CoreSessionRevert.stage(
            db: harness.db,
            bus: harness.bus,
            session: session,
            messageID: userMsgID,
            restoreFiles: true,
            snapshot: bridge
        )
        #expect(revert.snapshot == snap2)
        #expect(revert.files?.count == 2)
        let restoredA = ToolsConfigRuntimeHelper.utf8String(try await LocalFileSystem.shared.readFile(at: fileA))
        #expect(restoredA == "let version = 1\n")
        #expect(await LocalFileSystem.shared.exists(at: fileB) == false)

        // Clearing the staged revert restores v2 + added.swift!
        let sessionWithRevert = try harness.session.get(session.id)
        try await CoreSessionRevert.clear(bus: harness.bus, session: sessionWithRevert, snapshot: bridge)
        let afterClearA = ToolsConfigRuntimeHelper.utf8String(try await LocalFileSystem.shared.readFile(at: fileA))
        #expect(afterClearA == "let version = 2\nlet extra = true\n")
        #expect(await LocalFileSystem.shared.exists(at: fileB) == true)
    }
}
