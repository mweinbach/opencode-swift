import Testing
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

@Suite("CLI ACP Bridge & Protocol Suite")
struct CLIACPBridgeTests {

    // MARK: - 1. NDJSON Framing & JSON-RPC Codec

    @Test("NDJSON line buffer splits arbitrary chunks, handles CRLF/LF, and flushes trailing frames")
    func ndjsonLineBufferFraming() throws {
        var buffer = CLIACP.NDJSONLineBuffer()
        let req = CLIACP.JSONRPCMessage.request(
            id: .int(1),
            method: CLIACP.Methods.initialize,
            params: .object(["protocolVersion": .int(1)])
        )
        let note = CLIACP.JSONRPCMessage.notification(
            method: CLIACP.Methods.sessionCancel,
            params: .object(["sessionId": .string("ses_1")])
        )
        let raw1 = try CLIACP.NDJSONCodec.encodeLine(req)
        let raw2 = try CLIACP.NDJSONCodec.encodeLine(note).replacing("\n", with: "\r\n")
        let combined = Array((raw1 + "\n\n" + raw2 + "{\"jsonrpc\":\"2.0\",\"id\":\"tail\",\"result\":{}}").utf8)

        let splitA = Array(combined[0..<12])
        let splitB = Array(combined[12..<combined.count])

        var lines: [String] = []
        lines.append(contentsOf: buffer.push(splitA))
        lines.append(contentsOf: buffer.push(splitB))
        if let tail = buffer.flush() {
            lines.append(tail)
        }

        #expect(lines.count == 3)
        #expect(try CLIACP.NDJSONCodec.decode(lines[0]) == req)
        #expect(try CLIACP.NDJSONCodec.decode(lines[1]) == note)
        #expect(try CLIACP.NDJSONCodec.decode(lines[2]) == .response(id: .string("tail"), result: .object([:])))
    }

    @Test("NDJSONStream.fromBytes round-trips JSON-RPC frames over raw byte pipes")
    func ndjsonStreamFromBytesRoundtrip() async throws {
        let req = CLIACP.JSONRPCMessage.request(id: .string("abc"), method: "ping", params: .object(["v": .int(7)]))
        let encoded = try CLIACP.NDJSONCodec.encode(req)

        let input = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield(Array(encoded.prefix(5)))
            continuation.yield(Array(encoded.dropFirst(5)))
            continuation.finish()
        }
        let collector = CLIACPByteCollector()
        let stream = CLIACP.NDJSONStream.fromBytes(
            input: input,
            write: { bytes in
                collector.append(bytes)
            }
        )

        var decoded: [CLIACP.JSONRPCMessage] = []
        for try await message in stream.readable {
            decoded.append(message)
        }
        #expect(decoded == [req])

        let reply = CLIACP.JSONRPCMessage.response(id: .string("abc"), result: .object(["ok": .bool(true)]))
        try await stream.write(reply)
        let replyLine = String(decoding: collector.bytes, as: UTF8.self)
        #expect(replyLine.hasSuffix("\n"))
        #expect(try CLIACP.NDJSONCodec.decode(replyLine) == reply)
    }

    // MARK: - 2. Protocol Handshake, Capabilities & Auth

    @Test("initialize negotiates protocol v1, advertises capabilities, and gates terminal auth")
    func initializeAndAuthenticateHandshake() async throws {
        let wire = CLIACPWireFixture(version: "2.4.0")
        defer { Task { await wire.close() } }

        let plain = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 99),
            as: CLIACP.InitializeResponse.self
        )
        #expect(plain.protocolVersion == 1)
        #expect(plain.agentInfo == CLIACP.AgentInfo(name: "OpenCode", version: "2.4.0"))
        #expect(plain.agentCapabilities.loadSession == true)
        #expect(plain.agentCapabilities.mcpCapabilities == CLIACP.McpCapabilities(http: true, sse: false))
        #expect(plain.agentCapabilities.promptCapabilities == CLIACP.PromptCapabilities(embeddedContext: true, image: true))
        #expect(plain.agentCapabilities._meta?[CLIACP.Capabilities.childSessionUpdatesKey] == .bool(true))
        #expect(plain._meta?["steering"] == .object(["supported": .bool(true)]))
        #expect(plain.authMethods.count == 1)
        #expect(plain.authMethods[0].id == "opencode-login")
        #expect(plain.authMethods[0].type == nil)
        #expect(plain.authMethods[0]._meta == nil)

        let terminalMeta = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: CLIACP.ClientCapabilities(
                    auth: CLIACP.ClientAuthCapabilities(terminal: true),
                    _meta: ["terminal-auth": .bool(true)]
                )
            ),
            as: CLIACP.InitializeResponse.self
        )
        #expect(terminalMeta.authMethods[0].type == "terminal")
        #expect(terminalMeta.authMethods[0].args == ["--login"])
        #expect(terminalMeta.authMethods[0]._meta?["terminal-auth"] != nil)

        let okAuth = try await wire.peer.request(
            CLIACP.Methods.authenticate,
            params: CLIACP.AuthenticateRequest(methodId: "opencode-login"),
            as: CLIACP.AuthenticateResponse.self
        )
        #expect(okAuth == CLIACP.EmptyObject())

        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.authenticate,
                params: CLIACP.AuthenticateRequest(methodId: "unknown-method"),
                as: CLIACP.AuthenticateResponse.self
            )
            Issue.record("Expected unknown auth method to fail")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
            #expect(err.data == .object(["methodId": .string("unknown-method")]))
        }
    }

    @Test("Capabilities.parse treats null compaction and elicitation form capabilities as unsupported")
    func capabilitiesNullSemantics() {
        let supported = CLIACP.Capabilities.parse(
            CLIACP.ClientCapabilities(
                elicitation: CLIACP.ClientElicitationCapabilities(form: .object([:])),
                session: CLIACP.ClientSessionCapabilities(compaction: .object([:])),
                _meta: [CLIACP.Capabilities.childSessionUpdatesKey: .bool(true)]
            )
        )
        #expect(supported.childSessionUpdates == true)
        #expect(supported.formElicitation == true)
        #expect(supported.compaction == true)

        let nullCaps = CLIACP.Capabilities.parse(
            CLIACP.ClientCapabilities(
                elicitation: CLIACP.ClientElicitationCapabilities(form: .null),
                session: CLIACP.ClientSessionCapabilities(compaction: .null),
                _meta: [CLIACP.Capabilities.childSessionUpdatesKey: .bool(false)]
            )
        )
        #expect(nullCaps.childSessionUpdates == false)
        #expect(nullCaps.formElicitation == false)
        #expect(nullCaps.compaction == false)
    }

    // MARK: - 3. Error Sanitization & Classification

    @Test("fromUnknown and toRequestError sanitize unknown defects without leaking secrets")
    func errorSanitizationAndMapping() {
        let defect = CLIACPTestEvents.makeErrorWithSecret("stack has sk-ant-secret and oauth refresh token")
        let requestErr = CLIACP.Errors.toRequestError(.serviceFailure(CLIACP.Errors.fromUnknown(defect)))
        let serialized = CLIACPTestEvents.encodeJSONString(requestErr.toErrorResponse())

        #expect(requestErr.code == -32603)
        #expect(requestErr.message == "Internal error: Internal service failure")
        #expect(!serialized.contains("sk-ant-secret"))
        #expect(!serialized.contains("oauth refresh token"))
        #expect(!serialized.contains("stack"))

        let authErr = CLIACP.Errors.toRequestError(.authRequired(.init()))
        #expect(authErr.code == -32000)

        let unavail = CLIACP.Errors.toRequestError(.serverUnavailable(.init()))
        #expect(unavail.code == -32603)
        #expect(unavail.message == "Internal error: OpenCode server is unavailable")
        #expect(unavail.data == .object(["errorName": .string("ServerUnavailable")]))

        #expect(
            CLIACP.ClientHelpers.classify(ClientError(reason: .transport, detail: "down"))
                == .serverUnavailable(.init())
        )
        #expect(
            CLIACP.ClientHelpers.classify(OpenCodeProtocol.SessionNotFoundError(sessionID: "ses_1", message: "missing"))
                == .sessionNotFound(.init(sessionId: "ses_1"))
        )
        #expect(
            CLIACP.ClientHelpers.classify(OpenCodeProtocol.InvalidCursorError(message: "bad"))
                == .invalidRequest(.init(message: "bad", field: "cursor"))
        )
        #expect((try? CLIACP.ClientHelpers.decodeSessionID("ses_valid"))?.rawValue == "ses_valid")
        #expect((try? CLIACP.ClientHelpers.decodeSessionID("not_a_session")) == nil)
    }

    // MARK: - 4. Session Lifecycle, Replay, Additional Directories & MCP

    @Test("session/new, session/list, session/close unprompted cleanup, and session/delete lifecycle")
    func sessionLifecycleNewListCloseDelete() async throws {
        let wire = CLIACPWireFixture()
        defer { Task { await wire.close() } }

        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )

        let created = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(
                cwd: "/workspace",
                additionalDirectories: ["/shared/lib", "/workspace"],
                mcpServers: [
                    .stdio(CLIACP.McpServerStdio(name: "tools", command: "bun", args: ["srv.ts"], env: [.init(name: "K", value: "V")])),
                    .http(CLIACP.McpServerHttp(name: "docs", url: "https://example.com/mcp", headers: [.init(name: "Auth", value: "B")])),
                ]
            ),
            as: CLIACP.NewSessionResponse.self
        )
        #expect(created.sessionId.hasPrefix("ses_"))
        #expect(created.configOptions.first(where: { $0.id == "model" })?.currentValue == "test/first-model")
        #expect(created.configOptions.first(where: { $0.id == "mode" })?.currentValue == "build")

        // Commands update is published AFTER the session/new response.
        let gotCommands = await wire.waitUntil {
            wire.updates.contains { $0.sessionId == created.sessionId && $0.update.sessionUpdateKind == "available_commands_update" }
        }
        #expect(gotCommands)
        #expect(wire.backend.mcpAdds.count == 2)

        // List returns fallback title, ISO updatedAt, and additionalDirectories (without cwd).
        let listed = try await wire.peer.request(
            CLIACP.Methods.sessionList,
            params: CLIACP.ListSessionsRequest(cwd: "/workspace"),
            as: CLIACP.ListSessionsResponse.self
        )
        #expect(listed.sessions.count == 1)
        #expect(listed.sessions[0].sessionId == created.sessionId)
        #expect(listed.sessions[0].additionalDirectories == ["/shared/lib"])
        #expect(listed.sessions[0].title.hasPrefix("New session - "))
        #expect(listed.sessions[0].updatedAt.hasSuffix("Z"))

        // Closing an unprompted session with no messages removes it from the server.
        _ = try await wire.peer.request(
            CLIACP.Methods.sessionClose,
            params: CLIACP.CloseSessionRequest(sessionId: created.sessionId),
            as: CLIACP.CloseSessionResponse.self
        )
        #expect(wire.backend.getSession(created.sessionId) == nil)

        // Rejects SSE MCP server and glob additionalDirectory before creating a session.
        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionNew,
                params: CLIACP.NewSessionRequest(
                    cwd: "/workspace",
                    mcpServers: [.sse(CLIACP.McpServerUnsupported(type: "sse", name: "legacy", url: "https://x"))]
                ),
                as: CLIACP.NewSessionResponse.self
            )
            Issue.record("Expected SSE MCP server rejection")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
        }

        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionNew,
                params: CLIACP.NewSessionRequest(cwd: "/workspace", additionalDirectories: ["/bad/*"]),
                as: CLIACP.NewSessionResponse.self
            )
            Issue.record("Expected wildcard directory rejection")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
            #expect(err.data == .object(["additionalDirectory": .string("/bad/*")]))
        }
    }

    @Test("session/load replays paginated history and completed diffs while resume and fork skip replay")
    func sessionLoadResumeForkAndReplay() async throws {
        let editedPath = "/workspace/edited.ts"
        let patch = """
            --- a/edited.ts
            +++ b/edited.ts
            @@ -1,2 +1,2 @@
             one
            -two
            +three
            """
        let fs = CLIACPTestFS(files: [editedPath: "one\r\nthree\r\n"])
        let backend = CLIACPTestBackend()
        let saved = CLIACPTestBackend.makeSession(
            id: "ses_loaded",
            cwd: "/workspace",
            agent: "plan",
            model: SessionSchema.ModelRef(id: "second-model", providerID: "test", variant: "medium"),
            metadata: ["host": .string("tui"), CLIACP.Directories.metadataKey: .array([.string("/old")])],
            permissions: [
                SessionSchema.PermissionRule(action: "external_directory", resource: "/old/*", effect: .allow),
                SessionSchema.PermissionRule(action: "read", resource: "*.secret", effect: .deny),
            ]
        )
        backend.putSession(saved)

        // 201 messages to verify 200-item cursor pagination + assistant tool diff replay.
        var history: [SessionMessageSchema.Info] = (0..<200).map { idx in
            .user(
                SessionMessageSchema.User(
                    id: SessionMessageSchema.ID(rawValue: "msg_u_\(idx)")!,
                    time: SessionMessageSchema.TimeCreated(created: Int64(idx)),
                    text: "message \(idx)"
                )
            )
        }
        history.append(
            .assistant(
                SessionMessageSchema.Assistant(
                    id: SessionMessageSchema.ID(rawValue: "msg_asst")!,
                    agent: "plan",
                    model: SessionSchema.ModelRef(id: "second-model", providerID: "test"),
                    content: [
                        .text(SessionMessageSchema.AssistantText(text: "done")),
                        .reasoning(SessionMessageSchema.AssistantReasoning(text: "thought")),
                        .tool(
                            SessionMessageSchema.AssistantTool(
                                id: "call_edit",
                                name: "edit",
                                state: .completed(
                                    SessionMessageSchema.ToolStateCompleted(
                                        input: ["path": .string(editedPath)],
                                        content: [.text("edited")],
                                        metadata: [
                                            "files": .array([
                                                .object([
                                                    "file": .string(editedPath),
                                                    "patch": .string(patch),
                                                    "additions": .int(1),
                                                    "deletions": .int(1),
                                                    "status": .string("modified"),
                                                ]),
                                            ]),
                                        ]
                                    )
                                ),
                                time: SessionMessageSchema.AssistantTool.Time(created: 201)
                            )
                        ),
                    ],
                    time: SessionMessageSchema.Assistant.Time(created: 201)
                )
            )
        )
        backend.setMessages(sessionID: "ses_loaded", history)

        let wire = CLIACPWireFixture(backend: backend, fs: fs)
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )

        // Mismatched cwd must fail with -32602.
        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionLoad,
                params: CLIACP.LoadSessionRequest(sessionId: "ses_loaded", cwd: "/elsewhere"),
                as: CLIACP.LoadSessionResponse.self
            )
            Issue.record("Expected directory mismatch error")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
            #expect(err.data == .object(["sessionId": .string("ses_loaded"), "cwd": .string("/elsewhere")]))
        }

        let loaded = try await wire.peer.request(
            CLIACP.Methods.sessionLoad,
            params: CLIACP.LoadSessionRequest(
                sessionId: "ses_loaded",
                cwd: "/workspace",
                additionalDirectories: ["/shared/lib"]
            ),
            as: CLIACP.LoadSessionResponse.self
        )
        #expect(loaded.configOptions.first(where: { $0.id == "model" })?.currentValue == "test/second-model")
        #expect(loaded.configOptions.first(where: { $0.id == "effort" })?.currentValue == "medium")
        #expect(loaded.configOptions.first(where: { $0.id == "mode" })?.currentValue == "plan")

        // Additional directories replaced `/old` with `/shared/lib` while keeping `host: tui` and `*.secret` deny rule!
        let updatedSession = try #require(backend.getSession("ses_loaded"))
        #expect(updatedSession.metadata?["host"] == .string("tui"))
        #expect(CLIACP.Directories.list(updatedSession) == ["/shared/lib"])
        #expect(updatedSession.permissions?.contains { $0.resource == "*.secret" && $0.effect == .deny } == true)
        #expect(updatedSession.permissions?.contains { $0.resource == "/old/*" } == false)

        // All 200 user messages + assistant text + reasoning + tool_call + tool_call_update with CRLF diff replayed!
        let userChunks = wire.updates.filter { $0.sessionId == "ses_loaded" && $0.update.sessionUpdateKind == "user_message_chunk" }
        #expect(userChunks.count == 200)
        let toolCompleted = wire.updates.compactMap { note -> CLIACP.ToolCallUpdate? in
            if case .toolCallUpdate(let tu) = note.update, tu.toolCallId == "call_edit" { return tu }
            return nil
        }.first
        let diffContent = toolCompleted?.content?.compactMap { item -> CLIACP.DiffContent? in
            if case .diff(let d) = item { return d }
            return nil
        }.first
        #expect(diffContent == CLIACP.DiffContent(path: editedPath, oldText: "one\r\ntwo\r\n", newText: "one\r\nthree\r\n"))

        // Fork does not replay history and replaces inherited additionalDirectories.
        let forked = try await wire.peer.request(
            CLIACP.Methods.sessionFork,
            params: CLIACP.ForkSessionRequest(sessionId: "ses_loaded", cwd: "/workspace"),
            as: CLIACP.ForkSessionResponse.self
        )
        #expect(forked.sessionId != "ses_loaded")
        #expect(wire.updates.filter { $0.sessionId == forked.sessionId && $0.update.sessionUpdateKind == "user_message_chunk" }.isEmpty)
        let forkedSession = try #require(backend.getSession(forked.sessionId))
        #expect(CLIACP.Directories.list(forkedSession).isEmpty)

        // Resume with identical directories is a no-op on session.update.
        let updatesBeforeResume = backend.sessionUpdateCount
        _ = try await wire.peer.request(
            CLIACP.Methods.sessionResume,
            params: CLIACP.ResumeSessionRequest(
                sessionId: "ses_loaded",
                cwd: "/workspace",
                additionalDirectories: ["/shared/lib"]
            ),
            as: CLIACP.ResumeSessionResponse.self
        )
        #expect(backend.sessionUpdateCount == updatesBeforeResume)
    }

    // MARK: - 5. Model, Effort & Mode Config Options & Catalog Reload

    @Test("ConfigOption parses slash-containing model IDs, builds effort options, and reloads stale catalog")
    func configOptionsAndCatalogReload() async throws {
        let slashModel = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "claude/sonnet-4"),
            modelID: ModelSchema.ID(rawValue: "claude/sonnet-4"),
            providerID: ProviderSchema.ID(rawValue: "anthropic"),
            name: "Claude Sonnet 4",
            capabilities: ModelSchema.Capabilities.default(),
            variants: [
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "default")),
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "high")),
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "very-high")),
            ],
            time: ModelSchema.Info.Time(released: 0),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 200_000, output: 16_000)
        )
        let parsedExact = CLIACP.ConfigOption.parseModelSelection("anthropic/claude/sonnet-4", models: [slashModel])
        #expect(parsedExact == ModelSchema.Ref(id: .init(rawValue: "claude/sonnet-4"), providerID: .anthropic))

        let parsedVariant = CLIACP.ConfigOption.parseModelSelection("anthropic/claude/sonnet-4/very-high", models: [slashModel])
        #expect(
            parsedVariant == ModelSchema.Ref(
                id: .init(rawValue: "claude/sonnet-4"),
                providerID: .anthropic,
                variant: .init(rawValue: "very-high")
            )
        )

        let wire = CLIACPWireFixture()
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        // Add a new model on the server AFTER session/new; set_config_option retries with catalog reload!
        wire.backend.addModel(slashModel)
        let setModel = try await wire.peer.request(
            CLIACP.Methods.sessionSetConfigOption,
            params: CLIACP.SetSessionConfigOptionRequest(
                sessionId: session.sessionId,
                configId: "model",
                value: "anthropic/claude/sonnet-4/very-high"
            ),
            as: CLIACP.SetSessionConfigOptionResponse.self
        )
        #expect(setModel.configOptions.first(where: { $0.id == "model" })?.currentValue == "anthropic/claude/sonnet-4")
        let effortOpt = try #require(setModel.configOptions.first(where: { $0.id == "effort" }))
        #expect(effortOpt.currentValue == "very-high")
        #expect(effortOpt.options.first(where: { $0.value == "very-high" })?.name == "Very High")

        _ = try await wire.peer.request(
            CLIACP.Methods.sessionSetMode,
            params: CLIACP.SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"),
            as: CLIACP.SetSessionModeResponse.self
        )
        #expect(wire.backend.switchedAgents.last?.1 == "plan")

        // Unknown config option -> -32602
        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionSetConfigOption,
                params: CLIACP.SetSessionConfigOptionRequest(
                    sessionId: session.sessionId,
                    configId: "nonexistent",
                    value: "x"
                ),
                as: CLIACP.SetSessionConfigOptionResponse.self
            )
            Issue.record("Expected unknown config option error")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
            #expect(err.data == .object(["configId": .string("nonexistent")]))
        }
    }

    // MARK: - 6. Content Translation & Prompt Preparation

    @Test("Content maps annotations, zed links, file resources with line anchors, and round-trips replay chunks")
    func contentAndPromptPreparation() async throws {
        let blocks: [CLIACP.ContentBlock] = [
            .text(text: "visible text"),
            .text(text: "embedded ctx", annotations: CLIACP.ContentAnnotations(audience: ["assistant"])),
            .text(text: "ui only", annotations: CLIACP.ContentAnnotations(audience: ["user"])),
            .resourceLink(CLIACP.ResourceLink(uri: "zed://file?path=/workspace/a.swift", name: "a.swift", mimeType: "text/x-swift")),
            .resource(.text(uri: "file:///workspace/b.swift#L42", text: "let x = 1", mimeType: "text/x-swift")),
            .image(mimeType: "image/png", data: "AAAA", uri: "file:///workspace/shot.png"),
        ]
        let parts = CLIACP.Content.promptContentToParts(blocks)
        #expect(parts.count == 6)
        #expect(parts[1] == .text(text: "embedded ctx", synthetic: true))
        #expect(parts[2] == .text(text: "ui only", ignored: true))
        #expect(parts[3] == .file(url: "file:///workspace/a.swift", filename: "a.swift", mime: "text/x-swift"))
        #expect(parts[4] == .text(text: "[/workspace/b.swift:42]\nlet x = 1"))
        #expect(parts[5] == .file(url: "data:image/png;base64,AAAA", filename: "shot.png", mime: "image/png"))

        // Replay conversion round-trips text, reasoning, file://, image, and inline text/blob data URIs.
        let chunks = CLIACP.Content.partsToContentChunks([
            .text(text: "sys", synthetic: true),
            .reasoning(text: "think"),
            .file(url: "file:///workspace/note.md", filename: "note.md", mime: "text/markdown"),
            .file(url: "data:text/plain;base64,aGVsbG8=", filename: "inline.txt", mime: "text/plain"),
            .file(url: "data:image/png;base64,AAAA", filename: "pic.png", mime: "image/png"),
        ])
        #expect(chunks.count == 5)
        if case .resource(.text(_, let text, let mime)) = chunks[3].content {
            #expect(text == "hello")
            #expect(mime == "text/plain")
        } else {
            Issue.record("Expected decoded text resource chunk")
        }

        // Prompt.prepare checks unreadable file fallback, detects /compact, and rejects empty images.
        let fs = CLIACPTestFS(files: ["/workspace/readable.txt": "ok"])
        let catalog = CLIACP.CatalogStore.Catalog(
            models: CLIACPTestBackend.defaultModels(),
            defaultModel: ModelSchema.Ref(id: .init(rawValue: "first-model"), providerID: .init(rawValue: "test")),
            modes: [CLIACP.CatalogStore.Mode(id: .init(rawValue: "build"), name: "Build")],
            defaultModeID: .init(rawValue: "build"),
            commands: CLIACPTestBackend.defaultCommands()
        )
        let prepared = try await CLIACP.Prompt.prepare(
            catalog: catalog,
            content: [
                .text(text: "read files"),
                .resourceLink(CLIACP.ResourceLink(uri: "file:///workspace/readable.txt", name: "readable.txt")),
                .resourceLink(CLIACP.ResourceLink(uri: "file:///workspace/missing.txt", name: "missing.txt")),
                .text(text: "hidden ctx", annotations: CLIACP.ContentAnnotations(audience: ["assistant"])),
            ],
            fileSystem: fs
        )
        #expect(prepared.files.count == 1)
        #expect(prepared.files[0].uri == "file:///workspace/readable.txt")
        #expect(prepared.text.contains("[missing.txt](file:///workspace/missing.txt)"))
        #expect(prepared.synthetic == ["hidden ctx"])

        let compactPrepared = try await CLIACP.Prompt.prepare(
            catalog: catalog,
            content: [.text(text: "/compact")],
            fileSystem: fs
        )
        #expect(compactPrepared.start.type == .compaction)

        do {
            _ = try await CLIACP.Prompt.prepare(
                catalog: catalog,
                content: [.image(mimeType: "image/png", data: nil, uri: nil)],
                fileSystem: fs
            )
            Issue.record("Expected empty image error")
        } catch let err {
            #expect(err == .invalidRequest(.init(message: "image content has no data or uri", field: "prompt")))
        }
    }

    // MARK: - 7. End-to-End Prompt Streaming, Usage, Steering, Compaction & Cancellation

    @Test("session/prompt streams reasoning, text, tool lifecycle, usage_update, and reports token usage")
    func promptTurnStreamingAndUsage() async throws {
        let backend = CLIACPTestBackend()
        backend.setHooks(onPrompt: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                CLIACPTestEvents.reasoningDelta(sessionID: req.sessionID, messageID: "msg_a", delta: "think-0", ordinal: 0),
                CLIACPTestEvents.textDelta(sessionID: req.sessionID, messageID: "msg_a", delta: "hello ", ordinal: 1),
                CLIACPTestEvents.reasoningDelta(sessionID: req.sessionID, messageID: "msg_a", delta: "think-1", ordinal: 1),
                CLIACPTestEvents.toolStarted(sessionID: req.sessionID, id: "call_1", name: "bash"),
                CLIACPTestEvents.toolCalled(sessionID: req.sessionID, id: "call_1", input: ["command": .string("echo hi"), "workdir": .string("sub")]),
                CLIACPTestEvents.toolProgress(sessionID: req.sessionID, id: "call_1", metadata: ["phase": .int(1)]),
                CLIACPTestEvents.toolSucceeded(sessionID: req.sessionID, id: "call_1", metadata: ["exit": .int(0)], text: "hi"),
                CLIACPTestEvents.stepEnded(
                    sessionID: req.sessionID,
                    messageID: "msg_a",
                    finish: "stop",
                    input: 100,
                    output: 40,
                    reasoning: 7,
                    cacheRead: 11,
                    cacheWrite: 13
                ),
                CLIACPTestEvents.succeeded(sessionID: req.sessionID),
            ]
        })

        let wire = CLIACPWireFixture(backend: backend)
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let created = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let resp = try await wire.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: created.sessionId, prompt: [.text(text: "hi")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(resp.stopReason == .endTurn)
        #expect(resp.usage?.inputTokens == 100)
        #expect(resp.usage?.outputTokens == 40)
        #expect(resp.usage?.thoughtTokens == 7)
        #expect(resp.usage?.cachedReadTokens == 11)
        #expect(resp.usage?.cachedWriteTokens == 13)
        #expect(resp.usage?.totalTokens == 171)

        let kinds = wire.updates
            .filter { $0.update.sessionUpdateKind != "available_commands_update" }
            .map(\.update.sessionUpdateKind)
        #expect(kinds == [
            "agent_thought_chunk",
            "agent_message_chunk",
            "agent_thought_chunk",
            "tool_call",
            "tool_call_update",
            "tool_call_update",
            "tool_call_update",
            "usage_update",
        ])

        // Check reasoning ordinals & V1 bash -> shell/execute mapping + workdir location resolution.
        let thoughtIDs = wire.updates.compactMap { note -> String? in
            if case .agentThoughtChunk(let id, _, _) = note.update { return id }
            return nil
        }
        #expect(thoughtIDs == ["msg_a:reasoning:0", "msg_a:reasoning:1"])

        let runningTool = wire.updates.compactMap { note -> CLIACP.ToolCallUpdate? in
            if case .toolCallUpdate(let tu) = note.update, tu.status == .inProgress { return tu }
            return nil
        }.first
        #expect(runningTool?.kind == .execute)
        #expect(runningTool?.title == "echo hi")
        #expect(runningTool?.locations == [CLIACP.ToolCallLocation(path: "/workspace/sub")])
    }

    @Test("steering returns promptRequired when idle and injects with resume=false when active")
    func steeringIdleAndActive() async throws {
        let wire = CLIACPWireFixture()
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let idleResp = try await wire.peer.request(
            CLIACP.Methods.sessionSteering,
            params: CLIACP.Turn.SteeringRequest(sessionId: session.sessionId, prompt: [.text(text: "redirect")]),
            as: CLIACP.Turn.SteeringResponse.self
        )
        #expect(idleResp == .promptRequired(reason: "noRunningTurn"))

        wire.backend.setActive(sessionID: session.sessionId, active: true)
        let injected = try await wire.peer.request(
            CLIACP.Methods.sessionSteering,
            params: CLIACP.Turn.SteeringRequest(
                sessionId: session.sessionId,
                prompt: [
                    .text(text: "ctx", annotations: CLIACP.ContentAnnotations(audience: ["assistant"])),
                    .text(text: "change course"),
                ]
            ),
            as: CLIACP.Turn.SteeringResponse.self
        )
        #expect(injected == .injected)
        #expect(wire.backend.synthetics.count == 1)
        #expect(wire.backend.synthetics[0].resume == false)
        #expect(wire.backend.prompts.count == 1)
        #expect(wire.backend.prompts[0].text == "change course")
        #expect(wire.backend.prompts[0].delivery == .steer)
        #expect(wire.backend.prompts[0].resume == false)
    }

    @Test("session/cancel interrupts running turn and abandons stuck tools on drain timeout")
    func cancelTurnAndAbandonTools() async throws {
        let backend = CLIACPTestBackend()
        backend.setHooks(
            onPrompt: { req in
                [
                    CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                    CLIACPTestEvents.toolStarted(sessionID: req.sessionID, id: "call_hang", name: "shell"),
                    CLIACPTestEvents.toolCalled(sessionID: req.sessionID, id: "call_hang", input: ["command": .string("sleep 99")]),
                ]
            },
            onInterrupt: { _ in
                // Deliberately do not send session.execution.interrupted so drain timeout triggers abandon!
                []
            }
        )

        let wire = CLIACPWireFixture(backend: backend, drainTimeoutNanoseconds: 60_000_000)
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let promptTask = Task {
            try await wire.peer.request(
                CLIACP.Methods.sessionPrompt,
                params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "hang")]),
                as: CLIACP.PromptResponse.self
            )
        }

        let started = await wire.waitUntil {
            wire.updates.contains {
                if case .toolCallUpdate(let tu) = $0.update, tu.toolCallId == "call_hang", tu.status == .inProgress {
                    return true
                }
                return false
            }
        }
        #expect(started)

        try await wire.peer.notify(CLIACP.Methods.sessionCancel, params: CLIACP.CancelNotification(sessionId: session.sessionId))
        let result = try await promptTask.value
        #expect(result.stopReason == .cancelled)
        #expect(backend.interrupts == [session.sessionId])

        let abandoned = wire.updates.contains {
            if case .toolCallUpdate(let tu) = $0.update,
               tu.toolCallId == "call_hang",
               tu.status == .failed,
               tu.rawOutput?["error"] == .string("Cancelled")
            {
                return true
            }
            return false
        }
        #expect(abandoned)
    }

    @Test("Compaction emits standard updates when supported and legacy markers when unsupported")
    func compactionStandardAndLegacyUpdates() async throws {
        // 1. Standard client with compaction: {}
        let backendStd = CLIACPTestBackend()
        backendStd.setHooks(onCompact: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                OpenCodeEvent(
                    id: "evt_c1",
                    type: "session.compaction.started",
                    data: .object(["sessionID": .string(req.sessionID), "reason": .string("manual"), "inputID": .string(req.id)])
                ),
                OpenCodeEvent(
                    id: "evt_c2",
                    type: "session.compaction.delta",
                    data: .object(["sessionID": .string(req.sessionID), "text": .string("Summary text")])
                ),
                OpenCodeEvent(
                    id: "evt_c3",
                    type: "session.compaction.ended",
                    data: .object(["sessionID": .string(req.sessionID), "reason": .string("manual"), "text": .string("Summary text")])
                ),
                CLIACPTestEvents.succeeded(sessionID: req.sessionID),
            ]
        })
        let wireStd = CLIACPWireFixture(backend: backendStd)
        defer { Task { await wireStd.close() } }
        _ = try await wireStd.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: CLIACP.ClientCapabilities(
                    session: CLIACP.ClientSessionCapabilities(compaction: .object([:]))
                )
            ),
            as: CLIACP.InitializeResponse.self
        )
        let sesStd = try await wireStd.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )
        let respStd = try await wireStd.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: sesStd.sessionId, prompt: [.text(text: "/compact")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(respStd.stopReason == .endTurn)
        let stdKinds = wireStd.updates
            .filter { $0.update.sessionUpdateKind != "available_commands_update" }
            .map(\.update.sessionUpdateKind)
        #expect(stdKinds == ["compaction_update", "compaction_summary_chunk", "compaction_update"])

        // 2. Legacy client with compaction: null -> session_info_update markers only
        let backendLeg = CLIACPTestBackend()
        backendLeg.setHooks(onCompact: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                OpenCodeEvent(
                    id: "evt_c1",
                    type: "session.compaction.started",
                    data: .object(["sessionID": .string(req.sessionID), "reason": .string("manual"), "inputID": .string(req.id)])
                ),
                OpenCodeEvent(
                    id: "evt_c2",
                    type: "session.compaction.delta",
                    data: .object(["sessionID": .string(req.sessionID), "text": .string("ignored delta")])
                ),
                OpenCodeEvent(
                    id: "evt_c3",
                    type: "session.compaction.ended",
                    data: .object(["sessionID": .string(req.sessionID), "reason": .string("manual"), "text": .string("Summary text")])
                ),
                CLIACPTestEvents.succeeded(sessionID: req.sessionID),
            ]
        })
        let wireLeg = CLIACPWireFixture(backend: backendLeg)
        defer { Task { await wireLeg.close() } }
        _ = try await wireLeg.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: CLIACP.ClientCapabilities(
                    session: CLIACP.ClientSessionCapabilities(compaction: .null)
                )
            ),
            as: CLIACP.InitializeResponse.self
        )
        let sesLeg = try await wireLeg.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )
        _ = try await wireLeg.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: sesLeg.sessionId, prompt: [.text(text: "/compact")]),
            as: CLIACP.PromptResponse.self
        )
        let legKinds = wireLeg.updates
            .filter { $0.update.sessionUpdateKind != "available_commands_update" }
            .map(\.update.sessionUpdateKind)
        #expect(legKinds == ["session_info_update", "session_info_update"])
    }

    // MARK: - 8. Child Session Routing, Permissions & Elicitation

    @Test("Permissions bridge translates tool calls, diff previews, allow/reject/cancel, and child updates")
    func permissionAndChildSessionRouting() async throws {
        let patchText = """
            *** Begin Patch
            *** Add File: new.txt
            +hello
            *** End Patch
            """
        let backend = CLIACPTestBackend()
        backend.setHooks(onPrompt: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                CLIACPTestEvents.childCreated(id: "ses_child", parentID: req.sessionID, title: "Explore"),
                CLIACPTestEvents.childStarted(id: "ses_child"),
                CLIACPTestEvents.toolStarted(sessionID: "ses_child", id: "call_p", name: "patch"),
                CLIACPTestEvents.toolCalled(sessionID: "ses_child", id: "call_p", input: ["patchText": .string(patchText)]),
                CLIACPTestEvents.permissionAsked(
                    sessionID: "ses_child",
                    id: "per_1",
                    action: "patch",
                    sourceToolID: "call_p"
                ),
                CLIACPTestEvents.permissionAsked(sessionID: req.sessionID, id: "per_2", action: "shell"),
                CLIACPTestEvents.succeeded(sessionID: "ses_child"),
                CLIACPTestEvents.succeeded(sessionID: req.sessionID),
            ]
        })

        let wire = CLIACPWireFixture(
            backend: backend,
            permissionHandler: { req, _ in
                if req.toolCall.toolCallId == "ses_child:call_p" {
                    return CLIACP.RequestPermissionResponse(outcome: .selected(optionId: "always"))
                }
                return CLIACP.RequestPermissionResponse(outcome: .cancelled)
            }
        )
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: CLIACP.ClientCapabilities(
                    _meta: [CLIACP.Capabilities.childSessionUpdatesKey: .bool(true)]
                )
            ),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let resp = try await wire.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "go")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(resp.stopReason == .endTurn)
        #expect(wire.permissions.count == 2)

        let firstPerm = wire.permissions[0]
        #expect(firstPerm.toolCall.toolCallId == "ses_child:call_p")
        #expect(firstPerm.toolCall.title == "Explore: /workspace/new.txt")
        #expect(firstPerm.toolCall.content == [.diff(CLIACP.DiffContent(path: "/workspace/new.txt", oldText: nil, newText: "hello\n"))])
        #expect(firstPerm.toolCall._meta?["opencode/child-session"] != nil)

        #expect(backend.permissionReplies == [
            CLIACPRecordedPermissionReply(sessionID: "ses_child", requestID: "per_1", decision: .always),
            CLIACPRecordedPermissionReply(sessionID: session.sessionId, requestID: "per_2", decision: .reject),
        ])
        #expect(wire.childUpdates.contains { $0.childSessionId == "ses_child" && $0.event == .status(.created) })
        #expect(wire.childUpdates.contains { $0.childSessionId == "ses_child" && $0.event == .status(.completed) })
    }

    @Test("Elicitation blocks credential fields, cancels unshown question forms, and maps custom answers")
    func elicitationFilteringAndWireFlow() async throws {
        let capable = CLIACP.Capabilities.Parsed(childSessionUpdates: false, formElicitation: true, compaction: false)

        // Credential fields and unknown form kinds must return nil schema.
        let credForm = CLIACP.Elicitation.AskedForm(
            id: "frm_cred",
            sessionID: "ses_1",
            title: "Secrets",
            metadata: ["kind": .string("question")],
            fields: [.string(FormSchema.StringField(key: "api_key", title: "Key"))]
        )
        #expect(CLIACP.Elicitation.requestedSchema(form: credForm, capabilities: capable) == nil)

        let unknownKind = CLIACP.Elicitation.AskedForm(
            id: "frm_other",
            sessionID: "ses_1",
            title: "MCP",
            metadata: ["kind": .string("mcp-elicitation")],
            fields: [.string(FormSchema.StringField(key: "name"))]
        )
        #expect(CLIACP.Elicitation.requestedSchema(form: unknownKind, capabilities: capable) == nil)

        // End-to-end question form with string + multiselect custom answers!
        let questionForm = CLIACP.Elicitation.AskedForm(
            id: "frm_q1",
            sessionID: "ses_test_1",
            title: "Questions",
            metadata: [
                "kind": .string("question"),
                "tool": .object(["messageID": .string("msg_a"), "id": .string("call_q")]),
            ],
            fields: [
                .string(
                    FormSchema.StringField(
                        key: "q0",
                        title: "Runtime",
                        options: [
                            FormSchema.Option(value: "Bun", label: "Bun"),
                            FormSchema.Option(value: "Swift", label: "Swift"),
                        ],
                        custom: true
                    )
                ),
                .multiselect(
                    FormSchema.MultiselectField(
                        key: "q1",
                        title: "Goals",
                        options: [FormSchema.Option(value: "Fast", label: "Fast")],
                        custom: true
                    )
                ),
            ]
        )

        let backend = CLIACPTestBackend()
        backend.setHooks(
            onPrompt: { req in
                [
                    CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                    CLIACPTestEvents.toolStarted(sessionID: req.sessionID, id: "call_q", name: "question"),
                    CLIACPTestEvents.formCreated(
                        CLIACP.Elicitation.AskedForm(
                            id: questionForm.id,
                            sessionID: req.sessionID,
                            title: questionForm.title,
                            metadata: questionForm.metadata,
                            fields: questionForm.fields
                        )
                    ),
                ]
            },
            onFormReply: { rep in
                [
                    CLIACPTestEvents.formReplied(sessionID: rep.sessionID, id: rep.formID),
                    CLIACPTestEvents.toolSucceeded(sessionID: rep.sessionID, id: "call_q", text: "answered"),
                    CLIACPTestEvents.succeeded(sessionID: rep.sessionID),
                ]
            }
        )

        let wire = CLIACPWireFixture(
            backend: backend,
            elicitationHandler: { _, _ in
                CLIACP.CreateElicitationResponse(
                    action: "accept",
                    content: [
                        "q0": .string("Swift"),
                        "q1": .array([.string("Fast")]),
                        "q1_custom": .string("Portable"),
                    ]
                )
            }
        )
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: CLIACP.ClientCapabilities(
                    elicitation: CLIACP.ClientElicitationCapabilities(form: .object([:]))
                )
            ),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let resp = try await wire.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "ask me")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(resp.stopReason == .endTurn)
        #expect(wire.elicitations.count == 1)
        #expect(wire.elicitations[0].toolCallId == "call_q")
        #expect(wire.elicitations[0].requestedSchema.properties["q0_custom"] != nil)
        #expect(backend.formReplies.count == 1)
        #expect(backend.formReplies[0].answer["q0"] == .string("Swift"))
        #expect(backend.formReplies[0].answer["q1"] == .strings(["Fast", "Portable"]))

        // Unshown question form cancels with UnshownQuestionMessage.
        await CLIACP.Elicitation.cancelUnshown(client: backend, form: questionForm)
        #expect(backend.formCancels.last?.message == CLIACP.Elicitation.unshownQuestionMessage)
    }

    // MARK: - 9. Translator Edge Cases & Unified Diff Engine

    @Test("Translate handles retry metadata, auth failure, refusal, length stop, and readDisplayText")
    func translateEdgeCasesAndReadDisplayText() {
        let root = SessionID(rawValue: "ses_root")!
        let start = CLIACP.Translate.TurnStart(type: .input, id: SessionMessageSchema.ID(rawValue: "msg_in")!)
        let ctx = CLIACP.Translate.TurnContext(sessionID: root, cwd: "/workspace", start: start)

        // Events before matching delivery are ignored.
        let early = CLIACP.Translate.fold(
            CLIACP.Translate.initial,
            event: CLIACPTestEvents.textDelta(sessionID: root.rawValue, messageID: "msg_1", delta: "ignored"),
            ctx: ctx
        )
        #expect(early.outputs.isEmpty)

        // Deliver -> retry scheduled -> step started clears retry -> step ended (length) -> succeeded.
        var state = CLIACP.Translate.fold(
            CLIACP.Translate.initial,
            event: CLIACPTestEvents.delivered(sessionID: root.rawValue, inboxID: "msg_in"),
            ctx: ctx
        ).state
        let retryFold = CLIACP.Translate.fold(
            state,
            event: CLIACPTestEvents.retryScheduled(sessionID: root.rawValue, attempt: 1, atMs: 0, type: "provider.transport", message: "lost"),
            ctx: ctx
        )
        state = retryFold.state
        #expect(state.retries[root.rawValue]?.nextRetryAt == "1970-01-01T00:00:00.000Z")

        let clearedFold = CLIACP.Translate.fold(state, event: CLIACPTestEvents.stepStarted(sessionID: root.rawValue), ctx: ctx)
        state = clearedFold.state
        #expect(state.retries[root.rawValue] == nil)

        state = CLIACP.Translate.fold(
            state,
            event: CLIACPTestEvents.stepEnded(sessionID: root.rawValue, finish: "length"),
            ctx: ctx
        ).state
        let endFold = CLIACP.Translate.fold(state, event: CLIACPTestEvents.succeeded(sessionID: root.rawValue), ctx: ctx)
        #expect(endFold.terminal == .succeeded)
        #expect(CLIACP.Translate.response(endFold.state, sessionID: root.rawValue, terminal: .succeeded).stopReason == .maxTokens)

        // Auth failure -> AuthRequiredError; content-filter failure -> refusal with nil failure.
        var authState = CLIACP.Translate.fold(
            CLIACP.Translate.initial,
            event: CLIACPTestEvents.delivered(sessionID: root.rawValue, inboxID: "msg_in"),
            ctx: ctx
        ).state
        authState = CLIACP.Translate.fold(
            authState,
            event: CLIACPTestEvents.failed(sessionID: root.rawValue, type: "provider.auth", message: "missing key"),
            ctx: ctx
        ).state
        #expect(CLIACP.Translate.failure(authState) == .authRequired(.init()))

        var filterState = CLIACP.Translate.fold(
            CLIACP.Translate.initial,
            event: CLIACPTestEvents.delivered(sessionID: root.rawValue, inboxID: "msg_in"),
            ctx: ctx
        ).state
        filterState = CLIACP.Translate.fold(
            filterState,
            event: CLIACPTestEvents.failed(sessionID: root.rawValue, type: "provider.content-filter", message: "blocked"),
            ctx: ctx
        ).state
        #expect(CLIACP.Translate.failure(filterState) == nil)
        #expect(CLIACP.Translate.response(filterState, sessionID: root.rawValue, terminal: .failed).stopReason == .refusal)

        // ToolMapper read tool normalizes JSON envelope via TUIMini.readDisplayText.
        let readCompleted = CLIACP.ToolMapper.completedToolUpdate(
            toolCallId: "call_r",
            toolName: "read",
            input: ["filePath": .string("src/app.swift")],
            content: [.text("{\"type\":\"text-page\",\"content\":\"line1\\nline2\"}")],
            cwd: "/workspace"
        )
        #expect(readCompleted.locations == [CLIACP.ToolCallLocation(path: "/workspace/src/app.swift")])
        #expect(readCompleted.content == [.content(.text(text: "line1\nline2"))])
    }

    @Test("UnifiedDiff parses, applies, reverses, and builds structured patches preserving line endings")
    func unifiedDiffRoundtrip() throws {
        let oldStr = "alpha\nbeta\ngamma\n"
        let newStr = "alpha\nbeta-edited\ngamma\ndelta\n"
        let patch = CLIACP.UnifiedDiff.structuredPatch(
            oldFileName: "a.txt",
            newFileName: "a.txt",
            oldStr: oldStr,
            newStr: newStr
        )
        #expect(CLIACP.UnifiedDiff.applyPatch(oldStr, patch) == newStr)
        let reversed = CLIACP.UnifiedDiff.reversePatch(patch)
        #expect(CLIACP.UnifiedDiff.applyPatch(newStr, reversed) == oldStr)

        // No trailing newline round-trip
        let noNL = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,2 @@
             keep
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """
        let parsed = try #require(CLIACP.UnifiedDiff.parsePatch(noNL).first)
        #expect(CLIACP.UnifiedDiff.applyPatch("keep\nold", parsed) == "keep\nnew")
        #expect(CLIACP.UnifiedDiff.applyPatch("keep\nnew", CLIACP.UnifiedDiff.reversePatch(parsed)) == "keep\nold")
    }

    // MARK: - 10. Concurrency, Event Loss, Cancel-Request, Background Children & Commands

    @Test("Concurrent prompt on same session fails and stream closure mid-turn reports ServerUnavailable")
    func concurrentPromptAndServerUnavailable() async throws {
        let backend = CLIACPTestBackend()
        backend.setHooks(onPrompt: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                CLIACPTestEvents.textDelta(sessionID: req.sessionID, messageID: "msg_held", delta: "working"),
            ]
        })

        let wire = CLIACPWireFixture(backend: backend)
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let firstPrompt = Task {
            try await wire.peer.request(
                CLIACP.Methods.sessionPrompt,
                params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "hold")]),
                as: CLIACP.PromptResponse.self
            )
        }
        let streaming = await wire.waitUntil {
            wire.updates.contains { $0.update.sessionUpdateKind == "agent_message_chunk" }
        }
        #expect(streaming)

        // Second concurrent prompt must be rejected with -32603.
        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionPrompt,
                params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "second")]),
                as: CLIACP.PromptResponse.self
            )
            Issue.record("Expected concurrent prompt rejection")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32603)
            #expect(err.message.contains("already has an active ACP prompt"))
        }

        // Closing the backend event stream mid-turn reports ServerUnavailable (-32603).
        backend.closeAllEventStreams()
        do {
            _ = try await firstPrompt.value
            Issue.record("Expected ServerUnavailable on stream close")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32603)
            #expect(err.data == .object(["errorName": .string("ServerUnavailable")]))
        }

        backend.setFailListWithUnavailable(true)
        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionList,
                params: CLIACP.ListSessionsRequest(),
                as: CLIACP.ListSessionsResponse.self
            )
            Issue.record("Expected ServerUnavailable on transport error")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32603)
            #expect(err.data == .object(["errorName": .string("ServerUnavailable")]))
        }
    }

    @Test("Cancelling a turn with pending and queued permissions sends $/cancel_request and rejects both")
    func cancelTurnCancelsPendingPermissionAndRejectsQueued() async throws {
        let backend = CLIACPTestBackend()
        backend.setHooks(
            onPrompt: { req in
                [
                    CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                    CLIACPTestEvents.permissionAsked(sessionID: req.sessionID, id: "per_pending", action: "shell"),
                    CLIACPTestEvents.permissionAsked(sessionID: req.sessionID, id: "per_queued", action: "shell"),
                ]
            },
            onInterrupt: { sid in
                [CLIACPTestEvents.interrupted(sessionID: sid)]
            }
        )

        let wire = CLIACPWireFixture(
            backend: backend,
            permissionHandler: { _, signal in
                // Wait until cancelled via $/cancel_request!
                while !signal.isAborted && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return CLIACP.RequestPermissionResponse(outcome: .cancelled)
            }
        )
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let promptTask = Task {
            try await wire.peer.request(
                CLIACP.Methods.sessionPrompt,
                params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "hello")]),
                as: CLIACP.PromptResponse.self
            )
        }
        let askedOne = await wire.waitUntil { wire.permissions.count == 1 }
        #expect(askedOne)

        try await wire.peer.notify(
            CLIACP.Methods.sessionCancel,
            params: CLIACP.CancelNotification(sessionId: session.sessionId)
        )
        let resp = try await promptTask.value
        #expect(resp.stopReason == .cancelled)

        let bothReplied = await wire.waitUntil { backend.permissionReplies.count == 2 }
        #expect(bothReplied)
        #expect(backend.permissionReplies.map(\.requestID) == ["per_pending", "per_queued"])
        #expect(backend.permissionReplies.allSatisfy { $0.decision == .reject })
        // Only the first ask reached the client; queued ask was settled without being sent.
        #expect(wire.permissions.count == 1)
        let sentCancelNotif = wire.peer.receivedMessages.contains { msg in
            if case .notification(let method, _) = msg, method == CLIACP.Methods.cancelRequest { return true }
            return false
        }
        #expect(sentCancelNotif)
    }

    @Test("Non-child-capable client receives projected child tool updates and background child permissions")
    func projectedChildUpdatesAndBackgroundHandoff() async throws {
        let backend = CLIACPTestBackend()
        backend.setHooks(onPrompt: { req in
            [
                CLIACPTestEvents.delivered(sessionID: req.sessionID, inboxID: req.id),
                CLIACPTestEvents.childCreated(id: "ses_child", parentID: req.sessionID, title: "Worker"),
                CLIACPTestEvents.childStarted(id: "ses_child"),
                CLIACPTestEvents.toolStarted(sessionID: "ses_child", id: "call_r", name: "read"),
                CLIACPTestEvents.toolCalled(sessionID: "ses_child", id: "call_r", input: ["path": .string("/workspace/a.swift")]),
                CLIACPTestEvents.toolSucceeded(sessionID: "ses_child", id: "call_r", text: "ok"),
                CLIACPTestEvents.childCreated(id: "ses_bg", parentID: req.sessionID, title: "Background"),
                CLIACPTestEvents.succeeded(sessionID: "ses_child"),
                CLIACPTestEvents.succeeded(sessionID: req.sessionID),
            ]
        })

        let wire = CLIACPWireFixture(
            backend: backend,
            permissionHandler: { _, _ in
                CLIACP.RequestPermissionResponse(outcome: .selected(optionId: "once"))
            }
        )
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let resp = try await wire.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "work")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(resp.stopReason == .endTurn)
        #expect(wire.childUpdates.isEmpty)

        // Child tool call was projected into parent with prefixed ID, title, and opencode/child-session metadata.
        let projectedCall = wire.updates.compactMap { note -> CLIACP.ToolCall? in
            if case .toolCall(let tc) = note.update, tc.toolCallId == "ses_child:call_r" { return tc }
            return nil
        }.first
        #expect(projectedCall?.title == "Worker: read")
        #expect(projectedCall?._meta?["opencode/child-session"] != nil)

        // Background child continues after parent turn responds and its permission ask still reaches the client!
        backend.sendEvents([
            CLIACPTestEvents.childStarted(id: "ses_bg"),
            CLIACPTestEvents.permissionAsked(sessionID: "ses_bg", id: "per_bg", action: "read", metadata: ["path": .string("/workspace/bg.txt")]),
            CLIACPTestEvents.succeeded(sessionID: "ses_bg"),
        ])
        let bgReplied = await wire.waitUntil {
            backend.permissionReplies.contains { $0.requestID == "per_bg" && $0.decision == .once }
        }
        #expect(bgReplied)
    }

    @Test("Custom slash command dispatches session/command, session/delete detaches, and unknown RPC fails -32601")
    func slashCommandDeleteAndUnknownMethod() async throws {
        let wire = CLIACPWireFixture()
        defer { Task { await wire.close() } }
        _ = try await wire.peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        let session = try await wire.peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )

        let cmdResp = try await wire.peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(sessionId: session.sessionId, prompt: [.text(text: "/review staged diff")]),
            as: CLIACP.PromptResponse.self
        )
        #expect(cmdResp.stopReason == .endTurn)
        #expect(wire.backend.submittedCommands.count == 1)
        #expect(wire.backend.submittedCommands[0].name == "review")
        #expect(wire.backend.submittedCommands[0].text == "staged diff")

        // Delete removes and detaches the session.
        _ = try await wire.peer.request(
            CLIACP.Methods.sessionDelete,
            params: CLIACP.DeleteSessionRequest(sessionId: session.sessionId),
            as: CLIACP.DeleteSessionResponse.self
        )
        #expect(wire.backend.getSession(session.sessionId) == nil)

        do {
            _ = try await wire.peer.request(
                CLIACP.Methods.sessionSetMode,
                params: CLIACP.SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"),
                as: CLIACP.SetSessionModeResponse.self
            )
            Issue.record("Expected session not found after delete")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32602)
            #expect(err.data == .object(["sessionId": .string(session.sessionId)]))
        }

        // Unknown RPC method returns -32601.
        do {
            _ = try await wire.peer.requestRaw("nonexistent/rpc", params: .object([:]))
            Issue.record("Expected method not found error")
        } catch let err as CLIACP.RequestError {
            #expect(err.code == -32601)
        }
    }
}
