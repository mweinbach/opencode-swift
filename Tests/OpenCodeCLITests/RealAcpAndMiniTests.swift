import Testing
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

@Suite("Real ACP Bridge & Mini Runtime End-to-End Suite")
struct RealAcpAndMiniTests {

    // MARK: - P0 #8: Real `opencode acp` NDJSON Byte-Stream Bridge

    @Test("opencode acp runs real NDJSON initialize -> session/new -> session/prompt over in-memory byte streams and stops standalone server on EOF")
    func acpRealNdjsonByteStreamRoundTrip() async throws {
        let serverStopped = AtomicFlag(false)
        let transport = MockOpenCodeServerTransport(sessionPrefix: "ses_acp_") { sid, messageID, text, hub in
            let asstID = "msg_asst_acp_1"
            hub.emit(RealTestSSEEvents.inboxDelivered(sessionID: sid, inboxID: messageID))
            hub.emit(RealTestSSEEvents.executionStarted(sessionID: sid))
            hub.emit(RealTestSSEEvents.stepStarted(sessionID: sid, assistantMessageID: asstID))
            hub.emit(RealTestSSEEvents.reasoningDelta(sessionID: sid, assistantMessageID: asstID, delta: "Checking ACP prompt"))
            hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "ACP server "))
            hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "replied to: [\(text)]"))
            hub.emit(RealTestSSEEvents.executionSucceeded(sessionID: sid))
        }
        defer { transport.sseHub.closeAll() }

        let (ctx, _, _) = CLITestFixtures.makeContext(
            transport: transport,
            serverStarter: { _ in
                CLIServices.ServerProcess.StartedServer(
                    url: "http://127.0.0.1:49991",
                    shutdown: { serverStopped.set(true) }
                )
            }
        )

        // Raw byte pipes simulating process stdin (client -> agent) and stdout (agent -> client)
        let clientToAgent = InMemoryBytePipe()
        let agentToClient = InMemoryBytePipe()

        let agentStream = CLIACP.NDJSONStream.fromBytes(
            input: clientToAgent.makeStream(),
            write: { bytes in agentToClient.write(bytes) },
            close: { agentToClient.close() }
        )
        let clientStream = CLIACP.NDJSONStream.fromBytes(
            input: agentToClient.makeStream(),
            write: { bytes in clientToAgent.write(bytes) },
            close: { clientToAgent.close() }
        )

        let updates = SyncCollector<CLIACP.SessionNotification>()
        let peer = CLIACP.PeerClient(
            stream: clientStream,
            onUpdate: { note in updates.append(note) }
        )
        defer { Task { await peer.close() } }

        // Launch the real CLICommands.runACPBridge loop on the in-memory byte stream
        let bridgeTask = Task {
            try await CLICommands.runACPBridge(
                CLIFramework.Runtime.Input(commandPath: ["acp"]),
                context: ctx,
                stream: agentStream
            )
        }

        // 1. JSON-RPC `initialize`
        let initResp = try await peer.request(
            CLIACP.Methods.initialize,
            params: CLIACP.InitializeRequest(protocolVersion: 1),
            as: CLIACP.InitializeResponse.self
        )
        #expect(initResp.protocolVersion == 1)
        #expect(initResp.agentInfo.name == "OpenCode")

        // 2. JSON-RPC `session/new` -> real HTTP POST /api/session
        let newSession = try await peer.request(
            CLIACP.Methods.sessionNew,
            params: CLIACP.NewSessionRequest(cwd: "/workspace"),
            as: CLIACP.NewSessionResponse.self
        )
        #expect(newSession.sessionId == "ses_acp_1")
        #expect(newSession.configOptions.first(where: { $0.id == "model" })?.currentValue == "anthropic/claude-sonnet-4")

        // 3. JSON-RPC `session/prompt` -> real HTTP POST /api/session/ses_acp_1/prompt + SSE event stream
        let promptResp = try await peer.request(
            CLIACP.Methods.sessionPrompt,
            params: CLIACP.PromptRequest(
                sessionId: newSession.sessionId,
                prompt: [.text(text: "Hello real ACP")]
            ),
            as: CLIACP.PromptResponse.self
        )
        #expect(promptResp.stopReason == .endTurn)

        // Verify streamed ACP session/update notifications came from SSE deltas
        let thoughtText = updates.values.compactMap { note -> String? in
            guard note.sessionId == newSession.sessionId else { return nil }
            if case .agentThoughtChunk(messageId: _, content: .text(text: let text, annotations: _), _meta: _) = note.update {
                return text
            }
            return nil
        }.joined()
        let messageText = updates.values.compactMap { note -> String? in
            guard note.sessionId == newSession.sessionId else { return nil }
            if case .agentMessageChunk(messageId: _, content: .text(text: let text, annotations: _), _meta: _) = note.update {
                return text
            }
            return nil
        }.joined()
        #expect(thoughtText == "Checking ACP prompt")
        #expect(messageText == "ACP server replied to: [Hello real ACP]")

        // Verify HTTP requests went to standalone endpoint with Basic Authorization header
        let createReqs = transport.requests.filter { $0.method == "POST" && $0.url.hasSuffix("/api/session") }
        let promptReqs = transport.requests.filter { $0.method == "POST" && $0.url.contains("/api/session/ses_acp_1/prompt") }
        let sseReqs = transport.requests.filter { $0.method == "GET" && $0.url.contains("/api/event") }
        #expect(createReqs.count == 1)
        #expect(promptReqs.count == 1)
        #expect(!sseReqs.isEmpty)
        #expect(createReqs[0].headers["authorization"]?.hasPrefix("Basic ") == true)
        #expect(transport.promptTexts == ["Hello real ACP"])

        // 4. Close stdin byte stream (EOF) -> bridge exits cleanly and stops standalone server
        clientToAgent.close()
        try await bridgeTask.value
        #expect(serverStopped.isSet == true)
        #expect(ctx.envVariable("OPENCODE_CLIENT") == "acp")
    }

    @Test("opencode acp keeps context.acpRunner override intact")
    func acpRunnerOverridePreserved() async throws {
        let called = AtomicFlag(false)
        let (ctx, _, _) = CLITestFixtures.makeContext(acpRunner: { _, _ in
            called.set(true)
            return 0
        })
        try await CLICommands.runACP(CLIFramework.Runtime.Input(commandPath: ["acp"]), context: ctx)
        #expect(called.isSet == true)
        #expect(ctx.exitCode.value == 0)
    }

    // MARK: - P0 #9: Real `TUIMini.createSessionTransport` & `CLIRun.Mini.runMini`

    @Test("TUIMini.createSessionTransport creates/reuses real sessions over HTTP and streams SSE reasoning/text/tool/turnIdle deltas")
    func miniSessionTransportRealHttpAndSseStreaming() async throws {
        let turnCounter = SyncCollector<String>()
        let transport = MockOpenCodeServerTransport(sessionPrefix: "ses_mini_") { sid, messageID, text, hub in
            turnCounter.append(text)
            let count = turnCounter.values.count
            let asstID = "msg_asst_mini_\(count)"
            hub.emit(RealTestSSEEvents.inboxDelivered(sessionID: sid, inboxID: messageID))
            hub.emit(RealTestSSEEvents.executionStarted(sessionID: sid))
            hub.emit(RealTestSSEEvents.stepStarted(sessionID: sid, assistantMessageID: asstID))
            if count == 1 {
                hub.emit(RealTestSSEEvents.reasoningDelta(sessionID: sid, assistantMessageID: asstID, delta: "Analyzing actor isolation"))
                hub.emit(RealTestSSEEvents.toolCalled(
                    sessionID: sid,
                    assistantMessageID: asstID,
                    id: "call_read_1",
                    name: "read",
                    input: ["path": .string("/workspace/Actor.swift")]
                ))
                hub.emit(RealTestSSEEvents.toolSuccess(
                    sessionID: sid,
                    assistantMessageID: asstID,
                    id: "call_read_1",
                    name: "read",
                    outputText: "actor Counter {}"
                ))
                hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "Actors isolate "))
                hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "mutable state."))
            } else {
                hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "Second turn response."))
            }
            hub.emit(RealTestSSEEvents.executionSucceeded(sessionID: sid))
        }
        defer { transport.sseHub.closeAll() }

        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:49992", transport: transport))
        let footer = RecordingMiniFooter()
        let sessionTransport = await TUIMini.createSessionTransport(
            sessionID: nil,
            footer: footer,
            client: client,
            directory: "/workspace",
            thinking: true,
            tools: true
        )

        // Turn 1: creates a new session via POST /api/session, sends POST /api/session/ses_mini_1/prompt, streams SSE deltas
        let admitted1 = AtomicFlag(false)
        try await sessionTransport.runPromptTurn(
            TUIMini.SessionTurnInput(
                agent: "build",
                model: TUIMini.PromptModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4"),
                prompt: TUIMini.RunPrompt(text: "Explain Swift actors")
            ),
            { admitted1.set(true) }
        )
        #expect(admitted1.isSet == true)

        // Verify real SSE-streamed commits (reasoning, tool, assistant deltas, turnIdle) — NOT fake echo of user prompt!
        let reasoningText = footer.commits.filter { $0.kind == .reasoning }.map(\.text).joined()
        let assistantText = footer.commits.filter { $0.kind == .assistant }.map(\.text).joined()
        let toolCommits = footer.commits.filter { $0.kind == .tool }
        #expect(reasoningText == "Thinking: Analyzing actor isolation")
        #expect(assistantText == "Actors isolate mutable state.")
        #expect(!assistantText.contains("Explain Swift actors"))
        #expect(toolCommits.contains { $0.tool == "read" && $0.phase == .start })
        #expect(toolCommits.contains { $0.tool == "read" && $0.toolState == .completed })
        #expect(footer.events.contains(.turnIdle))

        // Turn 2: reuses the SAME session ID (no second POST /api/session!)
        try await sessionTransport.runPromptTurn(
            TUIMini.SessionTurnInput(prompt: TUIMini.RunPrompt(text: "Follow up question")),
            nil
        )
        await sessionTransport.close()

        let allAssistantText = footer.commits.filter { $0.kind == .assistant }.map(\.text).joined()
        #expect(allAssistantText == "Actors isolate mutable state.Second turn response.")

        let createReqs = transport.requests.filter { $0.method == "POST" && $0.url.hasSuffix("/api/session") }
        let promptReqs = transport.requests.filter { $0.method == "POST" && $0.url.contains("/api/session/ses_mini_1/prompt") }
        let sseReqs = transport.requests.filter { $0.method == "GET" && $0.url.contains("/api/event") }
        #expect(createReqs.count == 1)
        #expect(promptReqs.count == 2)
        #expect(!sseReqs.isEmpty)
        #expect(transport.promptTexts == ["Explain Swift actors", "Follow up question"])
    }

    @Test("CLIRun.Mini.runMini connects to input.server.endpoint, streams real server output, and preserves non-blocking demo mode")
    func runMiniConnectsToServerAndPreservesDemoMode() async throws {
        let transport = MockOpenCodeServerTransport(sessionPrefix: "ses_cmd_") { sid, messageID, _, hub in
            let asstID = "msg_asst_cmd_1"
            hub.emit(RealTestSSEEvents.inboxDelivered(sessionID: sid, inboxID: messageID))
            hub.emit(RealTestSSEEvents.executionStarted(sessionID: sid))
            hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "LIVE_SERVER_DELTA_OK"))
            hub.emit(RealTestSSEEvents.executionSucceeded(sessionID: sid))
        }
        defer { transport.sseHub.closeAll() }

        let (ctx, output, _) = CLITestFixtures.makeContext(
            isStdinTTY: true,
            isStdoutTTY: true,
            transport: transport
        )
        let endpoint = ServiceEndpoint(
            url: "http://127.0.0.1:49993",
            auth: ServiceBasicAuth(username: "opencode", password: "secret-password")
        )
        let paths = CLIRun.MiniHost.HostPaths(home: "/tmp/home", state: "/tmp/state", log: "/tmp/log")

        // 1. Live mode (demo: false) connects via context.makeClient(endpoint:) and hits real HTTP + SSE endpoints
        try await CLIRun.Mini.runMini(
            CLIRun.Mini.MiniCommandInput(
                server: CLIRun.Mini.ServerInput(endpoint: endpoint),
                prompt: "Ping real server",
                demo: false,
                paths: paths
            ),
            context: ctx
        )

        let createReqs = transport.requests.filter { $0.method == "POST" && $0.url.hasSuffix("/api/session") }
        let promptReqs = transport.requests.filter { $0.method == "POST" && $0.url.contains("/api/session/ses_cmd_1/prompt") }
        #expect(createReqs.count == 1)
        #expect(promptReqs.count == 1)
        #expect(createReqs[0].headers["authorization"]?.hasPrefix("Basic ") == true)
        #expect(transport.promptTexts == ["Ping real server"])
        #expect(output.stdout.contains("LIVE_SERVER_DELTA_OK"))

        // 2. Demo mode (demo: true) stays non-blocking and sends zero additional server requests
        let countBeforeDemo = transport.requests.count
        output.reset()
        try await CLIRun.Mini.runMini(
            CLIRun.Mini.MiniCommandInput(
                server: CLIRun.Mini.ServerInput(endpoint: endpoint),
                prompt: "Preview demo",
                demo: true,
                paths: paths
            ),
            context: ctx
        )
        #expect(transport.requests.count == countBeforeDemo)
        #expect(output.stdout.contains("Demo reply to: Preview demo"))
    }

    @Test("TUIMini.createSessionTransport without OpenCodeClient rejects instead of echoing fake local text")
    func miniSessionTransportWithoutClientDoesNotFakeEcho() async {
        let footer = RecordingMiniFooter()
        let transport = await TUIMini.createSessionTransport(sessionID: "ses_none", footer: footer, client: nil)
        await #expect(throws: ClientError.self) {
            try await transport.runPromptTurn(
                TUIMini.SessionTurnInput(prompt: TUIMini.RunPrompt(text: "Should not echo")),
                nil
            )
        }
        #expect(footer.commits.isEmpty)
        #expect(footer.events.contains(.turnIdle))
        await transport.close()
    }

    @Test("TUIMini.runPromptQueue interactive mode drains live footer prompt submissions through OpenCodeClient and exits on /exit")
    func miniInteractivePromptQueueDrainsAndExitsCleanly() async throws {
        let transport = MockOpenCodeServerTransport(sessionPrefix: "ses_loop_") { sid, messageID, text, hub in
            let asstID = "msg_asst_loop_\(messageID)"
            hub.emit(RealTestSSEEvents.inboxDelivered(sessionID: sid, inboxID: messageID))
            hub.emit(RealTestSSEEvents.executionStarted(sessionID: sid))
            hub.emit(RealTestSSEEvents.textDelta(sessionID: sid, assistantMessageID: asstID, delta: "Reply<\(text)>"))
            hub.emit(RealTestSSEEvents.executionSucceeded(sessionID: sid))
        }
        defer { transport.sseHub.closeAll() }

        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:49994", transport: transport))
        let footer = RecordingMiniFooter()
        let sessionTransport = await TUIMini.createSessionTransport(
            sessionID: nil,
            footer: footer,
            client: client,
            directory: "/workspace"
        )

        let queueTask = Task {
            await TUIMini.runPromptQueue(TUIMini.QueueInput(
                footer: footer,
                initialInput: "First prompt",
                interactive: true
            ) { prompt, admitted in
                try await sessionTransport.runPromptTurn(TUIMini.SessionTurnInput(prompt: prompt), admitted)
            })
        }

        // Wait briefly for the initial prompt turn, then submit a second interactive prompt followed by /exit
        try? await Task.sleep(for: .milliseconds(60))
        footer.submitPrompt(TUIMini.RunPrompt(text: "Second prompt"))
        footer.submitPrompt(TUIMini.RunPrompt(text: "/exit"))

        await queueTask.value
        await sessionTransport.close()

        #expect(footer.isClosed == true)
        #expect(transport.promptTexts == ["First prompt", "Second prompt"])
        let assistantText = footer.commits.filter { $0.kind == .assistant }.map(\.text).joined()
        #expect(assistantText == "Reply<First prompt>Reply<Second prompt>")
    }
}
