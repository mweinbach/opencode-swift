import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Browser Plugin, Core Providers & Codemode Parity Tests")
struct BrowserAndCodemodeParityTests {
    // MARK: - Test Doubles (Foundation-free)

    final class InMemoryBrowserFS: OpenCodeFileSystem, Sendable {
        private struct State: Sendable {
            var files: [String: [UInt8]] = [:]
            var dirs: Set<String> = ["/"]
        }

        private let state = Mutex(State())

        init(files: [String: [UInt8]] = [:], dirs: Set<String> = ["/"]) {
            state.withLock { s in
                s.files = files
                s.dirs = dirs
            }
        }

        func storedFiles() -> [String: [UInt8]] {
            state.withLock { $0.files }
        }

        func readFile(at path: String) async throws -> [UInt8] {
            guard let bytes = state.withLock({ $0.files[path] }) else {
                throw PlatformError.notFound(path)
            }
            return bytes
        }

        func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
            _ = createDirectories
            state.withLock { $0.files[path] = bytes }
        }

        func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws {
            try state.withLock { s in
                if s.files[path] != nil { throw PlatformError.alreadyExists(path) }
                s.files[path] = bytes
            }
        }

        func exists(at path: String) async -> Bool {
            state.withLock { $0.files[path] != nil || $0.dirs.contains(path) }
        }

        func stat(at path: String) async throws -> FileStat {
            try state.withLock { s in
                if let data = s.files[path] {
                    return FileStat(type: .file, size: Int64(data.count), modifiedAtMs: 0)
                }
                if s.dirs.contains(path) {
                    return FileStat(type: .directory, size: 0, modifiedAtMs: 0)
                }
                throw PlatformError.notFound(path)
            }
        }

        func makeDirectory(at path: String, recursive: Bool) async throws {
            _ = recursive
            state.withLock { _ = $0.dirs.insert(path) }
        }

        func readDirectory(at path: String) async throws -> [String] {
            _ = path
            return []
        }

        func remove(at path: String) async throws {
            state.withLock { s in
                s.files.removeValue(forKey: path)
                s.dirs.remove(path)
            }
        }

        func rename(from source: String, to destination: String) async throws {
            state.withLock { s in
                if let data = s.files.removeValue(forKey: source) {
                    s.files[destination] = data
                }
            }
        }

        func realPath(at path: String) async throws -> String { path }
        func setModificationTime(at path: String, epochMs: Int64) async throws { _ = (path, epochMs) }
        func chmod(at path: String, mode: UInt16) async throws { _ = (path, mode) }
    }

    final class MockTunnelSocket: BrowserPlugin.BrowserTunnel.Socket, Sendable {
        private struct State: Sendable {
            var readChunks: [BrowserPlugin.Browser.TunnelRead]
            var written: [([UInt8], Bool)] = []
            var destroyed: Bool = false
            var writableEnded: Bool = false
        }

        private let state: Mutex<State>

        init(readChunks: [BrowserPlugin.Browser.TunnelRead] = []) {
            self.state = Mutex(State(readChunks: readChunks))
        }

        var isDestroyed: Bool { state.withLock { $0.destroyed } }
        var isWritableEnded: Bool { state.withLock { $0.writableEnded } }
        func writtenRecords() -> [([UInt8], Bool)] { state.withLock { $0.written } }

        func read(maxBytes: Int) async throws -> BrowserPlugin.Browser.TunnelRead {
            _ = maxBytes
            return state.withLock { s in
                if s.readChunks.isEmpty {
                    return BrowserPlugin.Browser.TunnelRead(data: [], eof: true)
                }
                return s.readChunks.removeFirst()
            }
        }

        func write(_ data: [UInt8], end: Bool) async throws {
            state.withLock { s in
                s.written.append((data, end))
                if end { s.writableEnded = true }
            }
        }

        func destroy() {
            state.withLock { $0.destroyed = true }
        }
    }

    final class CapturingHTTPTransport: HTTPTransport, Sendable {
        private struct State: Sendable {
            var requests: [HTTPRequest] = []
            var nextResponse: HTTPResponse
        }

        private let state: Mutex<State>

        init(statusCode: Int = 200, body: String = "{}") {
            self.state = Mutex(State(
                nextResponse: HTTPResponse(
                    head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": "application/json"]),
                    body: Array(body.utf8)
                )
            ))
        }

        func recordedRequests() -> [HTTPRequest] {
            state.withLock { $0.requests }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            state.withLock { s in
                s.requests.append(request)
                return s.nextResponse
            }
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
            let res = try await send(request)
            return HTTPStreamingResponse(
                head: res.head,
                chunks: AsyncThrowingStream { cont in
                    cont.yield(res.body)
                    cont.finish()
                }
            )
        }
    }

    // MARK: - 1. BrowserPlugin RPC, Skill & URL Normalization

    @Test("BrowserPlugin defines 44 operations, 2 file actions, experimental.browser RPC contract, and browser skill")
    func browserRPCAndSkillContract() throws {
        #expect(BrowserPlugin.Browser.Operations.count == 44)
        #expect(BrowserPlugin.Browser.Method.allCases.count == 46)
        #expect(BrowserPlugin.Browser.Definition.id == "experimental.browser")
        #expect(BrowserPlugin.Browser.Definition.methods.count == 8)
        #expect(BrowserPlugin.Browser.Definition.events["control"] != nil)
        #expect(BrowserPlugin.BrowserSkill.id.rawValue == "browser")
        #expect(BrowserPlugin.BrowserSkill.info.content.contains("tools.browser.tabs.open"))
        #expect(BrowserPlugin.BrowserSkill.info.content.contains("tools.browser.lighthouse"))

        // Branded ID validations
        let validTab = try BrowserPlugin.Browser.TabID.make("tab_01234567-89ab-cdef-0123-456789abcdef")
        #expect(validTab.rawValue.hasPrefix("tab_"))
        #expect(BrowserPlugin.Browser.TabID(rawValue: "bad_tab") == nil)

        let validRef = try BrowserPlugin.Browser.Ref.make("@e12")
        #expect(validRef.rawValue == "@e12")
        #expect(BrowserPlugin.Browser.Ref(rawValue: "e0") == nil)

        let validFile = try BrowserPlugin.Browser.FileID.make("file_01234567-89ab-cdef-0123-456789abcdef")
        #expect(validFile.rawValue.hasPrefix("file_"))
        #expect(BrowserPlugin.Browser.FileID(rawValue: "file_short") == nil)

        let target = try BrowserPlugin.Browser.TunnelTarget(host: "127.0.0.1", port: 3000)
        #expect(target.host == "127.0.0.1")
        #expect(target.port == 3000)
        #expect(throws: BrowserPlugin.Browser.ValidationError.self) {
            _ = try BrowserPlugin.Browser.TunnelTarget(host: "bad host!", port: 80)
        }
        #expect(throws: BrowserPlugin.Browser.ValidationError.self) {
            _ = try BrowserPlugin.Browser.TunnelTarget(host: "localhost", port: 0)
        }
    }

    @Test("BrowserTools.normalizeAction resolves local/remote URLs and rejects paths, file://, and credentials")
    func browserURLNormalization() throws {
        func normalize(_ type: BrowserPlugin.Browser.Method, _ fields: [String: JSONValue]) throws -> BrowserPlugin.Browser.Action {
            try BrowserPlugin.BrowserTools.normalizeAction(BrowserPlugin.Browser.Input(type: type, fields: fields))
        }
        let local = try normalize(.navigate, ["tabID": .string("tab_x"), "url": .string("localhost:3000/app")])
        #expect(local.url == "http://localhost:3000/app")

        let remote = try normalize(.tabsOpen, ["url": .string("Example.COM")])
        #expect(remote.url == "https://example.com/")

        let blank = try normalize(.navigate, ["tabID": .string("tab_x"), "url": .string("   ")])
        #expect(blank.url == "about:blank")

        let omitted = try normalize(.tabsOpen, [:])
        #expect(omitted.url == nil)

        // A file: address names a workspace file and takes the path route.
        let file = try normalize(.navigate, ["tabID": .string("tab_x"), "url": .string("file:///etc/passwd")])
        #expect(file.type == .navigatePath)

        for bad in ["/tmp/index.html", "./local.html", #"C:\page.html"#, "https://user:secret@example.com"] {
            #expect(throws: ToolSchema.ToolError.self) {
                _ = try normalize(.navigate, ["tabID": .string("tab_x"), "url": .string(bad)])
            }
        }
    }

    // MARK: - 2. BrowserPlugin Files (read, save, captureName)

    @Test("BrowserFiles sanitizes filenames, enforces 5 MiB bounds, and reads/saves server-local files")
    func browserFilesReadSaveAndCaptureName() async throws {
        #expect(BrowserPlugin.BrowserFiles.captureName("hello world?.png") == "hello_world_.png")
        #expect(BrowserPlugin.BrowserFiles.captureName(".") == "capture")
        #expect(BrowserPlugin.BrowserFiles.captureName("..") == "capture")
        #expect(BrowserPlugin.BrowserFiles.captureName("") == "capture")
        #expect(BrowserPlugin.BrowserFiles.captureName("CON.txt") == "capture")
        #expect(BrowserPlugin.BrowserFiles.captureName("lpt1") == "capture")
        let longName = String(repeating: "a", count: 200) + ".png"
        #expect(BrowserPlugin.BrowserFiles.captureName(longName).count == 160)

        let fs = InMemoryBrowserFS(
            files: [
                "/work/shot.png": [0x89, 0x50, 0x4E, 0x47],
                "/work/data.json": Array("{\"ok\":true}".utf8),
            ],
            dirs: ["/", "/work", "/work/subdir", "/tmp"]
        )

        let uploaded = try await BrowserPlugin.BrowserFiles.read(
            paths: ["/work/shot.png", "/work/data.json"],
            names: ["shot.png", "/work/data.json"],
            fileSystem: fs
        )
        #expect(uploaded.count == 2)
        #expect(uploaded[0].name == "shot.png")
        #expect(uploaded[0].mime == "image/png")
        #expect(uploaded[1].mime == "application/json")

        // Directory path must fail
        await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await BrowserPlugin.BrowserFiles.read(paths: ["/work/subdir"], names: ["subdir"], fileSystem: fs)
        }

        // Save files into isolated indexed subdirectories
        let plan = BrowserPlugin.BrowserFiles.exportPaths(uploaded, root: BrowserPlugin.BrowserFiles.exportRoot("ses_1", cache: "/tmp"))
        let saved = try await BrowserPlugin.BrowserFiles.save(files: uploaded, plan: plan, fileSystem: fs)
        #expect(saved.count == 2)
        #expect(saved[0].path.contains("/0/shot.png"))
        #expect(saved[1].path.contains("/1/data.json"))
        #expect(fs.storedFiles()[saved[0].path] == [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - 3. BrowserProxy & BrowserTunnel State Machines + Framing

    @Test("BrowserProxy authenticates requests, strips hop-by-hop headers, chunks tunnel writes, and shuts down cleanly")
    func browserProxyAuthAndForwarding() async throws {
        // Proxy state machine checks
        #expect(BrowserPlugin.BrowserProxyMachine.admits(.open) == true)
        let closed = BrowserPlugin.BrowserProxyMachine.transition(.open, .close)
        #expect(closed.state == .closed)
        #expect(closed.effects == [.shutdown])
        #expect(BrowserPlugin.BrowserProxyMachine.transition(.closed, .close).effects.isEmpty)
        #expect(BrowserPlugin.BrowserProxyMachine.transitionRead(.idle, .pull) == .reading)
        #expect(BrowserPlugin.BrowserProxyMachine.transitionRead(.reading, .chunk) == .idle)
        #expect(BrowserPlugin.BrowserProxyMachine.transitionRead(.reading, .eof) == .ended)
        #expect(BrowserPlugin.BrowserProxyMachine.transitionRead(.ended, .destroyed) == .destroyed)

        let writtenChunks = Mutex<[[UInt8]]>([])
        let closedTunnels = Mutex<[String]>([])
        let readCount = Mutex<Int>(0)

        let transport = BrowserPlugin.BrowserProxy.Transport(
            open: { target in
                "tun-\(target.host):\(target.port)"
            },
            read: { _ in
                let step = readCount.withLock { c -> Int in
                    let cur = c
                    c += 1
                    return cur
                }
                if step == 0 {
                    let wire = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nKeep-Alive: timeout=5\r\n\r\nhello-tunnel"
                    return BrowserPlugin.Browser.TunnelRead(data: Array(wire.utf8), eof: false)
                }
                return BrowserPlugin.Browser.TunnelRead(data: [], eof: true)
            },
            write: { _, data, _ in
                writtenChunks.withLock { $0.append(data) }
            },
            close: { id in
                closedTunnels.withLock { $0.append(id) }
            }
        )

        let proxy = try await BrowserPlugin.BrowserProxy.make(transport: transport, bindListener: false)

        // Missing auth -> 407
        let unauth = await proxy.handleRequest(.init(method: "GET", target: "http://localhost:3000/"))
        #expect(unauth.statusCode == 407)

        // Valid auth -> forwards request stripping hop-by-hop headers
        let authHeader = proxy.credentials.authorizationHeaderValue
        let ok = await proxy.handleRequest(.init(
            method: "GET",
            target: "http://localhost:3000/hello",
            headers: [
                ("Proxy-Authorization", authHeader),
                ("Connection", "X-Custom-Hop"),
                ("X-Custom-Hop", "drop-me"),
                ("X-Keep", "keep-me"),
            ]
        ))
        #expect(ok.statusCode == 200)
        #expect(String(decoding: ok.body, as: UTF8.self) == "hello-tunnel")
        #expect(ok.headers.contains { $0.0.lowercased() == "keep-alive" } == false)

        let sentText = writtenChunks.withLock { $0.flatMap { $0 } }
        let sentStr = String(decoding: sentText, as: UTF8.self)
        #expect(sentStr.contains("GET /hello HTTP/1.1"))
        #expect(sentStr.contains("X-Keep: keep-me"))
        #expect(!sentStr.contains("X-Custom-Hop"))
        #expect(!sentStr.contains("Proxy-Authorization"))

        // CONNECT -> 200 Connection Established
        let connectRes = await proxy.handleRequest(.init(
            method: "CONNECT",
            target: "example.com:443",
            headers: [("Proxy-Authorization", authHeader)]
        ))
        #expect(connectRes.statusCode == 200)

        await proxy.close()
        #expect(proxy.isOpen == false)
    }

    @Test("BrowserTunnelMachine and BrowserTunnel enforce 64-slot cap, single-flight I/O, and auto-eviction")
    func browserTunnelLifecycle() async throws {
        var state = BrowserPlugin.BrowserTunnelMachine.initial()
        for i in 0..<BrowserPlugin.BrowserTunnelMachine.MAX_TUNNELS {
            state = BrowserPlugin.BrowserTunnelMachine.transition(state, .openStarted(id: "t\(i)")).state
        }
        #expect(BrowserPlugin.BrowserTunnelMachine.openError(state) != nil)

        let socket = MockTunnelSocket(readChunks: [
            BrowserPlugin.Browser.TunnelRead(data: Array("abc".utf8), eof: false),
            BrowserPlugin.Browser.TunnelRead(data: [], eof: true),
        ])
        let tunnels = BrowserPlugin.BrowserTunnel.make { _ in socket }
        let target = try BrowserPlugin.Browser.TunnelTarget(host: "127.0.0.1", port: 8080)
        let id = try await tunnels.open(target)
        #expect(BrowserPlugin.BrowserTunnelMachine.isOpen(tunnels.currentState(), id: id) == true)

        try await tunnels.write(id: id, data: Array("ping".utf8), end: true)
        let first = try await tunnels.read(id: id)
        #expect(first.eof == false)
        #expect(String(decoding: first.data, as: UTF8.self) == "abc")

        // Second read hits EOF after writeEnded -> auto-evicts and destroys socket
        let second = try await tunnels.read(id: id)
        #expect(second.eof == true)
        #expect(socket.isDestroyed == true)
        #expect(BrowserPlugin.BrowserTunnelMachine.isOpen(tunnels.currentState(), id: id) == false)

        tunnels.dispose()
        #expect(BrowserPlugin.BrowserTunnelMachine.openError(tunnels.currentState()) != nil)
    }

    // MARK: - 4. BrowserPlugin Machine + End-to-End Plugin Activation & RPC Dispatch

    @Test("BrowserMachine reconciles session permissions and drives full attach/command/revoke lifecycle")
    func browserMachineAndEndToEndPlugin() async throws {
        // Permission reconciliation idempotency
        let existing: [PermissionSchema.Rule] = [
            PermissionSchema.Rule(action: "read", resource: "*", effect: .allow),
        ]
        let granted = try #require(BrowserPlugin.BrowserMachine.reconcileBrowserPermissions(existing, allow: true))
        #expect(granted.count == 3)
        #expect(BrowserPlugin.BrowserMachine.reconcileBrowserPermissions(granted, allow: true) == nil)
        let revoked = try #require(BrowserPlugin.BrowserMachine.reconcileBrowserPermissions(granted, allow: false))
        #expect(revoked == existing)
        #expect(BrowserPlugin.BrowserMachine.reconcileBrowserPermissions(revoked, allow: false) == nil)

        // Internal catalog registers opencode.browser
        let internalPlugins = CorePlugin.Internal.list()
        #expect(internalPlugins.post.contains { $0.id == "opencode.browser" })

        // End-to-end activation in CorePlugin.Host.Environment
        let env = CorePlugin.Host.Environment(
            location: LocationSchema.Info(
                directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"),
                workspaceID: nil,
                project: LocationSchema.ProjectRef(
                    id: ProjectID.global,
                    directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"),
                    canonical: SchemaPrimitive.AbsolutePath(rawValue: "/workspace")
                )
            )
        )
        let sessionID = SessionID.create()
        env.registerSession(SessionSchema.Info(
            id: sessionID,
            projectID: ProjectID.global,
            cost: 0,
            tokens: .zero,
            time: SessionSchema.Info.Time(created: 1, updated: 1),
            location: OpenCodeLocation(directory: "/workspace")
        ))

        // The agent must resolve: core (and the browser's own rule check) denies everything to an unknown agent.
        try await env.activatePlugin(PluginEffect.define(PluginEffect.Plugin(id: "test.agents") { ctx in
            _ = await ctx.agent.transform { editor in editor.update("build") { _ in } }
        }))
        try await env.activatePlugin(BrowserPlugin.Plugin)
        #expect(env.registeredSkills().contains { $0.id.rawValue == "browser" })
        #expect(env.registeredTools().count == 44)
        #expect(env.registeredToolNamespaces().contains { $0.name == "browser" })

        // Subscribe to RPC control stream before attaching
        let controlStream = env.subscribeRpc(namespace: "experimental.browser", event: "control")
        let attachTask = Task {
            try await env.callRpc(
                namespace: "experimental.browser",
                method: "attach",
                input: .object([
                    "sessionID": .string(sessionID.rawValue),
                    "connectionID": .string("conn-1"),
                    "version": .int(4),
                ])
            )
        }

        // Wait for `attached` control event
        var iterator = controlStream.makeAsyncIterator()
        let attachedEvent = await iterator.next()
        #expect(attachedEvent?.data["type"] == .string("attached"))
        #expect(attachedEvent?.data["connectionID"] == .string("conn-1"))
        #expect(attachedEvent?.data["version"] == .int(4))

        // Session permissions were granted automatically
        let updatedSession = try #require(env.session(id: sessionID))
        #expect(updatedSession.permissions?.contains { $0.action == "browser" && $0.effect == .allow } == true)

        // Report browser state with one tab
        let tabID = "tab_01234567-89ab-cdef-0123-456789abcdef"
        _ = try await env.callRpc(
            namespace: "experimental.browser",
            method: "state",
            input: .object([
                "sessionID": .string(sessionID.rawValue),
                "connectionID": .string("conn-1"),
                "state": .object([
                    "tabs": .array([
                        .object([
                            "id": .string(tabID),
                            "url": .string("about:blank"),
                            "title": .string("Blank"),
                            "loading": .bool(false),
                            "canGoBack": .bool(false),
                            "canGoForward": .bool(false),
                            "generation": .int(1),
                        ]),
                    ]),
                    "focusedTabID": .string(tabID),
                ]),
            ])
        )

        // Invoke the registered `browser_navigate` tool while desktop RPC responds asynchronously
        let navTool = try #require(env.registeredTools().first { $0.id == "browser_navigate" })
        let toolTask = Task {
            try await navTool.execute(
                .object(["tabID": .string(tabID), "url": .string("localhost:3000")]),
                ToolSchema.Context(
                    sessionID: sessionID,
                    agent: AgentSchema.ID(rawValue: "build"),
                    messageID: "msg-1",
                    id: ToolSchema.CallID(rawValue: "call-1"),
                    progress: { _ in }
                )
            )
        }

        let commandEvent = await iterator.next()
        #expect(commandEvent?.data["type"] == .string("command"))
        guard case .string(let requestID) = commandEvent?.data["requestID"] else {
            Issue.record("Missing requestID on command control event")
            attachTask.cancel()
            return
        }

        let cmdPayload = try await env.callRpc(
            namespace: "experimental.browser",
            method: "command",
            input: .object([
                "sessionID": .string(sessionID.rawValue),
                "connectionID": .string("conn-1"),
                "requestID": .string(requestID),
            ])
        )
        if case .object(let cmdObj) = cmdPayload,
           case .object(let actionObj) = cmdObj["action"]
        {
            #expect(actionObj["type"] == .string("navigate"))
            #expect(actionObj["url"] == .string("http://localhost:3000/"))
        } else {
            Issue.record("Malformed command payload: \(cmdPayload)")
        }

        _ = try await env.callRpc(
            namespace: "experimental.browser",
            method: "result",
            input: .object([
                "sessionID": .string(sessionID.rawValue),
                "connectionID": .string("conn-1"),
                "requestID": .string(requestID),
                "outcome": .object([
                    "type": .string("success"),
                    "result": .object([
                        "value": .object([
                            "id": .string(tabID),
                            "url": .string("http://localhost:3000/"),
                            "title": .string("Local App"),
                            "loading": .bool(false),
                            "canGoBack": .bool(true),
                            "canGoForward": .bool(false),
                            "generation": .int(2),
                        ]),
                        "files": .array([]),
                    ]),
                ]),
            ])
        )

        let toolResult = try await toolTask.value
        if case .object(let outObj) = toolResult.output {
            #expect(outObj["title"] == .string("Local App"))
            #expect(outObj["generation"] == .int(2))
        } else {
            Issue.record("Unexpected tool output: \(String(describing: toolResult.output))")
        }

        attachTask.cancel()
        _ = try? await attachTask.value
    }

    // MARK: - 5. GitHub Copilot, Claude Agent & Watches Core Plugin Helpers

    @Test("GitHub Copilot helpers: entitlement errors, base URL resolution, interaction types, and utility title HTTP call")
    func githubCopilotHelpers() async throws {
        #expect(CorePlugin.GithubCopilot.copilotEntitlementError(.init(chatEnabled: true)) == nil)
        #expect(CorePlugin.GithubCopilot.copilotEntitlementError(.init(chatEnabled: nil)) == nil)
        let freeMsg = try #require(
            CorePlugin.GithubCopilot.copilotEntitlementError(.init(chatEnabled: false, canSignupForLimited: true))
        )
        #expect(freeMsg.contains("Copilot Free"))
        let paidMsg = try #require(
            CorePlugin.GithubCopilot.copilotEntitlementError(.init(chatEnabled: false, canSignupForLimited: false))
        )
        #expect(paidMsg.contains("active Copilot subscription"))

        #expect(CorePlugin.GithubCopilot.copilotBaseURL(nil) == "https://api.githubcopilot.com")
        #expect(CorePlugin.GithubCopilot.copilotBaseURL(["apiEndpoint": .string("https://custom.copilot.local")]) == "https://custom.copilot.local")
        #expect(CorePlugin.GithubCopilot.copilotBaseURL(["enterpriseUrl": .string("https://github.acme.com/")]) == "https://copilot-api.github.acme.com")
        #expect(CorePlugin.GithubCopilot.utilityTitleModels == ["gpt-4o-mini"])

        #expect(CorePlugin.GithubCopilot.interactionType(.title, child: false) == "conversation-background")
        #expect(CorePlugin.GithubCopilot.interactionType(.compaction, child: true) == "conversation-compaction")
        #expect(CorePlugin.GithubCopilot.interactionType(.primary, child: true) == "conversation-subagent")
        #expect(CorePlugin.GithubCopilot.interactionType(.primary, child: false) == "conversation-agent")

        let transport = CapturingHTTPTransport(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"  Fix Login Bug  "}}]}"#
        )
        let sid = SessionID.create()
        let title = try await CorePlugin.GithubCopilot.utilityTitle(
            .init(baseURL: "https://api.githubcopilot.com", token: "tok_123", model: "gpt-4o-mini", transport: transport),
            request: .init(
                sessionID: sid,
                system: [.init(text: "Write a short title.")],
                messages: [.init(role: "user", parts: [.init(text: "Please fix the login bug")])],
                maxTokens: 32
            )
        )
        #expect(title == "Fix Login Bug")
        let reqs = transport.recordedRequests()
        #expect(reqs.count == 1)
        #expect(reqs[0].url == "https://api.githubcopilot.com/chat/completions")
        #expect(reqs[0].headers["X-GitHub-Api-Version"] == "2026-08-01")
        #expect(reqs[0].headers["X-Interaction-Type"] == "agent-session-name-generation")
        #expect(reqs[0].headers["X-Interaction-Id"] == sid.rawValue)
        #expect(reqs[0].headers["x-initiator"] == "agent")
    }

    @Test("ClaudeAgent LanguageModel.Model enforces streaming-only doGenerate and routes doStream options")
    func claudeAgentLanguageModelMethods() async throws {
        let captured = Mutex<CorePlugin.ClaudeAgent.LanguageModel.StreamRunRequest?>(nil)
        let model = CorePlugin.ClaudeAgent.LanguageModel.Model(
            modelId: "claude-sonnet-4-5",
            dependencies: .init(run: { req in
                captured.withLock { $0 = req }
                req.emit(.textDelta("Hello"))
                req.emit(.toolCall(name: "mcp__opencode__read", arguments: .object(["path": .string("a.txt")])))
                req.emit(.finish(reason: "stop"))
            })
        )

        await #expect(throws: CorePlugin.ClaudeAgent.LanguageModel.LanguageModelError.self) {
            try await model.doGenerate()
        }

        // Invalid effort rejects
        await #expect(throws: CorePlugin.ClaudeAgent.LanguageModel.LanguageModelError.self) {
            _ = try await model.doStream(.init(
                providerOptions: ["claude-agent": ["effort": .string("turbo")]]
            ))
        }

        let streamRes = try await model.doStream(.init(
            headers: [
                CorePlugin.ClaudeAgent.RequestKindHeader: "primary",
                CorePlugin.ClaudeAgent.SessionHeader: "ses_1",
                CorePlugin.ClaudeAgent.ForkHeader: "ses_0",
            ],
            providerOptions: [
                "claude-agent": [
                    "effort": .string("high"),
                    CorePlugin.ClaudeAgent.AGENT_OPTION: .string("Build"),
                ],
            ],
            tools: ["read"]
        ))

        var parts: [CorePlugin.ClaudeAgent.LanguageModel.StreamPart] = []
        for try await part in streamRes.stream {
            parts.append(part)
        }
        #expect(parts.count == 4)
        #expect(parts[0] == .streamStart(warnings: []))
        #expect(parts[1] == .textDelta("Hello"))
        #expect(parts[2] == .toolCall(name: "read", arguments: .object(["path": .string("a.txt")])))
        #expect(parts[3] == .finish(reason: "stop"))

        let req = try #require(captured.withLock { $0 })
        #expect(req.sessionID == "ses_1")
        #expect(req.sourceID == "ses_0")
        #expect(req.effort == .high)
        #expect(req.system.contains("Build"))

        // Also check OpencodeWatches.shellTarget with git -C push
        let pushed = CorePlugin.OpencodeWatches.shellTarget(
            command: "git -C /repo push origin main",
            exitCode: 0,
            output: "To git@github.com:Acme/App.git\n   abc1234..def5678  main -> main\n"
        )
        #expect(pushed == .githubBranch(repo: "acme/app", branch: "main"))
    }

    // MARK: - 6. GUI Plugin Host API Contracts

    @Test("PluginGui exposes expanded host APIs (Toasts, Attention, Commands, Tabs, WindowEmbeds, Ui)")
    func guiPluginHostAPIs() async {
        let ctx = PluginGui.Context(id: "acme.gui")
        let handle = ctx.toast.show(PluginGui.ToastOptions(title: "Saved", variant: .success))
        handle.dismiss()
        let notifyRes = await ctx.attention.notify(PluginGui.NotifyOptions(title: "Done"))
        #expect(notifyRes.notification == false)
        #expect(ctx.commands.run("acme.noop") == false)
        #expect(ctx.tabs.list().isEmpty)
        let embedNode = ctx.embeds.View(PluginGui.EmbedProps(id: "e1", visible: true))
        #expect(embedNode.component == "embed")
        let buttonNode = ctx.ui.Button(PluginGui.UiButtonProps(children: PluginGui.ViewNode(component: "text", label: "Go")))
        #expect(buttonNode.component == "ui.button")
        #expect(buttonNode.label == "Go")
    }

    // MARK: - 7. Codemode Class Methods, Core Helpers & Re-Exports

    @Test("CoreCodemode Catalog.cost and Bun.display/extension match upstream semantics")
    func coreCodemodeCostAndBunHelpers() {
        #expect(CoreCodemode.Catalog.cost("") == 0)
        #expect(CoreCodemode.Catalog.cost("abcd") == 1)
        #expect(CoreCodemode.Catalog.cost("abcdef") == 2) // 6/4 = 1.5 -> rounds to 2

        #expect(CoreCodemode.Bun.extension.name == "bun")
        #expect(CoreCodemode.Bun.extension.modules?["bun"] == "Bun")

        let builtins = CodemodeLanguage.createBuiltins()
        let dst = CodemodeLanguage.Obj(proto: builtins.Object)
        CodemodeLanguage.define(dst, "name", .string("out.txt"))
        let src = CodemodeLanguage.Obj(proto: builtins.Object)
        CodemodeLanguage.define(src, "name", .string("in.txt"))

        let writeDisplay = CoreCodemode.Bun.display(name: "Bun.write", args: [.object(dst), .object(src)])
        #expect(writeDisplay["method"] == .string("write"))
        #expect(writeDisplay["path"] == .string("out.txt"))
        #expect(writeDisplay["from"] == .string("in.txt"))

        let fileDisplay = CoreCodemode.Bun.display(name: "Bun.file", args: [.string("README.md")])
        #expect(fileDisplay["method"] == .string("file"))
        #expect(fileDisplay["path"] == .string("README.md"))
        #expect(fileDisplay["from"] == nil)
    }

    @Test("Codemode CodeBuilder, OrderedTable live cursors, Obj subclass hooks, and TextDecoderObj streaming")
    func codemodeClassMethodsAndRuntime() async throws {
        // CodeBuilder methods
        let builder = CodemodeLanguage.CodeBuilder(
            source: CodemodeLanguage.SourceRef(id: "test", hash: "abc"),
            sourceObj: nil,
            index: 0,
            name: "main",
            flags: 0,
            length: 0,
            params: 0,
            locals: 1,
            localNames: ["x"]
        )
        #expect(builder.pc == 0)
        try builder.emitNumber(42, nodeIndex: 1)
        try builder.emitString("hi", nodeIndex: 2)
        var endLabel = builder.newLabel()
        try builder.emitJump(CodemodeLanguage.Op.JUMP, label: &endLabel)
        builder.unreachable()
        try builder.mark(&endLabel)
        let finLevel = builder.reserveFinally()
        try builder.setFinally(level: finLevel, tagSlot: 0, valSlot: 0, entryDepth: 0, targets: [builder.pc])
        builder.addHandler(start: 0, end: builder.pc, target: builder.pc, depth: 0)
        let compiled = builder.finish()
        #expect(compiled.code.count >= 3)
        #expect(compiled.nodeIndexAt(0) == 1)
        #expect(compiled.handlers.count == 4)
        #expect(compiled.finallyOffsets.count == 1)

        // OrderedTable live cursor & compaction
        let table = CodemodeLanguage.OrderedTable()
        for i in 0..<20 {
            table.set(.string("k\(i)"), .number(Double(i)))
        }
        let cursor = table.cursor()
        let firstIdx = table.advance(cursor)
        #expect(firstIdx == 0)
        for i in 1..<18 {
            table.delete(.string("k\(i)"))
        }
        // Compaction ran after tombstones >= 16 and shifted live cursor cleanly
        let nextIdx = table.advance(cursor)
        #expect(nextIdx >= 0)
        if let (k, _) = table.entry(at: nextIdx), case .string(let keyStr) = k {
            #expect(keyStr == "k18")
        } else {
            Issue.record("Expected k18 after compaction")
        }

        // Obj subclass methods + TextDecoderObj multi-byte streaming
        let builtins = CodemodeLanguage.createBuiltins()
        let arr = CodemodeLanguage.Arr(proto: builtins.Array, items: [.number(1), .null, .string("x")])
        #expect(arr.describe == "an array")
        #expect(arr.jsToString() == "1,,x")
        #expect(arr.toHost { v in
            if case .string(let s) = v { return .string(s.toHostString()) }
            if case .number(let n) = v { return .int(Int64(n)) }
            return nil
        } == .array([.int(1), .null, .string("x")]))

        let buf = CodemodeLanguage.BufferObj(proto: builtins.Buffer, data: Array("hi".utf8))
        #expect(buf.jsToString() == "hi")
        #expect(buf.inspect({ _ in "" }) == "<Buffer 68 69>")

        let decoder = CodemodeLanguage.TextDecoderObj(proto: builtins.TextDecoder, fatal: true, ignoreBOM: false)
        // UTF-8 BOM + split 4-byte emoji U+1F600 (F0 9F 98 80) across two chunks
        let part1 = try decoder.decode([0xEF, 0xBB, 0xBF, 0xF0, 0x9F], stream: true)
        #expect(part1 == "")
        let part2 = try decoder.decode([0x98, 0x80], stream: false)
        #expect(part2 == "😀")

        // Scheduler, HostCalls, Vm, Driver & CodemodeEngine re-exports
        let interp = CodemodeLanguage.Interpreter(builtins: builtins)
        let vm = CodemodeLanguage.Vm(interpreter: interp)
        let fnTarget = CodemodeLanguage.Host.Fn(run: { _, _, _ in .string("ok") }, type: .async)
        let res = vm.hostCalls.call(target: .fn(fnTarget), label: "tools.demo", path: "tools.demo", builtins: builtins)
        guard case .value(.object(let callPromise as CodemodeLanguage.PromiseObj)) = res else {
            Issue.record("Expected promise from async host call")
            return
        }
        let handed = vm.hostCalls.handOver()
        #expect(handed.count == 1)
        let driver = CodemodeLanguage.Driver(vm: vm)
        #expect(driver.blocking().count == 1)
        vm.complete(id: handed[0].id, completion: .ok(.string("done")))
        #expect(vm.hostCalls.deliver() == true)
        let outcome = await callPromise.awaitOutcome()
        if case .fulfilled(.string(let val)) = outcome {
            #expect(val == "done")
        } else {
            Issue.record("Expected fulfilled promise")
        }

        let scanned = CodemodeEngine.scanCodeModeTools("await tools.browser.tabs.list({});")
        #expect((try? scanned.get()) == ["browser.tabs.list"])
    }
}
