import Testing
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

@Suite("OpenCodeServer Live OAuth, Console Sync, ModelsDev & Provider Model Discovery")
struct ServerLiveOAuthAndModelsTests {

    // MARK: - 1. All 7 Upstream OAuth Methods Registered

    @Test("Registers all 7 real upstream OAuth methods with exact labels and form schemas")
    func registersAllSevenUpstreamOAuthMethods() async throws {
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: false)
        defer { Task { await harness.close() } }

        let integrations = try await harness.client.integration.list().data
        let byID = Dictionary(uniqueKeysWithValues: integrations.map { ($0.id.rawValue, $0) })

        func oauthMethod(on id: String, methodID: String) -> IntegrationSchema.OAuthMethod? {
            byID[id]?.methods.compactMap { m -> IntegrationSchema.OAuthMethod? in
                if case .oauth(let o) = m, o.id.rawValue == methodID { return o }
                return nil
            }.first
        }

        // 1. OpenCode Console ('opencode'): device + hidden server field
        let opencodeInt = try #require(byID["opencode"])
        #expect(opencodeInt.name == "OpenCode Console")
        let opencodeOAuth = try #require(oauthMethod(on: "opencode", methodID: "device"))
        #expect(opencodeOAuth.label == "OpenCode Console account")
        let serverField = try #require(opencodeOAuth.form?.elements.first)
        if case .string(let sf) = serverField {
            #expect(sf.key == "server")
            #expect(sf.hidden == true)
            #expect(sf.format == .uri)
            #expect(sf.defaultValue == CoreProvider.ConsoleAccess.defaultServer)
        } else {
            Issue.record("Expected hidden string field 'server' on opencode OAuth form")
        }

        // 2. OpenAI ('openai'): chatgpt-token-sharing
        let openaiOAuth = try #require(oauthMethod(on: "openai", methodID: "chatgpt-token-sharing"))
        #expect(openaiOAuth.label == "Sign in with ChatGPT")

        // 3. GitHub Copilot ('github-copilot'): device + deploymentType & conditional enterpriseUrl form
        let copilotOAuth = try #require(oauthMethod(on: "github-copilot", methodID: "device"))
        #expect(copilotOAuth.label == "Login with GitHub Copilot")
        let copilotFields = try #require(copilotOAuth.form?.elements)
        #expect(copilotFields.count == 2)
        if case .string(let deployField) = copilotFields[0] {
            #expect(deployField.key == "deploymentType")
            #expect(deployField.required == true)
            let optionValues = deployField.options?.map(\.value) ?? []
            #expect(optionValues == ["github.com", "enterprise"])
        } else {
            Issue.record("Expected deploymentType string field on GitHub Copilot OAuth form")
        }
        if case .string(let entField) = copilotFields[1] {
            #expect(entField.key == "enterpriseUrl")
            #expect(entField.required == true)
            #expect(entField.when == [FormSchema.When(key: "deploymentType", op: .eq, value: .string("enterprise"))])
        } else {
            Issue.record("Expected conditional enterpriseUrl field on GitHub Copilot OAuth form")
        }

        // 4. xAI ('xai'): browser
        let xaiOAuth = try #require(oauthMethod(on: "xai", methodID: "browser"))
        #expect(xaiOAuth.label == "Login with xAI")

        // 5. Poe ('poe'): poe-browser
        let poeOAuth = try #require(oauthMethod(on: "poe", methodID: "poe-browser"))
        #expect(poeOAuth.label == "Login with Poe (browser)")

        // 6. DigitalOcean ('digitalocean'): digitalocean-oauth
        let doOAuth = try #require(oauthMethod(on: "digitalocean", methodID: "digitalocean-oauth"))
        #expect(doOAuth.label == "Login with DigitalOcean")

        // 7. GitLab Duo ('gitlab'): gitlab-oauth + instanceUrl form
        let gitlabInt = try #require(byID["gitlab"])
        #expect(gitlabInt.name == "GitLab Duo")
        let gitlabOAuth = try #require(oauthMethod(on: "gitlab", methodID: "gitlab-oauth"))
        #expect(gitlabOAuth.label == "Login with GitLab")
        let instanceField = try #require(gitlabOAuth.form?.elements.first)
        if case .string(let gf) = instanceField {
            #expect(gf.key == "instanceUrl")
            #expect(gf.defaultValue == "https://gitlab.com")
        } else {
            Issue.record("Expected instanceUrl field on GitLab OAuth form")
        }
    }

    // MARK: - 2. OpenCode Console Device OAuth + Polling + Live /api/v2/config Merge

    @Test("OpenCode Console device-code OAuth polls pending -> token, fetches user/orgs, syncs /api/v2/config workspace providers/models/skills, and emits bus events")
    func openCodeConsoleDeviceFlowAndWorkspaceConfigSync() async throws {
        let pollCounter = Mutex(0)
        let consoleServer = "https://console.acme.test"

        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: true) { req in
            if req.url == "\(consoleServer)/auth/device/code" && req.method == "POST" {
                return .json(body: """
                {
                  "device_code": "dev_code_console_1",
                  "user_code": "WXYZ-9876",
                  "verification_uri_complete": "\(consoleServer)/auth/verify?code=WXYZ-9876",
                  "expires_in": 600,
                  "interval": 0.01
                }
                """)
            }
            if req.url == "\(consoleServer)/auth/device/token" && req.method == "POST" {
                let n = pollCounter.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    return .json(status: 400, body: #"{"error":"authorization_pending"}"#)
                }
                return .json(body: """
                {
                  "access_token": "oc_access_live_123",
                  "refresh_token": "oc_refresh_live_456",
                  "expires_in": 3600,
                  "org_id": "org_acme_1"
                }
                """)
            }
            if req.url == "\(consoleServer)/api/user" && req.method == "GET" {
                return .json(body: #"{"id":"usr_42","email":"dev@acme.test"}"#)
            }
            if req.url == "\(consoleServer)/api/orgs" && req.method == "GET" {
                return .json(body: #"[{"id":"org_acme_1","name":"Acme Engineering"},{"id":"org_other","name":"Other Org"}]"#)
            }
            if req.url == "\(consoleServer)/api/v2/config" && req.method == "GET" {
                return .json(
                    headers: ["x-opencode-instructions-skills": "1"],
                    body: """
                    {
                      "providers": {
                        "acme-gateway": {
                          "name": "Acme AI Gateway",
                          "package": "@opencode/ai/providers/openai-compatible",
                          "settings": { "baseURL": "https://gateway.acme.test/v1" },
                          "models": {
                            "acme-coder-v2": {
                              "name": "Acme Coder v2",
                              "limit": { "context": 256000, "output": 32768 }
                            }
                          }
                        }
                      }
                    }
                    """
                )
            }
            if req.url == "\(consoleServer)/api/v2/instructions" && req.method == "GET" {
                return .json(body: #"{"instructions":[{"id":"inst_1","content":"Always write Swift 6 Sendable code."}]}"#)
            }
            if req.url == "\(consoleServer)/api/v2/skills" && req.method == "GET" {
                return .json(body: #"{"skills":[{"slug":"acme-deploy","version":"1"}]}"#)
            }
            if req.url == "\(consoleServer)/api/v2/skills/acme-deploy" && req.method == "GET" {
                return .json(body: """
                {
                  "slug": "acme-deploy",
                  "files": [
                    { "path": "SKILL.md", "content": "---\\nname: acme-deploy\\ndescription: Deploy via Acme Console\\n---\\nRun acme deploy." }
                  ]
                }
                """)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        // Boot location first so reload & bus events are observable
        _ = try await harness.client.integration.list()
        let recorder = LiveExecutionFixture.EventRecorder(bus: harness.runtime.bus)
        defer { recorder.stop() }

        let attempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "opencode",
            methodID: "device",
            answer: ["server": .string(consoleServer)]
        )).data
        #expect(attempt.mode == .auto)
        #expect(attempt.url == "\(consoleServer)/auth/verify?code=WXYZ-9876")
        #expect(attempt.instructions == "Enter code: WXYZ-9876")

        // Wait for background poller to complete authorization & sync Console config
        let completed = try await LiveOAuthFixture.waitUntil(timeoutMs: 3_000) {
            let status = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
                integrationID: "opencode",
                attemptID: attempt.attemptID.rawValue
            )).data
            if case .complete = status { return true }
            return false
        }
        #expect(completed)

        // Verify persisted real CredentialSchema.OAuth metadata & org label
        let creds = try await harness.runtime.credential.list(IntegrationID(rawValue: "opencode"))
        let saved = try #require(creds.last)
        #expect(saved.label == "Acme Engineering")
        if case .oauth(let oauth) = saved.value {
            #expect(oauth.access == "oc_access_live_123")
            #expect(oauth.refresh == "oc_refresh_live_456")
            #expect(oauth.metadata?["server"] == .string(consoleServer))
            #expect(oauth.metadata?["accountID"] == .string("usr_42"))
            #expect(oauth.metadata?["email"] == .string("dev@acme.test"))
            #expect(oauth.metadata?["orgID"] == .string("org_acme_1"))
            #expect(oauth.metadata?["orgName"] == .string("Acme Engineering"))
        } else {
            Issue.record("Expected CredentialSchema.OAuth persisted for opencode")
        }

        // Verify GET /api/v2/config was sent with Bearer token AND x-org-id header
        let configReq = try #require(harness.mockTransport.recordedRequests.first { $0.url == "\(consoleServer)/api/v2/config" })
        #expect(configReq.header("authorization") == "Bearer oc_access_live_123")
        #expect(configReq.header("x-org-id") == "org_acme_1")

        // Verify workspace provider, custom model, and skill are live via HTTP API
        let providers = try await harness.client.provider.list().data
        #expect(providers.contains { $0.id.rawValue == "acme-gateway" })
        let models = try await harness.client.model.list().data
        let acmeModel = try #require(models.first { $0.providerID.rawValue == "acme-gateway" && $0.id.rawValue == "acme-coder-v2" })
        #expect(acmeModel.name == "Acme Coder v2")
        #expect(acmeModel.limit.context == 256_000)
        #expect(acmeModel.limit.output == 32_768)

        let skills = try await harness.client.skill.list().data
        #expect(skills.contains { $0.id.rawValue == "acme-deploy" })

        // Verify catalog update events emitted on CoreBus
        let events = recorder.types()
        #expect(events.contains("integration.updated"))
        #expect(events.contains("provider.updated"))
        #expect(events.contains("model.updated"))
    }

    // MARK: - 3. OpenCode Console Signed-Out Free Public Zen Fallback

    @Test("Signed-out OpenCode Console enables public free models (cost.input == 0) while disabling paid models, and respects OPENCODE_DISABLE_FREE_MODELS")
    func openCodeFreePublicZenFallback() async throws {
        let catalogJSON = LiveOAuthFixture.sampleModelsDevCatalogJSON()

        // 1. Signed out (free models enabled by default)
        let signedOut = try await LiveOAuthFixture.makeHarness(
            env: [:],
            modelsFetch: false,
            initialFiles: [
                "/tmp/opencode-oauth-test/cache/models.json": LiveOAuthFixture.bytes(catalogJSON),
            ]
        )
        defer { Task { await signedOut.close() } }

        let providers = try await signedOut.client.provider.list().data
        let opencodeProv = try #require(providers.first { $0.id == .opencode })
        #expect(opencodeProv.activation == .enabled)
        #expect(opencodeProv.settings?.extra["apiKey"] == .string("public"))

        let models = try await signedOut.client.model.list().data
        let freeModel = models.first { $0.providerID == .opencode && $0.id.rawValue == "big-pickle" }
        let paidModel = models.first { $0.providerID == .opencode && $0.id.rawValue == "claude-sonnet-4-6" }
        #expect(freeModel != nil)
        #expect(paidModel == nil) // paid model disabled while signed out!

        // Connect an OpenCode Console API key -> paid models become enabled!
        try await signedOut.client.integration.connect.key(IntegrationConnectKeyInput(
            integrationID: "opencode",
            key: "oc_key_paid_1"
        ))
        let signedInModels = try await signedOut.client.model.list().data
        #expect(signedInModels.contains { $0.providerID == .opencode && $0.id.rawValue == "claude-sonnet-4-6" })

        // 2. OPENCODE_DISABLE_FREE_MODELS=true disables public free fallback
        let disabledFree = try await LiveOAuthFixture.makeHarness(
            env: ["OPENCODE_DISABLE_FREE_MODELS": "true"],
            modelsFetch: false,
            initialFiles: [
                "/tmp/opencode-oauth-test/cache/models.json": LiveOAuthFixture.bytes(catalogJSON),
            ]
        )
        defer { Task { await disabledFree.close() } }

        let disabledProviders = try await disabledFree.client.provider.list().data
        #expect(!disabledProviders.contains { $0.id == .opencode })
    }

    // MARK: - 4. GitHub Copilot Device OAuth + Entitlement + Live /models Discovery

    @Test("GitHub Copilot Enterprise device OAuth checks /copilot_internal/user, saves apiEndpoint, and discovers live /models routed via CopilotModels.routeFor")
    func githubCopilotDeviceOAuthAndLiveModelDiscovery() async throws {
        let pollCounter = Mutex(0)
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: true) { req in
            if req.url == "https://acme.ghe.com/login/device/code" && req.method == "POST" {
                return .json(body: """
                {
                  "verification_uri": "https://acme.ghe.com/login/device",
                  "user_code": "GHCP-1122",
                  "device_code": "gh_dev_1",
                  "interval": 0.01,
                  "expires_in": 900
                }
                """)
            }
            if req.url == "https://acme.ghe.com/login/oauth/access_token" && req.method == "POST" {
                let n = pollCounter.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    return .json(body: #"{"error":"authorization_pending"}"#)
                }
                return .json(body: #"{"access_token":"gho_copilot_live_token"}"#)
            }
            if req.url == "https://api.acme.ghe.com/copilot_internal/user" && req.method == "GET" {
                return .json(body: """
                {
                  "chat_enabled": true,
                  "endpoints": { "api": "https://copilot-api.acme.ghe.com/" }
                }
                """)
            }
            if req.url == "https://copilot-api.acme.ghe.com/models" && req.method == "GET" {
                return .json(body: """
                {
                  "data": [
                    {
                      "id": "claude-sonnet-4.6",
                      "name": "Claude Sonnet 4.6",
                      "version": "2026-02",
                      "model_picker_enabled": true,
                      "supported_endpoints": ["/v1/messages"],
                      "billing": { "auto_discount": 0.1 },
                      "capabilities": {
                        "family": "claude-sonnet",
                        "limits": { "max_context_window_tokens": 200000, "max_prompt_tokens": 180000, "max_output_tokens": 64000 },
                        "supports": { "tool_calls": true, "vision": true }
                      }
                    },
                    {
                      "id": "gpt-5.4",
                      "name": "GPT-5.4 Copilot",
                      "version": "2026-03",
                      "model_picker_enabled": true,
                      "supported_endpoints": ["/responses"],
                      "capabilities": {
                        "family": "gpt",
                        "limits": { "max_context_window_tokens": 400000, "max_prompt_tokens": 350000, "max_output_tokens": 128000 },
                        "supports": { "tool_calls": true, "vision": true }
                      }
                    }
                  ]
                }
                """)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        _ = try await harness.client.integration.list()

        let attempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "github-copilot",
            methodID: "device",
            answer: [
                "deploymentType": .string("enterprise"),
                "enterpriseUrl": .string("https://acme.ghe.com"),
            ]
        )).data
        #expect(attempt.mode == .auto)
        #expect(attempt.url == "https://acme.ghe.com/login/device")
        #expect(attempt.instructions == "Enter code: GHCP-1122")

        let done = try await LiveOAuthFixture.waitUntil(timeoutMs: 3_000) {
            let st = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
                integrationID: "github-copilot",
                attemptID: attempt.attemptID.rawValue
            )).data
            if case .complete = st { return true }
            return false
        }
        #expect(done)

        // Verify persisted Copilot credential metadata
        let creds = try await harness.runtime.credential.list(IntegrationID(rawValue: "github-copilot"))
        let saved = try #require(creds.last)
        if case .oauth(let oauth) = saved.value {
            #expect(oauth.access == "gho_copilot_live_token")
            #expect(oauth.metadata?["enterpriseUrl"] == .string("acme.ghe.com"))
            #expect(oauth.metadata?["apiEndpoint"] == .string("https://copilot-api.acme.ghe.com"))
        } else {
            Issue.record("Expected OAuth credential for github-copilot")
        }

        // Verify live /models discovery & CoreModel.CopilotModels.routeFor routing
        let models = try await harness.client.model.list().data
        let claude = try #require(models.first { $0.providerID == .githubCopilot && $0.id.rawValue == "claude-sonnet-4.6" })
        #expect(claude.package == "@opencode/ai/providers/anthropic")
        #expect(claude.settings?.extra["baseURL"] == .string("https://copilot-api.acme.ghe.com/v1"))

        let gpt5 = try #require(models.first { $0.providerID == .githubCopilot && $0.id.rawValue == "gpt-5.4" })
        #expect(gpt5.package == "@opencode/ai/providers/openai-compatible-responses")
        #expect(gpt5.settings?.extra["baseURL"] == .string("https://copilot-api.acme.ghe.com"))

        // Auto router model synthesized because billing.auto_discount was present
        #expect(models.contains { $0.providerID == .githubCopilot && $0.id == CoreModel.CopilotModels.auto })

        // Verify Copilot headers were sent on /models
        let modelsReq = try #require(harness.mockTransport.recordedRequests.first { $0.url == "https://copilot-api.acme.ghe.com/models" })
        #expect(modelsReq.header("copilot-integration-id") == "vscode-chat")
        #expect(modelsReq.header("openai-intent") == "conversation-edits")
        #expect(modelsReq.header("editor-version") == "vscode/1.99.0")
    }

    // MARK: - 5. ChatGPT PKCE Loopback Callback + Live /codex/models + Manual /complete

    @Test("ChatGPT PKCE S256 serves real ephemeral loopback POSIXHTTPServer HTML callback, exchanges token, discovers /codex/models, and supports manual /complete")
    func chatGPTPKCELoopbackAndCodexModelDiscovery() async throws {
        let capturedNonce = Mutex<String?>(nil)
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: true) { req in
            if req.url == ServerLiveOAuth.chatGPTTokenURL && req.method == "POST" {
                let nonce = capturedNonce.withLock { $0 } ?? ""
                let idToken = LiveOAuthFixture.makeJWT(payload: [
                    "sub": .string("user_openai_77"),
                    "nonce": .string(nonce),
                    "chatgpt_account_id": .string("acct_chatgpt_live_99"),
                ])
                return .json(body: """
                {
                  "access_token": "cgpt_access_tok_1",
                  "refresh_token": "cgpt_refresh_tok_1",
                  "id_token": "\(idToken)",
                  "expires_in": 3600,
                  "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
                }
                """)
            }
            if req.url == ServerLiveOAuth.chatGPTCodexModelsURL && req.method == "GET" {
                return .json(body: """
                {
                  "models": [
                    {
                      "slug": "gpt-5.3-codex",
                      "display_name": "GPT-5.3 Codex Live",
                      "visibility": "list",
                      "supported_in_api": true,
                      "context_window": 400000,
                      "input_modalities": ["text", "image"],
                      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]
                    }
                  ]
                }
                """)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        _ = try await harness.client.integration.list()

        let attempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "openai",
            methodID: "chatgpt-token-sharing"
        )).data
        #expect(attempt.mode == .auto)

        let parsedAuth = ServerParsedURL(attempt.url)
        #expect(parsedAuth.host == "auth.openai.com")
        #expect(parsedAuth.queryValue(for: "client_id") == "dynamic_agent_client")
        #expect(parsedAuth.queryValue(for: "code_challenge_method") == "S256")
        let challenge = try #require(parsedAuth.queryValue(for: "code_challenge"))
        let state = try #require(parsedAuth.queryValue(for: "state"))
        let nonce = try #require(parsedAuth.queryValue(for: "nonce"))
        let redirectURI = try #require(parsedAuth.queryValue(for: "redirect_uri"))
        #expect(redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(redirectURI.hasSuffix("/auth/callback"))
        #expect(parsedAuth.queryValue(for: "scope")?.contains("chatgpt.tokens.use.direct") == true)
        capturedNonce.withLock { $0 = nonce }

        // Hit the REAL ephemeral loopback POSIXHTTPServer!
        let callbackURL = "\(redirectURI)?code=cgpt_auth_code_42&state=\(ServerParsedURL.encodeURIComponent(state))&client_id=dyn_client_77"
        let htmlResp = try await LiveOAuthFixture.sendRealLoopbackGET(callbackURL)
        #expect(htmlResp.status == 200)
        #expect(htmlResp.contentType?.contains("text/html") == true)
        #expect(htmlResp.body.contains("Authorization successful"))
        #expect(htmlResp.body.contains("ChatGPT"))

        // Verify attempt status became .complete
        let finalStatus = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
            integrationID: "openai",
            attemptID: attempt.attemptID.rawValue
        )).data
        let isComplete: Bool
        if case .complete = finalStatus { isComplete = true } else { isComplete = false }
        #expect(isComplete)

        // Verify token exchange carried real PKCE S256 code_verifier matching code_challenge!
        let tokenReq = try #require(harness.mockTransport.recordedRequests.first { $0.url == ServerLiveOAuth.chatGPTTokenURL })
        let formParams = LiveOAuthFixture.parseFormParams(tokenReq.bodyText)
        #expect(formParams["grant_type"] == "authorization_code")
        #expect(formParams["client_id"] == "dyn_client_77")
        #expect(formParams["code"] == "cgpt_auth_code_42")
        let verifier = try #require(formParams["code_verifier"])
        #expect(LiveOAuthFixture.s256Challenge(for: verifier) == challenge)

        // Verify live GET https://chatgpt.com/backend-api/codex/models merged gpt-5.3-codex!
        let codexReq = try #require(harness.mockTransport.recordedRequests.first { $0.url == ServerLiveOAuth.chatGPTCodexModelsURL })
        #expect(codexReq.header("authorization") == "Bearer cgpt_access_tok_1")
        #expect(codexReq.header("chatgpt-account-id") == "acct_chatgpt_live_99")

        let models = try await harness.client.model.list().data
        let codexModel = try #require(models.first { $0.providerID == .openai && $0.id.rawValue == "gpt-5.3-codex" })
        #expect(codexModel.name == "GPT-5.3 Codex Live")
        #expect(codexModel.cost.isEmpty)
        #expect(codexModel.variants.map(\.id.rawValue) == ["low", "high"])

        // Also test manual pasted callback URL via POST /complete on a second attempt
        let manualAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "openai",
            methodID: "chatgpt-token-sharing"
        )).data
        let manualParsed = ServerParsedURL(manualAttempt.url)
        let manualState = try #require(manualParsed.queryValue(for: "state"))
        let manualNonce = try #require(manualParsed.queryValue(for: "nonce"))
        let manualRedirect = try #require(manualParsed.queryValue(for: "redirect_uri"))
        capturedNonce.withLock { $0 = manualNonce }

        try await harness.client.integration.oauth.complete(IntegrationOauthCompleteInput(
            integrationID: "openai",
            attemptID: manualAttempt.attemptID.rawValue,
            code: "\(manualRedirect)?code=manual_code_9&state=\(ServerParsedURL.encodeURIComponent(manualState))"
        ))
        let manualStatus = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
            integrationID: "openai",
            attemptID: manualAttempt.attemptID.rawValue
        )).data
        let manualDone: Bool
        if case .complete = manualStatus { manualDone = true } else { manualDone = false }
        #expect(manualDone)
    }

    // MARK: - 6. xAI Device Flow + Poe, DigitalOcean & GitLab PKCE Flows

    @Test("Executes real xAI device-code OAuth and real Poe, DigitalOcean, and GitLab PKCE OAuth flows with manual complete and clean cancel")
    func xaiPoeDigitalOceanAndGitLabOAuthFlows() async throws {
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: false) { req in
            if req.url == "\(ServerLiveOAuth.xaiIssuer)/device/code" && req.method == "POST" {
                return .json(body: """
                {
                  "device_code": "xai_dev_1",
                  "user_code": "XAI-7777",
                  "verification_uri": "https://auth.x.ai/activate",
                  "verification_uri_complete": "https://auth.x.ai/activate?user_code=XAI-7777",
                  "expires_in": 300,
                  "interval": 0.01
                }
                """)
            }
            if req.url == "\(ServerLiveOAuth.xaiIssuer)/token" && req.method == "POST" {
                return .json(body: #"{"access_token":"xai_live_tok","refresh_token":"xai_live_ref","expires_in":3600}"#)
            }
            if req.url == ServerLiveOAuth.poeTokenURL && req.method == "POST" {
                return .json(body: #"{"api_key":"poe_live_key_123","api_key_expires_in":86400}"#)
            }
            if req.url == ServerLiveOAuth.digitalOceanTokenURL && req.method == "POST" {
                return .json(body: #"{"access_token":"do_live_tok_456","refresh_token":"do_live_ref_456","expires_in":3600}"#)
            }
            if req.url == "https://gitlab.acme.internal/oauth/token" && req.method == "POST" {
                return .json(body: #"{"access_token":"gl_live_tok_789","refresh_token":"gl_live_ref_789","expires_in":7200}"#)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        _ = try await harness.client.integration.list()

        // 1. xAI device-code flow
        let xaiAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "xai",
            methodID: "browser"
        )).data
        #expect(xaiAttempt.mode == .auto)
        #expect(xaiAttempt.url == "https://auth.x.ai/activate?user_code=XAI-7777")
        let xaiDone = try await LiveOAuthFixture.waitUntil(timeoutMs: 3_000) {
            let st = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
                integrationID: "xai",
                attemptID: xaiAttempt.attemptID.rawValue
            )).data
            if case .complete = st { return true }
            return false
        }
        #expect(xaiDone)

        // 2. Poe PKCE flow
        let poeAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "poe",
            methodID: "poe-browser"
        )).data
        let poeURL = ServerParsedURL(poeAttempt.url)
        #expect(poeURL.host == "poe.com")
        #expect(poeURL.queryValue(for: "code_challenge_method") == "S256")
        try await harness.client.integration.oauth.complete(IntegrationOauthCompleteInput(
            integrationID: "poe",
            attemptID: poeAttempt.attemptID.rawValue,
            code: "poe_code_1"
        ))
        let poeCreds = try await harness.runtime.credential.list(IntegrationID(rawValue: "poe"))
        if case .oauth(let o) = poeCreds.last?.value {
            #expect(o.access == "poe_live_key_123")
        } else {
            Issue.record("Expected Poe OAuth credential saved")
        }

        // 3. DigitalOcean PKCE flow
        let doAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "digitalocean",
            methodID: "digitalocean-oauth"
        )).data
        let doURL = ServerParsedURL(doAttempt.url)
        #expect(doURL.host == "cloud.digitalocean.com")
        #expect(doURL.pathname == "/v1/oauth/authorize")
        #expect(doURL.queryValue(for: "code_challenge_method") == "S256")
        try await harness.client.integration.oauth.complete(IntegrationOauthCompleteInput(
            integrationID: "digitalocean",
            attemptID: doAttempt.attemptID.rawValue,
            code: "do_code_1"
        ))
        let doCreds = try await harness.runtime.credential.list(IntegrationID(rawValue: "digitalocean"))
        if case .oauth(let o) = doCreds.last?.value {
            #expect(o.access == "do_live_tok_456")
        } else {
            Issue.record("Expected DigitalOcean OAuth credential saved")
        }

        // 4. GitLab Duo PKCE flow with custom instanceUrl
        let glAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "gitlab",
            methodID: "gitlab-oauth",
            answer: ["instanceUrl": .string("https://gitlab.acme.internal")]
        )).data
        let glURL = ServerParsedURL(glAttempt.url)
        #expect(glURL.host == "gitlab.acme.internal")
        #expect(glURL.pathname == "/oauth/authorize")
        #expect(glURL.queryValue(for: "code_challenge_method") == "S256")
        try await harness.client.integration.oauth.complete(IntegrationOauthCompleteInput(
            integrationID: "gitlab",
            attemptID: glAttempt.attemptID.rawValue,
            code: "gl_code_1"
        ))
        let glCreds = try await harness.runtime.credential.list(IntegrationID(rawValue: "gitlab"))
        if case .oauth(let o) = glCreds.last?.value {
            #expect(o.access == "gl_live_tok_789")
            #expect(o.metadata?["instanceUrl"] == .string("https://gitlab.acme.internal"))
        } else {
            Issue.record("Expected GitLab OAuth credential saved")
        }

        // 5. Cancel cleans up pending attempt & stops loopback server
        let cancelAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "poe",
            methodID: "poe-browser"
        )).data
        try await harness.client.integration.oauth.cancel(IntegrationOauthCancelInput(
            integrationID: "poe",
            attemptID: cancelAttempt.attemptID.rawValue
        ))
        #expect(!harness.runtime.oauthManager.hasAttempt(
            integrationID: IntegrationID(rawValue: "poe"),
            attemptID: cancelAttempt.attemptID
        ))
    }

    // MARK: - 7. OAuth Auto-Refresh on Expired Token Before Live LLM Call + Provider Headers

    @Test("Auto-refreshes expired OAuth tokens before live LLM calls (persisting to SQLite) and attaches x-org-id, ChatGPT-Account-ID, and Copilot headers")
    func oauthAutoRefreshBeforeLLMCallAndProviderHeaders() async throws {
        let consoleServer = "https://console.refresh.test"
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: false) { req in
            // 1. OpenCode Console token refresh
            if req.url == "\(consoleServer)/auth/device/token" && req.method == "POST" {
                return .json(body: """
                {
                  "access_token": "oc_refreshed_access_999",
                  "refresh_token": "oc_refreshed_refresh_999",
                  "expires_in": 7200
                }
                """)
            }
            // 2. ChatGPT OpenAI token refresh
            if req.url == ServerLiveOAuth.chatGPTTokenURL && req.method == "POST" {
                return .json(body: """
                {
                  "access_token": "cgpt_refreshed_access_888",
                  "refresh_token": "cgpt_refreshed_refresh_888",
                  "expires_in": 7200
                }
                """)
            }
            // 3. LLM endpoints
            if req.url.contains("opencode.ai/zen/v1/responses") || req.url.contains("api.openai.com/v1/responses") {
                return .sse(chunks: LiveOAuthFixture.openAIResponsesSSE(text: "Refreshed token succeeded!"))
            }
            if req.url.contains("api.githubcopilot.com") {
                return .sse(chunks: LiveOAuthFixture.openAIResponsesSSE(text: "Copilot headers verified!"))
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        let expiredMs = SchemaPrimitive.NonNegativeInt(rawValue: Int(max(1, Flock.currentEpochMs() - 10_000)))!

        // Seed expired OpenCode Console OAuth credential
        let ocCred = try await harness.runtime.credential.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "opencode"),
            value: .oauth(CredentialSchema.OAuth(
                methodID: ServerLiveOAuth.openCodeMethodID,
                refresh: "oc_stale_refresh",
                access: "oc_stale_access",
                expires: expiredMs,
                metadata: [
                    "server": .string(consoleServer),
                    "orgID": .string("org_refresh_42"),
                ]
            )),
            label: "Refresh Org",
            activate: true
        )

        // Seed expired ChatGPT OAuth credential
        let gptCred = try await harness.runtime.credential.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "openai"),
            value: .oauth(CredentialSchema.OAuth(
                methodID: ServerLiveOAuth.chatGPTMethodID,
                refresh: "cgpt_stale_refresh",
                access: "cgpt_stale_access",
                expires: expiredMs,
                metadata: [
                    "clientID": .string("cid_chatgpt_1"),
                    "accountID": .string("acct_live_header_77"),
                ]
            )),
            label: "ChatGPT Account",
            activate: true
        )

        // Seed active GitHub Copilot OAuth credential
        _ = try await harness.runtime.credential.create(
            id: nil,
            integrationID: IntegrationID(rawValue: "github-copilot"),
            value: .oauth(CredentialSchema.OAuth(
                methodID: ServerLiveOAuth.copilotMethodID,
                refresh: "gho_copilot_tok",
                access: "gho_copilot_tok",
                expires: .zero
            )),
            label: "Copilot",
            activate: true
        )

        // A. Prompt against `opencode/gpt-5.4` -> refreshes expired token, persists to SQLite, sends x-org-id
        let ocSession = try await harness.client.session.create(SessionCreateInput(
            title: "OpenCode Refresh Test",
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "gpt-5.4"), providerID: .opencode)
        ))
        _ = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: ocSession.id.rawValue,
            text: "Hello OpenCode"
        ))
        await harness.runtime.sessionExecution.awaitIdle(ocSession.id)

        let ocLLMReq = try #require(harness.mockTransport.recordedRequests.first { $0.url.contains("opencode.ai/zen/v1/responses") })
        #expect(ocLLMReq.header("authorization") == "Bearer oc_refreshed_access_999")
        #expect(ocLLMReq.header("x-org-id") == "org_refresh_42")

        // Confirm refreshed token persisted in SQLite!
        let persistedOC = try #require(try await harness.runtime.credential.get(ocCred.id))
        if case .oauth(let o) = persistedOC.value {
            #expect(o.access == "oc_refreshed_access_999")
            #expect(o.refresh == "oc_refreshed_refresh_999")
            #expect(Int64(o.expires.rawValue) > Flock.currentEpochMs() + 60_000)
        } else {
            Issue.record("Expected persisted refreshed OAuth credential for opencode")
        }

        // B. Prompt against `openai/gpt-5.4` -> refreshes expired ChatGPT token & attaches ChatGPT-Account-ID
        let gptSession = try await harness.client.session.create(SessionCreateInput(
            title: "ChatGPT Refresh Test",
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "gpt-5.4"), providerID: .openai)
        ))
        _ = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: gptSession.id.rawValue,
            text: "Hello ChatGPT"
        ))
        await harness.runtime.sessionExecution.awaitIdle(gptSession.id)

        let gptLLMReq = try #require(harness.mockTransport.recordedRequests.first { $0.url.contains("api.openai.com/v1/responses") })
        #expect(gptLLMReq.header("authorization") == "Bearer cgpt_refreshed_access_888")
        #expect(gptLLMReq.header("chatgpt-account-id") == "acct_live_header_77")

        let persistedGPT = try #require(try await harness.runtime.credential.get(gptCred.id))
        if case .oauth(let o) = persistedGPT.value {
            #expect(o.access == "cgpt_refreshed_access_888")
            #expect(o.refresh == "cgpt_refreshed_refresh_888")
        } else {
            Issue.record("Expected persisted refreshed OAuth credential for openai")
        }

        // C. Prompt against `github-copilot/gpt-5.4` -> attaches Copilot-Integration-Id / Openai-Intent / Editor-Version
        let cpSession = try await harness.client.session.create(SessionCreateInput(
            title: "Copilot Headers Test",
            model: ModelSchema.Ref(id: ModelSchema.ID(rawValue: "gpt-5.4"), providerID: .githubCopilot)
        ))
        _ = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: cpSession.id.rawValue,
            text: "Hello Copilot"
        ))
        await harness.runtime.sessionExecution.awaitIdle(cpSession.id)

        let cpLLMReq = try #require(harness.mockTransport.recordedRequests.first { $0.url.contains("api.githubcopilot.com") })
        #expect(cpLLMReq.header("authorization") == "Bearer gho_copilot_tok")
        #expect(cpLLMReq.header("copilot-integration-id") == "vscode-chat")
        #expect(cpLLMReq.header("openai-intent") == "conversation-edits")
        #expect(cpLLMReq.header("editor-version") == "vscode/1.99.0")
    }

    // MARK: - 8. Live ModelsDev Catalog Merge, Reload Force-Refresh & Local Model Discovery

    @Test("Fetches live ModelsDev catalog into KV + disk cache, force-refreshes on POST /api/location/reload, and discovers local Ollama/LM Studio/vLLM models")
    func liveModelsDevMergeReloadAndLocalDiscovery() async throws {
        let catalogVersion = Mutex(1)
        let modelsOrigin = "https://models.mock.test"

        let harness = try await LiveOAuthFixture.makeHarness(
            env: [
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "COHERE_API_KEY": "cohere-live-key",
            ],
            modelsFetch: true,
            modelsURL: modelsOrigin
        ) { req in
            if req.url == "\(modelsOrigin)\(CoreModel.ModelsDev.catalogPath)" {
                let v = catalogVersion.withLock { $0 }
                let json = v == 1
                    ? LiveOAuthFixture.sampleModelsDevCatalogJSON()
                    : LiveOAuthFixture.sampleModelsDevCatalogJSON(extraCohereModelID: "command-r-reloaded-v2")
                return .json(body: json)
            }
            if req.url == "http://127.0.0.1:11434/api/tags" {
                return .json(body: """
                {
                  "models": [
                    { "name": "Qwen 3 Local", "model": "qwen3:32b", "details": { "family": "qwen" } }
                  ]
                }
                """)
            }
            if req.url == "http://127.0.0.1:1234/v1/models" {
                return .json(body: #"{"data":[{"id":"lmstudio-deepseek-r1","owned_by":"lmstudio"}]}"#)
            }
            if req.url == "http://127.0.0.1:8000/v1/models" {
                return .json(body: #"{"data":[{"id":"vllm-llama-4","owned_by":"vllm","max_model_len":65536}]}"#)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        // 1. Live ModelsDev catalog fetched, merged without hiding built-ins, persisted to KV & disk cache!
        let models = try await harness.client.model.list().data
        #expect(models.contains { $0.providerID.rawValue == "cohere" && $0.id.rawValue == "command-a-live" })
        #expect(models.contains { $0.providerID == .anthropic && $0.id.rawValue == "claude-4-7-live" })
        #expect(models.contains { $0.providerID == .anthropic && $0.id.rawValue == "claude-sonnet-4-6" }) // built-in preserved!

        let kvCatalog = try await harness.runtime.kv.get(ServerLiveRuntime.modelsDevCatalogKVKey)
        #expect(kvCatalog != nil)
        let diskExists = await harness.fileSystem.exists(at: "\(harness.globalCache)/models.json")
        #expect(diskExists)

        // 2. Local models (Ollama, LM Studio, vLLM) discovered and activated!
        let providers = try await harness.client.provider.list().data
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id.rawValue, $0) })
        #expect(providerByID["ollama"]?.activation == .enabled)
        #expect(providerByID["lmstudio"]?.activation == .enabled)
        #expect(providerByID["vllm"]?.activation == .enabled)

        #expect(models.contains { $0.providerID.rawValue == "ollama" && $0.id.rawValue == "qwen3:32b" })
        #expect(models.contains { $0.providerID.rawValue == "lmstudio" && $0.id.rawValue == "lmstudio-deepseek-r1" })
        let vllmModel = try #require(models.first { $0.providerID.rawValue == "vllm" && $0.id.rawValue == "vllm-llama-4" })
        #expect(vllmModel.limit.context == 65_536)

        // 3. POST /api/location/reload force-refreshes ModelsDev catalog & picks up newly published model!
        catalogVersion.withLock { $0 = 2 }
        try await harness.client.location.reload()

        let reloadedModels = try await harness.client.model.list().data
        #expect(reloadedModels.contains { $0.providerID.rawValue == "cohere" && $0.id.rawValue == "command-r-reloaded-v2" })
    }

    @Test("Non-blocking background ModelsDev refresh updates stale cache, reloads locations, and emits catalog update events")
    func backgroundModelsDevRefreshUpdatesStaleCache() async throws {
        let modelsOrigin = "https://models.stale.test"
        let staleCatalogJSON = LiveOAuthFixture.sampleModelsDevCatalogJSON()
        let freshCatalogJSON = LiveOAuthFixture.sampleModelsDevCatalogJSON(extraCohereModelID: "command-bg-fresh")

        let harness = try await LiveOAuthFixture.makeHarness(
            env: ["COHERE_API_KEY": "cohere-stale-key"],
            modelsFetch: true,
            modelsURL: modelsOrigin,
            initialFiles: [
                "/tmp/opencode-oauth-test/cache/models.json": LiveOAuthFixture.bytes(staleCatalogJSON),
            ]
        ) { req in
            if req.url == "\(modelsOrigin)\(CoreModel.ModelsDev.catalogPath)" {
                return .json(body: freshCatalogJSON)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        // Seed stale metadata (2 hours old) in KV so initial boot serves disk cache immediately & triggers background refresh
        try await harness.runtime.kv.set(ServerLiveRuntime.modelsDevMetaKVKey, value: .object([
            "updatedAt": .int(Flock.currentEpochMs() - 7_200_000),
            "digest": .string(CoreModel.ModelsDev.bodyDigest(staleCatalogJSON)),
        ]))

        let recorder = LiveExecutionFixture.EventRecorder(bus: harness.runtime.bus)
        defer { recorder.stop() }

        // Initial call returns immediately with cached catalog
        let initial = try await harness.client.model.list().data
        #expect(initial.contains { $0.providerID.rawValue == "cohere" && $0.id.rawValue == "command-a-live" })

        // Background task updates cache & reloads location with fresh model
        let refreshed = try await LiveOAuthFixture.waitUntil(timeoutMs: 3_000) {
            let current = try await harness.client.model.list().data
            return current.contains { $0.providerID.rawValue == "cohere" && $0.id.rawValue == "command-bg-fresh" }
        }
        #expect(refreshed)

        let events = recorder.types()
        #expect(events.contains("integration.updated"))
        #expect(events.contains("provider.updated"))
        #expect(events.contains("model.updated"))
    }

    @Test("Handles Copilot entitlement denial and ChatGPT loopback invalid-state error HTML cleanly")
    func copilotEntitlementDenialAndChatGPTLoopbackErrorHTML() async throws {
        let harness = try await LiveOAuthFixture.makeHarness(modelsFetch: false) { req in
            if req.url == "https://github.com/login/device/code" && req.method == "POST" {
                return .json(body: """
                {
                  "verification_uri": "https://github.com/login/device",
                  "user_code": "DENY-0001",
                  "device_code": "gh_deny_1",
                  "interval": 0.01,
                  "expires_in": 900
                }
                """)
            }
            if req.url == "https://github.com/login/oauth/access_token" && req.method == "POST" {
                return .json(body: #"{"access_token":"gho_no_copilot_seat"}"#)
            }
            if req.url == "https://api.github.com/copilot_internal/user" && req.method == "GET" {
                return .json(body: #"{"chat_enabled":false,"can_signup_for_limited":true}"#)
            }
            return .json(status: 404, body: "{}")
        }
        defer { Task { await harness.close() } }

        _ = try await harness.client.integration.list()

        // 1. Copilot entitlement denial transitions attempt to .failed with signup guidance
        let copilotAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "github-copilot",
            methodID: "device",
            answer: ["deploymentType": .string("github.com")]
        )).data
        let failed = try await LiveOAuthFixture.waitUntil(timeoutMs: 3_000) {
            let st = try await harness.client.integration.oauth.status(IntegrationOauthStatusInput(
                integrationID: "github-copilot",
                attemptID: copilotAttempt.attemptID.rawValue
            )).data
            if case .failed(let msg, _) = st {
                return msg.contains("https://github.com/features/copilot/plans")
            }
            return false
        }
        #expect(failed)

        // 2. ChatGPT loopback callback with wrong state returns HTTP 400 OAuthPage.error HTML
        let gptAttempt = try await harness.client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: "openai",
            methodID: "chatgpt-token-sharing"
        )).data
        let parsed = ServerParsedURL(gptAttempt.url)
        let redirectURI = try #require(parsed.queryValue(for: "redirect_uri"))
        let errResp = try await LiveOAuthFixture.sendRealLoopbackGET("\(redirectURI)?code=abc&state=wrong-state")
        #expect(errResp.status == 400)
        #expect(errResp.contentType?.contains("text/html") == true)
        #expect(errResp.body.contains("Authorization failed"))
        #expect(errResp.body.contains("Invalid OAuth state"))
    }
}
