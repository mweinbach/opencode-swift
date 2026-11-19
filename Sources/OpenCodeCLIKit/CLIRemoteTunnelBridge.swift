import Foundation
import Synchronization
import OpenCodePlatform
import OpenCodeUtil
import OpenTunnelClient

// MARK: - OpenTunnelClient Bridge for `CLIServices.RemoteTunnel`

extension CLIServices.RemoteTunnel {
    /// Retry and timeout constants matching upstream `packages/cli/src/services/remote-tunnel.ts`.
    public enum Policy {
        public static let defaultInitialRetryDelay: Duration = .seconds(1)
        public static let defaultMaxRetryDelay: Duration = .seconds(30)
        public static let defaultEnsureTimeout: Duration = .seconds(300)
        public static let ensureTimeoutMessage =
            "Timed out creating the remote access tunnel; run the command again to resume"
        public static let setupBanner =
            "Setting up remote access; this can take a minute..."
        public static let stoppedLogMessage =
            "remote access tunnel stopped; run `opencode service set remote true` to retry"
        public static let retryingLogMessage =
            "remote access tunnel unavailable; retrying"
    }

    /// Injectable runtime policy for `CLIServices.RemoteTunnel.runWithPolicy` (defaults match upstream).
    public struct RunPolicy: Sendable {
        public let initialRetryDelay: Duration
        public let maxRetryDelay: Duration
        public let sleep: @Sendable (Duration) async throws -> Void
        public let onWarning: (@Sendable (String, any Error) -> Void)?
        public let onError: (@Sendable (String, any Error) -> Void)?

        public init(
            initialRetryDelay: Duration = Policy.defaultInitialRetryDelay,
            maxRetryDelay: Duration = Policy.defaultMaxRetryDelay,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            },
            onWarning: (@Sendable (String, any Error) -> Void)? = nil,
            onError: (@Sendable (String, any Error) -> Void)? = nil
        ) {
            self.initialRetryDelay = initialRetryDelay
            self.maxRetryDelay = maxRetryDelay
            self.sleep = sleep
            self.onWarning = onWarning
            self.onError = onError
        }

        public static let `default` = RunPolicy()
    }

    /// Exact upstream fatal error classification from `packages/cli/src/services/remote-tunnel.ts`.
    /// Stops retrying immediately on `OpenTunnelAttachError`, certificate issuance failure,
    /// unsupported proxy scheme (e.g. `socks5://`), or invalid proxy URL.
    public static func isFatalTunnelError(_ error: any Error) -> Bool {
        if OpenTunnelError.isFatalError(error) {
            return true
        }
        let msg = CLIUtil.errorMessage(error)
        return msg.hasPrefix("Certificate issuance failed")
            || msg.contains("Certificate issuance failed:")
            || msg.contains("unsupported proxy scheme")
            || msg.contains("not a valid proxy URL")
    }

    /// Holds the route for the life of the service with exponential backoff (1s capped at 30s),
    /// stopping immediately on fatal errors and clearing `onURL(nil)` on every disconnect/exit.
    public static func runWithPolicy(
        input: RunInput,
        context: CLIContext = CLIContext.current,
        policy: RunPolicy = .default
    ) async {
        let backend = resolvedBackend(for: context)
        var delay = policy.initialRetryDelay
        defer { input.onURL(nil) }

        while !Task.isCancelled {
            do {
                let conn = try await backend.connect(route: input.route, target: input.target)
                delay = policy.initialRetryDelay
                input.onURL("https://\(input.route).\(conn.hostname)")
                do {
                    try await withTaskCancellationHandler {
                        try await conn.waitForClose()
                    } onCancel: {
                        Task { await conn.close() }
                    }
                } catch {
                    await conn.close()
                    throw error
                }
                await conn.close()
                input.onURL(nil)
                return
            } catch is CancellationError {
                input.onURL(nil)
                return
            } catch {
                input.onURL(nil)
                if Task.isCancelled {
                    return
                }
                if isFatalTunnelError(error) {
                    policy.onError?(Policy.stoppedLogMessage, error)
                    return
                }
                policy.onWarning?(Policy.retryingLogMessage, error)
                let currentDelay = min(delay, policy.maxRetryDelay)
                do {
                    try await policy.sleep(currentDelay)
                } catch {
                    return
                }
                delay = min(currentDelay * 2, policy.maxRetryDelay)
            }
        }
    }

    /// Ensures the shared device tunnel exists, emitting the setup notice if provisioning is needed
    /// and enforcing the upstream 5-minute timeout.
    public static func ensureWithTimeout(
        context: CLIContext = CLIContext.current,
        timeout: Duration = Policy.defaultEnsureTimeout
    ) async throws -> String {
        let backend = resolvedBackend(for: context)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                if try await backend.getTunnelHostname() == nil {
                    context.io.writeStderr("\(Policy.setupBanner)\(context.io.eol)")
                }
                return try await backend.ensureTunnel()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CLIError(Policy.ensureTimeoutMessage)
            }
            guard let hostname = try await group.next() else {
                throw CLIError(Policy.ensureTimeoutMessage)
            }
            group.cancelAll()
            return hostname
        }
    }

    /// Production `CLIServices.RemoteTunnel.Backend` wired directly to `Packages/OpenTunnel`'s `OpenTunnelClient`.
    public final class OpenTunnelClientBackend: Backend, Sendable {
        private let client: OpenTunnelClient?
        private let initError: OpenTunnelClientError?
        private let storage: any OpenTunnelStorage
        private let profile: String

        public init(
            client: OpenTunnelClient,
            profile: String = OpenTunnelClientModule.defaultProfile
        ) {
            self.client = client
            self.initError = nil
            self.storage = client.options.storage
            self.profile = profile
        }

        private init(
            client: OpenTunnelClient?,
            initError: OpenTunnelClientError?,
            storage: any OpenTunnelStorage,
            profile: String
        ) {
            self.client = client
            self.initError = initError
            self.storage = storage
            self.profile = profile
        }

        /// Builds a live `OpenTunnelClientBackend` configured from a `CLIContext` (respecting environment
        /// overrides, XDG paths, `OPENTUNNEL_API`, `HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY`, and virtual
        /// `OpenCodeFileSystem` / `HTTPTransport` when injected in tests).
        public static func make(
            context: CLIContext,
            profile: String = OpenTunnelClientModule.defaultProfile,
            timing: OpenTunnelTimingConfiguration = .default
        ) -> OpenTunnelClientBackend {
            let env = collectEnvironment(from: context)
            let storagePlatform: OpenTunnelStoragePlatform = context.platformOS == .windows ? .windows : .posix
            let storage: any OpenTunnelStorage
            if context.fileSystem is LocalFileSystem {
                storage = OpenTunnelXDGStorage.xdg(
                    environment: env,
                    homeDirectory: context.environment.homeDirectory,
                    platform: storagePlatform
                )
            } else {
                storage = CLIFileSystemTunnelStorage(
                    fileSystem: context.fileSystem,
                    environment: env,
                    homeDirectory: context.environment.homeDirectory,
                    platform: storagePlatform
                )
            }

            let transport: any OpenTunnelTransport
            if context.transport is URLSessionHTTPTransport {
                transport = LiveOpenTunnelTransport.shared
            } else {
                transport = CLIHTTPBridgeOpenTunnelTransport(
                    httpTransport: context.transport,
                    fallback: LiveOpenTunnelTransport.shared
                )
            }

            let options = OpenTunnelClientOptions(
                storage: storage,
                transport: transport,
                environment: env,
                timing: timing
            )
            do {
                let client = try OpenTunnelClient(options: options)
                return OpenTunnelClientBackend(client: client, initError: nil, storage: storage, profile: profile)
            } catch {
                return OpenTunnelClientBackend(client: nil, initError: error, storage: storage, profile: profile)
            }
        }

        public func getTunnelHostname() async throws -> String? {
            let activeClient = try requireClient()
            return try await activeClient.tunnel.get(profile: profile)?.hostname
        }

        public func ensureTunnel() async throws -> String {
            let activeClient = try requireClient()
            return try await activeClient.tunnel.ensure(profile: profile).hostname
        }

        public func connect(route: String, target: String) async throws -> Connection {
            let activeClient = try requireClient()
            let conn = try await activeClient.tunnel.connect(
                routes: [route: target],
                profile: profile
            )
            return Connection(
                hostname: conn.tunnel.hostname,
                waitForClose: {
                    try await conn.closed
                },
                close: {
                    await conn.close()
                }
            )
        }

        public func loadStoredHostname() async -> String? {
            try? await storage.load(profile: profile)?.hostname
        }

        private func requireClient() throws -> OpenTunnelClient {
            if let client { return client }
            throw initError ?? OpenTunnelClientError(message: "Failed to initialize OpenTunnelClient")
        }

        private static func collectEnvironment(from context: CLIContext) -> [String: String] {
            var env: [String: String]
            if let dictEnv = context.environment as? DictionaryEnvironment {
                env = dictEnv.variables
            } else {
                env = [:]
            }
            let keys = [
                "OPENTUNNEL_API",
                "OPENTUNNEL_PROFILE",
                "HTTPS_PROXY", "https_proxy",
                "HTTP_PROXY", "http_proxy",
                "ALL_PROXY", "all_proxy",
                "NO_PROXY", "no_proxy",
                "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                "APPDATA", "LOCALAPPDATA", "HOME", "USERPROFILE",
            ]
            for key in keys {
                if let val = context.envVariable(key) {
                    env[key] = val
                }
            }
            return env
        }
    }
}

// MARK: - OpenCodeFileSystem -> OpenTunnelStorage Adapter

/// Adapts `OpenCodePlatform.OpenCodeFileSystem` (such as `InMemoryFileSystem` in CLI tests)
/// to `OpenTunnelClient.OpenTunnelStorage` using the exact same XDG directory layout and 0600 permissions.
internal final class CLIFileSystemTunnelStorage: OpenTunnelStorage, Sendable {
    private let fileSystem: any OpenCodeFileSystem
    private let primaryRoot: String
    private let fallbackRoots: [String]

    init(
        fileSystem: any OpenCodeFileSystem,
        environment: [String: String],
        homeDirectory: String?,
        platform: OpenTunnelStoragePlatform
    ) {
        self.fileSystem = fileSystem
        self.primaryRoot = OpenTunnelXDGPaths.primaryRoot(
            environment: environment,
            homeDirectory: homeDirectory,
            platform: platform
        )
        self.fallbackRoots = OpenTunnelXDGPaths.fallbackReadRoots(
            environment: environment,
            homeDirectory: homeDirectory,
            platform: platform
        )
    }

    func profiles() async throws -> [String] {
        var found: Set<String> = []
        for root in [primaryRoot] + fallbackRoots {
            guard let entries = try? await fileSystem.readDirectory(at: root) else { continue }
            for entry in entries where OpenTunnelNames.isValidProfileName(entry) {
                let candidate = CLIPath.join(root, entry, "tunnel.json")
                let pending = CLIPath.join(root, entry, "pending.json")
                let hasTunnel = await fileSystem.exists(at: candidate)
                let hasPending = hasTunnel ? false : await fileSystem.exists(at: pending)
                if hasTunnel || hasPending {
                    found.insert(entry)
                }
            }
        }
        return found.sorted()
    }

    func load(profile: String) async throws -> OpenTunnelIdentity? {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
        for root in [primaryRoot] + fallbackRoots {
            let dir = CLIPath.join(root, profile)
            if let metaBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "tunnel.json")) {
                guard let tokenBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "token")),
                      let keyBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "private-key.pem")),
                      let certBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "certificate.pem")),
                      let chainBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "chain.pem"))
                else {
                    throw OpenTunnelStorageError(message: "Incomplete tunnel identity for \(profile)")
                }
                let record = try JSONDecoder().decode(OpenTunnelMetadataRecord.self, from: Data(metaBytes))
                return OpenTunnelIdentity(
                    id: record.id,
                    hostname: record.hostname,
                    token: String(decoding: tokenBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    privateKey: String(decoding: keyBytes, as: UTF8.self),
                    certificate: String(decoding: certBytes, as: UTF8.self),
                    chain: String(decoding: chainBytes, as: UTF8.self),
                    certificateExpiry: record.certificateExpiry
                )
            }
            // Legacy single-file fallback (`<root>/<profile>.json`)
            let singleFile = CLIPath.join(root, "\(profile).json")
            if let bytes = try? await fileSystem.readFile(at: singleFile) {
                if let decoded = try? JSONDecoder().decode(OpenTunnelIdentity.self, from: Data(bytes)),
                   !decoded.hostname.isEmpty
                {
                    return decoded
                }
                struct MinimalHost: Decodable { let hostname: String; let id: String? }
                if let minimal = try? JSONDecoder().decode(MinimalHost.self, from: Data(bytes)),
                   !minimal.hostname.isEmpty
                {
                    return OpenTunnelIdentity(
                        id: minimal.id ?? profile,
                        hostname: minimal.hostname,
                        token: "",
                        privateKey: "",
                        certificate: "",
                        chain: "",
                        certificateExpiry: "2099-01-01T00:00:00.000Z"
                    )
                }
            }
        }
        return nil
    }

    func save(profile: String, identity: OpenTunnelIdentity) async throws {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
        let dir = CLIPath.join(primaryRoot, profile)
        try await fileSystem.makeDirectory(at: dir, recursive: true)
        try? await fileSystem.chmod(at: dir, mode: 0o700)

        let record = OpenTunnelMetadataRecord(
            id: identity.id,
            hostname: identity.hostname,
            certificateExpiry: identity.certificateExpiry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var metaData = try encoder.encode(record)
        metaData.append(0x0A)

        try await writePrivateFile(Array(metaData), to: CLIPath.join(dir, "tunnel.json"))
        try await writePrivateFile(Array("\(identity.token)\n".utf8), to: CLIPath.join(dir, "token"))
        try await writePrivateFile(Array(identity.privateKey.utf8), to: CLIPath.join(dir, "private-key.pem"))
        try await writePrivateFile(Array(identity.certificate.utf8), to: CLIPath.join(dir, "certificate.pem"))
        try await writePrivateFile(Array(identity.chain.utf8), to: CLIPath.join(dir, "chain.pem"))
        try? await fileSystem.remove(at: CLIPath.join(dir, "pending.json"))
    }

    func loadPending(profile: String) async throws -> OpenTunnelPendingIdentity? {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
        for root in [primaryRoot] + fallbackRoots {
            let dir = CLIPath.join(root, profile)
            guard let metaBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "pending.json")) else {
                continue
            }
            guard let tokenBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "token")),
                  let keyBytes = try? await fileSystem.readFile(at: CLIPath.join(dir, "private-key.pem"))
            else {
                throw OpenTunnelStorageError(message: "Incomplete pending tunnel identity for \(profile)")
            }
            let record = try JSONDecoder().decode(OpenTunnelPendingMetadataRecord.self, from: Data(metaBytes))
            return OpenTunnelPendingIdentity(
                id: record.id,
                hostname: record.hostname,
                token: String(decoding: tokenBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                privateKey: String(decoding: keyBytes, as: UTF8.self),
                csr: record.csr
            )
        }
        return nil
    }

    func savePending(profile: String, pending: OpenTunnelPendingIdentity) async throws {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
        let dir = CLIPath.join(primaryRoot, profile)
        try await fileSystem.makeDirectory(at: dir, recursive: true)
        try? await fileSystem.chmod(at: dir, mode: 0o700)

        let record = OpenTunnelPendingMetadataRecord(
            id: pending.id,
            hostname: pending.hostname,
            csr: pending.csr
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var metaData = try encoder.encode(record)
        metaData.append(0x0A)

        try await writePrivateFile(Array(metaData), to: CLIPath.join(dir, "pending.json"))
        try await writePrivateFile(Array("\(pending.token)\n".utf8), to: CLIPath.join(dir, "token"))
        try await writePrivateFile(Array(pending.privateKey.utf8), to: CLIPath.join(dir, "private-key.pem"))
    }

    func remove(profile: String) async throws {
        guard OpenTunnelNames.isValidProfileName(profile) else {
            throw OpenTunnelStorageError(message: "Invalid profile name '\(profile)'")
        }
        let dir = CLIPath.join(primaryRoot, profile)
        for name in ["tunnel.json", "pending.json", "token", "private-key.pem", "certificate.pem", "chain.pem"] {
            try? await fileSystem.remove(at: CLIPath.join(dir, name))
        }
        try? await fileSystem.remove(at: dir)
    }

    func list() async throws -> [OpenTunnelStoredTunnel] {
        var result: [OpenTunnelStoredTunnel] = []
        for name in try await profiles() {
            if let identity = try await load(profile: name) {
                result.append(OpenTunnelStoredTunnel(profile: name, tunnel: identity))
            }
        }
        return result
    }

    private func writePrivateFile(_ bytes: [UInt8], to path: String) async throws {
        let temp = "\(path).\(CLIPath.randomHex(bytes: 4)).tmp"
        try await fileSystem.writeFile(bytes, to: temp, createDirectories: true)
        try? await fileSystem.chmod(at: temp, mode: 0o600)
        try await fileSystem.rename(from: temp, to: path)
    }
}

// MARK: - OpenCodePlatform.HTTPTransport -> OpenTunnelTransport Adapter

/// Bridges an injected `OpenCodePlatform.HTTPTransport` into `OpenTunnelTransport` for HTTP API calls,
/// delegating WebSocket and local TCP forwarding to `fallback`.
internal final class CLIHTTPBridgeOpenTunnelTransport: OpenTunnelTransport, Sendable {
    private let httpTransport: any HTTPTransport
    private let fallback: any OpenTunnelTransport

    init(httpTransport: any HTTPTransport, fallback: any OpenTunnelTransport = LiveOpenTunnelTransport.shared) {
        self.httpTransport = httpTransport
        self.fallback = fallback
    }

    func sendHTTP(_ request: OpenTunnelHTTPRequest) async throws -> OpenTunnelHTTPResponse {
        let bridged = HTTPRequest(
            method: request.method,
            url: request.url,
            headers: request.headers,
            body: request.body
        )
        do {
            let response = try await httpTransport.send(bridged)
            return OpenTunnelHTTPResponse(
                statusCode: response.head.statusCode,
                headers: response.head.headers,
                body: response.body
            )
        } catch let err as OpenTunnelClientError {
            throw err
        } catch {
            throw OpenTunnelClientError.transient(CLIUtil.errorMessage(error), cause: error)
        }
    }

    func openWebSocket(
        url: String,
        protocols: [String],
        headers: [String: String],
        proxy: OpenTunnelProxyConfig?
    ) async throws -> any OpenTunnelWebSocket {
        try await fallback.openWebSocket(url: url, protocols: protocols, headers: headers, proxy: proxy)
    }

    func openLocalConnection(target: OpenTunnelTarget) async throws -> any OpenTunnelByteStream {
        try await fallback.openLocalConnection(target: target)
    }
}
