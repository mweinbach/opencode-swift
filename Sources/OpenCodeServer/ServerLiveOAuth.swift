#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Live Provider OAuth Engine (7 Real Upstream Provider Flows)

/// Provider OAuth constants, descriptors, PKCE/JWT helpers, and integration registration
/// matching upstream `packages/core/src/plugin/provider/{opencode,chatgpt,github-copilot,xai,poe,digitalocean,gitlab}.ts`.
public enum ServerLiveOAuth {
    // MARK: - Canonical Upstream Constants

    public static let openCodeClientID = "opencode-cli"
    public static let openCodeMethodID = IntegrationSchema.MethodID(rawValue: "device")

    public static let chatGPTRegistrationClientID = "dynamic_agent_client"
    public static let chatGPTAgentName = "OpenCode"
    public static let chatGPTIssuer = "https://auth.openai.com"
    public static let chatGPTAuthorizeURL = "https://auth.openai.com/api/accounts/authorize"
    public static let chatGPTTokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    public static let chatGPTLegacyTokenURL = "https://auth.openai.com/oauth/token"
    public static let chatGPTLegacyClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let chatGPTResource = "https://api.openai.com/v1"
    public static let chatGPTCodexModelsURL = "https://chatgpt.com/backend-api/codex/models"
    public static let chatGPTTokenSharingScope = "chatgpt.tokens.use.direct"
    public static let chatGPTMethodID = IntegrationSchema.MethodID(rawValue: "chatgpt-token-sharing")

    public static let copilotClientID = "Ov23li8tweQw6odWQebz"
    public static let copilotApiVersion = "2026-08-01"
    public static let copilotUserApiVersion = "2025-04-01"
    public static let copilotMethodID = IntegrationSchema.MethodID(rawValue: "device")

    public static let xaiClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let xaiIssuer = "https://auth.x.ai/oauth2"
    public static let xaiScope = "openid profile email offline_access grok-cli:access api:access"
    public static let xaiMethodID = IntegrationSchema.MethodID(rawValue: "browser")

    public static let poeClientID = "client_728290227fc048cc9262091a1ea197ea"
    public static let poeIssuer = "https://poe.com"
    public static let poeTokenURL = "https://api.poe.com/token"
    public static let poeMethodID = IntegrationSchema.MethodID(rawValue: "poe-browser")

    public static let digitalOceanClientID = "b1a6c5158156caac821fd1b30253ca8acb52454a48fa744420e41889cb589f82"
    public static let digitalOceanAuthorizeURL = "https://cloud.digitalocean.com/v1/oauth/authorize"
    public static let digitalOceanTokenURL = "https://cloud.digitalocean.com/v1/oauth/token"
    public static let digitalOceanCallbackPort = 1456
    public static let digitalOceanMethodID = IntegrationSchema.MethodID(rawValue: "digitalocean-oauth")

    public static let gitLabBundledClientID = "fd180700a8f9c5d5557aca231632dd0611a1135a3bb510a741d5a988a3394fa7"
    public static let gitLabLegacyClientID = "1d89f9fdb23ee96d4e603201f6861dab6e143c5c3c00469a018a2d94bdc03d4e"
    public static let gitLabCallbackPort = 8080
    public static let gitLabMethodID = IntegrationSchema.MethodID(rawValue: "gitlab-oauth")

    public static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    // MARK: - PKCE & URL / JWT Helpers

    public struct PKCEPair: Equatable, Sendable {
        public let verifier: String
        public let challenge: String
    }

    /// Generates an RFC 7636 S256 PKCE verifier/challenge pair using pure-Swift SHA-256.
    public static func generatePKCE(length: Int = 43) -> PKCEPair {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let random = ServerCrypto.randomBytes(max(length, 43))
        let verifier = String(random.map { alphabet[Int($0) % alphabet.count] })
        let challenge = ServerCrypto.base64URLEncode(ServerCrypto.sha256Bytes(Array(verifier.utf8)))
        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    public static func randomState(byteCount: Int = 32) -> String {
        ServerCrypto.base64URLEncode(ServerCrypto.randomBytes(byteCount))
    }

    public static func formURLEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { k, v in
            "\(ServerParsedURL.encodeURIComponent(k))=\(ServerParsedURL.encodeURIComponent(v))"
        }.joined(separator: "&")
    }

    public static func buildURL(_ base: String, query: [(String, String)]) -> String {
        guard !query.isEmpty else { return base }
        let sep = base.contains("?") ? "&" : "?"
        return "\(base)\(sep)\(formURLEncode(query))"
    }

    public static func normalizeServerURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = ServerParsedURL(trimmed)
        guard let scheme = parsed.scheme, (scheme == "http" || scheme == "https"),
              let host = parsed.host, !host.isEmpty
        else {
            throw CoreIntegration.Integration.AuthorizationError(message: "Invalid server URL: \(raw)")
        }
        var path = parsed.pathname
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(path)"
    }

    public static func resolveVerificationURL(_ raw: String, against server: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        let base = try normalizeServerURL(server)
        if trimmed.hasPrefix("/") {
            let parsed = ServerParsedURL(base)
            guard let scheme = parsed.scheme, let host = parsed.host else {
                throw CoreIntegration.Integration.AuthorizationError(message: "Invalid device verification URL")
            }
            return "\(scheme)://\(host)\(trimmed)"
        }
        if trimmed.contains("://") {
            throw CoreIntegration.Integration.AuthorizationError(message: "Invalid device verification URL: expected HTTP(S)")
        }
        return "\(base)/\(trimmed)"
    }

    public static func normalizeDomain(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        else if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func copilotBaseURL(_ metadata: [String: JSONValue]?) -> String {
        if case .string(let endpoint) = metadata?["apiEndpoint"], !endpoint.isEmpty {
            var trimmed = endpoint
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }
        if case .string(let enterprise) = metadata?["enterpriseUrl"], !enterprise.isEmpty {
            return "https://copilot-api.\(normalizeDomain(enterprise))"
        }
        return "https://api.githubcopilot.com"
    }

    public static func copilotUserURL(enterpriseDomain: String?) -> String {
        if let enterpriseDomain, !enterpriseDomain.isEmpty {
            return "https://api.\(normalizeDomain(enterpriseDomain))/copilot_internal/user"
        }
        return "https://api.github.com/copilot_internal/user"
    }

    public static func copilotEntitlementError(chatEnabled: Bool?, canSignupForLimited: Bool?) -> String? {
        guard chatEnabled == false else { return nil }
        if canSignupForLimited == true {
            return "This GitHub account is not signed up for GitHub Copilot. Sign up for Copilot Free at https://github.com/features/copilot/plans and connect again."
        }
        return "This GitHub account does not have GitHub Copilot access. It needs an active Copilot subscription or a seat assigned by an organization."
    }

    /// Decodes the JSON payload segment of a JWT (without signature verification) for claim extraction.
    public static func decodeJWTPayload(_ token: String?) -> [String: JSONValue]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let bytes = ServerCrypto.base64URLDecode(String(parts[1])),
              let decoded = try? ServerCodec.decode(JSONValue.self, from: bytes),
              case .object(let obj) = decoded
        else { return nil }
        return obj
    }

    public static func extractOpenAIAccountID(idToken: String?, accessToken: String?) -> String? {
        for candidate in [idToken, accessToken] {
            guard let claims = decodeJWTPayload(candidate) else { continue }
            if case .string(let acct) = claims["chatgpt_account_id"], !acct.isEmpty {
                return acct
            }
            if case .object(let auth) = claims["https://api.openai.com/auth"],
               case .string(let acct) = auth["chatgpt_account_id"], !acct.isEmpty
            {
                return acct
            }
            if case .array(let orgs) = claims["organizations"],
               case .object(let first) = orgs.first,
               case .string(let id) = first["id"], !id.isEmpty
            {
                return id
            }
        }
        return nil
    }

    // MARK: - Canonical Registration of All 7 Upstream OAuth Methods

    /// Registers all 7 real upstream OAuth methods onto `editor` (alongside existing key/env methods).
    public static func registerAllOAuthMethods(
        into editor: CoreIntegration.Integration.Editor,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) {
        let placeholderAuthorize: @Sendable (FormSchema.Answer) async throws -> CoreIntegration.Integration.OAuthAuthorization = { _ in
            throw CoreIntegration.Integration.AuthorizationError(message: "OAuth flow must be executed via ServerLiveOAuthManager")
        }

        // 1. OpenCode Console ('opencode'): device flow with hidden server field
        let opencodeID = IntegrationID(rawValue: "opencode")
        editor.update(opencodeID) { existing in
            IntegrationSchema.Ref(id: opencodeID, name: "OpenCode Console", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: opencodeID,
            method: IntegrationSchema.OAuthMethod(
                id: openCodeMethodID,
                label: "OpenCode Console account",
                form: FormSchema.Fields(
                    first: .string(FormSchema.StringField(
                        key: "server",
                        hidden: true,
                        format: .uri,
                        defaultValue: CoreProvider.ConsoleAccess.defaultServer
                    ))
                )
            ),
            authorize: placeholderAuthorize
        )))
        editor.updateMethod(.key(CoreIntegration.Integration.KeyImplementation(
            integrationID: opencodeID,
            method: IntegrationSchema.KeyMethod(label: "API key (service account)")
        )))

        // 2. OpenAI ('openai'): Sign in with ChatGPT (chatgpt-token-sharing)
        let openaiID = IntegrationID(rawValue: "openai")
        editor.update(openaiID) { existing in
            IntegrationSchema.Ref(id: openaiID, name: "OpenAI", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: openaiID,
            method: IntegrationSchema.OAuthMethod(
                id: chatGPTMethodID,
                label: "Sign in with ChatGPT"
            ),
            authorize: placeholderAuthorize
        )))

        // 3. GitHub Copilot ('github-copilot'): device flow with deploymentType + conditional enterpriseUrl form
        let copilotID = IntegrationID(rawValue: "github-copilot")
        editor.update(copilotID) { existing in
            IntegrationSchema.Ref(id: copilotID, name: "GitHub Copilot", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: copilotID,
            method: IntegrationSchema.OAuthMethod(
                id: copilotMethodID,
                label: "Login with GitHub Copilot",
                form: FormSchema.Fields(
                    first: .string(FormSchema.StringField(
                        key: "deploymentType",
                        title: "Select GitHub deployment type",
                        required: true,
                        options: [
                            FormSchema.Option(value: "github.com", label: "GitHub.com", description: "Public"),
                            FormSchema.Option(value: "enterprise", label: "GitHub Enterprise", description: "Data residency or self-hosted"),
                        ]
                    )),
                    rest: [
                        .string(FormSchema.StringField(
                            key: "enterpriseUrl",
                            title: "Enter your GitHub Enterprise URL or domain",
                            required: true,
                            when: [
                                FormSchema.When(key: "deploymentType", op: .eq, value: .string("enterprise")),
                            ],
                            placeholder: "company.ghe.com or https://company.ghe.com"
                        )),
                    ]
                )
            ),
            authorize: placeholderAuthorize
        )))

        // 4. xAI ('xai'): device-code flow
        let xaiID = IntegrationID(rawValue: "xai")
        editor.update(xaiID) { existing in
            IntegrationSchema.Ref(id: xaiID, name: "xAI", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: xaiID,
            method: IntegrationSchema.OAuthMethod(
                id: xaiMethodID,
                label: "Login with xAI"
            ),
            authorize: placeholderAuthorize
        )))

        // 5. Poe ('poe'): PKCE + loopback callback
        let poeID = IntegrationID(rawValue: "poe")
        editor.update(poeID) { existing in
            IntegrationSchema.Ref(id: poeID, name: "Poe", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: poeID,
            method: IntegrationSchema.OAuthMethod(
                id: poeMethodID,
                label: "Login with Poe (browser)"
            ),
            authorize: placeholderAuthorize
        )))

        // 6. DigitalOcean ('digitalocean'): PKCE + loopback callback
        let doID = IntegrationID(rawValue: "digitalocean")
        editor.update(doID) { existing in
            IntegrationSchema.Ref(id: doID, name: "DigitalOcean", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: doID,
            method: IntegrationSchema.OAuthMethod(
                id: digitalOceanMethodID,
                label: "Login with DigitalOcean"
            ),
            authorize: placeholderAuthorize
        )))

        // 7. GitLab Duo ('gitlab'): PKCE + loopback callback with instanceUrl form
        let gitlabID = IntegrationID(rawValue: "gitlab")
        let defaultGitLabURL = environment.variable("GITLAB_INSTANCE_URL") ?? "https://gitlab.com"
        editor.update(gitlabID) { existing in
            IntegrationSchema.Ref(id: gitlabID, name: "GitLab Duo", metadata: existing.metadata)
        }
        editor.updateMethod(.oauth(CoreIntegration.Integration.OAuthImplementation(
            integrationID: gitlabID,
            method: IntegrationSchema.OAuthMethod(
                id: gitLabMethodID,
                label: "Login with GitLab",
                form: FormSchema.Fields(
                    first: .string(FormSchema.StringField(
                        key: "instanceUrl",
                        title: "GitLab instance URL",
                        description: "Leave the default to use gitlab.com, or enter your self-managed GitLab URL.",
                        pattern: "^https?://\\S+$",
                        placeholder: defaultGitLabURL,
                        defaultValue: defaultGitLabURL
                    ))
                )
            ),
            authorize: placeholderAuthorize
        )))
    }
}

// MARK: - Live OAuth Manager

/// Process-global live OAuth coordinator executing all 7 real upstream provider OAuth flows,
/// managing ephemeral loopback `POSIXHTTPServer` listeners & device-code background pollers,
/// persisting real `CredentialSchema.OAuth` tokens, reloading provider catalogs, and performing
/// locked per-credential OAuth token refresh.
public final class ServerLiveOAuthManager: Sendable {
    private enum ProviderFlow: Sendable {
        case opencode
        case openaiChatGPT
        case githubCopilot
        case xai
        case poe
        case digitalOcean
        case gitlab
    }

    private struct ActiveAttempt: Sendable {
        let integrationID: IntegrationID
        let attemptID: IntegrationSchema.AttemptID
        let methodID: IntegrationSchema.MethodID
        let label: String?
        let time: IntegrationSchema.AttemptTime
        var status: IntegrationSchema.AttemptStatus
        var claimed: Bool
        var settled: Bool
        var pollTask: Task<Void, Never>?
        var callbackServer: POSIXHTTPServer?
        var manualSubmit: (@Sendable (String) async throws -> Void)?
    }

    private struct State: Sendable {
        var attempts: [String: ActiveAttempt] = [:]
        var onCredentialActivated: (@Sendable (IntegrationID) async -> Void)?
    }

    private let credential: CoreProvider.Credential.Service
    private let httpTransport: any HTTPTransport
    private let kv: CoreKV.Service
    private let bus: CoreBus.Service
    private let environment: any EnvironmentProviding
    private let userAgent: String
    private let workerdProfile: Bool
    private let state = Mutex(State())

    public init(
        credential: CoreProvider.Credential.Service,
        httpTransport: any HTTPTransport,
        kv: CoreKV.Service,
        bus: CoreBus.Service,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        userAgent: String = "opencode/2.0.0",
        workerdProfile: Bool = false,
        onCredentialActivated: (@Sendable (IntegrationID) async -> Void)? = nil
    ) {
        self.credential = credential
        self.httpTransport = httpTransport
        self.kv = kv
        self.bus = bus
        self.environment = environment
        self.userAgent = userAgent
        self.workerdProfile = workerdProfile
        self.state.withLock { $0.onCredentialActivated = onCredentialActivated }
    }

    public func setOnCredentialActivated(_ handler: @escaping @Sendable (IntegrationID) async -> Void) {
        state.withLock { $0.onCredentialActivated = handler }
    }

    private func attemptKey(_ integrationID: IntegrationID, _ attemptID: IntegrationSchema.AttemptID) -> String {
        "\(integrationID.rawValue)::\(attemptID.rawValue)"
    }

    private func resolveFlow(integrationID: IntegrationID, methodID: IntegrationSchema.MethodID) -> ProviderFlow? {
        switch (integrationID.rawValue, methodID.rawValue) {
        case ("opencode", "device"):
            return .opencode
        case ("openai", "chatgpt-token-sharing"), ("openai", "chatgpt-browser"):
            return .openaiChatGPT
        case ("github-copilot", "device"):
            return .githubCopilot
        case ("xai", "browser"), ("xai", "device"):
            return .xai
        case ("poe", "poe-browser"), ("poe", "browser"):
            return .poe
        case ("digitalocean", "digitalocean-oauth"), ("digitalocean", "browser"):
            return .digitalOcean
        case ("gitlab", "gitlab-oauth"), ("gitlab", "pkce"):
            return .gitlab
        default:
            return nil
        }
    }

    /// Returns `true` when this manager owns a real live OAuth flow for `(integrationID, methodID)`.
    public func supports(integrationID: IntegrationID, methodID: IntegrationSchema.MethodID) -> Bool {
        resolveFlow(integrationID: integrationID, methodID: methodID) != nil
    }

    /// Returns `true` when `attemptID` was started by this manager.
    public func hasAttempt(integrationID: IntegrationID, attemptID: IntegrationSchema.AttemptID) -> Bool {
        let key = attemptKey(integrationID, attemptID)
        return state.withLock { $0.attempts[key] != nil }
    }

    /// Returns the current attempt status, automatically marking expired pending attempts as `.expired`.
    public func status(
        integrationID: IntegrationID,
        attemptID: IntegrationSchema.AttemptID
    ) -> IntegrationSchema.AttemptStatus? {
        let key = attemptKey(integrationID, attemptID)
        let now = Double(Flock.currentEpochMs())
        return state.withLock { s -> IntegrationSchema.AttemptStatus? in
            guard var entry = s.attempts[key] else { return nil }
            if case .pending(let t) = entry.status, t.expires > 0, now >= t.expires {
                entry.status = .expired(time: t)
                entry.settled = true
                let task = entry.pollTask
                let server = entry.callbackServer
                entry.pollTask = nil
                entry.callbackServer = nil
                s.attempts[key] = entry
                task?.cancel()
                server?.stop()
            }
            return entry.status
        }
    }

    /// Starts a live OAuth authorization attempt for one of the 7 real upstream providers.
    public func connect(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        answer: FormSchema.Answer = [:],
        label: String? = nil
    ) async throws -> IntegrationSchema.Attempt {
        guard let flow = resolveFlow(integrationID: integrationID, methodID: methodID) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "Unsupported OAuth method '\(methodID.rawValue)' for integration '\(integrationID.rawValue)'"
            )
        }
        switch flow {
        case .opencode:
            return try await startOpenCodeDeviceFlow(integrationID: integrationID, methodID: methodID, answer: answer, label: label)
        case .openaiChatGPT:
            return try await startChatGPTPKCEFlow(integrationID: integrationID, methodID: methodID, label: label)
        case .githubCopilot:
            return try await startCopilotDeviceFlow(integrationID: integrationID, methodID: methodID, answer: answer, label: label)
        case .xai:
            return try await startXAIDeviceFlow(integrationID: integrationID, methodID: methodID, label: label)
        case .poe:
            return try await startPoePKCEFlow(integrationID: integrationID, methodID: methodID, label: label)
        case .digitalOcean:
            return try await startDigitalOceanPKCEFlow(integrationID: integrationID, methodID: methodID, label: label)
        case .gitlab:
            return try await startGitLabPKCEFlow(integrationID: integrationID, methodID: methodID, answer: answer, label: label)
        }
    }

    /// Submits a manual callback URL or authorization code to complete an active PKCE attempt.
    public func complete(
        integrationID: IntegrationID,
        attemptID: IntegrationSchema.AttemptID,
        code: String?
    ) async throws {
        let key = attemptKey(integrationID, attemptID)
        let snapshot: (status: IntegrationSchema.AttemptStatus, submit: (@Sendable (String) async throws -> Void)?) = try state.withLock { s in
            guard let entry = s.attempts[key] else {
                throw CoreIntegration.Integration.AttemptNotFoundError(integrationID: integrationID, attemptID: attemptID)
            }
            return (entry.status, entry.manualSubmit)
        }
        if case .complete = snapshot.status {
            return
        }
        if case .failed(let message, _) = snapshot.status {
            throw CoreIntegration.Integration.AuthorizationError(message: message)
        }
        if case .expired = snapshot.status {
            throw CoreIntegration.Integration.AuthorizationError(message: "OAuth attempt expired")
        }
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw CoreIntegration.Integration.CodeRequiredError(attemptID: attemptID)
        }
        guard let submit = snapshot.submit else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "This OAuth flow completes automatically once authorized"
            )
        }
        try await submit(trimmed)
    }

    /// Cancels an active OAuth attempt and releases any polling task or loopback listener.
    public func cancel(integrationID: IntegrationID, attemptID: IntegrationSchema.AttemptID) async {
        let key = attemptKey(integrationID, attemptID)
        let removed = state.withLock { $0.attempts.removeValue(forKey: key) }
        removed?.pollTask?.cancel()
        removed?.callbackServer?.stop()
    }

    /// Stops all active polling tasks and ephemeral loopback servers (called during runtime shutdown).
    public func close() async {
        let all = state.withLock { s -> [ActiveAttempt] in
            let list = Array(s.attempts.values)
            s.attempts.removeAll()
            return list
        }
        for entry in all {
            entry.pollTask?.cancel()
            entry.callbackServer?.stop()
        }
    }

    // MARK: - Locked Per-Credential OAuth Token Auto-Refresh

    /// Refreshes an expired (or expiring within 60s) OAuth credential under `CoreProvider.Credential.Service.refresh`'s
    /// per-credential lock, persisting the rotated tokens to SQLite.
    public func refreshToken(
        credentialID: CredentialSchema.ID,
        integrationID: IntegrationID,
        force: Bool = false
    ) async throws -> CredentialSchema.OAuth? {
        try await credential.refresh(
            credentialID,
            stale: { oauth, nowMs in
                if force { return true }
                let expires = Int64(oauth.expires.rawValue)
                return expires > 0 && expires <= nowMs + 60_000
            },
            refresh: { [self] current in
                try await performRefresh(integrationID: integrationID, current: current)
            }
        )
    }

    private func performRefresh(
        integrationID: IntegrationID,
        current: CredentialSchema.OAuth
    ) async throws -> CredentialSchema.OAuth {
        switch integrationID.rawValue {
        case "opencode":
            return try await refreshOpenCodeToken(current)
        case "openai":
            return try await refreshOpenAIToken(current)
        case "xai":
            return try await refreshXAIToken(current)
        case "gitlab":
            return try await refreshGitLabToken(current)
        case "poe":
            let now = Flock.currentEpochMs()
            if current.expires.rawValue > 0 && Int64(current.expires.rawValue) <= now {
                throw CoreIntegration.Integration.AuthorizationError(message: "Poe API key expired. Log in with Poe again.")
            }
            return current
        case "digitalocean":
            return try await refreshDigitalOceanToken(current)
        case "github-copilot":
            return current
        default:
            return current
        }
    }

    // MARK: - Completion & Failure State Transitions

    private func finalizeSuccess(
        integrationID: IntegrationID,
        attemptID: IntegrationSchema.AttemptID,
        oauth: CredentialSchema.OAuth,
        derivedLabel: String? = nil,
        deferServerStop: Bool = false
    ) async throws {
        let key = attemptKey(integrationID, attemptID)
        let entryLabel: String? = state.withLock { $0.attempts[key]?.label }
        let finalLabel = entryLabel ?? derivedLabel

        _ = try await credential.create(
            id: nil,
            integrationID: integrationID,
            value: .oauth(oauth),
            label: finalLabel,
            activate: true
        )

        let (srvToStop, callback): (POSIXHTTPServer?, (@Sendable (IntegrationID) async -> Void)?) = state.withLock { s in
            var srv: POSIXHTTPServer? = nil
            if var entry = s.attempts[key] {
                entry.settled = true
                entry.pollTask = nil
                srv = entry.callbackServer
                entry.callbackServer = nil
                s.attempts[key] = entry
            }
            return (srv, s.onCredentialActivated)
        }

        if let callback {
            await callback(integrationID)
        }
        await emitCatalogUpdated()

        state.withLock { s in
            if var entry = s.attempts[key] {
                entry.status = .complete(time: entry.time)
                s.attempts[key] = entry
            }
        }

        if let srv = srvToStop {
            if deferServerStop {
                // Schedule teardown strictly AFTER token exchange & location reload finish so slow
                // upstream model discovery never drops the loopback HTML response socket mid-flight.
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(500))
                    srv.stop()
                }
            } else {
                srv.stop()
            }
        }
    }

    private func finalizeFailure(
        integrationID: IntegrationID,
        attemptID: IntegrationSchema.AttemptID,
        message: String,
        deferServerStop: Bool = false
    ) {
        let key = attemptKey(integrationID, attemptID)
        state.withLock { s in
            guard var entry = s.attempts[key], !entry.settled else { return }
            entry.status = .failed(message: message, time: entry.time)
            entry.settled = true
            entry.pollTask = nil
            let srv = entry.callbackServer
            entry.callbackServer = nil
            s.attempts[key] = entry
            if let srv {
                if deferServerStop {
                    Task.detached {
                        try? await Task.sleep(for: .milliseconds(500))
                        srv.stop()
                    }
                } else {
                    srv.stop()
                }
            }
        }
    }

    private func claimPendingAttempt(
        integrationID: IntegrationID,
        attemptID: IntegrationSchema.AttemptID
    ) -> Bool {
        let key = attemptKey(integrationID, attemptID)
        return state.withLock { s in
            guard var entry = s.attempts[key], !entry.claimed, !entry.settled else { return false }
            entry.claimed = true
            s.attempts[key] = entry
            return true
        }
    }

    private static func htmlResponse(_ html: String, statusCode: Int) -> ServerHTTPResponse {
        ServerHTTPResponse.text(html, statusCode: statusCode, contentType: "text/html; charset=utf-8")
    }

    private func emitCatalogUpdated() async {
        let empty = JSONValue.object([:])
        await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: IntegrationSchema.Event.updated.type), data: empty)
        await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ProviderSchema.Event.updated.type), data: empty)
        await bus.emit(EventSchema.EphemeralDefinition<JSONValue>(type: ModelSchema.Event.updated.type), data: empty)
    }

    // MARK: - 1. OpenCode Console Device-Code Flow (`opencode.ts`)

    private struct OpenCodeDeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri_complete: String
        let expires_in: Double
        let interval: Double
    }

    private struct OpenCodeTokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let org_id: String?
        let error: String?
    }

    private struct OpenCodeUserResponse: Decodable {
        let id: String
        let email: String
    }

    private struct OpenCodeOrgResponse: Decodable {
        let id: String
        let name: String
    }

    private func startOpenCodeDeviceFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        answer: FormSchema.Answer,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let rawServer: String
        if case .string(let s) = answer["server"], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawServer = s
        } else {
            rawServer = CoreProvider.ConsoleAccess.defaultServer
        }
        let server = try ServerLiveOAuth.normalizeServerURL(rawServer)

        let bodyBytes = try ServerCodec.encode(JSONValue.object([
            "client_id": .string(ServerLiveOAuth.openCodeClientID),
            "supports_org_scope": .bool(true),
        ]))
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: "\(server)/auth/device/code",
            headers: [
                "accept": "application/json",
                "content-type": "application/json",
                "user-agent": userAgent,
            ],
            body: bodyBytes
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "OpenCode Console device authorization failed (HTTP \(resp.head.statusCode))"
            )
        }
        let device = try ServerCodec.decode(OpenCodeDeviceResponse.self, from: resp.body)
        let verificationURL = try ServerLiveOAuth.resolveVerificationURL(device.verification_uri_complete, against: server)

        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let ttlMs = max(device.expires_in, 30) * 1000.0
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + ttlMs)
        let key = attemptKey(integrationID, attemptID)

        let entry = ActiveAttempt(
            integrationID: integrationID,
            attemptID: attemptID,
            methodID: methodID,
            label: label,
            time: time,
            status: .pending(time: time),
            claimed: false,
            settled: false,
            pollTask: nil,
            callbackServer: nil,
            manualSubmit: nil
        )
        state.withLock { $0.attempts[key] = entry }

        let initialWaitMs = max(Int64((device.interval * 1000.0).rounded()), 1)
        let expiresAtMs = Int64(time.expires)
        let pollTask = Task { [self] in
            var waitMs = initialWaitMs
            while !Task.isCancelled {
                if Flock.currentEpochMs() >= expiresAtMs {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: "OpenCode Console device authorization timed out")
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(waitMs))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let pollBody = try ServerCodec.encode(JSONValue.object([
                        "grant_type": .string(ServerLiveOAuth.deviceGrantType),
                        "device_code": .string(device.device_code),
                        "client_id": .string(ServerLiveOAuth.openCodeClientID),
                    ]))
                    let pollResp = try await httpTransport.send(HTTPRequest(
                        method: "POST",
                        url: "\(server)/auth/device/token",
                        headers: [
                            "accept": "application/json",
                            "content-type": "application/json",
                            "user-agent": userAgent,
                        ],
                        body: pollBody
                    ))
                    let decoded = try ServerCodec.decode(OpenCodeTokenResponse.self, from: pollResp.body)
                    if let access = decoded.access_token, !access.isEmpty,
                       let refresh = decoded.refresh_token
                    {
                        let oauth = try await buildOpenCodeCredential(
                            server: server,
                            accessToken: access,
                            refreshToken: refresh,
                            expiresIn: decoded.expires_in ?? 3600,
                            orgID: decoded.org_id,
                            methodID: methodID
                        )
                        let derivedOrgName: String? = if case .string(let name) = oauth.metadata?["orgName"] { name } else { nil }
                        try await finalizeSuccess(
                            integrationID: integrationID,
                            attemptID: attemptID,
                            oauth: oauth,
                            derivedLabel: derivedOrgName
                        )
                        return
                    }
                    if decoded.error == "authorization_pending" {
                        continue
                    }
                    if decoded.error == "slow_down" {
                        waitMs += 5_000
                        continue
                    }
                    let errMsg = decoded.error.map { "Device authorization failed: \($0)" }
                        ?? "Device authorization failed (HTTP \(pollResp.head.statusCode))"
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: errMsg)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                    return
                }
            }
        }
        state.withLock { $0.attempts[key]?.pollTask = pollTask }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: verificationURL,
            instructions: "Enter code: \(device.user_code)",
            mode: .auto,
            time: time
        )
    }

    private func buildOpenCodeCredential(
        server: String,
        accessToken: String,
        refreshToken: String,
        expiresIn: Double,
        orgID: String?,
        methodID: IntegrationSchema.MethodID
    ) async throws -> CredentialSchema.OAuth {
        let authHeaders: [String: String] = [
            "accept": "application/json",
            "authorization": "Bearer \(accessToken)",
            "user-agent": userAgent,
        ]
        async let userResp = httpTransport.send(HTTPRequest(method: "GET", url: "\(server)/api/user", headers: authHeaders))
        async let orgsResp = httpTransport.send(HTTPRequest(method: "GET", url: "\(server)/api/orgs", headers: authHeaders))
        let (uResp, oResp) = try await (userResp, orgsResp)

        guard (200..<300).contains(uResp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "OpenCode Console user lookup failed (HTTP \(uResp.head.statusCode))"
            )
        }
        guard (200..<300).contains(oResp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "OpenCode Console organizations lookup failed (HTTP \(oResp.head.statusCode))"
            )
        }
        let user = try ServerCodec.decode(OpenCodeUserResponse.self, from: uResp.body)
        let orgs = try ServerCodec.decode([OpenCodeOrgResponse].self, from: oResp.body)

        let selectedOrg: OpenCodeOrgResponse?
        if let requestedOrgID = orgID {
            guard let found = orgs.first(where: { $0.id == requestedOrgID }) else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "OpenCode organization not found: \(requestedOrgID)"
                )
            }
            selectedOrg = found
        } else {
            selectedOrg = orgs.sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }.first
        }

        var metadata: [String: JSONValue] = [
            "server": .string(server),
            "accountID": .string(user.id),
            "email": .string(user.email),
        ]
        if let selectedOrg {
            metadata["orgID"] = .string(selectedOrg.id)
            metadata["orgName"] = .string(selectedOrg.name)
        }
        let expiresMs = Flock.currentEpochMs() + Int64(max(expiresIn, 0) * 1000.0)
        return CredentialSchema.OAuth(
            methodID: methodID,
            refresh: refreshToken,
            access: accessToken,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: metadata
        )
    }

    private func refreshOpenCodeToken(_ current: CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth {
        let server = try ServerLiveOAuth.normalizeServerURL(CoreProvider.ConsoleAccess.server(.oauth(current)))
        let bodyBytes = try ServerCodec.encode(JSONValue.object([
            "grant_type": .string("refresh_token"),
            "refresh_token": .string(current.refresh),
            "client_id": .string(ServerLiveOAuth.openCodeClientID),
        ]))
        let headers: [String: String] = [
            "accept": "application/json",
            "content-type": "application/json",
            "user-agent": userAgent,
        ]
        var resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: "\(server)/auth/device/token",
            headers: headers,
            body: bodyBytes
        ))
        if resp.head.statusCode == 404 {
            resp = try await httpTransport.send(HTTPRequest(
                method: "POST",
                url: "\(server)/auth/token",
                headers: headers,
                body: bodyBytes
            ))
        }
        if resp.head.statusCode == 400,
           let parsed = try? ServerCodec.decode(OpenCodeTokenResponse.self, from: resp.body),
           parsed.error == "invalid_grant"
        {
            throw CoreIntegration.Integration.AuthorizationError(message: "Reconnect OpenCode Console to continue.")
        }
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "OpenCode Console token refresh failed (HTTP \(resp.head.statusCode))"
            )
        }
        let token = try ServerCodec.decode(OpenCodeTokenResponse.self, from: resp.body)
        guard let access = token.access_token, !access.isEmpty else {
            throw CoreIntegration.Integration.AuthorizationError(message: "OpenCode Console refresh returned no access token")
        }
        let refresh = token.refresh_token ?? current.refresh
        let expiresMs = Flock.currentEpochMs() + Int64(max(token.expires_in ?? 3600, 0) * 1000.0)
        var metadata = current.metadata ?? [:]
        if let orgID = token.org_id, !orgID.isEmpty {
            let existingOrgID: String? = if case .string(let s) = metadata["orgID"] { s } else { nil }
            let existingOrgName: String? = if case .string(let s) = metadata["orgName"] { s } else { nil }
            metadata["orgID"] = .string(orgID)
            metadata["orgName"] = .string(existingOrgID == orgID ? (existingOrgName ?? orgID) : orgID)
        }
        return CredentialSchema.OAuth(
            methodID: current.methodID,
            refresh: refresh,
            access: access,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    // MARK: - 2. OpenAI / ChatGPT PKCE + Loopback Flow (`chatgpt.ts`)

    private struct OpenAITokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
        let scope: String?
    }

    private func startChatGPTPKCEFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let hostID: String
        if let existing = try? await kv.get("chatgpt-agent-host-id"), case .string(let s) = existing, !s.isEmpty {
            hostID = s
        } else {
            let generated = "urn:uuid:\(uuid())"
            try? await kv.set("chatgpt-agent-host-id", value: .string(generated))
            hostID = generated
        }

        // Reuse previously registered dynamic client ID if an active ChatGPT credential already exists
        let savedClientID: String? = await {
            guard let list = try? await credential.list(integrationID),
                  let active = list.last,
                  case .oauth(let o) = active.value,
                  case .string(let cid) = o.metadata?["clientID"], !cid.isEmpty
            else { return nil }
            return cid
        }()

        let pkce = ServerLiveOAuth.generatePKCE(length: 43)
        let oauthState = ServerLiveOAuth.randomState()
        let nonce = ServerLiveOAuth.randomState()
        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let key = attemptKey(integrationID, attemptID)

        let redirectBox = Mutex<String>("")

        let exchangeAndPersist: @Sendable (String, String?, Bool) async throws -> Void = { [self] code, callbackClientID, fromLoopback in
            if let saved = savedClientID, let returned = callbackClientID, returned != saved {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "ChatGPT returned a different client than this connection. Connect again."
                )
            }
            let clientID = savedClientID ?? callbackClientID ?? ServerLiveOAuth.chatGPTRegistrationClientID
            let redirect = redirectBox.withLock { $0 }
            let formBody = ServerLiveOAuth.formURLEncode([
                ("grant_type", "authorization_code"),
                ("client_id", clientID),
                ("code", code),
                ("code_verifier", pkce.verifier),
                ("redirect_uri", redirect),
                ("resource", ServerLiveOAuth.chatGPTResource),
            ])
            let resp = try await httpTransport.send(HTTPRequest(
                method: "POST",
                url: ServerLiveOAuth.chatGPTTokenURL,
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                    "user-agent": userAgent,
                ],
                body: Array(formBody.utf8)
            ))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "ChatGPT token exchange failed (HTTP \(resp.head.statusCode))"
                )
            }
            let tokens = try ServerCodec.decode(OpenAITokenResponse.self, from: resp.body)
            if let scopeStr = tokens.scope, !scopeStr.isEmpty,
               !scopeStr.split(separator: " ").contains(Substring(ServerLiveOAuth.chatGPTTokenSharingScope))
            {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "ChatGPT sign-in finished without token sharing. Sign in again and allow token sharing, or connect OpenAI with an API key."
                )
            }
            if let idToken = tokens.id_token, let claims = ServerLiveOAuth.decodeJWTPayload(idToken) {
                if case .string(let tokenNonce) = claims["nonce"], tokenNonce != nonce {
                    throw CoreIntegration.Integration.AuthorizationError(
                        message: "ID token nonce does not match this sign-in attempt"
                    )
                }
            }
            let scopes: [JSONValue] = (tokens.scope?.split(separator: " ").map(String.init) ?? [
                "openid", "profile", "email", "offline_access", ServerLiveOAuth.chatGPTTokenSharingScope,
            ]).map { .string($0) }
            var metadata: [String: JSONValue] = [
                "clientID": .string(clientID),
                "scopes": .array(scopes),
            ]
            if let accountID = ServerLiveOAuth.extractOpenAIAccountID(idToken: tokens.id_token, accessToken: tokens.access_token) {
                metadata["accountID"] = .string(accountID)
            }
            let expiresMs = Flock.currentEpochMs() + Int64(max(tokens.expires_in ?? 3600, 0) * 1000.0)
            let oauth = CredentialSchema.OAuth(
                methodID: methodID,
                refresh: tokens.refresh_token ?? "",
                access: tokens.access_token,
                expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
                metadata: metadata
            )
            try await finalizeSuccess(
                integrationID: integrationID,
                attemptID: attemptID,
                oauth: oauth,
                deferServerStop: fromLoopback
            )
        }

        let callbackServer = try startLoopbackServerIfAvailable(preferredPort: 0) { [self] req in
            guard req.pathname == "/auth/callback" else {
                return ServerHTTPResponse.text("Not found", statusCode: 404)
            }
            if let err = req.query("error_description") ?? req.query("error"), !err.isEmpty {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: err, deferServerStop: true)
                return Self.htmlResponse(
                    CoreProvider.OAuthPage.error(err, options: .init(provider: "ChatGPT")),
                    statusCode: 400
                )
            }
            let code = req.query("code")
            let returnedState = req.query("state")
            guard let code, !code.isEmpty, returnedState == oauthState else {
                let message = (code?.isEmpty == false) ? "Invalid OAuth state" : "Missing authorization code"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: message, deferServerStop: true)
                return Self.htmlResponse(
                    CoreProvider.OAuthPage.error(message, options: .init(provider: "ChatGPT")),
                    statusCode: 400
                )
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                return ServerHTTPResponse.text("OAuth callback already received", statusCode: 409)
            }
            let callbackClientID = req.query("client_id")
            do {
                try await exchangeAndPersist(code, callbackClientID, true)
                return Self.htmlResponse(
                    CoreProvider.OAuthPage.success(.init(provider: "ChatGPT")),
                    statusCode: 200
                )
            } catch {
                let msg = String(describing: error)
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(
                    CoreProvider.OAuthPage.error(msg, options: .init(provider: "ChatGPT")),
                    statusCode: 400
                )
            }
        }

        let port = callbackServer?.address.port ?? 1455
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        redirectBox.withLock { $0 = redirect }

        var queryItems: [(String, String)] = [
            ("client_id", savedClientID ?? ServerLiveOAuth.chatGPTRegistrationClientID),
        ]
        if savedClientID == nil {
            queryItems.append(("agent_name_hint", ServerLiveOAuth.chatGPTAgentName))
        }
        queryItems.append(contentsOf: [
            ("ext_agent_host_id", hostID),
            ("response_type", "code"),
            ("redirect_uri", redirect),
            ("scope", "openid profile email offline_access resource.invoke \(ServerLiveOAuth.chatGPTTokenSharingScope)"),
            ("resource", ServerLiveOAuth.chatGPTResource),
            ("state", oauthState),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", pkce.challenge),
        ])
        let authURL = ServerLiveOAuth.buildURL(ServerLiveOAuth.chatGPTAuthorizeURL, query: queryItems)

        let manualSubmit: @Sendable (String) async throws -> Void = { [self] input in
            let code: String
            let clientID: String?
            if input.hasPrefix("http://") || input.hasPrefix("https://") {
                let parsed = try CoreProvider.OAuthRedirect.pasted(text: input, state: oauthState)
                switch parsed {
                case .error(let msg, _):
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg)
                    throw CoreIntegration.Integration.AuthorizationError(message: msg)
                case .code(let parsedCode, let params):
                    code = parsedCode
                    clientID = params["client_id"]
                }
            } else {
                code = input
                clientID = nil
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                return
            }
            do {
                try await exchangeAndPersist(code, clientID, false)
            } catch {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                throw error
            }
        }

        let entry = ActiveAttempt(
            integrationID: integrationID,
            attemptID: attemptID,
            methodID: methodID,
            label: label,
            time: time,
            status: .pending(time: time),
            claimed: false,
            settled: false,
            pollTask: nil,
            callbackServer: callbackServer,
            manualSubmit: manualSubmit
        )
        state.withLock { $0.attempts[key] = entry }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: authURL,
            instructions: "Complete authorization in your browser. This window will close automatically.",
            mode: callbackServer != nil ? .auto : .code,
            paste: true,
            time: time
        )
    }

    private func refreshOpenAIToken(_ current: CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth {
        let isLegacy = current.methodID.rawValue == "chatgpt-browser" || current.methodID.rawValue == "chatgpt-headless"
        let tokenURL = isLegacy ? ServerLiveOAuth.chatGPTLegacyTokenURL : ServerLiveOAuth.chatGPTTokenURL
        let clientID: String = {
            if isLegacy { return ServerLiveOAuth.chatGPTLegacyClientID }
            if case .string(let cid) = current.metadata?["clientID"], !cid.isEmpty { return cid }
            return ServerLiveOAuth.chatGPTRegistrationClientID
        }()
        var params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", current.refresh),
        ]
        if !isLegacy {
            params.append(("resource", ServerLiveOAuth.chatGPTResource))
        }
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: tokenURL,
            headers: [
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
                "user-agent": userAgent,
            ],
            body: Array(ServerLiveOAuth.formURLEncode(params).utf8)
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "OpenAI token refresh failed (HTTP \(resp.head.statusCode))"
            )
        }
        let tokens = try ServerCodec.decode(OpenAITokenResponse.self, from: resp.body)
        var metadata = current.metadata ?? [:]
        if !isLegacy {
            metadata["clientID"] = .string(clientID)
        }
        if let scopeStr = tokens.scope, !scopeStr.isEmpty {
            metadata["scopes"] = .array(scopeStr.split(separator: " ").map { .string(String($0)) })
        }
        if let accountID = ServerLiveOAuth.extractOpenAIAccountID(idToken: tokens.id_token, accessToken: tokens.access_token) {
            metadata["accountID"] = .string(accountID)
        }
        let expiresMs = Flock.currentEpochMs() + Int64(max(tokens.expires_in ?? 3600, 0) * 1000.0)
        return CredentialSchema.OAuth(
            methodID: current.methodID,
            refresh: tokens.refresh_token ?? current.refresh,
            access: tokens.access_token,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    // MARK: - 3. GitHub Copilot Device-Code Flow (`github-copilot.ts`)

    private struct CopilotDeviceResponse: Decodable {
        let verification_uri: String
        let user_code: String
        let device_code: String
        let interval: Double
        let expires_in: Double?
    }

    private struct CopilotTokenResponse: Decodable {
        let access_token: String?
        let error: String?
        let interval: Double?
    }

    private struct CopilotUserResponse: Decodable {
        struct Endpoints: Decodable {
            let api: String?
        }
        let chat_enabled: Bool?
        let can_signup_for_limited: Bool?
        let endpoints: Endpoints?
    }

    private func startCopilotDeviceFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        answer: FormSchema.Answer,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let isEnterprise: Bool = {
            if case .string(let t) = answer["deploymentType"], t == "enterprise" { return true }
            return false
        }()
        let enterpriseURL: String? = {
            if case .string(let u) = answer["enterpriseUrl"] {
                let trimmed = u.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }()
        if isEnterprise && enterpriseURL == nil {
            throw CoreIntegration.Integration.AuthorizationError(message: "Enterprise URL is required")
        }
        let domain = isEnterprise ? ServerLiveOAuth.normalizeDomain(enterpriseURL ?? "") : "github.com"
        let deviceURL = "https://\(domain)/login/device/code"
        let tokenURL = "https://\(domain)/login/oauth/access_token"
        let reqHeaders: [String: String] = [
            "accept": "application/json",
            "content-type": "application/json",
            "user-agent": userAgent,
        ]

        let bodyBytes = try ServerCodec.encode(JSONValue.object([
            "client_id": .string(ServerLiveOAuth.copilotClientID),
            "scope": .string("read:user"),
        ]))
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: deviceURL,
            headers: reqHeaders,
            body: bodyBytes
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "GitHub Copilot device authorization failed (HTTP \(resp.head.statusCode))"
            )
        }
        let device = try ServerCodec.decode(CopilotDeviceResponse.self, from: resp.body)

        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let ttlMs = max(device.expires_in ?? 900, 30) * 1000.0
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + ttlMs)
        let key = attemptKey(integrationID, attemptID)

        let entry = ActiveAttempt(
            integrationID: integrationID,
            attemptID: attemptID,
            methodID: methodID,
            label: label,
            time: time,
            status: .pending(time: time),
            claimed: false,
            settled: false,
            pollTask: nil,
            callbackServer: nil,
            manualSubmit: nil
        )
        state.withLock { $0.attempts[key] = entry }

        let initialWaitMs = max(Int64((device.interval * 1000.0).rounded()), 1)
        let safetyMarginMs: Int64 = device.interval >= 1.0 ? 3_000 : 0
        let expiresAtMs = Int64(time.expires)

        let pollTask = Task { [self] in
            var waitMs = initialWaitMs
            while !Task.isCancelled {
                if Flock.currentEpochMs() >= expiresAtMs {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: "GitHub Copilot device authorization timed out")
                    return
                }
                do {
                    let pollBody = try ServerCodec.encode(JSONValue.object([
                        "client_id": .string(ServerLiveOAuth.copilotClientID),
                        "device_code": .string(device.device_code),
                        "grant_type": .string(ServerLiveOAuth.deviceGrantType),
                    ]))
                    let pollResp = try await httpTransport.send(HTTPRequest(
                        method: "POST",
                        url: tokenURL,
                        headers: reqHeaders,
                        body: pollBody
                    ))
                    let token = try ServerCodec.decode(CopilotTokenResponse.self, from: pollResp.body)
                    if let access = token.access_token, !access.isEmpty {
                        // Verify Copilot entitlement & discover account-specific API endpoint
                        let userEndpoint = ServerLiveOAuth.copilotUserURL(enterpriseDomain: isEnterprise ? domain : nil)
                        var apiEndpoint: String? = nil
                        if let userResp = try? await httpTransport.send(HTTPRequest(
                            method: "GET",
                            url: userEndpoint,
                            headers: [
                                "accept": "application/json",
                                "authorization": "Bearer \(access)",
                                "user-agent": userAgent,
                                "x-github-api-version": ServerLiveOAuth.copilotUserApiVersion,
                            ]
                        )), (200..<300).contains(userResp.head.statusCode),
                           let user = try? ServerCodec.decode(CopilotUserResponse.self, from: userResp.body)
                        {
                            if let denied = ServerLiveOAuth.copilotEntitlementError(
                                chatEnabled: user.chat_enabled,
                                canSignupForLimited: user.can_signup_for_limited
                            ) {
                                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: denied)
                                return
                            }
                            if var ep = user.endpoints?.api, !ep.isEmpty {
                                while ep.hasSuffix("/") { ep.removeLast() }
                                apiEndpoint = ep
                            }
                        }
                        var metadata: [String: JSONValue] = [:]
                        if isEnterprise { metadata["enterpriseUrl"] = .string(domain) }
                        if let apiEndpoint { metadata["apiEndpoint"] = .string(apiEndpoint) }

                        let oauth = CredentialSchema.OAuth(
                            methodID: methodID,
                            refresh: access,
                            access: access,
                            expires: .zero,
                            metadata: metadata.isEmpty ? nil : metadata
                        )
                        try await finalizeSuccess(integrationID: integrationID, attemptID: attemptID, oauth: oauth)
                        return
                    }
                    if token.error == "authorization_pending" {
                        try await Task.sleep(for: .milliseconds(waitMs + safetyMarginMs))
                        continue
                    }
                    if token.error == "slow_down" {
                        if let srvInterval = token.interval, srvInterval > 0 {
                            waitMs = Int64((srvInterval * 1000.0).rounded())
                        } else {
                            waitMs += 5_000
                        }
                        try await Task.sleep(for: .milliseconds(waitMs + safetyMarginMs))
                        continue
                    }
                    let msg = token.error.map { "Device authorization failed: \($0)" } ?? "Device authorization failed"
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                    return
                }
            }
        }
        state.withLock { $0.attempts[key]?.pollTask = pollTask }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: device.verification_uri,
            instructions: "Enter code: \(device.user_code)",
            mode: .auto,
            time: time
        )
    }

    // MARK: - 4. xAI Device-Code Flow (`xai.ts`)

    private struct XAIDeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: Double?
        let interval: Double?
    }

    private struct XAITokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private struct XAIErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private func startXAIDeviceFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let formBody = ServerLiveOAuth.formURLEncode([
            ("client_id", ServerLiveOAuth.xaiClientID),
            ("scope", ServerLiveOAuth.xaiScope),
            ("referrer", "opencode"),
        ])
        let headers: [String: String] = [
            "content-type": "application/x-www-form-urlencoded",
            "accept": "application/json",
            "user-agent": userAgent,
        ]
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: "\(ServerLiveOAuth.xaiIssuer)/device/code",
            headers: headers,
            body: Array(formBody.utf8)
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "xAI device authorization failed (HTTP \(resp.head.statusCode))"
            )
        }
        let device = try ServerCodec.decode(XAIDeviceResponse.self, from: resp.body)

        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let ttlSeconds = (device.expires_in ?? 300) > 0 ? (device.expires_in ?? 300) : 300
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + ttlSeconds * 1000.0)
        let key = attemptKey(integrationID, attemptID)

        let entry = ActiveAttempt(
            integrationID: integrationID,
            attemptID: attemptID,
            methodID: methodID,
            label: label,
            time: time,
            status: .pending(time: time),
            claimed: false,
            settled: false,
            pollTask: nil,
            callbackServer: nil,
            manualSubmit: nil
        )
        state.withLock { $0.attempts[key] = entry }

        let rawInterval = device.interval ?? 5.0
        let initialWaitMs = max(Int64((rawInterval * 1000.0).rounded()), 1)
        let safetyMarginMs: Int64 = rawInterval >= 1.0 ? 3_000 : 0
        let expiresAtMs = Int64(time.expires)

        let pollTask = Task { [self] in
            var waitMs = initialWaitMs
            while !Task.isCancelled {
                if Flock.currentEpochMs() >= expiresAtMs {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: "xAI device authorization timed out")
                    return
                }
                do {
                    let pollBody = ServerLiveOAuth.formURLEncode([
                        ("grant_type", ServerLiveOAuth.deviceGrantType),
                        ("client_id", ServerLiveOAuth.xaiClientID),
                        ("device_code", device.device_code),
                    ])
                    let pollResp = try await httpTransport.send(HTTPRequest(
                        method: "POST",
                        url: "\(ServerLiveOAuth.xaiIssuer)/token",
                        headers: headers,
                        body: Array(pollBody.utf8)
                    ))
                    if (200..<300).contains(pollResp.head.statusCode) {
                        let tokens = try ServerCodec.decode(XAITokenResponse.self, from: pollResp.body)
                        let oauth = buildXAICredential(methodID: methodID, tokens: tokens, currentRefresh: nil, metadata: nil)
                        try await finalizeSuccess(integrationID: integrationID, attemptID: attemptID, oauth: oauth)
                        return
                    }
                    let err = try? ServerCodec.decode(XAIErrorResponse.self, from: pollResp.body)
                    if err?.error == "authorization_pending" {
                        try await Task.sleep(for: .milliseconds(waitMs + safetyMarginMs))
                        continue
                    }
                    if err?.error == "slow_down" {
                        waitMs += 5_000
                        try await Task.sleep(for: .milliseconds(waitMs + safetyMarginMs))
                        continue
                    }
                    if err?.error == "access_denied" || err?.error == "authorization_denied" {
                        finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: "xAI device authorization was denied")
                        return
                    }
                    if err?.error == "expired_token" {
                        finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: "xAI device code expired - please re-run login")
                        return
                    }
                    let detail = err?.error_description ?? err?.error
                    finalizeFailure(
                        integrationID: integrationID,
                        attemptID: attemptID,
                        message: "xAI device token exchange failed (\(pollResp.head.statusCode))\(detail.map { ": \($0)" } ?? "")"
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                    return
                }
            }
        }
        state.withLock { $0.attempts[key]?.pollTask = pollTask }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: device.verification_uri_complete ?? device.verification_uri,
            instructions: "Open \(device.verification_uri) on any device and enter code: \(device.user_code)",
            mode: .auto,
            time: time
        )
    }

    private func buildXAICredential(
        methodID: IntegrationSchema.MethodID,
        tokens: XAITokenResponse,
        currentRefresh: String?,
        metadata: [String: JSONValue]?
    ) -> CredentialSchema.OAuth {
        let expiresMs: Int64
        if let expIn = tokens.expires_in, expIn > 0 {
            expiresMs = Flock.currentEpochMs() + Int64(expIn * 1000.0)
        } else if let claims = ServerLiveOAuth.decodeJWTPayload(tokens.access_token) {
            if case .int(let exp) = claims["exp"] {
                expiresMs = exp * 1000
            } else if case .double(let exp) = claims["exp"] {
                expiresMs = Int64(exp * 1000.0)
            } else {
                expiresMs = Flock.currentEpochMs() + 3_600_000
            }
        } else {
            expiresMs = Flock.currentEpochMs() + 3_600_000
        }
        return CredentialSchema.OAuth(
            methodID: methodID,
            refresh: tokens.refresh_token ?? currentRefresh ?? "",
            access: tokens.access_token,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: metadata
        )
    }

    private func refreshXAIToken(_ current: CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth {
        let formBody = ServerLiveOAuth.formURLEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refresh),
            ("client_id", ServerLiveOAuth.xaiClientID),
        ])
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: "\(ServerLiveOAuth.xaiIssuer)/token",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
                "user-agent": userAgent,
            ],
            body: Array(formBody.utf8)
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "xAI token refresh failed (HTTP \(resp.head.statusCode))"
            )
        }
        let tokens = try ServerCodec.decode(XAITokenResponse.self, from: resp.body)
        return buildXAICredential(methodID: current.methodID, tokens: tokens, currentRefresh: current.refresh, metadata: current.metadata)
    }

    // MARK: - 5. Poe PKCE + Loopback Flow (`poe.ts`)

    private struct PoeTokenResponse: Decodable {
        let api_key: String?
        let api_key_expires_in: Double?
        let access_token: String?
        let expires_in: Double?
    }

    private func startPoePKCEFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let pkce = ServerLiveOAuth.generatePKCE(length: 43)
        let oauthState = ServerLiveOAuth.randomState()
        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let key = attemptKey(integrationID, attemptID)
        let redirectBox = Mutex<String>("")

        let exchangeAndPersist: @Sendable (String, Bool) async throws -> Void = { [self] code, fromLoopback in
            let redirect = redirectBox.withLock { $0 }
            let formBody = ServerLiveOAuth.formURLEncode([
                ("grant_type", "authorization_code"),
                ("client_id", ServerLiveOAuth.poeClientID),
                ("code", code),
                ("redirect_uri", redirect),
                ("code_verifier", pkce.verifier),
            ])
            let resp = try await httpTransport.send(HTTPRequest(
                method: "POST",
                url: ServerLiveOAuth.poeTokenURL,
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                    "user-agent": userAgent,
                ],
                body: Array(formBody.utf8)
            ))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "Poe token exchange failed (\(resp.head.statusCode))"
                )
            }
            let decoded = try ServerCodec.decode(PoeTokenResponse.self, from: resp.body)
            guard let apiKey = (decoded.api_key ?? decoded.access_token)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty
            else {
                throw CoreIntegration.Integration.AuthorizationError(message: "Invalid Poe token response")
            }
            let expiresMs: Int64
            if let expIn = decoded.api_key_expires_in ?? decoded.expires_in, expIn >= 0 {
                expiresMs = Flock.currentEpochMs() + Int64(expIn * 1000.0)
            } else {
                expiresMs = 0
            }
            let oauth = CredentialSchema.OAuth(
                methodID: methodID,
                refresh: "",
                access: apiKey,
                expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero
            )
            try await finalizeSuccess(integrationID: integrationID, attemptID: attemptID, oauth: oauth, deferServerStop: fromLoopback)
        }

        let callbackServer = try startLoopbackServerIfAvailable(preferredPort: 0) { [self] req in
            guard req.method == "GET", req.pathname == "/callback" else {
                return ServerHTTPResponse.empty(statusCode: 404)
            }
            if req.query("state") != oauthState {
                let msg = "Invalid OAuth state"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "Poe")), statusCode: 400)
            }
            if let iss = req.query("iss"), iss != ServerLiveOAuth.poeIssuer {
                let msg = "Invalid OAuth issuer"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "Poe")), statusCode: 400)
            }
            if let err = req.query("error_description") ?? req.query("error"), !err.isEmpty {
                let safe = err.contains(oauthState) ? "Poe authorization failed" : err
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: safe, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(safe, options: .init(provider: "Poe")), statusCode: 400)
            }
            guard let code = req.query("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                let msg = "Missing authorization code"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "Poe")), statusCode: 400)
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                return ServerHTTPResponse.text("OAuth callback already received", statusCode: 409)
            }
            do {
                try await exchangeAndPersist(code, true)
                return Self.htmlResponse(CoreProvider.OAuthPage.success(.init(provider: "Poe")), statusCode: 200)
            } catch {
                let msg = String(describing: error)
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "Poe")), statusCode: 400)
            }
        }

        let port = callbackServer?.address.port ?? 8081
        let redirect = "http://127.0.0.1:\(port)/callback"
        redirectBox.withLock { $0 = redirect }

        let authURL = ServerLiveOAuth.buildURL("\(ServerLiveOAuth.poeIssuer)/oauth/authorize", query: [
            ("response_type", "code"),
            ("client_id", ServerLiveOAuth.poeClientID),
            ("redirect_uri", redirect),
            ("scope", "apikey:create"),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("state", oauthState),
        ])

        let manualSubmit: @Sendable (String) async throws -> Void = { [self] input in
            let code: String
            if input.hasPrefix("http://") || input.hasPrefix("https://") {
                let parsed = try CoreProvider.OAuthRedirect.pasted(text: input, state: oauthState)
                switch parsed {
                case .error(let msg, _):
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg)
                    throw CoreIntegration.Integration.AuthorizationError(message: msg)
                case .code(let parsedCode, let params):
                    if let iss = params["iss"], iss != ServerLiveOAuth.poeIssuer {
                        throw CoreIntegration.Integration.AuthorizationError(message: "Invalid OAuth issuer")
                    }
                    code = parsedCode
                }
            } else {
                code = input
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else { return }
            do {
                try await exchangeAndPersist(code, false)
            } catch {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                throw error
            }
        }

        state.withLock {
            $0.attempts[key] = ActiveAttempt(
                integrationID: integrationID,
                attemptID: attemptID,
                methodID: methodID,
                label: label,
                time: time,
                status: .pending(time: time),
                claimed: false,
                settled: false,
                pollTask: nil,
                callbackServer: callbackServer,
                manualSubmit: manualSubmit
            )
        }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: authURL,
            instructions: "Complete authorization in your browser. This window will close automatically.",
            mode: callbackServer != nil ? .auto : .code,
            paste: true,
            time: time
        )
    }

    // MARK: - 6. DigitalOcean PKCE + Loopback Flow (`digitalocean.ts`)

    private struct DigitalOceanTokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private struct DigitalOceanFragmentPayload: Decodable {
        let access_token: String?
        let expires_in: String?
        let state: String?
        let error: String?
        let error_description: String?
    }

    private func startDigitalOceanPKCEFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let pkce = ServerLiveOAuth.generatePKCE(length: 43)
        let oauthState = ServerLiveOAuth.randomState()
        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let key = attemptKey(integrationID, attemptID)
        let redirectBox = Mutex<String>("")

        let exchangeCode: @Sendable (String, Bool) async throws -> Void = { [self] code, fromLoopback in
            let redirect = redirectBox.withLock { $0 }
            let formBody = ServerLiveOAuth.formURLEncode([
                ("grant_type", "authorization_code"),
                ("client_id", ServerLiveOAuth.digitalOceanClientID),
                ("code", code),
                ("redirect_uri", redirect),
                ("code_verifier", pkce.verifier),
            ])
            let resp = try await httpTransport.send(HTTPRequest(
                method: "POST",
                url: ServerLiveOAuth.digitalOceanTokenURL,
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                    "user-agent": userAgent,
                ],
                body: Array(formBody.utf8)
            ))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "DigitalOcean token exchange failed (HTTP \(resp.head.statusCode))"
                )
            }
            let tokens = try ServerCodec.decode(DigitalOceanTokenResponse.self, from: resp.body)
            let ttlSeconds = (tokens.expires_in ?? 2_592_000) > 0 ? (tokens.expires_in ?? 2_592_000) : 2_592_000
            let expiresMs = Flock.currentEpochMs() + Int64(ttlSeconds * 1000.0)
            let oauth = CredentialSchema.OAuth(
                methodID: methodID,
                refresh: tokens.refresh_token ?? "",
                access: tokens.access_token,
                expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero
            )
            try await finalizeSuccess(integrationID: integrationID, attemptID: attemptID, oauth: oauth, deferServerStop: fromLoopback)
        }

        let callbackServer = try startLoopbackServerIfAvailable(
            preferredPort: ServerLiveOAuth.digitalOceanCallbackPort,
            fallbackToEphemeral: true
        ) { [self] req in
            if req.method == "GET", req.pathname == "/auth/callback" {
                if let err = req.query("error_description") ?? req.query("error"), !err.isEmpty {
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: err, deferServerStop: true)
                    return Self.htmlResponse(
                        CoreProvider.OAuthPage.error(err, options: .init(provider: "DigitalOcean")),
                        statusCode: 400
                    )
                }
                if let code = req.query("code"), !code.isEmpty {
                    guard req.query("state") == oauthState else {
                        let msg = "Invalid OAuth state"
                        finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                        return Self.htmlResponse(
                            CoreProvider.OAuthPage.error(msg, options: .init(provider: "DigitalOcean")),
                            statusCode: 400
                        )
                    }
                    guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                        return ServerHTTPResponse.text("OAuth callback already received", statusCode: 409)
                    }
                    do {
                        try await exchangeCode(code, true)
                        return Self.htmlResponse(
                            CoreProvider.OAuthPage.success(.init(provider: "DigitalOcean")),
                            statusCode: 200
                        )
                    } catch {
                        let msg = String(describing: error)
                        finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                        return Self.htmlResponse(
                            CoreProvider.OAuthPage.error(msg, options: .init(provider: "DigitalOcean")),
                            statusCode: 400
                        )
                    }
                }
                // Fragment token bootstrap page for implicit callbacks
                return Self.htmlResponse(
                    CoreProvider.OAuthPage.bootstrap(.init(tokenPath: "/auth/token", provider: "DigitalOcean")),
                    statusCode: 200
                )
            }
            if req.method == "POST", req.pathname == "/auth/token" {
                let body = try? ServerCodec.decode(DigitalOceanFragmentPayload.self, from: req.body)
                let err = body?.error_description ?? body?.error
                guard err == nil, let access = body?.access_token, !access.isEmpty, body?.state == oauthState else {
                    let msg = err ?? ((body?.access_token != nil) ? "Invalid OAuth state" : "Missing access token")
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                    return ServerHTTPResponse.json(JSONValue.object(["error": .string(msg)]), statusCode: 400)
                }
                guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                    return ServerHTTPResponse.json(JSONValue.object(["error": .string("OAuth callback already received")]), statusCode: 409)
                }
                let parsedExpires = Int64(body?.expires_in ?? "") ?? 2_592_000
                let ttlSeconds = parsedExpires > 0 ? parsedExpires : 2_592_000
                let expiresMs = Flock.currentEpochMs() + ttlSeconds * 1000
                let oauth = CredentialSchema.OAuth(
                    methodID: methodID,
                    refresh: "",
                    access: access,
                    expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero
                )
                do {
                    try await finalizeSuccess(integrationID: integrationID, attemptID: attemptID, oauth: oauth, deferServerStop: true)
                    return ServerHTTPResponse.json(JSONValue.object(["ok": .bool(true)]), statusCode: 200)
                } catch {
                    let msg = String(describing: error)
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                    return ServerHTTPResponse.json(JSONValue.object(["error": .string(msg)]), statusCode: 500)
                }
            }
            return ServerHTTPResponse.text("Not found", statusCode: 404)
        }

        let port = callbackServer?.address.port ?? ServerLiveOAuth.digitalOceanCallbackPort
        let redirect = "http://localhost:\(port)/auth/callback"
        redirectBox.withLock { $0 = redirect }

        let authURL = ServerLiveOAuth.buildURL(ServerLiveOAuth.digitalOceanAuthorizeURL, query: [
            ("response_type", "code"),
            ("client_id", ServerLiveOAuth.digitalOceanClientID),
            ("redirect_uri", redirect),
            ("scope", "genai:read inference:query"),
            ("state", oauthState),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
        ])

        let manualSubmit: @Sendable (String) async throws -> Void = { [self] input in
            let code: String
            if input.hasPrefix("http://") || input.hasPrefix("https://") {
                let parsed = try CoreProvider.OAuthRedirect.pasted(text: input, state: oauthState)
                switch parsed {
                case .error(let msg, _):
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg)
                    throw CoreIntegration.Integration.AuthorizationError(message: msg)
                case .code(let parsedCode, _):
                    code = parsedCode
                }
            } else {
                code = input
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else { return }
            do {
                try await exchangeCode(code, false)
            } catch {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                throw error
            }
        }

        state.withLock {
            $0.attempts[key] = ActiveAttempt(
                integrationID: integrationID,
                attemptID: attemptID,
                methodID: methodID,
                label: label,
                time: time,
                status: .pending(time: time),
                claimed: false,
                settled: false,
                pollTask: nil,
                callbackServer: callbackServer,
                manualSubmit: manualSubmit
            )
        }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: authURL,
            instructions: "Complete authorization in your browser. This window will close automatically.",
            mode: callbackServer != nil ? .auto : .code,
            paste: true,
            time: time
        )
    }

    private func refreshDigitalOceanToken(_ current: CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth {
        guard !current.refresh.isEmpty else {
            return current
        }
        let formBody = ServerLiveOAuth.formURLEncode([
            ("grant_type", "refresh_token"),
            ("client_id", ServerLiveOAuth.digitalOceanClientID),
            ("refresh_token", current.refresh),
        ])
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: ServerLiveOAuth.digitalOceanTokenURL,
            headers: [
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
                "user-agent": userAgent,
            ],
            body: Array(formBody.utf8)
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "DigitalOcean token refresh failed (HTTP \(resp.head.statusCode))"
            )
        }
        let tokens = try ServerCodec.decode(DigitalOceanTokenResponse.self, from: resp.body)
        let expiresMs = Flock.currentEpochMs() + Int64(max(tokens.expires_in ?? 2_592_000, 0) * 1000.0)
        return CredentialSchema.OAuth(
            methodID: current.methodID,
            refresh: tokens.refresh_token ?? current.refresh,
            access: tokens.access_token,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: current.metadata
        )
    }

    // MARK: - 7. GitLab Duo PKCE + Loopback Flow (`gitlab.ts`)

    private struct GitLabTokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
    }

    private func startGitLabPKCEFlow(
        integrationID: IntegrationID,
        methodID: IntegrationSchema.MethodID,
        answer: FormSchema.Answer,
        label: String?
    ) async throws -> IntegrationSchema.Attempt {
        let overrideClient = environment.variable("GITLAB_OAUTH_CLIENT_ID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = (overrideClient?.isEmpty == false) ? overrideClient! : ServerLiveOAuth.gitLabBundledClientID
        let rawInstance: String = {
            if case .string(let s) = answer["instanceUrl"], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return environment.variable("GITLAB_INSTANCE_URL") ?? "https://gitlab.com"
        }()
        let instanceURL = try ServerLiveOAuth.normalizeServerURL(rawInstance)
        let instanceHost = ServerParsedURL(instanceURL).host ?? "gitlab.com"

        let pkce = ServerLiveOAuth.generatePKCE(length: 43)
        let oauthState = ServerLiveOAuth.randomState()
        let attemptID = IntegrationSchema.AttemptID.create()
        let now = Double(Flock.currentEpochMs())
        let time = IntegrationSchema.AttemptTime(created: now, expires: now + 300_000)
        let key = attemptKey(integrationID, attemptID)
        let redirectBox = Mutex<String>("")

        let exchangeAndPersist: @Sendable (String, Bool) async throws -> Void = { [self] code, fromLoopback in
            let redirect = redirectBox.withLock { $0 }
            let formBody = ServerLiveOAuth.formURLEncode([
                ("grant_type", "authorization_code"),
                ("client_id", clientID),
                ("code", code),
                ("redirect_uri", redirect),
                ("code_verifier", pkce.verifier),
            ])
            let resp = try await httpTransport.send(HTTPRequest(
                method: "POST",
                url: "\(instanceURL)/oauth/token",
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                    "user-agent": userAgent,
                ],
                body: Array(formBody.utf8)
            ))
            guard (200..<300).contains(resp.head.statusCode) else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "GitLab token exchange failed (HTTP \(resp.head.statusCode))"
                )
            }
            let tokens = try ServerCodec.decode(GitLabTokenResponse.self, from: resp.body)
            let expiresMs = Flock.currentEpochMs() + Int64(max(tokens.expires_in ?? 7200, 0) * 1000.0)
            let oauth = CredentialSchema.OAuth(
                methodID: methodID,
                refresh: tokens.refresh_token,
                access: tokens.access_token,
                expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
                metadata: [
                    "instanceUrl": .string(instanceURL),
                    "clientID": .string(clientID),
                    "redirectURI": .string(redirect),
                ]
            )
            try await finalizeSuccess(
                integrationID: integrationID,
                attemptID: attemptID,
                oauth: oauth,
                derivedLabel: instanceHost,
                deferServerStop: fromLoopback
            )
        }

        let callbackServer = try startLoopbackServerIfAvailable(
            preferredPort: ServerLiveOAuth.gitLabCallbackPort,
            fallbackToEphemeral: true
        ) { [self] req in
            guard req.method == "GET", req.pathname == "/callback" else {
                return ServerHTTPResponse.empty(statusCode: 404)
            }
            if req.query("state") != oauthState {
                let msg = "Invalid OAuth state"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "GitLab")), statusCode: 400)
            }
            if let err = req.query("error_description") ?? req.query("error"), !err.isEmpty {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: err, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(err, options: .init(provider: "GitLab")), statusCode: 400)
            }
            guard let code = req.query("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                let msg = "Missing authorization code"
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "GitLab")), statusCode: 400)
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else {
                return ServerHTTPResponse.text("OAuth callback already received", statusCode: 409)
            }
            do {
                try await exchangeAndPersist(code, true)
                return Self.htmlResponse(CoreProvider.OAuthPage.success(.init(provider: "GitLab")), statusCode: 200)
            } catch {
                let msg = String(describing: error)
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg, deferServerStop: true)
                return Self.htmlResponse(CoreProvider.OAuthPage.error(msg, options: .init(provider: "GitLab")), statusCode: 400)
            }
        }

        let port = callbackServer?.address.port ?? ServerLiveOAuth.gitLabCallbackPort
        let redirect = "http://127.0.0.1:\(port)/callback"
        redirectBox.withLock { $0 = redirect }

        let authURL = ServerLiveOAuth.buildURL("\(instanceURL)/oauth/authorize", query: [
            ("client_id", clientID),
            ("redirect_uri", redirect),
            ("response_type", "code"),
            ("state", oauthState),
            ("scope", "api"),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
        ])

        let manualSubmit: @Sendable (String) async throws -> Void = { [self] input in
            let code: String
            if input.hasPrefix("http://") || input.hasPrefix("https://") {
                let parsed = try CoreProvider.OAuthRedirect.pasted(text: input, state: oauthState)
                switch parsed {
                case .error(let msg, _):
                    finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: msg)
                    throw CoreIntegration.Integration.AuthorizationError(message: msg)
                case .code(let parsedCode, _):
                    code = parsedCode
                }
            } else {
                code = input
            }
            guard claimPendingAttempt(integrationID: integrationID, attemptID: attemptID) else { return }
            do {
                try await exchangeAndPersist(code, false)
            } catch {
                finalizeFailure(integrationID: integrationID, attemptID: attemptID, message: String(describing: error))
                throw error
            }
        }

        state.withLock {
            $0.attempts[key] = ActiveAttempt(
                integrationID: integrationID,
                attemptID: attemptID,
                methodID: methodID,
                label: label,
                time: time,
                status: .pending(time: time),
                claimed: false,
                settled: false,
                pollTask: nil,
                callbackServer: callbackServer,
                manualSubmit: manualSubmit
            )
        }

        return IntegrationSchema.Attempt(
            attemptID: attemptID,
            url: authURL,
            instructions: "Complete authorization in your browser. This window will close automatically.",
            mode: callbackServer != nil ? .auto : .code,
            paste: true,
            time: time
        )
    }

    private func refreshGitLabToken(_ current: CredentialSchema.OAuth) async throws -> CredentialSchema.OAuth {
        let rawInstance: String = {
            if case .string(let s) = current.metadata?["instanceUrl"], !s.isEmpty { return s }
            return environment.variable("GITLAB_INSTANCE_URL") ?? "https://gitlab.com"
        }()
        let instanceURL = try ServerLiveOAuth.normalizeServerURL(rawInstance)
        let clientID: String = {
            if case .string(let s) = current.metadata?["clientID"], !s.isEmpty { return s }
            if let envID = environment.variable("GITLAB_OAUTH_CLIENT_ID")?.trimmingCharacters(in: .whitespacesAndNewlines), !envID.isEmpty {
                return envID
            }
            return ServerLiveOAuth.gitLabLegacyClientID
        }()
        let redirectURI: String = {
            if case .string(let s) = current.metadata?["redirectURI"], !s.isEmpty { return s }
            return "http://127.0.0.1:\(ServerLiveOAuth.gitLabCallbackPort)/callback"
        }()
        let formBody = ServerLiveOAuth.formURLEncode([
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refresh),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
        ])
        let resp = try await httpTransport.send(HTTPRequest(
            method: "POST",
            url: "\(instanceURL)/oauth/token",
            headers: [
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
                "user-agent": userAgent,
            ],
            body: Array(formBody.utf8)
        ))
        guard (200..<300).contains(resp.head.statusCode) else {
            throw CoreIntegration.Integration.AuthorizationError(
                message: "GitLab token refresh failed (HTTP \(resp.head.statusCode))"
            )
        }
        let tokens = try ServerCodec.decode(GitLabTokenResponse.self, from: resp.body)
        let expiresMs = Flock.currentEpochMs() + Int64(max(tokens.expires_in ?? 7200, 0) * 1000.0)
        return CredentialSchema.OAuth(
            methodID: current.methodID,
            refresh: tokens.refresh_token,
            access: tokens.access_token,
            expires: SchemaPrimitive.NonNegativeInt(rawValue: Int(max(0, expiresMs))) ?? .zero,
            metadata: [
                "instanceUrl": .string(instanceURL),
                "clientID": .string(clientID),
                "redirectURI": .string(redirectURI),
            ]
        )
    }

    // MARK: - Loopback Server Helper

    private func startLoopbackServerIfAvailable(
        preferredPort: Int,
        fallbackToEphemeral: Bool = false,
        handler: @escaping ServerHTTPHandler
    ) throws -> POSIXHTTPServer? {
        guard !workerdProfile else { return nil }
        do {
            return try POSIXHTTPServer.start(hostname: "127.0.0.1", port: preferredPort, handler: handler)
        } catch ServerTransportError.unsupportedPlatform {
            return nil
        } catch ServerTransportError.addressInUse {
            guard fallbackToEphemeral && preferredPort != 0 else {
                throw CoreIntegration.Integration.AuthorizationError(
                    message: "Local OAuth callback port \(preferredPort) is already in use"
                )
            }
            return try POSIXHTTPServer.start(hostname: "127.0.0.1", port: 0, handler: handler)
        }
    }
}
