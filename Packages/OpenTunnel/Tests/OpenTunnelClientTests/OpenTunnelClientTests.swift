import Testing
import Synchronization
@testable import OpenTunnelClient

// MARK: - Module & Error Classification

@Suite("OpenTunnelClient Errors & Metadata")
struct OpenTunnelErrorsTests {
    @Test("module version, user-agent, and defaults match upstream 0.6.1")
    func moduleMetadata() {
        #expect(OpenTunnelClientModule.version == "0.6.1")
        #expect(OpenTunnelClientModule.defaultAPIURL == "https://opentunnel.xyz")
        #expect(OpenTunnelClientModule.userAgent == "opentunnel-sdk/0.6.1")
        #expect(OpenTunnelClientModule.defaultProfile == "default")
    }

    @Test("OpenTunnelAttachError classifies fatal attach codes and formats conflict message")
    func attachErrorClassification() {
        let badToken = OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.badToken)
        #expect(badToken.isFatalAttachCode)
        #expect(badToken.message == "Bridge attach failed: bad_token")

        let certNotReady = OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.certNotReady)
        #expect(certNotReady.isFatalAttachCode)

        let conflict = OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.routeConflict)
        #expect(!conflict.isFatalAttachCode)
        #expect(conflict.message == "Bridge attach failed: route_conflict (another client holds a route)")

        let tooMany = OpenTunnelAttachError(code: OpenTunnelBridgeErrorCode.tooManyRoutes)
        #expect(!tooMany.isFatalAttachCode)
    }

    @Test("OpenTunnelError distinguishes fatal vs transient/retryable errors")
    func fatalVsRetryableClassification() {
        let attachErr = OpenTunnelClientError.attachFailed(OpenTunnelAttachError(code: "bad_token"))
        #expect(attachErr.isFatal)
        #expect(attachErr.code == "bad_token")
        #expect(OpenTunnelError.isFatalError(attachErr))
        #expect(OpenTunnelError.isFatalError(OpenTunnelError.client(attachErr)))

        let certErr = OpenTunnelClientError.certificateIssuanceFailed("ACME authorization failed")
        #expect(certErr.isFatal)
        #expect(certErr.message.hasPrefix("Certificate issuance failed"))
        #expect(OpenTunnelError.isFatalError(certErr))

        let socksErr = OpenTunnelClientError.unsupportedProxyScheme("socks5", source: "HTTPS_PROXY")
        #expect(socksErr.isFatal)
        #expect(socksErr.message.contains("unsupported proxy scheme"))
        #expect(OpenTunnelError.isFatalError(socksErr))

        let badProxyErr = OpenTunnelClientError.invalidProxyURL(source: "HTTPS_PROXY")
        #expect(badProxyErr.isFatal)
        #expect(badProxyErr.message.contains("not a valid proxy URL"))
        #expect(OpenTunnelError.isFatalError(badProxyErr))

        let transientErr = OpenTunnelClientError.transient("bridge closed: EOF")
        #expect(!transientErr.isFatal)
        #expect(transientErr.isTransient)
        #expect(!OpenTunnelError.isFatalError(transientErr))
        #expect(!OpenTunnelError.isFatalError(OpenTunnelError.client(transientErr)))

        let storageErr = OpenTunnelError.storage(OpenTunnelStorageError(message: "disk busy"))
        #expect(!storageErr.isFatal)
        #expect(!OpenTunnelError.isFatalError(storageErr))
    }
}

// MARK: - Names, Routes, Targets & PROXY Protocol

@Suite("OpenTunnelClient Names, Routes & PROXY Protocol")
struct OpenTunnelNamesAndRoutesTests {
    @Test("validates route names, profiles, public URLs, and SNI matching")
    func namesAndSNI() {
        #expect(OpenTunnelNames.isValidRouteName("@"))
        #expect(OpenTunnelNames.isValidRouteName("api"))
        #expect(OpenTunnelNames.isValidRouteName("0123456789abcdef"))
        #expect(OpenTunnelNames.isValidRouteName("a-1"))
        #expect(!OpenTunnelNames.isValidRouteName(""))
        #expect(!OpenTunnelNames.isValidRouteName("UPPER"))
        #expect(!OpenTunnelNames.isValidRouteName("-leading"))
        #expect(!OpenTunnelNames.isValidRouteName("trailing-"))
        #expect(!OpenTunnelNames.isValidRouteName("sub.domain"))
        #expect(!OpenTunnelNames.isValidRouteName(String(repeating: "a", count: 64)))

        #expect(OpenTunnelNames.isValidProfileName("default"))
        #expect(!OpenTunnelNames.isValidProfileName("@"))
        #expect(!OpenTunnelNames.isValidProfileName("../escape"))

        #expect(OpenTunnelNames.publicURL(route: "@", hostname: "abc123.opentunnel.xyz") == "https://abc123.opentunnel.xyz")
        #expect(OpenTunnelNames.publicURL(route: "web", hostname: "abc123.opentunnel.xyz") == "https://web.abc123.opentunnel.xyz")

        #expect(OpenTunnelNames.routeForSNI("abc123.opentunnel.xyz", hostname: "abc123.opentunnel.xyz") == "@")
        #expect(OpenTunnelNames.routeForSNI("API.ABC123.OPENTUNNEL.XYZ", hostname: "abc123.opentunnel.xyz") == "api")
        #expect(OpenTunnelNames.routeForSNI("deep.sub.abc123.opentunnel.xyz", hostname: "abc123.opentunnel.xyz") == nil)
        #expect(OpenTunnelNames.routeForSNI("other.example.com", hostname: "abc123.opentunnel.xyz") == nil)
    }

    @Test("parses host:port, [ipv6]:port, and http(s):// local targets")
    func targetParsing() throws {
        let t1 = try #require(OpenTunnelTarget.parse("127.0.0.1:4096"))
        #expect(t1.host == "127.0.0.1")
        #expect(t1.port == 4096)
        #expect(t1.urlString == "http://127.0.0.1:4096")

        let t2 = try #require(OpenTunnelTarget.parse("[::1]:8080"))
        #expect(t2.host == "::1")
        #expect(t2.port == 8080)
        #expect(t2.hostPort == "[::1]:8080")

        let t3 = try #require(OpenTunnelTarget.parse("http://127.0.0.1:3000/"))
        #expect(t3.host == "127.0.0.1")
        #expect(t3.port == 3000)

        #expect(OpenTunnelTarget.parse("127.0.0.1") == nil)
        #expect(OpenTunnelTarget.parse("127.0.0.1:0") == nil)
        #expect(OpenTunnelTarget.parse("127.0.0.1:70000") == nil)
        #expect(OpenTunnelTarget.parse(":8080") == nil)
        #expect(OpenTunnelTarget.parse("http://127.0.0.1:3000/path") == nil)
        #expect(OpenTunnelTarget.parse("socks5://127.0.0.1:1080") == nil)

        let resolved = try OpenTunnelRouteValidation.validateRoutes([
            "web": OpenTunnelRoute(target: "127.0.0.1:3000"),
            "api": OpenTunnelRoute(target: "http://127.0.0.1:4000", proxyProtocol: .v2),
        ])
        #expect(resolved["web"]?.target.port == 3000)
        #expect(resolved["api"]?.proxyProtocol == .v2)

        #expect(throws: OpenTunnelClientError.self) {
            try OpenTunnelRouteValidation.validateRoutes(["BAD_ROUTE": "127.0.0.1:3000"])
        }
        #expect(throws: OpenTunnelClientError.self) {
            try OpenTunnelRouteValidation.validateRoutes(["web": "not-a-target"])
        }
    }

    @Test("encodes PROXY protocol v1 and v2 headers accurately")
    func proxyProtocolHeaders() {
        let v1v4 = String(decoding: OpenTunnelProxyProtocolHeader.encode(version: .v1, peer: "203.0.113.9:51234", sni: "api.t.xyz"), as: UTF8.self)
        #expect(v1v4 == "PROXY TCP4 203.0.113.9 0.0.0.0 51234 443\r\n")

        let v1v6 = String(decoding: OpenTunnelProxyProtocolHeader.encode(version: .v1, peer: "[2001:0db8:0000:0000:0000:0000:0000:0001]:51234", sni: "api.t.xyz"), as: UTF8.self)
        #expect(v1v6 == "PROXY TCP6 2001:db8::1 :: 51234 443\r\n")

        let v1Mapped = String(decoding: OpenTunnelProxyProtocolHeader.encode(version: .v1, peer: "[::ffff:203.0.113.9]:51234", sni: "api.t.xyz"), as: UTF8.self)
        #expect(v1Mapped == "PROXY TCP4 203.0.113.9 0.0.0.0 51234 443\r\n")

        let v1Unknown = String(decoding: OpenTunnelProxyProtocolHeader.encode(version: .v1, peer: "not-an-ip", sni: "api.t.xyz"), as: UTF8.self)
        #expect(v1Unknown == "PROXY UNKNOWN\r\n")

        let v2v4 = OpenTunnelProxyProtocolHeader.encode(version: .v2, peer: "203.0.113.9:51234", sni: "api.t.xyz")
        #expect(Array(v2v4.prefix(12)) == OpenTunnelProxyProtocolHeader.v2Signature)
        #expect(v2v4[12] == 0x21) // V2_PROXY
        #expect(v2v4[13] == 0x11) // V2_TCP4
        // 12 addr bytes + 3 TLV header + 9 SNI bytes = 24
        #expect(((UInt16(v2v4[14]) << 8) | UInt16(v2v4[15])) == 24)
        #expect(v2v4[28] == 0x02) // PP2_TYPE_AUTHORITY
        #expect(String(decoding: v2v4[31...], as: UTF8.self) == "api.t.xyz")

        let v2Unknown = OpenTunnelProxyProtocolHeader.encode(version: .v2, peer: "invalid", sni: "a.b")
        #expect(v2Unknown[12] == 0x20) // V2_LOCAL
        #expect(v2Unknown[13] == 0x00) // V2_UNSPEC
        #expect(String(decoding: v2Unknown[19...], as: UTF8.self) == "a.b")
    }
}

// MARK: - Proxy Resolution & NO_PROXY

@Suite("OpenTunnelClient Proxy Resolver")
struct OpenTunnelProxyTests {
    @Test("parses http/https proxies, defaults missing scheme to http, and rejects socks5/invalid URLs without leaking secrets")
    func proxyParsingAndRejection() throws {
        let p1 = try OpenTunnelProxyResolver.parseProxy("http://user:secret@proxy.corp:3128", source: "HTTPS_PROXY")
        #expect(p1.scheme == "http")
        #expect(p1.host == "proxy.corp")
        #expect(p1.port == 3128)
        #expect(p1.username == "user")
        #expect(p1.password == "secret")
        #expect(p1.basicAuthorizationHeader != nil)

        let p2 = try OpenTunnelProxyResolver.parseProxy("proxy.internal:8080", source: "HTTP_PROXY")
        #expect(p2.scheme == "http")
        #expect(p2.host == "proxy.internal")
        #expect(p2.port == 8080)

        do {
            _ = try OpenTunnelProxyResolver.parseProxy("socks5://user:topsecret@127.0.0.1:1080", source: "ALL_PROXY")
            Issue.record("Expected socks5 proxy rejection")
        } catch let error {
            #expect(error.isFatal)
            #expect(error.message.contains("ALL_PROXY uses an unsupported proxy scheme 'socks5'"))
            #expect(!error.message.contains("topsecret"))
        }

        do {
            _ = try OpenTunnelProxyResolver.parseProxy("http://:badport", source: "HTTPS_PROXY")
            Issue.record("Expected invalid proxy URL rejection")
        } catch let error {
            #expect(error.isFatal)
            #expect(error.message == "HTTPS_PROXY is not a valid proxy URL")
        }
    }

    @Test("honors HTTPS_PROXY, HTTP_PROXY, ALL_PROXY precedence and NO_PROXY CIDR/domain/port rules")
    func envResolutionAndNoProxy() throws {
        let env = [
            "HTTPS_PROXY": "http://https-proxy:8443",
            "HTTP_PROXY": "http://http-proxy:8080",
            "ALL_PROXY": "http://all-proxy:9000",
            "NO_PROXY": "localhost, .internal.corp, 10.0.0.0/8, [2001:db8::]/32, exact.port:8443",
        ]

        let resolvedHTTPS = try OpenTunnelProxyResolver.resolveProxy(for: "wss://opentunnel.xyz/api/tunnel/x/connect", environment: env)
        #expect(resolvedHTTPS?.host == "https-proxy")
        #expect(resolvedHTTPS?.port == 8443)

        let resolvedHTTP = try OpenTunnelProxyResolver.resolveProxy(for: "ws://opentunnel.xyz/api/tunnel/x/connect", environment: env)
        #expect(resolvedHTTP?.host == "http-proxy")

        #expect(try OpenTunnelProxyResolver.resolveProxy(for: "https://sub.internal.corp/api", environment: env) == nil)
        #expect(try OpenTunnelProxyResolver.resolveProxy(for: "https://10.42.1.7/api", environment: env) == nil)
        #expect(try OpenTunnelProxyResolver.resolveProxy(for: "https://[2001:db8::5]/api", environment: env) == nil)
        #expect(try OpenTunnelProxyResolver.resolveProxy(for: "https://exact.port:8443/api", environment: env) == nil)
        #expect(try OpenTunnelProxyResolver.resolveProxy(for: "https://exact.port:443/api", environment: env)?.host == "https-proxy")

        #expect(OpenTunnelProxyResolver.bypassesProxy(host: "anything.example", port: 443, noProxy: "*"))
    }
}

// MARK: - XDG & Memory Storage

@Suite("OpenTunnelClient Storage")
struct OpenTunnelStorageTests {
    @Test("resolves POSIX ~/.config/opentunnel, XDG_CONFIG_HOME, Windows APPDATA, and XDG_DATA_HOME fallbacks")
    func xdgPathResolution() {
        #expect(
            OpenTunnelXDGPaths.primaryRoot(environment: [:], homeDirectory: "/Users/alice", platform: .posix)
                == "/Users/alice/.config/opentunnel"
        )
        #expect(
            OpenTunnelXDGPaths.primaryRoot(
                environment: ["XDG_CONFIG_HOME": "/custom/cfg"],
                homeDirectory: "/Users/alice",
                platform: .posix
            ) == "/custom/cfg/opentunnel"
        )
        #expect(
            OpenTunnelXDGPaths.primaryRoot(
                environment: ["APPDATA": "C:\\Users\\alice\\AppData\\Roaming"],
                homeDirectory: "C:\\Users\\alice",
                platform: .windows
            ) == "C:\\Users\\alice\\AppData\\Roaming\\opentunnel"
        )
        let fallbacks = OpenTunnelXDGPaths.fallbackReadRoots(
            environment: ["XDG_DATA_HOME": "/custom/data"],
            homeDirectory: "/Users/alice",
            platform: .posix
        )
        #expect(fallbacks.contains("/custom/data/opentunnel"))
    }

    @Test("OpenTunnelMemoryStorage persists identities, pending state, and rejects invalid profiles")
    func memoryStorageRoundTrip() async throws {
        let storage = OpenTunnelMemoryStorage()
        #expect(try await storage.load() == nil)
        #expect(try await storage.profiles().isEmpty)

        let pending = OpenTunnelPendingIdentity(
            id: "tun123456789",
            hostname: "tun123456789.opentunnel.xyz",
            token: "tok-secret",
            privateKey: "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n",
            csr: "-----BEGIN CERTIFICATE REQUEST-----\nCSR\n-----END CERTIFICATE REQUEST-----"
        )
        try await storage.savePending(pending)
        #expect(try await storage.loadPending() == pending)
        #expect(try await storage.profiles() == ["default"])

        let identity = OpenTunnelIdentity(
            id: pending.id,
            hostname: pending.hostname,
            token: pending.token,
            privateKey: pending.privateKey,
            certificate: "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----\n",
            chain: "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n",
            certificateExpiry: "2028-01-01T00:00:00.000Z"
        )
        try await storage.save(identity)
        #expect(try await storage.load() == identity)
        #expect(try await storage.loadPending() == nil)
        #expect(try await storage.list().count == 1)

        try await storage.remove()
        #expect(try await storage.load() == nil)

        await #expect(throws: OpenTunnelStorageError.self) {
            _ = try await storage.load(profile: "../bad")
        }
    }

    @Test("OpenTunnelXDGStorage atomically persists files with 0600 permissions and 0700 directory, plus XDG_DATA_HOME fallback")
    func xdgDiskStoragePermissionsAndFallback() async throws {
        let tmp = try OpenTunnelTestHelper.makeTempDirectory(prefix: "opentunnel-xdg")
        defer { OpenTunnelTestHelper.removePath(tmp) }

        let configHome = "\(tmp)/config"
        let dataHome = "\(tmp)/data"
        let storage = OpenTunnelXDGStorage.xdg(
            environment: ["XDG_CONFIG_HOME": configHome, "XDG_DATA_HOME": dataHome],
            homeDirectory: tmp,
            platform: .posix
        )
        #expect(storage.rootDirectory == "\(configHome)/opentunnel")

        let pending = OpenTunnelPendingIdentity(
            id: "abc123def456",
            hostname: "abc123def456.opentunnel.xyz",
            token: "secret-token-value",
            privateKey: "-----BEGIN PRIVATE KEY-----\nPRIVATE\n-----END PRIVATE KEY-----\n",
            csr: "-----BEGIN CERTIFICATE REQUEST-----\nCSRDATA\n-----END CERTIFICATE REQUEST-----"
        )
        try await storage.savePending(pending)
        #expect(try await storage.loadPending() == pending)

        let profileDir = storage.profileDirectory(for: "default")
        #expect(OpenTunnelTestHelper.posixMode(of: profileDir) == 0o700)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/token") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/private-key.pem") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/pending.json") == 0o600)

        let identity = OpenTunnelIdentity(
            id: pending.id,
            hostname: pending.hostname,
            token: pending.token,
            privateKey: pending.privateKey,
            certificate: "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n",
            chain: "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n",
            certificateExpiry: "2028-06-01T12:00:00.000Z"
        )
        try await storage.save(identity)
        #expect(!OpenTunnelTestHelper.fileExists("\(profileDir)/pending.json"))
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/tunnel.json") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/token") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/private-key.pem") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/certificate.pem") == 0o600)
        #expect(OpenTunnelTestHelper.posixMode(of: "\(profileDir)/chain.pem") == 0o600)

        let loaded = try await storage.load()
        #expect(loaded == identity)
        #expect(try await storage.profiles() == ["default"])

        // Test fallback loading from upstream XDG_DATA_HOME layout (`$XDG_DATA_HOME/opentunnel/<profile>/`)
        let legacyProfileDir = "\(dataHome)/opentunnel/secondary"
        try OpenTunnelTestHelper.writeFile(
            "{\"id\":\"leg999\",\"hostname\":\"leg999.opentunnel.xyz\",\"certificateExpiry\":\"2029-01-01T00:00:00.000Z\"}\n",
            to: "\(legacyProfileDir)/tunnel.json"
        )
        try OpenTunnelTestHelper.writeFile("legacy-tok\n", to: "\(legacyProfileDir)/token")
        try OpenTunnelTestHelper.writeFile("KEY", to: "\(legacyProfileDir)/private-key.pem")
        try OpenTunnelTestHelper.writeFile("CERT", to: "\(legacyProfileDir)/certificate.pem")
        try OpenTunnelTestHelper.writeFile("CHAIN", to: "\(legacyProfileDir)/chain.pem")

        let legacyLoaded = try await storage.load(profile: "secondary")
        #expect(legacyLoaded?.id == "leg999")
        #expect(legacyLoaded?.hostname == "leg999.opentunnel.xyz")
        #expect(legacyLoaded?.token == "legacy-tok")

        try await storage.remove(profile: "default")
        #expect(try await storage.load(profile: "default") == nil)
    }
}

// MARK: - Cryptography, Wire Protocol & Timestamps

@Suite("OpenTunnelClient Crypto, Protocol & Timestamps")
struct OpenTunnelProtocolAndCryptoTests {
    @Test("generates valid PKCS#8 P-256 key and signed PKCS#10 CSR with CN and wildcard SAN")
    func keyAndCSRGeneration() async throws {
        let host = "abcd1234efgh.opentunnel.xyz"
        let generated = try await DefaultOpenTunnelKeyProvider.shared.generateKeyAndCSR(hostname: host)
        #expect(generated.privateKeyPEM.contains("-----BEGIN PRIVATE KEY-----"))
        #expect(generated.csrPEM.contains("-----BEGIN CERTIFICATE REQUEST-----"))
        let der = try #require(OpenTunnelTestHelper.decodePEMBody(generated.csrPEM))
        #expect(OpenTunnelTestHelper.bytesContainASCII(der, host))
        #expect(OpenTunnelTestHelper.bytesContainASCII(der, "*.\(host)"))

        // Also cross-verify our pure-Swift NIST P-256 + SHA-256 CSR implementation against CryptoKit!
        let pureCheck = try OpenTunnelTestHelper.verifyPureSwiftCSR(hostname: host)
        #expect(pureCheck.pemValid)
        #expect(pureCheck.cryptoVerified)
        #expect(pureCheck.containsHost)
        #expect(pureCheck.containsWildcard)
    }

    @Test("encodes and decodes bridge control messages, ignores unknown types, and roundtrips binary frames")
    func bridgeProtocolFraming() throws {
        let attachText = try OpenTunnelBridgeProtocol.encodeClientMessage(
            .attach(
                token: "tok-1",
                transport: "ws",
                routes: ["api", "web"],
                client: OpenTunnelBridgeClientInfo(version: "0.6.1", maxConns: 256)
            )
        )
        let parsedAttach = try #require(OpenTunnelTestHelper.decodeClientControlType(attachText))
        #expect(parsedAttach.type == "attach")
        #expect(parsedAttach.routes == ["api", "web"])

        let attached = OpenTunnelBridgeProtocol.decodeServerMessage(
            "{\"type\":\"attached\",\"session\":\"sess-1\",\"routes\":[\"api\"],\"heartbeat_ms\":15000,\"idle_timeout_ms\":45000,\"extra_future_field\":true}"
        )
        #expect(attached == .attached(session: "sess-1", routes: ["api"], heartbeatMs: 15_000, idleTimeoutMs: 45_000))

        let openMsg = OpenTunnelBridgeProtocol.decodeServerMessage(
            "{\"type\":\"open\",\"conn\":42,\"peer\":\"198.51.100.10:5555\",\"sni\":\"api.t.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        )
        #expect(openMsg == .open(conn: 42, peer: "198.51.100.10:5555", sni: "api.t.opentunnel.xyz", alpn: "http/1.1"))

        let unknown = OpenTunnelBridgeProtocol.decodeServerMessage("{\"type\":\"future_notice\",\"foo\":1}")
        #expect(unknown == .unknown(type: "future_notice"))
        #expect(OpenTunnelBridgeProtocol.decodeServerMessage("not-json") == nil)

        let payload: [UInt8] = Array("hello tunnel".utf8)
        let frame = OpenTunnelBridgeProtocol.buildDataFrame(conn: 0x0102_0304, payload: payload)
        #expect(Array(frame.prefix(4)) == [0x01, 0x02, 0x03, 0x04])
        let decodedFrame = try #require(OpenTunnelBridgeProtocol.parseDataFrame(frame))
        #expect(decodedFrame.conn == 0x0102_0304)
        #expect(decodedFrame.payload == payload)
        #expect(OpenTunnelBridgeProtocol.parseDataFrame([0x01, 0x02, 0x03]) == nil)
    }

    @Test("API retry classification, Retry-After cap, Cloudflare status descriptions, and ISO-8601 timestamps")
    func apiRetryAndTimestamps() throws {
        #expect(OpenTunnelAPIRetry.retryableStatus(429, repeatPolicy: .idempotent))
        #expect(OpenTunnelAPIRetry.retryableStatus(500, repeatPolicy: .idempotent))
        #expect(OpenTunnelAPIRetry.retryableStatus(525, repeatPolicy: .once))
        #expect(!OpenTunnelAPIRetry.retryableStatus(500, repeatPolicy: .once))
        #expect(!OpenTunnelAPIRetry.retryableStatus(401, repeatPolicy: .idempotent))

        let range0 = OpenTunnelAPIRetry.retryDelayMs(attempt: 0)
        #expect(range0.min == 125 && range0.max == 250)
        let rangeCap = OpenTunnelAPIRetry.retryDelayMs(attempt: 10)
        #expect(rangeCap.min == 4_000 && rangeCap.max == 8_000)
        let retryAfter = OpenTunnelAPIRetry.retryDelayMs(attempt: 0, retryAfter: "30")
        #expect(retryAfter.min == 8_000 && retryAfter.max == 8_000)

        let cfMsg = OpenTunnelAPIRetry.statusMessage(status: 525, body: "<html>CF</html>")
        #expect(cfMsg == "Cloudflare 525: the SSL handshake with the server failed (HTTP 525)")

        let epoch = try #require(OpenTunnelTimestamp.parseISO8601("2028-02-29T13:45:30.250Z"))
        #expect(OpenTunnelTimestamp.formatISO8601(epochSeconds: epoch) == "2028-02-29T13:45:30.250Z")
        let withOffset = try #require(OpenTunnelTimestamp.parseISO8601("2028-02-29T15:45:30.250+02:00"))
        #expect(withOffset == epoch)
    }
}

// MARK: - OpenTunnelClient Provisioning, Resume, Renewal & Remove

@Suite("OpenTunnelClient Provisioning Lifecycle")
struct OpenTunnelClientLifecycleTests {
    private static let fastTiming = OpenTunnelTimingConfiguration(
        certificatePollIntervalMs: 5,
        connectTimeoutMs: 500,
        minHeartbeatMs: 25,
        minIdleTimeoutMs: 80,
        reconnectBackoffMinMs: 10,
        reconnectBackoffMaxMs: 40,
        certificateCheckFreshMs: 60_000,
        certificateCheckDueMs: 60_000,
        apiMaxRetries: 3,
        apiRetryBaseMs: 2,
        apiRetryMaxMs: 10
    )

    @Test("ensure creates tunnel, polls certificate challenge->issuing->ready, persists identity, and emits stages")
    func ensureCreatesAndPollsCertificate() async throws {
        let storage = OpenTunnelMemoryStorage()
        let pollCounter = Mutex(0)
        let stages = Mutex<[OpenTunnelProvisionStage]>([])

        let transport = MockOpenTunnelTransport(http: { req in
            if req.method == "POST" && req.url.hasSuffix("/api/tunnel") {
                return OpenTunnelHTTPResponse(
                    statusCode: 201,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelCreateResponse(
                            tunnel: OpenTunnelInfo(id: "dev123456789", hostname: "dev123456789.opentunnel.xyz", state: .offline),
                            token: "tok-created-1"
                        )
                    )
                )
            }
            if req.method == "POST" && req.url.hasSuffix("/api/tunnel/dev123456789/certificate") {
                #expect(req.headers["authorization"] == "Bearer tok-created-1")
                return OpenTunnelHTTPResponse(
                    statusCode: 202,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelCertificateInfo(id: "cert-1", state: .challenge(token: "ch", key: "k"))
                    )
                )
            }
            if req.method == "GET" && req.url.hasSuffix("/api/tunnel/dev123456789/certificate") {
                let n = pollCounter.withLock { c -> Int in c += 1; return c }
                let certState: OpenTunnelCertificateState = switch n {
                case 1: .challenge(token: "ch", key: "k")
                case 2: .issuing
                default: .ready(certificate: "CERT-V1", chain: "CHAIN-V1", expiry: "2029-01-01T00:00:00.000Z")
                }
                return OpenTunnelHTTPResponse(
                    statusCode: 200,
                    body: OpenTunnelTestHelper.encodeJSONBytes(OpenTunnelCertificateInfo(id: "cert-1", state: certState))
                )
            }
            return OpenTunnelHTTPResponse(statusCode: 404)
        })

        let client = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: Self.fastTiming
        )

        #expect(try await client.tunnel.get() == nil)
        let identity = try await client.tunnel.ensure { stage in
            stages.withLock { $0.append(stage) }
        }
        #expect(identity.id == "dev123456789")
        #expect(identity.hostname == "dev123456789.opentunnel.xyz")
        #expect(identity.token == "tok-created-1")
        #expect(identity.certificate == "CERT-V1")
        #expect(try await client.tunnel.get() == identity)
        #expect(try await client.tunnel.pending() == nil)

        let recordedStages = stages.withLock { $0 }
        #expect(recordedStages.contains(.creatingTunnel))
        #expect(recordedStages.contains(.generatingKey))
        #expect(recordedStages.contains(.generatingCSR))
        #expect(recordedStages.contains(.requestingCertificate))
        #expect(recordedStages.contains(.waitingCertificate))
        #expect(recordedStages.contains(.savingIdentity))
        #expect(recordedStages.last == .ready)
    }

    @Test("ensure resumes interrupted pending provisioning and tolerates CertificateInProgressError")
    func ensureResumesPendingProvision() async throws {
        let pending = OpenTunnelPendingIdentity(
            id: "res123456789",
            hostname: "res123456789.opentunnel.xyz",
            token: "tok-resume",
            privateKey: "KEY-RESUME",
            csr: "CSR-RESUME"
        )
        let storage = OpenTunnelMemoryStorage(initialPending: ["default": pending])

        let transport = MockOpenTunnelTransport(http: { req in
            if req.method == "POST" && req.url.hasSuffix("/certificate") {
                return OpenTunnelHTTPResponse(
                    statusCode: 409,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelAPIErrorBody(tag: "CertificateInProgressError", message: "Issuance already running")
                    )
                )
            }
            if req.method == "GET" && req.url.hasSuffix("/certificate") {
                return OpenTunnelHTTPResponse(
                    statusCode: 200,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelCertificateInfo(
                            id: "cert-res",
                            state: .ready(certificate: "CERT-RESUMED", chain: "CHAIN", expiry: "2029-05-01T00:00:00.000Z")
                        )
                    )
                )
            }
            return OpenTunnelHTTPResponse(statusCode: 404)
        })

        let client = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: Self.fastTiming
        )

        #expect(try await client.tunnel.pending()?.id == "res123456789")
        let identity = try await client.tunnel.ensure()
        #expect(identity.id == "res123456789")
        #expect(identity.certificate == "CERT-RESUMED")
        #expect(try await client.tunnel.pending() == nil)
    }

    @Test("ensure updates renewed certificate, falls back to non-expired cert on transient 525, and fails fatally on cert failure")
    func ensureRenewalOfflineFallbackAndFailure() async throws {
        let existing = OpenTunnelIdentity(
            id: "tun999",
            hostname: "tun999.opentunnel.xyz",
            token: "tok-999",
            privateKey: "KEY",
            certificate: "CERT-OLD",
            chain: "CHAIN-OLD",
            certificateExpiry: "2099-01-01T00:00:00.000Z"
        )

        // 1. Offline/transient 525 fallback keeps non-expired certificate
        let storageOffline = OpenTunnelMemoryStorage(initialIdentities: ["default": existing])
        let offlineTransport = MockOpenTunnelTransport(http: { _ in
            OpenTunnelHTTPResponse(statusCode: 525, body: Array("Cloudflare 525".utf8))
        })
        let offlineClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storageOffline,
            transport: offlineTransport,
            environment: [:],
            timing: Self.fastTiming
        )
        let kept = try await offlineClient.tunnel.ensure()
        #expect(kept == existing)
        #expect(offlineTransport.httpRequests.count == 4) // initial + 3 retries

        // 2. Server renewed certificate updates storage
        let storageRenew = OpenTunnelMemoryStorage(initialIdentities: ["default": existing])
        let renewTransport = MockOpenTunnelTransport(http: { _ in
            OpenTunnelHTTPResponse(
                statusCode: 200,
                body: OpenTunnelTestHelper.encodeJSONBytes(
                    OpenTunnelCertificateInfo(
                        id: "cert-new",
                        state: .ready(certificate: "CERT-NEW", chain: "CHAIN-NEW", expiry: "2099-06-01T00:00:00.000Z")
                    )
                )
            )
        })
        let renewClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storageRenew,
            transport: renewTransport,
            environment: [:],
            timing: Self.fastTiming
        )
        let renewed = try await renewClient.tunnel.ensure()
        #expect(renewed.certificate == "CERT-NEW")
        #expect(try await storageRenew.load()?.certificate == "CERT-NEW")

        // 3. Failed certificate issuance throws fatal error
        let storageFail = OpenTunnelMemoryStorage()
        let failTransport = MockOpenTunnelTransport(http: { req in
            if req.method == "POST" && req.url.hasSuffix("/api/tunnel") {
                return OpenTunnelHTTPResponse(
                    statusCode: 201,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelCreateResponse(
                            tunnel: OpenTunnelInfo(id: "badcert1", hostname: "badcert1.opentunnel.xyz"),
                            token: "tok-bad"
                        )
                    )
                )
            }
            if req.method == "POST" && req.url.hasSuffix("/certificate") {
                return OpenTunnelHTTPResponse(
                    statusCode: 202,
                    body: OpenTunnelTestHelper.encodeJSONBytes(OpenTunnelCertificateInfo(id: "c", state: .issuing))
                )
            }
            return OpenTunnelHTTPResponse(
                statusCode: 200,
                body: OpenTunnelTestHelper.encodeJSONBytes(
                    OpenTunnelCertificateInfo(id: "c", state: .failed(reason: "CAA record blocked issuance"))
                )
            )
        })
        let failClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storageFail,
            transport: failTransport,
            environment: [:],
            timing: Self.fastTiming
        )
        do {
            _ = try await failClient.tunnel.ensure()
            Issue.record("Expected fatal certificate issuance failure")
        } catch let error as OpenTunnelClientError {
            #expect(error.isFatal)
            #expect(error.message == "Certificate issuance failed: CAA record blocked issuance")
        }
    }

    @Test("remove deletes remote tunnel and clears local storage; invalid explicit proxy fails at init")
    func removeAndExplicitProxyRejection() async throws {
        let existing = OpenTunnelIdentity(
            id: "rm123",
            hostname: "rm123.opentunnel.xyz",
            token: "tok-rm",
            privateKey: "KEY",
            certificate: "CERT",
            chain: "",
            certificateExpiry: "2099-01-01T00:00:00.000Z"
        )
        let storage = OpenTunnelMemoryStorage(initialIdentities: ["default": existing])
        let transport = MockOpenTunnelTransport(http: { req in
            #expect(req.method == "DELETE")
            #expect(req.url.hasSuffix("/api/tunnel/rm123"))
            #expect(req.headers["authorization"] == "Bearer tok-rm")
            return OpenTunnelHTTPResponse(statusCode: 204)
        })
        let client = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: Self.fastTiming
        )
        try await client.tunnel.remove()
        #expect(try await client.tunnel.get() == nil)

        do {
            _ = try OpenTunnelClient(storage: storage, transport: transport, proxy: "socks5://127.0.0.1:1080")
            Issue.record("Expected fatal error for socks5 explicit proxy")
        } catch let err {
            #expect(err.isFatal)
            #expect(err.message.contains("unsupported proxy scheme 'socks5'"))
        }
    }
}

// MARK: - Live Bridge Control, Heartbeat, Reconnect & Loopback HTTP/SSE/WS Forwarding

@Suite("OpenTunnelClient Bridge & Reverse Proxy")
struct OpenTunnelBridgeForwardingTests {
    private static let fastTiming = OpenTunnelTimingConfiguration(
        certificatePollIntervalMs: 5,
        connectTimeoutMs: 400,
        minHeartbeatMs: 25,
        minIdleTimeoutMs: 120,
        reconnectBackoffMinMs: 10,
        reconnectBackoffMaxMs: 30,
        certificateCheckFreshMs: 60_000,
        certificateCheckDueMs: 60_000,
        apiMaxRetries: 1,
        apiRetryBaseMs: 2,
        apiRetryMaxMs: 5
    )

    private static func sampleIdentity() -> OpenTunnelIdentity {
        OpenTunnelIdentity(
            id: "brg123456789",
            hostname: "brg123456789.opentunnel.xyz",
            token: "tok-bridge-secret",
            privateKey: "KEY",
            certificate: "CERT",
            chain: "CHAIN",
            certificateExpiry: "2099-01-01T00:00:00.000Z"
        )
    }

    @Test("connect claims routes, handles heartbeat ping/pong, reconnects on drain, supports setRoutes, and closes cleanly")
    func bridgeControlHeartbeatDrainAndSetRoutes() async throws {
        let storage = OpenTunnelMemoryStorage(initialIdentities: ["default": Self.sampleIdentity()])
        let sessionNumber = Mutex(0)
        let receivedPongs = Mutex<[Int64]>([])
        let receivedClientPings = Mutex(0)
        let attachedRouteLists = Mutex<[[String]]>([])
        let secondSessionServer = Mutex<InMemoryOpenTunnelWebSocket?>(nil)

        let transport = MockOpenTunnelTransport(
            http: { _ in
                OpenTunnelHTTPResponse(
                    statusCode: 200,
                    body: OpenTunnelTestHelper.encodeJSONBytes(
                        OpenTunnelCertificateInfo(
                            id: "c1",
                            state: .ready(certificate: "CERT", chain: "CHAIN", expiry: "2099-01-01T00:00:00.000Z")
                        )
                    )
                )
            },
            ws: { _, protocols, _, _ in
                #expect(protocols == ["opentunnel"])
                let (clientWS, serverWS) = InMemoryOpenTunnelWebSocket.makePair()
                let num = sessionNumber.withLock { n -> Int in n += 1; return n }
                if num >= 2 {
                    secondSessionServer.withLock { $0 = serverWS }
                }
                Task {
                    do {
                        for try await frame in serverWS.incoming {
                            guard case .text(let text) = frame,
                                  let msg = OpenTunnelTestHelper.decodeClientControlType(text)
                            else { continue }
                            switch msg.type {
                            case "attach":
                                let claimed = msg.routes ?? []
                                attachedRouteLists.withLock { $0.append(claimed) }
                                let routesJSON = OpenTunnelTestHelper.encodeJSONString(claimed)
                                try await serverWS.send(.text(
                                    "{\"type\":\"attached\",\"session\":\"sess-\(num)\",\"routes\":\(routesJSON),\"heartbeat_ms\":30,\"idle_timeout_ms\":400}"
                                ))
                                if num == 1 {
                                    // Send server ping to verify client replies pong immediately
                                    try await serverWS.send(.text("{\"type\":\"ping\",\"time_sent\":987654}"))
                                }
                            case "pong":
                                if let ts = msg.timeSent {
                                    receivedPongs.withLock { $0.append(ts) }
                                }
                                if num == 1 {
                                    // Trigger graceful drain reconnect
                                    try await serverWS.send(.text("{\"type\":\"drain\",\"reason\":\"deploy\"}"))
                                }
                            case "ping":
                                receivedClientPings.withLock { $0 += 1 }
                                if let ts = msg.timeSent {
                                    try await serverWS.send(.text("{\"type\":\"pong\",\"time_sent\":\(ts)}"))
                                }
                            default:
                                break
                            }
                        }
                    } catch {}
                }
                return clientWS
            }
        )

        let events = Mutex<[OpenTunnelClientEvent]>([])
        let client = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: Self.fastTiming
        )

        let conn = try await client.tunnel.connect(
            routes: ["web": "127.0.0.1:3000"],
            onEvent: { ev in events.withLock { $0.append(ev) } }
        )
        #expect(conn.tunnel.hostname == "brg123456789.opentunnel.xyz")
        #expect(conn.urls["web"] == "https://web.brg123456789.opentunnel.xyz")

        // Wait for drain reconnect -> session 2 attached and at least one client ping
        for _ in 0..<80 {
            if sessionNumber.withLock({ $0 }) >= 2 && receivedClientPings.withLock({ $0 }) >= 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(receivedPongs.withLock { $0 }.contains(987_654))
        #expect(sessionNumber.withLock { $0 } >= 2)
        #expect(receivedClientPings.withLock { $0 } >= 1)

        // Target-only setRoutes does NOT re-attach
        let sessionsBeforeTargetUpdate = sessionNumber.withLock { $0 }
        try await conn.setRoutes(["web": "127.0.0.1:4000"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(sessionNumber.withLock { $0 } == sessionsBeforeTargetUpdate)

        // Adding a new route name triggers re-attach claiming both routes
        try await conn.setRoutes(["web": "127.0.0.1:4000", "api": "127.0.0.1:5000"])
        for _ in 0..<50 {
            if attachedRouteLists.withLock({ $0.last == ["api", "web"] }) { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(attachedRouteLists.withLock { $0.last } == ["api", "web"])
        #expect(conn.urls["api"] == "https://api.brg123456789.opentunnel.xyz")

        // Graceful shutdown completes `closed` cleanly
        await conn.close()
        try await conn.closed
        #expect(conn.status.state == .stopped)
    }

    @Test("connect rejects fatal bad_token immediately and respects onRouteConflict fail vs retry")
    func fatalAttachErrorsAndRouteConflictPolicy() async throws {
        let storage = OpenTunnelMemoryStorage(initialIdentities: ["default": Self.sampleIdentity()])

        // 1. Fatal bad_token rejects connect with OpenTunnelClientError wrapping OpenTunnelAttachError
        let badTokenTransport = MockOpenTunnelTransport(
            http: { _ in OpenTunnelHTTPResponse(statusCode: 503) },
            ws: { _, _, _, _ in
                let (clientWS, serverWS) = InMemoryOpenTunnelWebSocket.makePair()
                Task {
                    for try await frame in serverWS.incoming {
                        if case .text = frame {
                            try? await serverWS.send(.text("{\"type\":\"attach_error\",\"code\":\"bad_token\"}"))
                            await serverWS.close(code: 1008, reason: "bad_token")
                            break
                        }
                    }
                }
                return clientWS
            }
        )
        let badClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: badTokenTransport,
            environment: [:],
            timing: Self.fastTiming
        )
        do {
            _ = try await badClient.tunnel.connect(routes: ["web": "127.0.0.1:3000"])
            Issue.record("Expected fatal attach error for bad_token")
        } catch let error as OpenTunnelClientError {
            #expect(error.isFatal)
            #expect(error.code == "bad_token")
            #expect(error.attachError == OpenTunnelAttachError(code: "bad_token"))
        }

        // 2. route_conflict with .fail stops immediately; with .retry succeeds on attempt 2
        let attempts = Mutex(0)
        let conflictTransport = MockOpenTunnelTransport(
            http: { _ in OpenTunnelHTTPResponse(statusCode: 503) },
            ws: { _, _, _, _ in
                let (clientWS, serverWS) = InMemoryOpenTunnelWebSocket.makePair()
                let attempt = attempts.withLock { a -> Int in a += 1; return a }
                Task {
                    for try await frame in serverWS.incoming {
                        if case .text = frame {
                            if attempt == 1 {
                                try? await serverWS.send(.text("{\"type\":\"attach_error\",\"code\":\"route_conflict\"}"))
                                await serverWS.close(code: 1008, reason: "conflict")
                            } else {
                                try? await serverWS.send(.text(
                                    "{\"type\":\"attached\",\"session\":\"s-ok\",\"routes\":[\"web\"],\"heartbeat_ms\":5000,\"idle_timeout_ms\":15000}"
                                ))
                            }
                            break
                        }
                    }
                }
                return clientWS
            }
        )
        let conflictClient = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: conflictTransport,
            environment: [:],
            timing: Self.fastTiming
        )
        do {
            _ = try await conflictClient.tunnel.connect(routes: ["web": "127.0.0.1:3000"], onRouteConflict: .fail)
            Issue.record("Expected route_conflict failure under .fail policy")
        } catch let err as OpenTunnelClientError {
            #expect(err.code == "route_conflict")
            #expect(err.attachError == OpenTunnelAttachError(code: "route_conflict"))
        }

        // Reset attempt counter and verify .retry succeeds on attempt 2
        attempts.withLock { $0 = 0 }
        let conflictEvents = Mutex<[OpenTunnelClientEvent]>([])
        let conn = try await conflictClient.tunnel.connect(
            routes: ["web": "127.0.0.1:3000"],
            onRouteConflict: .retry,
            onEvent: { ev in conflictEvents.withLock { $0.append(ev) } }
        )
        #expect(attempts.withLock { $0 } == 2)
        #expect(conflictEvents.withLock { $0 }.contains(.routeConflict(routes: ["web"])))
        await conn.close()
    }

    @Test("live reverse-proxy bridge forwards HTTP, streaming SSE, WebSocket upgrade, and PROXY protocol to local 127.0.0.1 TCP server")
    func liveLoopbackReverseProxyHTTPAndSSEAndWS() async throws {
        // Boot a real loopback POSIX TCP server serving HTTP JSON, streaming SSE, and WS echo!
        let receivedPayloads = Mutex<[String]>([])
        let loopbackServer = try LoopbackTestTCPServer { clientFD in
            let reqBytes = LoopbackTestTCPServer.readUntilHeadersEnd(fd: clientFD)
            let reqText = String(decoding: reqBytes, as: UTF8.self)
            receivedPayloads.withLock { $0.append(reqText) }

            if reqText.contains("GET /api/ping") {
                let body = "{\"ok\":true,\"via\":\"opentunnel\"}"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array(resp.utf8))
            } else if reqText.contains("GET /events") {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
                LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array(header.utf8))
                LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array("data: chunk-1\n\n".utf8))
                LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array("data: chunk-2\n\n".utf8))
            } else if reqText.contains("Upgrade: websocket") {
                let upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array(upgrade.utf8))
                let wsPayload = LoopbackTestTCPServer.readChunk(fd: clientFD)
                if !wsPayload.isEmpty {
                    LoopbackTestTCPServer.writeAll(fd: clientFD, bytes: Array("ECHO:".utf8) + wsPayload)
                }
            }
        }
        defer { loopbackServer.stop() }

        let storage = OpenTunnelMemoryStorage(initialIdentities: ["default": Self.sampleIdentity()])
        let serverWSBox = Mutex<InMemoryOpenTunnelWebSocket?>(nil)

        let transport = MockOpenTunnelTransport(
            http: { _ in OpenTunnelHTTPResponse(statusCode: 503) },
            ws: { _, _, _, _ in
                let (clientWS, serverWS) = InMemoryOpenTunnelWebSocket.makePair()
                serverWSBox.withLock { $0 = serverWS }
                return clientWS
            },
            local: { target in
                // Use REAL LiveOpenTunnelTransport TCP forwarding to 127.0.0.1:<loopbackServer.port>!
                try await LiveOpenTunnelTransport.shared.openLocalConnection(target: target)
            }
        )

        let client = try OpenTunnelClient(
            apiURL: "https://api.opentunnel.test",
            storage: storage,
            transport: transport,
            environment: [:],
            timing: Self.fastTiming
        )

        let connectTask = Task {
            try await client.tunnel.connect(routes: [
                "svc": OpenTunnelRoute(target: "http://127.0.0.1:\(loopbackServer.port)"),
                "pp": OpenTunnelRoute(target: "127.0.0.1:\(loopbackServer.port)", proxyProtocol: .v1),
            ])
        }

        // Wait for mock relay WebSocket to open
        var relayWS: InMemoryOpenTunnelWebSocket?
        for _ in 0..<50 {
            if let ws = serverWSBox.withLock({ $0 }) {
                relayWS = ws
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let relay = try #require(relayWS)

        // Collect all outgoing frames from client in background
        let connBuffers = Mutex<[UInt32: [UInt8]]>([:])
        let connEnded = Mutex<Set<UInt32>>([])
        let connResets = Mutex<[UInt32: String]>([:])
        let relayReader = Task {
            for try await frame in relay.incoming {
                switch frame {
                case .text(let text):
                    guard let msg = OpenTunnelTestHelper.decodeClientControlType(text) else { continue }
                    if msg.type == "attach" {
                        try await relay.send(.text(
                            "{\"type\":\"attached\",\"session\":\"live-1\",\"routes\":[\"pp\",\"svc\"],\"heartbeat_ms\":15000,\"idle_timeout_ms\":45000}"
                        ))
                    } else if msg.type == "end", let c = msg.conn {
                        _ = connEnded.withLock { $0.insert(c) }
                    } else if msg.type == "reset", let c = msg.conn, let code = msg.code {
                        connResets.withLock { $0[c] = code }
                    }
                case .binary(let bytes):
                    if let parsed = OpenTunnelBridgeProtocol.parseDataFrame(bytes) {
                        connBuffers.withLock { $0[parsed.conn, default: []].append(contentsOf: parsed.payload) }
                    }
                case .close:
                    break
                }
            }
        }
        defer { relayReader.cancel() }

        let connection = try await connectTask.value

        // 1. Tunneled HTTP/1.1 GET /api/ping
        try await relay.send(.text(
            "{\"type\":\"open\",\"conn\":1,\"peer\":\"203.0.113.5:50001\",\"sni\":\"svc.brg123456789.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        ))
        try await relay.send(.binary(OpenTunnelBridgeProtocol.buildDataFrame(
            conn: 1,
            payload: Array("GET /api/ping HTTP/1.1\r\nHost: svc.brg123456789.opentunnel.xyz\r\n\r\n".utf8)
        )))

        // 2. Tunneled SSE GET /events
        try await relay.send(.text(
            "{\"type\":\"open\",\"conn\":2,\"peer\":\"203.0.113.5:50002\",\"sni\":\"svc.brg123456789.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        ))
        try await relay.send(.binary(OpenTunnelBridgeProtocol.buildDataFrame(
            conn: 2,
            payload: Array("GET /events HTTP/1.1\r\nHost: svc.brg123456789.opentunnel.xyz\r\n\r\n".utf8)
        )))

        // 3. Tunneled WebSocket upgrade + bidirectional payload echo
        try await relay.send(.text(
            "{\"type\":\"open\",\"conn\":3,\"peer\":\"203.0.113.5:50003\",\"sni\":\"svc.brg123456789.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        ))
        try await relay.send(.binary(OpenTunnelBridgeProtocol.buildDataFrame(
            conn: 3,
            payload: Array("GET /ws HTTP/1.1\r\nHost: svc.brg123456789.opentunnel.xyz\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        )))

        // 4. Route with PROXY protocol v1 preamble
        try await relay.send(.text(
            "{\"type\":\"open\",\"conn\":4,\"peer\":\"203.0.113.9:51234\",\"sni\":\"pp.brg123456789.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        ))
        try await relay.send(.binary(OpenTunnelBridgeProtocol.buildDataFrame(
            conn: 4,
            payload: Array("GET /api/ping HTTP/1.1\r\nHost: pp.brg123456789.opentunnel.xyz\r\n\r\n".utf8)
        )))

        // 5. Unknown SNI triggers `reset` with `unknown_route`
        try await relay.send(.text(
            "{\"type\":\"open\",\"conn\":99,\"peer\":\"203.0.113.5:50099\",\"sni\":\"nope.brg123456789.opentunnel.xyz\",\"alpn\":\"http/1.1\"}"
        ))

        // Wait for WS 101 upgrade before sending bidirectional WS payload on conn 3
        for _ in 0..<80 {
            let wsSoFar = String(decoding: connBuffers.withLock { $0[3] ?? [] }, as: UTF8.self)
            if wsSoFar.contains("101 Switching Protocols") { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        try await relay.send(.binary(OpenTunnelBridgeProtocol.buildDataFrame(
            conn: 3,
            payload: Array("hello-ws-frame".utf8)
        )))

        // Wait for all 4 proxied connections to complete and conn 99 to reset
        for _ in 0..<100 {
            let ended = connEnded.withLock { $0 }
            let resets = connResets.withLock { $0 }
            if ended.contains(1) && ended.contains(2) && ended.contains(3) && ended.contains(4) && resets[99] != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }

        let httpResp = String(decoding: connBuffers.withLock { $0[1] ?? [] }, as: UTF8.self)
        #expect(httpResp.contains("200 OK"))
        #expect(httpResp.contains("{\"ok\":true,\"via\":\"opentunnel\"}"))

        let sseResp = String(decoding: connBuffers.withLock { $0[2] ?? [] }, as: UTF8.self)
        #expect(sseResp.contains("text/event-stream"))
        #expect(sseResp.contains("data: chunk-1\n\n"))
        #expect(sseResp.contains("data: chunk-2\n\n"))

        let wsResp = String(decoding: connBuffers.withLock { $0[3] ?? [] }, as: UTF8.self)
        #expect(wsResp.contains("101 Switching Protocols"))
        #expect(wsResp.contains("ECHO:hello-ws-frame"))

        let ppResp = String(decoding: connBuffers.withLock { $0[4] ?? [] }, as: UTF8.self)
        #expect(ppResp.contains("200 OK"))
        let sawProxyHeader = receivedPayloads.withLock { list in
            list.contains { $0.hasPrefix("PROXY TCP4 203.0.113.9 0.0.0.0 51234 443\r\nGET /api/ping") }
        }
        #expect(sawProxyHeader)
        #expect(connResets.withLock { $0[99] } == OpenTunnelBridgeErrorCode.unknownRoute)

        await connection.close()
        try await connection.closed
    }
}
