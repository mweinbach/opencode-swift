import Synchronization
import Testing
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView

@Suite("TUI Live OAuth Flows, Form Prompts, Browser Launch & Large Live Model Catalog")
struct TUILiveOAuthAndModelsTests {

    // MARK: - 1. GitHub Copilot OAuth Form (github.com) -> Device-Code Polling -> Browser Launch -> Model Refresh

    @Test("GitHub Copilot OAuth form (github.com) skips enterpriseUrl, launches browser, polls to complete, refreshes live models, and shows confirmation toast")
    func githubCopilotGitHubComAutoPollingFlow() async {
        let pollCount = Mutex(0)
        let isConnected = Mutex(false)
        let capturedConnectBody = Mutex<[String: JSONValue]?>(nil)
        let cancelCalled = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/github-copilot/connect/oauth") && !req.url.contains("/complete") {
                capturedConnectBody.withLock { $0 = TUILiveOAuthFixtures.decodeJSONObject(req.body) }
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_gh_public_1","url":"https://github.com/login/device","instructions":"Open GitHub and enter code: R283-GOUEO","mode":"auto","time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/github-copilot/connect/oauth/con_gh_public_1") {
                let n = pollCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if n < 3 {
                    return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "pending"))
                }
                isConnected.withLock { $0 = true }
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "complete"))
            }
            if req.method == "DELETE" && req.url.contains("/api/integration/github-copilot/connect/oauth/con_gh_public_1") {
                cancelCalled.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            let connected = isConnected.withLock { $0 }
            if req.method == "GET" && req.url.contains("/api/integration") {
                let conns = connected
                    ? #"[{"type":"credential","id":"cred_gh1","label":"GitHub Copilot","method":"device"}]"#
                    : "[]"
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":[{"id":"github-copilot","name":"GitHub Copilot","methods":[{"type":"oauth","id":"device","label":"Login with GitHub Copilot"}],"connections":\(conns)}]}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/provider") {
                let data = connected ? "[\(TUILiveOAuthFixtures.providerJSON(id: "github-copilot", name: "GitHub Copilot"))]" : "[]"
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(data)}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                let data = connected
                    ? TUILiveOAuthFixtures.modelJSON(id: "claude-sonnet-4-6", providerID: "github-copilot", name: "Claude Sonnet 4.6 (Copilot)")
                    : "null"
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(data)}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                let data = connected
                    ? "[\(TUILiveOAuthFixtures.modelJSON(id: "claude-sonnet-4-6", providerID: "github-copilot", name: "Claude Sonnet 4.6 (Copilot)")),\(TUILiveOAuthFixtures.modelJSON(id: "gpt-5", providerID: "github-copilot", name: "GPT-5 (Copilot)"))]"
                    : "[]"
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(data)}"#)
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [TUILiveOAuthFixtures.githubCopilotIntegration()])
        let harness = TUILiveOAuthHarness(state: state, transport: transport, oauthPollInterval: .milliseconds(15))
        defer { harness.destroy() }

        // Open Connect Provider dialog and select GitHub Copilot
        harness.controller.openDialog(.connectProvider)
        #expect(harness.frame().contains("GitHub Copilot"))
        harness.testRenderer.mockInput.pressEnter()

        // Step 1: Prompts for deploymentType form choices (GitHub.com vs GitHub Enterprise)
        let formSnap = harness.store.snapshot()
        #expect(formSnap.activeDialog == .connectMethod)
        #expect(formSnap.connectFormState != nil)
        let formFrame = harness.frame()
        #expect(formFrame.contains("Select GitHub deployment type"))
        #expect(formFrame.contains("GitHub.com"))
        #expect(formFrame.contains("GitHub Enterprise"))

        // Select GitHub.com (index 0) -> skips enterpriseUrl -> starts OAuth flow immediately
        harness.testRenderer.mockInput.pressEnter()

        // Wait for polling completion -> live model refresh -> model picker transition
        let completed = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().activeDialog == .modelPicker && harness.store.snapshot().models.count == 2
        }
        #expect(completed)

        // Verify POST /connect/oauth payload had methodID="device" and answer={"deploymentType":"github.com"} only
        let body = capturedConnectBody.withLock { $0 }
        #expect(body?["methodID"] == .string("device"))
        if case .object(let answer) = body?["answer"] {
            #expect(answer["deploymentType"] == .string("github.com"))
            #expect(answer["enterpriseUrl"] == nil)
        } else {
            Issue.record("Expected answer object in OAuth connect request")
        }

        // Verify browser was launched automatically with verification URL
        #expect(harness.launchedURLs == ["https://github.com/login/device"])

        // Verify multiple polls occurred and attempt was NOT cancelled after completion
        #expect(pollCount.withLock { $0 } >= 3)
        #expect(cancelCalled.withLock { $0 } == false)

        // Verify integrations, providers, models reloaded and confirmation toast was set
        let after = harness.store.snapshot()
        #expect(after.activeDialog == .modelPicker)
        #expect(after.modelPickerProviderID == "github-copilot")
        #expect(after.providers["github-copilot"] == "GitHub Copilot")
        #expect(after.models.contains(where: { $0.id == "claude-sonnet-4-6" && $0.providerID == "github-copilot" }))
        #expect(after.models.contains(where: { $0.id == "gpt-5" && $0.providerID == "github-copilot" }))
        #expect(after.toastMessage == "Connected GitHub Copilot")
        #expect(after.toastIsError == false)
        #expect(harness.frame().contains("Claude Sonnet 4.6 (Copilot)"))
    }

    // MARK: - 2. GitHub Copilot OAuth Form (GitHub Enterprise + Enterprise URL validation & back-step)

    @Test("GitHub Copilot OAuth form (enterprise) prompts for conditional enterpriseUrl, validates required input, supports stepping back with Esc, and sends full answer")
    func githubCopilotEnterpriseFormAndValidation() async {
        let capturedConnectBody = Mutex<[String: JSONValue]?>(nil)
        let isConnected = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/github-copilot/connect/oauth") && !req.url.contains("/complete") {
                capturedConnectBody.withLock { $0 = TUILiveOAuthFixtures.decodeJSONObject(req.body) }
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_gh_ent_1","url":"https://corp.ghe.com/login/device","instructions":"Enter code: ABCD-5678","mode":"auto","time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/github-copilot/connect/oauth/con_gh_ent_1") {
                isConnected.withLock { $0 = true }
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "complete"))
            }
            let connected = isConnected.withLock { $0 }
            if req.method == "GET" && req.url.contains("/api/integration") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[{"id":"github-copilot","name":"GitHub Copilot","methods":[{"type":"oauth","id":"device","label":"Login with GitHub Copilot"}],"connections":\#(connected ? #"[{"type":"credential","id":"cred_ent","label":"corp.ghe.com","method":"device"}]"# : "[]")}]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/provider") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.providerJSON(id: "github-copilot", name: "GitHub Copilot"))]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(TUILiveOAuthFixtures.modelJSON(id: "gpt-5", providerID: "github-copilot", name: "GPT-5 Enterprise"))}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.modelJSON(id: "gpt-5", providerID: "github-copilot", name: "GPT-5 Enterprise"))]}"#)
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [TUILiveOAuthFixtures.githubCopilotIntegration()])
        let harness = TUILiveOAuthHarness(state: state, transport: transport, oauthPollInterval: .milliseconds(15))
        defer { harness.destroy() }

        // Select GitHub Copilot
        harness.controller.openDialog(.connectProvider)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().connectFormState?.fieldIndex == 0)

        // Move down to "GitHub Enterprise" and confirm -> enters conditional field 1 (enterpriseUrl)
        harness.testRenderer.mockInput.pressArrow(.down)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().connectFormState?.fieldIndex == 1)
        #expect(harness.frame().contains("Enter your GitHub Enterprise URL or domain"))

        // Pressing Enter with empty URL surfaces validation error and stays on field 1
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().connectFormState?.fieldIndex == 1)
        #expect(harness.store.snapshot().connectErrorMessage == "Required")

        // Pressing Esc steps back to field 0 (deploymentType) cleanly
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().connectFormState?.fieldIndex == 0)

        // Choose GitHub Enterprise again, type enterprise domain, and submit
        harness.testRenderer.mockInput.pressArrow(.down)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().connectFormState?.fieldIndex == 1)
        harness.testRenderer.mockInput.typeText("corp.ghe.com")
        harness.testRenderer.mockInput.pressEnter()

        let finished = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().activeDialog == .modelPicker && !harness.store.snapshot().models.isEmpty
        }
        #expect(finished)

        let body = capturedConnectBody.withLock { $0 }
        if case .object(let answer) = body?["answer"] {
            #expect(answer["deploymentType"] == .string("enterprise"))
            #expect(answer["enterpriseUrl"] == .string("corp.ghe.com"))
        } else {
            Issue.record("Expected enterprise form answer in OAuth connect payload")
        }
        #expect(harness.launchedURLs == ["https://corp.ghe.com/login/device"])
        #expect(harness.store.snapshot().toastMessage == "Connected GitHub Copilot")
    }

    // MARK: - 3. OAuth `.code` Manual Paste Mode & OAuth Method Ordering

    @Test("OAuth .code mode sorts OAuth before API key, launches browser without polling, validates code, and submits POST /complete")
    func oauthCodeModeManualPasteSubmission() async {
        let statusPollCount = Mutex(0)
        let capturedCompleteBody = Mutex<[String: JSONValue]?>(nil)
        let isConnected = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/gitlab/connect/oauth/con_gl_1/complete") {
                capturedCompleteBody.withLock { $0 = TUILiveOAuthFixtures.decodeJSONObject(req.body) }
                isConnected.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "POST" && req.url.contains("/api/integration/gitlab/connect/oauth") {
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_gl_1","url":"https://gitlab.com/oauth/authorize?client_id=opencode&code_challenge=xyz","instructions":"Authorize OpenCode in your browser and paste the code below.","mode":"code","time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/gitlab/connect/oauth/con_gl_1") {
                statusPollCount.withLock { $0 += 1 }
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "pending"))
            }
            let connected = isConnected.withLock { $0 }
            if req.method == "GET" && req.url.contains("/api/integration") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[{"id":"gitlab","name":"GitLab Duo","methods":[{"type":"oauth","id":"pkce","label":"Sign in with GitLab OAuth"},{"type":"key","label":"Personal Access Token"}],"connections":\#(connected ? #"[{"type":"credential","id":"cred_gl1","label":"GitLab","method":"pkce"}]"# : "[]")}]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/provider") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.providerJSON(id: "gitlab", name: "GitLab Duo"))]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(TUILiveOAuthFixtures.modelJSON(id: "duo-chat-pro", providerID: "gitlab", name: "GitLab Duo Chat Pro"))}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.modelJSON(id: "duo-chat-pro", providerID: "gitlab", name: "GitLab Duo Chat Pro"))]}"#)
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let gitlab = TUILiveOAuthFixtures.codeModeOAuthIntegration()
        // Verify OAuth method sorts ahead of API key method
        #expect(gitlab.connectMethods.first?.rowID == "method:oauth:pkce")

        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [gitlab])
        let harness = TUILiveOAuthHarness(state: state, transport: transport)
        defer { harness.destroy() }

        // Open connectProvider -> GitLab Duo -> method picker (OAuth is first!) -> start OAuth
        harness.controller.openDialog(.connectProvider)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .connectMethod)
        let methodRows = harness.store.snapshot().dialogRows()
        #expect(methodRows.first?.id == "method:oauth:pkce")

        harness.testRenderer.mockInput.pressEnter()

        let dialogReady = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            let s = harness.store.snapshot()
            return s.activeDialog == .connectOAuth && s.connectOAuthAttemptID == "con_gl_1" && !s.connectSubmitting
        }
        #expect(dialogReady)

        let oauthSnap = harness.store.snapshot()
        #expect(oauthSnap.connectOAuthMode == .code)
        #expect(oauthSnap.connectOAuthNeedsCode == true)
        #expect(harness.launchedURLs == ["https://gitlab.com/oauth/authorize?client_id=opencode&code_challenge=xyz"])
        let oauthFrame = harness.frame()
        #expect(oauthFrame.contains("https://gitlab.com/oauth/"))
        #expect(oauthFrame.contains("authorize?client_id=opencode"))
        #expect(oauthFrame.contains("Paste authorization code"))

        // Submitting empty code shows validation error and does not complete
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().connectErrorMessage == "Please paste the authorization code")
        #expect(capturedCompleteBody.withLock { $0 } == nil)

        // Paste authorization code and press Enter -> submits POST /complete
        harness.testRenderer.mockInput.typeText("pkce_code_4242")
        harness.testRenderer.mockInput.pressEnter()

        let finished = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().activeDialog == .modelPicker && !harness.store.snapshot().models.isEmpty
        }
        #expect(finished)
        #expect(statusPollCount.withLock { $0 } == 0)
        #expect(capturedCompleteBody.withLock { $0 }?["code"] == .string("pkce_code_4242"))
        #expect(harness.store.snapshot().models.contains(where: { $0.id == "duo-chat-pro" }))
        #expect(harness.store.snapshot().toastMessage == "Connected GitLab Duo")
    }

    // MARK: - 4. OAuth `.auto` Mode with `paste: true` (Redirect URL Paste + Empty-Enter Browser Re-open)

    @Test("OAuth .auto mode with paste=true supports re-opening browser on empty Enter and submitting pasted redirect URL via POST /complete")
    func oauthAutoModeWithRedirectPasteFallback() async {
        let capturedCompleteBody = Mutex<[String: JSONValue]?>(nil)
        let isConnected = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/openai/connect/oauth/con_oai_1/complete") {
                capturedCompleteBody.withLock { $0 = TUILiveOAuthFixtures.decodeJSONObject(req.body) }
                isConnected.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "POST" && req.url.contains("/api/integration/openai/connect/oauth") {
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_oai_1","url":"https://auth.openai.com/oauth/authorize?state=abc","instructions":"Complete sign-in in your browser.","mode":"auto","paste":true,"time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/openai/connect/oauth/con_oai_1") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "pending"))
            }
            if req.method == "GET" && req.url.contains("/api/integration") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[{"id":"openai","name":"OpenAI","methods":[{"type":"oauth","id":"chatgpt","label":"ChatGPT Plus/Pro (Codex)"}],"connections":[]}]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/provider") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.providerJSON(id: "openai", name: "OpenAI"))]}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":\#(TUILiveOAuthFixtures.modelJSON(id: "gpt-5.3-codex", providerID: "openai", name: "GPT-5.3 Codex"))}"#)
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[\#(TUILiveOAuthFixtures.modelJSON(id: "gpt-5.3-codex", providerID: "openai", name: "GPT-5.3 Codex"))]}"#)
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [TUILiveOAuthFixtures.openAIOAuthAndKeyIntegration()])
        let harness = TUILiveOAuthHarness(state: state, transport: transport, oauthPollInterval: .milliseconds(30))
        defer { harness.destroy() }

        harness.controller.openDialog(.connectProvider)
        harness.testRenderer.mockInput.pressEnter() // OpenAI -> method picker
        #expect(harness.store.snapshot().dialogRows().first?.id == "method:oauth:chatgpt")
        harness.testRenderer.mockInput.pressEnter() // Select OAuth method

        let ready = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            let s = harness.store.snapshot()
            return s.activeDialog == .connectOAuth && s.connectOAuthAttemptID == "con_oai_1" && !s.connectSubmitting
        }
        #expect(ready)
        harness.render()
        #expect(harness.store.snapshot().connectOAuthAllowsPaste == true)
        #expect(harness.store.snapshot().connectOAuthNeedsCode == true)
        #expect(harness.launchedURLs.count == 1)

        // Pressing Enter with empty input re-opens the browser URL instead of showing an error
        harness.testRenderer.mockInput.pressEnter()
        let reopened = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 1_000) {
            harness.launchedURLs.count == 2
        }
        #expect(reopened)
        #expect(harness.store.snapshot().connectErrorMessage == nil)

        // Paste redirect URL and press Enter -> completes via POST /complete
        harness.testRenderer.mockInput.typeText("http://localhost:1455/auth/callback?code=codex_99&state=abc")
        harness.testRenderer.mockInput.pressEnter()

        let done = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().activeDialog == .modelPicker && harness.store.snapshot().models.contains(where: { $0.id == "gpt-5.3-codex" })
        }
        #expect(done)
        #expect(capturedCompleteBody.withLock { $0 }?["code"] == .string("http://localhost:1455/auth/callback?code=codex_99&state=abc"))
        #expect(harness.store.snapshot().toastMessage == "Connected OpenAI")
    }

    // MARK: - 5. Cancellation on Esc Stops Polling & Calls DELETE /oauth/:attemptID

    @Test("Pressing Esc during active OAuth polling cancels server attempt via DELETE and halts further status polls")
    func oauthCancellationOnEsc() async {
        let pollCount = Mutex(0)
        let deleteCalled = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/xai/connect/oauth") {
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_xai_cancel","url":"https://accounts.x.ai/device","instructions":"Enter code: XAI9-8877","mode":"auto","time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/xai/connect/oauth/con_xai_cancel") {
                pollCount.withLock { $0 += 1 }
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "pending"))
            }
            if req.method == "DELETE" && req.url.contains("/api/integration/xai/connect/oauth/con_xai_cancel") {
                deleteCalled.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "GET" && req.url.contains("/api/integration") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[{"id":"xai","name":"xAI","methods":[{"type":"oauth","id":"device","label":"Sign in with xAI"}],"connections":[]}]}"#)
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let xai = TUIIntegrationItem(
            id: "xai",
            name: "xAI",
            methods: [.oauth(id: "device", label: "Sign in with xAI")]
        )
        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [xai])
        let harness = TUILiveOAuthHarness(state: state, transport: transport, oauthPollInterval: .milliseconds(20))
        defer { harness.destroy() }

        harness.controller.openDialog(.connectProvider)
        harness.testRenderer.mockInput.pressEnter()

        let pollingStarted = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().connectOAuthAttemptID == "con_xai_cancel" && pollCount.withLock { $0 } >= 1
        }
        #expect(pollingStarted)
        #expect(harness.store.snapshot().connectOAuthUserCode == "XAI9-8877")
        #expect(harness.launchedURLs == ["https://accounts.x.ai/device"])

        // Press Esc to cancel OAuth
        harness.pressEscapeAndFlush()

        let cancelled = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            deleteCalled.withLock { $0 }
        }
        #expect(cancelled)
        #expect(harness.store.snapshot().activeDialog == .connectProvider)
        #expect(harness.store.snapshot().connectOAuthAttemptID == nil)
        #expect(harness.store.snapshot().connectOAuthURL == nil)

        // Confirm polling actually stopped and does not keep incrementing
        let countAfterCancel = pollCount.withLock { $0 }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(pollCount.withLock { $0 } == countAfterCancel)
    }

    // MARK: - 6. OAuth `.failed` Surfaces Error Cleanly Without Spurious Cancel

    @Test("OAuth .failed polling status surfaces error message and does not send DELETE on subsequent Esc")
    func oauthFailedStatusSurfacesError() async {
        let deleteCalled = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/poe/connect/oauth") {
                let json = """
                {"location":{"directory":"\(TUILiveOAuthFixtures.defaultDirectory)"},"data":{"attemptID":"con_poe_fail","url":"https://poe.com/oauth","instructions":"Approve in browser","mode":"auto","time":{"created":1750000000000,"expires":1750000900000}}}
                """
                return TUILiveOAuthFixtures.jsonResponse(200, json: json)
            }
            if req.method == "GET" && req.url.contains("/api/integration/poe/connect/oauth/con_poe_fail") {
                return TUILiveOAuthFixtures.jsonResponse(200, json: TUILiveOAuthFixtures.attemptStatusJSON(status: "failed", message: "Access denied by user"))
            }
            if req.method == "DELETE" {
                deleteCalled.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let poe = TUIIntegrationItem(id: "poe", name: "Poe", methods: [.oauth(id: "oauth", label: "Sign in with Poe")])
        let state = TUILiveOAuthFixtures.makeBaseState(integrations: [poe])
        let harness = TUILiveOAuthHarness(state: state, transport: transport, oauthPollInterval: .milliseconds(15))
        defer { harness.destroy() }

        harness.controller.beginConnectMethod(poe, method: poe.methods[0])
        let failed = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().connectErrorMessage == "Access denied by user"
        }
        #expect(failed)
        #expect(harness.frame().contains("Access denied by user"))

        harness.pressEscapeAndFlush()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(deleteCalled.withLock { $0 } == false)
    }

    // MARK: - 7. SSE `model.updated` Refreshes Live Models Picker with 320+ Providers & 1,200+ Models

    @Test("SSE model.updated refreshes open Models picker with 320+ providers and 1,200+ live models and supports fast multi-token search filtering")
    func sseModelUpdatedRefreshesLargeModelCatalog() async {
        let catalog = TUILiveOAuthFixtures.largeCatalogJSON(providerCount: 320, modelsPerProvider: 4)
        let catalogReady = Mutex(false)
        let sseServed = Mutex(false)

        let transport = MockHTTPTransport { req in
            if req.method == "GET" && req.url.contains("/api/event") {
                let first = sseServed.withLock { served -> Bool in
                    if served { return false }
                    served = true
                    return true
                }
                if first {
                    catalogReady.withLock { $0 = true }
                    return TUILiveOAuthFixtures.sseResponse(events: [
                        (id: "evt_live_1", type: "model.updated", dataJSON: "{}"),
                    ])
                }
                return TUILiveOAuthFixtures.sseResponse(events: [])
            }
            let ready = catalogReady.withLock { $0 }
            if req.method == "GET" && req.url.contains("/api/provider") {
                return TUILiveOAuthFixtures.jsonResponse(
                    200,
                    json: ready ? catalog.providersJSON : #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[]}"#
                )
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                return TUILiveOAuthFixtures.jsonResponse(
                    200,
                    json: ready ? catalog.defaultJSON : #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":null}"#
                )
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                return TUILiveOAuthFixtures.jsonResponse(
                    200,
                    json: ready ? catalog.modelsJSON : #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[]}"#
                )
            }
            if req.method == "GET" && req.url.contains("/api/integration") {
                return TUILiveOAuthFixtures.jsonResponse(
                    200,
                    json: #"{"location":{"directory":"\#(TUILiveOAuthFixtures.defaultDirectory)"},"data":[]}"#
                )
            }
            return TUILiveOAuthFixtures.jsonResponse(200, json: "{}")
        }

        let state = TUILiveOAuthFixtures.makeBaseState()
        let harness = TUILiveOAuthHarness(state: state, transport: transport)
        defer { harness.destroy() }

        // Open Models picker via Cmd+M (Kitty CSI u super+m) while catalog is still empty
        harness.testRenderer.renderer.feedInput("\u{1B}[109;9u")
        #expect(harness.store.snapshot().activeDialog == .modelPicker)
        #expect(harness.store.snapshot().models.isEmpty)

        // Start live SSE stream -> delivers `model.updated` -> reloads 320 providers & 1,253 models!
        let sseTask = harness.controller.startEventStream()
        defer { sseTask.cancel() }

        let loaded = await TUILiveOAuthFixtures.waitUntil(timeoutMs: 2_000) {
            harness.store.snapshot().models.count >= 1_200 && harness.store.snapshot().providers.count >= 320
        }
        #expect(loaded)

        let snap = harness.store.snapshot()
        #expect(snap.activeDialog == .modelPicker)
        #expect(snap.providers.count == 320)
        #expect(snap.models.count > 1_200)
        #expect(snap.dialogRows().count == snap.models.count)

        // Render mounted model picker input before typing multi-token filter across 1,200+ models
        harness.render()
        harness.testRenderer.mockInput.typeText("github-copilot opus")
        let filteredRows = harness.store.snapshot().dialogRows()
        #expect(filteredRows.count == 1)
        #expect(filteredRows.first?.id == "github-copilot/claude-opus-4-6")
        #expect(harness.frame().contains("Claude Opus 4.6 (Copilot)"))

        // Confirm selection picks that live model cleanly
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == nil)
        #expect(harness.store.snapshot().selectedModel?.id == "claude-opus-4-6")
        #expect(harness.store.snapshot().selectedModel?.providerID == "github-copilot")

        // Also verify SSE reducer effects for provider.updated, integration.updated, models-dev.refreshed, and plugin.updated
        var reducerState = TUILiveOAuthFixtures.makeBaseState()
        for eventType in ["model.updated", "provider.updated", "integration.updated", "models-dev.refreshed", "plugin.updated"] {
            let eff = TUIInteractiveClient.applyServerEvent(
                OpenCodeEvent(id: "evt_\(eventType)", type: eventType, data: .object([:])),
                to: &reducerState
            )
            #expect(eff.refreshModels == true)
            #expect(eff.refreshIntegrations == true)
        }
    }
}
