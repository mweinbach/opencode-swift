import Foundation
import Synchronization

/// Configuration options for `OpenTunnelClient`.
public struct OpenTunnelClientOptions: Sendable {
    /// OpenTunnel control API base URL (defaults to `$OPENTUNNEL_API`, then `https://opentunnel.xyz`).
    public let apiURL: String
    /// Profile identity storage backend (defaults to `OpenTunnelXDGStorage.xdg(...)`).
    public let storage: any OpenTunnelStorage
    /// HTTP/WebSocket/TCP transport backend (defaults to `LiveOpenTunnelTransport.shared`).
    public let transport: any OpenTunnelTransport
    /// Cryptographic key & PKCS#10 CSR generator (defaults to `DefaultOpenTunnelKeyProvider.shared`).
    public let keyProvider: any OpenTunnelKeyProvider
    /// Optional server-side TLS terminator for incoming encrypted bridge channels.
    public let tlsAdapter: (any OpenTunnelTLSAdapter)?
    /// Optional explicit `http://` or `https://` proxy URL overriding environment proxy variables.
    public let proxy: String?
    /// Process environment map used for `OPENTUNNEL_API` and `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY`.
    public let environment: [String: String]
    /// Protocol timing & backpressure configuration.
    public let timing: OpenTunnelTimingConfiguration

    public init(
        apiURL: String? = nil,
        storage: (any OpenTunnelStorage)? = nil,
        transport: any OpenTunnelTransport = LiveOpenTunnelTransport.shared,
        keyProvider: any OpenTunnelKeyProvider = DefaultOpenTunnelKeyProvider.shared,
        tlsAdapter: (any OpenTunnelTLSAdapter)? = nil,
        proxy: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timing: OpenTunnelTimingConfiguration = .default
    ) {
        let envAPI = environment["OPENTUNNEL_API"]?.trimmingASCIIWhitespace()
        self.apiURL = apiURL ?? ((envAPI?.isEmpty == false) ? envAPI! : OpenTunnelClientModule.defaultAPIURL)
        self.storage = storage ?? OpenTunnelXDGStorage.xdg(environment: environment)
        self.transport = transport
        self.keyProvider = keyProvider
        self.tlsAdapter = tlsAdapter
        self.proxy = proxy
        self.environment = environment
        self.timing = timing
    }
}

/// Active connected tunnel handle returned by `OpenTunnelClient.tunnel.connect(...)`.
public final class OpenTunnelConnection: Sendable {
    /// Identity of the connected tunnel (use `connection.tunnel.hostname`).
    public var tunnel: OpenTunnelIdentity {
        running.currentIdentity
    }

    /// Stream of lifecycle and connection events until the tunnel stops.
    public let events: AsyncStream<OpenTunnelClientEvent>

    /// Current connection status snapshot.
    public var status: OpenTunnelStatus {
        running.getStatus()
    }

    /// Public HTTPS URL for each currently claimed route (`https://<route>.<hostname>` or `https://<hostname>` for `@`).
    public var urls: [String: String] {
        running.getURLs()
    }

    /// Completes when the tunnel closes gracefully, or throws when it stops with a fatal error.
    public var closed: Void {
        get async throws {
            try await running.waitClosed()
        }
    }

    private let running: OpenTunnelRunningTunnel

    internal init(running: OpenTunnelRunningTunnel, events: AsyncStream<OpenTunnelClientEvent>) {
        self.running = running
        self.events = events
    }

    /// Replaces the tunnel's routes. Target-only changes apply immediately; route name changes re-attach.
    public func setRoutes(_ routes: [String: OpenTunnelRoute]) async throws {
        try running.setRoutes(routes)
    }

    /// Replaces the tunnel's routes using `host:port` target strings.
    public func setRoutes(_ routes: [String: String]) async throws {
        try running.setRoutes(routes.mapValues { OpenTunnelRoute(target: $0) })
    }

    /// Awaits tunnel shutdown or throws on fatal bridge error.
    public func waitUntilClosed() async throws {
        try await running.waitClosed()
    }

    /// Gracefully shuts down the tunnel, closing active proxied connections and the bridge WebSocket.
    public func close() async {
        await running.close()
    }
}

/// Cross-platform Swift 6.2 port of `@opentunnel/client` (`OpenTunnelClient`).
public final class OpenTunnelClient: Sendable {
    public let options: OpenTunnelClientOptions
    public let profile: ProfileService
    public let tunnel: TunnelService

    public init(options: OpenTunnelClientOptions = OpenTunnelClientOptions()) throws(OpenTunnelClientError) {
        // Validate explicit proxy upfront, matching `@opentunnel/client`'s `OpenTunnelClient.layer({ proxy })`.
        if let proxy = options.proxy {
            _ = try OpenTunnelProxyResolver.parseProxy(proxy, source: "The proxy option")
        }
        self.options = options
        self.profile = ProfileService(storage: options.storage)
        self.tunnel = TunnelService(options: options)
    }

    /// Convenience initializer mirroring `@opentunnel/client`'s `create(...)`.
    public convenience init(
        apiURL: String? = nil,
        storage: (any OpenTunnelStorage)? = nil,
        transport: any OpenTunnelTransport = LiveOpenTunnelTransport.shared,
        keyProvider: any OpenTunnelKeyProvider = DefaultOpenTunnelKeyProvider.shared,
        tlsAdapter: (any OpenTunnelTLSAdapter)? = nil,
        proxy: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timing: OpenTunnelTimingConfiguration = .default
    ) throws(OpenTunnelClientError) {
        try self.init(
            options: OpenTunnelClientOptions(
                apiURL: apiURL,
                storage: storage,
                transport: transport,
                keyProvider: keyProvider,
                tlsAdapter: tlsAdapter,
                proxy: proxy,
                environment: environment,
                timing: timing
            )
        )
    }

    // MARK: - Profile Service

    public struct ProfileService: Sendable {
        private let storage: any OpenTunnelStorage

        internal init(storage: any OpenTunnelStorage) {
            self.storage = storage
        }

        public func list() async throws -> [String] {
            try await storage.profiles()
        }
    }

    // MARK: - Tunnel Service

    public struct TunnelService: Sendable {
        private let options: OpenTunnelClientOptions

        internal init(options: OpenTunnelClientOptions) {
            self.options = options
        }

        public func list() async throws -> [OpenTunnelStoredTunnel] {
            try await options.storage.list()
        }

        public func get(profile: String = OpenTunnelClientModule.defaultProfile) async throws -> OpenTunnelIdentity? {
            try await options.storage.load(profile: profile)
        }

        public func pending(profile: String = OpenTunnelClientModule.defaultProfile) async throws -> OpenTunnelPendingTunnelSummary? {
            guard let pending = try await options.storage.loadPending(profile: profile) else { return nil }
            return OpenTunnelPendingTunnelSummary(id: pending.id, hostname: pending.hostname)
        }

        public func resume(
            profile: String = OpenTunnelClientModule.defaultProfile,
            onProgress: (@Sendable (OpenTunnelProvisionStage) -> Void)? = nil
        ) async throws -> OpenTunnelIdentity? {
            guard let pending = try await options.storage.loadPending(profile: profile) else {
                return nil
            }
            onProgress?(.resumingCertificate)
            return try await completePending(profile: profile, pending: pending, onProgress: onProgress)
        }

        public func create(
            profile: String = OpenTunnelClientModule.defaultProfile,
            onProgress: (@Sendable (OpenTunnelProvisionStage) -> Void)? = nil
        ) async throws -> OpenTunnelIdentity {
            if try await options.storage.load(profile: profile) != nil {
                throw OpenTunnelClientError(message: "Profile '\(profile)' already has a tunnel")
            }
            if let existingPending = try await options.storage.loadPending(profile: profile) {
                onProgress?(.resumingCertificate)
                return try await completePending(profile: profile, pending: existingPending, onProgress: onProgress)
            }

            onProgress?(.creatingTunnel)
            let created: OpenTunnelCreateResponse = try await sendAPI(
                method: "POST",
                path: "/api/tunnel",
                token: nil,
                body: Array("{}".utf8),
                repeatPolicy: .once,
                errorPrefix: "Failed to create tunnel"
            )
            return try await provision(
                profile: profile,
                id: created.tunnel.id,
                hostname: created.tunnel.hostname,
                token: created.token,
                onProgress: onProgress
            )
        }

        /// Returns the profile's existing tunnel (checking for certificate renewal or re-provisioning
        /// if the server reports certificate failure), or creates/resumes a new tunnel if none exists.
        public func ensure(
            profile: String = OpenTunnelClientModule.defaultProfile,
            onProgress: (@Sendable (OpenTunnelProvisionStage) -> Void)? = nil
        ) async throws -> OpenTunnelIdentity {
            guard let existing = try await get(profile: profile) else {
                return try await create(profile: profile, onProgress: onProgress)
            }

            onProgress?(.checkingCertificate)
            let certInfo: OpenTunnelCertificateInfo?
            do {
                certInfo = try await sendAPI(
                    method: "GET",
                    path: "/api/tunnel/\(percentEncodePath(existing.id))/certificate",
                    token: existing.token,
                    body: nil,
                    repeatPolicy: .idempotent,
                    errorPrefix: "Failed to read certificate"
                )
            } catch let clientError as OpenTunnelClientError {
                // Keep using a non-expired saved certificate when the API is transiently unreachable.
                if clientError.isTransient && !existing.isCertificateExpired() {
                    certInfo = nil
                } else {
                    throw clientError
                }
            }

            guard let certInfo else {
                onProgress?(.ready)
                return existing
            }

            switch certInfo.state {
            case let .ready(certificate, chain, expiry):
                if !certificate.isEmpty && certificate != existing.certificate {
                    let renewed = existing.withRenewedCertificate(
                        certificate: certificate,
                        chain: chain,
                        expiry: expiry
                    )
                    onProgress?(.savingIdentity)
                    try await options.storage.save(profile: profile, identity: renewed)
                    onProgress?(.ready)
                    return renewed
                }
                onProgress?(.ready)
                return existing

            case .challenge, .issuing:
                onProgress?(.ready)
                return existing

            case .failed:
                return try await provision(
                    profile: profile,
                    id: existing.id,
                    hostname: existing.hostname,
                    token: existing.token,
                    onProgress: onProgress
                )
            }
        }

        public func remove(profile: String = OpenTunnelClientModule.defaultProfile) async throws {
            guard let identity = try await options.storage.load(profile: profile) else {
                return
            }
            try await sendAPIVoid(
                method: "DELETE",
                path: "/api/tunnel/\(percentEncodePath(identity.id))",
                token: identity.token,
                body: nil,
                repeatPolicy: .once,
                errorPrefix: "Failed to remove tunnel"
            )
            try await options.storage.remove(profile: profile)
        }

        /// Ensures the device tunnel exists, opens the bridge WebSocket, claims `routes`,
        /// waits for the first `attached` handshake, and returns a live `OpenTunnelConnection`.
        public func connect(
            routes: [String: OpenTunnelRoute],
            profile: String = OpenTunnelClientModule.defaultProfile,
            onRouteConflict: OpenTunnelRouteConflictPolicy = .retry,
            onEvent: (@Sendable (OpenTunnelClientEvent) -> Void)? = nil
        ) async throws -> OpenTunnelConnection {
            let resolved = try OpenTunnelRouteValidation.validateRoutes(routes)
            // Eagerly validate proxy configuration for the bridge URL before provisioning/connecting.
            let probeWS = makeBridgeProbeURL(apiURL: options.apiURL)
            _ = try OpenTunnelProxyResolver.resolveProxy(
                for: probeWS,
                explicitProxy: options.proxy,
                environment: options.environment
            )

            let identity = try await ensure(profile: profile)

            var eventContStorage: AsyncStream<OpenTunnelClientEvent>.Continuation?
            let eventStream = AsyncStream<OpenTunnelClientEvent> { eventContStorage = $0 }
            let eventContinuation = eventContStorage!

            let storage = options.storage
            let running = OpenTunnelRunningTunnel(
                apiURL: options.apiURL,
                identity: identity,
                routes: routes,
                resolved: resolved,
                transport: options.transport,
                tlsAdapter: options.tlsAdapter,
                explicitProxy: options.proxy,
                environment: options.environment,
                timing: options.timing,
                onRouteConflict: onRouteConflict,
                onEvent: { event in
                    onEvent?(event)
                    eventContinuation.yield(event)
                    if case .stopped = event {
                        eventContinuation.finish()
                    }
                },
                onRenewed: { renewed in
                    try? await storage.save(profile: profile, identity: renewed)
                }
            )

            do {
                try await withTaskCancellationHandler {
                    try await running.waitReady()
                } onCancel: {
                    Task { await running.close() }
                }
            } catch {
                await running.close()
                eventContinuation.finish()
                throw error
            }

            return OpenTunnelConnection(running: running, events: eventStream)
        }

        /// Convenience overload accepting `[route: target]` string dictionary (e.g. `["abc123": "127.0.0.1:4096"]`).
        public func connect(
            routes: [String: String],
            profile: String = OpenTunnelClientModule.defaultProfile,
            onRouteConflict: OpenTunnelRouteConflictPolicy = .retry,
            onEvent: (@Sendable (OpenTunnelClientEvent) -> Void)? = nil
        ) async throws -> OpenTunnelConnection {
            try await connect(
                routes: routes.mapValues { OpenTunnelRoute(target: $0) },
                profile: profile,
                onRouteConflict: onRouteConflict,
                onEvent: onEvent
            )
        }

        // MARK: - Provisioning & API Helpers

        private func provision(
            profile: String,
            id: String,
            hostname: String,
            token: String,
            onProgress: (@Sendable (OpenTunnelProvisionStage) -> Void)?
        ) async throws -> OpenTunnelIdentity {
            onProgress?(.generatingKey)
            onProgress?(.generatingCSR)
            let keyAndCSR: OpenTunnelGeneratedKeyAndCSR
            do {
                keyAndCSR = try await options.keyProvider.generateKeyAndCSR(hostname: hostname)
            } catch let err as OpenTunnelClientError {
                throw err
            } catch {
                throw OpenTunnelClientError(message: "Failed to generate certificate request: \(error)", cause: error)
            }

            let pending = OpenTunnelPendingIdentity(
                id: id,
                hostname: hostname,
                token: token,
                privateKey: keyAndCSR.privateKeyPEM,
                csr: keyAndCSR.csrPEM
            )
            try await options.storage.savePending(profile: profile, pending: pending)
            return try await completePending(profile: profile, pending: pending, onProgress: onProgress)
        }

        private func completePending(
            profile: String,
            pending: OpenTunnelPendingIdentity,
            onProgress: (@Sendable (OpenTunnelProvisionStage) -> Void)?
        ) async throws -> OpenTunnelIdentity {
            onProgress?(.requestingCertificate)
            struct BindPayload: Encodable {
                let csr: String
            }
            let bindBody = try Array(JSONEncoder().encode(BindPayload(csr: pending.csr)))
            do {
                let _: OpenTunnelCertificateInfo = try await sendAPI(
                    method: "POST",
                    path: "/api/tunnel/\(percentEncodePath(pending.id))/certificate",
                    token: pending.token,
                    body: bindBody,
                    repeatPolicy: .idempotent,
                    errorPrefix: "Failed to start certificate issuance",
                    ignoreErrorTags: ["CertificateInProgressError"]
                )
            } catch let err as IgnoredAPIErrorTag {
                _ = err // Resumed provision already has issuance in flight.
            }

            while true {
                try Task.checkCancellation()
                onProgress?(.waitingCertificate)
                let certInfo: OpenTunnelCertificateInfo = try await sendAPI(
                    method: "GET",
                    path: "/api/tunnel/\(percentEncodePath(pending.id))/certificate",
                    token: pending.token,
                    body: nil,
                    repeatPolicy: .idempotent,
                    errorPrefix: "Failed to read certificate"
                )
                switch certInfo.state {
                case let .ready(certificate, chain, expiry):
                    let identity = OpenTunnelIdentity(
                        id: pending.id,
                        hostname: pending.hostname,
                        token: pending.token,
                        privateKey: pending.privateKey,
                        certificate: certificate,
                        chain: chain,
                        certificateExpiry: expiry
                    )
                    onProgress?(.savingIdentity)
                    try await options.storage.save(profile: profile, identity: identity)
                    onProgress?(.ready)
                    return identity

                case .failed(let reason):
                    throw OpenTunnelClientError.certificateIssuanceFailed(reason)

                case .challenge, .issuing:
                    try await Task.sleep(for: .milliseconds(max(options.timing.certificatePollIntervalMs, 1)))
                }
            }
        }

        private struct IgnoredAPIErrorTag: Error {}

        private func sendAPI<T: Decodable>(
            method: String,
            path: String,
            token: String?,
            body: [UInt8]?,
            repeatPolicy: OpenTunnelAPIRetry.RepeatPolicy,
            errorPrefix: String,
            ignoreErrorTags: Set<String> = []
        ) async throws -> T {
            let response = try await executeAPIRequest(
                method: method,
                path: path,
                token: token,
                body: body,
                repeatPolicy: repeatPolicy,
                errorPrefix: errorPrefix,
                ignoreErrorTags: ignoreErrorTags
            )
            do {
                return try JSONDecoder().decode(T.self, from: Data(response.body))
            } catch {
                throw OpenTunnelClientError(
                    message: "\(errorPrefix): invalid JSON response: \(error)",
                    cause: error
                )
            }
        }

        private func sendAPIVoid(
            method: String,
            path: String,
            token: String?,
            body: [UInt8]?,
            repeatPolicy: OpenTunnelAPIRetry.RepeatPolicy,
            errorPrefix: String
        ) async throws {
            _ = try await executeAPIRequest(
                method: method,
                path: path,
                token: token,
                body: body,
                repeatPolicy: repeatPolicy,
                errorPrefix: errorPrefix,
                ignoreErrorTags: []
            )
        }

        private func executeAPIRequest(
            method: String,
            path: String,
            token: String?,
            body: [UInt8]?,
            repeatPolicy: OpenTunnelAPIRetry.RepeatPolicy,
            errorPrefix: String,
            ignoreErrorTags: Set<String>
        ) async throws -> OpenTunnelHTTPResponse {
            let base = options.apiURL.hasSuffix("/") ? String(options.apiURL.dropLast()) : options.apiURL
            let url = "\(base)\(path)"
            let proxy = try OpenTunnelProxyResolver.resolveProxy(
                for: url,
                explicitProxy: options.proxy,
                environment: options.environment
            )

            var headers: [String: String] = [
                "user-agent": OpenTunnelClientModule.userAgent,
                "accept": "application/json",
            ]
            if let token {
                headers["authorization"] = "Bearer \(token)"
            }
            if body != nil {
                headers["content-type"] = "application/json"
            }

            let request = OpenTunnelHTTPRequest(
                method: method,
                url: url,
                headers: headers,
                body: body,
                proxy: proxy
            )

            let maxRetries = max(options.timing.apiMaxRetries, 0)
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    let response = try await options.transport.sendHTTP(request)
                    if (200..<300).contains(response.statusCode) {
                        return response
                    }

                    if let apiErr = try? JSONDecoder().decode(OpenTunnelAPIErrorBody.self, from: Data(response.body)),
                       let tag = apiErr.tag,
                       ignoreErrorTags.contains(tag)
                    {
                        throw IgnoredAPIErrorTag()
                    }

                    if attempt < maxRetries && OpenTunnelAPIRetry.retryableStatus(response.statusCode, repeatPolicy: repeatPolicy) {
                        let range = OpenTunnelAPIRetry.retryDelayMs(
                            attempt: attempt,
                            retryAfter: response.header("retry-after"),
                            baseMs: options.timing.apiRetryBaseMs,
                            maxMs: options.timing.apiRetryMaxMs
                        )
                        let delayMs = range.min >= range.max ? range.min : Int.random(in: range.min...range.max)
                        attempt += 1
                        if delayMs > 0 {
                            try await Task.sleep(for: .milliseconds(delayMs))
                        }
                        continue
                    }

                    throw classifyAPIError(response: response, prefix: errorPrefix)
                } catch let ignored as IgnoredAPIErrorTag {
                    throw ignored
                } catch is CancellationError {
                    throw CancellationError()
                } catch let clientErr as OpenTunnelClientError {
                    if clientErr.isFatal {
                        throw clientErr
                    }
                    if attempt < maxRetries && clientErr.isTransient {
                        let range = OpenTunnelAPIRetry.retryDelayMs(
                            attempt: attempt,
                            retryAfter: nil,
                            baseMs: options.timing.apiRetryBaseMs,
                            maxMs: options.timing.apiRetryMaxMs
                        )
                        let delayMs = range.min >= range.max ? range.min : Int.random(in: range.min...range.max)
                        attempt += 1
                        if delayMs > 0 {
                            try await Task.sleep(for: .milliseconds(delayMs))
                        }
                        continue
                    }
                    throw OpenTunnelClientError(
                        message: "\(errorPrefix): \(clientErr.message)",
                        code: clientErr.code,
                        attachError: clientErr.attachError,
                        cause: clientErr,
                        isTransient: clientErr.isTransient
                    )
                } catch {
                    if attempt < maxRetries {
                        let range = OpenTunnelAPIRetry.retryDelayMs(
                            attempt: attempt,
                            retryAfter: nil,
                            baseMs: options.timing.apiRetryBaseMs,
                            maxMs: options.timing.apiRetryMaxMs
                        )
                        let delayMs = range.min >= range.max ? range.min : Int.random(in: range.min...range.max)
                        attempt += 1
                        if delayMs > 0 {
                            try await Task.sleep(for: .milliseconds(delayMs))
                        }
                        continue
                    }
                    throw OpenTunnelClientError.transient("\(errorPrefix): \(error)", cause: error)
                }
            }
        }

        private func classifyAPIError(response: OpenTunnelHTTPResponse, prefix: String) -> OpenTunnelClientError {
            let transient = OpenTunnelAPIRetry.retryableStatus(response.statusCode, repeatPolicy: .idempotent)
            if let apiErr = try? JSONDecoder().decode(OpenTunnelAPIErrorBody.self, from: Data(response.body)),
               let tag = apiErr.tag,
               let message = apiErr.message
            {
                return OpenTunnelClientError(
                    message: "\(prefix): \(tag): \(message)",
                    isTransient: transient
                )
            }
            let statusDesc = OpenTunnelAPIRetry.statusMessage(status: response.statusCode, body: response.bodyString)
            return OpenTunnelClientError(
                message: "\(prefix): \(statusDesc)",
                isTransient: transient
            )
        }

        private func percentEncodePath(_ segment: String) -> String {
            segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
        }

        private func makeBridgeProbeURL(apiURL: String) -> String {
            if apiURL.hasPrefix("https://") {
                return "wss://" + apiURL.dropFirst("https://".count)
            }
            if apiURL.hasPrefix("http://") {
                return "ws://" + apiURL.dropFirst("http://".count)
            }
            return apiURL
        }
    }
}
