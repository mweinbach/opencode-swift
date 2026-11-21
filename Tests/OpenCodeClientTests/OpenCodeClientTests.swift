import Testing
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

@Suite("OpenCodeClient Complete Port Tests")
struct OpenCodeClientTests {

    // MARK: - Module & Contract Metadata

    @Test("OpenCodeClient module exposes upstream package metadata and full ClientApi contract")
    func moduleMetadataAndContract() {
        #expect(OpenCodeClientModule.upstreamPackage == "client")
        #expect(OpenCodeClientModule.api.groups.count == 32)
        #expect(OpenCodeClientModule.api.endpoints.count == 178)
        #expect(OpenCodeClientModule.groupNames["server.fs"] == "file")
        #expect(OpenCodeClientModule.clientNamespace(path: "/api/experimental/usage/limits") == "experimental")
        #expect(OpenCodeClientModule.clientNamespace(path: "/api/session") == nil)
        #expect(OpenCodeClientModule.promiseOmitEndpoints.contains("pty.connect"))
        #expect(OpenCodeClientModule.effectOmitEndpoints.contains("fs.read"))
    }

    // MARK: - HTTP Request Construction, Query Encoding & Multi-Group API Calls

    @Test("HTTP requests preserve baseUrl path prefix, deepObject location query, auth headers, and decode typed responses")
    func multiGroupTypedHTTPRequests() async throws {
        let transport = MockHTTPTransport { request in
            if request.url == "http://127.0.0.1:4096/proxy/api/info" {
                return try ClientTestHelper.jsonResponse(
                    body: ServerInfo(
                        version: "2.3.0",
                        pid: 4242,
                        hostname: "dev-box",
                        urls: ["http://127.0.0.1:4096"],
                        paths: ServerInfo.Paths(tmp: "/tmp/opencode"),
                        capabilities: ServerInfo.Capabilities(persistentPty: true)
                    )
                )
            }
            if request.url.hasPrefix("http://127.0.0.1:4096/proxy/api/location?") {
                return try ClientTestHelper.jsonResponse(
                    body: LocationSchema.PublicInfo(
                        directory: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app"),
                        project: LocationSchema.ProjectRef(
                            id: ProjectID(rawValue: "proj_1"),
                            directory: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app"),
                            canonical: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app")
                        )
                    )
                )
            }
            if request.url == "http://127.0.0.1:4096/proxy/api/location/reload" && request.method == "POST" {
                return ClientTestHelper.emptyResponse(status: 204)
            }
            if request.url.hasPrefix("http://127.0.0.1:4096/proxy/api/session/ses_abc123?") ||
               request.url == "http://127.0.0.1:4096/proxy/api/session/ses_abc123" {
                let session = SessionSchema.Info(
                    id: try SessionID(validating: "ses_abc123"),
                    projectID: ProjectID(rawValue: "proj_1"),
                    agent: "build",
                    cost: 0.12,
                    tokens: SessionSchema.TokenUsage(input: 100, output: 50, reasoning: 0, cache: .init(read: 10, write: 5)),
                    time: SessionSchema.Info.Time(created: 1_000, updated: 2_000),
                    title: "Port Client",
                    location: SessionSchema.LocationRef(directory: "/my repo/app")
                )
                return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: session))
            }
            if request.url.hasPrefix("http://127.0.0.1:4096/proxy/api/fs/read/src/my%20file.txt") {
                return ClientTestHelper.binaryResponse(bytes: Array("hello binary".utf8))
            }
            if request.url.hasPrefix("http://127.0.0.1:4096/proxy/api/experimental/fs/write?") && request.method == "POST" {
                let envelope = LocationSchema.ResponseEnvelope(
                    location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app")),
                    data: FileSystemSchema.Write(path: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app/out.bin"))
                )
                return try ClientTestHelper.jsonResponse(body: envelope)
            }
            if request.url.hasPrefix("http://127.0.0.1:4096/proxy/api/pty/pty_1/connect-token") && request.method == "POST" {
                let token = PtyTicketSchema.ConnectToken(
                    ticket: "tk_secret",
                    expiresIn: try SchemaPrimitive.PositiveInt(validating: 30)
                )
                return try ClientTestHelper.jsonResponse(
                    body: LocationSchema.ResponseEnvelope(
                        location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/my repo/app")),
                        data: token
                    )
                )
            }
            if request.url == "http://127.0.0.1:4096/proxy/api/experimental/config" && request.method == "PATCH" {
                return ClientTestHelper.emptyResponse(status: 204)
            }
            if request.url == "http://127.0.0.1:4096/proxy/api/experimental/migration/v1" {
                return try ClientTestHelper.jsonResponse(body: V1MigrationStatus.completed)
            }
            return ClientTestHelper.emptyResponse(status: 404)
        }

        let authHeader = ClientHTTPHeaders.basicAuthorization(username: "opencode", password: "pw")
        let client = OpenCode.make(
            ClientOptions(
                baseUrl: "http://127.0.0.1:4096/proxy",
                transport: transport,
                headers: ["Authorization": authHeader]
            )
        )

        // 1. server.info
        let info = try await client.server.info()
        #expect(info.version == "2.3.0")
        #expect(info.pid == 4242)
        #expect(info.capabilities?.persistentPty == true)

        // 2. location.get with deepObject query encoding
        let loc = try await client.location.get(
            LocationGetInput(location: LocationQuery.LocationField(directory: "/my repo/app"))
        )
        #expect(loc.directory.rawValue == "/my repo/app")
        let locReq = try #require(transport.requests.first { $0.url.contains("/api/location?") })
        #expect(locReq.url.contains("location%5Bdirectory%5D=%2Fmy+repo%2Fapp"))
        #expect(locReq.headers["Authorization"] == authHeader)

        // 3. location.reload (204 No Content)
        try await client.location.reload()

        // 4. session.get ({ data: ... } unwrapping)
        let session = try await client.session.get(SessionGetInput(sessionID: "ses_abc123"))
        #expect(session.id.rawValue == "ses_abc123")
        #expect(session.title == "Port Client")

        // 5. file.read (encodePath preserves '/', escapes spaces, binary response)
        let fileBytes = try await client.file.read(
            FileReadInput(location: LocationQuery.LocationField(directory: "/my repo/app"), path: "src/my file.txt")
        )
        #expect(String(decoding: fileBytes, as: UTF8.self) == "hello binary")

        // 6. experimental.file.write (binary body + application/octet-stream)
        let writeRes = try await client.experimental.file.write(
            ExperimentalFileWriteInput(
                location: LocationQuery.LocationField(directory: "/my repo/app"),
                path: "out.bin",
                payload: [0x01, 0x02, 0x03]
            )
        )
        #expect(writeRes.data.path.rawValue == "/my repo/app/out.bin")
        let writeReq = try #require(transport.requests.first { $0.url.contains("/api/experimental/fs/write") })
        #expect(writeReq.headers["content-type"] == "application/octet-stream")
        #expect(writeReq.body == [0x01, 0x02, 0x03])

        // 7. pty.connect.token (header forwarding)
        let ticket = try await client.pty.connect.token(
            PtyConnectTokenInput(ptyID: "pty_1", xOpencodeTicket: PTY_CONNECT_TOKEN_HEADER_VALUE)
        )
        #expect(ticket.data.ticket == "tk_secret")
        let ptyReq = try #require(transport.requests.first { $0.url.contains("/api/pty/pty_1/connect-token") })
        #expect(ptyReq.headers["x-opencode-ticket"] == "1")

        // 8. Deprecated alias config.update with explicit JSON null
        try await client.config.update(ConfigUpdateInput(shell: .null))
        let cfgReq = try #require(transport.requests.first { $0.url.contains("/api/experimental/config") })
        #expect(String(decoding: cfgReq.body ?? [], as: UTF8.self) == "{\"shell\":null}")

        // 9. Deprecated alias migration.v1.status
        let migration = try await client.migration.v1.status()
        #expect(migration == .completed)

        // 10. Dynamic ProtocolApi endpoint invocation
        let endpoint = try #require(OpenCodeProtocol.ClientApi.endpoint(openAPIIdentifier: "server.info"))
        let rawResp = try await client.invoke(endpoint: endpoint)
        #expect(rawResp.head.statusCode == 200)
    }

    // MARK: - Protocol Error Decoding & Type Guards

    @Test("Declared protocol errors decode into ProtocolErrorEnvelope & match is*Error guards; undeclared statuses throw ClientError")
    func errorDecodingAndTypeGuards() async throws {
        let transport = MockHTTPTransport { request in
            if request.url.contains("/api/session/ses_missing") {
                return try ClientTestHelper.jsonResponse(
                    status: 404,
                    body: ProtocolErrorEnvelope.sessionNotFound(
                        SessionNotFoundError(sessionID: "ses_missing", message: "No such session")
                    )
                )
            }
            if request.url.contains("/instructions/entries/k1") {
                return try ClientTestHelper.jsonResponse(
                    status: 413,
                    body: InstructionEntrySchema.ValueTooLargeError(
                        actualBytes: 300_000,
                        maxBytes: 262_144,
                        message: "Too large"
                    )
                )
            }
            if request.url.contains("/api/info") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 502, headers: ["content-type": "text/plain"]),
                    body: Array("bad gateway".utf8)
                )
            }
            if request.url.contains("/api/pair") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/html"]),
                    body: Array("<html>oops</html>".utf8)
                )
            }
            return HTTPResponse(
                head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                body: Array("{invalid json".utf8)
            )
        }

        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))

        // 404 declared SessionNotFoundError
        do {
            _ = try await client.session.get(SessionGetInput(sessionID: "ses_missing"))
            Issue.record("Expected SessionNotFoundError")
        } catch {
            #expect(isSessionNotFoundError(error))
            #expect(!isAgentNotFoundError(error))
            let extracted = extractSessionNotFoundError(error)
            #expect(extracted?.sessionID == "ses_missing")
            #expect(extracted?.message == "No such session")
        }

        // 413 declared InstructionEntryValueTooLargeError
        do {
            try await client.experimental.session.instructions.entry.put(
                ExperimentalSessionInstructionsEntryPutInput(sessionID: "ses_1", key: "k1", value: .string("huge"))
            )
            Issue.record("Expected InstructionEntryValueTooLargeError")
        } catch {
            #expect(isInstructionEntryValueTooLargeError(error))
            #expect(!isConflictError(error))
        }

        // 502 undeclared status -> ClientError.unexpectedStatus
        do {
            _ = try await client.server.info()
            Issue.record("Expected ClientError.unexpectedStatus")
        } catch let err as ClientError {
            #expect(err.reason == .unexpectedStatus)
            #expect(err.statusCode == 502)
            #expect(err.message == "UnexpectedStatus: 502")
        }

        // Wrong content-type -> ClientError.unsupportedContentType
        do {
            _ = try await client.server.pair()
            Issue.record("Expected ClientError.unsupportedContentType")
        } catch let err as ClientError {
            #expect(err.reason == .unsupportedContentType)
            #expect(err.detail == "text/html")
        }

        // Malformed JSON -> ClientError.malformedResponse
        do {
            _ = try await client.project.list()
            Issue.record("Expected ClientError.malformedResponse")
        } catch let err as ClientError {
            #expect(err.reason == .malformedResponse)
        }

        // Pre-aborted signal -> ClientError.transport before touching transport
        let beforeCount = transport.requests.count
        let abortedSignal = AbortSignal.aborted()
        do {
            _ = try await client.server.info(options: RequestOptions(signal: abortedSignal))
            Issue.record("Expected ClientError.transport on aborted signal")
        } catch let err as ClientError {
            #expect(err.reason == .transport)
            #expect(transport.requests.count == beforeCount)
        }
    }

    // MARK: - Media Refs & mediaHashFromUri

    @Test("mediaHashFromUri validates strict 64-hex media:<hash> URIs and withMediaRefs scopes capability header")
    func mediaRefsCapabilityScoping() async throws {
        let validHash = String(repeating: "a1b2c3d4", count: 8)
        #expect(mediaHashFromUri("media:\(validHash)") == validHash)
        #expect(mediaHashFromUri("media:\(validHash.uppercased())") == nil)
        #expect(mediaHashFromUri("media:short") == nil)
        #expect(mediaHashFromUri("https://example.com/\(validHash)") == nil)
        #expect(mediaHashFromUri(nil) == nil)

        let transport = MockHTTPTransport { request in
            if request.url.contains("/message?") || request.url.hasSuffix("/message") {
                return try ClientTestHelper.jsonResponse(body: SessionMessagesResponse(data: []))
            }
            if request.url.contains("/inbox") {
                return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: [SessionInboxSchema.Info]()))
            }
            if request.url.contains("/api/info") {
                return try ClientTestHelper.jsonResponse(
                    body: ServerInfo(version: "2.0.0", pid: 1, urls: [], paths: .init(tmp: "/tmp"))
                )
            }
            return ClientTestHelper.emptyResponse(status: 404)
        }

        let base = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let mediaClient = withMediaRefs(base)

        _ = try await mediaClient.message.list(MessageListInput(sessionID: "ses_1"))
        _ = try await mediaClient.message.list(MessageListInput(sessionID: "ses_1"), options: MediaRequestOptions(mediaRefs: false))
        _ = try await mediaClient.session.inbox.list(SessionInboxListInput(sessionID: "ses_1"))
        _ = try await mediaClient.server.info()

        let reqs = transport.requests
        #expect(reqs.count == 4)
        #expect(reqs[0].headers["X-OpenCode-Capabilities"] == "experimental-media-uri")
        #expect(reqs[1].headers["X-OpenCode-Capabilities"] == nil)
        #expect(reqs[2].headers["X-OpenCode-Capabilities"] == "experimental-media-uri")
        #expect(reqs[3].headers["X-OpenCode-Capabilities"] == nil)
    }

    // MARK: - SSE Stream Parsing & SharedEvents Multiplexing

    @Test("SSE parser handles split CRLF frames, keepalives, multi-line data, and SharedEvents multiplexes with server.connected replay")
    func sseStreamingAndSharedEventsMultiplexing() async throws {
        let connectedEvent = OpenCodeEvent(id: "evt_0", type: "server.connected", created: 100, data: .object([:]))
        let renameEvent = OpenCodeEvent(
            id: "evt_1",
            type: "session.renamed",
            created: 200,
            data: .object(["sessionID": .string("ses_1"), "title": .string("Updated")])
        )
        let otherEvent = OpenCodeEvent(
            id: "evt_2",
            type: "project.updated",
            created: 300,
            data: .object(["id": .string("proj_1")])
        )

        let connectedJSON = try ClientTestHelper.encodeJSONString(connectedEvent)
        let renameJSON = try ClientTestHelper.encodeJSONString(renameEvent)
        let otherJSON = try ClientTestHelper.encodeJSONString(otherEvent)

        // Split across chunks including CRLF boundary split and keepalive comments
        let chunks: [[UInt8]] = [
            Array(": keepalive\r\n\r\ndata: \(connectedJSON)\r".utf8),
            Array("\n\r\ndata: \(renameJSON)\n\n".utf8),
            Array("data: \(otherJSON)\n\n".utf8),
        ]

        let transport = MockHTTPTransport(streamHandler: { _ in
            ClientTestHelper.sseResponse(chunks: chunks, chunkDelayMs: 5, keepOpen: true)
        })

        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let activityCount = Mutex(0)

        let signalA = AbortController()
        let signalB = AbortController()

        let streamA = client.event.subscribe(
            SubscribeOptions(
                types: ["session.renamed"],
                signal: signalA.signal,
                onActivity: { activityCount.withLock { $0 += 1 } }
            )
        )

        var receivedA: [OpenCodeEvent] = []
        for try await ev in streamA {
            receivedA.append(ev)
            if receivedA.count == 2 {
                // Late subscriber joins while shared connection is alive: should immediately get cached server.connected!
                let streamB = client.event.subscribe(SubscribeOptions(types: ["project.updated"], signal: signalB.signal))
                var receivedB: [OpenCodeEvent] = []
                for try await evB in streamB {
                    receivedB.append(evB)
                    if receivedB.count == 1 {
                        signalB.abort()
                        break
                    }
                }
                #expect(receivedB.first?.type == "server.connected")
                signalA.abort()
                break
            }
        }

        // Only ONE underlying HTTP SSE stream was opened despite two subscribers!
        #expect(transport.streamRequests.count == 1)
        #expect(receivedA.map(\.type) == ["server.connected", "session.renamed"])
        #expect(activityCount.withLock { $0 } > 0)
    }

    // MARK: - Promise RPC, Effect RPC & RpcRuntime

    @Test("Promise & Effect RPC clients invoke /api/rpc/:id/:method, map RpcError payloads, and filter rpc.* events")
    func rpcClientsAndRuntime() async throws {
        let transport = MockHTTPTransport(
            sendHandler: { request in
                if request.url.contains("/api/rpc/demo/echo") {
                    return try ClientTestHelper.jsonResponse(body: RpcOutput(output: .object(["echo": .string("hi")])))
                }
                if request.url.contains("/api/rpc/demo/fail") {
                    return try ClientTestHelper.jsonResponse(
                        status: 400,
                        body: ProtocolErrorEnvelope.rpc(
                            RpcError(type: "custom.denied", message: "Denied", data: .object(["code": .int(7)]))
                        )
                    )
                }
                return ClientTestHelper.emptyResponse(status: 404)
            },
            streamHandler: { _ in
                let connected = try ClientTestHelper.encodeJSONString(
                    OpenCodeEvent(id: "evt_0", type: "server.connected", data: .object([:]))
                )
                let rpcEv = try ClientTestHelper.encodeJSONString(
                    OpenCodeEvent(id: "evt_1", type: "rpc.demo.ping", data: .object(["n": .int(42)]))
                )
                return ClientTestHelper.sseResponse(
                    chunks: [Array("data: \(connected)\n\ndata: \(rpcEv)\n\n".utf8)]
                )
            }
        )

        let anySchema = ToolSchema.ValueSchema.jsonSchema([:])
        let def = RpcSchema.PortableDefinition(
            id: "demo",
            methods: [
                "echo": RpcSchema.PortableMethod(input: anySchema, output: anySchema),
                "fail": RpcSchema.PortableMethod(input: anySchema, output: anySchema, errors: ["custom.denied": anySchema]),
            ],
            events: [
                "ping": RpcSchema.EventDefinition(schema: anySchema),
            ]
        )

        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let demo = client.rpc(def)

        let echoed = try await demo.call(
            "echo",
            input: JSONValue.object(["msg": .string("hi")]),
            options: RpcCallOptions(location: LocationQuery.LocationField(directory: "/repo"))
        )
        #expect(echoed == JSONValue.object(["echo": .string("hi")]))
        #expect(transport.requests.first?.url.contains("location%5Bdirectory%5D=%2Frepo") == true)

        // RpcError maps to RpcMethodErrorPayload
        do {
            _ = try await demo.call("fail")
            Issue.record("Expected RpcMethodErrorPayload")
        } catch let err as RpcMethodErrorPayload {
            #expect(err.type == "custom.denied")
            #expect(err.message == "Denied")
            #expect(err.data == .object(["code": .int(7)]))
        }

        // RPC event filtering
        let eventStream = try demo.events.subscribe("ping")
        var events: [RpcEventPayload] = []
        for try await ev in eventStream {
            events.append(ev)
        }
        #expect(events.count == 1)
        #expect(events[0].type == "rpc.demo.ping")
        #expect(events[0].data == .object(["n": .int(42)]))

        // EffectClient RPC + RpcRuntime + cooperative AbortSignal
        let effectClient = EffectClient.OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let effectDef = RpcSchema.Definition(
            id: "demo",
            methods: ["echo": RpcSchema.Method(input: anySchema, output: anySchema)],
            events: ["ping": RpcSchema.EventDefinition(schema: anySchema)]
        )
        #expect(RpcRuntime.eventType(definition: effectDef, name: "ping") == "rpc.demo.ping")
        let effectDemo = effectClient.rpc(effectDef)
        let effectOut = try await effectDemo.call("echo", input: JSONValue.object(["msg": .string("hi")]))
        #expect(effectOut == JSONValue.object(["echo": .string("hi")]))

        let preAborted = AbortSignal.aborted()
        await EffectClient.RpcClientRuntime.aborted(preAborted)
        do {
            _ = try await effectDemo.call("echo", options: RpcCallOptions(signal: preAborted))
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    // MARK: - Service Discovery, Probing, Version Matching, Contender Pool & PTY Handoff

    @Test("Service version matching, decision tree, fallback path, auth headers, probeResult, and contenderPool backoff")
    func serviceProbeDecisionAndContenderPool() async throws {
        // matchesVersion
        #expect(matchesVersion("2.1.0", options: ServiceDiscoverOptions()))
        #expect(matchesVersion(nil, options: ServiceDiscoverOptions()))
        #expect(matchesVersion("2.1.0", options: ServiceDiscoverOptions(version: .exact("2.1.0"))))
        #expect(!matchesVersion("2.0.0", options: ServiceDiscoverOptions(version: .exact("2.1.0"))))
        #expect(!matchesVersion(nil, options: ServiceDiscoverOptions(version: .exact("2.1.0"))))
        #expect(matchesVersion("2.5.0", options: ServiceDiscoverOptions(version: .predicate { $0.hasPrefix("2.") })))

        // fallback & headers & same
        let envXdg = DictionaryEnvironment(variables: ["XDG_STATE_HOME": "/var/state"], homeDirectory: "/home/alice")
        #expect(fallback(environment: envXdg) == "/var/state/opencode/service.json")
        let envHome = DictionaryEnvironment(variables: [:], homeDirectory: "/home/alice")
        #expect(fallback(environment: envHome) == "/home/alice/.local/state/opencode/service.json")

        let ep = ServiceEndpoint(url: "http://127.0.0.1:4096", auth: ServiceBasicAuth(username: "opencode", password: "secret"))
        #expect(headers(for: ep)?["authorization"] == "Basic b3BlbmNvZGU6c2VjcmV0")
        #expect(headers(for: ServiceEndpoint(url: "http://127.0.0.1:4096")) == nil)

        let infoA = ServiceInfo(id: "svc_1", version: "2.0.0", url: "http://127.0.0.1:4096", pid: 777, password: "secret")
        let infoB = ServiceInfo(id: "svc_1", version: "2.0.0", url: "http://127.0.0.1:4096", pid: 777, password: "other")
        #expect(same(infoA, infoB))

        // decide matrix
        let readySvc = LocalService(info: infoA, endpoint: ep, version: "2.0.0", state: .ready, compatible: true)
        let waitingSvc = LocalService(info: infoA, endpoint: ep, version: "2.0.0", state: .waiting, compatible: true)
        let failedSvc = LocalService(info: infoA, endpoint: ep, version: "2.0.0", state: .failed, compatible: true)
        let incompatSvc = LocalService(info: infoA, endpoint: ep, version: "2.0.0", state: .ready, compatible: false)

        #expect(decide(readySvc, options: ServiceDiscoverOptions(version: .exact("2.0.0"))) == .reuse)
        #expect(decide(waitingSvc, options: ServiceDiscoverOptions(version: .exact("2.0.0"))) == .wait)
        #expect(decide(readySvc, options: ServiceDiscoverOptions(version: .exact("3.0.0"))) == .replace(pty: .handoff))
        #expect(decide(waitingSvc, options: ServiceDiscoverOptions(version: .exact("3.0.0"))) == .replace(pty: .clear))
        if case .fail = decide(failedSvc, options: ServiceDiscoverOptions()) {} else { Issue.record("Expected fail") }
        if case .fail = decide(incompatSvc, options: ServiceDiscoverOptions()) {} else { Issue.record("Expected fail") }

        // probeResult across ready, waiting, 404 incompatible, PID mismatch, and timeout
        let readyTransport = MockHTTPTransport { _ in
            try ClientTestHelper.jsonResponse(
                status: 200,
                body: ServerInfo(version: "2.0.0", pid: 777, urls: [], paths: .init(tmp: "/tmp"))
            )
        }
        let readyProbe = await probeResult(infoA, transport: readyTransport)
        #expect(readyProbe.timedOut == false)
        #expect(readyProbe.service?.state == .ready)
        #expect(readyProbe.service?.compatible == true)

        let incompatTransport = MockHTTPTransport { _ in ClientTestHelper.emptyResponse(status: 404) }
        let incompatProbe = await probeResult(infoA, transport: incompatTransport)
        #expect(incompatProbe.service?.compatible == false)

        let mismatchTransport = MockHTTPTransport { _ in
            try ClientTestHelper.jsonResponse(
                status: 200,
                body: ServerInfo(version: "2.0.0", pid: 999, urls: [], paths: .init(tmp: "/tmp"))
            )
        }
        let mismatchProbe = await probeResult(infoA, transport: mismatchTransport)
        #expect(mismatchProbe.service == nil)

        let timeoutTransport = MockHTTPTransport { _ in throw ServiceProbeTimeoutError() }
        let timeoutProbe = await probeResult(infoA, transport: timeoutTransport)
        #expect(timeoutProbe.timedOut == true)
        #expect(timeoutProbe.service == nil)

        // ContenderPool exponential backoff, cap of 2 contenders, failure retention, stderr tail limit
        let clock = MockClock(10_000)
        let customTiming = EnsureTiming(spawnDelay: 1_000, maxSpawnDelay: 4_000)
        let pool = contenderPool(timing: customTiming, now: { clock.now() })

        // When registered is true on first tick, pool waits one spawnDelay before recruiting
        #expect(!pool.shouldRecruit(registered: true))
        clock.advance(by: 1_000)
        #expect(pool.shouldRecruit(registered: true))

        let p1 = MockChildProcess(pid: 101)
        let c1 = ServiceContender(child: p1)
        p1.emitStderr("boot error line")
        pool.add(c1)

        // Clean exit (code 0) doubles spawnDelay from 1000 -> 2000
        p1.emitExit(code: 0)
        #expect(contenderFinished(c1))
        #expect(pool.reap() == nil)
        clock.advance(by: 1_500)
        #expect(!pool.shouldRecruit(registered: false))
        clock.advance(by: 500)
        #expect(pool.shouldRecruit(registered: false))

        // Failure exit code retains error & reports once no contenders remain
        let p2 = MockChildProcess(pid: 102)
        let c2 = ServiceContender(child: p2)
        p2.emitStderr("fatal crash")
        pool.add(c2)
        p2.emitExit(code: 1)
        let failure = pool.reap()
        #expect(failure != nil)
        #expect(String(describing: failure!).contains("fatal crash"))

        // Eviction resets failure and spawn clock
        pool.evict(pid: 102)
        #expect(pool.failure() == nil)
        pool.recruitNow()
        #expect(pool.shouldRecruit(registered: false))
    }

    @Test("PtyHandoff prepare/environment/complete/clear and PromiseService/EffectClient.Service lifecycle")
    func ptyHandoffAndServiceLifecycle() async throws {
        let fs = InMemoryFileSystem()
        let clock = MockClock(1_000_000)
        let regFile = "/state/opencode/service.json"
        let oldInfo = ServiceInfo(id: "old", version: "1.0.0", url: "http://127.0.0.1:4096", pid: 500, password: "pw")
        let newInfo = ServiceInfo(id: "new", version: "2.0.0", url: "http://127.0.0.1:4097", pid: 600, password: "pw2")
        try await fs.writeFile(try ClientTestHelper.encodeJSON(oldInfo), to: regFile, createDirectories: true)

        let ticket = PersistentPtySchema.Handoff(
            directory: "/repo",
            instanceID: "inst_1",
            ticket: "handoff_tk",
            expiresAt: Double(clock.now() + 60_000)
        )
        let transport = MockHTTPTransport { request in
            if request.url.contains("/api/experimental/persistent-pty/handoff") {
                return try ClientTestHelper.jsonResponse(body: PersistentPtyHandoffResponse(handoff: ticket))
            }
            if request.url == "http://127.0.0.1:4096/api/info" {
                return try ClientTestHelper.jsonResponse(
                    body: ServerInfo(version: "1.0.0", pid: 500, urls: [], paths: .init(tmp: "/tmp"))
                )
            }
            if request.url == "http://127.0.0.1:4097/api/info" {
                return try ClientTestHelper.jsonResponse(
                    body: ServerInfo(version: "2.0.0", pid: 600, urls: [], paths: .init(tmp: "/tmp"))
                )
            }
            return ClientTestHelper.emptyResponse(status: 404)
        }

        // Prepare writes sidecar; environment injects OPENCODE_PTY_HANDOFF
        await PtyHandoff.prepare(file: regFile, info: oldInfo, fileSystem: fs, transport: transport, now: { clock.now() })
        let env = await PtyHandoff.environment(file: regFile, env: ["FOO": "bar"], fileSystem: fs, now: { clock.now() })
        #expect(env["FOO"] == "bar")
        #expect(env["OPENCODE_PTY_HANDOFF"]?.contains("handoff_tk") == true)

        // EffectClient.Service.incumbent recognizes incumbent service on explicit URL
        let inc = await EffectClient.Service.incumbent(
            url: "http://127.0.0.1:4096",
            options: ServiceDiscoverOptions(file: regFile),
            fileSystem: fs,
            transport: transport
        )
        #expect(inc?.state == .ready)
        #expect(inc?.endpoint.auth?.password == "pw")

        // PromiseService.ensure replaces version-mismatched old service, spawns contender, and completes handoff
        let signaler = MockServiceSignaler(runningPids: [500], ignoreSigTermPids: [500]) // tests SIGTERM -> SIGKILL escalation!
        let launcher = MockServiceLauncher { _, _, spawnEnv in
            #expect(spawnEnv["OPENCODE_PTY_HANDOFF"]?.contains("handoff_tk") == true)
            let proc = MockChildProcess(pid: 600)
            Task {
                try? await fs.writeFile(try ClientTestHelper.encodeJSON(newInfo), to: regFile, createDirectories: true)
            }
            return proc
        }
        let startReasons = Mutex<[(ServiceEnsureReason, String?)]>([])
        let ensureOpts = withEnsureTiming(
            ServiceEnsureOptions(
                file: regFile,
                version: .exact("2.0.0"),
                onStart: { reason, prev in startReasons.withLock { $0.append((reason, prev)) } }
            ),
            overrides: EnsureTimingOverrides(
                pollInterval: 1,
                requestTimeout: 500,
                spawnDelay: 1,
                maxSpawnDelay: 10,
                promiseTimeout: 5_000,
                stopPollInterval: 1,
                stopPollAttempts: 2
            )
        )
        #expect(ensureTiming(ensureOpts).pollInterval == 1)

        let ensured = try await PromiseService.ensure(
            options: ensureOpts,
            fileSystem: fs,
            transport: transport,
            launcher: launcher,
            signaler: signaler,
            now: { clock.now() }
        )
        #expect(ensured.url == "http://127.0.0.1:4097")
        #expect(ensured.auth?.password == "pw2")
        #expect(signaler.signalsSent.contains { $0.pid == 500 && $0.signal == "SIGTERM" })
        #expect(signaler.signalsSent.contains { $0.pid == 500 && $0.signal == "SIGKILL" })
        #expect(startReasons.withLock { $0.first?.0 } == .versionMismatch)
        #expect(startReasons.withLock { $0.first?.1 } == "1.0.0")
        // Sidecar cleared once new service identity won
        #expect(await fs.exists(at: regFile + ".pty-handoff") == false)
    }

    // MARK: - Client MCP Over WebSocket

    @Test("connectClientMcp answers initialize, ping, tools/list, tools/call (including sessionID & errors), and unknown methods")
    func clientMcpWebSocketJsonRpc() async throws {
        let wsFactory = MockWebSocketFactory()
        let capturedSessionIDs = Mutex<[String?]>([])

        let tool = ClientMcpTool(
            name: "greet",
            description: "Greets a caller",
            inputSchema: ["properties": .object(["who": .object(["type": .string("string")])])],
            handler: { args, ctx in
                capturedSessionIDs.withLock { $0.append(ctx.sessionID) }
                if case .string(let who) = args["who"] {
                    if who == "boom" { throw ServiceLifecycleError("exploded") }
                    return ClientMcpToolResult(content: [.text("Hello, \(who)!")])
                }
                return ClientMcpToolResult(content: [.text("Hello!")])
            }
        )

        let connection = connectClientMcp(
            options: ClientMcpOptions(
                url: "https://opencode.local/base?ticket=tk1",
                name: "ide",
                directory: "/repo",
                tools: [tool],
                webSocketFactory: wsFactory,
                reconnectMinMs: 5,
                reconnectMaxMs: 20
            )
        )

        // Wait briefly for connection task to open the socket
        for _ in 0..<50 {
            if !wsFactory.sockets.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let socket = try #require(wsFactory.sockets.first)
        let connectedURL = try #require(wsFactory.connectedURLs.first)
        #expect(connectedURL.hasPrefix("wss://opencode.local/base/api/experimental/client-mcp?"))
        #expect(connectedURL.contains("ticket=tk1"))
        #expect(connectedURL.contains("location%5Bdirectory%5D=%2Frepo"))
        #expect(connectedURL.contains("name=ide"))

        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"who\":\"world\"},\"_meta\":{\"ai.opencode/sessionID\":\"ses_42\"}}}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"who\":\"boom\"}}}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"missing\"}}")
        socket.pushServerText("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"unknown/method\"}")

        for _ in 0..<100 {
            if socket.sentTexts.count >= 7 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(socket.sentTexts.count == 7)
        #expect(capturedSessionIDs.withLock { $0 } == ["ses_42", nil])

        let replies = try socket.sentTexts.map { try ClientTestHelper.decodeJSON(JSONValue.self, from: $0) }
        #expect("\(replies[0])".contains("2025-11-25"))
        #expect("\(replies[2])".contains("greet"))
        #expect("\(replies[3])".contains("Hello, world!"))
        #expect("\(replies[4])".contains("exploded") && "\(replies[4])".contains("isError"))
        #expect("\(replies[5])".contains("-32602"))
        #expect("\(replies[6])".contains("-32601"))

        await connection.close()
        #expect(socket.closedCode == 1000)
    }

    // MARK: - Reactive State Stores (Usage, Persistent PTY, Connection, Retention, Data Store)

    @Test("lastAssistantWithUsage selects latest token-bearing assistant after completed compaction and before boundary")
    func usageCalculationAcrossCompactionAndBoundary() throws {
        let model = SessionSchema.ModelRef(id: "claude", providerID: "anthropic")
        let tokens1 = SessionSchema.TokenUsage(input: 100, output: 20, reasoning: 0, cache: .init(read: 0, write: 0))
        let tokens2 = SessionSchema.TokenUsage(input: 250, output: 40, reasoning: 0, cache: .init(read: 0, write: 0))

        let m1 = SessionMessageSchema.Info.assistant(
            SessionMessageSchema.Assistant(
                id: try SessionMessageSchema.ID(validating: "msg_1"),
                agent: "build", model: model, content: [], tokens: tokens1,
                time: .init(created: 1)
            )
        )
        let compact = SessionMessageSchema.Info.compaction(
            .completed(SessionMessageSchema.CompactionCompleted(
                id: try SessionMessageSchema.ID(validating: "msg_2"),
                time: .init(created: 2), reason: .auto, summary: "sum"
            ))
        )
        let m3 = SessionMessageSchema.Info.assistant(
            SessionMessageSchema.Assistant(
                id: try SessionMessageSchema.ID(validating: "msg_3"),
                agent: "build", model: model, content: [], tokens: tokens2,
                time: .init(created: 3)
            )
        )
        let m4 = SessionMessageSchema.Info.assistant(
            SessionMessageSchema.Assistant(
                id: try SessionMessageSchema.ID(validating: "msg_4"),
                agent: "build", model: model, content: [], tokens: nil,
                time: .init(created: 4)
            )
        )

        #expect(lastAssistantWithUsage([m1, compact, m3, m4])?.id.rawValue == "msg_3")
        // Boundary before compaction picks m1
        #expect(lastAssistantWithUsage([m1, compact, m3, m4], boundary: "msg_2")?.id.rawValue == "msg_1")
        // Boundary right after compaction finds none
        #expect(lastAssistantWithUsage([m1, compact, m3, m4], boundary: "msg_3") == nil)
        // Missing boundary returns nil
        #expect(lastAssistantWithUsage([m1, compact, m3, m4], boundary: "msg_missing") == nil)
    }

    @Test("Persistent PTY message decoding, binary framing, and ticketed WebSocket connect")
    func persistentPtyProtocolAndConnect() async throws {
        let attached = decodePersistentPtyMessage(
            "{\"type\":\"attached\",\"inputProtocol\":1,\"info\":{\"size\":{\"cols\":120,\"rows\":40}},\"role\":\"controller\"}"
        )
        #expect(attached == .attached(
            inputProtocol: 1,
            info: .init(size: PersistentPtySchema.Size(
                cols: try SchemaPrimitive.PositiveInt(validating: 120),
                rows: try SchemaPrimitive.PositiveInt(validating: 40)
            )),
            role: .controller
        ))
        #expect(decodePersistentPtyMessage("{\"type\":\"replay_complete\"}") == .replayComplete)
        #expect(decodePersistentPtyMessage("{\"type\":\"resized\",\"cols\":80,\"rows\":24,\"checkpoint\":\"cp1\"}") == .resized(cols: 80, rows: 24, checkpoint: "cp1"))
        #expect(decodePersistentPtyMessage("{\"type\":\"exited\",\"exitCode\":0}") == .exited(exitCode: 0))
        #expect(decodePersistentPtyMessage("{\"type\":\"title_changed\",\"title\":\"zsh\"}") == .titleChanged(title: "zsh"))
        #expect(decodePersistentPtyMessage("{\"type\":\"foreground_process_changed\",\"process\":null}") == .foregroundProcessChanged(process: nil))
        #expect(decodePersistentPtyMessage("{\"type\":\"bogus\"}") == nil)

        // Binary framing: big-endian cols/rows + kind byte
        let resizeFrame = persistentPtyFrame(cols: 300, rows: 40)
        #expect(resizeFrame == [0, 0x01, 0x2C, 0x00, 0x28])
        let dataFrame = persistentPtyFrame(cols: 80, rows: 24, data: [0x61, 0x62])
        #expect(dataFrame == [1, 0x00, 0x50, 0x00, 0x18, 0x61, 0x62])

        // Ticket exchange + WS URL construction
        let transport = MockHTTPTransport { request in
            #expect(request.headers["x-opencode-ticket"] == "1")
            return try ClientTestHelper.jsonResponse(
                body: ClientDataEnvelope(
                    data: PtyTicketSchema.ConnectToken(
                        ticket: "pt_99",
                        expiresIn: try SchemaPrimitive.PositiveInt(validating: 60)
                    )
                )
            )
        }
        let wsFactory = MockWebSocketFactory()
        let api = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let ptyClient = createPersistentPtyClient(api, options: PtyClientOptions(url: "https://host.test/api-root", webSocketFactory: wsFactory))
        _ = try await ptyClient.connect(
            PersistentPtyConnectInput(ptyID: "pty_abc", cursor: 12, attachmentID: "att_1", takeover: true)
        )
        let wsURL = try #require(wsFactory.connectedURLs.first)
        #expect(wsURL.hasPrefix("wss://host.test/api-root/api/experimental/persistent-pty/pty_abc/connect?"))
        #expect(wsURL.contains("ticket=pt_99"))
        #expect(wsURL.contains("cursor=12"))
        #expect(wsURL.contains("attachment_id=att_1"))
        #expect(wsURL.contains("takeover=true"))
        #expect(wsURL.contains("input_protocol=1"))
    }

    @Test("ClientConnection connects on server.connected, batches events, records history, and resyncs")
    func clientConnectionLifecycle() async throws {
        let connected = try ClientTestHelper.encodeJSONString(
            OpenCodeEvent(id: "evt_0", type: "server.connected", created: 100, data: .object([:]))
        )
        let renamed = try ClientTestHelper.encodeJSONString(
            OpenCodeEvent(id: "evt_1", type: "session.renamed", created: 200, data: .object(["sessionID": .string("ses_1"), "title": .string("Hi")]))
        )

        let transport = MockHTTPTransport(streamHandler: { _ in
            ClientTestHelper.sseResponse(
                chunks: [Array("data: \(connected)\n\ndata: \(renamed)\n\n".utf8)],
                keepOpen: true
            )
        })
        let api = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let received = Mutex<[OpenCodeEvent]>([])

        let conn = createClientConnection(
            api,
            options: ClientConnectionOptions(
                onEvent: { ev in received.withLock { $0.append(ev) } },
                flushInterval: 0,
                reconnectDelay: 5
            )
        )

        for _ in 0..<100 {
            if conn.status() == .connected && received.withLock({ $0.count }) >= 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(conn.status() == .connected)
        #expect(conn.attempt() == 0)
        #expect(received.withLock { $0.map(\.type) } == ["server.connected", "session.renamed"])
        #expect(conn.history().contains { $0.data.status == .connected })
        #expect(defaultIdleTimeout == 45_000)
        #expect(foregroundIdleThreshold == 20_000)

        conn.dispose()
    }

    @Test("ClientDataStore & SessionRetention handle optimistic mutations, live event projections, tool file omission, and LRU eviction")
    func reactiveDataStoreAndRetention() async throws {
        #expect(settleMs == 150)
        #expect(locationKey(LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/repo"))) == "[\"/repo\",null]")
        #expect(
            locationKey(
                LocationSchema.Ref(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: "/repo"),
                    workspaceID: WorkspaceID(rawValue: "wrk_1")
                )
            ) == "[\"/repo\",\"wrk_1\"]"
        )

        let failNextCreate = Mutex(false)
        let transport = MockHTTPTransport { request in
            if request.url.hasSuffix("/api/session") && request.method == "POST" {
                if failNextCreate.withLock({ $0 }) {
                    return try ClientTestHelper.jsonResponse(
                        status: 400,
                        body: ProtocolErrorEnvelope.invalidRequest(InvalidRequestError(message: "bad create"))
                    )
                }
                let bodyObj = try ClientTestHelper.decodeJSON(JSONValue.self, from: request.body ?? [])
                var idStr = "ses_default"
                if case .object(let obj) = bodyObj, case .string(let id) = obj["id"] { idStr = id }
                let info = SessionSchema.Info(
                    id: try SessionID(validating: idStr),
                    projectID: ProjectID(rawValue: "proj_1"),
                    cost: 1.5,
                    tokens: .init(input: 10, output: 5, reasoning: 0, cache: .init(read: 0, write: 0)),
                    time: .init(created: 100, updated: 200),
                    title: "Created",
                    location: .init(directory: "/repo")
                )
                return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: info))
            }
            if request.url.contains("/prompt") && request.method == "POST" {
                let bodyObj = try ClientTestHelper.decodeJSON(JSONValue.self, from: request.body ?? [])
                var idStr = "msg_1"
                if case .object(let obj) = bodyObj, case .string(let id) = obj["id"] { idStr = id }
                let userInbox = SessionInboxSchema.User(
                    id: try SessionMessageSchema.ID(validating: idStr),
                    sessionID: try SessionID(validating: "ses_1"),
                    time: .init(created: 300),
                    payload: .init(text: "Hello"),
                    delivery: .steer
                )
                return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: userInbox))
            }
            return ClientTestHelper.emptyResponse(status: 204)
        }

        let bus = ClientDataEventBus()
        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let store = createData(
            CreateDataInput(
                api: { client },
                directory: "/repo",
                event: bus,
                omitToolFileData: { true }
            )
        )

        let observerCalls = Mutex(0)
        let unsub = store.onChange { observerCalls.withLock { $0 += 1 } }

        // 1. Optimistic create success & rollback on error
        let created = try await store.createSession(id: "ses_1", title: "Draft")
        #expect(created.id.rawValue == "ses_1")
        #expect(store.getSession("ses_1")?.title == "Created")

        failNextCreate.withLock { $0 = true }
        do {
            _ = try await store.createSession(id: "ses_fail", title: "Will Rollback")
            Issue.record("Expected failure")
        } catch {
            #expect(isInvalidRequestError(error))
            #expect(store.getSession("ses_fail") == nil)
        }

        // 2. Optimistic prompt admission & pendingStatus (.starting -> .queued via event)
        _ = try await store.prompt(SessionPromptInput(sessionID: "ses_1", id: "msg_u1", text: "Hello"))
        #expect(store.pendingStatus("ses_1", inboxID: "msg_u1") == .starting)
        bus.emit(
            OpenCodeEvent(
                id: "evt_chg",
                type: "session.inbox.delivery.changed",
                created: 310,
                data: .object(["sessionID": .string("ses_1"), "inboxID": .string("msg_u1"), "delivery": .string("queue")])
            )
        )
        #expect(store.pendingStatus("ses_1", inboxID: "msg_u1") == .queued)

        // 3. Live streaming assistant step + text delta + execution succeeded idle marker
        bus.emit(
            OpenCodeEvent(
                id: "evt_run",
                type: "session.execution.started",
                created: 400,
                data: .object(["sessionID": .string("ses_1")])
            )
        )
        #expect(store.sessionStatus("ses_1") == .running)

        bus.emit(
            OpenCodeEvent(
                id: "evt_step",
                type: "session.step.started",
                created: 410,
                data: .object([
                    "sessionID": .string("ses_1"),
                    "assistantMessageID": .string("msg_a1"),
                    "agent": .string("build"),
                    "model": .object(["id": .string("claude"), "providerID": .string("anthropic")]),
                    "started": .int(410),
                ])
            )
        )
        bus.emit(OpenCodeEvent(id: "evt_ts", type: "session.text.started", created: 411, data: .object(["sessionID": .string("ses_1"), "assistantMessageID": .string("msg_a1")])))
        bus.emit(OpenCodeEvent(id: "evt_td", type: "session.text.delta", created: 412, data: .object(["sessionID": .string("ses_1"), "assistantMessageID": .string("msg_a1"), "delta": .string("Hi there")])))
        bus.emit(OpenCodeEvent(id: "evt_te", type: "session.text.ended", created: 413, data: .object(["sessionID": .string("ses_1"), "assistantMessageID": .string("msg_a1"), "text": .string("Hi there!")])))
        bus.emit(OpenCodeEvent(id: "evt_done", type: "session.execution.succeeded", created: 420, data: .object(["sessionID": .string("ses_1")])))

        #expect(store.sessionStatus("ses_1") == .idle)
        if case .assistant(let a) = store.message("ses_1", messageID: "msg_a1"),
           case .text(let t) = a.content.first {
            #expect(t.text == "Hi there!")
        } else {
            Issue.record("Expected projected assistant message text")
        }
        #expect(store.messages("ses_1").contains { if case .idle = $0 { return true }; return false })

        // 4. Child session family & root cost aggregation + SessionRetention LRU eviction
        let child = SessionSchema.Info(
            id: try SessionID(validating: "ses_child"),
            parentID: try SessionID(validating: "ses_1"),
            projectID: ProjectID(rawValue: "proj_1"),
            cost: 0.75,
            tokens: .init(input: 5, output: 5, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: .init(created: 500, updated: 500),
            location: .init(directory: "/repo")
        )
        let otherRoot = SessionSchema.Info(
            id: try SessionID(validating: "ses_other"),
            projectID: ProjectID(rawValue: "proj_1"),
            cost: 0.25,
            tokens: .init(input: 1, output: 1, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: .init(created: 600, updated: 600),
            location: .init(directory: "/repo")
        )
        store.rememberSession(child)
        store.rememberSession(otherRoot)
        #expect(store.rootSession("ses_child") == "ses_1")
        #expect(store.sessionCost("ses_1") == 2.25)
        #expect(store.sessionCost("ses_child") == 0.75)

        let currentNav = Mutex<String?>("ses_other")
        let evictedRoots = Mutex<[String]>([])
        let retention = createSessionRetention(
            SessionRetentionInput(
                listSessions: { store.listSessions() },
                rootSession: { store.rootSession($0) },
                evictSession: { root in
                    evictedRoots.withLock { $0.append(root) }
                    store.evictSession(root)
                },
                messageCount: { store.messages($0).count },
                current: { currentNav.withLock { $0 } },
                keep: { [] },
                limit: 0
            )
        )
        #expect(evictedRoots.withLock { $0.contains("ses_1") })
        _ = retention

        #expect(observerCalls.withLock { $0 } > 0)
        unsub()
        store.dispose()
    }

    @Test("PromiseService.ensure recovers after 3 consecutive probe timeouts and PtyHandoff falls back to shutdown on failure")
    func unresponsiveServiceRecoveryAndHandoffFallback() async throws {
        let fs = InMemoryFileSystem()
        let clock = MockClock(2_000_000)
        let regFile = "/state/opencode/service.json"
        let hungInfo = ServiceInfo(id: "hung", version: "2.0.0", url: "http://127.0.0.1:4100", pid: 800, password: "pw")
        let healthyInfo = ServiceInfo(id: "ok", version: "2.0.0", url: "http://127.0.0.1:4101", pid: 801, password: "pw2")
        try await fs.writeFile(try ClientTestHelper.encodeJSON(hungInfo), to: regFile, createDirectories: true)

        let shutdownCalled = Mutex(false)
        let transport = MockHTTPTransport { request in
            if request.url.contains("/api/experimental/persistent-pty/handoff") {
                return ClientTestHelper.emptyResponse(status: 503)
            }
            if request.url.contains("/api/experimental/persistent-pty/shutdown") {
                shutdownCalled.withLock { $0 = true }
                return ClientTestHelper.emptyResponse(status: 204)
            }
            if request.url == "http://127.0.0.1:4100/api/info" {
                throw ServiceProbeTimeoutError()
            }
            if request.url == "http://127.0.0.1:4101/api/info" {
                return try ClientTestHelper.jsonResponse(
                    body: ServerInfo(version: "2.0.0", pid: 801, urls: [], paths: .init(tmp: "/tmp"))
                )
            }
            return ClientTestHelper.emptyResponse(status: 404)
        }

        // 1. PtyHandoff.prepare falls back to persistentPty.shutdown when handoff fails
        await PtyHandoff.prepare(file: regFile, info: hungInfo, fileSystem: fs, transport: transport, now: { clock.now() })
        #expect(shutdownCalled.withLock { $0 } == true)
        let envAfterFallback = await PtyHandoff.environment(file: regFile, fileSystem: fs, now: { clock.now() })
        #expect(envAfterFallback["OPENCODE_PTY_HANDOFF"] == nil)

        // 2. PromiseService.discover returns nil for unresponsive service
        let discovered = await PromiseService.discover(
            options: ServiceDiscoverOptions(file: regFile),
            fileSystem: fs,
            transport: transport
        )
        #expect(discovered == nil)

        // 3. PromiseService.ensure terminates hung PID after 3 consecutive timeouts and spawns replacement
        let signaler = MockServiceSignaler(runningPids: [800])
        let launcher = MockServiceLauncher { _, _, _ in
            let child = MockChildProcess(pid: 801)
            Task {
                try? await fs.writeFile(try ClientTestHelper.encodeJSON(healthyInfo), to: regFile, createDirectories: true)
            }
            return child
        }
        let opts = withEnsureTiming(
            ServiceEnsureOptions(file: regFile),
            overrides: EnsureTimingOverrides(
                pollInterval: 1,
                requestTimeout: 50,
                spawnDelay: 100,
                maxSpawnDelay: 200,
                promiseTimeout: 5_000,
                stopPollInterval: 1,
                stopPollAttempts: 5
            )
        )
        let endpoint = try await PromiseService.ensure(
            options: opts,
            fileSystem: fs,
            transport: transport,
            launcher: launcher,
            signaler: signaler,
            now: { clock.now() }
        )
        #expect(endpoint.url == "http://127.0.0.1:4101")
        #expect(signaler.signalsSent.contains { $0.pid == 800 && $0.signal == "SIGTERM" })
    }

    @Test("ClientDataStore handles revert commit pruning, worktree adoption, global form headers, and omitToolFileData")
    func dataStoreRevertWorktreeFormsAndToolFileOmission() async throws {
        let transport = MockHTTPTransport { _ in
            ClientTestHelper.emptyResponse(status: 204)
        }
        let bus = ClientDataEventBus()
        let client = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let store = createData(
            CreateDataInput(
                api: { client },
                directory: "/repo",
                event: bus,
                omitToolFileData: { true }
            )
        )

        let session = SessionSchema.Info(
            id: try SessionID(validating: "ses_adopt"),
            projectID: ProjectID.global,
            cost: 0,
            tokens: .init(input: 0, output: 0, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: .init(created: 10, updated: 10),
            location: .init(directory: "/repo/packages/sub")
        )
        store.rememberSession(session)

        // Worktree adoption updates projectID & subpath
        bus.emit(
            OpenCodeEvent(
                id: "evt_wt",
                type: "worktree.resolved",
                created: 20,
                data: .object([
                    "projectID": .string("proj_real"),
                    "directory": .string("/repo"),
                    "previous": .string("global"),
                ])
            )
        )
        #expect(store.getSession("ses_adopt")?.projectID.rawValue == "proj_real")
        #expect(store.getSession("ses_adopt")?.subpath == "packages/sub")

        // Global form preserves event location and sends x-opencode-directory header on reply
        let globalLoc = OpenCodeLocation(directory: "/repo/a b")
        let formJSON = try ClientTestHelper.decodeJSON(
            JSONValue.self,
            from: "{\"id\":\"frm_1\",\"sessionID\":\"global\",\"title\":\"Auth\",\"fields\":[{\"key\":\"ok\",\"type\":\"boolean\"}],\"time\":{\"created\":50}}"
        )
        bus.emit(
            OpenCodeEvent(
                id: "evt_form",
                type: "form.created",
                created: 50,
                location: globalLoc,
                data: .object(["form": formJSON])
            )
        )
        let locRef = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/repo/a b"))
        #expect(store.forms("global", location: locRef)?.count == 1)
        try await store.replyForm(
            SessionFormReplyInput(sessionID: "global", formID: "frm_1", answer: ["ok": .bool(true)]),
            location: locRef
        )
        #expect(store.forms("global", location: locRef)?.isEmpty == true)
        #expect(transport.requests.last?.headers["x-opencode-directory"] == "%2Frepo%2Fa%20b")

        // Revert commit prunes messages >= to boundary
        bus.emit(
            OpenCodeEvent(
                id: "evt_s1",
                type: "session.step.started",
                created: 100,
                data: .object([
                    "sessionID": .string("ses_adopt"),
                    "assistantMessageID": .string("msg_001"),
                    "agent": .string("build"),
                    "model": .object(["id": .string("m"), "providerID": .string("p")]),
                    "started": .int(100),
                ])
            )
        )
        bus.emit(
            OpenCodeEvent(
                id: "evt_s2",
                type: "session.step.started",
                created: 110,
                data: .object([
                    "sessionID": .string("ses_adopt"),
                    "assistantMessageID": .string("msg_002"),
                    "agent": .string("build"),
                    "model": .object(["id": .string("m"), "providerID": .string("p")]),
                    "started": .int(110),
                ])
            )
        )
        #expect(store.messages("ses_adopt").count == 2)
        bus.emit(
            OpenCodeEvent(
                id: "evt_rev",
                type: "session.revert.committed",
                created: 120,
                data: .object(["sessionID": .string("ses_adopt"), "to": .string("msg_002")])
            )
        )
        #expect(store.messages("ses_adopt").map(\.id.rawValue) == ["msg_001"])

        store.dispose()
    }

    @Test("Additional Promise & Effect endpoints: model.default(null), generate.text, artifacts.view binary, session.log SSE, and EffectClient error wrapping")
    func additionalGroupsAndEffectClient() async throws {
        let logEvent = try ClientTestHelper.encodeJSONString(
            SessionLogItem.event(OpenCodeEvent(id: "evt_10", type: "session.created", created: 10, data: .object([:])))
        )
        let logSynced = try ClientTestHelper.encodeJSONString(
            SessionLogItem.synced(
                EventLogSchema.Synced(aggregateID: "ses_1", seq: try EventSchema.Seq(validating: 5))
            )
        )

        let transport = MockHTTPTransport(
            sendHandler: { request in
                if request.url.contains("/api/model/default") {
                    let body: LocationSchema.ResponseEnvelope<ModelSchema.Info?> = LocationSchema.ResponseEnvelope(
                        location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/repo")),
                        data: nil
                    )
                    return try ClientTestHelper.jsonResponse(body: body)
                }
                if request.url.contains("/api/experimental/generate/text") {
                    return try ClientTestHelper.jsonResponse(body: ClientDataEnvelope(data: GenerateTextData(text: "Generated!")))
                }
                if request.url.contains("/api/experimental/artifacts/art_1/view/index.html") {
                    return ClientTestHelper.binaryResponse(bytes: Array("<h1>ok</h1>".utf8), contentType: "text/html")
                }
                return ClientTestHelper.emptyResponse(status: 404)
            },
            streamHandler: { request in
                if request.url.contains("/api/experimental/session/ses_1/log") {
                    return ClientTestHelper.sseResponse(
                        chunks: [Array("data: \(logEvent)\n\ndata: \(logSynced)\n\n".utf8)]
                    )
                }
                // Wrong content type on /api/event -> EffectClient wraps into EffectClient.ClientError
                return ClientTestHelper.sseResponse(contentType: "text/plain", chunks: [])
            }
        )

        let promiseClient = OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let defaultModel = try await promiseClient.model.`default`(
            ModelDefaultInput(location: LocationQuery.LocationField(directory: "/repo"))
        )
        #expect(defaultModel.data == nil)
        #expect(defaultModel.location.directory.rawValue == "/repo")

        let gen = try await promiseClient.generate.text(GenerateTextInput(prompt: "hi"))
        #expect(gen.text == "Generated!")

        let htmlBytes = try await promiseClient.experimental.artifacts.view(
            ExperimentalArtifactsViewInput(artifactID: "art_1", path: "index.html")
        )
        #expect(String(decoding: htmlBytes, as: UTF8.self) == "<h1>ok</h1>")

        var logItems: [SessionLogItem] = []
        for try await item in promiseClient.experimental.session.log(ExperimentalSessionLogInput(sessionID: "ses_1", after: 0, follow: false)) {
            logItems.append(item)
        }
        #expect(logItems.count == 2)
        if case .synced(let s) = logItems[1] {
            #expect(s.aggregateID == "ses_1")
            #expect(s.seq?.rawValue == 5)
        } else {
            Issue.record("Expected synced log item")
        }

        // EffectClient wraps stream errors into EffectClient.ClientError
        let effectClient = EffectClient.OpenCode.make(ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        do {
            for try await _ in effectClient.event.subscribe() {}
            Issue.record("Expected EffectClient.ClientError")
        } catch let err as EffectClient.ClientError {
            #expect(EffectClient.ClientError.tag == "ClientError")
            #expect(err.description.contains("UnsupportedContentType"))
        }
    }
}
