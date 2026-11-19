import Testing
import OpenCodeGUIPlugins
import OpenCodePlatform

private final class StubSSHExecutor: SSHCommandExecutor, @unchecked Sendable {
    let handler: @Sendable ([String], [String: String], [UInt8]?) async throws -> String
    init(handler: @escaping @Sendable ([String], [String: String], [UInt8]?) async throws -> String) {
        self.handler = handler
    }
    func run(args: [String], env: [String: String], stdin: [UInt8]?) async throws -> String {
        try await handler(args, env, stdin)
    }
}

private struct StubHTTPTransport: HTTPTransport {
    let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await handler(request)
    }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        HTTPStreamingResponse(head: HTTPResponseHead(statusCode: 200), chunks: AsyncThrowingStream { $0.finish() })
    }
}

private actor RecordingSSHDriver: SSHBackendDriver {
    var started: [(id: String, attempt: Int, replace: Bool)] = []
    var stopped: [Int] = []
    var responses: [(attempt: Int, promptID: String, value: String)] = []
    var savedConfigs: [[SSHConfig]] = []
    var healthResult = true

    func startAttempt(id: String, attempt: Int, config: SSHConfig, replace: Bool) async {
        started.append((id, attempt, replace))
    }
    func stopAttempt(attempt: Int) async {
        stopped.append(attempt)
    }
    func respondAttempt(attempt: Int, promptID: String, value: String) async {
        responses.append((attempt, promptID, value))
    }
    func scheduleRetry(id: String, attempt: Int, delayMs: Int) async {}
    func cancelRetry(attempt: Int) async {}
    func probeHealth(http: SSHHttp) async -> Bool { healthResult }
    func saveConfigs(_ configs: [SSHConfig]) async { savedConfigs.append(configs) }
}

@Suite("SSH Plugin Domain & State Machines")
struct SSHPluginTests {
    @Test("parses valid SSH targets, aliases, options, IPv6, and rejects unsafe inputs")
    func parseTargetValidation() throws {
        let parsed = try SSHCommand.parseTarget(#"ssh -p 2222 -i "~/.ssh/work key" -J gateway user@devbox"#)
        #expect(parsed == ParsedSSHTarget(host: "user@devbox", args: ["-p", "2222", "-i", "~/.ssh/work key", "-J", "gateway"]))

        #expect(try SSHCommand.parseTarget("devbox") == ParsedSSHTarget(host: "devbox", args: []))
        #expect(try SSHCommand.parseTarget("ssh user@[::1]").host == "user@[::1]")
        #expect(SSHCommand.sshArgs(for: parsed).contains("PermitLocalCommand=no"))
        #expect(SSHCommand.quote("a'b") == "'a'\\''b'")

        let rejectedInputs = [
            "",
            "ssh host whoami",
            "host;whoami",
            "ssh user:password@host",
            "ssh -t host",
            "ssh -o RemoteCommand=whoami host",
            "ssh -L 1234:x:80 host",
            "ssh -p 70000 host",
            #"ssh -i "key host"#,
            "host\nwhoami",
        ]
        for bad in rejectedInputs {
            #expect(throws: SSHFailure.self) {
                _ = try SSHCommand.parseTarget(bad)
            }
        }
    }

    @Test("builds tunnel args overriding ControlMaster and redacts registration blocks in failure details")
    func tunnelAndRedaction() {
        let target = ParsedSSHTarget(
            host: "devbox",
            args: ["-o", "ControlMaster=auto", "-o", "ControlPersist=60", "-o", "ControlPath=/test/socket"]
        )
        let args = SSHCommand.tunnelArgs(for: target, localPort: 1234, remoteHost: "127.0.0.1", remotePort: 5678)
        #expect(Array(args.prefix(4)) == ["-o", "ControlMaster=no", "-o", "ControlPersist=no"])
        #expect(args.contains("ControlPath=/test/socket"))
        #expect(Array(args.suffix(4)) == ["-L", "127.0.0.1:1234:127.0.0.1:5678", "devbox", "sh -c 'exec cat >/dev/null'"])

        let redacted = SSHCommand.commandFailureDetail(
            exitCode: 1,
            stdout: "OPENCODE_SSH_REGISTRATION_BEGIN\n{\"password\":\"secret\"}\nOPENCODE_SSH_REGISTRATION_END\nFailed to read next file",
            stderr: ""
        )
        #expect(redacted == "Failed to read next file")

        let truncatedRedaction = SSHCommand.commandFailureDetail(
            exitCode: 1,
            stdout: "OPENCODE_SSH_REGISTRATION_BEGIN\n{\"password\":\"secret\"}",
            stderr: "read interrupted"
        )
        #expect(truncatedRedaction == "read interrupted")
        #expect(SSHCommand.commandFailureDetail(exitCode: 255, stdout: "", stderr: "") == "{\"exitCode\":255}")
    }

    @Test("naming helpers extract hostnames and map server states accurately")
    func namingAndServerState() {
        #expect(SSHNaming.hostname("ssh -p 2222 alice@prod.example.com") == "prod.example.com")
        #expect(SSHNaming.name(SSHConfig(id: "1", target: "alice@box", name: "")) == "box")
        #expect(SSHNaming.name(SSHConfig(id: "1", target: "alice@box", name: "Prod")) == "Prod")

        let authElsewhere = SSHItem(
            config: SSHConfig(id: "1", target: "box", name: "Box"),
            saved: true,
            stage: .authentication,
            authenticatingElsewhere: true
        )
        #expect(SSHNaming.serverState(authElsewhere) == .starting)
        let authHere = SSHItem(
            config: SSHConfig(id: "1", target: "box", name: "Box"),
            saved: true,
            stage: .authentication,
            authenticatingElsewhere: false
        )
        #expect(SSHNaming.serverState(authHere) == .auth)
    }

    @Test("askpass protocol validates token, encodes response, and serializes concurrent prompts")
    func askpassCoordinator() async throws {
        let env = SSHAskpassProtocol.environment(binary: "/bin/askpass", port: 43210, token: "tok-1", existingDisplay: "")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["DISPLAY"] == "opencode")
        #expect(env["OPENCODE_SSH_ASKPASS_PORT"] == "43210")

        #expect(throws: SSHFailure.self) {
            _ = try SSHAskpassProtocol.decodeRequest("{\"token\":\"wrong\",\"text\":\"Pass\",\"confirm\":false}\n", expectedToken: "tok-1")
        }

        let coordinator = SSHAskpassCoordinator(
            token: "tok-1",
            onPrompt: { _ in },
            onClear: { _ in }
        )

        let task = Task {
            try await coordinator.handleRequestLine("{\"token\":\"tok-1\",\"text\":\"Password:\",\"confirm\":false}\n")
        }

        var promptID: String?
        for _ in 0..<50 {
            if let current = await coordinator.currentPromptID() {
                promptID = current
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = try #require(promptID)
        await coordinator.respond(promptID: id, value: "s3cr3t")
        let response = try await task.value
        #expect(response == "{\"value\":\"s3cr3t\"}")
    }

    @Test("bootstrap parses registration, validates loopback address, and falls back to archive upload")
    func bootstrapLifecycle() async throws {
        let output = """
        OPENCODE_SSH_STATUS=http://127.0.0.1:4096
        OPENCODE_SSH_REGISTRATION_BEGIN
        {"url":"http://127.0.0.1:4096","password":"pw","version":"2.0.0","pid":999}
        OPENCODE_SSH_REGISTRATION_END
        """
        let reg = try #require(SSHBootstrap.parseRegistration(output))
        #expect(reg.pid == 999)
        #expect(reg.version == "2.0.0")

        let addr = try SSHBootstrap.connectionAddress(urlString: "http://[::1]:8080", password: "pw")
        #expect(addr == SSHBootstrapAddress(host: "[::1]", port: 8080, password: "pw"))
        #expect(throws: SSHFailure.self) {
            _ = try SSHBootstrap.connectionAddress(urlString: "http://10.0.0.5:8080", password: "pw")
        }

        // Exercise fallback upload path when remote curl download fails
        let target = try SSHCommand.parseTarget("devbox")
        let executor = StubSSHExecutor { args, _, stdin in
            let script = stdin.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if script.contains("OPENCODE_REMOTE_TARGET=") {
                return "OPENCODE_REMOTE_TARGET=linux-arm64\n"
            }
            if script.contains("curl -fsSL --connect-timeout 15") {
                throw SSHFailure(code: .connection, detail: "no internet on remote")
            }
            if args.last?.contains("tar -xzf") == true {
                #expect(stdin == [1, 2, 3, 4])
                return ""
            }
            if script.contains("service start") {
                return output
            }
            return ""
        }
        let http = StubHTTPTransport { req in
            #expect(req.url == "https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.0.0.tgz")
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: [1, 2, 3, 4])
        }
        let connected = try await SSHBootstrap.run(
            target: target,
            version: "2.0.0",
            executor: executor,
            httpTransport: http
        )
        #expect(connected == SSHBootstrapAddress(host: "127.0.0.1", port: 4096, password: "pw"))
    }

    @Test("SSH add and dialog state machines manage chunk loading, prompts, and incompatible updates")
    func addAndDialogMachines() {
        var addState = SSHAddMachine.initialState
        let t1: GUIStateTransition<SSHAddMachine.State, SSHAddMachine.Effect<String>> = SSHAddMachine.reduce(
            state: addState,
            event: .addRequested(openProject: false)
        )
        addState = t1.state
        #expect(t1.effects == [.load(attempt: 1)])
        // Second click requesting openProject upgrades the in-flight load
        let t2: GUIStateTransition<SSHAddMachine.State, SSHAddMachine.Effect<String>> = SSHAddMachine.reduce(
            state: addState,
            event: .addRequested(openProject: true)
        )
        #expect(t2.state == .loading(attempt: 1, openProject: true))
        let t3: GUIStateTransition<SSHAddMachine.State, SSHAddMachine.Effect<String>> = SSHAddMachine.reduce(
            state: t2.state,
            event: .addLoaded(attempt: 1, module: "DialogModule")
        )
        #expect(t3.state == .idle(issued: 1))
        #expect(t3.effects == [.open(module: "DialogModule", openProject: true)])

        // Dialog machine flow: edit -> submit -> prompt -> respond -> ready
        var dialog = SSHDialogMachine.createState(id: "srv-1")
        dialog = SSHDialogMachine.reduce(state: dialog, event: .targetChanged("alice@box")).state
        let submit = SSHDialogMachine.reduce(state: dialog, event: .submitted(snapshot: SSHDialogMachine.Snapshot()))
        dialog = submit.state
        #expect(submit.effects == [.connect(config: SSHConfig(id: "srv-1", target: "alice@box", name: ""), replace: false)])

        let prompt = SSHPrompt(id: "p1", text: "Trust host key?", confirm: true)
        let authItem = SSHItem(config: SSHConfig(id: "srv-1", target: "alice@box", name: ""), saved: false, stage: .authentication, prompt: prompt)
        dialog = SSHDialogMachine.reduce(state: dialog, event: .synced(snapshot: SSHDialogMachine.Snapshot(item: authItem, activeAttempt: true))).state
        let view = SSHDialogMachine.view(state: dialog, snapshot: SSHDialogMachine.Snapshot(item: authItem, activeAttempt: true))
        #expect(view.primary.action == .respond)
        #expect(view.primary.label == .trust)
        #expect(!view.primary.disabled)

        let responded = SSHDialogMachine.reduce(state: dialog, event: .responded(snapshot: SSHDialogMachine.Snapshot(item: authItem, activeAttempt: true)))
        #expect(responded.effects == [.respond(prompt: "p1", value: "yes")])

        let readyItem = SSHItem(config: SSHConfig(id: "srv-1", target: "alice@box", name: ""), saved: true, stage: .ready, http: SSHHttp(url: "http://127.0.0.1:9999", password: "pw"))
        let done = SSHDialogMachine.reduce(state: dialog, event: .synced(snapshot: SSHDialogMachine.Snapshot(item: readyItem)))
        #expect(done.effects == [.complete])
    }

    @Test("SSH main & window machines enforce owner isolation, retry budgets, and host-key classification")
    func mainAndWindowMachinesAndController() async {
        let cfg = SSHConfig(id: "prod-1", target: "alice@prod", name: "Prod")
        var main = SSHMainMachine.createState(configs: [cfg])

        // Start from window 1
        let started = SSHMainMachine.reduce(state: main, event: .start(request: SSHStart(id: "prod-1", target: "alice@prod", name: "Prod"), owner: 1))
        main = started.state
        #expect(started.effects == [.attemptStart(id: "prod-1", attempt: 1, config: cfg, replace: false)])

        // Prompt visible only to owner window 1, not window 2
        let prompt = SSHPrompt(id: "p1", text: "Password:", confirm: false)
        main = SSHMainMachine.reduce(state: main, event: .promptReceived(id: "prod-1", attempt: 1, prompt: prompt)).state
        #expect(SSHMainMachine.selectServers(state: main, viewer: 1).first?.prompt == prompt)
        #expect(SSHMainMachine.selectServers(state: main, viewer: 2).first?.prompt == nil)
        #expect(SSHMainMachine.selectServers(state: main, viewer: 2).first?.authenticatingElsewhere == true)

        // Host key failure classifies as non-retryable .hostKey
        let failed = SSHMainMachine.reduce(
            state: main,
            event: .attemptFailed(id: "prod-1", attempt: 1, code: .connection, detail: "Host key verification failed")
        )
        #expect(SSHMainMachine.selectServers(state: failed.state, viewer: 1).first?.error == .hostKey)
        #expect(SSHMainMachine.selectServers(state: failed.state, viewer: 1).first?.retrying == nil)

        // Window machine restores saved disconnected server once
        var window = SSHWindowMachine.createState()
        let disconnectedItem = SSHItem(config: cfg, saved: true, stage: .disconnected)
        let sync1 = SSHWindowMachine.reduce(state: window, event: .itemsSynced(ipcActive: true, items: [disconnectedItem]))
        window = sync1.state
        #expect(sync1.effects == [.rpcRestore(config: cfg)])
        let sync2 = SSHWindowMachine.reduce(state: window, event: .itemsSynced(ipcActive: true, items: [disconnectedItem]))
        #expect(sync2.effects.isEmpty)

        // Actor controller end-to-end
        let driver = RecordingSSHDriver()
        let controller = SSHController(configs: [cfg], driver: driver)
        let rev = await controller.start(SSHStart(id: "prod-1", target: "alice@prod", name: "Prod"), owner: 1)
        #expect(rev == 1)
        await controller.report(.attemptReady(id: "prod-1", attempt: 1, http: SSHHttp(url: "http://127.0.0.1:4100", password: "pw")))
        let resolved = await controller.resolve(id: "prod-1")
        #expect(resolved == SSHHttp(url: "http://127.0.0.1:4100", password: "pw"))
    }

    @Test("SSH main machine schedules retries for saved servers, detaches owner attempts, and handles forget")
    func mainMachineRetriesDetachAndForget() {
        let cfg = SSHConfig(id: "box-1", target: "dev@box", name: "Box")
        var state = SSHMainMachine.createState(configs: [cfg])
        state = SSHMainMachine.reduce(state: state, event: .start(request: SSHStart(id: "box-1", target: "dev@box", name: "Box"), owner: 7)).state

        // Transient failure schedules automatic retry for saved server
        let f1 = SSHMainMachine.reduce(state: state, event: .attemptFailed(id: "box-1", attempt: 1, code: .connection, detail: "Connection timed out"))
        state = f1.state
        #expect(f1.effects == [.retrySchedule(id: "box-1", attempt: 2, delayMs: SSHMainMachine.retryDelayMs)])
        #expect(SSHMainMachine.selectServers(state: state, viewer: 7).first?.retrying == true)

        // Retry due starts a new background attempt
        let r1 = SSHMainMachine.reduce(state: state, event: .retryDue(id: "box-1", attempt: 2))
        state = r1.state
        #expect(r1.effects == [.attemptStart(id: "box-1", attempt: 3, config: cfg, replace: false)])

        // Background attempt receiving a prompt pauses in .authentication and stops attempt
        let bgPrompt = SSHMainMachine.reduce(
            state: state,
            event: .promptReceived(id: "box-1", attempt: 3, prompt: SSHPrompt(id: "p", text: "Pass", confirm: false))
        )
        state = bgPrompt.state
        #expect(bgPrompt.effects == [.attemptStop(attempt: 3)])
        #expect(SSHMainMachine.selectServers(state: state, viewer: 7).first?.stage == .authentication)

        // Window detach cancels active owned attempt and restores resting phase
        state = SSHMainMachine.reduce(state: state, event: .start(request: SSHStart(id: "box-1", target: "dev@box", name: "Box"), owner: 9)).state
        let detached = SSHMainMachine.reduce(state: state, event: .windowDetached(owner: 9))
        #expect(detached.effects == [.attemptStop(attempt: 4)])
        #expect(SSHMainMachine.selectServers(state: detached.state, viewer: 9).first?.stage == .authentication)

        // Forget removes saved server and emits configsSave
        let forgotten = SSHMainMachine.reduce(state: detached.state, event: .forget(id: "box-1"))
        #expect(forgotten.state.servers.isEmpty)
        #expect(forgotten.effects == [.configsSave(configs: [])])
    }

    @Test("SSH window machine enforces once-per-visit cover offer, prompt target selection, and dialog failure cancel")
    func windowMachineCoverOfferAndDialogFailure() {
        let cfg = SSHConfig(id: "s1", target: "dev@s1", name: "S1")
        let prompt = SSHPrompt(id: "pr1", text: "Code:", confirm: false)
        let authItem = SSHItem(config: cfg, saved: true, stage: .authentication, prompt: prompt)

        var state = SSHWindowMachine.createState()
        #expect(SSHWindowMachine.canOffer(state: state, id: "s1", path: "/s1", dialogActive: false, ipcActive: true, item: authItem))

        // First cover offer starts connect and consumes offer for this visit
        let offered = SSHWindowMachine.reduce(
            state: state,
            event: .coverOffered(id: "s1", path: "/s1", dialogActive: false, ipcActive: true, item: authItem)
        )
        state = offered.state
        #expect(offered.effects == [.rpcStart(id: "s1", attempt: 1, config: cfg, replace: false)])
        #expect(!SSHWindowMachine.canOffer(state: state, id: "s1", path: "/s1", dialogActive: false, ipcActive: true, item: authItem))

        // Confirming start enters waiting, making server eligible as promptTarget
        state = SSHWindowMachine.reduce(state: state, event: .startConfirmed(id: "s1", attempt: 1, item: authItem)).state
        let target = SSHWindowMachine.promptTarget(state: state, items: [authItem])
        #expect(target == SSHWindowMachine.PromptTarget(item: authItem, attempt: 1))

        // Dialog chunk loading -> fails -> cancels attempt & shows toast
        state = SSHWindowMachine.reduce(state: state, event: .dialogLoading(id: "s1", attempt: 1)).state
        #expect(SSHWindowMachine.canOpenDialog(state: state, id: "s1", attempt: 1))
        let failed = SSHWindowMachine.reduce(state: state, event: .dialogFailed(id: "s1", attempt: 1, saved: true))
        #expect(failed.effects == [.toastError, .rpcCancel(id: "s1", forget: false)])
        #expect(SSHWindowMachine.error(state: failed.state, id: "s1"))
    }
}
