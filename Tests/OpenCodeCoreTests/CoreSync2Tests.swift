import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Core Sync #2 Parity Coverage")
struct CoreSync2Tests {
    // MARK: - 1. Session Search & Session Search Index

    @Test("SessionSearchIndex folds extra letters and classifies FTS query errors")
    func sessionSearchIndexFoldingAndErrors() {
        #expect(SessionSearchIndex.foldText("Straße") == "Strasse")
        #expect(SessionSearchIndex.foldText("Đơn đ") == "Dơn d")
        #expect(SessionSearchIndex.foldText("Łódź Øresund Æon Œuvre") == "Lódź Oresund AEon OEuvre")

        #expect(SessionSearchIndex.isQueryError(SQLiteError.unsupportedSQL("fts5: syntax error")))
        #expect(SessionSearchIndex.isQueryError(SQLiteError.stepFailed(sql: "SELECT 1", code: 1, message: "no such column: foo")))
        #expect(!SessionSearchIndex.isQueryError(SQLiteError.stepFailed(sql: "SELECT 1", code: 5, message: "database is locked")))
    }

    @Test("SessionSearch lists with pagination, directory prefix isolation, and subagent filtering")
    func sessionSearchListPaginationAndFiltering() async throws {
        let db = try await CoreSync2Helpers.openSearchDB()
        let projA = ProjectID(rawValue: "proj-a")
        let projB = ProjectID(rawValue: "proj-b")

        let s1 = SessionID.create()
        let s2 = SessionID.create()
        let s3 = SessionID.create()
        let sub = SessionID.create()
        let sibling = SessionID.create()
        let otherProj = SessionID.create()

        try CoreSync2Helpers.seedSession(db: db, id: s1, projectID: projA, directory: "/work/app", title: "Root app session", updated: 1_000)
        try CoreSync2Helpers.seedSession(db: db, id: s2, projectID: projA, directory: "/work/app/sub", title: "Nested dir session", updated: 2_000)
        try CoreSync2Helpers.seedSession(db: db, id: s3, projectID: projA, directory: "/work/app", title: "Newest app session", updated: 3_000)
        try CoreSync2Helpers.seedSession(db: db, id: sub, projectID: projA, directory: "/work/app", title: "Subagent worker", parentID: s3, updated: 4_000)
        try CoreSync2Helpers.seedSession(db: db, id: sibling, projectID: projA, directory: "/work/app_2", title: "Sibling prefix trap", updated: 5_000)
        try CoreSync2Helpers.seedSession(db: db, id: otherProj, projectID: projB, directory: "/work/other", title: "Other project", updated: 6_000)

        let service = SessionSearch.Service(db: db)

        // Default list excludes subagents and orders newest updated first.
        let page1 = try await service.search(SessionSearch.SearchInput(projectID: projA, directory: "/work/app", limit: 2, offset: 0))
        let p1Sessions = try #require(page1.sessions)
        #expect(p1Sessions.map(\.sessionID) == [s3, s2])
        #expect(page1.next == 2)

        // Second page ends with next == nil and encodes `"next":null` on the wire.
        let page2 = try await service.search(SessionSearch.SearchInput(projectID: projA, directory: "/work/app", limit: 2, offset: 2))
        let p2Sessions = try #require(page2.sessions)
        #expect(p2Sessions.map(\.sessionID) == [s1])
        #expect(page2.next == nil)
        let encodedPage2 = try CoreSync2Helpers.encodeToJSONString(page2)
        #expect(encodedPage2.contains(#""next":null"#))

        // Sibling `/work/app_2` must NOT match directory filter `/work/app` (LIKE escaping).
        #expect(!p1Sessions.contains { $0.sessionID == sibling })
        #expect(!p2Sessions.contains { $0.sessionID == sibling })

        // `subagents: true` includes subagent rows.
        let withSubs = try await service.search(SessionSearch.SearchInput(projectID: projA, directory: "/work/app", subagents: true, limit: 10))
        #expect(withSubs.sessions?.first?.sessionID == sub)
        #expect(withSubs.sessions?.first?.parentID == s3)

        // `sessionID` bypasses projectID filter.
        let bySession = try await service.search(SessionSearch.SearchInput(projectID: projA, sessionID: otherProj))
        #expect(bySession.sessions?.map(\.sessionID) == [otherProj])
    }

    @Test("SessionSearch FTS5 full-text search handles diacritics, stemming, 3-hit cap, syntax fallback, and missing index")
    func sessionSearchFTSQueriesAndFallback() async throws {
        let db = try await CoreSync2Helpers.openSearchDB()
        let proj = ProjectID(rawValue: "proj-fts")
        let s1 = SessionID.create()
        let s2 = SessionID.create()

        try CoreSync2Helpers.seedSession(db: db, id: s1, projectID: proj, directory: "/work/fts", title: "Hóa đơn billing audit", updated: 2_000)
        try CoreSync2Helpers.seedSession(db: db, id: s2, projectID: proj, directory: "/work/fts", title: "Straße deployment notes", updated: 1_000)

        // Seed 4 matching user messages in s1 to verify the 3-hit cap per session.
        for i in 1...4 {
            let msgID = SessionMessageSchema.ID.create()
            let userMsg = SessionMessageSchema.Info.user(SessionMessageSchema.User(
                id: msgID,
                time: SessionMessageSchema.TimeCreated(created: Int64(1_000 + i * 10)),
                text: "Invoice batch \(i): running hóa đơn export for customer \(i)"
            ))
            try CoreSync2Helpers.seedMessage(db: db, sessionID: s1, seq: Int64(i), message: userMsg, created: Int64(1_000 + i * 10))
        }

        let asstID = SessionMessageSchema.ID.create()
        let asstMsg = SessionMessageSchema.Info.assistant(SessionMessageSchema.Assistant(
            id: asstID,
            agent: "build",
            model: SessionSchema.ModelRef(id: "claude-sonnet-4", providerID: "anthropic"),
            content: [
                .text(SessionMessageSchema.AssistantText(text: "Checked Straße gateway and confirmed service runs cleanly.")),
            ],
            finish: .stop,
            time: SessionMessageSchema.Assistant.Time(created: 1_050, completed: 1_055)
        ))
        try CoreSync2Helpers.seedMessage(db: db, sessionID: s2, seq: 1, message: asstMsg, created: 1_050)

        try CoreSync2Helpers.buildSearchIndex(db: db)

        let service = SessionSearch.Service(db: db)

        // Diacritic-insensitive query matches title & messages, capped at 3 matches per session.
        let diacriticRes = try await service.search(SessionSearch.SearchInput(query: "hoa don", projectID: proj))
        let results = try #require(diacriticRes.results)
        #expect(results.count == 1)
        #expect(results[0].sessionID == s1)
        #expect(results[0].matches.count == 3)

        // Extra-letter folding (`Straße` <-> `strasse`) + English stemming (`running` <-> `runs`).
        let foldedRes = try await service.search(SessionSearch.SearchInput(query: "strasse running", projectID: proj))
        #expect(foldedRes.results?.first?.sessionID == s2)
        #expect(foldedRes.results?.first?.matches.first?.snippet.contains("Straße") == true)

        // Invalid FTS syntax (unbalanced quote / stray colon) falls back to plainOrQuery instead of failing.
        let fallbackRes = try await service.search(SessionSearch.SearchInput(query: #"foo: "strasse"#, projectID: proj))
        #expect(fallbackRes.results?.contains { $0.sessionID == s2 } == true)

        // Punctuation-only query returns empty results cleanly.
        let punctRes = try await service.search(SessionSearch.SearchInput(query: "!!! --- :::", projectID: proj))
        #expect(punctRes.results == [])

        // Missing FTS table throws `IndexUnavailableError`.
        let unindexedDB = try await CoreSync2Helpers.openSearchDB()
        let unindexedService = SessionSearch.Service(db: unindexedDB)
        await #expect(throws: SessionSearch.IndexUnavailableError.self) {
            _ = try await unindexedService.search(SessionSearch.SearchInput(query: "hello"))
        }
    }

    @Test("SessionSearch.read paginates around/before/after without duplicates and toggles full tool details")
    func sessionSearchReadPaginationAndToolDetails() async throws {
        let db = try await CoreSync2Helpers.openSearchDB()
        let proj = ProjectID(rawValue: "proj-read")
        let sid = SessionID.create()
        try CoreSync2Helpers.seedSession(db: db, id: sid, projectID: proj, directory: "/work/read", title: "Transcript test")

        let m1 = SessionMessageSchema.ID.create()
        let mSys = SessionMessageSchema.ID.create()
        let m2 = SessionMessageSchema.ID.create()
        let m3 = SessionMessageSchema.ID.create()

        try CoreSync2Helpers.seedMessage(
            db: db,
            sessionID: sid,
            seq: 1,
            message: .user(SessionMessageSchema.User(id: m1, time: .init(created: 100), text: "First question")),
            created: 100
        )
        try CoreSync2Helpers.seedMessage(
            db: db,
            sessionID: sid,
            seq: 2,
            message: .system(SessionMessageSchema.System(id: mSys, time: .init(created: 150), text: "System note")),
            created: 150
        )
        let toolPart = SessionMessageSchema.AssistantTool(
            id: "call-1",
            name: "read",
            state: .completed(SessionMessageSchema.ToolStateCompleted(
                input: ["filePath": .string("/work/read/README.md")],
                content: [.text("README body content")]
            )),
            time: SessionMessageSchema.AssistantTool.Time(created: 200, completed: 210)
        )
        try CoreSync2Helpers.seedMessage(
            db: db,
            sessionID: sid,
            seq: 3,
            message: .assistant(SessionMessageSchema.Assistant(
                id: m2,
                agent: "build",
                model: SessionSchema.ModelRef(id: "claude-sonnet-4", providerID: "anthropic"),
                content: [
                    .text(SessionMessageSchema.AssistantText(text: "Checking files now.")),
                    .tool(toolPart),
                ],
                finish: .stop,
                time: .init(created: 200, completed: 220)
            )),
            created: 200
        )
        try CoreSync2Helpers.seedMessage(
            db: db,
            sessionID: sid,
            seq: 4,
            message: .user(SessionMessageSchema.User(id: m3, time: .init(created: 300), text: "Thanks!")),
            created: 300
        )

        let service = SessionSearch.Service(db: db)

        // Compact read hides system messages and summarizes tool calls as single strings.
        let compact = try await service.read(SessionSearch.ReadInput(sessionID: sid, messageID: m2, direction: .around, limit: 5, full: false))
        #expect(compact.messages.map(\.messageID) == [m1, m2, m3])
        let assistantCompact = try #require(compact.messages.first { $0.messageID == m2 })
        if case .summary(let line) = assistantCompact.calls?.first {
            #expect(line == #"read({"filePath":"/work/read/README.md"})"#)
        } else {
            Issue.record("Expected compact summary call entry")
        }

        // Full read includes system messages and full CallDetail with output.
        let full = try await service.read(SessionSearch.ReadInput(sessionID: sid, messageID: m2, direction: .around, limit: 10, full: true))
        #expect(full.messages.contains { $0.messageID == mSys })
        let assistantFull = try #require(full.messages.first { $0.messageID == m2 })
        if case .detail(let detail) = assistantFull.calls?.first {
            #expect(detail.name == "read")
            #expect(detail.status == "completed")
            #expect(detail.output?.contains("README body content") == true)
        } else {
            Issue.record("Expected CallDetail entry when full=true")
        }

        // Cursor pagination: `after` from oldest never repeats anchor.
        let oldest = try await service.read(SessionSearch.ReadInput(sessionID: sid, direction: .after, limit: 2))
        #expect(oldest.messages.map(\.messageID) == [m1, m2])
        #expect(oldest.older == nil)
        #expect(oldest.newer == m2)

        let nextPage = try await service.read(SessionSearch.ReadInput(sessionID: sid, messageID: oldest.newer, direction: .after, limit: 2))
        #expect(nextPage.messages.map(\.messageID) == [m3])
        #expect(nextPage.newer == nil)

        // Error cases
        await #expect(throws: SessionSearch.SessionNotFoundError.self) {
            _ = try await service.read(SessionSearch.ReadInput(sessionID: SessionID.create()))
        }
        await #expect(throws: SessionSearch.MessageNotFoundError.self) {
            _ = try await service.read(SessionSearch.ReadInput(sessionID: sid, messageID: SessionMessageSchema.ID.create()))
        }
    }

    @Test("SessionSearchTools.Plugin registers opencode.session tools only when sqlite_fts is enabled")
    func sessionSearchToolPluginGatingAndScope() async throws {
        let db = try await CoreSync2Helpers.openSearchDB()
        let projA = ProjectID(rawValue: "proj-tool-a")
        let projB = ProjectID(rawValue: "proj-tool-b")
        let sA = SessionID.create()
        let sB = SessionID.create()
        try CoreSync2Helpers.seedSession(db: db, id: sA, projectID: projA, directory: "/work/a", title: "Alpha session")
        try CoreSync2Helpers.seedSession(db: db, id: sB, projectID: projB, directory: "/work/b", title: "Beta session")
        let searchService = SessionSearch.Service(db: db)

        // Disabled when sqliteFts == false
        let disabledRegistry = CoreTool.Service()
        var disabledEnv = CoreTool.BuiltinEnvironment(
            directory: "/work/a",
            projectID: projA,
            sessionSearch: searchService
        )
        disabledEnv.sqliteFts = false
        let disabledEnvSnap = disabledEnv
        _ = await disabledRegistry.transform { editor in
            CoreTool.SessionSearchTools.Plugin.register(editor, disabledEnvSnap)
        }
        let disabledNames = Set(await disabledRegistry.list().map(\.id))
        #expect(!disabledNames.contains("opencode_session_search"))
        #expect(!disabledNames.contains("opencode_session_read"))

        // Enabled when sqliteFts == true
        let enabledRegistry = CoreTool.Service()
        var enabledEnv = CoreTool.BuiltinEnvironment(
            directory: "/work/a",
            projectID: projA,
            sessionSearch: searchService
        )
        enabledEnv.sqliteFts = true
        let enabledEnvSnap = enabledEnv
        _ = await enabledRegistry.transform { editor in
            CoreTool.SessionSearchTools.Plugin.register(editor, enabledEnvSnap)
        }
        let toolsByPath = await enabledRegistry.codeModeTools(["opencode.session.search", "opencode.session.read"])
        #expect(toolsByPath.keys.contains("opencode.session.search"))
        #expect(toolsByPath.keys.contains("opencode.session.read"))

        let searchTool = try #require(toolsByPath["opencode.session.search"])
        let ctx = ToolSchema.Context(
            sessionID: sA,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg-1",
            id: ToolSchema.CallID(rawValue: "call-1"),
            progress: { _ in }
        )
        let projOnly = try await searchTool.execute(.object([:]), ctx)
        if case .object(let obj) = projOnly.output, case .array(let arr) = obj["sessions"] {
            #expect(arr.count == 1)
        } else {
            Issue.record("Expected sessions array from opencode.session.search")
        }

        let allScope = try await searchTool.execute(.object(["scope": .string("all")]), ctx)
        if case .object(let obj) = allScope.output, case .array(let arr) = obj["sessions"] {
            #expect(arr.count == 2)
        } else {
            Issue.record("Expected sessions array for scope=all")
        }
    }

    // MARK: - 2. Shell Permissions & FileAccess

    @Test("CoreShellPermissions.requests handles local/remote, external directories, and once mode")
    func shellPermissionsRequests() async throws {
        let workDir = "/workspace/repo"
        let fileAccess = CoreFilesystem.FileAccess.Service(
            directory: workDir,
            worktree: workDir,
            environment: CoreLocation.Environment.local()
        )
        let target = try await fileAccess.resolve(CoreFilesystem.FileAccess.ResolveInput(path: ".", kind: .directory))

        // Normal mode includes save patterns and detects external directory access.
        let normalReqs = try await CoreShellPermissions.requests(
            access: fileAccess,
            input: CoreShellPermissions.RequestInput(
                command: "cd /tmp && ls -la",
                program: "/bin/sh",
                target: target,
                once: false
            )
        )
        #expect(normalReqs.count == 2)
        #expect(normalReqs[0].action == "external_directory")
        #expect(normalReqs[0].resources.contains("/tmp/*"))
        #expect(normalReqs[0].save != nil)
        #expect(normalReqs[1].action == "shell")
        #expect(normalReqs[1].save != nil)

        // `once: true` strips `save` patterns on every request and still emits a `shell` request even when parser yields no subcommands.
        let onceReqs = try await CoreShellPermissions.requests(
            access: fileAccess,
            input: CoreShellPermissions.RequestInput(
                command: "# comment only",
                program: "/bin/sh",
                target: target,
                once: true
            )
        )
        #expect(onceReqs.count == 1)
        #expect(onceReqs[0].action == "shell")
        #expect(onceReqs[0].resources == ["# comment only"])
        #expect(onceReqs[0].save == nil)
    }

    @Test("FileAccess.always scopes remote machines and rejects relative known-machine paths")
    func fileAccessAlwaysAndRelativeMachineRejection() async throws {
        let localTarget = CoreFilesystem.FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/repo/a.txt"),
            resource: "a.txt",
            machine: nil
        )
        let gpuID = CoreLocation.Environment.ID(rawValue: "gpu")
        let remoteTarget = CoreFilesystem.FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/work/train.py"),
            resource: "gpu:/work/train.py",
            machine: gpuID
        )
        #expect(CoreFilesystem.FileAccess.always(localTarget) == "*")
        #expect(CoreFilesystem.FileAccess.always(remoteTarget) == "gpu:*")

        let machines = Sync2StubMachines(items: [Machines.Info(id: "gpu", online: true, paired: true)])
        let flags = CoreFlag.Service(
            config: CoreConfig.Test(),
            channel: "local"
        )
        let fileAccess = CoreFilesystem.FileAccess.Service(
            directory: "/workspace/repo",
            worktree: "/workspace/repo",
            environment: CoreLocation.Environment.local(),
            flags: flags,
            machines: machines
        )

        // Relative path prefixed with a known machine name must fail instead of falling through to a local file named `gpu:work`.
        await #expect(throws: (any Error).self) {
            _ = try await fileAccess.resolve(CoreFilesystem.FileAccess.ResolveInput(path: "gpu:work/train.py", kind: .file))
        }
    }

    // MARK: - 3. Automation Shell Actions, Code AST Scanner, & Tool Plugin

    @Test("CoreAutomationShell.authorize enforces once-only approval and rejects author mismatch")
    func automationShellAuthorize() async throws {
        let tmpDir = try CoreSync2Helpers.makeTempDirectory(prefix: "auto-shell-auth")
        defer { CoreSync2Helpers.removeItem(at: tmpDir) }

        let env = CoreLocation.Environment.local()
        let fileAccess = CoreFilesystem.FileAccess.Service(directory: tmpDir, worktree: tmpDir, environment: env)
        let permission = Sync2RecordingPermission()
        let agents = CoreAgent.Agent.Service()
        let shellSelect = CoreShell.Select.Service()

        let ownerID = SessionID.create()
        let owner = SessionSchema.Info(
            id: ownerID,
            projectID: ProjectID(rawValue: "proj-auto"),
            agent: "build",
            cost: 0,
            tokens: SessionSchema.TokenUsage(input: 0, output: 0, reasoning: 0, cache: SessionSchema.TokenUsage.Cache(read: 0, write: 0)),
            time: SessionSchema.Info.Time(created: 1_000, updated: 1_000),
            location: OpenCodeLocation(directory: tmpDir)
        )

        try await CoreAutomationShell.authorize(
            owner: owner,
            name: "nightly-check",
            trigger: .cron(AutomationSchema.Cron(cron: "0 9 * * *", tz: "UTC")),
            action: AutomationSchema.ShellAction(command: "echo ok"),
            agents: agents,
            shellSelect: shellSelect,
            environment: env,
            fileAccess: fileAccess,
            permission: permission
        )

        let assertions = permission.recorded
        #expect(assertions.count == 1)
        #expect(assertions[0].action == "shell")
        #expect(assertions[0].save == nil)
        #expect(assertions[0].metadata?["automation"] == .string("nightly-check"))
        #expect(assertions[0].metadata?["unattended"] == .bool(true))
        #expect(assertions[0].metadata?["command"] == .string("echo ok"))

        // Mismatched invocation session fails with InvalidError.
        await #expect(throws: CoreAutomation.InvalidError.self) {
            try await CoreAutomationShell.authorize(
                owner: owner,
                name: "bad-author",
                trigger: .cron(AutomationSchema.Cron(cron: "0 9 * * *", tz: "UTC")),
                action: AutomationSchema.ShellAction(command: "echo nope"),
                invocation: CoreAutomation.Author.Invocation(
                    sessionID: SessionID.create(),
                    agent: AgentSchema.ID(rawValue: "build")
                ),
                agents: agents,
                shellSelect: shellSelect,
                environment: env,
                fileAccess: fileAccess,
                permission: permission
            )
        }
    }

    @Test("CoreAutomation executes shell actions end-to-end and respects automations config toggle")
    func automationShellExecutionAndDisableConfig() async throws {
        let tmpDir = try CoreSync2Helpers.makeTempDirectory(prefix: "auto-shell-run")
        defer { CoreSync2Helpers.removeItem(at: tmpDir) }

        let db = try await CoreSync2Helpers.openSearchDB()
        let projectID = ProjectID(rawValue: "proj-shell-auto")
        let ownerID = SessionID.create()
        try CoreSync2Helpers.seedSession(db: db, id: ownerID, projectID: projectID, directory: tmpDir, title: "Automation owner")

        let env = CoreLocation.Environment.local()
        let fileAccess = CoreFilesystem.FileAccess.Service(directory: tmpDir, worktree: tmpDir, environment: env)
        let permission = Sync2RecordingPermission()
        let agents = CoreAgent.Agent.Service()
        let shellSelect = CoreShell.Select.Service()
        let shellService = CoreShell.Service(directory: tmpDir, projectID: projectID)

        // When disabled via `automations: false`, create throws DisabledError.
        let disabledService = try CoreAutomation.Service(
            database: db,
            isEnabled: { _ in false },
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: false,
                    agents: agents,
                    permission: permission,
                    shell: shellService,
                    shellSelect: shellSelect,
                    fileAccess: fileAccess,
                    environment: env
                )
            }
        )
        await #expect(throws: CoreAutomation.DisabledError.self) {
            _ = try await disabledService.create(
                AutomationSchema.CreateInput(
                    sessionID: ownerID,
                    name: "blocked",
                    trigger: .cron(AutomationSchema.Cron(cron: "0 9 * * *", tz: "UTC")),
                    action: .shell(AutomationSchema.ShellActionInput(command: "echo blocked"))
                ),
                projectID: projectID,
                directory: tmpDir,
                invocation: nil
            )
        }

        // Enabled service creates & ticks a due shell action and records its async exit outcome.
        let nowBox = AtomicBox<Int64>(1_700_000_000_000)
        let enabledService = try CoreAutomation.Service(
            database: db,
            clock: { nowBox.get() },
            isEnabled: { _ in true },
            resolveLocation: { _ in
                CoreAutomation.LocationContext(
                    enabled: true,
                    agents: agents,
                    permission: permission,
                    shell: shellService,
                    shellSelect: shellSelect,
                    fileAccess: fileAccess,
                    environment: env
                )
            }
        )
        let created = try await enabledService.create(
            AutomationSchema.CreateInput(
                sessionID: ownerID,
                name: "say-hello",
                trigger: .every(AutomationSchema.Every(every: "1 minute")),
                action: .shell(AutomationSchema.ShellActionInput(command: "echo hello-shell-automation"))
            ),
            projectID: projectID,
            directory: tmpDir,
            invocation: nil
        )
        #expect(created.status == .active)

        // Advance clock to due time and tick!
        nowBox.modify { $0 += 60_000 }
        try await enabledService.tick()

        var finalInfo = try await enabledService.get(created.id)
        for _ in 0..<60 {
            if finalInfo.lastOutput != nil { break }
            try await Task.sleep(for: .milliseconds(50))
            finalInfo = try await enabledService.get(created.id)
        }
        #expect(finalInfo.runCount.rawValue == 1)
        #expect(finalInfo.lastOutcome == .fired)
        #expect(finalInfo.lastOutput?.contains("hello-shell-automation") == true)
    }

    @Test("CoreAutomation.Code.scan tracks fetch, Bun read/write, slice forwarding, and tool paths")
    func automationCodeScannerCapabilities() throws {
        // Read-only Bun.file().slice().text() requires read + external_directory (not edit)
        let readScan = try CoreAutomation.Code.scan("""
        const f = Bun.file("/tmp/data.txt");
        return await f.slice(0, 10).text();
        """).get()
        #expect(readScan.actions.contains("read"))
        #expect(readScan.actions.contains("external_directory"))
        #expect(!readScan.actions.contains("edit"))
        #expect(!readScan.actions.contains("webfetch"))

        // Write via Bun.write(...) requires edit + external_directory (not read)
        let writeScan = try CoreAutomation.Code.scan("""
        await Bun.write("/tmp/out.txt", "hi");
        """).get()
        #expect(!writeScan.actions.contains("read"))
        #expect(writeScan.actions.contains("edit"))
        #expect(writeScan.actions.contains("external_directory"))

        // fetch usage requires webfetch
        let fetchScan = try CoreAutomation.Code.scan("""
        const res = await fetch("https://example.com");
        return await res.text();
        """).get()
        #expect(fetchScan.actions.contains("webfetch"))

        // import "bun" treated conservatively as read + edit + external_directory
        let importScan = try CoreAutomation.Code.scan("""
        import { file } from "bun";
        return file;
        """).get()
        #expect(importScan.actions.contains("read"))
        #expect(importScan.actions.contains("edit"))
        #expect(importScan.actions.contains("external_directory"))

        // Static tools.* path extraction
        let toolScan = try CoreAutomation.Code.scan("""
        return await tools.shell({ command: "echo hi" });
        """).get()
        #expect(toolScan.tools == ["shell"])
    }

    @Test("AutomationTools.Plugin gates on automationsEnabled and registers automation namespace")
    func automationToolPluginNamespace() async {
        let offRegistry = CoreTool.Service()
        var offEnv = CoreTool.BuiltinEnvironment(directory: "/work", projectID: ProjectID(rawValue: "p"))
        offEnv.automationsEnabled = false
        let offEnvSnap = offEnv
        _ = await offRegistry.transform { editor in
            CoreTool.AutomationTools.Plugin.register(editor, offEnvSnap)
        }
        #expect(await offRegistry.list().isEmpty)

        let onRegistry = CoreTool.Service()
        var onEnv = CoreTool.BuiltinEnvironment(directory: "/work", projectID: ProjectID(rawValue: "p"))
        onEnv.automationsEnabled = true
        let onEnvSnap = onEnv
        _ = await onRegistry.transform { editor in
            CoreTool.AutomationTools.Plugin.register(editor, onEnvSnap)
        }
        let ids = Set(await onRegistry.list().map(\.id))
        #expect(ids == Set(["automation_create", "automation_list", "automation_pause", "automation_resume", "automation_delete"]))
    }

    // MARK: - 4. Flag Resolution & Config Overlay

    @Test("CoreFlagResolve resolves channel defaults, optInOnly, config experimental, and env precedence")
    func flagResolveRules() {
        let local = CoreFlagResolve.resolve(CoreFlagResolve.ResolveInput(entries: [], channel: "local"))
        #expect(local[.projectOverlay] == CoreFlagResolve.State(enabled: true, source: .default))
        #expect(local[.sqliteFts] == CoreFlagResolve.State(enabled: true, source: .default))
        #expect(local[.todo] == CoreFlagResolve.State(enabled: false, source: .default))

        let release = CoreFlagResolve.resolve(CoreFlagResolve.ResolveInput(entries: [], channel: "latest"))
        #expect(release[.projectOverlay] == CoreFlagResolve.State(enabled: false, source: .default))
        #expect(release[.sqliteFts] == CoreFlagResolve.State(enabled: false, source: .default))

        // Env overrides beat config, `all` skips optInOnly (`todo`).
        let entries: [CoreConfigEntry] = [
            .document(ConfigSchema.Document(info: ConfigSchema.Info(
                experimental: ConfigExperimentalSchema.Info(projectOverlay: false, sqliteFts: true)
            ))),
        ]
        let overridden = CoreFlagResolve.resolve(CoreFlagResolve.ResolveInput(
            entries: entries,
            channel: "latest",
            overrides: "all,-sqlite_fts"
        ))
        #expect(overridden[.projectOverlay] == CoreFlagResolve.State(enabled: true, source: .env))
        #expect(overridden[.sqliteFts] == CoreFlagResolve.State(enabled: false, source: .env))
        #expect(overridden[.todo] == CoreFlagResolve.State(enabled: false, source: .default))
    }

    @Test("CoreConfigNormalize flags removed experimental.automations/schedules and CoreConfig loads project overlay")
    func configNormalizeAndProjectOverlay() async throws {
        // Removed experimental keys emit `.removed` diagnostics and are stripped while top-level `automations` stays.
        let raw: JSONValue = .object([
            "automations": .bool(false),
            "experimental": .object([
                "automations": .bool(true),
                "schedules": .bool(true),
                "project_overlay": .bool(true),
            ]),
        ])
        let normalized = CoreConfigNormalize.normalize(raw)
        if case .normalized(let doc, let diagnostics) = normalized {
            #expect(diagnostics.contains { $0.kind == .removed && $0.path == ["experimental", "automations"] })
            #expect(diagnostics.contains { $0.kind == .removed && $0.path == ["experimental", "schedules"] })
            #expect(doc["automations"] == .bool(false))
            if case .object(let exp) = doc["experimental"] {
                #expect(exp["automations"] == nil)
                #expect(exp["schedules"] == nil)
                #expect(exp["project_overlay"] == .bool(true))
            } else {
                Issue.record("Expected experimental object to remain with project_overlay")
            }
        } else {
            Issue.record("Expected normalized config result")
        }

        // Project overlay discovery & loading between global and project config.
        let tmp = try CoreSync2Helpers.makeTempDirectory(prefix: "config-overlay")
        defer { CoreSync2Helpers.removeItem(at: tmp) }
        let globalPaths = CoreSync2Helpers.makeGlobalPaths(root: tmp)
        let projectDir = "\(tmp)/repo"
        let projectID = ProjectID(rawValue: "proj-overlay-1")
        let overlayDir = "\(globalPaths.config)/project/\(projectID.rawValue)"

        try CoreSync2Helpers.writeText(#"{"model":"global/m1","default_agent":"global-agent"}"#, to: "\(globalPaths.config)/opencode.json")
        try CoreSync2Helpers.writeText(#"{"model":"overlay/m2"}"#, to: "\(overlayDir)/opencode.json")
        try CoreSync2Helpers.writeText(#"{"default_agent":"project-agent"}"#, to: "\(projectDir)/opencode.json")

        let overlayCandidate = await CoreConfigDiscovery.overlay(projectID: projectID, global: globalPaths)
        #expect(overlayCandidate?.path.rawValue == overlayDir)

        // Channel `local` enables `project_overlay` by default: overlay overrides global `model`, project overrides `default_agent`.
        let loadedSvc = await CoreConfig.Service(
            directory: projectDir,
            projectID: projectID,
            channel: "local",
            globalPaths: globalPaths
        )
        let loadedEntries = await loadedSvc.entries()
        #expect(CoreConfig.latest(loadedEntries, \.model)?.providerID.rawValue == "overlay")
        #expect(CoreConfig.latest(loadedEntries, \.defaultAgent) == "project-agent")

        // When `project_overlay: false` is set via env override, overlay is skipped so `model` stays `"global/m1"`.
        let skippedSvc = await CoreConfig.Service(
            directory: projectDir,
            projectID: projectID,
            channel: "local",
            flagOverrides: "-project_overlay",
            globalPaths: globalPaths
        )
        let skippedEntries = await skippedSvc.entries()
        #expect(CoreConfig.latest(skippedEntries, \.model)?.providerID.rawValue == "global")
        #expect(CoreConfig.latest(skippedEntries, \.defaultAgent) == "project-agent")
    }

    // MARK: - 5. Tool Registry CodeMode Rewrite, Machine Tool, MCP Client, & Plugins

    @Test("CoreSessionStep.asProgram rewrites top-level Code Mode tool calls into execute")
    func sessionStepCodeModeToolCallRewrite() {
        let events: [AISchema.LLMEvent] = [
            .toolInputStart(AISchema.ToolInputStart(id: "tc-1", name: "opencode_session_search")),
            .toolInputDelta(AISchema.ToolInputDelta(id: "tc-1", name: "opencode_session_search", text: #"{"query":"hello"}"#)),
            .toolInputEnd(AISchema.ToolInputEnd(id: "tc-1", name: "opencode_session_search")),
            .toolCall(AISchema.ToolCall(id: "tc-1", name: "opencode_session_search", input: .object(["query": .string("hello")]))),
            .toolCall(AISchema.ToolCall(id: "tc-2", name: "read", input: .object(["filePath": .string("/a.txt")]))),
        ]
        var programs: [String: String] = [:]
        let expressionFor: @Sendable (String) -> String? = { name in
            name == "opencode_session_search" ? "tools.opencode.session.search" : nil
        }

        let collected = events.compactMap { CoreSessionStep.asProgram($0, programs: &programs, expressionFor: expressionFor) }

        #expect(collected.contains {
            if case .toolInputStart(let s) = $0 { return s.id == "tc-1" && s.name == "execute" }
            return false
        })
        #expect(!collected.contains {
            if case .toolInputDelta(let d) = $0 { return d.id == "tc-1" }
            return false
        })
        #expect(collected.contains {
            if case .toolCall(let c) = $0,
               c.id == "tc-1",
               c.name == "execute",
               case .object(let obj) = c.input,
               case .string(let code) = obj["code"]
            {
                return code.hasPrefix("return await tools.opencode.session.search(")
            }
            return false
        })
        // Direct tool (`read`) passes through unchanged.
        #expect(collected.contains {
            if case .toolCall(let c) = $0 { return c.id == "tc-2" && c.name == "read" }
            return false
        })
    }

    @Test("MachineTools.Plugin gates on machinesEnabled and lists machines")
    func machineToolsPluginGating() async throws {
        let disabledRegistry = CoreTool.Service()
        var disabledEnv = CoreTool.BuiltinEnvironment(directory: "/work", projectID: ProjectID(rawValue: "p"))
        disabledEnv.machinesEnabled = false
        let disabledEnvSnap = disabledEnv
        _ = await disabledRegistry.transform { editor in
            CoreTool.MachineTools.Plugin.register(editor, disabledEnvSnap)
        }
        #expect(await disabledRegistry.list().isEmpty)

        let enabledRegistry = CoreTool.Service()
        var enabledEnv = CoreTool.BuiltinEnvironment(directory: "/work", projectID: ProjectID(rawValue: "p"))
        enabledEnv.machinesEnabled = true
        let enabledEnvSnap = enabledEnv
        _ = await enabledRegistry.transform { editor in
            CoreTool.MachineTools.Plugin.register(editor, enabledEnvSnap)
        }
        let tools = await enabledRegistry.codeModeTools(["machine.list"])
        let listTool = try #require(tools["machine.list"])
        let ctx = ToolSchema.Context(
            sessionID: SessionID.create(),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "m1",
            id: ToolSchema.CallID(rawValue: "c1"),
            progress: { _ in }
        )
        let res = try await listTool.execute(.object([:]), ctx)
        let expectedOutput: JSONValue = .object(["machines": .array([])])
        #expect(res.output == expectedOutput)
    }

    @Test("CoreMCP.Client handles version negotiation, rejectsUnknownQuery, ?codemode=false retry, and auto timeout fallback")
    func mcpClientNegotiationAndFallbacks() async throws {
        // Version negotiation
        #expect(CoreMCP.Client.negotiation(protocol: .legacy, startupMs: 30_000) == .legacy)
        #expect(CoreMCP.Client.negotiation(protocol: .auto, startupMs: 30_000) == .auto(probeTimeoutMs: 5_000))
        #expect(CoreMCP.Client.negotiation(protocol: .auto, startupMs: 1_200) == .auto(probeTimeoutMs: 1_200))
        #expect(CoreMCP.Client.negotiation(protocol: .rev20260728, startupMs: 30_000) == .pin("2026-07-28"))

        // rejectsUnknownQuery
        #expect(CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("https://gmailmcp.googleapis.com/mcp"))))
        #expect(CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("https://gateway.zohomcp.eu/rpc"))))
        #expect(CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("http://localhost:3845/mcp"))))
        #expect(CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("http://127.0.0.1:8080/mcp"))))
        #expect(CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("http://[::1]:8080/mcp"))))
        #expect(!CoreMCP.Client.rejectsUnknownQuery(try #require(CoreSync2Helpers.parseURL("https://mcp.cloudflare.com/sse"))))

        // ?codemode=false retry on 404
        let retryHTTP = Sync2MockHTTPTransport { req in
            if req.url.contains("codemode=false") {
                return CoreSync2Helpers.makeTextResponse(status: 404, body: "unknown query param")
            }
            let msg = try CoreSync2Helpers.decodeRPCRequest(from: req.body)
            switch msg {
            case .request(let r) where r.method == "initialize":
                return try CoreSync2Helpers.makeJSONResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object(["protocolVersion": .string("2026-07-28"), "serverInfo": .object(["name": .string("cf")])]),
                ]))
            case .notification:
                return CoreSync2Helpers.makeTextResponse(status: 202)
            default:
                return CoreSync2Helpers.makeTextResponse(status: 404)
            }
        }
        let conn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "cf",
            config: .remote(McpSchema.RemoteConfig(url: "https://mcp.cloudflare.com/rpc")),
            http: retryHTTP
        ))
        #expect(conn.modern)
        #expect(retryHTTP.requests.first?.url == "https://mcp.cloudflare.com/rpc?codemode=false")
        #expect(retryHTTP.requests.dropFirst().first?.url == "https://mcp.cloudflare.com/rpc")

        // Auto probe timeout falls back to legacy within startup budget.
        let attempts = AtomicCounter(0)
        let seenRequestedVersions = AtomicBox<[String]>([])
        let slowProbeHTTP = Sync2MockHTTPTransport { req in
            let msg = try CoreSync2Helpers.decodeRPCRequest(from: req.body)
            switch msg {
            case .request(let r) where r.method == "initialize":
                if case .object(let p) = r.params, case .string(let v) = p["protocolVersion"] {
                    seenRequestedVersions.modify { $0.append(v) }
                }
                let count = attempts.increment()
                if count == 1 {
                    // Simulate hanging modern auto probe until probe timeout fires.
                    try await Task.sleep(for: .milliseconds(500))
                }
                return try CoreSync2Helpers.makeJSONResponse(body: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(1),
                    "result": .object(["protocolVersion": .string("2025-11-25"), "serverInfo": .object(["name": .string("legacy-srv")])]),
                ]))
            case .notification:
                return CoreSync2Helpers.makeTextResponse(status: 202)
            default:
                return CoreSync2Helpers.makeTextResponse(status: 404)
            }
        }
        let fallbackConn = try await CoreMCP.Client.connect(CoreMCP.Client.ConnectOptions(
            server: "legacy-srv",
            config: .remote(McpSchema.RemoteConfig(
                url: "http://127.0.0.1:9999/rpc",
                timeout: McpSchema.TimeoutConfig(startup: SchemaPrimitive.PositiveInt(rawValue: 10_000)),
                wireProtocol: .auto
            )),
            http: slowProbeHTTP,
            probeTimeoutMs: 60
        ))
        #expect(!fallbackConn.modern)
        #expect(fallbackConn.protocolVersion == "2025-11-25")
        #expect(attempts.value == 2)
        #expect(seenRequestedVersions.get() == [CoreMCP.Client.latestProtocolVersion, CoreMCP.Client.legacyProtocolVersion])
    }

    @Test("NpmSpec.classifyFollows, OpencodeWatches.shellTarget, HomeMemoryPlugin, and PluginGui updates")
    func pluginAndNpmFollowsParity() {
        // NpmSpec.classifyFollows
        #expect(NpmSpec.classifyFollows("foo@latest") == .always)
        #expect(NpmSpec.classifyFollows("foo@^1.2.0") == .always)
        #expect(NpmSpec.classifyFollows("foo") == .never)
        #expect(NpmSpec.classifyFollows("foo@1.2.3") == .never)
        #expect(NpmSpec.classifyFollows("foo@next") == .never)
        #expect(NpmSpec.classifyFollows("github:org/repo#semver:^1.0.0") == .always)
        if case .gitRef(_, let ref) = NpmSpec.classifyFollows("github:org/repo#main") {
            #expect(ref == "main")
        } else {
            Issue.record("Expected gitRef for github:org/repo#main")
        }

        // OpencodeWatches.shellTarget accepts nullable exitCode (nil -> no target, 0 -> detects PR target)
        let nilExit = CorePlugin.OpencodeWatches.shellTarget(
            command: "gh pr create",
            exitCode: nil,
            output: "https://github.com/anomalyco/opencode/pull/42"
        )
        #expect(nilExit == nil)
        let okExit = CorePlugin.OpencodeWatches.shellTarget(
            command: "gh pr create",
            exitCode: 0,
            output: "https://github.com/anomalyco/opencode/pull/42"
        )
        #expect(okExit != nil)

        // HomeMemoryPlugin includes skills guidance when project_overlay supplies a skills path
        let descWithSkills = CorePlugin.HomeMemoryPlugin.description("/mem", skills: "/overlay/skills")
        #expect(descWithSkills.contains("/overlay/skills"))
        let descWithoutSkills = CorePlugin.HomeMemoryPlugin.description("/mem", skills: nil)
        #expect(!descWithoutSkills.contains("SKILL.md"))

        // PluginGui Composer delivery/send & BuiltinDesktop dragOut
        let sentText = AtomicBox<String?>(nil)
        let composer = PluginGui.Composer(
            delivery: { .steer },
            send: { sentText.set($0) }
        )
        #expect(composer.delivery() == .steer)
        composer.send("go")
        #expect(sentText.get() == "go")

        let dragged = AtomicBox<[String]>([])
        let desktop = PluginGui.BuiltinDesktop(
            base: PluginGui.Desktop(),
            dragOut: { _, path in
                dragged.modify { $0.append(path) }
                return true
            }
        )
        #expect(desktop.dragOut(.object([:]), "/tmp/a.png") == true)
        #expect(dragged.get() == ["/tmp/a.png"])
    }
}
