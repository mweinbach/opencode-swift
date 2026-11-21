import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

@Suite("Code Mode Sync #2 Parity Tests (Diffs, scanProgram, Tool & Job Options)")
struct CodemodeSync2Tests {
    // MARK: - 1. CodeModeDiffs Unit Tests (`core/test/codemode/diffs.test.ts`)

    @Test("Two patches to one file are recorded as two changes in order with each diff")
    func diffsAroundOrder() async {
        let diffs = CoreCodemode.Diffs.make()
        let first = CoreTool.fileDiff(file: "src/app.ts", before: "one\ntwo\n", after: "one\nTWO\n")
        let second = CoreTool.fileDiff(file: "src/app.ts", before: "one\nTWO\n", after: "one\nTWO\nthree\n")

        _ = await CoreCodemode.Diffs.around(diffs, tool: "patch", input: .object([:])) {
            ToolSchema.Result(output: .object([:]), metadata: ["files": CodemodeTestHelper.encodeFileDiffs([first])])
        }
        _ = await CoreCodemode.Diffs.around(diffs, tool: "patch", input: .object([:])) {
            ToolSchema.Result(output: .object([:]), metadata: ["files": CodemodeTestHelper.encodeFileDiffs([second])])
        }

        #expect(diffs.files() == [
            CoreCodemode.Diffs.File(file: "src/app.ts", status: .modified, additions: 1, deletions: 1, patch: first.patch),
            CoreCodemode.Diffs.File(file: "src/app.ts", status: .modified, additions: 1, deletions: 0, patch: second.patch),
        ])
    }

    @Test("changes extracts diffs from edit/patch metadata, created/overwritten write output, and ignores non-file tools")
    func diffsChangesExtraction() {
        let edit = CoreTool.fileDiff(file: "a.ts", before: "a\n", after: "b\n")
        let editResult = ToolSchema.Result<JSONValue>(
            output: .object([:]),
            metadata: ["files": CodemodeTestHelper.encodeFileDiffs([edit])]
        )
        #expect(CoreCodemode.Diffs.changes(tool: "edit", input: .object([:]), result: editResult) == [
            CoreCodemode.Diffs.File(file: "a.ts", status: .modified, additions: 1, deletions: 1, patch: edit.patch),
        ])

        // Omitted status defaults to modified; invalid entries are skipped.
        let mixedPatch = ToolSchema.Result<JSONValue>(
            output: .object([:]),
            metadata: [
                "files": .array([
                    .object(["file": .string("m.ts"), "additions": .int(3)]),
                    .object(["file": .string("bad.ts"), "status": .string("renamed")]),
                    .string("junk"),
                ]),
            ]
        )
        #expect(CoreCodemode.Diffs.changes(tool: "patch", input: .object([:]), result: mixedPatch) == [
            CoreCodemode.Diffs.File(file: "m.ts", status: .modified, additions: 3),
        ])

        let created = CoreCodemode.Diffs.changes(
            tool: "write",
            input: .object(["path": .string("n.md"), "content": .string("# N\nx\n")]),
            result: ToolSchema.Result(output: .string("Created file successfully: n.md"))
        )
        #expect(created.count == 1)
        #expect(created.first?.file == "n.md")
        #expect(created.first?.status == .added)
        #expect(created.first?.additions == 2)
        #expect(created.first?.deletions == 0)
        #expect(created.first?.patch != nil)

        let overwritten = CoreCodemode.Diffs.changes(
            tool: "write",
            input: .object(["path": .string("n.md"), "content": .string("y\n")]),
            result: ToolSchema.Result(output: .string("Wrote file successfully: n.md"))
        )
        #expect(overwritten == [CoreCodemode.Diffs.File(file: "n.md", status: .modified)])

        #expect(CoreCodemode.Diffs.changes(tool: "read", input: .object(["path": .string("a.ts")]), result: editResult) == [])
    }

    @Test("written, appended, record, and no-op overwrite filtering work through Diffs.Service")
    func diffsServiceHelpers() async {
        let diffs = CoreCodemode.Diffs.make()
        let target = CoreFilesystem.FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/log.txt"),
            resource: "log.txt"
        )
        let preview = CoreTool.fileDiff(file: "log.txt", before: "", after: "one\n", status: .added)
        let noop = CoreTool.fileDiff(file: "same.txt", before: "a\n", after: "a\n", status: .modified)

        await CoreCodemode.Diffs.Service.$current.withValue(diffs) {
            await CoreCodemode.Diffs.written(target, status: .added, preview: preview)
            await CoreCodemode.Diffs.appended(target, status: .modified, text: "two\nthree\n")
            await CoreCodemode.Diffs.written(target, status: .modified, preview: nil)
            await CoreCodemode.Diffs.record(CoreCodemode.Diffs.File(file: "gone.txt", status: .deleted))
            // Overwrite with zero additions and zero deletions is ignored.
            await CoreCodemode.Diffs.written(target, status: .modified, preview: noop)
        }

        #expect(diffs.files() == [
            CoreCodemode.Diffs.File(file: "log.txt", status: .added, additions: 1, deletions: 0, patch: preview.patch),
            CoreCodemode.Diffs.File(file: "log.txt", status: .modified, additions: 2, deletions: 0),
            CoreCodemode.Diffs.File(file: "log.txt", status: .modified),
            CoreCodemode.Diffs.File(file: "gone.txt", status: .deleted),
        ])
    }

    @Test("Patch byte budget and file count cap apply as changes arrive")
    func diffsBudgetAndCap() {
        let diffs = CoreCodemode.Diffs.make()
        let big = String(repeating: "x", count: CoreCodemode.Diffs.MAX_PATCH_BYTES)
        diffs.record(CoreCodemode.Diffs.File(file: "small.txt", status: .added, additions: 1, deletions: 0, patch: "+a"))
        diffs.record(CoreCodemode.Diffs.File(file: "big.txt", status: .added, additions: 1, deletions: 0, patch: big))
        diffs.record(CoreCodemode.Diffs.File(file: "after.txt", status: .added, additions: 1, deletions: 0, patch: "+b"))

        let snapshot = diffs.files()
        #expect(snapshot.map(\.file) == ["small.txt", "big.txt", "after.txt"])
        #expect(snapshot.map { $0.patch != nil } == [true, false, true])
        #expect(snapshot[1].additions == 1)
        #expect(snapshot[1].deletions == 0)

        for idx in 0..<CoreCodemode.Diffs.MAX_FILES {
            diffs.record(CoreCodemode.Diffs.File(file: "f\(idx).txt", status: .deleted))
        }
        #expect(diffs.files().count == CoreCodemode.Diffs.MAX_FILES)
    }

    // MARK: - 2. Script Diffs Wiring in Tool.create & Bun Extension

    @Test("execute records changes from Bun.write, file.write, file.writer, file.delete, and inner file tools; namespaced tools record nothing")
    func executeRecordsDiffsFromToolsAndBun() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/notes.txt": CodemodeTestHelper.utf8Bytes("first\n"),
            "/workspace/gone.txt": CodemodeTestHelper.utf8Bytes("bye\n"),
        ])
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs
        )
        let inventory = CoreCodemode.Tool.Inventory(
            tools: [
                "write": CoreCodemode.Tool.ToolRegistration(
                    name: "write",
                    description: "Write file",
                    execute: { input, _ in
                        guard case .object(let obj) = input,
                              case .string(let path) = obj["path"]
                        else {
                            return ToolSchema.Result(output: .string(""))
                        }
                        let msg = path == "over.txt"
                            ? "Wrote file successfully: \(path)"
                            : "Created file successfully: \(path)"
                        return ToolSchema.Result(output: .string(msg), content: .text(msg))
                    }
                ),
                "edit": CoreCodemode.Tool.ToolRegistration(
                    name: "edit",
                    description: "Edit file",
                    execute: { _, _ in
                        let diff = CoreTool.fileDiff(file: "a.txt", before: "one\n", after: "two\n", status: .modified)
                        return ToolSchema.Result(
                            output: .string("Edited a.txt"),
                            metadata: ["files": CodemodeTestHelper.encodeFileDiffs([diff])]
                        )
                    }
                ),
                "notes_write": CoreCodemode.Tool.ToolRegistration(
                    name: "write",
                    description: "Namespaced write tool",
                    options: ToolSchema.Options(namespace: "notes"),
                    execute: { _, _ in
                        let diff = CoreTool.fileDiff(file: "ignored.md", before: "", after: "x\n", status: .added)
                        return ToolSchema.Result(
                            output: .string("Created file successfully: ignored.md"),
                            metadata: ["files": CodemodeTestHelper.encodeFileDiffs([diff])]
                        )
                    }
                ),
            ],
            namespaces: ["notes": ToolSchema.Namespace(name: "notes", description: "Notes")]
        )

        let tool = CoreCodemode.Tool.create(inventory: inventory, transport: transport, services: services)
        let progressCounts = Mutex<[Int]>([])
        let ctx = CodemodeTestHelper.makeToolContext { update in
            let count: Int
            if case .array(let files) = update["files"] { count = files.count } else { count = 0 }
            progressCounts.withLock { $0.append(count) }
        }

        let res = try await tool.execute(.init(code: """
        await tools.write({ path: "a.txt", content: "one\\n" });
        await tools.edit({ path: "a.txt" });
        await tools.write({ path: "over.txt", content: "two\\n" });
        await tools.notes.write({ path: "ignored.md", content: "x\\n" });
        await Bun.write("notes.txt", "second\\n");
        await Bun.write("notes.txt", "second\\n"); // no-op overwrite, ignored
        await Bun.write("copy.txt", Bun.file("notes.txt"));
        const sink = Bun.file("log.txt").writer();
        sink.write("line1\\n");
        await sink.flush();
        sink.write("line2\\nline3\\n");
        await sink.end();
        await Bun.file("gone.txt").delete();
        return "ok";
        """), ctx)

        #expect(res.metadata?["error"] == nil, "Script failed: \(res.output?.output ?? "")")
        guard case .array(let files) = res.metadata?["files"] else {
            Issue.record("Expected metadata.files array, got \(String(describing: res.metadata))")
            return
        }
        let summary: [(String, String, Int?, Bool)] = files.compactMap { entry in
            guard case .object(let obj) = entry,
                  case .string(let f) = obj["file"],
                  case .string(let s) = obj["status"]
            else { return nil }
            let adds: Int? = if case .int(let n) = obj["additions"] { Int(n) } else { nil }
            let hasPatch = obj["patch"] != nil
            return (f, s, adds, hasPatch)
        }
        try #require(summary.count == 8, "Unexpected files summary: \(summary)")
        #expect(summary[0] == ("a.txt", "added", 1, true))
        #expect(summary[1] == ("a.txt", "modified", 1, true))
        #expect(summary[2] == ("over.txt", "modified", nil, false))
        #expect(summary[3] == ("notes.txt", "modified", 1, true))
        #expect(summary[4] == ("copy.txt", "added", nil, false))
        #expect(summary[5] == ("log.txt", "added", 1, true))
        #expect(summary[6] == ("log.txt", "modified", 2, false))
        #expect(summary[7] == ("gone.txt", "deleted", nil, false))

        let counts = progressCounts.withLock { $0 }
        #expect(counts.contains(1))
        #expect(counts == counts.sorted())
        #expect(counts.last == 8)

        let logContent = CodemodeTestHelper.stringFromUTF8(try await fs.readFile(at: "/workspace/log.txt"))
        #expect(logContent == "line1\nline2\nline3\n")
        #expect(await fs.exists(at: "/workspace/gone.txt") == false)
    }

    @Test("Failed script preserves recorded file changes capped at MAX_FILES")
    func failedScriptKeepsDiffs() async throws {
        let fs = InMemoryFileSystem()
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs
        )
        let tool = CoreCodemode.Tool.create(inventory: .init(tools: [:]), transport: transport, services: services)
        let res = try await tool.execute(.init(code: """
        for (let i = 0; i < \(CoreCodemode.Diffs.MAX_FILES + 5); i++) {
          await Bun.write("f" + i + ".txt", "x\\n");
        }
        throw new Error("boom");
        """), CodemodeTestHelper.makeToolContext())

        #expect(res.metadata?["error"] == .bool(true))
        guard case .array(let files) = res.metadata?["files"] else {
            Issue.record("Expected metadata.files on failed script")
            return
        }
        #expect(files.count == CoreCodemode.Diffs.MAX_FILES)
    }

    @Test("Real WriteTool, EditTool, and PatchTool called inside execute record exact diffs in metadata.files")
    func realFileToolsScriptDiffs() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/old.txt": CodemodeTestHelper.utf8Bytes("keep\n"),
        ])
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let flags = CoreFlag.Service(config: CoreConfig.Test(), overrides: "full_codemode")
        let permission = CorePermission.Service()
        var env = CoreTool.BuiltinEnvironment(
            directory: "/workspace",
            fileSystem: fs,
            permission: permission,
            httpTransport: transport,
            flags: flags
        )
        env.fullCodeMode = true
        let registry = CoreTool.Service(codeMode: CoreTool.CodeModeHost(
            transport: transport,
            permission: .allowAll,
            flags: flags
        ))
        let capturedEnv = env
        _ = await registry.transform { editor in
            CoreTool.WriteTool.Plugin.register(editor, capturedEnv)
            CoreTool.EditTool.Plugin.register(editor, capturedEnv)
            CoreTool.PatchTool.Plugin.register(editor, capturedEnv)
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs
        )
        let allowAllRules: PermissionSchema.Ruleset = [
            PermissionSchema.Rule(action: "*", resource: "*", effect: .allow),
        ]
        let snapshot = await registry.snapshot(
            permissions: allowAllRules,
            options: CoreTool.SnapshotOptions(services: services)
        )
        let result = try await CorePermission.Unattended.$current.withValue(allowAllRules) {
            try await snapshot.execute(CoreTool.ExecuteCallInput(
                sessionID: SessionID.create(),
                agent: AgentSchema.ID(rawValue: "build"),
                messageID: "msg_script_diffs",
                callID: ToolSchema.CallID(rawValue: "call_script_diffs"),
                name: "execute",
                input: .object([
                    "code": .string("""
                    await tools.write({ path: "a.txt", content: "one\\n" });
                    await tools.edit({ path: "a.txt", oldString: "one", newString: "two" });
                    await tools.patch({ patchText: "*** Begin Patch\\n*** Add File: b.txt\\n+b\\n*** Delete File: old.txt\\n*** End Patch" });
                    await tools.write({ path: "a.txt", content: "three\\n" });
                    return [];
                    """),
                ])
            ))
        }

        guard case .array(let files) = result.metadata?["files"] else {
            Issue.record("Expected metadata.files from real file tools, got \(String(describing: result.metadata))")
            return
        }
        let summary: [(String, String, Int?, Int?, Bool)] = files.compactMap { entry in
            guard case .object(let obj) = entry,
                  case .string(let f) = obj["file"],
                  case .string(let s) = obj["status"]
            else { return nil }
            let adds: Int? = if case .int(let n) = obj["additions"] { Int(n) } else { nil }
            let dels: Int? = if case .int(let n) = obj["deletions"] { Int(n) } else { nil }
            return (f, s, adds, dels, obj["patch"] != nil)
        }
        #expect(summary.count == 5)
        #expect(summary[0] == ("a.txt", "added", 1, 0, true))
        #expect(summary[1] == ("a.txt", "modified", 1, 1, true))
        #expect(summary[2] == ("b.txt", "added", 1, 0, true))
        #expect(summary[3] == ("old.txt", "deleted", 0, 1, true))
        #expect(summary[4] == ("a.txt", "modified", nil, nil, false))
    }

    // MARK: - 3. FullInput, Tool.find, Job.Options, Job.make & Registry Wiring

    @Test("FullInput validates positive integer timeout and execute exposes full schema/description only when full_codemode services are provided")
    func fullInputAndExecuteSchema() throws {
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: InMemoryFileSystem()
        )

        let plain = CoreCodemode.Tool.create(inventory: .init(tools: [:]), transport: transport)
        #expect(!plain.description.contains("background"))
        if case .jsonSchema(let schema) = plain.input, case .object(let props) = schema["properties"] {
            #expect(Set(props.keys) == ["code"])
        } else {
            Issue.record("Expected plain JSON schema")
        }

        let full = CoreCodemode.Tool.create(inventory: .init(tools: [:]), transport: transport, services: services)
        #expect(full.description.contains("do not poll"))
        if case .jsonSchema(let schema) = full.input, case .object(let props) = schema["properties"] {
            #expect(Set(props.keys) == ["code", "timeout", "background"])
        } else {
            Issue.record("Expected full JSON schema")
        }

        let valid = try CodemodeTestHelper.decodeFullInput(json: #"{"code":"1","timeout":3000,"background":true}"#)
        #expect(valid.code == "1")
        #expect(valid.timeout == 3000)
        #expect(valid.background == true)

        #expect(throws: (any Error).self) {
            _ = try CodemodeTestHelper.decodeFullInput(json: #"{"code":"1","timeout":0}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try CodemodeTestHelper.decodeFullInput(json: #"{"code":"1","timeout":-10}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try CodemodeTestHelper.decodeFullInput(json: #"{"code":"1","timeout":1.5}"#)
        }
    }

    @Test("CoreCodemode.Tool.find resolves tools by registry ID or qualified call path")
    func toolFindLookup() {
        let searchReg = CoreCodemode.Tool.ToolRegistration(
            name: "search",
            description: "Search sessions",
            options: ToolSchema.Options(namespace: "opencode.session"),
            execute: { _, _ in ToolSchema.Result(output: .null) }
        )
        let inventory = CoreCodemode.Tool.Inventory(tools: ["opencode_session_search": searchReg])

        let byID = CoreCodemode.Tool.find(inventory, name: "opencode_session_search")
        #expect(byID?.id == "opencode_session_search")
        #expect(byID?.registration.name == "search")

        let byQualified = CoreCodemode.Tool.find(inventory, name: "opencode.session.search")
        #expect(byQualified?.id == "opencode_session_search")
        #expect(byQualified?.registration.name == "search")

        #expect(CoreCodemode.Tool.find(inventory, name: "missing") == nil)
    }

    @Test("CoreCodemode.Job.make honors background: true, per-call timeout, and keeps background scripts running past timeout")
    func jobOptionsBehavior() async throws {
        let notices = Mutex<[CoreCodemode.Job.Notice]>([])
        let runFn = CoreCodemode.Job.make(fullCodemode: true, blockTimeoutMs: 5_000) { notice in
            notices.withLock { $0.append(notice) }
        }
        let ctx = CodemodeTestHelper.makeToolContext()

        // 1. background: true returns immediately even with tiny timeout, and script still finishes and notifies.
        let bg = try await runFn(ctx, options: .init(timeout: 5, background: true)) { _ in
            await CodemodeTestHelper.sleepMs(80)
            return ToolSchema.Result(output: .string("bg done"), content: .text("bg done"))
        }
        guard case .string(let bgJobID) = bg.metadata?["jobID"] else {
            Issue.record("Expected jobID for background run")
            return
        }
        #expect(bgJobID.hasPrefix("cm_"))
        for _ in 0..<100 where notices.withLock({ $0.count }) < 1 {
            await CodemodeTestHelper.sleepMs(15)
        }
        #expect(notices.withLock { $0.first?.metadata["jobID"] } == .string(bgJobID))
        #expect(notices.withLock { $0.first?.metadata["state"] } == .string("completed"))
        #expect(notices.withLock { $0.first?.text.contains("bg done") } == true)

        // 2. Per-call timeout overrides default blockTimeoutMs and detaches to background.
        let fgTimeout = try await runFn(ctx, options: .init(timeout: 25)) { _ in
            await CodemodeTestHelper.sleepMs(120)
            return ToolSchema.Result(output: .string("after timeout"), content: .text("after timeout"))
        }
        guard case .string(let fgJobID) = fgTimeout.metadata?["jobID"] else {
            Issue.record("Expected jobID when per-call timeout expires")
            return
        }
        for _ in 0..<100 where notices.withLock({ $0.count }) < 2 {
            await CodemodeTestHelper.sleepMs(15)
        }
        #expect(notices.withLock { $0.last?.metadata["jobID"] } == .string(fgJobID))
        #expect(notices.withLock { $0.last?.text.contains("after timeout") } == true)

        // 3. Script finishing within per-call timeout returns directly without jobID.
        let fast = try await runFn(ctx, options: .init(timeout: 2_000)) { _ in
            await CodemodeTestHelper.sleepMs(10)
            return ToolSchema.Result(output: .string("fast"), content: .text("fast"))
        }
        #expect(fast.metadata?["jobID"] == nil)
        #expect(fast.output == .string("fast"))
    }

    @Test("CoreTool.Service snapshot routes execute timeout/background through CoreCodemode.Job.Current when full_codemode is enabled")
    func registryRoutesJobOptions() async throws {
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let flags = CoreFlag.Service(config: CoreConfig.Test(), overrides: "full_codemode")
        let registry = CoreTool.Service(codeMode: CoreTool.CodeModeHost(transport: transport, flags: flags))
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: InMemoryFileSystem()
        )
        let snapshot = await registry.snapshot(permissions: [], options: CoreTool.SnapshotOptions(services: services))

        let observedOptions = Mutex<CoreCodemode.Job.Options?>(nil)
        let runner = CoreCodemode.Job.Runner { ctx, opts, exec in
            observedOptions.withLock { $0 = opts }
            return try await exec(ctx)
        }
        let result = try await CoreCodemode.Job.Current.$run.withValue(runner) {
            try await snapshot.execute(CoreTool.ExecuteCallInput(
                sessionID: SessionID.create(),
                agent: AgentSchema.ID(rawValue: "build"),
                messageID: "msg_reg",
                callID: ToolSchema.CallID(rawValue: "call_reg"),
                name: "execute",
                input: .object(["code": .string("return 42"), "timeout": .int(1500), "background": .bool(true)])
            ))
        }
        #expect(observedOptions.withLock { $0 } == CoreCodemode.Job.Options(timeout: 1500, background: true))
        if case .object(let out) = result.output {
            #expect(out["output"] == .string("42"))
        } else {
            Issue.record("Expected execute object output")
        }
    }

    // MARK: - 4. CoreCodemode.Tool.check with Extensions

    @Test("CoreCodemode.Tool.check supports fetch, path, and Bun extensions when services are supplied")
    func toolCheckWithExtensions() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/fixture.txt": CodemodeTestHelper.utf8Bytes("hello check"),
        ])
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "ready")
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs
        )
        let res = try await CoreCodemode.Tool.check(
            inventory: .init(tools: [:]),
            code: """
            const file = Bun.file(path.resolve("fixture.txt"));
            const body = await (await fetch(url)).text();
            return { text: await file.text(), body };
            """,
            bindings: ["url": .string("https://example.test/ping")],
            context: CodemodeTestHelper.makeToolContext(),
            permission: .allowAll,
            services: services,
            transport: transport
        ) { _, _, _ in
            ToolSchema.Result(output: .null)
        }

        guard case .success(let ok) = res else {
            Issue.record("Expected check success, got \(res)")
            return
        }
        #expect(ok.value == .object(["text": .string("hello check"), "body": .string("ready")]))
    }

    @Test("Bun.Glob scan/scanSync authorize read permission instead of glob")
    func bunGlobUsesReadPermission() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/keep.txt": CodemodeTestHelper.utf8Bytes("keep"),
        ])
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let actions = Mutex<[String]>([])
        let permission = CoreCodemode.PermissionHook(
            assertAllowed: { req in
                actions.withLock { $0.append(req.action) }
                if req.action == "glob" {
                    throw CoreCodemode.PermissionRejectedError(message: "Permission denied: glob")
                }
            }
        )
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs,
            permission: permission
        )
        let tool = CoreCodemode.Tool.create(inventory: .init(tools: [:]), transport: transport, permission: permission, services: services)
        let res = try await tool.execute(.init(code: #"return new Bun.Glob("*.txt").scanSync()"#), CodemodeTestHelper.makeToolContext())
        #expect(res.metadata?["error"] == nil)
        #expect(res.output?.output == #"["keep.txt"]"#)
        #expect(actions.withLock { $0 } == ["read"])
    }

    // MARK: - 5. CodemodeEngine.scanProgram (`codemode/src/codemode/scan.ts`)

    @Test("scanProgram tracks static tools, global member uses, forwarding members, local bindings, and literal modules")
    func scanProgramComprehensive() throws {
        let scanned = try CodemodeEngine.scanProgram("""
        import p from "node:path";
        const fs = require("fs");
        const direct = await Bun.file("a.txt").slice(0, 5).text();
        const f = Bun.file("b.txt");
        function readLater() { return f.slice(1).json(); }
        await f.bytes();
        const writable = await Bun.file("c.txt");
        await writable.slice(0, 2).delete();
        const escaped = Bun.file("d.txt");
        const copy = escaped;
        await Bun.write("e.txt", "hi");
        const files = await new Bun.Glob("*.txt").scan();
        const res = await fetch("https://example.test/");
        const r = await tools.slack.read_thread({ ts: await tools.slack.latest_ts({}) });
        return { direct, copy, files, res, r, p, fs, readLater };
        """, globals: ["fetch", "Bun"], forwardingMembers: ["slice"]).get()

        #expect(scanned.tools == ["slack.read_thread", "slack.latest_ts"])
        #expect(scanned.modules == Set(["path", "fs"]))

        let fetchUses = scanned.globals["fetch"] ?? []
        #expect(fetchUses == [CodemodeEngine.GlobalUse(member: nil, resultMembers: [nil])])

        let bunUses = scanned.globals["Bun"] ?? []
        #expect(bunUses == [
            CodemodeEngine.GlobalUse(member: "file", resultMembers: ["text"]),
            CodemodeEngine.GlobalUse(member: "file", resultMembers: ["json", "bytes"]),
            CodemodeEngine.GlobalUse(member: "file", resultMembers: ["delete"]),
            CodemodeEngine.GlobalUse(member: "file", resultMembers: [nil]),
            CodemodeEngine.GlobalUse(member: "write", resultMembers: []),
            CodemodeEngine.GlobalUse(member: "Glob", resultMembers: [nil]),
        ])

        // Re-export matches scanProgram directly.
        let reexported = try CodemodeEngine.scanCodeModeProgram(
            "await Bun.file('x').text(); await fetch('https://a.test');",
            ["fetch", "Bun"],
            ["slice"]
        ).get()
        #expect(reexported.globals["Bun"] == [CodemodeEngine.GlobalUse(member: "file", resultMembers: ["text"])])
        #expect(reexported.globals["fetch"] == [CodemodeEngine.GlobalUse(member: nil, resultMembers: [nil])])
    }

    @Test("scanProgram ignores shadowed globals (including nested var and imports) and rejects dynamic/aliased tools")
    func scanProgramShadowingAndRejections() throws {
        let shadowed = try CodemodeEngine.scanProgram("""
        import Bun from "custom-bun";
        {
          var fetch = () => "local";
          fetch("x");
        }
        function helper(tools) { return tools[k](); }
        Bun.write("a", "b");
        return helper({});
        """, globals: ["fetch", "Bun"], forwardingMembers: ["slice"]).get()

        #expect(shadowed.tools.isEmpty)
        #expect(shadowed.globals.isEmpty)
        #expect(shadowed.modules == Set(["custom-bun"]))

        // Rejects loading tools via import/require or dynamic specifier.
        for bad in [
            #"import t from "tools";"#,
            #"const t = require("node:tools");"#,
            #"const t = await import("tools");"#,
            #"const t = require(name);"#,
            #"const t = await import(name);"#,
            #"tools = 1;"#,
            #"const x = tools.a.b;"#,
            #"await tools.a[k]();"#,
        ] {
            if case .success(let ok) = CodemodeEngine.scanProgram(bad, globals: ["Bun"]) {
                Issue.record("Expected failure for `\(bad)`, got \(ok)")
            }
        }
    }
}
