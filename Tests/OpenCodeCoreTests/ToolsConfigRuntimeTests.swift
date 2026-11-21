import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - 1. Built-In Tool Suite & Output Truncation Tests

@Suite("CoreTool Built-ins & Registry")
struct CoreToolBuiltinsTests {
    private func makeTestHarness(
        files: [String: [UInt8]] = [:],
        directory: String = "/workspace",
        permission: (any CorePermission.Interface)? = nil,
        httpTransport: (any HTTPTransport)? = nil,
        spawner: (any ProcessSpawner)? = nil,
        artifactEnabled: Bool = false
    ) async -> (
        fs: InMemoryFileSystem,
        registry: CoreTool.Service,
        env: CoreTool.BuiltinEnvironment,
        snapshot: CoreTool.Snapshot
    ) {
        let fs = InMemoryFileSystem(initialFiles: files)
        try? await fs.makeDirectory(at: directory, recursive: true)
        let globalPaths = Global.Interface(
            home: "/home/tester",
            data: "/data",
            cache: "/cache",
            config: "/config",
            state: "/state",
            tmp: "/tmp",
            bin: "/cache/bin",
            log: "/data/log",
            repos: "/data/repos"
        )
        let perm = permission ?? CorePermission.Service()
        let flags = CoreFlag.Service(
            config: CoreConfig.Test(),
            channel: "release",
            overrides: artifactEnabled ? "artifacts" : nil
        )
        let artifactSvc = CoreArtifact.Service(
            directory: directory,
            projectID: ProjectID(rawValue: "proj_test"),
            globalPaths: globalPaths,
            fileSystem: fs,
            flags: flags
        )
        let processes: any AppProcess.Interface = spawner.map { AppProcess.Service(spawner: $0) } ?? AppProcess.Service()
        let env = CoreTool.BuiltinEnvironment(
            directory: directory,
            fileSystem: fs,
            permission: perm,
            httpTransport: httpTransport,
            artifact: artifactSvc,
            flags: flags,
            globalPaths: globalPaths,
            processes: processes
        )
        let registry = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: registry, environment: env)
        let snapshot = await registry.snapshot()
        return (fs, registry, env, snapshot)
    }

    private func call(
        _ snapshot: CoreTool.Snapshot,
        name: String,
        input: JSONValue,
        sessionID: SessionID = SessionID(rawValue: "ses_tools_001")!
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

    @Test("read tool reads text lines, paginates offset/limit, handles negative tail, directories, media, and binary rejection")
    func readToolFullBehavior() async throws {
        let sampleText = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let harness = await makeTestHarness(files: [
            "/workspace/notes.txt": ToolsConfigRuntimeHelper.utf8Bytes(sampleText),
            "/workspace/src/app.swift": ToolsConfigRuntimeHelper.utf8Bytes("let x = 1\n"),
            "/workspace/photo.png": ToolsConfigRuntimeHelper.samplePNGBytes(),
            "/workspace/bin.dat": [0x01, 0x00, 0x02, 0x03],
        ])

        // 1. Paginated text read (offset 3, limit 3)
        let page = try await call(harness.snapshot, name: "read", input: .object([
            "path": .string("notes.txt"),
            "offset": .int(3),
            "limit": .int(3),
        ]))
        let pageText = ToolsConfigRuntimeHelper.firstText(from: page)
        #expect(pageText.contains("Read file notes.txt, lines 3-5"))
        #expect(pageText.contains("3: line 3"))
        #expect(pageText.contains("5: line 5"))
        #expect(pageText.contains("Continue reading with offset: 6"))
        #expect(page.metadata?["truncated"] == .bool(true))

        // 2. Negative offset reads last N lines
        let tail = try await call(harness.snapshot, name: "read", input: .object([
            "path": .string("notes.txt"),
            "offset": .int(-2),
        ]))
        let tailText = ToolsConfigRuntimeHelper.firstText(from: tail)
        #expect(tailText.contains("9: line 9"))
        #expect(tailText.contains("10: line 10"))

        // 3. Directory listing (directories first with trailing slash)
        let dir = try await call(harness.snapshot, name: "read", input: .object([
            "path": .string("."),
        ]))
        let dirText = ToolsConfigRuntimeHelper.firstText(from: dir)
        #expect(dirText.contains("src/"))
        #expect(dirText.contains("notes.txt"))

        // 4. PNG image returns inline base64 file content part
        let media = try await call(harness.snapshot, name: "read", input: .object([
            "path": .string("photo.png"),
        ]))
        #expect(media.content.count == 2)
        if case .file(let fc) = media.content[1] {
            #expect(fc.mime == "image/png")
            #expect(fc.uri.hasPrefix("data:image/png;base64,"))
        } else {
            Issue.record("Expected file content part for PNG")
        }

        // 5. Binary file fails with BinaryFileError message
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(harness.snapshot, name: "read", input: .object([
                "path": .string("bin.dat"),
            ]))
        }

        // 6. Missing file offers "Did you mean" suggestion
        do {
            _ = try await call(harness.snapshot, name: "read", input: .object([
                "path": .string("note.txt"),
            ]))
            Issue.record("Expected failure for missing file")
        } catch let err as AISchema.ToolFailure {
            #expect(err.message.contains("File not found"))
            #expect(err.message.contains("notes.txt"))
        }
    }

    @Test("write tool creates parent directories and preserves existing UTF-8 BOM")
    func writeToolCreatesAndPreservesBom() async throws {
        let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF] + ToolsConfigRuntimeHelper.utf8Bytes("old\n")
        let harness = await makeTestHarness(files: [
            "/workspace/bom.txt": bomBytes,
        ])

        let created = try await call(harness.snapshot, name: "write", input: .object([
            "path": .string("nested/deep/file.swift"),
            "content": .string("print(\"hello\")\n"),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: created).contains("Created file successfully"))
        let saved = try await harness.fs.readFile(at: "/workspace/nested/deep/file.swift")
        #expect(ToolsConfigRuntimeHelper.utf8String(saved) == "print(\"hello\")\n")

        let overwritten = try await call(harness.snapshot, name: "write", input: .object([
            "path": .string("bom.txt"),
            "content": .string("updated\n"),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: overwritten).contains("Wrote file successfully"))
        let afterBom = try await harness.fs.readFile(at: "/workspace/bom.txt")
        #expect(Bom.has(afterBom))
        #expect(Bom.decodeBytes(afterBom).text == "updated\n")
    }

    @Test("edit tool handles exact, smart-quote normalized, trailing-whitespace, CRLF, and replaceAll edits")
    func editToolVariants() async throws {
        let initial = "let greeting = \"hello\"\r\nlet a = 1  \r\nlet b = a + a\r\n"
        let harness = await makeTestHarness(files: [
            "/workspace/code.swift": ToolsConfigRuntimeHelper.utf8Bytes(initial),
        ])

        // 1. Typographic smart quotes normalized match + CRLF preserved
        _ = try await call(harness.snapshot, name: "edit", input: .object([
            "path": .string("code.swift"),
            "oldString": .string("let greeting = \u{201C}hello\u{201D}"),
            "newString": .string("let greeting = \"world\""),
        ]))
        let afterSmart = ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/code.swift"))
        #expect(afterSmart.contains("let greeting = \"world\"\r\n"))

        // 2. Trailing whitespace line retry (newline forces line-trimmed matching when source has trailing spaces)
        _ = try await call(harness.snapshot, name: "edit", input: .object([
            "path": .string("code.swift"),
            "oldString": .string("let a = 1\n"),
            "newString": .string("let a = 42\n"),
        ]))
        let afterTrim = ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/code.swift"))
        #expect(afterTrim.contains("let a = 42\r\n"))

        // 3. Multiple matches rejected unless replaceAll = true
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(harness.snapshot, name: "edit", input: .object([
                "path": .string("code.swift"),
                "oldString": .string("a"),
                "newString": .string("x"),
            ]))
        }

        _ = try await call(harness.snapshot, name: "edit", input: .object([
            "path": .string("code.swift"),
            "oldString": .string("let "),
            "newString": .string("var "),
            "replaceAll": .bool(true),
        ]))
        let afterAll = ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/code.swift"))
        #expect(!afterAll.contains("let "))
        #expect(afterAll.contains("var greeting = \"world\""))
    }

    @Test("patch tool applies add, update, move, and delete hunks using OpenCodeUtil.Patch")
    func patchToolMultiFileOperations() async throws {
        let harness = await makeTestHarness(files: [
            "/workspace/modify.txt": ToolsConfigRuntimeHelper.utf8Bytes("alpha\nbeta\ngamma\n"),
            "/workspace/oldname.txt": ToolsConfigRuntimeHelper.utf8Bytes("before\n"),
            "/workspace/remove.txt": ToolsConfigRuntimeHelper.utf8Bytes("bye\n"),
        ])

        let patchText = """
        *** Begin Patch
        *** Add File: created.txt
        +hello from patch
        *** Update File: modify.txt
        @@
         alpha
        -beta
        +BETA
         gamma
        *** Update File: oldname.txt
        *** Move to: newname.txt
        @@
        -before
        +after move
        *** Delete File: remove.txt
        *** End Patch
        """

        let res = try await call(harness.snapshot, name: "patch", input: .object([
            "patchText": .string(patchText),
        ]))
        let text = ToolsConfigRuntimeHelper.firstText(from: res)
        #expect(text.contains("A created.txt"))
        #expect(text.contains("M modify.txt"))
        #expect(text.contains("M newname.txt"))
        #expect(text.contains("D remove.txt"))

        #expect(ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/created.txt")) == "hello from patch\n")
        #expect(ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/modify.txt")) == "alpha\nBETA\ngamma\n")
        #expect(await harness.fs.exists(at: "/workspace/oldname.txt") == false)
        #expect(ToolsConfigRuntimeHelper.utf8String(try await harness.fs.readFile(at: "/workspace/newname.txt")) == "after move\n")
        #expect(await harness.fs.exists(at: "/workspace/remove.txt") == false)
    }

    @Test("glob and grep tools work against InMemoryFileSystem and real temporary directories")
    func globAndGrepToolsInMemoryAndTempDir() async throws {
        let harness = await makeTestHarness(files: [
            "/workspace/Sources/Alpha.swift": ToolsConfigRuntimeHelper.utf8Bytes("struct Alpha {\n    let token = \"SECRET_42\"\n}\n"),
            "/workspace/Sources/Beta.swift": ToolsConfigRuntimeHelper.utf8Bytes("struct Beta {\n    let token = \"secret_99\"\n}\n"),
            "/workspace/.hidden/secret.swift": ToolsConfigRuntimeHelper.utf8Bytes("let hidden = true\n"),
            "/workspace/README.md": ToolsConfigRuntimeHelper.utf8Bytes("# Docs\n"),
        ])

        // Glob excluding hidden files
        let globRes = try await call(harness.snapshot, name: "glob", input: .object([
            "pattern": .string("**/*.swift"),
        ]))
        let globText = ToolsConfigRuntimeHelper.firstText(from: globRes)
        #expect(globText.contains("Alpha.swift"))
        #expect(globText.contains("Beta.swift"))
        #expect(!globText.contains("secret.swift"))

        // Glob including hidden files with limit truncation
        let globHidden = try await call(harness.snapshot, name: "glob", input: .object([
            "pattern": .string("**/*.swift"),
            "hidden": .bool(true),
            "limit": .int(2),
        ]))
        #expect(globHidden.metadata?["truncated"] == .bool(true))
        #expect(ToolsConfigRuntimeHelper.firstText(from: globHidden).contains("Results are truncated"))

        // Grep case-insensitive regex with include filter
        let grepRes = try await call(harness.snapshot, name: "grep", input: .object([
            "pattern": .string("secret_[0-9]+"),
            "include": .string("*.swift"),
            "caseSensitive": .bool(false),
        ]))
        let grepText = ToolsConfigRuntimeHelper.firstText(from: grepRes)
        #expect(grepText.contains("Found 2 matches"))
        #expect(grepText.contains("SECRET_42"))
        #expect(grepText.contains("secret_99"))

        // Real temp directory read/write/glob/grep round-trip
        let tmpDir = try ToolsConfigRuntimeHelper.makeTempDirectory(prefix: "opencode-tools")
        defer { ToolsConfigRuntimeHelper.removeTempDirectory(tmpDir) }
        let localEnv = CoreTool.BuiltinEnvironment(
            directory: tmpDir,
            fileSystem: LocalFileSystem.shared
        )
        let localReg = CoreTool.Service()
        _ = await CoreTool.registerAllBuiltins(into: localReg, environment: localEnv)
        let localSnap = await localReg.snapshot()

        _ = try await call(localSnap, name: "write", input: .object([
            "path": .string("pkg/hello.swift"),
            "content": .string("public func greet() -> String { \"hi\" }\n"),
        ]))
        let diskGlob = try await call(localSnap, name: "glob", input: .object([
            "pattern": .string("**/*.swift"),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: diskGlob).contains("pkg/hello.swift"))
        let diskGrep = try await call(localSnap, name: "grep", input: .object([
            "pattern": .string("func greet"),
            "literal": .bool(true),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: diskGrep).contains("Found 1 matches"))
    }

    @Test("webfetch converts HTML to markdown/text, validates URLs, and checks redirect permissions")
    func webfetchToolBehavior() async throws {
        let mockHTTP = ToolsConfigRuntimeHelper.MockHTTPTransport { req in
            if req.url == "https://example.com/start" {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 302, headers: ["Location": "https://example.com/final"]),
                    body: []
                )
            }
            let html = """
            <html><head><title>Skip</title><script>evil()</script></head>
            <body><h1>Title</h1><p>Hello <strong>World</strong> and <a href="https://opencode.ai">OpenCode</a>.</p></body></html>
            """
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"]),
                body: ToolsConfigRuntimeHelper.utf8Bytes(html)
            )
        }
        let harness = await makeTestHarness(httpTransport: mockHTTP)

        let mdRes = try await call(harness.snapshot, name: "webfetch", input: .object([
            "url": .string("https://example.com/start#frag"),
            "format": .string("markdown"),
        ]))
        let md = ToolsConfigRuntimeHelper.firstText(from: mdRes)
        #expect(md.contains("# Title"))
        #expect(md.contains("**World**"))
        #expect(md.contains("[OpenCode](https://opencode.ai)"))
        #expect(!md.contains("evil()"))
        #expect(mockHTTP.requests().count == 2)

        let txtRes = try await call(harness.snapshot, name: "webfetch", input: .object([
            "url": .string("https://example.com/final"),
            "format": .string("text"),
        ]))
        let plain = ToolsConfigRuntimeHelper.firstText(from: txtRes)
        #expect(plain.contains("Title"))
        #expect(plain.contains("Hello World"))
        #expect(!plain.contains("evil()"))

        // Rejects credentialed URLs
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(harness.snapshot, name: "webfetch", input: .object([
                "url": .string("https://user:pass@example.com/secret"),
            ]))
        }
    }

    @Test("tool output truncation saves full output, respects UTF-8 grapheme boundaries, and cleans up expired files")
    func toolOutputTruncationAndRetention() async throws {
        let fs = InMemoryFileSystem(initialClockMs: 1_700_000_000_000)
        let global = Global.Interface(
            home: "/h", data: "/data", cache: "/c", config: "/cfg", state: "/st",
            tmp: "/tmp", bin: "/c/bin", log: "/data/log", repos: "/data/repos"
        )
        let outputSvc = CoreToolOutput.Service(
            globalPaths: global,
            fileSystem: fs,
            limits: CoreToolOutput.Limits(maxLines: 3, maxBytes: 1024),
            nowMs: { fs.currentClockMs() }
        )

        // Small output is not truncated
        let small = await outputSvc.truncate(CoreToolOutput.NormalizedResult(
            content: [.text(ToolSchema.TextContent(text: "line1\nline2\n"))]
        ))
        #expect(small.metadata?["truncated"] == .bool(false))

        // Over line limit saves full output and appends marker
        let bigText = (1...10).map { "row-\($0) 😀" }.joined(separator: "\n")
        let truncated = await outputSvc.truncate(CoreToolOutput.NormalizedResult(
            content: [.text(ToolSchema.TextContent(text: bigText))]
        ))
        #expect(truncated.metadata?["truncated"] == .bool(true))
        guard case .string(let savedPath) = truncated.metadata?["outputPath"] else {
            Issue.record("Expected outputPath in truncated metadata")
            return
        }
        let diskFull = ToolsConfigRuntimeHelper.utf8String(try await fs.readFile(at: savedPath))
        #expect(diskFull == bigText)
        let combined = ToolsConfigRuntimeHelper.allText(from: truncated)
        #expect(combined.contains("[showing lines 1-3 of 10"))
        #expect(combined.contains(savedPath))

        // Byte-budget truncation never splits multi-byte emoji
        let byteSvc = CoreToolOutput.Service(
            globalPaths: global,
            fileSystem: fs,
            limits: CoreToolOutput.Limits(maxLines: 100, maxBytes: 6)
        )
        let emojiTrunc = await byteSvc.truncate(CoreToolOutput.NormalizedResult(
            content: [.text(ToolSchema.TextContent(text: "ab😀cd"))]
        ))
        #expect(emojiTrunc.metadata?["truncated"] == .bool(true))
        if case .text(let first) = emojiTrunc.content[0] {
            #expect(first.text == "ab😀")
        } else {
            Issue.record("Expected text part")
        }

        // Advance clock past 7-day retention and verify cleanup removes expired file
        fs.setClockMs(1_700_000_000_000 + CoreToolOutput.RETENTION + 1_000)
        await outputSvc.cleanup()
        #expect(await fs.exists(at: savedPath) == false)
    }

    @Test("todo, question, subagent, artifact tools, MCP bridge, and registry permission filtering")
    func registryExtrasAndMcpBridge() async throws {
        let harness = await makeTestHarness(artifactEnabled: true)

        // Todo summary
        let todoRes = try await call(harness.snapshot, name: "todowrite", input: .object([
            "todos": .array([
                .object(["content": .string("Port core"), "status": .string("completed")]),
                .object(["content": .string("Run tests"), "status": .string("in_progress")]),
            ]),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: todoRes).contains("1/2 completed, 1 in progress"))

        // Artifact CRUD via opencode_artifact_* tools
        let artCreate = try await call(harness.snapshot, name: "opencode_artifact_create", input: .object([
            "title": .string("Demo Page"),
            "files": .object(["index.html": .string("<h1>Hi</h1>")]),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: artCreate).contains("Published Demo Page"))
        guard case .object(let artObj) = artCreate.output, case .string(let artID) = artObj["id"] else {
            Issue.record("Expected artifact ID in tool output")
            return
        }
        let artRead = try await call(harness.snapshot, name: "opencode_artifact_read", input: .object([
            "id": .string(artID),
        ]))
        #expect(ToolsConfigRuntimeHelper.firstText(from: artRead).contains("Demo Page"))

        // Wholly denied tool disappears from snapshot definitions
        let restrictedSnap = await harness.registry.snapshot(permissions: [
            PermissionSchema.Rule(action: "shell", resource: "*", effect: .deny),
        ])
        #expect(!restrictedSnap.definitions.contains(where: { $0.name == "shell" }))
        #expect(restrictedSnap.definitions.contains(where: { $0.name == "read" }))

        // MCP tool bridge namespaces & executes tools
        let mcpBridge = ToolsConfigRuntimeHelper.MockMcpBridge(
            descriptors: [
                CoreTool.Mcp.ToolDescriptor(server: "my.server", name: "fetch-item", description: "Fetches item"),
            ],
            callHandler: { _, _, _, _ in
                CoreTool.Mcp.ToolCallResult(content: [.text("{\"ok\":true}")])
            }
        )
        let mcpSvc = CoreTool.Mcp.Service(
            toolsRegistry: harness.registry,
            permission: harness.env.permission,
            toolOutput: harness.env.toolOutput,
            client: mcpBridge
        )
        await mcpSvc.flush()
        let mcpSnap = await harness.registry.snapshot()
        let mcpRes = try await call(mcpSnap, name: "my_server_fetch-item", input: .object([:]))
        #expect(mcpRes.output == .object(["ok": .bool(true)]))
    }

    @Test("shell built-in tool, registry overrides/disposal, namespaces, and CodeMode check")
    func shellToolAndRegistryLifecycle() async throws {
        let spawner = ToolsConfigRuntimeHelper.MockProcessSpawner { spec in
            ProcessOutput(
                exitCode: 0,
                stdout: ToolsConfigRuntimeHelper.utf8Bytes("ran:\(spec.arguments.last ?? "")\n"),
                stderr: []
            )
        }
        let harness = await makeTestHarness(spawner: spawner)

        // Foreground shell execution via built-in shell tool
        let shellRes = try await call(harness.snapshot, name: "shell", input: .object([
            "command": .string("echo hi"),
            "description": .string("Print greeting"),
        ]))
        let shellText = ToolsConfigRuntimeHelper.firstText(from: shellRes)
        #expect(shellText.contains("ran:echo hi"))

        // Opaque shell command substitution rejected
        await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await call(harness.snapshot, name: "shell", input: .object([
                "command": .string("echo $(id)"),
            ]))
        }

        // Tool registry override, update, disposal restoring earlier definition, namespace, and CodeMode check
        let reg = CoreTool.Service()
        _ = await reg.transform { editor in
            editor.namespace(ToolSchema.Namespace(name: "custom", description: "Custom tools"))
            editor.add(CoreTool.RegisteredTool(
                name: "ping",
                description: "v1",
                outputSchema: ["type": .string("string")],
                options: ToolSchema.Options(namespace: "custom", codemode: true)
            ) { _, _ in
                ToolSchema.Result(output: .string("v1"), content: .text("v1"))
            })
        }
        let overrideHandle = await reg.transform { editor in
            editor.update("custom_ping") { tool in
                tool.description = "v2"
                tool.execute = { _, _ in
                    ToolSchema.Result(output: .string("v2"), content: .text("v2"))
                }
            }
        }
        let snapV2 = await reg.snapshot()
        let v2Res = try await call(snapV2, name: "custom_ping", input: .object([:]))
        #expect(v2Res.output == .string("v2"))

        // CodeMode check lists visible codemode tools and honors execute deny rule
        let ctx = ToolsConfigRuntimeHelper.makeToolContext()
        let okCheck = await reg.check(CoreTool.CheckInput(code: "", tools: ["custom_ping"], context: ctx))
        #expect(okCheck.ok == true)
        #expect(okCheck.availableTools == ["custom_ping"])
        let deniedCheck = await reg.check(CoreTool.CheckInput(
            code: "",
            tools: ["custom_ping"],
            permissions: [PermissionSchema.Rule(action: "execute", resource: "*", effect: .deny)],
            context: ctx
        ))
        #expect(deniedCheck.ok == false)

        // Disposing override transform and reloading restores v1
        overrideHandle.dispose()
        await reg.reload()
        let snapV1 = await reg.snapshot()
        let v1Res = try await call(snapV1, name: "custom_ping", input: .object([:]))
        #expect(v1Res.output == .string("v1"))
    }
}

// MARK: - 2. Permission Engine & Persisted SQLite Approvals Tests

@Suite("CorePermission Engine & Persistence")
struct CorePermissionTests {
    @Test("wildcard matching supports *, ?, trailing ' *' optional args, backslash normalization, and case rules")
    func wildcardAndEvaluateRules() {
        #expect(CorePermissionWildcard.match("git status", pattern: "git *"))
        #expect(CorePermissionWildcard.match("git", pattern: "git *"))
        #expect(!CorePermissionWildcard.match("gitx", pattern: "git *"))
        #expect(CorePermissionWildcard.match("src\\a\\b.ts", pattern: "src/*/b.??"))
        #expect(CorePermissionWildcard.match("**/*.swift", pattern: "*"))

        let rules: PermissionSchema.Ruleset = [
            PermissionSchema.Rule(action: "*", resource: "*", effect: .ask),
            PermissionSchema.Rule(action: "read", resource: "*.env", effect: .deny),
            PermissionSchema.Rule(action: "read", resource: "safe.env", effect: .allow),
        ]
        #expect(CorePermission.evaluate(action: "read", resource: ".env", rules).effect == .deny)
        #expect(CorePermission.evaluate(action: "read", resource: "safe.env", rules).effect == .allow)
        #expect(CorePermission.evaluate(action: "shell", resource: "ls", rules).effect == .ask)
        #expect(CorePermission.ignoresCase("read", platform: .macOS) == true)
        #expect(CorePermission.ignoresCase("shell", platform: .macOS) == false)
        #expect(CorePermission.ignoresCase("read", platform: .linux) == false)
    }

    @Test("interactive assert/reply persists 'always' approvals to SQLite and auto-approves matching pending asks")
    func interactiveReplyAndSQLitePersistence() async throws {
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let saved = try CorePermissionSaved.Service(database: db)
        let projectID = ProjectID(rawValue: "proj_perm_1")
        let sessionID = SessionID(rawValue: "ses_perm_1")!

        let engine = CorePermission.Service(
            projectID: projectID,
            saved: saved,
            configuredRules: { _, _ in
                [PermissionSchema.Rule(action: "shell", resource: "*", effect: .ask)]
            }
        )

        let assertTask1 = Task {
            try await engine.assert(CorePermission.AssertInput(
                sessionID: sessionID,
                action: "shell",
                resources: ["git status"],
                save: ["git *"],
                source: .tool(messageID: "m1", id: "c1")
            ))
        }
        let assertTask2 = Task {
            try await engine.assert(CorePermission.AssertInput(
                sessionID: sessionID,
                action: "shell",
                resources: ["git diff"],
                save: ["git *"],
                source: .tool(messageID: "m1", id: "c2")
            ))
        }

        // Wait until both asks are pending
        var pending: [PermissionSchema.Request] = []
        for _ in 0..<50 {
            pending = await engine.forSession(sessionID)
            if pending.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pending.count == 2)

        // Approving first with .always persists `git *` and auto-resolves the second pending request!
        try await engine.reply(CorePermission.ReplyInput(requestID: pending[0].id, reply: .always))
        try await assertTask1.value
        try await assertTask2.value
        #expect(await engine.list().isEmpty)

        // Persisted approval is in SQLite and allows future matching commands immediately
        let persisted = try await saved.list(CorePermissionSaved.ListInput(projectID: projectID))
        #expect(persisted.count == 1)
        #expect(persisted[0].action == "shell")
        #expect(persisted[0].resource == "git *")
        #expect(try await engine.allows(CorePermission.AssertInput(
            sessionID: sessionID,
            action: "shell",
            resources: ["git log"]
        )) == true)

        // Duplicate update throws ConflictError
        try await saved.add(CorePermissionSaved.AddInput(projectID: projectID, action: "shell", resources: ["npm *"]))
        let allSaved = try await saved.list(CorePermissionSaved.ListInput(projectID: projectID))
        #expect(allSaved.count == 2)
        let npmItem = try #require(allSaved.first(where: { $0.resource == "npm *" }))
        await #expect(throws: CorePermissionSaved.ConflictError.self) {
            _ = try await saved.update(CorePermissionSaved.UpdateInput(id: npmItem.id, resource: "git *"))
        }
    }

    @Test("reject with feedback throws CorrectedError and unattended rules settle ask decisions")
    func rejectAndUnattendedBehavior() async throws {
        let sessionID = SessionID(rawValue: "ses_perm_2")!
        let engine = CorePermission.Service(
            configuredRules: { _, _ in
                [PermissionSchema.Rule(action: "edit", resource: "*", effect: .ask)]
            }
        )

        // Unattended ruleset denies ask when not explicitly allowed
        await CorePermission.Unattended.$current.withValue([]) {
            await #expect(throws: CorePermission.BlockedError.self) {
                try await engine.assert(CorePermission.AssertInput(
                    sessionID: sessionID,
                    action: "edit",
                    resources: ["a.swift"]
                ))
            }
        }
        // Unattended ruleset allows matching ask
        try await CorePermission.Unattended.$current.withValue([
            PermissionSchema.Rule(action: "edit", resource: "*.swift", effect: .allow),
        ]) {
            try await engine.assert(CorePermission.AssertInput(
                sessionID: sessionID,
                action: "edit",
                resources: ["a.swift"]
            ))
        }

        // Reject with feedback raises CorrectedError
        let task = Task {
            try await engine.assert(CorePermission.AssertInput(
                sessionID: sessionID,
                action: "edit",
                resources: ["b.swift"],
                source: .tool(messageID: "m2", id: "c3")
            ))
        }
        var reqs: [PermissionSchema.Request] = []
        for _ in 0..<50 {
            reqs = await engine.list()
            if !reqs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await engine.reply(CorePermission.ReplyInput(
            requestID: reqs[0].id,
            reply: .reject,
            message: "Use patch instead"
        ))
        do {
            try await task.value
            Issue.record("Expected CorrectedError")
        } catch let err as CorePermission.CorrectedError {
            #expect(err.feedback == "Use patch instead")
        }
    }
}

// MARK: - 3. JSONC Config Loader, Feature Flags, Markdown & Managed Policy Tests

@Suite("CoreConfig, CoreFlag & CoreManagedPolicy")
struct CoreConfigFlagPolicyTests {
    @Test("JSONC strips comments and trailing commas while preserving strings")
    func jsoncParsing() throws {
        let jsonc = """
        {
          // line comment with "quotes"
          "username": "alice // not a comment",
          /* block
             comment */
          "snapshots": true,
          "instructions": [
            "a.md",
            "b.md",
          ],
        }
        """
        let (info, diagnostics) = try CoreConfigJSONC.parseInfo(jsonc)
        #expect(diagnostics.isEmpty)
        #expect(info.username == "alice // not a comment")
        #expect(info.snapshots == true)
        #expect(info.instructions == ["a.md", "b.md"])
    }

    @Test("variable substitution expands {env:VAR} and {file:path}, skips comment lines, and escapes broken JSON")
    func variableSubstitution() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/project/secret.txt": ToolsConfigRuntimeHelper.utf8Bytes("top-secret-token\n"),
        ])
        let env = DictionaryEnvironment(variables: ["API_PATH": "C:\\Users\\Alice"])
        let inputText = """
        {
          // {file:missing.txt}
          "username": "{file:secret.txt}",
          "shell": "{env:API_PATH}"
        }
        """
        let out = await CoreConfigVariable.substitute(
            CoreConfigVariable.SubstituteInput(
                source: .path("/project/opencode.jsonc"),
                text: inputText,
                environment: env
            ),
            fileSystem: fs
        )
        #expect(out.references.contains("/project/secret.txt"))
        let (info, _) = try CoreConfigJSONC.parseInfo(out.text)
        #expect(info.username == "top-secret-token")
        #expect(info.shell == "C:\\Users\\Alice")
    }

    @Test("config normalization migrates V1 fields and reports conflict/unsupported diagnostics")
    func configNormalization() throws {
        let legacyJSON = """
        {
          "logLevel": "debug",
          "snapshot": false,
          "autoupdate": "notify",
          "update": "auto",
          "autoshare": true,
          "tools": { "bash": false },
          "enabled_providers": ["anthropic"],
          "compaction": { "preserve_recent_tokens": 4000, "reserved": "10%" }
        }
        """
        let raw = try CoreConfigJSONC.parse(legacyJSON)
        let result = CoreConfigNormalize.normalize(raw)
        guard case .normalized(let encoded, let diagnostics) = result else {
            Issue.record("Expected normalized config")
            return
        }
        #expect(encoded["snapshots"] == .bool(false))
        #expect(encoded["update"] == .string("auto"))
        #expect(encoded["share"] == .string("auto"))
        #expect(diagnostics.contains(where: { $0.kind == .unsupported && $0.path == ["logLevel"] }))
        #expect(diagnostics.contains(where: { $0.kind == .conflict && $0.path == ["update"] }))
    }

    @Test("hierarchical config loader merges system, global, project, and inline content in exact priority order")
    func hierarchicalConfigMerge() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/etc/opencode/opencode.jsonc": ToolsConfigRuntimeHelper.utf8Bytes("""
            {
              "username": "managed-user",
              "policies": [{ "action": "tool.use", "resource": "shell:rm *", "effect": "deny" }]
            }
            """),
            "/home/u/.config/opencode/opencode.json": ToolsConfigRuntimeHelper.utf8Bytes("""
            { "username": "global-user", "shell": "/bin/zsh", "snapshots": false }
            """),
            "/repo/opencode.jsonc": ToolsConfigRuntimeHelper.utf8Bytes("""
            { "shell": "/bin/bash", "snapshots": true, }
            """),
        ])
        let globalPaths = Global.Interface(
            home: "/home/u", data: "/home/u/.local/share/opencode", cache: "/home/u/.cache/opencode",
            config: "/home/u/.config/opencode", state: "/home/u/.local/state/opencode",
            tmp: "/tmp/opencode", bin: "/home/u/.cache/opencode/bin", log: "/log", repos: "/repos"
        )
        let service = await CoreConfig.Service(
            directory: "/repo",
            options: CoreConfig.Options(system: .custom("/etc/opencode"), content: "{\"timezone\":\"UTC\"}"),
            globalPaths: globalPaths,
            fileSystem: fs,
            platform: .linux
        )
        let entries = await service.entries()
        // Managed settings load last and override global/project username
        #expect(CoreConfig.latest(entries, \.username) == "managed-user")
        // Project overrides global shell and snapshots
        #expect(CoreConfig.latest(entries, \.shell) == "/bin/bash")
        #expect(CoreConfig.latest(entries, \.snapshots) == true)
        #expect(CoreConfig.latest(entries, \.timezone) == "UTC")
        // Managed policies load earliest so they win in CoreManagedPolicy
        let policyStatements = CoreManagedPolicy.statements(entries)
        #expect(CoreManagedPolicy.decision(policyStatements, action: .toolUse, resource: "shell:rm -rf /") == .deny)
    }

    @Test("feature flag precedence: OPENCODE_FLAGS > experimental.<key> > all_flags > channel default, respecting optInOnly")
    func featureFlagPrecedence() {
        let doc1 = CoreConfigEntry.document(ConfigSchema.Document(
            info: ConfigSchema.Info(experimental: ConfigExperimentalSchema.Info(allFlags: true, mediaBlob: false))
        ))
        let doc2 = CoreConfigEntry.document(ConfigSchema.Document(
            info: ConfigSchema.Info(experimental: ConfigExperimentalSchema.Info(machines: false))
        ))

        // 1. Release channel: all_flags turns on non-optInOnly flags, latest experimental doc overrides machines, optInOnly stays off
        let r1 = CoreFlag.resolve(CoreFlag.ResolveInput(entries: [doc1, doc2], channel: "release", overrides: nil))
        #expect(r1[.artifacts] == CoreFlag.State(enabled: true, source: .config))
        #expect(r1[.machines] == CoreFlag.State(enabled: false, source: .config))
        #expect(r1[.todo] == CoreFlag.State(enabled: false, source: .default))
        #expect(r1[.sqliteFts] == CoreFlag.State(enabled: true, source: .config))
        #expect(r1[.projectOverlay] == CoreFlag.State(enabled: true, source: .config))
        #expect(r1[.fullCodemode] == CoreFlag.State(enabled: true, source: .config))

        // 2. OPENCODE_FLAGS=all,-media_blob,todo overrides everything; optInOnly requires explicit key
        let r2 = CoreFlag.resolve(CoreFlag.ResolveInput(entries: [doc1], channel: "release", overrides: "all,-media_blob,todo"))
        #expect(r2[.artifacts] == CoreFlag.State(enabled: true, source: .env))
        #expect(r2[.mediaBlob] == CoreFlag.State(enabled: false, source: .env))
        #expect(r2[.todo] == CoreFlag.State(enabled: true, source: .env))
        #expect(r2[.sqliteFts] == CoreFlag.State(enabled: true, source: .env))
        #expect(r2[.fullCodemode] == CoreFlag.State(enabled: true, source: .env))

        // 3. Local channel enables regular flags (including sqlite_fts & project_overlay) by default, keeps optInOnly off
        let r4 = CoreFlag.resolve(CoreFlag.ResolveInput(entries: [], channel: "local", overrides: nil))
        #expect(r4[.artifacts] == CoreFlag.State(enabled: true, source: .default))
        #expect(r4[.fullCodemode] == CoreFlag.State(enabled: true, source: .default))
        #expect(r4[.sqliteFts] == CoreFlag.State(enabled: true, source: .default))
        #expect(r4[.todo] == CoreFlag.State(enabled: false, source: .default))
    }

    @Test("markdown frontmatter sanitization, skill file parsing, and managed policy org messages")
    func markdownSkillAndManagedPolicy() throws {
        let tricky = """
        ---
        name: My Skill
        description: [Tag] Handles foo: bar cleanly
        disable-model-invocation: true
        ---
        # Instructions
        Do the work.
        """
        let parsedSkill = CoreConfigPlugin.SkillFile.parse(
            directory: "/skills",
            filepath: "/skills/my-skill/SKILL.md",
            content: tricky
        )
        guard case .parsed(let skill) = parsedSkill else {
            Issue.record("Expected skill to parse after sanitization")
            return
        }
        #expect(skill.id.rawValue == "my-skill")
        #expect(skill.name.rawValue == "My Skill")
        #expect(skill.autoinvoke == false)
        #expect(skill.content.contains("# Instructions"))

        // Integration document policy gets organization-branded message & strips local credentials
        let remote = CoreConfigIntegration.Remote(
            providers: [
                "openai": ConfigProviderSchema.Info(
                    name: "OpenAI",
                    env: ["OPENAI_API_KEY"],
                    settings: ProviderSchema.Settings(extra: ["apiKey": .string("leak"), "region": .string("us")])
                ),
            ],
            mcp: ConfigMCPSchema.Info(servers: [
                "bad-local": .local(McpSchema.LocalConfig(command: ["sh"])),
                "good-remote": .remote(McpSchema.RemoteConfig(url: "https://mcp.example.com")),
            ]),
            policies: [
                ConfigPolicySchema.Info(action: .providerUse, resource: "blocked-*", effect: .deny),
            ]
        )
        let doc = CoreConfigIntegration.make(CoreConfigIntegration.MakeInput(
            integrationID: IntegrationID(rawValue: "console"),
            connection: .env(ConnectionSchema.EnvInfo(name: "K")),
            organization: "Acme Corp",
            info: remote
        ))
        #expect(doc.info.providers?["openai"]?.env == nil)
        #expect(doc.info.providers?["openai"]?.settings?.extra["apiKey"] == nil)
        #expect(doc.info.providers?["openai"]?.settings?.extra["region"] == JSONValue.string("us"))
        #expect(doc.info.mcp?.servers?["bad-local"] == nil)
        #expect(doc.info.mcp?.servers?["good-remote"] != nil)

        let stmts = CoreManagedPolicy.statements([.integration(doc)])
        let matched = CoreManagedPolicy.match(stmts, action: .providerUse, resource: "blocked-model")
        #expect(matched?.effect == .deny)
        #expect(matched?.message == "Blocked by Acme Corp's policy")
        #expect(CoreManagedPolicy.integrationResource("console", account: "org_1") == "console#org_1")
        #expect(CoreManagedPolicy.integrationResource("console", account: nil) == "console")
    }

    @Test("config plugins: SkillScan, EntryObserver, and plugin Source add/remove/relative resolution")
    func configPluginsAndSkillScan() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/skills/root-guide.md": ToolsConfigRuntimeHelper.utf8Bytes("# Root"),
            "/skills/alpha/SKILL.md": ToolsConfigRuntimeHelper.utf8Bytes("# Alpha"),
            "/skills/alpha/nested.md": ToolsConfigRuntimeHelper.utf8Bytes("# Ignored when SKILL.md present"),
            "/skills/.hidden/SKILL.md": ToolsConfigRuntimeHelper.utf8Bytes("# Hidden"),
            "/skills/node_modules/pkg/SKILL.md": ToolsConfigRuntimeHelper.utf8Bytes("# Ignored"),
        ])
        let scanned = await CoreConfigPlugin.SkillScan.scan(root: "/skills", fileSystem: fs)
        #expect(scanned == ["/skills/alpha/SKILL.md", "/skills/root-guide.md"])

        let dirEntry = CoreConfigEntry.directory(ConfigSchema.Directory(
            path: SchemaPrimitive.AbsolutePath(rawValue: "/repo/.opencode")
        ))
        #expect(CoreConfigPlugin.EntryObserver.isDirectorySource(
            entries: [dirEntry],
            file: "/repo/.opencode/skills/my/SKILL.md",
            names: ["skills"]
        ) == true)
        #expect(CoreConfigPlugin.EntryObserver.isDirectorySource(
            entries: [dirEntry],
            file: "/repo/other/file.md",
            names: ["skills"]
        ) == false)

        let pluginConfig = CoreConfig.Test(initial: [
            .document(ConfigSchema.Document(
                path: SchemaPrimitive.AbsolutePath(rawValue: "/repo/opencode.jsonc"),
                info: ConfigSchema.Info(plugins: [
                    .specifier("./local-plugin.ts"),
                    .specifier("-disabled-plugin"),
                    .entry(ConfigPluginSchema.Entry(package: "acme-plugin", options: ["debug": .bool(true)])),
                ])
            )),
        ])
        let sourceSvc = CoreConfigPlugin.Source.Service(config: pluginConfig, directory: "/repo")
        let ops = await sourceSvc.operations()
        #expect(ops == [
            .add(target: "/repo/local-plugin.ts", options: [:]),
            .remove(target: "disabled-plugin"),
            .add(target: "acme-plugin", options: ["debug": .bool(true)]),
        ])
    }
}

// MARK: - 4. Runtime Tests: MIME, Filesystem, Ripgrep, Formatter, Shell, PTY, Blob, Artifact, Snapshot

@Suite("CoreRuntime: Filesystem, Shell, PTY, Blob, Artifact & Snapshot")
struct CoreRuntimeTests {
    @Test("MIME detection identifies PNG, JPEG, PDF, WebP, AVIF, text, and binary accurately")
    func mimeDetection() {
        #expect(CoreFilesystem.Mime.detectMedia(ToolsConfigRuntimeHelper.samplePNGBytes()) == "image/png")
        #expect(CoreFilesystem.Mime.detectMedia(ToolsConfigRuntimeHelper.sampleJPEGBytes()) == "image/jpeg")
        #expect(CoreFilesystem.Mime.detectMedia(ToolsConfigRuntimeHelper.samplePDFBytes()) == "application/pdf")
        #expect(CoreFilesystem.Mime.detectMedia(ToolsConfigRuntimeHelper.sampleWebPBytes()) == "image/webp")
        #expect(CoreFilesystem.Mime.detectMedia(ToolsConfigRuntimeHelper.sampleAVIFBytes()) == "image/avif")
        #expect(CoreFilesystem.Mime.detect(ToolsConfigRuntimeHelper.utf8Bytes("hello utf8")) == "text/plain")
        #expect(CoreFilesystem.Mime.detect([0x00, 0xFF, 0x10]) == "application/octet-stream")
        #expect(CoreFilesystem.Mime.isTextual("application/vnd.api+json"))
        #expect(!CoreFilesystem.Mime.isTextual("image/png"))
    }

    @Test("Ripgrep binary SHA-256 verification and built-in formatter registry")
    func ripgrepVerifyAndFormatters() async throws {
        let bytes = ToolsConfigRuntimeHelper.utf8Bytes("ripgrep-archive")
        let expected = Hash.sha256(bytes)
        try CoreRipgrep.Binary.verify(bytes, filename: "rg.tar.gz", expected: expected)
        #expect(throws: CoreRipgrep.RipgrepError.self) {
            try CoreRipgrep.Binary.verify(bytes, filename: "rg.tar.gz", expected: "0000")
        }

        let fs = InMemoryFileSystem(initialFiles: [
            "/bin/gofmt": ToolsConfigRuntimeHelper.utf8Bytes("#!/bin/sh\n"),
            "/repo/main.go": ToolsConfigRuntimeHelper.utf8Bytes("package main\n"),
        ])
        let spawner = ToolsConfigRuntimeHelper.MockProcessSpawner { _ in
            ProcessOutput(exitCode: 0, stdout: [], stderr: [])
        }
        let builtins = CoreFormatter.make(CoreFormatter.MakeInput(
            directory: "/repo",
            worktree: "/repo",
            fileSystem: fs,
            processes: AppProcess.Service(spawner: spawner),
            bin: "/bin",
            environment: DictionaryEnvironment(variables: ["PATH": "/bin"])
        ))
        #expect(builtins.count == 26)
        let formatterSvc = CoreFormatter.Service(directory: "/repo", processes: AppProcess.Service(spawner: spawner))
        _ = await formatterSvc.transform { editor in
            for item in builtins { editor.set(item) }
        }
        let didFormat = await formatterSvc.file("/repo/main.go")
        #expect(didFormat == true)
        #expect(spawner.specs().first?.executable == "/bin/gofmt")
    }

    @Test("Shell parser, selector, service execution, and output cursor pagination")
    func shellParsingAndExecution() async throws {
        // Parse commands & cd directories
        let parsed = try CoreShell.Parse.scan(
            command: "cd ../other && git status --short && npm run test",
            shell: "/bin/zsh",
            cwd: "/workspace/sub"
        )
        #expect(parsed.directories == ["/workspace/other"])
        #expect(parsed.commands.count == 3)
        #expect(parsed.commands[1].save == "git status *")
        #expect(parsed.commands[2].save == "npm run test")

        // Opaque command substitution rejected
        #expect(throws: AppProcess.AppProcessError.self) {
            _ = try CoreShell.Parse.scan(command: "echo $(whoami)", shell: "/bin/sh", cwd: "/workspace")
        }

        // ShellSelect args formatting
        #expect(CoreShell.Select.args("/bin/zsh", command: "echo *") == ["+o", "nomatch", "-c", "echo *"])
        #expect(CoreShell.Select.args("pwsh", command: "ls") == ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "ls"])
        #expect(CoreShell.Select.login("/bin/bash") == true)

        // Shell service runs command via mock ProcessSpawner and paginates file-backed output
        let fs = InMemoryFileSystem()
        let spawner = ToolsConfigRuntimeHelper.MockProcessSpawner { _ in
            ProcessOutput(exitCode: 0, stdout: ToolsConfigRuntimeHelper.utf8Bytes("hello world\n"), stderr: [])
        }
        let global = Global.Interface(
            home: "/h", data: "/data", cache: "/c", config: "/cfg", state: "/st",
            tmp: "/tmp", bin: "/c/bin", log: "/log", repos: "/repos"
        )
        let shellSvc = CoreShell.Service(
            directory: "/workspace",
            globalPaths: global,
            fileSystem: fs,
            processes: AppProcess.Service(spawner: spawner)
        )
        let info = try await shellSvc.create(CoreShell.CreateRequest(command: "echo hello", shell: "/bin/sh"))
        let done = try await shellSvc.wait(info.id)
        #expect(done.status == .exited)
        #expect(done.exit == 0)

        let chunk1 = try await shellSvc.output(info.id, input: ShellSchema.OutputInput(
            cursor: .zero,
            limit: SchemaPrimitive.NonNegativeInt(rawValue: 5)
        ))
        #expect(chunk1.output == "hello")
        #expect(chunk1.truncated == true)
        let chunk2 = try await shellSvc.output(info.id, input: ShellSchema.OutputInput(
            cursor: chunk1.cursor,
            limit: SchemaPrimitive.NonNegativeInt(rawValue: 100)
        ))
        #expect(chunk2.output == " world\n")
        #expect(chunk2.truncated == false)
    }

    @Test("PTY wire protocol, one-time tickets, live PTY sessions, and persistent PTY/pipe daemon integration")
    func ptyAndPersistentPtySessions() async throws {
        // WireProtocol
        let frame = CorePty.WireProtocol.metaFrame(cursor: 42)
        #expect(frame.first == 0)
        #expect(ToolsConfigRuntimeHelper.utf8String(Array(frame.dropFirst())) == "{\"cursor\":42}")
        #expect(CorePty.WireProtocol.decodeInput([0xFF, 0xFE]) == nil)
        #expect(CorePty.WireProtocol.decodeInput(ToolsConfigRuntimeHelper.utf8Bytes("abc")) == "abc")

        // One-time connect ticket with TTL and scope matching
        let clock = ToolsConfigRuntimeHelper.Box<Int64>(1_000_000)
        let tickets = CorePty.Ticket.make(ttlMs: 5_000, nowMs: { clock.get() })
        let ptyID = PtySchema.ID.create()
        let scope = CorePty.Ticket.Scope(target: .pty(ptyID), directory: "/repo")
        let token = await tickets.issue(scope)
        // Wrong scope fails without consuming? Wait: scope mismatch returns false
        #expect(await tickets.consume(ticket: token.ticket, scope: CorePty.Ticket.Scope(target: .pty(ptyID), directory: "/other")) == false)
        // Exact scope succeeds once and cannot be reused
        #expect(await tickets.consume(ticket: token.ticket, scope: scope) == true)
        #expect(await tickets.consume(ticket: token.ticket, scope: scope) == false)
        // Expired ticket fails
        let token2 = await tickets.issue(scope)
        clock.update { $0 += 10_000 }
        #expect(await tickets.consume(ticket: token2.ticket, scope: scope) == false)

        // Location-scoped PTY service (simulated echo backend)
        let ptySvc = CorePty.Service(directory: "/repo", backend: .simulated(onWrite: nil))
        let created = try await ptySvc.create(PtySchema.CreateInput(command: "/bin/sh", title: "Dev Shell"))
        #expect(created.status == .running)
        let received = ToolsConfigRuntimeHelper.Box<String>("")
        let att = try await ptySvc.attach(created.id, input: CorePty.AttachInput(
            onData: { chunk in received.update { $0 += chunk } },
            onEnd: { _ in }
        ))
        att.activate()
        try await ptySvc.write(created.id, data: "echo ok\n")
        #expect(received.get().contains("echo ok"))
        let renamed = try await ptySvc.update(created.id, input: PtySchema.UpdateInput(title: "Renamed"))
        #expect(renamed.title == "Renamed")
        att.detach()
        try await ptySvc.remove(created.id)
        #expect(await ptySvc.list().isEmpty)

        // Persistent PTY service backed by ProcessDaemon.TerminalService
        let persistent = CorePty.Persistent.Service(backend: .simulated(onWrite: nil))
        let sid = SessionID(rawValue: "ses_pty_001")!
        let pInfo = try await persistent.create(sessionID: sid, input: CorePty.Persistent.CreateTerminalInput(
            command: "/bin/sh",
            cwd: "/repo",
            title: "Build",
            cols: 80,
            rows: 24
        ))
        try await persistent.write(pInfo.id, data: "hello persistent\r\n")
        let snap = try await persistent.snapshot(pInfo.id)
        #expect(snap.text.contains("hello persistent"))
        let screen = try await persistent.read(sessionID: sid, lines: nil)
        #expect(screen?.screen.text.contains("hello persistent") == true)

        let handoff = try await persistent.handoff()
        #expect(handoff != nil)
        #expect(persistent.handoffPrepared() == true)
        try await persistent.remove(pInfo.id)
        try await persistent.shutdown()
        #expect(persistent.handoffPrepared() == false)
    }

    @Test("Blob store, Artifact store, and Snapshot capture/diff/restore work end-to-end")
    func blobArtifactAndSnapshotStores() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/repo/a.txt": ToolsConfigRuntimeHelper.utf8Bytes("line1\nline2\n"),
            "/repo/b.txt": ToolsConfigRuntimeHelper.utf8Bytes("stay\n"),
        ])
        let global = Global.Interface(
            home: "/h", data: "/data", cache: "/c", config: "/cfg", state: "/st",
            tmp: "/tmp", bin: "/c/bin", log: "/log", repos: "/repos"
        )

        // 1. BlobStore
        let blobs = CoreBlobStore.Service(globalPaths: global, fileSystem: fs)
        let png = ToolsConfigRuntimeHelper.samplePNGBytes()
        let blobInfo = try await blobs.write(png)
        #expect(blobInfo.mime == "image/png")
        #expect(Int(blobInfo.bytes) == png.count)
        let loadedBlob = try await blobs.read(blobInfo.id)
        #expect(loadedBlob.mime == "image/png")
        await blobs.remove(blobInfo.id)
        await #expect(throws: CoreBlobStore.NotFoundError.self) {
            _ = try await blobs.read(blobInfo.id)
        }

        // 2. Artifact store (flag disabled vs enabled + CRUD + locate + traversal guard)
        let disabledFlags = CoreFlag.Service(config: CoreConfig.Test(), channel: "release", overrides: nil)
        let disabledArtifacts = CoreArtifact.Service(directory: "/repo", globalPaths: global, fileSystem: fs, flags: disabledFlags)
        await #expect(throws: CoreArtifact.DisabledError.self) {
            _ = try await disabledArtifacts.providers()
        }

        let kv = CoreArtifact.InMemoryKVStore()
        let enabledFlags = CoreFlag.Service(config: CoreConfig.Test(), channel: "release", overrides: "artifacts")
        let artifacts = CoreArtifact.Service(
            directory: "/repo",
            projectID: ProjectID(rawValue: "proj_art"),
            globalPaths: global,
            fileSystem: fs,
            flags: enabledFlags,
            kv: kv
        )
        let art = try await artifacts.create(ArtifactSchema.CreateInput(
            title: "Chart",
            files: ["index.html": "<html>ok</html>", "app.js": "console.log(1)"]
        ))
        #expect(art.entry == "index.html")
        #expect(await CoreArtifact.locate(kv: kv, id: art.id) == "/repo")
        let localFile = try await artifacts.readLocalFile(art.id, subpath: "index.html")
        #expect(ToolsConfigRuntimeHelper.utf8String(localFile.bytes) == "<html>ok</html>")
        #expect(localFile.mime.contains("text/html"))

        // Traversal path rejected
        await #expect(throws: CoreArtifact.InvalidError.self) {
            _ = try await artifacts.create(ArtifactSchema.CreateInput(
                title: "Bad",
                files: ["../escape.txt": "nope"]
            ))
        }

        // 3. Snapshot capture, files, diff, and selective restore
        let snapshots = CoreSnapshot.Service(directory: "/repo", fileSystem: fs)
        let s1 = try #require(await snapshots.capture())
        try await fs.writeFile(ToolsConfigRuntimeHelper.utf8Bytes("line1\nLINE2\n"), to: "/repo/a.txt", createDirectories: true)
        try await fs.writeFile(ToolsConfigRuntimeHelper.utf8Bytes("new file\n"), to: "/repo/c.txt", createDirectories: true)
        let s2 = try #require(await snapshots.capture())

        let changed = try await snapshots.files(CoreSnapshot.CompareInput(from: s1, to: s2))
        #expect(changed.map(\.rawValue) == ["a.txt", "c.txt"])

        let diffs = try await snapshots.diff(CoreSnapshot.DiffInput(from: s1, to: s2))
        #expect(diffs.count == 2)
        #expect(diffs.first(where: { $0.file == "a.txt" })?.status == .modified)
        #expect(diffs.first(where: { $0.file == "c.txt" })?.status == .added)

        // Restore a.txt and c.txt back to s1 (a.txt reverted, c.txt deleted)
        try await snapshots.restore(CoreSnapshot.RestoreInput(files: [
            SchemaPrimitive.RelativePath(rawValue: "a.txt"): s1,
            SchemaPrimitive.RelativePath(rawValue: "c.txt"): s1,
        ]))
        #expect(ToolsConfigRuntimeHelper.utf8String(try await fs.readFile(at: "/repo/a.txt")) == "line1\nline2\n")
        #expect(await fs.exists(at: "/repo/c.txt") == false)
    }

    @Test("Filesystem protected home checks, retention cleanup, watcher policy, fuzzy search, and persistent pipe processes")
    func filesystemExtrasAndPersistentPipes() async throws {
        // Protected home helpers
        #expect(CoreFilesystem.Protected.isHome("/Users/alice", home: "/Users/alice") == true)
        #expect(CoreFilesystem.Protected.isHome("/Users/alice/repo", home: "/Users/alice") == false)
        #expect(CoreFilesystem.Protected.names(platform: .macOS).contains("Library"))
        #expect(CoreFilesystem.Protected.names(platform: .windows).contains("AppData"))
        #expect(CoreFilesystem.Protected.names(platform: .linux).isEmpty)

        // FileRetention cleanup removes only files older than retention threshold
        let fs = InMemoryFileSystem(
            initialFiles: [
                "/tmp/old.log": ToolsConfigRuntimeHelper.utf8Bytes("old"),
                "/tmp/fresh.log": ToolsConfigRuntimeHelper.utf8Bytes("fresh"),
                "/repo/Sources/App.swift": ToolsConfigRuntimeHelper.utf8Bytes("struct App {}\n"),
                "/repo/Sources/Router.swift": ToolsConfigRuntimeHelper.utf8Bytes("struct Router {}\n"),
            ],
            initialClockMs: 1_000_000
        )
        fs.setClockMs(2_000_000)
        try await fs.writeFile(ToolsConfigRuntimeHelper.utf8Bytes("fresh2"), to: "/tmp/fresh.log", createDirectories: true)
        await CoreFilesystem.FileRetention.cleanup(
            fileSystem: fs,
            files: ["/tmp/old.log", "/tmp/fresh.log"],
            retentionMs: 500_000,
            nowMs: 2_000_000
        )
        #expect(await fs.exists(at: "/tmp/old.log") == false)
        #expect(await fs.exists(at: "/tmp/fresh.log") == true)

        // LocationWatcherPolicy transform, reload, and disposal
        let policy = CoreFilesystem.LocationWatcherPolicy.Service()
        let observed = ToolsConfigRuntimeHelper.Box<[String]>([])
        let obsHandle = policy.observe { patterns in observed.update { $0 = patterns } }
        let reg1 = await policy.transform { $0.add(["dist/**"]) }
        let reg2 = await policy.transform { $0.add([".cache/**"]) }
        #expect(policy.current() == ["dist/**", ".cache/**"])
        #expect(observed.get() == ["dist/**", ".cache/**"])
        reg2.dispose()
        await policy.reload()
        #expect(policy.current() == ["dist/**"])
        reg1.dispose()
        obsHandle.dispose()

        // Fuzzy filesystem search ranks matching files
        let searchSvc = CoreFilesystem.Search.Service(directory: "/repo", fileSystem: fs)
        let found = await searchSvc.find(FileSystemSchema.FindInput(query: "rtr"))
        #expect(found.contains(where: { $0.path.rawValue == "Sources/Router.swift" }))

        // Persistent pipe process CRUD via ProcessDaemon.TerminalService
        let pipeTmpDir = try ToolsConfigRuntimeHelper.makeTempDirectory(prefix: "opencode-pipe")
        defer { ToolsConfigRuntimeHelper.removeTempDirectory(pipeTmpDir) }
        let persistent = CorePty.Persistent.Service(backend: .simulated(onWrite: nil))
        let pipe = try await persistent.createPipe(CorePty.Persistent.CreatePipeInput(
            program: "/bin/sh",
            args: ["-c", "echo piped"],
            cwd: "/repo",
            groupID: "grp_pipe_1",
            outputPath: "\(pipeTmpDir)/pipe.out",
            metadata: ["kind": .string("test")]
        ))
        #expect(pipe.groupID == "grp_pipe_1")
        let pipes = try await persistent.listPipes()
        #expect(pipes.contains(where: { $0.id == pipe.id }))
        try await persistent.setPipeMetadata(pipe.id, metadata: ["kind": .string("updated")])
        let fetched = try await persistent.getPipe(pipe.id)
        #expect(fetched.metadata["kind"] == .string("updated"))
        try await persistent.terminatePipe(pipe.id)
        try await persistent.shutdown()
    }
}
