import Testing
import Synchronization
import OpenCodeCLIKit
import OpenCodePlatform
import OpenTunnelClient

@Suite("OpenTunnel CLI RemoteTunnel Bridge")
struct OpenTunnelBridgeTests {
    // MARK: - 1. RemoteTunnel.hostname backed by OpenTunnelStorage

    @Test("RemoteTunnel.hostname loads stored OpenTunnelIdentity from virtual XDG storage and returns nil when absent")
    func hostnameReadsStoredXDGIdentity() async {
        // Absent -> nil
        let (emptyCtx, _, _) = CLITestFixtures.makeContext()
        #expect(await CLIServices.RemoteTunnel.hostname("abc123def4560000", emptyCtx) == nil)

        // Present in XDG config storage -> "<route>.<hostname>"
        let files = OpenTunnelBridgeTestHelper.storedIdentityFiles(
            configRoot: "/home/tester/.config",
            identity: OpenTunnelBridgeTestHelper.sampleIdentity(hostname: "dev000111222.opentunnel.xyz")
        )
        let (ctx, _, _) = CLITestFixtures.makeContext(files: files)
        let resolved = await CLIServices.RemoteTunnel.hostname("deadbeef01234567", ctx)
        #expect(resolved == "deadbeef01234567.dev000111222.opentunnel.xyz")
    }

    @Test("RemoteTunnel.hostname reads real on-disk OpenTunnelXDGStorage when LocalFileSystem is active")
    func hostnameReadsRealDiskXDGStorage() async throws {
        let tmp = try OpenTunnelBridgeTestHelper.makeTempDirectory(prefix: "cli-hostname-disk")
        defer { OpenTunnelBridgeTestHelper.removePath(tmp) }

        let storage = OpenTunnelXDGStorage.xdg(
            environment: ["XDG_CONFIG_HOME": "\(tmp)/config"],
            homeDirectory: tmp,
            platform: .posix
        )
        try await storage.save(OpenTunnelBridgeTestHelper.sampleIdentity(hostname: "disk987654321.opentunnel.xyz"))

        let (ctx, _) = OpenTunnelBridgeTestHelper.makeDiskContext(tempRoot: tmp)
        let host = await CLIServices.RemoteTunnel.hostname("0123456789abcdef", ctx)
        #expect(host == "0123456789abcdef.disk987654321.opentunnel.xyz")
    }

    // MARK: - 2. RemoteTunnel.ensure & 5-Minute Timeout

    @Test("RemoteTunnel.ensure provisions via OpenTunnelClient, writes setup banner once, and skips banner when already provisioned")
    func ensureProvisionsAndReusesIdentity() async throws {
        let storage = OpenTunnelMemoryStorage()
        let transport = OpenTunnelBridgeTestHelper.makeBridgeTransport(
            tunnelID: "ens111222333",
            hostname: "ens111222333.opentunnel.xyz"
        )
        let otClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: OpenTunnelBridgeTestHelper.fastTiming
        )
        let backend = CLIServices.RemoteTunnel.OpenTunnelClientBackend(client: otClient)

        // First ensure: no tunnel yet -> prints setup notice and creates + persists identity
        let (ctx1, out1, _) = CLITestFixtures.makeContext(remoteTunnelBackend: backend)
        let host1 = try await CLIServices.RemoteTunnel.ensure(ctx1)
        #expect(host1 == "ens111222333.opentunnel.xyz")
        #expect(out1.stderr.contains("Setting up remote access; this can take a minute..."))
        #expect(try await storage.load()?.hostname == "ens111222333.opentunnel.xyz")

        // Second ensure: identity already exists -> no setup notice written to stderr
        let (ctx2, out2, _) = CLITestFixtures.makeContext(remoteTunnelBackend: backend)
        let host2 = try await CLIServices.RemoteTunnel.ensure(ctx2)
        #expect(host2 == "ens111222333.opentunnel.xyz")
        #expect(out2.stderr.isEmpty)
    }

    @Test("RemoteTunnel.ensure enforces upstream 5-minute timeout with exact error message")
    func ensureTimeoutPolicy() async {
        #expect(CLIServices.RemoteTunnel.Policy.defaultEnsureTimeout == .seconds(300))

        let hangingBackend = ScriptedRemoteTunnelBackend(
            get: { nil },
            ensure: {
                try await Task.sleep(for: .seconds(10))
                return "never.opentunnel.xyz"
            }
        )
        let (ctx, out, _) = CLITestFixtures.makeContext(remoteTunnelBackend: hangingBackend)

        do {
            _ = try await CLIServices.RemoteTunnel.ensureWithTimeout(context: ctx, timeout: .milliseconds(30))
            Issue.record("Expected ensureWithTimeout to fail with timeout error")
        } catch let error as CLIError {
            #expect(error.message == "Timed out creating the remote access tunnel; run the command again to resume")
            #expect(out.stderr.contains("Setting up remote access; this can take a minute..."))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - 3. RemoteTunnel.run Retry Backoff & Fatal Stop Classification

    @Test("RemoteTunnel.run retries transient errors with exact exponential 1s..30s backoff then publishes https://<route>.<hostname>")
    func runExponentialBackoffAndURLCallback() async {
        let attempts = Mutex(0)
        let recordedDelays = Mutex<[Duration]>([])
        let observedURLs = Mutex<[String?]>([])
        let closedCalled = Mutex(false)

        let backend = ScriptedRemoteTunnelBackend(
            connect: { route, target in
                #expect(route == "abcdef0123456789")
                #expect(target == "127.0.0.1:4096")
                let n = attempts.withLock { a -> Int in a += 1; return a }
                if n <= 7 {
                    throw OpenTunnelClientError.transient("network EOF attempt \(n)")
                }
                return CLIServices.RemoteTunnel.Connection(
                    hostname: "retryhost.opentunnel.xyz",
                    waitForClose: {},
                    close: { closedCalled.withLock { $0 = true } }
                )
            }
        )

        let (ctx, _, _) = CLITestFixtures.makeContext(remoteTunnelBackend: backend)
        let policy = CLIServices.RemoteTunnel.RunPolicy(
            sleep: { duration in
                recordedDelays.withLock { $0.append(duration) }
            }
        )

        await CLIServices.RemoteTunnel.runWithPolicy(
            input: CLIServices.RemoteTunnel.RunInput(
                route: "abcdef0123456789",
                target: "127.0.0.1:4096",
                onURL: { url in observedURLs.withLock { $0.append(url) } }
            ),
            context: ctx,
            policy: policy
        )

        #expect(attempts.withLock { $0 } == 8)
        #expect(recordedDelays.withLock { $0 } == [
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8),
            .seconds(16),
            .seconds(30),
            .seconds(30),
        ])
        let urls = observedURLs.withLock { $0 }
        #expect(urls.contains("https://abcdef0123456789.retryhost.opentunnel.xyz"))
        #expect(urls.last == .some(nil))
        #expect(closedCalled.withLock { $0 })
    }

    @Test("RemoteTunnel.run stops immediately without retrying on OpenTunnelAttachError, certificate failure, and invalid/SOCKS proxy")
    func runStopsImmediatelyOnFatalErrors() async {
        let fatalErrors: [any Error & Sendable] = [
            OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.badToken),
            OpenTunnelClientError.attachFailed(OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.certNotReady)),
            OpenTunnelClientError.certificateIssuanceFailed("ACME rate limit exceeded"),
            OpenTunnelClientError.unsupportedProxyScheme("socks5", source: "HTTPS_PROXY"),
            OpenTunnelClientError.invalidProxyURL(source: "HTTPS_PROXY"),
        ]

        for fatalError in fatalErrors {
            let attempts = Mutex(0)
            let sleeps = Mutex(0)
            let errorLogs = Mutex<[String]>([])

            let backend = ScriptedRemoteTunnelBackend(
                connect: { _, _ in
                    attempts.withLock { $0 += 1 }
                    throw fatalError
                }
            )
            let (ctx, _, _) = CLITestFixtures.makeContext(remoteTunnelBackend: backend)
            let policy = CLIServices.RemoteTunnel.RunPolicy(
                sleep: { _ in sleeps.withLock { $0 += 1 } },
                onError: { msg, _ in errorLogs.withLock { $0.append(msg) } }
            )

            await CLIServices.RemoteTunnel.runWithPolicy(
                input: CLIServices.RemoteTunnel.RunInput(route: "r1", target: "127.0.0.1:4096", onURL: { _ in }),
                context: ctx,
                policy: policy
            )

            #expect(attempts.withLock { $0 } == 1)
            #expect(sleeps.withLock { $0 } == 0)
            #expect(errorLogs.withLock { $0 } == [CLIServices.RemoteTunnel.Policy.stoppedLogMessage])
        }
    }

    @Test("RemoteTunnel.run stops immediately when HTTPS_PROXY=socks5:// is configured in CLIContext environment")
    func runStopsImmediatelyOnSocks5EnvironmentProxy() async {
        let sleeps = Mutex(0)
        let errorLogs = Mutex<[String]>([])
        let (ctx, _, _) = CLITestFixtures.makeContext(
            env: ["HTTPS_PROXY": "socks5://127.0.0.1:1080"]
        )
        let policy = CLIServices.RemoteTunnel.RunPolicy(
            sleep: { _ in sleeps.withLock { $0 += 1 } },
            onError: { msg, _ in errorLogs.withLock { $0.append(msg) } }
        )

        await CLIServices.RemoteTunnel.runWithPolicy(
            input: CLIServices.RemoteTunnel.RunInput(route: "0123456789abcdef", target: "127.0.0.1:4096", onURL: { _ in }),
            context: ctx,
            policy: policy
        )

        #expect(sleeps.withLock { $0 } == 0)
        #expect(errorLogs.withLock { $0 } == [CLIServices.RemoteTunnel.Policy.stoppedLogMessage])
    }

    @Test("RemoteTunnel.run connects end-to-end with OpenTunnelClientBackend, publishes URL, and closes cleanly on cancellation")
    func runEndToEndConnectAndCancellationCleanup() async throws {
        let storage = OpenTunnelMemoryStorage(
            initialIdentities: ["default": OpenTunnelBridgeTestHelper.sampleIdentity(hostname: "live001.opentunnel.xyz")]
        )
        let claimedRoutes = Mutex<[String]>([])
        let transport = OpenTunnelBridgeTestHelper.makeBridgeTransport(
            tunnelID: "dev000111222",
            hostname: "live001.opentunnel.xyz",
            onAttach: { routes, serverWS in
                claimedRoutes.withLock { $0 = routes }
                let routesJSON = OpenTunnelBridgeTestHelper.encodeJSONString(routes)
                try? await serverWS.send(.text(
                    "{\"type\":\"attached\",\"session\":\"s-live\",\"routes\":\(routesJSON),\"heartbeat_ms\":15000,\"idle_timeout_ms\":45000}"
                ))
            }
        )
        let otClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: OpenTunnelBridgeTestHelper.fastTiming
        )
        let backend = CLIServices.RemoteTunnel.OpenTunnelClientBackend(client: otClient)
        let (ctx, _, _) = CLITestFixtures.makeContext(remoteTunnelBackend: backend)

        let urlHistory = Mutex<[String?]>([])
        let task = Task {
            await CLIServices.RemoteTunnel.run(
                CLIServices.RemoteTunnel.RunInput(
                    route: "feedface12345678",
                    target: "127.0.0.1:4096",
                    onURL: { url in urlHistory.withLock { $0.append(url) } }
                ),
                ctx
            )
        }

        // Wait until live tunnel URL is published
        for _ in 0..<80 {
            if urlHistory.withLock({ $0.contains("https://feedface12345678.live001.opentunnel.xyz") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(claimedRoutes.withLock { $0 } == ["feedface12345678"])
        #expect(urlHistory.withLock { $0 }.contains("https://feedface12345678.live001.opentunnel.xyz"))

        // Cancel tunnel task -> must close OpenTunnelConnection and emit onURL(nil)
        task.cancel()
        await task.value
        #expect(urlHistory.withLock { $0.last } == .some(nil))
    }

    // MARK: - 4. Integration with `opencode service set remote true` & `opencode pair --remote --yes`

    @Test("opencode service set remote true and opencode pair --remote work end-to-end via OpenTunnelClientBackend")
    func serviceSetRemoteAndPairIntegration() async throws {
        // 1. `opencode service set remote true` provisions tunnel via real OpenTunnelClient + HTTP transport
        let provisionHTTP = MockCLIHTTPTransport { req in
            if req.method == "POST" && req.url.hasSuffix("/api/tunnel") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 201, headers: ["content-type": "application/json"]),
                    body: OpenTunnelBridgeTestHelper.encodeJSONBytes(
                        OpenTunnelCreateResponse(
                            tunnel: OpenTunnelInfo(id: "svc123456789", hostname: "svc123456789.opentunnel.xyz"),
                            token: "tok-svc-remote"
                        )
                    )
                )
            }
            if req.method == "POST" && req.url.hasSuffix("/certificate") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 202, headers: ["content-type": "application/json"]),
                    body: OpenTunnelBridgeTestHelper.encodeJSONBytes(
                        OpenTunnelCertificateInfo(id: "cert-svc", state: .issuing)
                    )
                )
            }
            if req.method == "GET" && req.url.hasSuffix("/certificate") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: OpenTunnelBridgeTestHelper.encodeJSONBytes(
                        OpenTunnelCertificateInfo(
                            id: "cert-svc",
                            state: .ready(certificate: "CERT-SVC", chain: "CHAIN-SVC", expiry: "2099-01-01T00:00:00.000Z")
                        )
                    )
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let (serviceCtx, serviceOut, serviceFS) = CLITestFixtures.makeContext(
            env: ["OPENTUNNEL_API": "https://api.opentunnel.test"],
            transport: provisionHTTP
        )
        try await CLIServices.ServiceConfig.set(key: "remote", value: "true", context: serviceCtx)
        #expect(serviceOut.stderr.contains("Setting up remote access; this can take a minute..."))

        let cfg = try await CLIServices.ServiceConfig.read(context: serviceCtx)
        let route = try #require(cfg.remote?.route)
        #expect(OpenTunnelNames.isValidRouteName(route))

        // Verify the identity persisted into InMemoryFileSystem is read directly by RemoteTunnel.hostname
        let expectedHost = await CLIServices.RemoteTunnel.hostname(route, serviceCtx)
        #expect(expectedHost == "\(route).svc123456789.opentunnel.xyz")
        #expect(await serviceFS.exists(at: "/home/tester/.config/opentunnel/default/tunnel.json"))

        // 2. `opencode pair --remote --yes` discovers stored OpenTunnel identity without any mock backend!
        var pairFiles = OpenTunnelBridgeTestHelper.storedIdentityFiles(
            configRoot: "/home/tester/.config",
            identity: OpenTunnelBridgeTestHelper.sampleIdentity(hostname: "svc123456789.opentunnel.xyz")
        )
        pairFiles["/home/tester/.local/state/opencode/service.json"] =
            "{\"id\":\"svc-1\",\"version\":\"2.1.0\",\"url\":\"http://127.0.0.1:49374\",\"pid\":4242,\"password\":\"secret\"}"
        pairFiles["/home/tester/.config/opencode/service.json"] =
            "{\"remote\":{\"route\":\"\(route)\"},\"remoteAccepted\":true}"

        let pairTransport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":4242,\"urls\":[\"http://127.0.0.1:49374\",\"https://\(route).svc123456789.opentunnel.xyz\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/pair") && req.method == "POST" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"code\":\"PAIRREAL99\",\"expires_in\":600}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }

        let (pairCtx, pairOut, _) = CLITestFixtures.makeContext(
            files: pairFiles,
            transport: pairTransport,
            signaler: MockServiceSignaler(running: [4242])
        )
        let exitCode = await CLIEntrypoint.run(arguments: ["pair", "--remote", "--yes"], context: pairCtx)
        #expect(exitCode == 0)
        #expect(pairOut.stdout.contains("https://\(route).svc123456789.opentunnel.xyz/auth/connect/PAIRREAL99"))
        #expect(pairOut.stdout.contains("\u{2588}"))
    }
}
