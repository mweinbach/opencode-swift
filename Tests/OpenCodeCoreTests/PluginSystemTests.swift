import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Plugin System Tests")
struct PluginSystemTests {
    // MARK: - 1. Non-Blocking Async Plugin Activation & Prefix Reload Semantics

    @Test("Non-blocking async activation: reads and hooks return immediately while slow plugin loads")
    func nonBlockingAsyncActivation() async throws {
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env)
        let gate = PluginSystemHelper.AsyncGate()

        let slowPlugin = CorePlugin.Generation(
            id: "acme.slow",
            effect: { ctx in
                await gate.markEnteredAndWait()
                _ = await ctx.shell.hook("create.before") { event in
                    var updated = event
                    updated.command = "slow-hook:\(updated.command)"
                    return updated
                }
            },
            revision: "v1",
            source: .package(target: "acme-slow", version: "1.0.0")
        )

        // Start activation in background — MUST NOT block caller.
        service.startBackgroundActivation([slowPlugin])
        await gate.waitUntilEntered()

        // CRITICAL INVARIANT: list(), has(), and trigger() return immediately with currently loaded state!
        let coldInventory = service.list()
        #expect(coldInventory.isEmpty)
        #expect(env.hooks.has(domain: .shell, name: "create.before") == false)

        let coldShell = await env.hooks.triggerShell(
            PluginEffect.ShellCreateBefore(command: "ls", cwd: "/", timeout: 5000, shell: "/bin/sh")
        )
        #expect(coldShell.command == "ls")

        // Now release slow plugin and await activation explicitly (as a one-shot CLI/test caller would).
        gate.open()
        await CorePlugin.awaitActivation(service)

        let warmInventory = service.list()
        #expect(warmInventory.count == 1)
        #expect(warmInventory[0].id?.rawValue == "acme.slow")
        #expect(warmInventory[0].state == .active)
        #expect(env.hooks.has(domain: .shell, name: "create.before") == true)

        let warmShell = await env.hooks.triggerShell(
            PluginEffect.ShellCreateBefore(command: "ls", cwd: "/", timeout: 5000, shell: "/bin/sh")
        )
        #expect(warmShell.command == "slow-hook:ls")

        await service.close()
    }

    @Test("Prefix diff keeps unchanged plugins alive, tears down suffix in LIFO order, and restores fallback on reload failure")
    func prefixDiffAndFallbackRestoration() async throws {
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env)
        let trace = PluginSystemHelper.TraceRecorder()

        let p1 = CorePlugin.Generation(
            id: "plug.a",
            effect: { ctx in
                trace.record("load:a:v1")
                ctx.addFinalizer { trace.record("close:a:v1") }
            },
            revision: "v1"
        )
        let p2v1 = CorePlugin.Generation(
            id: "plug.b",
            effect: { ctx in
                trace.record("load:b:v1")
                ctx.addFinalizer { trace.record("close:b:v1") }
            },
            revision: "v1"
        )
        let p3 = CorePlugin.Generation(
            id: "plug.c",
            effect: { ctx in
                trace.record("load:c:v1")
                ctx.addFinalizer { trace.record("close:c:v1") }
            },
            revision: "v1"
        )

        try await service.activate([p1, p2v1, p3])
        #expect(trace.snapshot() == ["load:a:v1", "load:b:v1", "load:c:v1"])

        // Reload with p1 unchanged, p2 failing v2, and p3 unchanged (after changed p2, so p3 reloads too).
        let p2v2Failing = CorePlugin.Generation(
            id: "plug.b",
            effect: { _ in
                trace.record("load:b:v2-fail")
                throw PluginSystemHelper.FailingTestError(message: "boom in v2")
            },
            revision: "v2"
        )

        try await service.activate([p1, p2v2Failing, p3])

        // p1 stayed alive (never closed/reloaded); suffix closed in reverse order (c then b);
        // b:v2 failed and fell back to restoring b:v1; c reloaded.
        #expect(trace.snapshot() == [
            "load:a:v1",
            "load:b:v1",
            "load:c:v1",
            "close:c:v1",
            "close:b:v1",
            "load:b:v2-fail",
            "load:b:v1",
            "load:c:v1",
        ])

        let infos = service.list()
        #expect(infos.count == 3)
        #expect(infos[0].state == .active)
        if case .failed(let error, _) = infos[1].state {
            #expect(error.contains("boom in v2"))
        } else {
            Issue.record("Expected plug.b to report failed state while running restored fallback")
        }
        #expect(infos[2].state == .active)

        await service.close()
        // Closing tears down remaining active scopes in reverse order: c, b (restored), a.
        #expect(trace.snapshot().suffix(3) == ["close:c:v1", "close:b:v1", "close:a:v1"])
    }

    @Test("Duplicate plugin IDs fail activation and explicit hold delays awaitActivation without blocking list()")
    func duplicateIDsAndHoldReadiness() async throws {
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env)

        let dup1 = CorePlugin.Generation(id: "dup.id", effect: { _ in }, revision: "1")
        let dup2 = CorePlugin.Generation(id: "dup.id", effect: { _ in }, revision: "2")
        await #expect(throws: CorePlugin.ActivationError.duplicatePluginID("dup.id")) {
            try await service.activate([dup1, dup2])
        }

        let releaseHold = service.hold()
        // list() never blocks even while a hold is active
        #expect(service.list().isEmpty)

        let settled = Mutex(false)
        let waiter = Task {
            await service.awaitActivation()
            settled.withLock { $0 = true }
        }
        await Task.yield()
        #expect(settled.withLock { $0 } == false)

        releaseHold()
        await waiter.value
        #expect(settled.withLock { $0 } == true)
    }

    // MARK: - 2. Hook Ordering, Provider Scoping & Error Containment

    @Test("Hook trigger ordering, provider scoping, disposal, and error containment")
    func hookOrderingScopingAndErrorContainment() async throws {
        let hooks = CorePlugin.Hooks.Service()
        let trace = PluginSystemHelper.TraceRecorder()

        // Register 3 hooks on session.http.request:
        // 1) unscoped -> appends header H1
        // 2) throws an error -> MUST be contained without stopping hook 3!
        // 3) scoped to "anthropic" -> appends header H3 only for anthropic requests
        let reg1 = hooks.registerSession(name: "http.request", options: nil) { event in
            guard case .httpRequest(var req) = event else { return event }
            trace.record("hook1")
            var headers = req.request.headers
            headers["X-Order"] = "1"
            req.request = HTTPRequest(method: req.request.method, url: req.request.url, headers: headers)
            return .httpRequest(req)
        }
        _ = hooks.registerSession(name: "http.request", options: nil) { _ in
            trace.record("hook2-throws")
            throw PluginSystemHelper.FailingTestError(message: "transient plugin failure")
        }
        _ = hooks.registerSession(
            name: "http.request",
            options: PluginEffect.ModelHookOptions(providerID: "anthropic")
        ) { event in
            guard case .httpRequest(var req) = event else { return event }
            trace.record("hook3-anthropic")
            var headers = req.request.headers
            headers["X-Order"] = (headers["X-Order"] ?? "") + ",3"
            req.request = HTTPRequest(method: req.request.method, url: req.request.url, headers: headers)
            return .httpRequest(req)
        }

        let sessionID = PluginSystemHelper.makeSampleSessionID("hook1")
        let anthropicEvent = PluginEffect.SessionHooks.httpRequest(
            PluginEffect.SessionHttpRequest(
                sessionID: sessionID,
                agent: AgentSchema.ID(rawValue: "build"),
                model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "claude-4"), providerID: ProviderSchema.ID(rawValue: "anthropic")),
                kind: .primary,
                request: PluginSystemHelper.makeSampleHTTPRequest()
            )
        )

        let outAnthropic = await hooks.triggerSession(anthropicEvent)
        if case .httpRequest(let req) = outAnthropic {
            #expect(req.request.headers["X-Order"] == "1,3")
        } else {
            Issue.record("Expected httpRequest event")
        }
        #expect(trace.snapshot() == ["hook1", "hook2-throws", "hook3-anthropic"])
        #expect(hooks.containedErrors().count == 1)
        #expect(hooks.containedErrors()[0].hookKey == "session.http.request")

        // OpenAI provider skips anthropic-scoped hook3.
        let openaiEvent = PluginEffect.SessionHooks.httpRequest(
            PluginEffect.SessionHttpRequest(
                sessionID: sessionID,
                agent: AgentSchema.ID(rawValue: "build"),
                model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "gpt-5"), providerID: ProviderSchema.ID(rawValue: "openai")),
                kind: .primary,
                request: PluginSystemHelper.makeSampleHTTPRequest()
            )
        )
        let outOpenAI = await hooks.triggerSession(openaiEvent)
        if case .httpRequest(let req) = outOpenAI {
            #expect(req.request.headers["X-Order"] == "1")
        }

        // Disposing reg1 removes only hook1.
        await reg1.dispose()
        #expect(hooks.has(domain: .session, name: "http.request", providerID: "anthropic") == true)
        let afterDispose = await hooks.triggerSession(openaiEvent)
        if case .httpRequest(let req) = afterDispose {
            #expect(req.request.headers["X-Order"] == nil)
        }
    }

    @Test("Tool hooks: execute.before propagates ToolError rejection while execute.after contains errors")
    func toolHookFailurePolicy() async throws {
        let hooks = CorePlugin.Hooks.Service()
        let sessionID = PluginSystemHelper.makeSampleSessionID("tool1")

        _ = hooks.registerTool(name: "execute.before") { _ in
            throw ToolSchema.ToolError(message: "Blocked dangerous command")
        }
        _ = hooks.registerTool(name: "execute.after") { _ in
            throw PluginSystemHelper.FailingTestError(message: "post-hook logging crash")
        }

        let beforeEvent = PluginEffect.ToolHooks.executeBefore(
            PluginEffect.ToolHooks.ExecuteBefore(
                tool: "shell",
                sessionID: sessionID,
                agent: AgentSchema.ID(rawValue: "build"),
                messageID: SessionMessageSchema.ID(rawValue: "msg_1")!,
                id: ToolSchema.CallID(rawValue: "call_1"),
                input: .object(["command": .string("rm -rf /")])
            )
        )

        do {
            _ = try await hooks.triggerTool(beforeEvent)
            Issue.record("Expected execute.before to throw ToolError")
        } catch let err {
            #expect(err.message == "Blocked dangerous command")
        }

        let afterEvent = PluginEffect.ToolHooks.executeAfter(
            PluginEffect.ToolHooks.ExecuteAfter(
                tool: "shell",
                sessionID: sessionID,
                agent: AgentSchema.ID(rawValue: "build"),
                messageID: SessionMessageSchema.ID(rawValue: "msg_1")!,
                id: ToolSchema.CallID(rawValue: "call_1"),
                input: .null,
                outcome: .completed(ToolSchema.Result(output: .string("ok")))
            )
        )
        let afterResult = try await hooks.triggerTool(afterEvent)
        #expect(afterResult.hookName == "execute.after")
        #expect(hooks.containedErrors().contains { $0.hookKey == "tool.execute.after" })
    }

    // MARK: - 3. Scoped Plugin Storage & Scoped Permissions

    @Test("Scoped plugin storage isolates namespaces with UTF-16 hex encoding and paginated scans")
    func scopedPluginStorageAndSQLitePersistence() async throws {
        let memKV = CorePlugin.InMemoryKVStore()
        let storeA = CorePlugin.Host.storage(kv: memKV, pluginID: "ab")
        let storeB = CorePlugin.Host.storage(kv: memKV, pluginID: "ab:")

        try await storeA.set("item:1", .string("a1"))
        try await storeA.set("item:2", .string("a2"))
        try await storeA.set("item:3", .string("a3"))
        try await storeB.set("item:1", .string("b1"))

        // Verify exact upstream UTF-16 4-hex-digit namespace encoding (`a`=0061, `b`=0062, `:`=003a).
        let rawKeys = memKV.rawKeys()
        #expect(rawKeys.contains("plugin:00610062:item:1"))
        #expect(rawKeys.contains("plugin:00610062003a:item:1"))

        // Complete isolation between plugins even with prefix-overlapping IDs.
        #expect(try await storeA.get("item:1") == .string("a1"))
        #expect(try await storeB.get("item:1") == .string("b1"))

        // Paginated scan strips namespace prefix from both entries and `next` cursor.
        let page1 = try await storeA.scan(PluginContract.StorageScanOptions(prefix: "item:", after: nil, limit: 2))
        #expect(page1.entries.map(\.key) == ["item:1", "item:2"])
        #expect(page1.next == "item:2")

        let page2 = try await storeA.scan(PluginContract.StorageScanOptions(prefix: "item:", after: page1.next, limit: 2))
        #expect(page2.entries.map(\.key) == ["item:3"])
        #expect(page2.next == nil)

        try await storeA.remove("item:2")
        #expect(try await storeA.get("item:2") == nil)

        // Verify SQLiteKVStore persistence via OpenCodePlatform.SQLiteDatabase.
        let sqliteKV = try PluginSystemHelper.makeInMemorySQLiteKVStore()
        let sqliteScoped = CorePlugin.Host.storage(kv: sqliteKV, pluginID: "acme.db")
        try await sqliteScoped.set("k1", .object(["count": .int(42)]))
        #expect(try await sqliteScoped.get("k1") == .object(["count": .int(42)]))
        let scanSQL = try await sqliteScoped.scan(PluginContract.StorageScanOptions(prefix: "k"))
        #expect(scanSQL.entries.count == 1)
        #expect(scanSQL.entries[0].key == "k1")
    }

    @Test("Scoped permission evaluation honors rules, evaluate hooks, always-save, and rejection feedback")
    func scopedPermissionsEvaluation() async throws {
        let hooks = CorePlugin.Hooks.Service()
        let promptCount = Mutex(0)
        let permissions = CorePlugin.PermissionRuntime(
            rules: [
                PermissionSchema.Rule(action: "read", resource: "/safe/*", effect: .allow),
                PermissionSchema.Rule(action: "delete", resource: "*", effect: .deny),
            ],
            hooks: hooks,
            promptApproval: { req in
                promptCount.withLock { $0 += 1 }
                if req.action == "write" {
                    return (.always, nil)
                }
                return (.reject, "User rejected network call")
            }
        )
        let sessionID = PluginSystemHelper.makeSampleSessionID("perm1")

        // Allowed by rule without prompting
        try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "read", resources: ["/safe/a.txt"]))
        #expect(promptCount.withLock { $0 } == 0)

        // Denied by rule throws ToolError
        do {
            try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "delete", resources: ["/tmp/x"]))
            Issue.record("Expected delete to be denied")
        } catch let err {
            #expect(err.message.contains("denied"))
        }

        // First write asks and saves .always rule; second write succeeds without prompting again!
        try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "write", resources: ["/work/a.txt"]))
        try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "write", resources: ["/work/a.txt"]))
        #expect(promptCount.withLock { $0 } == 1)

        // Hook can override an allow rule into a deny with custom message
        let reg = hooks.registerPermission(name: "evaluate") { eval in
            var copy = eval
            if eval.resources.contains("/safe/secret.env") {
                copy.effect = .deny
                copy.message = "Blocked by secret guard plugin"
            }
            return copy
        }
        do {
            try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "read", resources: ["/safe/secret.env"]))
            Issue.record("Expected hook override to deny secret.env")
        } catch let err {
            #expect(err.message == "Blocked by secret guard plugin")
        }
        await reg.dispose()

        // Rejection with feedback throws ToolError carrying feedback
        do {
            try await permissions.assert(PluginContract.AssertInput(sessionID: sessionID, action: "fetch", resources: ["https://example.com"]))
            Issue.record("Expected fetch rejection")
        } catch let err {
            #expect(err.message == "User rejected network call")
        }
    }

    // MARK: - 4. Native Swift Plugin & Promise Adapter

    @Test("Native Swift PluginSDK.NativePlugin and PluginPromise.fromPromise activate and clean up")
    func nativeSwiftAndPromisePlugins() async throws {
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env)
        let trace = PluginSystemHelper.TraceRecorder()

        let nativePlugin = PluginSystemHelper.SampleNativePlugin(id: "swift.native", recorder: trace)
        let promisePlugin = PluginPromise.define(
            PluginPromise.Plugin(id: "js.promise") { ctx in
                trace.record("promise:setup")
                _ = await ctx.tool.transform { editor in
                    editor.add(
                        PluginPromise.Info(
                            name: "promise_tool",
                            input: .jsonSchema(["type": .string("object")]),
                            description: "Promise adapted tool",
                            execute: { input, _ in
                                ToolSchema.Result(output: .object(["wrapped": input]))
                            }
                        )
                    )
                }
                return {
                    trace.record("promise:cleanup")
                }
            }
        )

        try await service.activate([
            CorePlugin.Generation(nativePlugin: nativePlugin),
            CorePlugin.Generation(plugin: PluginPromise.fromPromise(promisePlugin), revision: "1", source: .sdk),
        ])

        let tools = env.registeredTools()
        #expect(tools.map(\.id) == ["native_echo", "promise_tool"])

        let toolCtx = ToolSchema.Context(
            sessionID: PluginSystemHelper.makeSampleSessionID("t1"),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_1",
            id: ToolSchema.CallID(rawValue: "call_1"),
            progress: { _ in }
        )
        let promiseTool = try #require(tools.first { $0.id == "promise_tool" })
        let res = try await promiseTool.execute(.string("hi"), toolCtx)
        #expect(res.output == .object(["wrapped": .string("hi")]))

        await service.close()
        #expect(trace.snapshot() == [
            "native:swift.native:activate",
            "promise:setup",
            "promise:cleanup",
            "native:swift.native:cleanup",
        ])
    }

    // MARK: - 5. Out-of-Process JSON-RPC / MCP Plugin Bridge

    @Test("Out-of-process JSON-RPC plugin bridge dispatches initialize, tools, hooks, and shutdown")
    func jsonRpcPluginBridgeDispatch() async throws {
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env)
        let handshake = CorePlugin.RPCBridge.Handshake(
            id: "ext.rpc-plugin",
            hooks: ["shell.create.before", "permission.evaluate"],
            tools: [
                CorePlugin.RPCBridge.Handshake.ToolDescriptor(
                    name: "remote_lint",
                    description: "Runs remote JSON-RPC linter",
                    inputSchema: ["type": .string("object")]
                )
            ]
        )
        let transport = PluginSystemHelper.MockRPCTransport(handshake: handshake)
        let client = CorePlugin.RPCBridge.Client(transport: transport)
        let bridgedPlugin = client.asEffectPlugin(id: "ext.rpc-plugin", options: ["strict": .bool(true)])

        try await service.activate([
            CorePlugin.Generation(
                plugin: bridgedPlugin,
                revision: "rpc-1",
                source: .package(target: "ext-rpc-plugin", version: "1.2.0"),
                features: PluginSchema.Features(server: true, rpc: true)
            )
        ])

        // Remote tool was registered and executes over JSON-RPC
        let remoteTool = try #require(env.registeredTools().first { $0.id == "remote_lint" })
        let toolCtx = ToolSchema.Context(
            sessionID: PluginSystemHelper.makeSampleSessionID("rpc1"),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_rpc",
            id: ToolSchema.CallID(rawValue: "call_rpc"),
            progress: { _ in }
        )
        let toolResult = try await remoteTool.execute(.string("src/main.swift"), toolCtx)
        #expect(
            toolResult.output == .object([
                "executedBy": .string("remote-rpc"),
                "tool": .string("remote_lint"),
                "echo": .string("src/main.swift"),
            ])
        )

        // Hook triggers dispatch across JSON-RPC bridge and apply returned mutations
        let shellOut = await env.hooks.triggerShell(
            PluginEffect.ShellCreateBefore(command: "swift test", cwd: "/repo", timeout: 30_000, shell: "/bin/zsh")
        )
        #expect(shellOut.command == "rpc-wrapped: swift test")

        let permOut = await env.hooks.triggerPermission(
            PluginEffect.PermissionEvaluation(
                sessionID: PluginSystemHelper.makeSampleSessionID("rpc1"),
                action: "exec",
                resources: ["*"],
                effect: .allow
            )
        )
        #expect(permOut.effect == .deny)
        #expect(permOut.message == "Denied by remote JSON-RPC plugin")

        // Deactivation sends plugin.shutdown and closes transport
        await service.close()
        #expect(transport.isClosed() == true)
        #expect(transport.recordedMethods() == [
            "plugin.initialize",
            "plugin.tool.execute",
            "plugin.hook.trigger",
            "plugin.hook.trigger",
            "plugin.shutdown",
        ])
    }

    @Test("WebSearchMcp parses direct JSON and SSE streams and executes JSON-RPC tools/call")
    func webSearchMcpParsingAndCall() async throws {
        let direct = CorePlugin.WebSearchMcp.parseResponse(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
        #expect(direct == .object(["ok": .bool(true)]))

        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"hits\":3}}\n\n"
        #expect(CorePlugin.WebSearchMcp.parseResponse(sse) == .object(["hits": .int(3)]))

        let mockHTTP = MockHTTPTransport { _ in
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 200),
                body: PluginSystemHelper.utf8Bytes(sse)
            )
        }
        let result = try await CorePlugin.WebSearchMcp.call(
            transport: mockHTTP,
            url: CorePlugin.WebSearchExa.endpoint,
            tool: "web_search_exa",
            arguments: .object(["query": .string("swift 6.2")])
        )
        #expect(result == .object(["hits": .int(3)]))
    }

    // MARK: - 6. TUI & GUI Plugin Descriptor Registration

    @Test("TUI plugin descriptor registration, slot claims, keymaps, task-local context, and teardown")
    func tuiPluginDescriptorRegistration() async throws {
        let registry = PluginTui.DescriptorRegistry()
        let trace = PluginSystemHelper.TraceRecorder()

        let tuiDef = PluginTui.define(
            PluginTui.Definition(id: "acme.tui") { ctx in
                _ = ctx.ui.registerPage(
                    PluginTui.Page(name: "dashboard") { _ in
                        PluginTui.RenderNode(kind: "text", text: "Dashboard")
                    }
                )
                _ = ctx.ui.slot(
                    PluginTui.SlotClaim(placement: .append(.promptFooterStatus)) { _ in
                        PluginTui.RenderNode(kind: "badge", text: "ACME")
                    }
                )
                ctx.keymap.layer {
                    PluginTui.KeymapLayer(
                        mode: "base",
                        commands: [
                            PluginTui.KeymapCommand(id: "acme.open", title: "Open Dashboard", bind: "mod+d", palette: true)
                        ]
                    )
                }
                _ = ctx.registerCodeBlockRenderer("mermaid") { _ in
                    PluginTui.RenderNode(kind: "diagram")
                }
                ctx.ui.navigate(.pluginPage(name: "dashboard", data: nil))

                // Verify PluginContextProvider / usePlugin scoping
                let activeAppVersion = try PluginTui.PluginContextProvider(value: ctx) {
                    try PluginTui.usePlugin().app.version
                }
                trace.record("version:\(activeAppVersion)")
                return { trace.record("tui:cleanup") }
            }
        )

        let cleanup = try await registry.register(tuiDef, app: PluginTui.App(version: "2.1.0", channel: "dev"))
        #expect(registry.registeredPages().map(\.name) == ["dashboard"])
        #expect(registry.slotClaims(for: .promptFooterStatus).count == 1)
        #expect(registry.commands().map(\.id) == ["acme.open"])
        #expect(registry.codeBlockLanguages() == ["mermaid"])
        #expect(registry.currentRoute() == .plugin(id: "acme.tui", name: "dashboard", data: nil))
        #expect(PluginTui.SlotPath.promptFooter.contains(.promptFooterStatus) == true)

        // Outside provider, usePlugin throws
        #expect(throws: PluginTui.TuiContextError.missingContextProvider) {
            _ = try PluginTui.usePlugin()
        }

        // Teardown withdraws every page, slot, keymap layer, and code block renderer
        await cleanup()
        #expect(registry.registeredPages().isEmpty)
        #expect(registry.slotClaims(for: .promptFooterStatus).isEmpty)
        #expect(registry.commands().isEmpty)
        #expect(registry.codeBlockLanguages().isEmpty)
        #expect(trace.snapshot() == ["version:2.1.0", "tui:cleanup"])
    }

    @Test("GUI plugin descriptor registration, OS filtering, reserved ID guards, Scope LIFO teardown, and host helpers")
    func guiPluginDescriptorRegistrationAndHelpers() async throws {
        let host = PluginGui.DescriptorHost(os: .macos)
        let builtins = PluginGui.compose([
            (id: "review", entry: PluginGui.Entry(id: "review")),
            (id: "file", entry: PluginGui.Entry(id: "file")),
        ])

        // Reserved namespace and built-in collisions are rejected
        #expect(PluginGui.pluginIdAvailable("opencode", builtins: builtins) == false)
        #expect(PluginGui.pluginIdAvailable("opencode.extra", builtins: builtins) == false)
        #expect(PluginGui.pluginIdAvailable("review", builtins: builtins) == false)
        #expect(PluginGui.pluginIdAvailable("review.child", builtins: builtins) == false)
        #expect(PluginGui.pluginIdAvailable("acme.tools", builtins: builtins) == true)

        // OS filtering (Linux-only plugin skipped on macOS host)
        let linuxOnly = PluginGui.Entry(
            id: "acme.linux",
            declarations: PluginGui.Declarations(os: [.linux]),
            windowEntry: { { _ in nil } }
        )
        #expect(try await host.activate(linuxOnly, builtins: builtins) == false)
        #expect(PluginGui.runsOn(PluginGui.Declarations(os: [.macos]), os: nil) == false)
        #expect(PluginGui.runsOn(PluginGui.Declarations(os: nil), os: nil) == true)

        // Built-ins always stay enabled even when disabled in EnableState
        let disabledState = [
            PluginGui.EnableState(id: "review", enabled: false),
            PluginGui.EnableState(id: "acme.gui", enabled: false),
        ]
        #expect(PluginGui.pluginEnabled(id: "review", builtin: true, state: disabledState) == true)
        #expect(PluginGui.pluginEnabled(id: "acme.gui", builtin: false, state: disabledState) == false)

        // Active macOS GUI plugin registers Command + Theme and withdraws on deactivate
        let macEntry = PluginGui.Entry(
            id: "acme.gui",
            declarations: PluginGui.Declarations(
                os: [.macos, .windows],
                icons: ["logo": "<svg viewBox=\"0 0 16 16\"/>"]
            ),
            windowEntry: {
                { setupCtx in
                    #expect(setupCtx.icons["logo"] == PluginGui.pluginIconName(plugin: "acme.gui", name: "logo"))
                    setupCtx.base.add(
                        PluginGui.Command.registry,
                        PluginGui.Command(id: "open", title: "Open Acme", bind: "mod+shift+a")
                    )
                    setupCtx.base.add(PluginGui.Style, ".acme { color: red; }")
                    return nil
                }
            }
        )
        #expect(try await host.activate(macEntry, builtins: builtins) == true)
        #expect(host.activePluginIDs() == ["acme.gui"])
        #expect(host.list(PluginGui.Command.registry).map(\.id) == ["open"])
        #expect(host.list(PluginGui.Style) == [".acme { color: red; }"])

        await host.deactivate(id: "acme.gui")
        #expect(host.activePluginIDs().isEmpty)
        #expect(host.list(PluginGui.Command.registry).isEmpty)
        #expect(host.list(PluginGui.Style).isEmpty)

        // Scope LIFO teardown & child fork cascading
        let trace = PluginSystemHelper.TraceRecorder()
        let parentScope = PluginGui.Scope.make("acme")
        parentScope.addFinalizer(label: "first") { trace.record("first") }
        let childScope = parentScope.fork("session")
        childScope.addFinalizer(label: "child") { trace.record("child") }
        parentScope.addFinalizer(label: "last") { trace.record("last") }
        await parentScope.close()
        #expect(parentScope.signal.isAborted == true)
        #expect(childScope.signal.isAborted == true)
        #expect(trace.snapshot() == ["last", "child", "first"])

        // Host helpers & Vite preset policy
        #expect(PluginGui.mainOnlyModule("electron") == true)
        #expect(PluginGui.mainOnlyModule("node:fs") == true)
        #expect(PluginGui.mainOnlyModule("path") == true)
        #expect(PluginGui.mainOnlyModule("solid-js") == false)
        #expect(PluginGui.inertModule("electron").description == "[inert module electron]")

        let preset = PluginGui.gui()
        #expect(preset.isAllowedExternal("@opencode/plugin/gui") == true)
        #expect(preset.isForbiddenUnprovided("@opencode/core/session") == true)

        let activeGuiInfo = PluginSchema.Info(
            id: PluginSchema.ID(rawValue: "acme"),
            source: .package(target: "opencode-acme", version: "1.0.0"),
            features: PluginSchema.Features(server: true, gui: true),
            state: .active
        )
        #expect(PluginGui.shipsPluginGui(activeGuiInfo) == true)

        let builtinGuiInfo = PluginSchema.Info(
            id: PluginSchema.ID(rawValue: "opencode.builtin"),
            source: .builtin,
            features: PluginSchema.Features(server: true, gui: true),
            state: .active
        )
        #expect(PluginGui.shipsPluginGui(builtinGuiInfo) == false)
    }

    // MARK: - 7. Plugin Contract Resolution, Source Discovery, Supervisor & Built-in Helpers

    @Test("PluginContract host resolution, source tracking, directory discovery, supervisor guarded rules, and helpers")
    func contractResolutionDiscoverySupervisorAndHelpers() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/plugins/my-pkg/package.json": PluginSystemHelper.utf8Bytes(
                #"{"name":"@acme/my-plugin","exports":{".":"./dist/server.js","./tui":"./dist/tui.js","./gui-experimental":"./dist/gui.cjs"}}"#
            ),
            "/plugins/my-pkg/dist/server.js": PluginSystemHelper.utf8Bytes("export default { id: 'acme' }"),
            "/plugins/my-pkg/dist/tui.js": PluginSystemHelper.utf8Bytes("export default { id: 'acme' }"),
            "/plugins/my-pkg/dist/gui.cjs": PluginSystemHelper.utf8Bytes("module.exports = {}"),
            "/workspace/plugins/alpha.ts": PluginSystemHelper.utf8Bytes("export default {}"),
            "/workspace/plugin/beta.js": PluginSystemHelper.utf8Bytes("export default {}"),
            "/workspace/plugins/ignored.md": PluginSystemHelper.utf8Bytes("# readme"),
        ])

        let entrypoints = await PluginContract.Host.resolve(
            PluginContract.Host.Target(directory: "/plugins/my-pkg"),
            fileSystem: fs
        )
        #expect(entrypoints.server == "file:///plugins/my-pkg/dist/server.js")
        #expect(entrypoints.tui == "file:///plugins/my-pkg/dist/tui.js")
        #expect(entrypoints.gui == "file:///plugins/my-pkg/dist/gui.cjs")
        #expect(entrypoints.rpc == nil)

        let pkgID = await PluginContract.Host.packageID(
            PluginContract.Host.Target(directory: "/plugins/my-pkg"),
            fileSystem: fs
        )
        #expect(pkgID == "@acme/my-plugin")

        let discovered = await CorePlugin.SourceDirectory.discover(fs: fs, directory: "/workspace")
        #expect(discovered == ["/workspace/plugin/beta.js", "/workspace/plugins/alpha.ts"])

        // Supervisor remove "*" must NEVER remove guarded built-in plugins
        let internalPartition = CorePlugin.Internal.list()
        let resolution = await CorePlugin.Supervisor.resolve(
            loader: CorePlugin.Module.make(fileSystem: fs),
            pre: internalPartition.pre,
            post: internalPartition.post,
            operations: [.remove(target: "*")]
        )
        #expect(resolution.plugins.map(\.id) == ["opencode.provider.opencode"])

        // Built-in pure helpers parity checks
        #expect(
            CorePlugin.IdentityPlugin.identity(
                name: "Claude 4",
                ref: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "claude-4"), providerID: ProviderSchema.ID(rawValue: "anthropic"))
            ) == "# Your Model\n- Name: Claude 4\n- Provider ID: anthropic\n- Model ID: claude-4"
        )
        #expect(CorePlugin.OpencodeWatches.fence("has ``` inside").hasPrefix("````text\n"))
        #expect(
            CorePlugin.OpencodeWatches.shellTarget(
                command: "gh pr create --fill",
                exitCode: 0,
                output: "https://github.com/anomalyco/opencode/pull/42\n"
            ) == .pullRequestURL("https://github.com/anomalyco/opencode/pull/42")
        )
        #expect(CorePlugin.ClaudeAgent.Probe.versionError("2.1.248") == nil)
        #expect(CorePlugin.ClaudeAgent.Probe.versionError("2.1.100")?.contains("too old") == true)
        #expect(CorePlugin.ClaudeAgent.ToolNames.short("read_file") == "read_file")
        #expect(CorePlugin.ClaudeAgent.ToolNames.original("mcp__opencode__read_file", tools: ["read_file"]) == "read_file")
    }

    @Test("PluginContract source digest caching, reload invalidation, missingPackageTarget, and runtime filter")
    func sourceDigestCachingAndRuntimeFilters() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/app/package.json": PluginSystemHelper.utf8Bytes(#"{"name":"my-app"}"#),
            "/app/plugins/entry.js": PluginSystemHelper.utf8Bytes("export default 1"),
        ])
        let loadCount = Mutex(0)
        let watchedFiles = PluginSystemHelper.TraceRecorder()
        let sources = PluginContract.Source.createPluginSources(
            watch: { path in watchedFiles.record(path) },
            fileSystem: fs,
            prepare: { entrypoint, track in
                try await PluginContract.Source.prepareBunSource(
                    entrypoint: entrypoint,
                    track: track,
                    fileSystem: fs,
                    loader: { _ in
                        let n = loadCount.withLock { c -> Int64 in
                            c += 1
                            return Int64(c)
                        }
                        return .int(n)
                    }
                )
            }
        )

        let first = try await sources.read("file:///app/plugins/entry.js")
        let second = try await sources.read("file:///app/plugins/entry.js")
        // Unchanged file reuses cached evaluation!
        #expect(first.module == .int(1))
        #expect(second.module == .int(1))
        #expect(loadCount.withLock { $0 } == 1)

        // Modifying the file changes its SHA-256 digest and triggers a fresh reload
        try await fs.writeFile(PluginSystemHelper.utf8Bytes("export default 2"), to: "/app/plugins/entry.js", createDirectories: false)
        let third = try await sources.read("file:///app/plugins/entry.js")
        #expect(third.module == .int(2))
        #expect(loadCount.withLock { $0 } == 2)
        await sources.dispose()

        #expect(PluginContract.Source.localSource("./foo.ts", directory: "/work") == "file:///work/foo.ts")
        #expect(PluginContract.Source.localSource("bare-pkg", directory: "/work") == nil)
        #expect(
            await PluginContract.Source.missingPackageTarget(
                specifier: "@scope/pkg/sub",
                importer: "/app/plugins/entry.js",
                fileSystem: fs
            ) == "/app/node_modules/@scope/pkg"
        )
        #expect(
            await PluginContract.Source.missingPackageTarget(
                specifier: "#internal",
                importer: "/app/plugins/entry.js",
                fileSystem: fs
            ) == nil
        )
        #expect(
            PluginContract.RuntimeModules.pluginRuntimeLoaderCode(
                specifier: "effect/Schema",
                entries: ["effect": "/e/index.js", "effect/Schema": "/e/Schema.js"],
                isReexportedMember: { _, _, _ in true }
            ) == #"() => require("effect")["Schema"]"#
        )
        let filterPattern = PluginContract.Runtime.createForeignPackageFilter(rootsInput: ["/host/root"])
        #expect(filterPattern.contains(#"(?!(?:[/\\]host[/\\]root)[/\\])"#))
    }

    @Test("CorePlugin GUI bundle lookup, transform failure isolation, SDK/Instance registries, and ClaudeAgent sync")
    func guiBundleTransformFailureSdkInstanceAndClaudeSync() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/plugins/ext/gui-experimental.cjs": PluginSystemHelper.utf8Bytes("module.exports = { ok: true }")
        ])
        let env = CorePlugin.Host.Environment()
        let service = PluginSystemHelper.makeCoreService(environment: env, fileSystem: fs)
        let trace = PluginSystemHelper.TraceRecorder()

        let guiGen = CorePlugin.Generation(
            id: "ext.with-gui",
            effect: { ctx in
                ctx.addFinalizer { trace.record("gui-plugin-closed") }
            },
            revision: "r1",
            source: .local(path: "/plugins/ext"),
            features: PluginSchema.Features(server: true, gui: true),
            gui: CorePlugin.Generation.GuiDescriptor(
                file: "file:///plugins/ext/gui-experimental.cjs",
                revision: "gui-rev-1",
                options: ["theme": .string("midnight")]
            )
        )
        try await service.activate([guiGen])

        let bundle = try #require(try await service.gui(PluginSchema.ID(rawValue: "ext.with-gui")))
        #expect(bundle.code == "module.exports = { ok: true }")
        #expect(bundle.revision == "gui-rev-1")
        #expect(bundle.options["theme"] == .string("midnight"))

        // Transform failure disables plugin with err_<8hex> ref and tears down its scope
        await service.failActivePlugin(id: "ext.with-gui", stateName: "tool", cause: "bad transform")
        #expect(trace.snapshot() == ["gui-plugin-closed"])
        if case .failed(let error, let ref) = service.list().first?.state {
            #expect(error.contains("tool.transform failed"))
            #expect(ref?.hasPrefix("err_") == true)
        } else {
            Issue.record("Expected failed state after transform failure")
        }

        // SdkPlugins increments revision on re-registration; InstancePlugins rejects duplicates
        let sdkStore = CorePlugin.SdkPlugins.Service()
        sdkStore.register(PluginEffect.define(PluginEffect.Plugin(id: "sdk.one") { _ in }))
        sdkStore.register(PluginEffect.define(PluginEffect.Plugin(id: "sdk.one") { _ in }))
        #expect(sdkStore.all().map(\.revision) == ["2"])

        #expect(throws: CorePlugin.ActivationError.self) {
            _ = try CorePlugin.InstancePlugins.bound([
                PluginEffect.Plugin(id: "inst.dup") { _ in },
                PluginEffect.Plugin(id: "inst.dup") { _ in },
            ])
        }

        // ClaudeAgent sync decision & usage tracking
        let prompt: [(role: String, text: String)] = [
            (role: "user", text: "hello"),
            (role: "assistant", text: "hi there"),
            (role: "user", text: "follow up"),
        ]
        let checkpoints = CorePlugin.ClaudeAgent.Sync.buildCheckpoints(
            prompt: Array(prompt.prefix(2)),
            userID: "u1",
            replyText: nil
        )
        let record = CorePlugin.ClaudeAgent.Sync.Record(claudeSessionID: "cs_1", history: checkpoints)
        let decision = CorePlugin.ClaudeAgent.Sync.decide(prompt: prompt, record: record)
        #expect(decision.kind == .continue)
        #expect(decision.start == 2)

        let usage = CorePlugin.ClaudeAgent.UsageTracker.make()
        usage.update(id: "m1", input: 100, read: 50, write: 25, output: 40, reasoning: 10)
        let snap = usage.snapshot()
        #expect(snap.inputTotal == 175)
        #expect(snap.outputTotal == 40)
        #expect(snap.outputReasoning == 10)
        #expect(snap.outputText == 30)
    }
}
