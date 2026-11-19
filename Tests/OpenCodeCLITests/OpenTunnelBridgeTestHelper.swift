import Foundation
import Synchronization
import OpenCodeCLIKit
import OpenCodePlatform
import OpenTunnelClient

/// Foundation-using fixtures and mock transports for `OpenTunnelBridgeTests`.
/// Kept separate from files importing `Testing` (macOS CLT cross-import rule).
enum OpenTunnelBridgeTestHelper {
    static let fastTiming = OpenTunnelTimingConfiguration(
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

    static func makeTempDirectory(prefix: String = "opencode-tunnel-bridge") throws -> String {
        let base = FileManager.default.temporaryDirectory.path
        let path = (base as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func removePath(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func encodeJSONBytes<T: Encodable>(_ value: T) -> [UInt8] {
        (try? Array(JSONEncoder().encode(value))) ?? Array("{}".utf8)
    }

    static func encodeJSONString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func extractAttachRoutes(from text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "attach"
        else { return nil }
        return obj["routes"] as? [String]
    }

    static func sampleIdentity(
        id: String = "dev000111222",
        hostname: String = "dev000111222.opentunnel.xyz",
        token: String = "tok-bridge-cli"
    ) -> OpenTunnelIdentity {
        OpenTunnelIdentity(
            id: id,
            hostname: hostname,
            token: token,
            privateKey: "-----BEGIN PRIVATE KEY-----\nCLIKEY\n-----END PRIVATE KEY-----\n",
            certificate: "-----BEGIN CERTIFICATE-----\nCLICERT\n-----END CERTIFICATE-----\n",
            chain: "-----BEGIN CERTIFICATE-----\nCLICHAIN\n-----END CERTIFICATE-----\n",
            certificateExpiry: "2099-01-01T00:00:00.000Z"
        )
    }

    /// Files map pre-populating an XDG `opentunnel/default` profile inside `InMemoryFileSystem`.
    static func storedIdentityFiles(
        configRoot: String = "/home/tester/.config",
        identity: OpenTunnelIdentity = sampleIdentity()
    ) -> [String: String] {
        let dir = "\(configRoot)/opentunnel/default"
        let meta = encodeJSONString(
            OpenTunnelMetadataRecord(
                id: identity.id,
                hostname: identity.hostname,
                certificateExpiry: identity.certificateExpiry
            )
        )
        return [
            "\(dir)/tunnel.json": meta + "\n",
            "\(dir)/token": identity.token + "\n",
            "\(dir)/private-key.pem": identity.privateKey,
            "\(dir)/certificate.pem": identity.certificate,
            "\(dir)/chain.pem": identity.chain,
        ]
    }

    /// Builds a `CLIContext` backed by real `LocalFileSystem.shared` rooted in an isolated temp directory.
    static func makeDiskContext(
        tempRoot: String,
        env: [String: String] = [:],
        transport: (any HTTPTransport)? = nil,
        remoteTunnelBackend: (any CLIServices.RemoteTunnel.Backend)? = nil
    ) -> (context: CLIContext, output: CLIBufferedOutput) {
        let output = CLIBufferedOutput()
        let io = CLIIO.buffered(output: output)
        var fullEnv = env
        fullEnv["XDG_CONFIG_HOME"] = fullEnv["XDG_CONFIG_HOME"] ?? "\(tempRoot)/config"
        fullEnv["XDG_DATA_HOME"] = fullEnv["XDG_DATA_HOME"] ?? "\(tempRoot)/data"
        fullEnv["XDG_STATE_HOME"] = fullEnv["XDG_STATE_HOME"] ?? "\(tempRoot)/state"
        fullEnv["XDG_CACHE_HOME"] = fullEnv["XDG_CACHE_HOME"] ?? "\(tempRoot)/cache"
        let environment = DictionaryEnvironment(
            variables: fullEnv,
            homeDirectory: tempRoot,
            temporaryDirectory: "\(tempRoot)/tmp"
        )
        let ctx = CLIContext(
            io: io,
            environment: environment,
            fileSystem: LocalFileSystem.shared,
            transport: transport ?? MockCLIHTTPTransport { req in
                HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: Array("unhandled \(req.url)".utf8))
            },
            spawner: MockCLIProcessSpawner { _ in ProcessOutput(exitCode: 0, stdout: [], stderr: []) },
            launcher: MockServiceLauncher(),
            signaler: MockServiceSignaler(),
            cwd: tempRoot,
            executablePath: "/usr/local/bin/opencode",
            version: "2.1.0",
            channel: "latest",
            platformOS: .macOS,
            remoteTunnelBackend: remoteTunnelBackend
        )
        return (ctx, output)
    }

    /// Creates a mock `OpenTunnelTransport` that serves tunnel provisioning REST calls and WebSocket attach.
    static func makeBridgeTransport(
        tunnelID: String = "cli123456789",
        hostname: String = "cli123456789.opentunnel.xyz",
        token: String = "tok-live-cli",
        onAttach: (@Sendable ([String], InMemoryOpenTunnelWebSocket) async -> Void)? = nil
    ) -> CLIBridgeMockOpenTunnelTransport {
        CLIBridgeMockOpenTunnelTransport(
            http: { req in
                if req.method == "POST" && req.url.hasSuffix("/api/tunnel") {
                    return OpenTunnelHTTPResponse(
                        statusCode: 201,
                        body: encodeJSONBytes(
                            OpenTunnelCreateResponse(
                                tunnel: OpenTunnelInfo(id: tunnelID, hostname: hostname, state: .offline),
                                token: token
                            )
                        )
                    )
                }
                if req.method == "POST" && req.url.hasSuffix("/certificate") {
                    return OpenTunnelHTTPResponse(
                        statusCode: 202,
                        body: encodeJSONBytes(OpenTunnelCertificateInfo(id: "cert-cli", state: .issuing))
                    )
                }
                if req.method == "GET" && req.url.hasSuffix("/certificate") {
                    return OpenTunnelHTTPResponse(
                        statusCode: 200,
                        body: encodeJSONBytes(
                            OpenTunnelCertificateInfo(
                                id: "cert-cli",
                                state: .ready(certificate: "CERT-CLI", chain: "CHAIN-CLI", expiry: "2099-01-01T00:00:00.000Z")
                            )
                        )
                    )
                }
                return OpenTunnelHTTPResponse(statusCode: 404)
            },
            ws: { _, _, _, _ in
                let (clientWS, serverWS) = InMemoryOpenTunnelWebSocket.makePair()
                Task {
                    for try await frame in serverWS.incoming {
                        if case .text(let text) = frame,
                           let routes = extractAttachRoutes(from: text)
                        {
                            if let onAttach {
                                await onAttach(routes, serverWS)
                            } else {
                                let routesJSON = encodeJSONString(routes)
                                try? await serverWS.send(.text(
                                    "{\"type\":\"attached\",\"session\":\"cli-sess-1\",\"routes\":\(routesJSON),\"heartbeat_ms\":15000,\"idle_timeout_ms\":45000}"
                                ))
                            }
                            break
                        }
                    }
                }
                return clientWS
            }
        )
    }
}

final class CLIBridgeMockOpenTunnelTransport: OpenTunnelTransport, Sendable {
    private let httpHandler: @Sendable (OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse
    private let wsHandler: @Sendable (String, [String], [String: String], OpenTunnelProxyConfig?) async throws -> any OpenTunnelWebSocket

    init(
        http: @escaping @Sendable (OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse,
        ws: @escaping @Sendable (String, [String], [String: String], OpenTunnelProxyConfig?) async throws -> any OpenTunnelWebSocket
    ) {
        self.httpHandler = http
        self.wsHandler = ws
    }

    func sendHTTP(_ request: OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse {
        try await httpHandler(request)
    }

    func openWebSocket(
        url: String,
        protocols: [String],
        headers: [String: String],
        proxy: OpenTunnelProxyConfig?
    ) async throws -> any OpenTunnelWebSocket {
        try await wsHandler(url, protocols, headers, proxy)
    }

    func openLocalConnection(target: OpenTunnelTarget) async throws -> any OpenTunnelByteStream {
        let (client, _) = InMemoryOpenTunnelByteStream.makePair()
        _ = target
        return client
    }
}

/// Programmable `CLIServices.RemoteTunnel.Backend` for testing retry backoff, cancellation, and timeout rules.
final class ScriptedRemoteTunnelBackend: CLIServices.RemoteTunnel.Backend, Sendable {
    private let getHandler: @Sendable () async throws -> String?
    private let ensureHandler: @Sendable () async throws -> String
    private let connectHandler: @Sendable (String, String) async throws -> CLIServices.RemoteTunnel.Connection
    private let storedHandler: @Sendable () async -> String?

    init(
        get: @escaping @Sendable () async throws -> String? = { nil },
        ensure: @escaping @Sendable () async throws -> String = { "scripted.opentunnel.xyz" },
        connect: @escaping @Sendable (String, String) async throws -> CLIServices.RemoteTunnel.Connection = { _, _ in
            CLIServices.RemoteTunnel.Connection(hostname: "scripted.opentunnel.xyz")
        },
        stored: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.getHandler = get
        self.ensureHandler = ensure
        self.connectHandler = connect
        self.storedHandler = stored
    }

    func getTunnelHostname() async throws -> String? { try await getHandler() }
    func ensureTunnel() async throws -> String { try await ensureHandler() }
    func connect(route: String, target: String) async throws -> CLIServices.RemoteTunnel.Connection {
        try await connectHandler(route, target)
    }
    func loadStoredHostname() async -> String? { await storedHandler() }
}
