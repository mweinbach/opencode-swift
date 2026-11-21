import Testing
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

// MARK: - 1. Auth, Pairing, CORS, RequestSite, ByteRange, ContentHeaders & Primitives

@Suite("OpenCodeServer Auth & Middleware Primitives")
struct OpenCodeServerAuthAndMiddlewareTests {
    @Test("ServerAuth password, HMAC-SHA256 session tokens, expiry, and rotation revocation")
    func serverAuthSessionTokens() throws {
        let disabled = ServerAuth.Info(password: nil)
        #expect(!ServerAuth.required(disabled))
        #expect(ServerAuth.issueSession(disabled) == nil)
        #expect(!ServerAuth.verifySession("123.abc", config: disabled))

        let config = ServerAuth.Info(password: "super-secret-pass", username: "opencode")
        #expect(ServerAuth.required(config))

        let nowMs: Int64 = 1_700_000_000_000
        let token = try #require(ServerAuth.issueSession(config, nowMs: nowMs))
        #expect(ServerAuth.verifySession(token, config: config, nowMs: nowMs + 1000))
        // Tampered token fails
        #expect(!ServerAuth.verifySession(token + "x", config: config, nowMs: nowMs + 1000))
        // Expired token fails
        let afterExpiry = nowMs + Int64(ServerAuth.SESSION_TTL_SECONDS + 10) * 1000
        #expect(!ServerAuth.verifySession(token, config: config, nowMs: afterExpiry))
        // Password rotation immediately revokes all existing sessions
        let rotated = ServerAuth.Info(password: "new-secret-pass", username: "opencode")
        #expect(!ServerAuth.verifySession(token, config: rotated, nowMs: nowMs + 1000))

        // Basic credential authorization accepts both password and session token
        #expect(ServerAuth.authorized(ServerAuth.DecodedCredentials(username: "opencode", password: "super-secret-pass"), config: config, nowMs: nowMs))
        #expect(ServerAuth.authorized(ServerAuth.DecodedCredentials(username: "opencode", password: token), config: config, nowMs: nowMs))
        #expect(!ServerAuth.authorized(ServerAuth.DecodedCredentials(username: "wrong", password: "super-secret-pass"), config: config, nowMs: nowMs))
        #expect(!ServerAuth.authorized(ServerAuth.DecodedCredentials(username: "opencode", password: "wrong"), config: config, nowMs: nowMs))

        // Port-scoped cookie name
        #expect(ServerAuth.sessionCookieName("localhost:4096") == "opencode_session_4096")
        #expect(ServerAuth.sessionCookieName("opencode.local") == "opencode_session")
        #expect(ServerAuth.sessionCookieName(nil) == "opencode_session")
    }

    @Test("Authorization middleware supports Basic, Bearer, auth_token query, same-origin cookie, and suppresses browser fetch challenge")
    func authorizationRequestVariants() throws {
        let config = ServerAuth.Info(password: "pw-123", username: "opencode")
        let token = try #require(ServerAuth.issueSession(config))

        // Basic auth
        let basicReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: ["authorization": "Basic " + bytesToBase64(Array("opencode:pw-123".utf8))]
        )
        #expect(authorizedRequest(basicReq, config: config))

        // Bearer auth with session token
        let bearerReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: ["authorization": "Bearer \(token)"]
        )
        #expect(authorizedRequest(bearerReq, config: config))

        // Query auth_token
        let queryReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/info?auth_token=\(base64Encode("opencode:\(token)"))"
        )
        #expect(authorizedRequest(queryReq, config: config))

        // Same-origin session cookie accepted; cross-origin rejected
        let sameOriginCookieReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: [
                "host": "127.0.0.1:4096",
                "origin": "http://127.0.0.1:4096",
                "cookie": "opencode_session_4096=\(token)",
            ]
        )
        #expect(authorizedRequest(sameOriginCookieReq, config: config))

        let crossOriginCookieReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: [
                "host": "127.0.0.1:4096",
                "origin": "http://127.0.0.1:9999",
                "cookie": "opencode_session_4096=\(token)",
            ]
        )
        #expect(!authorizedRequest(crossOriginCookieReq, config: config))

        // WWW-Authenticate challenge sent for non-browser / navigate, omitted for fetch cors mode
        let cliResp = unauthorizedResponse(ServerHTTPRequest(method: "GET", url: "/api/info"))
        #expect(cliResp.statusCode == 401)
        #expect(ServerHeaders.value(in: cliResp.headers, for: "www-authenticate") == "Basic realm=\"Secure Area\"")

        let fetchResp = unauthorizedResponse(ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: ["sec-fetch-mode": "cors"]
        ))
        #expect(fetchResp.statusCode == 401)
        #expect(ServerHeaders.value(in: fetchResp.headers, for: "www-authenticate") == nil)

        // Pairing link and ticketed PTY connect bypass authorizationLayer
        #expect(authorizationLayer(config, PAIRING_CONNECT_PATH, ServerHTTPRequest(method: "GET", url: "/auth/connect/abc")) == nil)
        #expect(authorizationLayer(config, PTY_CONNECT_PATH, ServerHTTPRequest(method: "GET", url: "/api/pty/pty_1/connect?ticket=tok")) == nil)
        #expect(authorizationLayer(config, "/api/info", ServerHTTPRequest(method: "GET", url: "/api/info"))?.statusCode == 401)
    }

    @Test("CORS and RequestSite origin & cross-site protection rules")
    func corsAndRequestSite() {
        #expect(isAllowedCorsOrigin(nil))
        #expect(isAllowedCorsOrigin("http://localhost:3000"))
        #expect(isAllowedCorsOrigin("http://127.0.0.1:5173"))
        #expect(isAllowedCorsOrigin("oc://renderer"))
        #expect(isAllowedCorsOrigin("tauri://localhost"))
        #expect(isAllowedCorsOrigin("https://opencode.ai"))
        #expect(isAllowedCorsOrigin("https://app.opencode.ai"))
        #expect(!isAllowedCorsOrigin("https://evil.example.com"))
        #expect(isAllowedCorsOrigin("https://custom.example.com", opts: CorsOptions(cors: ["https://custom.example.com"])))

        #expect(isAllowedRequestOrigin("http://myhost:4096", host: "myhost:4096"))
        #expect(!isAllowedRequestOrigin("http://evil.com", host: "myhost:4096"))

        // RequestSite blocks cross-site browser navigation to /api/*
        let crossNav = ServerHTTPRequest(
            method: "GET",
            url: "/api/info",
            headers: ["sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate"]
        )
        #expect(RequestSite.rejected(crossNav))

        // RequestSite allows opaque-origin sandboxed artifact views
        let artifactView = ServerHTTPRequest(
            method: "GET",
            url: "/api/experimental/artifacts/art_123/view/index.html",
            headers: ["sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate"]
        )
        #expect(!RequestSite.rejected(artifactView))

        // Non-browser requests pass
        #expect(!RequestSite.rejected(ServerHTTPRequest(method: "GET", url: "/api/info")))
    }

    @Test("ByteRange parser, ContentHeaders XSS neutralization, MediaURI, Pairing, ServiceStatus, ServerInfo")
    func serverUtilitiesParity() {
        // ByteRange
        #expect(ByteRange.parse(nil, size: 10) == nil)
        #expect(ByteRange.parse("bytes=0-4", size: 10) == .range(ByteRange.Slice(start: 0, end: 4)))
        #expect(ByteRange.parse("bytes=5-", size: 10) == .range(ByteRange.Slice(start: 5, end: 9)))
        #expect(ByteRange.parse("bytes=-3", size: 10) == .range(ByteRange.Slice(start: 7, end: 9)))
        #expect(ByteRange.parse("bytes=0-99", size: 10) == .range(ByteRange.Slice(start: 0, end: 9)))
        #expect(ByteRange.parse("bytes=10-12", size: 10) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=-0", size: 10) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=0-1, 3-4", size: 10) == nil) // multi-range falls back to full 200
        #expect(ByteRange.parse("bytes=-", size: 10) == nil)

        // ContentHeaders
        let htmlHeaders = ContentHeaders.download(path: "/dir/page (1).html", mime: "text/html")
        #expect(htmlHeaders["content-type"] == "text/plain; charset=utf-8")
        #expect(htmlHeaders["x-content-type-options"] == "nosniff")
        #expect(htmlHeaders["content-security-policy"] == ContentHeaders.CONTENT_SECURITY_POLICY)
        #expect(htmlHeaders["content-disposition"]?.contains("filename*=UTF-8''page%20%281%29.html") == true)

        let svgHeaders = ContentHeaders.download(path: "icon.svg", mime: "image/svg+xml")
        #expect(svgHeaders["content-type"] == "text/plain; charset=utf-8")

        let pngHeaders = ContentHeaders.download(path: "pic.png", mime: "image/png")
        #expect(pngHeaders["content-type"] == "image/png")
        #expect(ContentHeaders.disposition("") == "attachment")

        // wantsMediaRefs
        #expect(wantsMediaRefs(ServerHTTPRequest(
            method: "GET",
            url: "/api/session/ses_1/message",
            headers: ["X-OpenCode-Capabilities": "foo, experimental-media-uri"]
        )))
        #expect(!wantsMediaRefs(ServerHTTPRequest(method: "GET", url: "/api/session/ses_1/message")))

        // ServerPairing single-use codes
        let pairing = ServerPairing.Service()
        let issued = pairing.issue()
        #expect(issued.expiresIn == 300)
        #expect(!issued.code.isEmpty)
        #expect(pairing.consume(issued.code))
        #expect(!pairing.consume(issued.code)) // single-use

        // ServiceStatus state machine
        let status = ServiceStatus.make(initial: .starting)
        #expect(status.current == .starting)
        status.ready()
        #expect(status.current == .ready)
        status.fail() // cannot transition ready -> failed
        #expect(status.current == .ready)
        status.beginStopping()
        #expect(status.current == .stopping)

        // ServerInfo.connectionURLs
        #expect(ServerInfo.connectionURLs("http://127.0.0.1:4096") == ["http://127.0.0.1:4096"])
        let expanded = ServerInfo.connectionURLs("http://0.0.0.0:4096", interfaceAddresses: { _ in ["192.168.1.50"] })
        #expect(expanded == ["http://127.0.0.1:4096", "http://192.168.1.50:4096"])

        // requestRef extraction priority: query > header > default
        let qReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/location?location%5Bdirectory%5D=%2Ffrom-query",
            headers: ["x-opencode-directory": "%2Ffrom-header"]
        )
        #expect(requestRef(qReq, defaultDirectory: "/default").directory.rawValue == "/from-query")

        let hReq = ServerHTTPRequest(
            method: "GET",
            url: "/api/location",
            headers: ["x-opencode-directory": "%2Ffrom-header"]
        )
        #expect(requestRef(hReq, defaultDirectory: "/default").directory.rawValue == "/from-header")

        let dReq = ServerHTTPRequest(method: "GET", url: "/api/location")
        #expect(requestRef(dReq, defaultDirectory: "/default").directory.rawValue == "/default")
    }
}

// MARK: - 2. EventFeed & Live SSE Streaming

@Suite("OpenCodeServer EventFeed & SSE")
struct OpenCodeServerEventFeedTests {
    @Test("EventFeed filters by types, ignores private events, and isolates per-subscriber overflow")
    func eventFeedFilteringAndOverflow() async throws {
        let feed = EventFeed.Service(options: EventFeed.Options(capacity: 2))

        let filteredStream = feed.subscribe(types: ["session.renamed"])
        let slowStream = feed.subscribe(types: nil)

        // Private event ignored
        feed.publish(OpenCodeEvent(id: "evt_priv", type: "internal.private", data: .object([:])))
        // Publish 3 public events while slowStream hasn't drained (capacity=2 -> overflows on 3rd)
        feed.publish(OpenCodeEvent(id: "evt_1", type: "session.created", data: .object(["n": .int(1)])))
        feed.publish(OpenCodeEvent(id: "evt_2", type: "session.renamed", data: .object(["n": .int(2)])))
        feed.publish(OpenCodeEvent(id: "evt_3", type: "session.deleted", data: .object(["n": .int(3)])))

        // Filtered subscriber only buffered 1 matching event and stays healthy!
        var filteredFrames: [String] = []
        var filteredIter = filteredStream.makeAsyncIterator()
        if let first = try await filteredIter.next() {
            filteredFrames.append(first)
        }
        #expect(filteredFrames.count == 1)
        #expect(filteredFrames[0].hasPrefix("data: "))
        #expect(filteredFrames[0].contains("session.renamed"))

        // Slow subscriber hits SubscriberOverflowError after draining buffered frames
        var overflowCaught = false
        do {
            for try await _ in slowStream {}
        } catch let err as EventFeed.Error {
            if case .subscriberOverflow(let overflow) = err {
                #expect(overflow.capacity == 2)
                overflowCaught = true
            }
        }
        #expect(overflowCaught)

        await feed.close()
    }

    @Test("Live SSE /api/event delivers initial server.connected frame and live CoreBus events via OpenCodeClient")
    func liveSSEThroughInProcessClient() async throws {
        let harness = try await ServerTestFixture.makeHarness()
        defer { Task { await harness.close() } }

        let stream = harness.client.event.subscribe()
        let (connectedStream, connectedCont) = AsyncStream<Void>.makeStream()
        let collectorTask = Task {
            try await ServerTestFixture.collectEvents(from: stream, count: 2, timeoutMs: 10_000) {
                connectedCont.yield(())
                connectedCont.finish()
            }
        }

        // Wait deterministically for the initial server.connected frame so CoreBus subscription is active
        for await _ in connectedStream { break }
        let created = try await harness.client.session.create(SessionCreateInput(title: "SSE Live Session"))

        let events = try await collectorTask.value
        #expect(events.count == 2)
        #expect(events[0].type == "server.connected")
        #expect(events[1].type == "session.created")
        if case .object(let data) = events[1].data, case .string(let sid) = data["sessionID"] {
            #expect(sid == created.id.rawValue)
        } else {
            Issue.record("Expected sessionID in session.created SSE payload")
        }
    }
}

// MARK: - 3. Non-Blocking Plugin Loading Invariant

@Suite("OpenCodeServer Non-Blocking Plugin Invariant")
struct OpenCodeServerPluginInvariantTests {
    @Test("Server handlers NEVER block waiting for async plugin loading")
    func serverNeverBlocksOnAsyncPluginLoading() async throws {
        let harness = try await ServerTestFixture.makeHarness(onLocationBoot: { loc in
            // Simulate a slow background plugin activation that takes 30 seconds, so even a heavily loaded
            // run (location boot under full parallel tests) stays far below it unless a handler truly blocks.
            let slowPlugin = PluginEffect.Plugin(
                id: "slow-bg-plugin",
                effect: { _ in
                    try? await Task.sleep(for: .seconds(30))
                }
            )
            let gen = CorePlugin.Generation(
                plugin: slowPlugin,
                revision: "rev1",
                source: .sdk
            )
            loc.plugin.startBackgroundActivation([gen], failures: [])
        })
        defer { Task { await harness.close() } }

        let startMs = Flock.currentEpochMs()

        // All of these MUST answer immediately without awaiting plugin activation!
        let plugins = try await harness.client.plugin.list()
        let agents = try await harness.client.agent.list()
        let models = try await harness.client.model.list()
        let providers = try await harness.client.provider.list()

        var rpcFailedImmediately = false
        do {
            _ = try await harness.client.rpc.call(RpcCallInput(rpcID: "slow-rpc", method: "ping"))
        } catch {
            rpcFailedImmediately = isRpcError(error)
        }

        let elapsedMs = Flock.currentEpochMs() - startMs
        #expect(elapsedMs < 10_000, "Handlers must return immediately without waiting for slow plugins (took \(elapsedMs)ms)")
        #expect(plugins.location.directory.rawValue == harness.rootDir)
        #expect(agents.data.isEmpty)
        #expect(models.data.isEmpty)
        #expect(providers.data.isEmpty)
        #expect(rpcFailedImmediately)
    }
}

// MARK: - 4. End-to-End In-Process OpenCodeClient <-> OpenCodeServer <-> OpenCodeCore Tests

@Suite("OpenCodeServer End-to-End API Integration")
struct OpenCodeServerEndToEndTests {
    @Test("All 32 protocol groups and every ClientApi endpoint are registered in OpenCodeServer")
    func routeCoverageMatchesProtocolApi() {
        #expect(OpenCodeServerModule.upstreamPackage == "server")
        #expect(OpenCodeServer.handlers.count == 32)
        let registeredNames = Set(OpenCodeServer.handlers.flatMap { $0.routes.map(\.endpointName) })
        let protocolNames = Set(OpenCodeServer.Api.endpoints.map(\.name))
        let missing = protocolNames.subtracting(registeredNames)
        #expect(missing.isEmpty, "Missing handler routes for protocol endpoints: \(missing.sorted())")
    }

    @Test("Server info, OpenAPI JSON, Pairing flow (JSON & Browser Cookie), and authenticated access")
    func serverInfoAndPairingFlow() async throws {
        let harness = try await ServerTestFixture.makeHarness(password: "secret-42")
        defer { Task { await harness.close() } }

        // Unauthenticated client rejected with 401 UnauthorizedError
        let unauthClient = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: harness.transport
        ))
        var gotUnauthorized = false
        do {
            _ = try await unauthClient.server.info()
        } catch {
            gotUnauthorized = isUnauthorizedError(error)
        }
        #expect(gotUnauthorized)

        // Authenticated GET /api/info
        let info = try await harness.client.server.info()
        #expect(info.version == "2.0.0-test")

        // OpenAPI JSON endpoint
        let openApiResp = await harness.router.handle(ServerHTTPRequest(method: "GET", url: "/openapi.json"))
        #expect(openApiResp.statusCode == 200)
        let openApiDoc = try ServerTestFixture.decodeJSONObject(from: try await openApiResp.collectBytes())
        #expect(openApiDoc["openapi"] == .string("3.1.0"))

        // Pairing flow: issue code -> redeem as JSON API client -> authenticate with issued token
        let pairCode = try await harness.client.server.pair()
        #expect(pairCode.expiresIn == 300)
        let pairingSession = try await unauthClient.server.connect(ServerConnectInput(code: pairCode.code))
        #expect(pairingSession.token.contains("."))

        // Replaying same pairing code fails with 401
        var replayUnauthorized = false
        do {
            _ = try await unauthClient.server.connect(ServerConnectInput(code: pairCode.code))
        } catch {
            replayUnauthorized = isUnauthorizedError(error)
        }
        #expect(replayUnauthorized)

        // Paired session token works as Basic password
        let pairedClient = OpenCodeClient(options: ClientOptions(
            baseUrl: "http://127.0.0.1:4096",
            transport: harness.transport,
            headers: ["authorization": ClientHTTPHeaders.basicAuthorization(username: "opencode", password: pairingSession.token)]
        ))
        let pairedInfo = try await pairedClient.server.info()
        #expect(pairedInfo.version == "2.0.0-test")

        // Browser pairing flow receives 302 redirect + HttpOnly Set-Cookie
        let browserCode = try await harness.client.server.pair()
        let browserResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/auth/connect/\(browserCode.code)",
            headers: ["accept": "text/html", "host": "127.0.0.1:4096"]
        ))
        #expect(browserResp.statusCode == 302)
        #expect(ServerHeaders.value(in: browserResp.headers, for: "location") == "/")
        #expect(browserResp.setCookies.first?.hasPrefix("opencode_session_4096=") == true)
    }

    @Test("Session, Inbox, Instructions, Export/Import, Active, Interrupt, and Error Mapping via OpenCodeClient")
    func sessionLifecycleEndToEnd() async throws {
        let harness = try await ServerTestFixture.makeHarness()
        defer { Task { await harness.close() } }

        // Create session
        let created = try await harness.client.session.create(SessionCreateInput(title: "Alpha Session"))
        #expect(created.title == "Alpha Session")

        // Get & List
        let fetched = try await harness.client.session.get(SessionGetInput(sessionID: created.id.rawValue))
        #expect(fetched.id == created.id)

        let listed = try await harness.client.session.list(SessionListInput(limit: 10))
        #expect(listed.data.contains(where: { $0.id == created.id }))

        // Rename, archive, unarchive, switch agent & model
        try await harness.client.session.update(SessionUpdateInput(sessionID: created.id.rawValue, title: "Renamed Alpha"))
        let renamed = try await harness.client.session.get(SessionGetInput(sessionID: created.id.rawValue))
        #expect(renamed.title == "Renamed Alpha")

        try await harness.client.session.switchAgent(SessionSwitchAgentInput(sessionID: created.id.rawValue, agent: "plan"))
        try await harness.client.session.switchModel(SessionSwitchModelInput(
            sessionID: created.id.rawValue,
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "gpt-5"), providerID: ProviderSchema.ID(rawValue: "openai"))
        ))

        // Durable prompt admission -> inbox list -> inbox update -> inbox cancel
        let admitted = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: created.id.rawValue,
            text: "Hello from OpenCodeClient!",
            delivery: .queue,
            resume: false
        ))
        let inboxItems = try await harness.client.session.inbox.list(SessionInboxListInput(sessionID: created.id.rawValue))
        #expect(inboxItems.count == 1)
        #expect(inboxItems[0].id == admitted.id)

        try await harness.client.session.inbox.update(SessionInboxUpdateInput(
            sessionID: created.id.rawValue,
            inboxID: admitted.id.rawValue,
            delivery: .steer
        ))
        try await harness.client.session.inbox.cancel(SessionInboxCancelInput(
            sessionID: created.id.rawValue,
            inboxID: admitted.id.rawValue
        ))
        let afterCancel = try await harness.client.session.inbox.list(SessionInboxListInput(sessionID: created.id.rawValue))
        #expect(afterCancel.isEmpty)

        // Synthetic & Compaction admission
        let synth = try await harness.client.session.synthetic(SessionSyntheticInput(
            sessionID: created.id.rawValue,
            text: "System note",
            resume: false
        ))
        #expect(synth.payload.text == "System note")

        let comp = try await harness.client.session.compact(SessionCompactInput(sessionID: created.id.rawValue))
        #expect(comp.delivery == .steer)

        // Instruction entries put / list / remove (plus invalid slash key rejection)
        var rejectedBadKey = false
        do {
            try await harness.client.experimental.session.instructions.entry.put(ExperimentalSessionInstructionsEntryPutInput(
                sessionID: created.id.rawValue,
                key: "bad/key",
                value: .string("nope")
            ))
        } catch {
            rejectedBadKey = isInvalidRequestError(error)
        }
        #expect(rejectedBadKey)

        try await harness.client.experimental.session.instructions.entry.put(ExperimentalSessionInstructionsEntryPutInput(
            sessionID: created.id.rawValue,
            key: "team-rules",
            value: .string("always write tests")
        ))
        let instrList = try await harness.client.experimental.session.instructions.entry.list(
            ExperimentalSessionInstructionsEntryListInput(sessionID: created.id.rawValue)
        )
        #expect(instrList.count == 1)
        let firstInstr = try #require(instrList.first)
        #expect(firstInstr.key.rawValue == "team-rules")
        try await harness.client.experimental.session.instructions.entry.remove(ExperimentalSessionInstructionsEntryRemoveInput(
            sessionID: created.id.rawValue,
            key: "team-rules"
        ))
        let instrAfter = try await harness.client.experimental.session.instructions.entry.list(
            ExperimentalSessionInstructionsEntryListInput(sessionID: created.id.rawValue)
        )
        #expect(instrAfter.isEmpty)

        // Active & idle interrupt (no-op returns interrupted == false)
        let active = try await harness.client.session.active()
        #expect(active.isEmpty)
        let interruptRes = try await harness.client.session.interrupt(SessionInterruptInput(sessionID: created.id.rawValue))
        #expect(interruptRes.interrupted == false)

        // Export & remove & not-found check
        let exported = try await harness.client.experimental.session.export(
            ExperimentalSessionExportInput(sessionID: created.id.rawValue)
        )
        #expect(exported.info.id == created.id)

        try await harness.client.session.remove(SessionRemoveInput(sessionID: created.id.rawValue))
        var notFound = false
        do {
            _ = try await harness.client.session.get(SessionGetInput(sessionID: created.id.rawValue))
        } catch {
            notFound = isSessionNotFoundError(error)
        }
        #expect(notFound)
    }

    @Test("Filesystem read with Range 206/416, ETag 304, XSS ContentHeaders, write, list, and find")
    func filesystemAndRangeEndpoints() async throws {
        let harness = try await ServerTestFixture.makeHarness(initialFiles: [
            "/workspace/hello.txt": Array("0123456789ABCDEF".utf8),
            "/workspace/index.html": Array("<h1>hello</h1>".utf8),
        ])
        defer { Task { await harness.close() } }

        // Full read via OpenCodeClient
        let bytes = try await harness.client.file.read(FileReadInput(path: "hello.txt"))
        #expect(ServerTestFixture.utf8String(bytes) == "0123456789ABCDEF")

        // HTTP Range 206 Partial Content
        let rangeResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/fs/read/hello.txt",
            headers: ["range": "bytes=2-6"]
        ))
        #expect(rangeResp.statusCode == 206)
        #expect(ServerHeaders.value(in: rangeResp.headers, for: "content-range") == "bytes 2-6/16")
        #expect(ServerTestFixture.utf8String(try await rangeResp.collectBytes()) == "23456")

        // ETag 304 Not Modified
        let etag = try #require(ServerHeaders.value(in: rangeResp.headers, for: "etag"))
        let notModResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/fs/read/hello.txt",
            headers: ["if-none-match": etag]
        ))
        #expect(notModResp.statusCode == 304)

        // Unsatisfiable Range 416
        let badRange = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/fs/read/hello.txt",
            headers: ["range": "bytes=100-200"]
        ))
        #expect(badRange.statusCode == 416)
        #expect(ServerHeaders.value(in: badRange.headers, for: "content-range") == "bytes */16")

        // HTML served as inert text/plain with sandbox CSP
        let htmlResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/fs/read/index.html"
        ))
        #expect(htmlResp.statusCode == 200)
        #expect(ServerHeaders.value(in: htmlResp.headers, for: "content-type") == "text/plain; charset=utf-8")
        #expect(ServerHeaders.value(in: htmlResp.headers, for: "content-security-policy") == ContentHeaders.CONTENT_SECURITY_POLICY)

        // Write, list, find via OpenCodeClient
        let writeRes = try await harness.client.experimental.file.write(ExperimentalFileWriteInput(
            path: "sub/newfile.txt",
            payload: Array("written!".utf8)
        ))
        #expect(writeRes.data.path.rawValue == "/workspace/sub/newfile.txt")
        let readBack = try await harness.client.file.read(FileReadInput(path: "sub/newfile.txt"))
        #expect(ServerTestFixture.utf8String(readBack) == "written!")

        let listRes = try await harness.client.file.list(FileListInput())
        #expect(listRes.data.contains(where: { $0.path.rawValue == "hello.txt" }))

        let findRes = try await harness.client.file.find(FileFindInput(query: "hello"))
        #expect(findRes.data.contains(where: { $0.path.rawValue == "hello.txt" }))
    }

    @Test("Forms, cold-location form shortcut, Permissions, Credentials, Config, RPC, Blobs, Media & Migration")
    func multiGroupCoreHandlers() async throws {
        let harness = try await ServerTestFixture.makeHarness(onLocationBoot: { loc in
            _ = try? await loc.agent.transform { editor in
                editor.update(AgentSchema.ID(rawValue: "reviewer")) { current in
                    AgentSchema.Info(
                        id: current.id,
                        name: AgentSchema.Name(rawValue: "Reviewer"),
                        request: current.request,
                        description: "Code reviewer",
                        mode: .primary,
                        hidden: false,
                        permissions: current.permissions
                    )
                }
            }
            _ = await loc.rpc.register(rpcID: "demo", handlers: [
                "echo": { input in .object(["echoed": input]) },
            ])
        })
        defer { Task { await harness.close() } }

        // Session + Cold-location form list shortcut does NOT boot location
        let session = try await harness.client.session.create(SessionCreateInput(title: "Form Session"))
        let coldForms = try await harness.client.session.form.list(SessionFormListInput(sessionID: session.id.rawValue))
        #expect(coldForms.isEmpty)
        #expect(harness.runtime.locations.keys().isEmpty)

        // Creating a form boots the location and persists form state
        let fieldsJSON: JSONValue = .array([
            .object([
                "type": .string("string"),
                "key": .string("answer"),
                "title": .string("Your answer"),
                "required": .bool(true),
            ]),
        ])
        let createdForm = try await harness.client.session.form.create(SessionFormCreateInput(
            sessionID: session.id.rawValue,
            title: "Confirm",
            fields: fieldsJSON
        ))
        let fetchedForm = try await harness.client.session.form.get(SessionFormGetInput(
            sessionID: session.id.rawValue,
            formID: createdForm.id.rawValue
        ))
        #expect(fetchedForm.title == "Confirm")
        try await harness.client.session.form.reply(SessionFormReplyInput(
            sessionID: session.id.rawValue,
            formID: createdForm.id.rawValue,
            answer: ["answer": .string("yes")]
        ))

        // Agent list & get
        let agent = try await harness.client.agent.get(AgentGetInput(agentID: "reviewer"))
        #expect(agent.data.name.rawValue == "Reviewer")

        // RPC call success + unknown method RpcError
        let rpcOut = try await harness.client.rpc.call(RpcCallInput(rpcID: "demo", method: "echo", input: .string("hi")))
        let expectedRPC: JSONValue = .object(["echoed": .string("hi")])
        #expect(rpcOut.output == expectedRPC)

        // Credentials CRUD
        let cred = try await harness.client.credential.create(CredentialCreateInput(
            integrationID: "openai",
            label: "Primary",
            value: .key(CredentialSchema.Key(key: "sk-test-123"))
        ))
        #expect(cred.active == true)
        let creds = try await harness.client.credential.list()
        #expect(creds.count == 1)
        try await harness.client.credential.update(CredentialUpdateInput(credentialID: cred.id.rawValue, label: "Updated"))
        try await harness.client.credential.remove(CredentialRemoveInput(credentialID: cred.id.rawValue))
        #expect((try await harness.client.credential.list()).isEmpty)

        // Blob store GET with Range + ETag 304
        let storedBlob = try await harness.runtime.blobStore.write([Array("BLOBDATA1234".utf8)])
        let blobBytes = try await harness.client.experimental.blob.get(ExperimentalBlobGetInput(id: storedBlob.id.rawValue))
        #expect(ServerTestFixture.utf8String(blobBytes) == "BLOBDATA1234")
        let blobRange = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/experimental/blob/\(storedBlob.id.rawValue)",
            headers: ["range": "bytes=4-7"]
        ))
        #expect(blobRange.statusCode == 206)
        #expect(ServerTestFixture.utf8String(try await blobRange.collectBytes()) == "DATA")

        // Referenced media blob GET (inline image PNG vs 304)
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let mediaHash = try ServerTestFixture.insertReferencedMediaBlob(
            in: harness.runtime.db,
            sessionID: session.id,
            mime: "image/png",
            data: pngBytes
        )
        let mediaResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/experimental/media/\(mediaHash)"
        ))
        #expect(mediaResp.statusCode == 200)
        #expect(ServerHeaders.value(in: mediaResp.headers, for: "content-type") == "image/png")
        #expect(try await mediaResp.collectBytes() == pngBytes)

        // Migration v1 status, Config, VCS, Debug location list/evict
        let mig = try await harness.client.experimental.migration.v1.status()
        #expect(mig == .completed)
        let cfgEntries = try await harness.client.config.get()
        #expect(cfgEntries.count >= 0)
        let vcsInfo = try await harness.client.vcs.get()
        #expect(vcsInfo.location.directory.rawValue == harness.rootDir)
        let loadedLocs = try await harness.client.debug.location.list()
        #expect(loadedLocs.contains(where: { $0.directory.rawValue == harness.rootDir }))
        try await harness.client.debug.location.evict()
        let remainingLocs = try await harness.client.debug.location.list()
        #expect(!remainingLocs.contains(where: { $0.directory.rawValue == harness.rootDir }))
    }

    @Test("PTY WebSocket bridge runPtySocket & holdLocation shutdown 1012 close")
    func ptyWebSocketBridgeAndHoldLocation() async throws {
        let (clientWS, serverWS) = InMemoryServerWebSocket.makePair()
        let lifecycle = CoreLocation.Lifecycle.Service()
        let (outbox, outboxCont) = AsyncStream<Outbound>.makeStream()
        let release = holdLocation(lifecycle, outboxCont)

        let received = Mutex<[String]>([])
        let detached = Mutex(false)

        let bridgeTask = Task {
            await runPtySocket(
                socket: serverWS,
                outbox: outbox,
                onOpen: {
                    outboxCont.yield(.text("hello-terminal"))
                },
                onMessage: { msg in
                    if case .text(let s) = msg {
                        received.withLock { $0.append(s) }
                    }
                },
                detach: {
                    detached.withLock { $0 = true }
                    release()
                    outboxCont.finish()
                }
            )
        }

        // Send inbound message from client -> server
        try await clientWS.send(.text("ls -la\n"))

        // Collect frames received by client until location shutdown triggers 1012 close
        var clientIter = clientWS.incoming.makeAsyncIterator()
        let first = await clientIter.next()
        #expect(first == .text("hello-terminal"))

        // Trigger location shutdown -> holdLocation sends 1012 close frame!
        await lifecycle.shutdown()
        let second = await clientIter.next()
        #expect(second == .close(ServerWebSocketCloseEvent(code: 1012, reason: "location shut down")))

        await bridgeTask.value
        #expect(detached.withLock { $0 } == true)
        #expect(received.withLock { $0 }.contains("ls -la\n"))
    }

    @Test("Workerd runtime profile boots with DurableObjectStorage and degrades VCS cleanly")
    func workerdRuntimeProfile() async throws {
        let storage = try ServerTestFixture.MockDurableObjectStorage()
        let opts = ServerWorkerd.Options(
            storage: storage,
            app: ServerOptions.AppOptions(name: "opencode-worker", version: "2.0.0-workerd")
        )
        let derived = ServerWorkerd.serverOptions(opts)
        #expect(derived.fs?.filewatcher == false)
        #expect(derived.fs?.fff == false)
        #expect(derived.events?.persist == true)
        #expect(!ServerWorkerd.replacements(opts).isEmpty)

        // Workerd runtime profile
        let handle = try await ServerWorkerd.create(opts)
        defer { Task { await handle.close() } }

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: "https://worker.opencode.local",
            transport: handle.transport
        ))
        let info = try await client.server.info()
        #expect(info.version == "2.0.0-workerd")
        let vcs = try await client.vcs.get()
        #expect(vcs.data.provider == nil)
    }

    @Test("Artifacts, Automations, Integrations, MCP, and PTY connect tokens")
    func experimentalAndSubsystemEndpoints() async throws {
        let configJSON = """
        {
          "experimental": {
            "artifacts": true,
            "automations": true
          }
        }
        """
        let harness = try await ServerTestFixture.makeHarness(
            configContent: configJSON,
            onLocationBoot: { loc in
                _ = try? await loc.integration.transform { editor in
                    editor.update(IntegrationID(rawValue: "github")) { ref in
                        IntegrationSchema.Ref(id: ref.id, name: "GitHub", metadata: nil)
                    }
                    editor.updateMethod(.key(CoreIntegration.Integration.KeyImplementation(
                        integrationID: IntegrationID(rawValue: "github"),
                        method: IntegrationSchema.KeyMethod(label: "Token")
                    )))
                }
            }
        )
        defer { Task { await harness.close() } }

        // Artifacts: providers, create, list, get, update, view (308 redirect + 200 file), delete
        let providers = try await harness.client.experimental.artifacts.providers()
        #expect(!providers.data.isEmpty)

        let artifact = try await harness.client.experimental.artifacts.create(ExperimentalArtifactsCreateInput(
            title: "Demo Page",
            files: ["index.html": "<html><body>Hi</body></html>"]
        ))
        let artifactList = try await harness.client.experimental.artifacts.list()
        #expect(artifactList.data.contains(where: { $0.id == artifact.data.id }))

        let fetchedArtifact = try await harness.client.experimental.artifacts.get(
            ExperimentalArtifactsGetInput(artifactID: artifact.data.id.rawValue)
        )
        #expect(fetchedArtifact.data.files["index.html"] == "<html><body>Hi</body></html>")

        // View without trailing slash returns 308 redirect; view with file path returns 200 sandboxed HTML
        let redirectResp = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/experimental/artifacts/\(artifact.data.id.rawValue)/view"
        ))
        #expect(redirectResp.statusCode == 308)
        let htmlView = await harness.router.handle(ServerHTTPRequest(
            method: "GET",
            url: "/api/experimental/artifacts/\(artifact.data.id.rawValue)/view/index.html"
        ))
        #expect(htmlView.statusCode == 200)
        #expect(ServerHeaders.value(in: htmlView.headers, for: "content-security-policy") == "sandbox allow-scripts")
        #expect(ServerTestFixture.utf8String(try await htmlView.collectBytes()) == "<html><body>Hi</body></html>")

        try await harness.client.experimental.artifacts.delete(
            ExperimentalArtifactsDeleteInput(artifactID: artifact.data.id.rawValue)
        )

        // Automations: create, list, get, pause, resume, delete
        let autoSession = try await harness.client.session.create(SessionCreateInput(title: "Automation Host"))
        let auto = try await harness.client.experimental.automation.create(ExperimentalAutomationCreateInput(
            sessionID: autoSession.id.rawValue,
            directory: harness.rootDir,
            name: "Nightly Check",
            trigger: .object(["type": .string("every"), "every": .string("1 hour")]),
            action: .object(["type": .string("prompt"), "prompt": .string("check status")])
        ))
        #expect(auto.name == "Nightly Check")
        let paused = try await harness.client.experimental.automation.pause(
            ExperimentalAutomationPauseInput(automationID: auto.id.rawValue)
        )
        #expect(paused.status == AutomationSchema.Status.paused)
        let resumed = try await harness.client.experimental.automation.resume(
            ExperimentalAutomationResumeInput(automationID: auto.id.rawValue)
        )
        #expect(resumed.status == AutomationSchema.Status.active)
        try await harness.client.experimental.automation.delete(
            ExperimentalAutomationDeleteInput(automationID: auto.id.rawValue)
        )

        // Integrations: list, get, connect.key, oauth flow
        let integrations = try await harness.client.integration.list()
        #expect(integrations.data.contains(where: { $0.id.rawValue == "github" }))
        try await harness.client.integration.connect.key(IntegrationConnectKeyInput(
            integrationID: "github",
            key: "ghp_test_token",
            label: "Dev"
        ))
        let oauthAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "github",
            methodID: "oauth-default"
        ))
        let oauthStatus = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
            integrationID: "github",
            attemptID: oauthAttempt.data.attemptID.rawValue
        ))
        let isPending: Bool
        if case .pending = oauthStatus.data {
            isPending = true
        } else {
            isPending = false
        }
        #expect(isPending)
        try await harness.client.integration.oauth.complete(IntegrationOauthCompleteInput(
            integrationID: "github",
            attemptID: oauthAttempt.data.attemptID.rawValue,
            code: "oauth-code-123"
        ))

        // MCP: add, list, clientToken header validation (forbidden without x-opencode-ticket: 1), remove
        let mcpTokenForbiddenResp = await harness.router.handle(ServerHTTPRequest(
            method: "POST",
            url: "\(MCP_CLIENT_PATH)/token?name=browser"
        ))
        #expect(mcpTokenForbiddenResp.statusCode == 403)

        let mcpTokenRes = try await harness.client.experimental.mcp.client.token(ExperimentalMcpClientTokenInput(
            name: "browser",
            xOpencodeTicket: PTY_CONNECT_TOKEN_HEADER_VALUE
        ))
        #expect(!mcpTokenRes.data.ticket.isEmpty)

        // Jobs, Usage, Voice, WebSearch providers
        let jobs = try await harness.client.experimental.job.list()
        #expect(jobs.isEmpty)
        // Cancelling a job that already finished (or never existed) does nothing and answers 204.
        try await harness.client.experimental.job.cancel(ExperimentalJobCancelInput(id: "job_missing"))
        let videoJobs = try await harness.client.experimental.job.list(ExperimentalJobListInput(kind: .string("video")))
        #expect(videoJobs.isEmpty)
        let usage = try await harness.client.experimental.usage.limits()
        #expect(usage.data == nil)
        let voiceModels = try await harness.client.experimental.voice.models()
        #expect(!voiceModels.models.isEmpty)
        let searchProviders = try await harness.client.websearch.providers()
        #expect(searchProviders.data.isEmpty)
    }
}

// MARK: - 5. Real POSIX Loopback TCP HTTP/1.1 + SSE Server End-to-End Test (macOS / Linux)

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
@Suite("OpenCodeServer Real POSIX TCP Loopback Server")
struct OpenCodeServerPOSIXTCPTests {
    @Test("Real loopback TCP server handles Basic auth, CORS preflight, CRUD, Range 206, and live chunked SSE via URLSessionHTTPTransport")
    func realLoopbackTCPServerEndToEnd() async throws {
        let workspaceDir = try ServerTestFixture.makeTempWorkspaceDirectory()
        defer { ServerTestFixture.removeTempDirectory(workspaceDir) }

        let samplePath = "\(workspaceDir)/sample.txt"
        try await LocalFileSystem.shared.writeFile(Array("ABCDEFGHIJ".utf8), to: samplePath, createDirectories: true)

        let running = try await ServerProcess.start(
            options: ServerOptions(
                app: ServerOptions.AppOptions(name: "opencode", version: "2.0.0-tcp", channel: "local"),
                hostname: "127.0.0.1",
                port: 0, // OS-assigned ephemeral loopback port
                password: "tcp-secret-password",
                cors: ["https://client.example.com"],
                database: CoreDatabaseStore.Options(path: ":memory:"),
                config: ServerOptions.ConfigOptions(project: false, claude: false)
            ),
            defaultDirectory: workspaceDir
        )
        defer { Task { await running.stop() } }

        let baseUrl = running.address.urlString
        #expect(running.address.port > 0)
        #expect(running.status.current == .ready)

        let urlTransport = ServerTestFixture.makeURLSessionTransport()
        defer { urlTransport.invalidateAndCancel() }

        // 1. Unauthenticated TCP request rejected with 401
        let unauthResp = try await urlTransport.send(HTTPRequest(method: "GET", url: "\(baseUrl)/api/info"))
        #expect(unauthResp.head.statusCode == 401)

        // 2. CORS preflight OPTIONS over real TCP
        let preflight = try await urlTransport.send(HTTPRequest(
            method: "OPTIONS",
            url: "\(baseUrl)/api/info",
            headers: [
                "Origin": "https://client.example.com",
                "Access-Control-Request-Method": "GET",
            ]
        ))
        #expect(preflight.head.statusCode == 204)
        #expect(ClientHTTPHeaders.value(in: preflight.head.headers, for: "access-control-allow-origin") == "https://client.example.com")

        // 3. Authenticated OpenCodeClient over real TCP
        let client = ServerTestFixture.makeTCPClient(baseUrl: baseUrl, password: "tcp-secret-password", transport: urlTransport)
        let info = try await client.server.info()
        #expect(info.version == "2.0.0-tcp")
        #expect(info.urls.contains(baseUrl))

        // 4. Create session & admit prompt over real TCP
        let created = try await client.session.create(SessionCreateInput(
            title: "Real TCP Session",
            location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: workspaceDir))
        ))
        #expect(created.title == "Real TCP Session")
        let fetched = try await client.session.get(SessionGetInput(sessionID: created.id.rawValue))
        #expect(fetched.id == created.id)

        // 5. Real HTTP Range request (206 Partial Content) over TCP
        let authHeader = ClientHTTPHeaders.basicAuthorization(username: "opencode", password: "tcp-secret-password")
        let rangeResp = try await urlTransport.send(HTTPRequest(
            method: "GET",
            url: "\(baseUrl)/api/fs/read/sample.txt?location%5Bdirectory%5D=\(ClientURLBuilder.encodeURIComponent(workspaceDir))",
            headers: ["Authorization": authHeader, "Range": "bytes=3-6"]
        ))
        #expect(rangeResp.head.statusCode == 206)
        #expect(ClientHTTPHeaders.value(in: rangeResp.head.headers, for: "content-range") == "bytes 3-6/10")
        #expect(ServerTestFixture.utf8String(rangeResp.body) == "DEFG")

        // 6. Real live chunked SSE /api/event over TCP!
        let sseTransport = ServerTestFixture.makeURLSessionTransport()
        defer { sseTransport.invalidateAndCancel() }
        let sseClient = ServerTestFixture.makeTCPClient(baseUrl: baseUrl, password: "tcp-secret-password", transport: sseTransport)
        let sseStream = sseClient.event.subscribe()
        let (sseConnectedStream, sseConnectedCont) = AsyncStream<Void>.makeStream()
        let sseTask = Task {
            try await ServerTestFixture.collectEvents(from: sseStream, count: 2, timeoutMs: 10_000) {
                sseConnectedCont.yield(())
                sseConnectedCont.finish()
            }
        }

        // Wait deterministically for the SSE handshake frame, then trigger a live session rename event
        for await _ in sseConnectedStream { break }
        try await client.session.update(SessionUpdateInput(sessionID: created.id.rawValue, title: "Renamed Over TCP"))

        let liveEvents = try await sseTask.value
        #expect(liveEvents.count == 2)
        #expect(liveEvents[0].type == "server.connected")
        #expect(liveEvents[1].type == "session.renamed")
    }
}
#endif
