import Testing
import OpenCodeGUIPlugins

private actor MockPairingMainDriver: PairingMainDriver {
    var blockerCounter = 0
    var activeBlockers: Set<Int> = []
    var persistedScreen: [Bool] = []
    var executedArgs: [[String]] = []
    var remoteValue = false

    func startBlocker() async -> Int {
        blockerCounter += 1
        activeBlockers.insert(blockerCounter)
        return blockerCounter
    }

    func stopBlocker(id: Int) async {
        activeBlockers.remove(id)
    }

    func isBlockerStarted(id: Int) async -> Bool {
        activeBlockers.contains(id)
    }

    func persistScreenActive(_ enabled: Bool) async {
        persistedScreen.append(enabled)
    }

    func execService(attempt: Int, args: [String], timeoutMs: Int) async -> Result<String, PairingServiceError> {
        executedArgs.append(args)
        if args == ["get", "remote"] {
            return .success(remoteValue ? "true" : "false")
        }
        if args.prefix(2) == ["set", "remote"] {
            remoteValue = (args.last == "true")
            return .success("")
        }
        return .success("")
    }

    func abortService(attempt: Int) async {}
}

@Suite("Pairing Plugin Domain & State Machines")
struct PairingPluginTests {
    @Test("remoteAddress picks HTTPS origin and QR payload encodes exact JSON contract")
    func remoteAddressAndQRPayload() {
        let origin = PairingRemote.remoteAddress(urls: ["http://127.0.0.1:4096", "https://tunnel.opencode.ai:443/path"])
        #expect(origin == "https://tunnel.opencode.ai")

        let customPort = PairingRemote.remoteAddress(urls: ["https://remote.example.com:8443/foo"])
        #expect(customPort == "https://remote.example.com:8443")

        #expect(PairingRemote.remoteAddress(urls: ["http://localhost:4096"]) == nil)
        #expect(PairingRemote.connectURL(tunnel: "https://tunnel.opencode.ai", code: "ABC123") == "https://tunnel.opencode.ai/auth/connect/ABC123")
        #expect(
            PairingRemote.encodeQRPayload(code: "ABC123", tunnel: "https://tunnel.opencode.ai")
                == #"{"code":"ABC123","urls":["https://tunnel.opencode.ai"]}"#
        )
    }

    @Test("pairing window machine orchestrates remote enablement, tunnel polling, code expiry, and QR view")
    func pairingWindowLifecycle() {
        var state = PairingMachine.createState()
        state = PairingMachine.reduce(state: state, event: .serverChanged(available: true)).state
        let m1 = PairingMachine.reduce(state: state, event: .mainChanged(.active(generation: 1)))
        state = m1.state
        #expect(m1.effects == [
            .readRemote(generation: 1, attempt: 1, timeoutMs: PairingMachine.remoteReadTimeoutMs),
            .readScreen(generation: 1, attempt: 2, timeoutMs: PairingMachine.screenTimeoutMs),
        ])

        state = PairingMachine.reduce(state: state, event: .readSucceeded(attempt: 1, enabled: false)).state
        state = PairingMachine.reduce(state: state, event: .screenReadSucceeded(attempt: 2, enabled: false)).state
        #expect(!PairingMachine.viewPage(state).remoteChecked)
        #expect(!PairingMachine.viewPage(state).pairDisabled)

        // Opening dialog while remote is off automatically turns remote access on
        let open = PairingMachine.reduce(state: state, event: .dialogOpened)
        state = open.state
        #expect(open.effects == [
            .openDialog,
            .setRemote(generation: 1, attempt: 3, enabled: true, restart: false, timeoutMs: PairingMachine.remoteChangeTimeoutMs),
        ])
        #expect(PairingMachine.viewDialog(state.dialog) == .loading(setup: true))

        // Remote change succeeds -> begins tunnel polling
        let remoteOn = PairingMachine.reduce(state: state, event: .changeSucceeded(attempt: 3))
        state = remoteOn.state
        #expect(remoteOn.effects == [.abort(attempt: 3), .pollTunnel(attempt: 4, timeoutMs: PairingMachine.tunnelTimeoutMs)])

        // Tunnel found -> fetches pairing code
        let found = PairingMachine.reduce(state: state, event: .tunnelFound(attempt: 4, tunnel: "https://t.opencode.ai"))
        state = found.state
        #expect(found.effects == [.abort(attempt: 4), .fetchCode(attempt: 5, timeoutMs: PairingMachine.codeTimeoutMs)])
        #expect(PairingMachine.viewDialog(state.dialog) == .loading(setup: false))

        // Code loaded -> ready with URL, QR JSON, and countdown
        state = PairingMachine.reduce(state: state, event: .codeLoaded(attempt: 5, code: "PAIR99", expiresIn: 60, now: 10_000)).state
        #expect(
            PairingMachine.viewDialog(state.dialog) == .ready(
                url: "https://t.opencode.ai/auth/connect/PAIR99",
                qr: #"{"code":"PAIR99","urls":["https://t.opencode.ai"]}"#,
                refreshing: false
            )
        )
        #expect(PairingMachine.remainingSeconds(state.dialog, now: 25_000) == 45)

        // Clock tick at expiration triggers automatic background code refresh
        let expired = PairingMachine.reduce(state: state, event: .tick(now: 70_000))
        #expect(expired.effects == [.fetchCode(attempt: 6, timeoutMs: PairingMachine.codeTimeoutMs)])
    }

    @Test("pairing copy machine tracks copying, copied feedback, URL staleness, and failure")
    func copyMachineLifecycle() {
        let url1 = "https://t.opencode.ai/auth/connect/A"
        let url2 = "https://t.opencode.ai/auth/connect/B"
        var copy = PairingCopyMachine.createState()

        let c1 = PairingCopyMachine.reduce(state: copy, event: .copyRequested(url: url1))
        copy = c1.state
        #expect(c1.effects == [.cancelTimer, .write(attempt: 1, url: url1, timeoutMs: PairingCopyMachine.timeoutMs)])
        #expect(PairingCopyMachine.view(copy, url: url1).disabled)

        let c2 = PairingCopyMachine.reduce(state: copy, event: .copySucceeded(attempt: 1))
        copy = c2.state
        #expect(c2.effects == [.cancelTimer, .scheduleFeedback(attempt: 1, delayMs: PairingCopyMachine.feedbackMs)])
        #expect(PairingCopyMachine.view(copy, url: url1) == PairingCopyMachine.CopyView(icon: .check, label: .copied, disabled: false, error: false))
        // Different link never shows stale "Copied" feedback
        #expect(PairingCopyMachine.view(copy, url: url2) == PairingCopyMachine.CopyView(icon: .copy, label: .copyLink, disabled: false, error: false))

        copy = PairingCopyMachine.reduce(state: copy, event: .feedbackEnded(attempt: 1)).state
        #expect(PairingCopyMachine.view(copy, url: url1).label == .copyLink)
    }

    @Test("pairing main machine and controller serialize set-remote + service start and manage sleep blocker")
    func mainMachineAndController() async throws {
        let driver = MockPairingMainDriver()
        let controller = PairingController(driver: driver)

        #expect(try await controller.remoteEnabled() == false)
        try await controller.setRemoteEnabled(true)
        #expect(try await controller.remoteEnabled() == true)
        #expect(await driver.executedArgs == [
            ["get", "remote"],
            ["set", "remote", "true"],
            ["start"],
            ["get", "remote"],
        ])

        await controller.setScreenActive(true)
        #expect(await controller.blockerID() == 1)
        await controller.setScreenActive(false)
        #expect(await controller.blockerID() == nil)
        #expect(await driver.persistedScreen == [true, false])
    }

    @Test("pairing machine retries remote read with exponential backoff and handles screen retry")
    func pairingReadBackoffAndScreenRetry() {
        #expect(PairingMachine.remoteReadDelay(failures: 0) == 1_000)
        #expect(PairingMachine.remoteReadDelay(failures: 1) == 2_000)
        #expect(PairingMachine.remoteReadDelay(failures: 2) == 4_000)
        #expect(PairingMachine.remoteReadDelay(failures: 10) == 30_000)

        var state = PairingMachine.createState()
        state = PairingMachine.reduce(state: state, event: .mainChanged(.active(generation: 1))).state

        // 4 consecutive failures (initial + 3 retries) exhausts remote read into .failed
        let f1 = PairingMachine.reduce(state: state, event: .readFailed(attempt: 1))
        #expect(f1.effects == [.abort(attempt: 1), .wait(phase: .read, attempt: 3, delayMs: 1_000)])
        let w1 = PairingMachine.reduce(state: f1.state, event: .waitEnded(phase: .read, attempt: 3))
        let f2 = PairingMachine.reduce(state: w1.state, event: .readFailed(attempt: 4))
        let w2 = PairingMachine.reduce(state: f2.state, event: .waitEnded(phase: .read, attempt: 5))
        let f3 = PairingMachine.reduce(state: w2.state, event: .readFailed(attempt: 6))
        let w3 = PairingMachine.reduce(state: f3.state, event: .waitEnded(phase: .read, attempt: 7))
        let f4 = PairingMachine.reduce(state: w3.state, event: .readFailed(attempt: 8))
        #expect(PairingMachine.viewPage(f4.state).remoteError)

        // Screen retry recovers from failed screen read
        var s = PairingMachine.reduce(state: f4.state, event: .screenReadFailed(attempt: 2)).state
        s = PairingMachine.reduce(state: s, event: .waitEnded(phase: .screen, attempt: 9)).state
        s = PairingMachine.reduce(state: s, event: .screenReadFailed(attempt: 10)).state
        s = PairingMachine.reduce(state: s, event: .waitEnded(phase: .screen, attempt: 11)).state
        s = PairingMachine.reduce(state: s, event: .screenReadFailed(attempt: 12)).state
        s = PairingMachine.reduce(state: s, event: .waitEnded(phase: .screen, attempt: 13)).state
        s = PairingMachine.reduce(state: s, event: .screenReadFailed(attempt: 14)).state
        #expect(PairingMachine.viewPage(s).screenError)

        let retried = PairingMachine.reduce(state: s, event: .screenRetry)
        #expect(retried.effects == [.readScreen(generation: 1, attempt: 15, timeoutMs: PairingMachine.screenTimeoutMs)])
    }
}
