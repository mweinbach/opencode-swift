import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeSimulation
import OpenCodeUtil

@Suite("OpenCodeSimulation Backend, Network, OpenAI, Provider & Control Server")
struct SimulationBackendTests {
    // MARK: - SimulationNetwork

    @Test("SimulationNetwork isolates routes & request logs per run and denies unregistered destinations")
    func networkRouteIsolationAndLogging() async throws {
        let first = SimulationNetwork.make(
            routes: [
                SimulationNetwork.json(
                    method: "GET",
                    url: "https://example.test/value",
                    body: .object(["source": .string("first")])
                ),
            ],
            clockMs: { 1_234 }
        )
        let second = SimulationNetwork.make(routes: [], clockMs: { 1_234 })
        let request = HTTPRequest(method: "GET", url: "https://example.test/value")

        let response = try await first.client.send(request)
        #expect(response.head.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"source":"first"}"#)

        var deniedError: SimulationNetwork.TransportError?
        do {
            _ = try await second.client.send(request)
        } catch let err as SimulationNetwork.TransportError {
            deniedError = err
        }
        #expect(deniedError != nil)
        #expect(deniedError?.detail.contains("Simulation denied unregistered network destination") == true)

        #expect(await first.log() == [
            OpenCodeProtocol.Backend.NetworkLogEntry(
                time: 1_234,
                method: "GET",
                url: "https://example.test/value",
                matched: true
            ),
        ])
        #expect(await second.log() == [
            OpenCodeProtocol.Backend.NetworkLogEntry(
                time: 1_234,
                method: "GET",
                url: "https://example.test/value",
                matched: false
            ),
        ])
    }

    @Test("SimulationNetwork supports fault injection and latency simulation")
    func networkFaultAndLatencyInjection() async throws {
        let transportFault = SimulationNetwork.fault(
            method: "POST",
            urlPrefix: "https://api.example.test/fail",
            fault: .transportError("simulated ECONNRESET")
        )
        let statusFault = SimulationNetwork.fault(
            method: "GET",
            urlPrefix: "https://api.example.test/rate-limit",
            fault: .httpStatus(429, body: #"{"error":"slow down"}"#, headers: ["retry-after": "1"])
        )
        let midStreamFault = SimulationNetwork.fault(
            method: "GET",
            urlPrefix: "https://api.example.test/drop",
            fault: .disconnectMidStream(afterBytes: 4, message: "stream dropped")
        )
        let delayedJSON = SimulationNetwork.withLatency(
            SimulationNetwork.json(method: "GET", url: "https://api.example.test/slow", body: .object(["ok": .bool(true)])),
            delayMs: 15
        )
        let run = SimulationNetwork.make(routes: [transportFault, statusFault, midStreamFault, delayedJSON])

        // 1. Transport error fault
        var caughtTransport: SimulationNetwork.TransportError?
        do {
            _ = try await run.client.send(HTTPRequest(method: "POST", url: "https://api.example.test/fail"))
        } catch let err as SimulationNetwork.TransportError {
            caughtTransport = err
        }
        #expect(caughtTransport?.detail == "simulated ECONNRESET")

        // 2. HTTP 429 fault
        let rlResp = try await run.client.send(HTTPRequest(method: "GET", url: "https://api.example.test/rate-limit"))
        #expect(rlResp.head.statusCode == 429)
        #expect(rlResp.head.headers["retry-after"] == "1")
        #expect(String(decoding: rlResp.body, as: UTF8.self) == #"{"error":"slow down"}"#)

        // 3. Mid-stream disconnect fault
        var sawBytes = 0
        var caughtMidStream: SimulationNetwork.TransportError?
        let streamResp = try await run.client.stream(HTTPRequest(method: "GET", url: "https://api.example.test/drop"))
        do {
            for try await chunk in streamResp.chunks {
                sawBytes += chunk.count
            }
        } catch let err as SimulationNetwork.TransportError {
            caughtMidStream = err
        }
        #expect(sawBytes == 4)
        #expect(caughtMidStream?.detail == "stream dropped")

        // 4. Delayed JSON route
        let slowResp = try await run.client.send(HTTPRequest(method: "GET", url: "https://api.example.test/slow"))
        #expect(slowResp.head.statusCode == 200)
        #expect(String(decoding: slowResp.body, as: UTF8.self) == #"{"ok":true}"#)
    }

    // MARK: - SimulationOpenAI

    @Test("SimulationOpenAI encodes text, tool input deltas, and finish events as OpenAI SSE")
    func openAISSEEncodingAndInvalidJSON() async throws {
        // 1. Text deltas + stop finish
        let textProvider = SimulatedProvider.Service.scripted([
            [.textDelta("Hello "), .textDelta("from Drive"), .finish(reason: .stop)],
        ])
        let textNet = SimulationNetwork.make(routes: [SimulationOpenAI.route(textProvider)])
        let url = AIProtocols.OpenAIChat.DEFAULT_BASE_URL + AIProtocols.OpenAIChat.PATH
        let reqBody = Array(#"{"model":"gpt-5"}"#.utf8)
        let textResp = try await textNet.client.send(HTTPRequest(method: "POST", url: url, body: reqBody))
        #expect(textResp.head.statusCode == 200)
        #expect(textResp.head.headers["content-type"] == "text/event-stream")
        let expectedTextBody = [
            #"data: {"choices":[{"delta":{"content":"Hello "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"from Drive"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
            "",
        ].joined(separator: "\n\n")
        #expect(String(decoding: textResp.body, as: UTF8.self) == expectedTextBody)

        // 2. Provider-neutral partial tool input -> OpenAI tool_calls deltas
        let toolProvider = SimulatedProvider.Service.scripted([
            [
                .toolInputStart(index: 0, id: "call_lookup", name: "lookup"),
                .toolInputDelta(index: 0, text: #"{"query":"#),
                .toolInputDelta(index: 0, text: #""OpenCode"}"#),
                .finish(reason: .toolCalls),
            ],
        ])
        let toolNet = SimulationNetwork.make(routes: [SimulationOpenAI.route(toolProvider)])
        let toolResp = try await toolNet.client.send(HTTPRequest(method: "POST", url: url, body: reqBody))
        let expectedToolBody = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_lookup","function":{"name":"lookup","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"OpenCode\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
            "",
        ].joined(separator: "\n\n")
        #expect(String(decoding: toolResp.body, as: UTF8.self) == expectedToolBody)

        // 3. Rejects malformed JSON request body as TransportError
        let badRespNet = SimulationNetwork.make(routes: [SimulationOpenAI.route(textProvider)])
        var caughtBadBody: SimulationNetwork.TransportError?
        do {
            _ = try await badRespNet.client.send(HTTPRequest(method: "POST", url: url, body: Array("{".utf8)))
        } catch let err as SimulationNetwork.TransportError {
            caughtBadBody = err
        }
        #expect(caughtBadBody?.detail.contains("invalid OpenAI request body") == true)
    }

    @Test("SimulationOpenAI integrates end-to-end with OpenCodeAI OpenAIChat streaming pipeline")
    func openAIEndToEndWithOpenCodeAI() async throws {
        let provider = SimulatedProvider.Service.scripted([
            [
                .reasoningDelta("Thinking..."),
                .textDelta("Answer: 42"),
                .toolCall(index: 0, id: "call_1", name: "echo", input: .object(["msg": .string("hi")])),
                .finish(reason: .toolCalls),
            ],
        ])
        let net = SimulationNetwork.make(routes: [SimulationOpenAI.route(provider)])
        let llmReq = AIProtocolUtils.LLMRequest(
            model: AIProtocolUtils.ModelDescriptor(
                id: "gpt-5",
                provider: "openai",
                routeID: "openai-chat",
                baseURL: AIProtocols.OpenAIChat.DEFAULT_BASE_URL
            ),
            messages: [
                AIProtocolUtils.Message(role: .user, content: [.text(AIProtocolUtils.TextPart(text: "Hello"))]),
            ]
        )

        let events = try await AIProtocols.OpenAIChat.route.executeStream(llmReq, transport: net.client)
        let textDeltas = events.compactMap { ev -> String? in
            if case .textDelta(_, let text, _) = ev { return text }
            return nil
        }
        let toolCalls = events.compactMap { ev -> (id: String, name: String, input: JSONValue)? in
            if case .toolCall(let id, let name, _, let input, _, _) = ev { return (id, name, input) }
            return nil
        }
        #expect(textDeltas.joined() == "Answer: 42")
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.name == "echo")
        #expect(toolCalls.first?.input == .object(["msg": .string("hi")]))
    }

    // MARK: - SimulationControlServer (Real Loopback TCP WebSocket + Lifecycle)

    @Test("SimulationControlServer awaits socket cleanup, releases port, survives closed target, and enforces 64MiB outbound bound")
    func controlServerLifecycleAndBounds() async throws {
        // 1. Awaits accepted socket cleanup before close() returns and immediately releases port for rebind
        let port1 = try SimTestNet.availableLoopbackPort()
        let cleaned = Mutex(false)
        let server1 = try await SimulationControlServer.start(
            options: SimulationControlServer.StartOptions<JSONValue>(
                endpoint: "ws://127.0.0.1:\(port1)",
                label: "control server test",
                data: { SimulationControlServer.SocketData() },
                decode: { try SimTestJSON.parseValue($0) },
                requestID: { val in
                    if case .object(let obj) = val, case .int(let n) = obj["id"] { return .number(Double(n)) }
                    return nil
                },
                handle: { _, _ in .object(["ok": .bool(true)]) },
                close: { _ in
                    try? await Task.sleep(for: .milliseconds(25))
                    cleaned.withLock { $0 = true }
                }
            )
        )
        let client1 = try await SimTestTCPWebSocket.connect(url: server1.url)
        try client1.sendJSON(.object(["id": .int(1)]))
        let resp1 = try await client1.readJSON()
        #expect(resp1["id"] == .int(1))
        #expect(resp1["result"] == .object(["ok": .bool(true)]))

        await server1.close()
        client1.close()
        #expect(cleaned.withLock { $0 } == true)
        #expect(SimTestNet.canBindLoopbackPort(port1) == true)

        // 2. Continues serving after a response targets a closed socket
        let port2 = try SimTestNet.availableLoopbackPort()
        let server2 = try await SimulationControlServer.start(
            options: SimulationControlServer.StartOptions<JSONValue>(
                endpoint: "ws://127.0.0.1:\(port2)",
                label: "control server closed target test",
                data: { SimulationControlServer.SocketData() },
                decode: { try SimTestJSON.parseValue($0) },
                requestID: { val in
                    if case .object(let obj) = val, case .int(let n) = obj["id"] { return .number(Double(n)) }
                    return nil
                },
                handle: { _, _ in
                    try? await Task.sleep(for: .milliseconds(25))
                    return .object(["ok": .bool(true)])
                }
            )
        )
        let closedClient = try await SimTestTCPWebSocket.connect(url: server2.url)
        try closedClient.sendJSON(.object(["id": .int(1)]))
        closedClient.close()
        try await Task.sleep(for: .milliseconds(50))

        let liveClient = try await SimTestTCPWebSocket.connect(url: server2.url)
        try liveClient.sendJSON(.object(["id": .int(2)]))
        let resp2 = try await liveClient.readJSON()
        #expect(resp2["id"] == .int(2))
        #expect(resp2["result"] == .object(["ok": .bool(true)]))
        liveClient.close()
        await server2.close()

        // 3. Disconnects and cleans up when outbound message exceeds 64 MiB queue bound
        let overflowCleaned = Mutex(false)
        let overflowDelivered = Mutex(false)
        let server3 = try await SimulationControlServer.start(
            options: SimulationControlServer.StartOptions<JSONValue>(
                endpoint: "ws://127.0.0.1:0",
                label: "control server overflow test",
                data: { SimulationControlServer.SocketData() },
                decode: { try SimTestJSON.parseValue($0) },
                requestID: { val in
                    if case .object(let obj) = val, case .int(let n) = obj["id"] { return .number(Double(n)) }
                    return nil
                },
                handle: { socket, _ in
                    let oversized = String(repeating: "x", count: SimulationControlServer.maxOutboundBytes + 1)
                    try await socket.send(oversized)
                    overflowDelivered.withLock { $0 = true }
                    return .object(["ok": .bool(true)])
                },
                close: { _ in
                    overflowCleaned.withLock { $0 = true }
                },
                bindNetwork: false
            )
        )
        let memSock = SimTestInMemorySocket()
        let serveTask = server3.attachConnection(memSock.server)
        try await memSock.sendJSON(.object(["id": .int(1)]))
        var receivedTextMessages: [String] = []
        while let frame = await memSock.nextFrame() {
            switch frame {
            case .text(let s): receivedTextMessages.append(s)
            case .binary: break
            case .close: break
            }
        }
        await serveTask.value
        await server3.close()
        #expect(overflowCleaned.withLock { $0 } == true)
        #expect(overflowDelivered.withLock { $0 } == false)
        #expect(receivedTextMessages.isEmpty)
    }

    // MARK: - SimulatedProvider LLM Driver

    @Test("SimulatedProvider streams Drive-controlled responses, replays late attach, replaces controllers, and handles disconnect & backpressure")
    func simulatedProviderLLMLifecycle() async throws {
        let handle = try await SimulatedProvider.startDrive(
            SimulatedProvider.DriveOptions(endpoint: "ws://127.0.0.1:0", version: "2.0.0-test", bindNetwork: false)
        )
        defer { Task { await handle.shutdown() } }

        let sock = SimTestInMemorySocket()
        _ = handle.server.attachConnection(sock.server)

        // 1. Handshake
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(0),
            "method": .string("simulation.handshake"),
            "params": .object([
                "client": .object(["name": .string("test"), "version": .string("1.0")]),
                "expectedRole": .string("backend"),
                "offeredVersions": .array([.int(1)]),
                "requiredCapabilities": .array([.string("llm.attach"), .string("llm.request")]),
                "optionalCapabilities": .array([]),
            ]),
        ]))
        let hs = try await sock.nextJSON()
        #expect(hs["id"] == .int(0))
        #expect(hs["result"]?["protocolVersion"] == .int(1))
        #expect(hs["result"]?["role"] == .string("backend"))

        // 2. Malformed JSON yields id: null, code: -32000
        try await sock.sendText("{")
        let parseErr = try await sock.nextJSON()
        #expect(parseErr["id"] == .null)
        #expect(parseErr["error"]?["code"] == .int(-32000))

        // 3. Attach -> stream -> chunk -> finish -> pending empty
        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("llm.attach")]))
        let attachResp = try await sock.nextJSON()
        #expect(attachResp["id"] == .int(1))
        #expect(attachResp["result"]?["attached"] == .bool(true))

        let req = SimulatedProvider.ProviderRequest(
            url: "https://api.openai.com/v1/chat/completions",
            body: .object(["model": .string("gpt-5")])
        )
        let streamTask = Task { () async throws -> [SimulatedProvider.ProviderResponseEvent] in
            var collected: [SimulatedProvider.ProviderResponseEvent] = []
            for try await ev in handle.service.stream(req) {
                collected.append(ev)
            }
            return collected
        }

        let opened = try await sock.nextJSON()
        #expect(opened["method"] == .string("llm.request"))
        guard case .string(let invID) = opened["params"]?["id"] else {
            Issue.record("Missing invocation id in llm.request")
            return
        }

        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(2),
            "method": .string("llm.chunk"),
            "params": .object([
                "id": .string(invID),
                "items": .array([.object(["type": .string("textDelta"), "text": .string("Hello from Drive")])]),
            ]),
        ]))
        let chunkResp = try await sock.nextJSON()
        #expect(chunkResp["id"] == .int(2))
        #expect(chunkResp["result"]?["ok"] == .bool(true))

        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(3),
            "method": .string("llm.finish"),
            "params": .object(["id": .string(invID)]),
        ]))
        let finishResp = try await sock.nextJSON()
        #expect(finishResp["id"] == .int(3))
        #expect(finishResp["result"]?["ok"] == .bool(true))

        let events = try await streamTask.value
        #expect(events == [
            .textDelta("Hello from Drive"),
            .finish(reason: .stop),
        ])

        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(4), "method": .string("llm.pending")]))
        let pendingResp = try await sock.nextJSON()
        #expect(pendingResp["result"]?["invocations"] == .array([]))

        // 4. Disconnect fails stream with ProviderDisconnectedError
        let discTask = Task { () async -> SimulatedProvider.ProviderDisconnectedError? in
            do {
                for try await _ in handle.service.stream(req) {}
                return nil
            } catch let err as SimulatedProvider.ProviderDisconnectedError {
                return err
            } catch {
                return nil
            }
        }
        let opened2 = try await sock.nextJSON()
        guard case .string(let invID2) = opened2["params"]?["id"] else {
            Issue.record("Missing second invocation id")
            return
        }
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(5),
            "method": .string("llm.disconnect"),
            "params": .object(["id": .string(invID2)]),
        ]))
        _ = try await sock.nextJSON()
        let discErr = await discTask.value
        #expect(discErr?.message == "Simulated model provider disconnected")

        // 5. Controller replacement + late-attach replay
        let sock2 = SimTestInMemorySocket()
        _ = handle.server.attachConnection(sock2.server)
        try await sock2.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(10), "method": .string("llm.attach")]))
        let attach2 = try await sock2.nextJSON()
        #expect(attach2["id"] == .int(10))
        #expect(attach2["result"]?["attached"] == .bool(true))

        // 6. Backpressure: 300 items (>256 queue capacity) unblocks when consumer cancels
        let gotFirst = Mutex(false)
        let bpTask = Task {
            for try await _ in handle.service.stream(req) {
                gotFirst.withLock { $0 = true }
                try await Task.sleep(for: .seconds(60))
            }
        }
        let opened3 = try await sock2.nextJSON()
        guard case .string(let invID3) = opened3["params"]?["id"] else {
            Issue.record("Missing third invocation id")
            return
        }
        let manyItems: [JSONValue] = (0..<300).map { i in
            .object(["type": .string("textDelta"), "text": .string("\(i)")])
        }
        try await sock2.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(11),
            "method": .string("llm.chunk"),
            "params": .object(["id": .string(invID3), "items": .array(manyItems)]),
        ]))
        while !gotFirst.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(15))
        // Backpressured chunk response has not arrived yet
        #expect(await sock2.bufferedCount() == 0)
        // Cancelling the consumer unblocks the backpressured llm.chunk RPC
        bpTask.cancel()
        let bpResp = try await sock2.nextJSON()
        #expect(bpResp["id"] == .int(11))

        await sock.close()
        await sock2.close()
        await handle.shutdown()
    }

    @Test("SimulatedProvider replays pending invocation on late attach and removes invocation on early consumer cancel")
    func simulatedProviderLateAttachAndEarlyCancel() async throws {
        let handle = try await SimulatedProvider.startDrive(
            SimulatedProvider.DriveOptions(endpoint: "ws://127.0.0.1:0", version: "test", bindNetwork: false)
        )
        let req = SimulatedProvider.ProviderRequest(
            url: "https://api.openai.com/v1/chat/completions",
            body: .object(["model": .string("gpt-5")])
        )

        // 1. Open stream BEFORE any controller attaches
        let streamTask = Task { () async throws -> [SimulatedProvider.ProviderResponseEvent] in
            var out: [SimulatedProvider.ProviderResponseEvent] = []
            for try await ev in handle.service.stream(req) {
                out.append(ev)
            }
            return out
        }
        try await Task.sleep(for: .milliseconds(15))

        // Controller attaches late and receives both {id:1, result:{attached:true}} and replayed llm.request
        let sock = SimTestInMemorySocket()
        _ = handle.server.attachConnection(sock.server)
        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("llm.attach")]))
        let m1 = try await sock.nextJSON()
        let m2 = try await sock.nextJSON()
        let pair = [m1, m2]
        #expect(pair.contains { $0["id"] == .int(1) && $0["result"]?["attached"] == .bool(true) })
        guard let replayed = pair.first(where: { $0["method"] == .string("llm.request") }),
              case .string(let replayedID) = replayed["params"]?["id"]
        else {
            Issue.record("Pending invocation was not replayed on late attach")
            await sock.close()
            await handle.shutdown()
            return
        }
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(2),
            "method": .string("llm.finish"),
            "params": .object(["id": .string(replayedID), "reason": .string("stop")]),
        ]))
        _ = try await sock.nextJSON()
        let events = try await streamTask.value
        #expect(events == [.finish(reason: .stop)])

        // 2. Cancelling consumer while awaiting first event removes invocation from llm.pending
        let cancelledTask = Task {
            for try await _ in handle.service.stream(req) {}
        }
        _ = try await sock.nextJSON() // llm.request notification
        cancelledTask.cancel()
        _ = try? await cancelledTask.value
        try await Task.sleep(for: .milliseconds(15))

        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(3), "method": .string("llm.pending")]))
        let pending = try await sock.nextJSON()
        #expect(pending["result"]?["invocations"] == .array([]))

        await sock.close()
        await handle.shutdown()
    }

    // MARK: - SimulatedProvider Tool Driver

    @Test("SimulatedProvider controls simulated tools across locations with progress sequencing, idempotency, cancel, reconnect, and namespaces")
    func simulatedProviderToolLifecycle() async throws {
        let sdkPlugins = CorePlugin.SdkPlugins.Service()
        let handle = try await SimulatedProvider.startDrive(
            SimulatedProvider.DriveOptions(endpoint: "ws://127.0.0.1:0", version: "test", bindNetwork: false),
            sdkPlugins: sdkPlugins
        )
        defer { Task { await handle.shutdown() } }

        // Boot two independent Location plugin environments sharing the SDK plugin
        let primaryEnv = CorePlugin.Host.Environment()
        let secondaryEnv = CorePlugin.Host.Environment()
        let primaryPluginSvc = CorePlugin.Service(environment: primaryEnv)
        let secondaryPluginSvc = CorePlugin.Service(environment: secondaryEnv)
        try await primaryPluginSvc.activate(sdkPlugins.all())
        try await secondaryPluginSvc.activate(sdkPlugins.all())

        let sock = SimTestInMemorySocket()
        _ = handle.server.attachConnection(sock.server)

        let lookupReg: JSONValue = .object([
            "name": .string("lookup"),
            "description": .string("Look up a value"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]),
            ]),
            "outputSchema": .object(["type": .string("object")]),
            "permission": .string("simulate_lookup"),
            "options": .object(["codemode": .bool(false)]),
        ])

        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "method": .string("tool.attach"),
            "params": .object(["tools": .array([lookupReg])]),
        ]))
        let attachResp = try await sock.nextJSON()
        #expect(attachResp["id"] == .int(1))
        #expect(attachResp["result"]?["attached"] == .bool(true))

        // Both locations received the simulated tool
        #expect(primaryEnv.registeredTools().map(\.id) == ["lookup"])
        #expect(secondaryEnv.registeredTools().map(\.id) == ["lookup"])
        guard let lookupTool = primaryEnv.registeredTools().first(where: { $0.id == "lookup" }) else {
            Issue.record("Expected lookup tool registered")
            return
        }

        // Execute tool with progress updates (idempotent replay, conflicting seq, skipped seq) and finish (with file content + idempotent replay)
        let progressLog = Mutex<[ToolSchema.Metadata]>([])
        let sessionID = try #require(SessionID(rawValue: "ses_sim_tools"))
        let toolCtx = ToolSchema.Context(
            sessionID: sessionID,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_sim_tools",
            id: ToolSchema.CallID(rawValue: "call_success"),
            progress: { update in
                progressLog.withLock { $0.append(update) }
            }
        )

        let execTask: Task<ToolSchema.Result<JSONValue>, Error> = Task {
            try await lookupTool.execute(.object(["query": .string("answer")]), toolCtx)
        }
        let invNotif = try await sock.nextJSON()
        #expect(invNotif["method"] == .string("tool.invocation"))
        #expect(invNotif["params"]?["name"] == .string("lookup"))
        guard case .string(let toolCallID) = invNotif["params"]?["id"] else {
            Issue.record("Missing tool invocation id")
            return
        }

        // Sequence 0 update
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(20),
            "method": .string("tool.update"),
            "params": .object([
                "id": .string(toolCallID),
                "sequence": .int(0),
                "update": .object(["phase": .string("searching")]),
            ]),
        ]))
        #expect((try await sock.nextJSON())["result"]?["ok"] == .bool(true))

        // Idempotent replay of sequence 0 with identical payload
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(21),
            "method": .string("tool.update"),
            "params": .object([
                "id": .string(toolCallID),
                "sequence": .int(0),
                "update": .object(["phase": .string("searching")]),
            ]),
        ]))
        #expect((try await sock.nextJSON())["result"]?["ok"] == .bool(true))

        // Reusing sequence 0 with different progress -> error
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(22),
            "method": .string("tool.update"),
            "params": .object([
                "id": .string(toolCallID),
                "sequence": .int(0),
                "update": .object(["phase": .string("different")]),
            ]),
        ]))
        let reuseErr = try await sock.nextJSON()
        if case .string(let msg) = reuseErr["error"]?["message"] {
            #expect(msg.contains("reused with different progress"))
        } else {
            Issue.record("Expected error message on sequence reuse")
        }

        // Skipped sequence 2 -> error
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(23),
            "method": .string("tool.update"),
            "params": .object([
                "id": .string(toolCallID),
                "sequence": .int(2),
                "update": .object(["phase": .string("skipped")]),
            ]),
        ]))
        let skipErr = try await sock.nextJSON()
        if case .string(let msg) = skipErr["error"]?["message"] {
            #expect(msg.contains("Expected simulated tool update sequence 1"))
        } else {
            Issue.record("Expected error message on skipped sequence")
        }

        // Finish with structured output + text & file content
        let finishParams: JSONValue = .object([
            "id": .string(toolCallID),
            "output": .object([
                "structured": .object(["answer": .int(42)]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("42")]),
                    .object(["type": .string("file"), "data": .string("SGk="), "mime": .string("text/plain"), "name": .string("note.txt")]),
                ]),
            ]),
        ])
        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(24), "method": .string("tool.finish"), "params": finishParams]))
        #expect((try await sock.nextJSON())["result"]?["ok"] == .bool(true))
        // Idempotent finish replay
        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(25), "method": .string("tool.finish"), "params": finishParams]))
        #expect((try await sock.nextJSON())["result"]?["ok"] == .bool(true))

        let toolResult = try await execTask.value
        #expect(toolResult.output == .object(["answer": .int(42)]))
        #expect(toolResult.content == .parts([
            .text(ToolSchema.TextContent(text: "42")),
            .file(ToolSchema.FileContent(uri: "data:text/plain;base64,SGk=", mime: "text/plain", name: "note.txt")),
        ]))
        #expect(progressLog.withLock { $0 } == [["phase": .string("searching")]])

        // tool.fail propagates ToolError
        let failTask = Task { () async -> String? in
            do {
                _ = try await lookupTool.execute(.object(["query": .string("missing")]), toolCtx)
                return nil
            } catch let err as ToolSchema.ToolError {
                return err.message
            } catch {
                return String(describing: error)
            }
        }
        let failNotif = try await sock.nextJSON()
        guard case .string(let failID) = failNotif["params"]?["id"] else {
            Issue.record("Missing fail tool id")
            return
        }
        try await sock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(26),
            "method": .string("tool.fail"),
            "params": .object(["id": .string(failID), "message": .string("lookup failed")]),
        ]))
        #expect((try await sock.nextJSON())["result"]?["ok"] == .bool(true))
        #expect(await failTask.value == "lookup failed")

        // Cancellation emits tool.cancel
        let cancelTask: Task<Void, Never> = Task {
            _ = try? await lookupTool.execute(.object(["query": .string("slow")]), toolCtx)
        }
        let cancelNotif = try await sock.nextJSON()
        guard case .string(let cancelID) = cancelNotif["params"]?["id"] else {
            Issue.record("Missing cancel tool id")
            return
        }
        cancelTask.cancel()
        let cancelledMsg = try await sock.nextJSON()
        #expect(cancelledMsg["method"] == .string("tool.cancel"))
        #expect(cancelledMsg["params"]?["id"] == .string(cancelID))
        #expect(cancelledMsg["params"]?["reason"] == .string("interrupted"))
        await cancelTask.value

        // Contention, disconnect preserving pending invocation, reconnect replay, and namespaced replacement
        let replayTask: Task<ToolSchema.Result<JSONValue>, Error> = Task {
            try await lookupTool.execute(.object(["query": .string("reconnect")]), toolCtx)
        }
        let origNotif = try await sock.nextJSON()
        guard case .string(let origID) = origNotif["params"]?["id"] else {
            Issue.record("Missing reconnect tool id")
            return
        }

        let replacementSock = SimTestInMemorySocket()
        _ = handle.server.attachConnection(replacementSock.server)
        // Contention while first controller still connected
        try await replacementSock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(30),
            "method": .string("tool.attach"),
            "params": .object(["tools": .array([lookupReg])]),
        ]))
        let contendResp = try await replacementSock.nextJSON()
        if case .string(let msg) = contendResp["error"]?["message"] {
            #expect(msg.contains("already attached"))
        } else {
            Issue.record("Expected already-attached error")
        }

        // Disconnect first controller
        await sock.close()
        try await Task.sleep(for: .milliseconds(25))

        // Reject replacing tools while invocation is pending
        let differentReg: JSONValue = .object([
            "name": .string("other"),
            "description": .string("Other"),
            "inputSchema": .object(["type": .string("object")]),
            "options": .object(["codemode": .bool(false)]),
        ])
        try await replacementSock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(31),
            "method": .string("tool.attach"),
            "params": .object(["tools": .array([differentReg])]),
        ]))
        let settleErr = try await replacementSock.nextJSON()
        if case .string(let msg) = settleErr["error"]?["message"] {
            #expect(msg.contains("must settle pending invocations"))
        } else {
            Issue.record("Expected settle pending invocations error")
        }

        // Reconnect with identical registrations -> attached + replayed tool.invocation
        try await replacementSock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(32),
            "method": .string("tool.attach"),
            "params": .object(["tools": .array([lookupReg])]),
        ]))
        let msgA = try await replacementSock.nextJSON()
        let msgB = try await replacementSock.nextJSON()
        let received = [msgA, msgB]
        #expect(received.contains { $0["id"] == .int(32) && $0["result"]?["attached"] == .bool(true) })
        #expect(received.contains { $0["method"] == .string("tool.invocation") && $0["params"]?["id"] == .string(origID) })

        // Finish replayed invocation
        try await replacementSock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(33),
            "method": .string("tool.finish"),
            "params": .object([
                "id": .string(origID),
                "output": .object([
                    "structured": .string("replayed result"),
                    "content": .array([.object(["type": .string("text"), "text": .string("replayed result")])]),
                ]),
            ]),
        ]))
        #expect((try await replacementSock.nextJSON())["result"]?["ok"] == .bool(true))
        let replayedResult = try await replayTask.value
        #expect(replayedResult.output == .string("replayed result"))

        // Replace with namespaced tools and verify stale handle rejects with "no longer active"
        let namespacedRegs: [JSONValue] = [
            .object([
                "name": .string("search"),
                "description": .string("GitHub search"),
                "inputSchema": .object(["type": .string("object")]),
                "options": .object(["namespace": .string("github"), "codemode": .bool(false)]),
            ]),
            .object([
                "name": .string("search"),
                "description": .string("Web search"),
                "inputSchema": .object(["type": .string("object")]),
                "options": .object(["namespace": .string("web"), "codemode": .bool(false)]),
            ]),
        ]
        try await replacementSock.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(34),
            "method": .string("tool.attach"),
            "params": .object(["tools": .array(namespacedRegs)]),
        ]))
        #expect((try await replacementSock.nextJSON())["result"]?["attached"] == .bool(true))
        #expect(primaryEnv.registeredTools().map(\.id) == ["github_search", "web_search"])
        #expect(secondaryEnv.registeredTools().map(\.id) == ["github_search", "web_search"])

        // Old captured lookupTool handle rejects with "no longer active"
        var staleMsg: String?
        do {
            _ = try await lookupTool.execute(.object(["query": .string("stale")]), toolCtx)
        } catch {
            staleMsg = error.message
        }
        #expect(staleMsg?.contains("no longer active") == true)

        await replacementSock.close()
        await primaryPluginSvc.close()
        await secondaryPluginSvc.close()
        await handle.shutdown()
    }

    // MARK: - Simulation.simulationReplacements

    @Test("Simulation.simulationReplacements replaces httpClient offline and wires Drive provider when OPENCODE_DRIVE is set")
    func simulationReplacementsLayerWiring() async throws {
        // 1. Without OPENCODE_DRIVE -> empty ModelsDev catalog + denies unknown destinations
        let offlineReplacements = try await Simulation.simulationReplacements(
            app: Simulation.AppDescriptor(version: "2.0.0"),
            environment: DictionaryEnvironment()
        )
        let offlineGraph = try LayerNode.compile(
            LayerNodePlatform.httpClient,
            options: LayerNode.CompileOptions(replacements: offlineReplacements)
        )
        let offlineScope = LayerNode.ResourceScope()
        let offlineOut = try await offlineGraph.build(scope: offlineScope)
        guard let offlineClient = offlineOut.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self) else {
            Issue.record("Expected replaced HTTPTransport")
            return
        }
        let modelsResp = try await offlineClient.send(HTTPRequest(method: "GET", url: Simulation.modelsCatalogURL))
        #expect(modelsResp.head.statusCode == 200)
        #expect(String(decoding: modelsResp.body, as: UTF8.self) == "{}")

        var denied = false
        do {
            _ = try await offlineClient.send(HTTPRequest(method: "GET", url: "https://external.invalid/leak"))
        } catch is SimulationNetwork.TransportError {
            denied = true
        }
        #expect(denied)
        await offlineScope.close()

        // 2. With OPENCODE_DRIVE -> resolves manifest and wires SimulatedProvider + OpenAI route + ModelsDev
        let port = try SimTestNet.availableLoopbackPort()
        let manifestJSON = """
        {"endpoints":{"ui":"ws://127.0.0.1:41900","backend":"ws://127.0.0.1:\(port)"}}
        """
        let fs = InMemoryFileSystem(initialFiles: ["/drive/sim.json": Array(manifestJSON.utf8)])
        let env = DictionaryEnvironment(variables: [
            "OPENCODE_DRIVE": "sim",
            "DRIVE_REGISTRY_DIR": "/drive",
        ])
        let driveReplacements = try await Simulation.simulationReplacements(
            app: Simulation.AppDescriptor(version: "2.0.0-sim"),
            environment: env,
            fileSystem: fs,
            bindNetwork: false
        )
        let driveGraph = try LayerNode.compile(
            LayerNodePlatform.httpClient,
            options: LayerNode.CompileOptions(replacements: driveReplacements)
        )
        let driveScope = LayerNode.ResourceScope()
        let driveOut = try await driveGraph.build(scope: driveScope)
        #expect(driveOut.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self) != nil)
        #expect(driveOut.get(SimulatedProvider.Service.serviceKey, as: SimulatedProvider.Service.self) != nil)
        #expect(driveOut.get(SimulatedProvider.driveServerKey, as: SimulationControlServer.Server.self) != nil)
        await driveScope.close()
    }
}
