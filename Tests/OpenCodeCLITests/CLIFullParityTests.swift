import Testing
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

@Suite("CLI Full Parity P5: Models, Pair, Auth, Session & Interactive Terminal Prompts")
struct CLIFullParityTests {
    // MARK: - 1. opencode models Parity

    @Test("opencode models lists all models, filters by positional provider, supports --verbose and --refresh")
    func modelsFullParity() async {
        let modelsPayload = CLIFullParityFixtures.richModelsEnvelopeJSON()
        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":1,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/location/reload") && req.method == "POST" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/plugin") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"location\":{\"directory\":\"/workspace/project\"},\"data\":[{\"id\":\"p1\",\"source\":{\"type\":\"builtin\"},\"features\":{\"server\":true},\"state\":{\"status\":\"active\"}}]}"
                )
            }
            if req.url.contains("/api/model") {
                return CLITestFixtures.jsonResponse(200, json: modelsPayload)
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }

        // Default listing (all providers, sorted)
        let (ctxAll, outAll, _) = CLITestFixtures.makeContext(transport: transport)
        let codeAll = await CLIEntrypoint.run(arguments: ["models", "--server", "http://127.0.0.1:49374"], context: ctxAll)
        #expect(codeAll == 0)
        #expect(outAll.stdout == "anthropic/claude-sonnet-4\ngoogle/gemini-2.5-pro\nopenai/gpt-5\n")

        // Positional [provider] filter
        let (ctxFiltered, outFiltered, _) = CLITestFixtures.makeContext(transport: transport)
        let codeFiltered = await CLIEntrypoint.run(
            arguments: ["models", "anthropic", "--server", "http://127.0.0.1:49374"],
            context: ctxFiltered
        )
        #expect(codeFiltered == 0)
        #expect(outFiltered.stdout == "anthropic/claude-sonnet-4\n")

        // Unknown provider filter returns empty with exit 0
        let (ctxUnknown, outUnknown, _) = CLITestFixtures.makeContext(transport: transport)
        let codeUnknown = await CLIEntrypoint.run(
            arguments: ["models", "nonexistent", "--server", "http://127.0.0.1:49374"],
            context: ctxUnknown
        )
        #expect(codeUnknown == 0)
        #expect(outUnknown.stdout.isEmpty)

        // --verbose prints full JSON metadata including limit, cost, variants, and capabilities
        let (ctxVerbose, outVerbose, _) = CLITestFixtures.makeContext(transport: transport)
        let codeVerbose = await CLIEntrypoint.run(
            arguments: ["models", "anthropic", "--verbose", "--server", "http://127.0.0.1:49374"],
            context: ctxVerbose
        )
        #expect(codeVerbose == 0)
        #expect(outVerbose.stdout.hasPrefix("anthropic/claude-sonnet-4\n{"))
        #expect(outVerbose.stdout.contains("\"context\" : 200000") || outVerbose.stdout.contains("\"context\": 200000"))
        #expect(outVerbose.stdout.contains("\"output\" : 64000") || outVerbose.stdout.contains("\"output\": 64000"))
        #expect(outVerbose.stdout.contains("\"capabilities\""))
        #expect(outVerbose.stdout.contains("\"variants\""))
        #expect(outVerbose.stdout.contains("\"high\""))
        #expect(outVerbose.stdout.contains("\"cost\""))
        #expect(!outVerbose.stdout.contains("openai/gpt-5"))

        // --refresh invokes POST /api/location/reload before GET /api/model
        let refreshTransport = MockCLIHTTPTransport { req in
            try await transport.send(req)
        }
        let (ctxRefresh, outRefresh, _) = CLITestFixtures.makeContext(transport: refreshTransport)
        let codeRefresh = await CLIEntrypoint.run(
            arguments: ["models", "--refresh", "--server", "http://127.0.0.1:49374"],
            context: ctxRefresh
        )
        #expect(codeRefresh == 0)
        #expect(outRefresh.stdout.contains("anthropic/claude-sonnet-4"))
        let reloadIdx = refreshTransport.requests.firstIndex { $0.url.contains("/api/location/reload") && $0.method == "POST" }
        let modelIdx = refreshTransport.requests.firstIndex { $0.url.contains("/api/model") && $0.method == "GET" }
        #expect(reloadIdx != nil)
        #expect(modelIdx != nil)
        if let reloadIdx, let modelIdx {
            #expect(reloadIdx < modelIdx)
        }

        // --help shows provider arg and --verbose / --refresh flags
        let (ctxHelp, outHelp, _) = CLITestFixtures.makeContext()
        #expect(await CLIEntrypoint.run(arguments: ["models", "--help"], context: ctxHelp) == 0)
        #expect(outHelp.stdout.contains("[provider]"))
        #expect(outHelp.stdout.contains("--verbose"))
        #expect(outHelp.stdout.contains("--refresh"))
    }

    // MARK: - 2. opencode pair Parity (Real Unicode QR Code + Links + Expiry)

    @Test("opencode pair renders real Unicode half-block QR code, pairing links, and expiration time")
    func pairRendersUnicodeQRCodeAndLinks() async throws {
        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":4242,\"urls\":[\"http://127.0.0.1:49374\",\"http://192.168.1.42:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/pair") && req.method == "POST" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"code\":\"PAIRCODE99\",\"expires_in\":300}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }
        let serviceFiles = CLIFullParityFixtures.sampleServiceRegistrationFiles()

        // 1. Default pair with loopback + LAN address renders QR for LAN address and SSH hint on stderr
        let (ctxLan, outLan, _) = CLITestFixtures.makeContext(
            files: serviceFiles,
            transport: transport,
            signaler: MockServiceSignaler(running: [4242])
        )
        let codeLan = await CLIEntrypoint.run(arguments: ["pair"], context: ctxLan)
        #expect(codeLan == 0)
        #expect(outLan.stdout.contains("expire in 5 minutes"))
        #expect(outLan.stdout.contains("http://127.0.0.1:49374/auth/connect/PAIRCODE99"))
        #expect(outLan.stdout.contains("http://192.168.1.42:49374/auth/connect/PAIRCODE99"))
        #expect(outLan.stdout.contains("\u{2580}")) // ▀
        #expect(outLan.stdout.contains("\u{2584}")) // ▄
        #expect(outLan.stdout.contains("\u{2588}")) // █
        let expectedLanQR = try CLIFullParityFixtures.expectedPairingQR(
            code: "PAIRCODE99",
            urls: ["http://192.168.1.42:49374"]
        )
        let expectedFirstQRLine = expectedLanQR.split(separator: "\n").first.map(String.init) ?? ""
        #expect(!expectedFirstQRLine.isEmpty)
        #expect(outLan.stdout.contains("  \(expectedFirstQRLine)"))
        #expect(outLan.stderr.contains("Over SSH? Forward the port"))
        #expect(outLan.stderr.contains("ssh -L 49374:127.0.0.1:49374 <host>"))

        // 2. pair --url https://code.example.com renders QR for external URL and suppresses SSH hint
        let (ctxExt, outExt, _) = CLITestFixtures.makeContext(
            files: serviceFiles,
            transport: transport,
            signaler: MockServiceSignaler(running: [4242])
        )
        let codeExt = await CLIEntrypoint.run(
            arguments: ["pair", "--url", "https://code.example.com/"],
            context: ctxExt
        )
        #expect(codeExt == 0)
        #expect(outExt.stdout.contains("https://code.example.com/auth/connect/PAIRCODE99"))
        #expect(outExt.stdout.contains("\u{2580}"))
        #expect(outExt.stdout.contains("\u{2584}"))
        #expect(outExt.stdout.contains("\u{2588}"))
        #expect(outExt.stderr.isEmpty)

        // 3. pair --remote --yes resolves tunnel URL and renders QR
        let tunnelTransport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":4242,\"urls\":[\"http://127.0.0.1:49374\",\"https://test-route.tunnel.opencode.dev\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/pair") && req.method == "POST" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"code\":\"REMOTECODE1\",\"expires_in\":600}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }
        let remoteServiceFiles = CLIFullParityFixtures.sampleServiceRegistrationFiles(includeRemoteConfig: true)
        let (ctxRemote, outRemote, _) = CLITestFixtures.makeContext(
            files: remoteServiceFiles,
            transport: tunnelTransport,
            signaler: MockServiceSignaler(running: [4242]),
            remoteTunnelBackend: MockRemoteTunnelBackend(storedHost: "tunnel.opencode.dev", ensuredHost: "tunnel.opencode.dev")
        )
        let codeRemote = await CLIEntrypoint.run(arguments: ["pair", "--remote", "--yes"], context: ctxRemote)
        #expect(codeRemote == 0)
        #expect(outRemote.stdout.contains("expire in 10 minutes"))
        #expect(outRemote.stdout.contains("https://test-route.tunnel.opencode.dev/auth/connect/REMOTECODE1"))
        #expect(outRemote.stdout.contains("\u{2588}"))

        // 4. Combining --remote and --url fails cleanly
        let (ctxBad, outBad, _) = CLITestFixtures.makeContext(files: serviceFiles)
        let codeBad = await CLIEntrypoint.run(
            arguments: ["pair", "--remote", "--url", "https://code.example.com"],
            context: ctxBad
        )
        #expect(codeBad == 1)
        #expect(outBad.stderr.contains("--remote cannot be combined with --url"))

        // 5. Loopback-only server URLs omit QR code and emit SSH forwarding hint
        let loopbackTransport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":4242,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/pair") && req.method == "POST" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"code\":\"LOCALONLY1\",\"expires_in\":180}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }
        let (ctxLocal, outLocal, _) = CLITestFixtures.makeContext(
            files: serviceFiles,
            transport: loopbackTransport,
            signaler: MockServiceSignaler(running: [4242])
        )
        #expect(await CLIEntrypoint.run(arguments: ["pair"], context: ctxLocal) == 0)
        #expect(outLocal.stdout.contains("expire in 3 minutes"))
        #expect(outLocal.stdout.contains("http://127.0.0.1:49374/auth/connect/LOCALONLY1"))
        #expect(!outLocal.stdout.contains("\u{2588}"))
        #expect(outLocal.stderr.contains("opencode service set hostname 0.0.0.0"))

        // 6. Pair.remoteURL timeout reports proxy guidance
        let (ctxTimeout, _, _) = CLITestFixtures.makeContext(
            files: remoteServiceFiles,
            transport: loopbackTransport,
            remoteTunnelBackend: MockRemoteTunnelBackend(storedHost: "tunnel.opencode.dev", ensuredHost: "tunnel.opencode.dev")
        )
        let timeoutClient = ctxTimeout.makeClient(endpoint: ServiceEndpoint(url: "http://127.0.0.1:49374"))
        do {
            _ = try await CLICommands.Pair.remoteURL(
                client: timeoutClient,
                context: ctxTimeout,
                maxWait: .milliseconds(25),
                pollInterval: .milliseconds(10)
            )
            Issue.record("Expected remoteURL timeout error")
        } catch let err as CLIError {
            #expect(err.message.contains("Timed out waiting for the remote tunnel"))
            #expect(err.message.contains("HTTPS_PROXY"))
        }
    }

    // MARK: - 3. opencode auth list / login / logout / switch / export / import

    @Test("opencode auth list, login (API key via prompt backend), logout, switch, export, and import")
    func authSubcommandsFullParity() async {
        let integrationsPayload = CLIFullParityFixtures.authIntegrationsEnvelopeJSON()
        let credentialsPayload = CLIFullParityFixtures.sampleCredentialsJSON()
        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":1,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/plugin") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"location\":{\"directory\":\"/workspace/project\"},\"data\":[{\"id\":\"p1\",\"source\":{\"type\":\"builtin\"},\"features\":{\"server\":true},\"state\":{\"status\":\"active\"}}]}"
                )
            }
            if req.url.contains("/api/integration/anthropic/connect/key") && req.method == "POST" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/integration") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: integrationsPayload)
            }
            if req.url.contains("/api/credential/crd_1") && req.method == "DELETE" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/credential/crd_2/activate") && req.method == "POST" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/credential") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: "{\"data\":\(credentialsPayload)}")
            }
            if req.url.contains("/api/credential") && req.method == "POST" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"data\":{\"id\":\"crd_new_99\",\"integrationID\":\"anthropic\",\"label\":\"Work Anthropic\",\"active\":true,\"value\":{\"type\":\"key\",\"key\":\"sk-ant-test-99\"}}}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }

        // auth list (table)
        let (ctxList, outList, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(await CLIEntrypoint.run(arguments: ["auth", "list", "--server", "http://127.0.0.1:49374"], context: ctxList) == 0)
        #expect(outList.stdout.contains("Anthropic"))
        #expect(outList.stdout.contains("ANTHROPIC_API_KEY"))
        #expect(outList.stdout.contains("environment"))
        #expect(outList.stdout.contains("OpenAI"))
        #expect(outList.stdout.contains("Personal"))
        #expect(outList.stdout.contains("stored"))

        // auth list --format json
        let (ctxJson, outJson, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "list", "--format", "json", "--server", "http://127.0.0.1:49374"],
                context: ctxJson
            ) == 0
        )
        #expect(outJson.stdout.contains("\"id\" : \"anthropic\"") || outJson.stdout.contains("\"id\": \"anthropic\""))
        #expect(outJson.stdout.contains("\"connections\""))

        // auth login anthropic (key flow via mock prompt backend)
        let (ctxLogin, outLogin, _) = CLITestFixtures.makeContext(
            isStdinTTY: true,
            isStdoutTTY: true,
            transport: transport,
            promptBackend: MockPromptBackend(passwordResult: "sk-ant-live-secret")
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "login", "anthropic", "--server", "http://127.0.0.1:49374"],
                context: ctxLogin
            ) == 0
        )
        #expect(outLogin.stderr.contains("Connected to Anthropic"))
        #expect(outLogin.stderr.contains("Done"))
        let keyConnectReq = transport.requests.first { $0.url.contains("/api/integration/anthropic/connect/key") && $0.method == "POST" }
        #expect(keyConnectReq != nil)
        if let body = keyConnectReq?.body {
            #expect(CLIFullParityFixtures.decodeUTF8(body).contains("sk-ant-live-secret"))
        }

        // auth logout openai Personal
        let (ctxLogout, outLogout, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "logout", "openai", "Personal", "--server", "http://127.0.0.1:49374"],
                context: ctxLogout
            ) == 0
        )
        #expect(outLogout.stderr.contains("Removed account from OpenAI"))
        #expect(transport.requests.contains { $0.url.contains("/api/credential/crd_1") && $0.method == "DELETE" })

        // auth switch openai Work
        let (ctxSwitch, outSwitch, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "switch", "openai", "Work", "--server", "http://127.0.0.1:49374"],
                context: ctxSwitch
            ) == 0
        )
        #expect(outSwitch.stderr.contains("Switched account for OpenAI"))
        #expect(transport.requests.contains { $0.url.contains("/api/credential/crd_2/activate") && $0.method == "POST" })

        // auth login non-TTY without target fails cleanly
        let (ctxNoTarget, outNoTarget, _) = CLITestFixtures.makeContext(isStdinTTY: false, isStdoutTTY: false, transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "login", "--server", "http://127.0.0.1:49374"],
                context: ctxNoTarget
            ) == 1
        )
        #expect(outNoTarget.stderr.contains("Pass an integration ID or name"))

        // auth logout on env-only integration explains how to disconnect
        let (ctxEnvLogout, outEnvLogout, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "logout", "anthropic", "ANTHROPIC_API_KEY", "--server", "http://127.0.0.1:49374"],
                context: ctxEnvLogout
            ) == 1
        )
        #expect(outEnvLogout.stderr.contains("ANTHROPIC_API_KEY"))
        #expect(outEnvLogout.stderr.contains("unset the environment variable"))

        // auth export & auth import
        let (ctxExport, outExport, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "export", "anthropic", "--server", "http://127.0.0.1:49374"],
                context: ctxExport
            ) == 0
        )
        #expect(outExport.stdout.contains("crd_new_99"))
        #expect(!outExport.stdout.contains("crd_1"))

        let (ctxImport, outImport, _) = CLITestFixtures.makeContext(
            files: ["/workspace/project/creds.json": credentialsPayload],
            transport: transport
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["auth", "import", "creds.json", "--server", "http://127.0.0.1:49374"],
                context: ctxImport
            ) == 0
        )
        #expect(outImport.stderr.contains("skipped 2 already present"))
    }

    // MARK: - 4. opencode session list / export / import / delete

    @Test("opencode session list, export, import, and delete against mock HTTP transport")
    func sessionSubcommandsFullParity() async {
        let sessionItemJSON = CLITestFixtures.sampleSessionInfoJSON(
            id: "ses_demo0001",
            title: "Line1\nLine2\tTab"
        )
        let exportedJSON = CLIFullParityFixtures.sampleSessionExportJSON(
            id: "ses_demo0001",
            title: "Exported Session"
        )
        let importedEnvelopeJSON = "{\"data\":\(CLITestFixtures.sampleSessionInfoJSON(id: "ses_imported01", title: "Imported Session"))}"

        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":1,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/location") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"directory\":\"/workspace/project\",\"project\":{\"id\":\"prj_test0001\",\"directory\":\"/workspace/project\",\"canonical\":\"/workspace/project\"}}"
                )
            }
            if req.url.contains("/api/experimental/session/ses_demo0001/export") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: "{\"data\":\(exportedJSON)}")
            }
            if req.url.contains("/api/experimental/session/import") && req.method == "POST" {
                if let body = req.body, CLIFullParityFixtures.decodeUTF8(body).contains("ses_conflict01") {
                    return CLITestFixtures.jsonResponse(409, json: "{\"error\":\"conflict\"}")
                }
                return CLITestFixtures.jsonResponse(200, json: importedEnvelopeJSON)
            }
            if req.url.contains("/api/session/ses_demo0001") && req.method == "DELETE" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/session") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"data\":[\(sessionItemJSON)],\"cursor\":{\"next\":null,\"prev\":null}}"
                )
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }

        // session list (table format sanitizes whitespace and requests parentID=null)
        let (ctxList, outList, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "list", "--max-count", "10", "--server", "http://127.0.0.1:49374"],
                context: ctxList
            ) == 0
        )
        #expect(outList.stdout.contains("ses_demo0001\tLine1 Line2 Tab\t"))
        let listReq = transport.requests.first { $0.url.contains("/api/session") && $0.method == "GET" }
        #expect(listReq?.url.contains("parentID=null") == true)
        #expect(listReq?.url.contains("limit=10") == true)

        // session export <id> --sanitize
        let (ctxExport, outExport, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "export", "ses_demo0001", "--sanitize", "--server", "http://127.0.0.1:49374"],
                context: ctxExport
            ) == 0
        )
        #expect(outExport.stdout.contains("ses_demo0001"))
        #expect(outExport.stdout.contains("Exported Session"))
        let exportReq = transport.requests.first { $0.url.contains("/api/experimental/session/ses_demo0001/export") }
        #expect(exportReq?.url.contains("sanitize=true") == true)

        // session export (interactive picker when session ID omitted)
        let (ctxPickExport, outPickExport, _) = CLITestFixtures.makeContext(
            isStdinTTY: true,
            isStdoutTTY: true,
            transport: transport,
            promptBackend: MockPromptBackend(selectResult: "ses_demo0001")
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "export", "--server", "http://127.0.0.1:49374"],
                context: ctxPickExport
            ) == 0
        )
        #expect(outPickExport.stdout.contains("ses_demo0001"))

        // session import (file)
        let (ctxImport, outImport, _) = CLITestFixtures.makeContext(
            files: ["/workspace/project/bundle.json": exportedJSON],
            transport: transport
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "import", "bundle.json", "--server", "http://127.0.0.1:49374"],
                context: ctxImport
            ) == 0
        )
        #expect(outImport.stdout == "Imported session: ses_imported01\n")

        // session import (409 conflict handled cleanly)
        let conflictJSON = CLIFullParityFixtures.sampleSessionExportJSON(id: "ses_conflict01", title: "Existing")
        let (ctxConflict, outConflict, _) = CLITestFixtures.makeContext(
            files: ["/workspace/project/dup.json": conflictJSON],
            transport: transport
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "import", "dup.json", "--server", "http://127.0.0.1:49374"],
                context: ctxConflict
            ) == 0
        )
        #expect(outConflict.stderr.contains("Session already exists"))

        // session export non-TTY without session ID fails cleanly
        let (ctxExportNoTTY, outExportNoTTY, _) = CLITestFixtures.makeContext(
            isStdinTTY: false,
            isStdoutTTY: false,
            transport: transport
        )
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "export", "--server", "http://127.0.0.1:49374"],
                context: ctxExportNoTTY
            ) == 1
        )
        #expect(outExportNoTTY.stderr.contains("Pass a session ID"))

        // session delete
        let (ctxDelete, outDelete, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(
            await CLIEntrypoint.run(
                arguments: ["session", "delete", "ses_demo0001", "--server", "http://127.0.0.1:49374"],
                context: ctxDelete
            ) == 0
        )
        #expect(outDelete.stdout == "Session ses_demo0001 deleted\n")
    }

    @Test("opencode mcp list and logout interact cleanly with server API")
    func mcpListAndLogoutParity() async {
        let integrationsPayload = CLIFullParityFixtures.authIntegrationsEnvelopeJSON()
        let mcpListJSON = """
        {"location":{"directory":"/workspace/project"},"data":[
          {"name":"linear","status":{"status":"connected"},"integrationID":"openai"},
          {"name":"github","status":{"status":"needs_auth","error":"expired"}},
          {"name":"broken","status":{"status":"failed","error":"timeout"}}
        ]}
        """
        let singleIntegrationJSON = """
        {"location":{"directory":"/workspace/project"},"data":{
          "id":"openai","name":"OpenAI","methods":[],"connections":[
            {"type":"credential","id":"crd_1","label":"Personal","method":"key"}
          ]
        }}
        """
        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(
                    200,
                    json: "{\"version\":\"2.1.0\",\"pid\":1,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}"
                )
            }
            if req.url.contains("/api/mcp") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: mcpListJSON)
            }
            if req.url.contains("/api/integration/openai") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: singleIntegrationJSON)
            }
            if req.url.contains("/api/integration") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: integrationsPayload)
            }
            if req.url.contains("/api/credential/crd_1") && req.method == "DELETE" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }

        let (ctxList, outList, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(await CLIEntrypoint.run(arguments: ["mcp", "list", "--server", "http://127.0.0.1:49374"], context: ctxList) == 0)
        #expect(outList.stdout.contains("✓ linear"))
        #expect(outList.stdout.contains("⚠ github"))
        #expect(outList.stdout.contains("needs authentication"))
        #expect(outList.stdout.contains("✗ broken"))
        #expect(outList.stdout.contains("failed: timeout"))

        let (ctxLogout, outLogout, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(await CLIEntrypoint.run(arguments: ["mcp", "logout", "linear", "--server", "http://127.0.0.1:49374"], context: ctxLogout) == 0)
        #expect(outLogout.stdout == "Removed OAuth credentials for linear\n")
        #expect(transport.requests.contains { $0.url.contains("/api/credential/crd_1") && $0.method == "DELETE" })
    }

    // MARK: - 5. DefaultTerminalBackend Non-TTY Fallback & Interactive Picker + POSIX termios

    @Test("DefaultTerminalBackend non-TTY fallback supports confirm, text, password, select, and multiselect")
    func defaultTerminalBackendNonTTYFallback() async throws {
        let (io, out) = CLIFullParityFixtures.makeBufferedIO(stdinLines: [
            "yes",
            "",
            "custom-text",
            "",
            "my-secret-pass",
            "2",
            "beta",
            "1, 3, 1",
            "",
        ])
        let backend = CLIUI.Prompt.DefaultTerminalBackend(io: io)

        #expect(try await backend.confirm(message: "Proceed?", initialValue: false) == true)
        #expect(try await backend.confirm(message: "Keep default?", initialValue: false) == false)
        #expect(try await backend.text(message: "Name", placeholder: "enter", initialValue: nil, validate: nil) == "custom-text")
        #expect(try await backend.text(message: "Fallback", placeholder: nil, initialValue: "def", validate: nil) == "def")
        #expect(try await backend.password(message: "Secret", validate: { $0.isEmpty ? "Required" : nil }) == "my-secret-pass")

        let opts = [
            CLIUI.Prompt.SelectOption(value: "alpha", label: "Alpha", hint: "first"),
            CLIUI.Prompt.SelectOption(value: "beta", label: "Beta"),
            CLIUI.Prompt.SelectOption(value: "gamma", label: "Gamma"),
        ]
        #expect(try await backend.select(message: "Pick one", options: opts, initialValue: "alpha") == "beta")
        #expect(try await backend.select(message: "Pick by value", options: opts, initialValue: nil) == "beta")
        #expect(try await backend.multiselect(message: "Pick many", options: opts, initialValues: nil, required: true) == ["alpha", "gamma"])
        #expect(try await backend.multiselect(message: "Defaults", options: opts, initialValues: ["beta"], required: true) == ["beta"])
        #expect(out.stderr.contains("Pick one"))
        #expect(out.stderr.contains("1. Alpha (first)"))

        // Validation error and EOF cancellation
        let (errIO, _) = CLIFullParityFixtures.makeBufferedIO(stdinLines: [""])
        let errBackend = CLIUI.Prompt.DefaultTerminalBackend(io: errIO)
        await #expect(throws: CLIError.self) {
            _ = try await errBackend.password(message: "Key", validate: { $0.isEmpty ? "Required" : nil })
        }
        await #expect(throws: CLIUI.Prompt.CancelledError.self) {
            _ = try await errBackend.confirm(message: "EOF?", initialValue: true)
        }
    }

    @Test("TerminalKey decoder and masked password loop handle arrows, UTF-8, backspace, Ctrl+U, and Ctrl+C")
    func terminalKeyDecoderAndMaskedPasswordLoop() throws {
        // CSI & SS3 arrows, standalone Esc, Ctrl+C, Backspace, UTF-8 'é' (0xC3 0xA9)
        let rawBytes: [UInt8] = [
            0x1B, 0x5B, 0x41, // Up
            0x1B, 0x5B, 0x42, // Down
            0x1B, 0x4F, 0x41, // SS3 Up
            0x1B, 0x4F, 0x42, // SS3 Down
            0xC3, 0xA9,       // 'é'
            0x7F,             // Backspace
            0x20,             // Space
            0x0D,             // Enter
            0x03,             // Ctrl+C
            0x1B,             // Standalone Escape
        ]
        let reader = CLIFullParityFixtures.makeByteReader(from: rawBytes)
        var decoded: [CLIUI.Prompt.TerminalKey] = []
        while let key = CLIUI.Prompt.DefaultTerminalBackend.decodeTerminalKey(readByte: reader) {
            decoded.append(key)
        }
        #expect(decoded == [
            .up, .down, .up, .down, .character("é"), .backspace, .space, .enter, .ctrlC, .escape,
        ])

        // Masked password: type "ab", arrow up (ignored), backspace, "cd", enter
        let pwBytes: [UInt8] = [0x61, 0x62, 0x1B, 0x5B, 0x41, 0x7F, 0x63, 0x64, 0x0D]
        var pwStderr = ""
        let pw = try CLIUI.Prompt.DefaultTerminalBackend.readMaskedPassword(
            prompt: "Pass: ",
            readByte: CLIFullParityFixtures.makeByteReader(from: pwBytes),
            writeStderr: { pwStderr += $0 }
        )
        #expect(pw == "acd")
        #expect(pwStderr == "Pass: **\u{08} \u{08}**\n")
        #expect(!pwStderr.contains("acd"))

        // Ctrl+U clears line before entering new password
        let clearBytes: [UInt8] = [0x78, 0x79, 0x15, 0x7A, 0x0A]
        var clearStderr = ""
        let cleared = try CLIUI.Prompt.DefaultTerminalBackend.readMaskedPassword(
            prompt: "Key: ",
            readByte: CLIFullParityFixtures.makeByteReader(from: clearBytes),
            writeStderr: { clearStderr += $0 }
        )
        #expect(cleared == "z")
        #expect(clearStderr.hasSuffix("*\n"))

        // Ctrl+C cancels and writes trailing newline
        var cancelStderr = ""
        #expect(throws: CLIUI.Prompt.CancelledError.self) {
            _ = try CLIUI.Prompt.DefaultTerminalBackend.readMaskedPassword(
                prompt: "Key: ",
                readByte: CLIFullParityFixtures.makeByteReader(from: [0x61, 0x03]),
                writeStderr: { cancelStderr += $0 }
            )
        }
        #expect(cancelStderr == "Key: *\n")
    }

    @Test("Interactive arrow-key select, live type-to-filter (>5 items), multiselect toggle, and cancel")
    func interactiveArrowKeyPickers() throws {
        // 1. Small list (<= 5 items): wrap-around navigation with Up/Down + Enter
        let smallOpts = [
            CLIUI.Prompt.SelectOption(value: "one", label: "One"),
            CLIUI.Prompt.SelectOption(value: "two", label: "Two"),
            CLIUI.Prompt.SelectOption(value: "three", label: "Three"),
        ]
        var smallOut = ""
        let smallChosen = try CLIUI.Prompt.DefaultTerminalBackend.runInteractiveSelect(
            message: "Choose",
            options: smallOpts,
            initialValue: "one",
            nextKey: CLIFullParityFixtures.makeKeyReader(from: [.up, .enter]),
            writeStderr: { smallOut += $0 }
        )
        #expect(smallChosen == "three")
        #expect(smallOut.contains("\u{1B}[?25l"))
        #expect(smallOut.contains("\u{1B}[?25h"))
        #expect(!smallOut.contains("Search:"))

        // 2. Large list (> 5 items): live type-to-filter search + Backspace + Enter
        let largeOpts = [
            CLIUI.Prompt.SelectOption(value: "openai", label: "OpenAI"),
            CLIUI.Prompt.SelectOption(value: "anthropic", label: "Anthropic"),
            CLIUI.Prompt.SelectOption(value: "google", label: "Google"),
            CLIUI.Prompt.SelectOption(value: "mistral", label: "Mistral"),
            CLIUI.Prompt.SelectOption(value: "groq", label: "Groq"),
            CLIUI.Prompt.SelectOption(value: "deepseek", label: "DeepSeek"),
        ]
        var largeOut = ""
        let filteredChosen = try CLIUI.Prompt.DefaultTerminalBackend.runInteractiveSelect(
            message: "Provider",
            options: largeOpts,
            nextKey: CLIFullParityFixtures.makeKeyReader(from: [
                .character("d"), .character("e"), .character("x"), .backspace, .character("e"), .enter,
            ]),
            writeStderr: { largeOut += $0 }
        )
        #expect(filteredChosen == "deepseek")
        #expect(largeOut.contains("Search:"))

        // 3. Escape throws CancelledError and restores cursor
        var escOut = ""
        #expect(throws: CLIUI.Prompt.CancelledError.self) {
            _ = try CLIUI.Prompt.DefaultTerminalBackend.runInteractiveSelect(
                message: "Abort",
                options: smallOpts,
                nextKey: CLIFullParityFixtures.makeKeyReader(from: [.down, .escape]),
                writeStderr: { escOut += $0 }
            )
        }
        #expect(escOut.contains("\u{1B}[?25h"))

        // 4. Multiselect: required validation -> Space toggle -> Enter preserves option ordering
        var multiOut = ""
        let multiChosen = try CLIUI.Prompt.DefaultTerminalBackend.runInteractiveMultiselect(
            message: "Features",
            options: smallOpts,
            initialValues: nil,
            required: true,
            nextKey: CLIFullParityFixtures.makeKeyReader(from: [
                .enter,       // rejected because required & empty
                .down, .down, // move to "Three"
                .space,       // toggle "Three" ON
                .up, .up,     // move to "One"
                .space,       // toggle "One" ON
                .enter,       // confirm -> ["one", "three"]
            ]),
            writeStderr: { multiOut += $0 }
        )
        #expect(multiChosen == ["one", "three"])
        #expect(multiOut.contains("At least one selection is required"))
        #expect(multiOut.contains("\u{1B}[?25h"))

        // 5. Interactive integration picker with live search
        let choices = [
            CLIUI.IntegrationChoice(value: "mcp-lin", label: "Linear", category: .mcp, connected: true),
            CLIUI.IntegrationChoice(value: "anthropic", label: "Anthropic", category: .popular, connected: false),
            CLIUI.IntegrationChoice(value: "openai", label: "OpenAI", category: .popular, connected: true),
        ]
        var integOut = ""
        let pickedIntegration = try CLIUI.runInteractiveIntegrationPicker(
            choices: choices,
            kind: "integration",
            nextKey: CLIFullParityFixtures.makeKeyReader(from: [.character("a"), .character("n"), .character("t"), .enter]),
            writeStderr: { integOut += $0 }
        )
        #expect(pickedIntegration == "anthropic")
        #expect(integOut.contains("Select integration"))
        #expect(integOut.contains("\u{1B}[?25h"))
    }

    @Test("POSIX termios no-echo raw mode disables ECHO and restores terminal attributes in defer")
    func posixTermiosEchoMaskAndRestore() {
        let result = CLIFullParityFixtures.runPOSIXTermiosAndPTYChecks()
        if result.supported {
            #expect(result.hadEchoBefore == true)
            #expect(result.echoDisabledInside == true)
            #expect(result.canonicalDisabledInside == true)
            #expect(result.isigDisabledInside == true)
            #expect(result.restoredAfterNormalReturn == true)
            #expect(result.restoredAfterThrow == true)
            #expect(result.maskedPasswordResult == "acd")
            #expect(result.maskedPasswordStderr == "API Key: **\u{08} \u{08}**\n")
            #expect(!result.maskedPasswordStderr.contains("acd"))
            #expect(result.echoRestoredAfterPassword == true)
            #expect(result.cancelledOnCtrlC == true)
            #expect(result.cancelledStderrHasNewline == true)
            #expect(result.echoRestoredAfterCancel == true)
        }
    }
}
