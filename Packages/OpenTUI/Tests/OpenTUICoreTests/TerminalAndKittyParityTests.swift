import OpenTUICore
import OpenTUIRenderables
import OpenTUITerminal
import Synchronization
import Testing

#if os(macOS)
import Darwin
#elseif os(Linux) || os(FreeBSD)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#endif

// MARK: - Helpers

private func substringByteOffset(of needle: String, in haystack: String) -> Int? {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty, n.count <= h.count else { return nil }
    for i in 0...(h.count - n.count) {
        var matched = true
        for j in 0..<n.count {
            if h[i + j] != n[j] {
                matched = false
                break
            }
        }
        if matched { return i }
    }
    return nil
}

private func waitUntil(
    timeoutMs: Int = 2_000,
    pollMs: Int = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
    while !condition() {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return true
}

private struct ForcedBodyFailure: Error {}

private final class AtomicFlag: Sendable {
    private let state = Mutex(false)

    var value: Bool {
        state.withLock { $0 }
    }

    func set() {
        state.withLock { $0 = true }
    }
}

private final class MarkerTextRenderable: Renderable, @unchecked Sendable {
    var label: String

    init(ctx: any RenderContext, label: String) {
        self.label = label
        super.init(ctx: ctx, options: RenderableOptions(width: .percent(100), height: .point(1)))
    }

    override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        buffer.drawText(label, x: origin.x, y: origin.y, fg: RGBA.fromInts(255, 255, 255, 255))
    }
}

// MARK: - Kitty Keyboard Protocol Push / Pop Parity Tests

@Suite("KittyKeyboardProtocolParity")
struct KittyKeyboardProtocolParityTests {
    @Test("runWithTerminalBackend emits Kitty push (ESC[>5u) on setup and pop (ESC[<u) on teardown when KittyKeyboardOptions() is configured")
    func runWithTerminalBackendEmitsKittyPushAndPop() async throws {
        let backend = MemoryTerminalBackend(size: TerminalSize(width: 80, height: 24))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: 80,
                height: 24,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useMouse: true,
                useKittyKeyboard: KittyKeyboardOptions(),
                clock: ManualClock()
            )
        )
        #expect(renderer.activeKittyKeyboardFlags == 5)
        renderer.root.add(MarkerTextRenderable(ctx: renderer, label: "KITTY-ON"))

        try await runWithTerminalBackend(renderer: renderer, backend: backend) { _, _ in
            #expect(await backend.isRawMode == true)
        }

        #expect(await backend.isRawMode == false)
        #expect(renderer.isDestroyed == true)

        let output = await backend.renderedOutput
        let pushSeq = "\u{1B}[>5u"
        let popSeq = "\u{1B}[<u"

        let pushIdx = try #require(substringByteOffset(of: pushSeq, in: output))
        let bodyIdx = try #require(substringByteOffset(of: "KITTY-ON", in: output))
        let popIdx = try #require(substringByteOffset(of: popSeq, in: output))
        let mainScreenIdx = try #require(substringByteOffset(of: ANSI.switchToMainScreen, in: output))

        #expect(pushIdx < bodyIdx)
        #expect(bodyIdx < popIdx)
        #expect(popIdx < mainScreenIdx)
    }

    @Test("runWithTerminalBackend omits Kitty push and pop when useKittyKeyboard is nil")
    func runWithTerminalBackendOmitsKittyWhenNil() async throws {
        let backend = MemoryTerminalBackend(size: TerminalSize(width: 80, height: 24))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: 80,
                height: 24,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useMouse: false,
                useKittyKeyboard: nil,
                clock: ManualClock()
            )
        )
        #expect(renderer.activeKittyKeyboardFlags == 0)
        renderer.root.add(MarkerTextRenderable(ctx: renderer, label: "KITTY-OFF"))

        try await runWithTerminalBackend(renderer: renderer, backend: backend) { _, _ in }

        let output = await backend.renderedOutput
        #expect(output.contains("KITTY-OFF"))
        #expect(output.contains("\u{1B}[?2004h"))
        #expect(output.contains("\u{1B}[?2004l"))
        #expect(!output.contains("\u{1B}[>"))
        #expect(!output.contains("\u{1B}[<u"))
    }

    @Test("runWithTerminalBackend encodes custom Kitty flags bitmask and respects manageTerminalModes == false")
    func runWithTerminalBackendCustomKittyFlagsAndModeGuard() async throws {
        // 1. All 5 Kitty flags enabled => 1 | 2 | 4 | 8 | 16 = 31 => ESC[>31u / ESC[<u
        let fullBackend = MemoryTerminalBackend(size: TerminalSize(width: 60, height: 16))
        let fullKitty = KittyKeyboardOptions(
            disambiguate: true,
            alternateKeys: true,
            events: true,
            allKeysAsEscapes: true,
            reportText: true
        )
        let fullRenderer = CliRenderer(
            config: CliRendererConfig(
                width: 60,
                height: 16,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useMouse: false,
                useKittyKeyboard: fullKitty,
                clock: ManualClock()
            )
        )
        #expect(fullRenderer.activeKittyKeyboardFlags == 31)

        try await runWithTerminalBackend(renderer: fullRenderer, backend: fullBackend) { _, _ in }

        let fullOutput = await fullBackend.renderedOutput
        #expect(fullOutput.contains("\u{1B}[>31u"))
        #expect(fullOutput.contains("\u{1B}[<u"))

        // 2. manageTerminalModes: false emits neither push nor pop
        let rawBackend = MemoryTerminalBackend(size: TerminalSize(width: 60, height: 16))
        let rawRenderer = CliRenderer(
            config: CliRendererConfig(
                width: 60,
                height: 16,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useMouse: false,
                useKittyKeyboard: KittyKeyboardOptions(),
                clock: ManualClock()
            )
        )
        try await runWithTerminalBackend(
            renderer: rawRenderer,
            backend: rawBackend,
            options: TerminalBackendRunOptions(manageTerminalModes: false)
        ) { _, _ in }

        let rawOutput = await rawBackend.renderedOutput
        #expect(!rawOutput.contains("\u{1B}[>5u"))
        #expect(!rawOutput.contains("\u{1B}[<u"))
    }

    @Test("runWithTerminalBackend still emits Kitty pop (ESC[<u) and exits raw mode when body throws")
    func runWithTerminalBackendPopsKittyOnBodyError() async throws {
        let backend = MemoryTerminalBackend(size: TerminalSize(width: 70, height: 20))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: 70,
                height: 20,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useKittyKeyboard: KittyKeyboardOptions(),
                clock: ManualClock()
            )
        )

        await #expect(throws: ForcedBodyFailure.self) {
            try await runWithTerminalBackend(renderer: renderer, backend: backend) { _, _ in
                throw ForcedBodyFailure()
            }
        }

        #expect(await backend.isRawMode == false)
        #expect(renderer.isDestroyed == true)
        let output = await backend.renderedOutput
        #expect(output.contains("\u{1B}[>5u"))
        #expect(output.contains("\u{1B}[<u"))
        #expect(output.contains(ANSI.switchToMainScreen))
    }

    @Test("SSHCliRendererAdapter emits Kitty push/pop when enabled and omits both when useKittyKeyboard is nil")
    func sshCliRendererAdapterKittyPushPopParity() async throws {
        let hostKey = generateEd25519KeyPair()

        // Enabled case
        do {
            let driver = InMemorySSHTransportDriver()
            let ready = AtomicFlag()
            let server = try createCliSSHServer(
                config: SSHServerConfig(auth: .open, hostKey: .pem(hostKey.privatePem), startupBanner: false),
                rendererConfig: SSHCliRendererConfig(
                    screenMode: .alternateScreen,
                    exitOnCtrlC: false,
                    useMouse: false,
                    useKittyKeyboard: KittyKeyboardOptions(),
                    clockFactory: { ManualClock() }
                ),
                driver: driver
            )
            .serve { session in
                guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else { return }
                cli.root.add(MarkerTextRenderable(ctx: cli, label: "SSH-KITTY-ON"))
                cli.renderOnce(force: true)
                await adapter.flushOutput()
                ready.set()
                cli.destroy()
            }

            _ = try await server.listen(port: 0, host: "127.0.0.1")
            let client = driver.connect()
            #expect(await client.authenticate(method: "none", username: "dev") == .accepted)
            client.emitReady()
            let sess = client.openSession()
            sess.requestPty(term: "xterm-256color", cols: 60, rows: 16)
            let channel = try #require(sess.requestShell())

            #expect(await waitUntil { ready.value && channel.isClosed })
            let out = channel.writtenText
            #expect(out.contains("\u{1B}[>5u"))
            #expect(out.contains("SSH-KITTY-ON"))
            #expect(out.contains("\u{1B}[<u"))
            await server.close()
        }

        // Disabled case (useKittyKeyboard: nil)
        do {
            let driver = InMemorySSHTransportDriver()
            let ready = AtomicFlag()
            let server = try createCliSSHServer(
                config: SSHServerConfig(auth: .open, hostKey: .pem(hostKey.privatePem), startupBanner: false),
                rendererConfig: SSHCliRendererConfig(
                    screenMode: .alternateScreen,
                    exitOnCtrlC: false,
                    useMouse: false,
                    useKittyKeyboard: nil,
                    clockFactory: { ManualClock() }
                ),
                driver: driver
            )
            .serve { session in
                guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else { return }
                cli.root.add(MarkerTextRenderable(ctx: cli, label: "SSH-KITTY-OFF"))
                cli.renderOnce(force: true)
                await adapter.flushOutput()
                ready.set()
                cli.destroy()
            }

            _ = try await server.listen(port: 0, host: "127.0.0.1")
            let client = driver.connect()
            #expect(await client.authenticate(method: "none", username: "dev") == .accepted)
            client.emitReady()
            let sess = client.openSession()
            sess.requestPty(term: "xterm-256color", cols: 60, rows: 16)
            let channel = try #require(sess.requestShell())

            #expect(await waitUntil { ready.value && channel.isClosed })
            let out = channel.writtenText
            #expect(out.contains("SSH-KITTY-OFF"))
            #expect(!out.contains("\u{1B}[>"))
            #expect(!out.contains("\u{1B}[<u"))
            await server.close()
        }
    }
}

// MARK: - POSIX SIGWINCH Self-Pipe Wakeup Tests

#if os(macOS) || ((os(Linux) || os(FreeBSD)) && (canImport(Glibc) || canImport(Musl)))

private struct PosixPTY: Sendable {
    let masterFD: Int32
    let slaveFD: Int32

    static func openPair(width: UInt16 = 80, height: UInt16 = 24) -> PosixPTY? {
        #if canImport(Darwin)
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            _ = closeFD(master)
            return nil
        }
        let slave = open(namePtr, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            _ = closeFD(master)
            return nil
        }
        let pair = PosixPTY(masterFD: master, slaveFD: slave)
        pair.setSize(width: width, height: height)
        return pair
        #else
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: height, ws_col: width, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            return nil
        }
        return PosixPTY(masterFD: master, slaveFD: slave)
        #endif
    }

    func setSize(width: UInt16, height: UInt16) {
        var ws = winsize(ws_row: height, ws_col: width, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
    }

    func writeToMaster(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            #if os(macOS)
            _ = Darwin.write(masterFD, base, raw.count)
            #elseif canImport(Glibc)
            _ = Glibc.write(masterFD, base, raw.count)
            #elseif canImport(Musl)
            _ = Musl.write(masterFD, base, raw.count)
            #endif
        }
    }

    func closeAll() {
        _ = Self.closeFD(slaveFD)
        _ = Self.closeFD(masterFD)
    }

    @discardableResult
    private static func closeFD(_ fd: Int32) -> Int32 {
        #if os(macOS)
        return Darwin.close(fd)
        #elseif canImport(Glibc)
        return Glibc.close(fd)
        #elseif canImport(Musl)
        return Musl.close(fd)
        #endif
    }
}

private let sentinelSigwinchHandler: @convention(c) (Int32) -> Void = { _ in }

private func currentSigwinchHandlerAddress() -> UInt {
    var act = sigaction()
    guard sigaction(SIGWINCH, nil, &act) == 0 else { return 0 }
    #if os(macOS) || os(FreeBSD)
    return unsafeBitCast(act.__sigaction_u.__sa_handler, to: UInt.self)
    #elseif canImport(Glibc)
    return unsafeBitCast(act.__sigaction_handler.sa_handler, to: UInt.self)
    #elseif canImport(Musl)
    return unsafeBitCast(act.__sa_handler.sa_handler, to: UInt.self)
    #endif
}

@Suite("PlatformTerminalSigwinchWakeup", .serialized)
struct PlatformTerminalSigwinchWakeupTests {
    @Test("SIGWINCH self-pipe wakes pollRead(timeoutMs: 5000) in <250ms, refreshes cachedSize, and reports resize signal")
    func sigwinchWakesPollReadImmediately() async throws {
        let pty = try #require(PosixPTY.openPair(width: 80, height: 24))
        defer { pty.closeAll() }

        let backend = PlatformTerminalBackend(
            inputFD: pty.slaveFD,
            outputFD: pty.slaveFD,
            defaultSize: TerminalSize(width: 80, height: 24)
        )
        #expect(backend.isInteractiveTerminal)
        #expect(await backend.size == TerminalSize(width: 80, height: 24))
        #expect(backend.cachedSize == TerminalSize(width: 80, height: 24))

        try await backend.enterRawMode()
        do {
            #expect(await backend.isRawMode == true)
            #expect(backend.didResizeSinceLastPoll == false)

            // Deliver PTY resize + SIGWINCH after 25ms while pollRead waits with a 5000ms timeout
            let signalTask = Task.detached {
                try? await Task.sleep(for: .milliseconds(25))
                pty.setSize(width: 132, height: 42)
                _ = kill(getpid(), SIGWINCH)
            }

            let clock = ContinuousClock()
            let start = clock.now
            let bytes = try backend.pollRead(maxBytes: 4096, timeoutMs: 5_000)
            let elapsed = start.duration(to: clock.now)
            await signalTask.value

            #expect(bytes.isEmpty)
            #expect(elapsed < .milliseconds(250), "Expected SIGWINCH wakeup <250ms, elapsed=\(elapsed)")
            #expect(backend.didResizeSinceLastPoll == true)
            #expect(backend.cachedSize == TerminalSize(width: 132, height: 42))
            #expect(await backend.size == TerminalSize(width: 132, height: 42))

            // consumeResizeSignal() reports true once and clears the flag
            #expect(backend.consumeResizeSignal() == true)
            #expect(backend.didResizeSinceLastPoll == false)
            #expect(backend.consumeResizeSignal() == false)
        } catch {
            try? await backend.exitRawMode()
            throw error
        }

        try await backend.exitRawMode()
        #expect(await backend.isRawMode == false)
    }

    @Test("Pre-poll SIGWINCH burst wakes pollRead immediately without lost-signal race and drains all wake bytes")
    func prePollSigwinchBurstCoalescesCleanly() async throws {
        let pty = try #require(PosixPTY.openPair(width: 90, height: 30))
        defer { pty.closeAll() }

        let backend = PlatformTerminalBackend(inputFD: pty.slaveFD, outputFD: pty.slaveFD)
        try await backend.enterRawMode()
        do {
            // Resize PTY and deliver a burst of 5 process-wide SIGWINCH signals BEFORE calling pollRead.
            // Brief sleep lets the unblocked signal-receiving thread run the handler and enqueue all
            // wake bytes into the self-pipe before pollRead starts (verifying zero lost-signal race).
            pty.setSize(width: 120, height: 36)
            for _ in 0..<5 {
                _ = kill(getpid(), SIGWINCH)
            }
            try await Task.sleep(for: .milliseconds(10))

            let clock = ContinuousClock()
            let start = clock.now
            let bytes = try backend.pollRead(maxBytes: 4096, timeoutMs: 5_000)
            let elapsed = start.duration(to: clock.now)

            #expect(bytes.isEmpty)
            #expect(elapsed < .milliseconds(100))
            #expect(backend.didResizeSinceLastPoll == true)
            #expect(backend.cachedSize == TerminalSize(width: 120, height: 36))

            // A subsequent pollRead with no new SIGWINCH must NOT report a stale resize
            let followUp = try backend.pollRead(maxBytes: 4096, timeoutMs: 15)
            #expect(followUp.isEmpty)
            #expect(backend.didResizeSinceLastPoll == false)

            // consumeResizeSignal() also drains a pending SIGWINCH directly without needing pollRead
            pty.setSize(width: 104, height: 28)
            _ = kill(getpid(), SIGWINCH)
            #expect(await waitUntil(timeoutMs: 250) { backend.consumeResizeSignal() })
            #expect(backend.cachedSize == TerminalSize(width: 104, height: 28))
            #expect(backend.consumeResizeSignal() == false)
        } catch {
            try? await backend.exitRawMode()
            throw error
        }

        try await backend.exitRawMode()
    }

    @Test("pollRead delivers normal PTY input bytes while SIGWINCH watcher is active without false resize")
    func pollReadDeliversInputBytesNormally() async throws {
        let pty = try #require(PosixPTY.openPair(width: 80, height: 24))
        defer { pty.closeAll() }

        let backend = PlatformTerminalBackend(inputFD: pty.slaveFD, outputFD: pty.slaveFD)
        try await backend.enterRawMode()
        do {
            pty.writeToMaster(Array("ping".utf8))
            let bytes = try backend.pollRead(maxBytes: 64, timeoutMs: 1_000)

            #expect(bytes == Array("ping".utf8))
            #expect(backend.didResizeSinceLastPoll == false)
            #expect(backend.consumeResizeSignal() == false)

            // Simultaneous PTY input + SIGWINCH preserves BOTH bytes and resize flag
            pty.setSize(width: 112, height: 34)
            _ = kill(getpid(), SIGWINCH)
            try await Task.sleep(for: .milliseconds(10))
            pty.writeToMaster(Array("ok".utf8))
            let both = try backend.pollRead(maxBytes: 64, timeoutMs: 1_000)
            #expect(both == Array("ok".utf8))
            #expect(backend.didResizeSinceLastPoll == true)
            #expect(backend.cachedSize == TerminalSize(width: 112, height: 34))
            #expect(backend.consumeResizeSignal() == true)
        } catch {
            try? await backend.exitRawMode()
            throw error
        }

        try await backend.exitRawMode()
    }

    @Test("exitRawMode wakes an in-flight pollRead cleanly via wake pipe teardown without a false resize flag")
    func exitRawModeWakesInFlightPollReadCleanly() async throws {
        let pty = try #require(PosixPTY.openPair(width: 80, height: 24))
        defer { pty.closeAll() }

        let backend = PlatformTerminalBackend(inputFD: pty.slaveFD, outputFD: pty.slaveFD)
        try await backend.enterRawMode()

        let exitTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(25))
            try? await backend.exitRawMode()
        }

        let clock = ContinuousClock()
        let start = clock.now
        let bytes = try backend.pollRead(maxBytes: 4096, timeoutMs: 5_000)
        let elapsed = start.duration(to: clock.now)
        await exitTask.value

        #expect(bytes.isEmpty)
        #expect(elapsed < .milliseconds(250), "Expected exitRawMode wakeup <250ms, elapsed=\(elapsed)")
        #expect(backend.didResizeSinceLastPoll == false)
        #expect(await backend.isRawMode == false)
    }

    @Test("Previous SIGWINCH signal action is restored cleanly on exitRawMode() and on deinit")
    func restoresPreviousSigwinchActionOnExitAndDeinit() async throws {
        let pty = try #require(PosixPTY.openPair(width: 80, height: 24))
        defer { pty.closeAll() }

        // Install a known sentinel SIGWINCH action and restore original after this test
        var originalAction = sigaction()
        _ = sigaction(SIGWINCH, nil, &originalAction)
        defer {
            var restore = originalAction
            _ = sigaction(SIGWINCH, &restore, nil)
        }

        #if os(macOS) || os(FreeBSD)
        var sentinelAction = sigaction()
        sentinelAction.__sigaction_u.__sa_handler = sentinelSigwinchHandler
        sigemptyset(&sentinelAction.sa_mask)
        sentinelAction.sa_flags = SA_RESTART
        _ = sigaction(SIGWINCH, &sentinelAction, nil)
        #elseif canImport(Glibc)
        _ = Glibc.signal(SIGWINCH, sentinelSigwinchHandler)
        #elseif canImport(Musl)
        _ = Musl.signal(SIGWINCH, sentinelSigwinchHandler)
        #endif

        let sentinelAddr = currentSigwinchHandlerAddress()
        #expect(sentinelAddr != 0)

        // 1. enterRawMode() installs OpenTUI's handler; exitRawMode() restores sentinel
        let backend = PlatformTerminalBackend(inputFD: pty.slaveFD, outputFD: pty.slaveFD)
        try await backend.enterRawMode()
        let activeAddr = currentSigwinchHandlerAddress()
        #expect(activeAddr != sentinelAddr)

        try await backend.exitRawMode()
        #expect(currentSigwinchHandlerAddress() == sentinelAddr)

        // 2. Dropping a raw-mode backend without exitRawMode() restores sentinel in deinit
        do {
            let scopedBackend = PlatformTerminalBackend(inputFD: pty.slaveFD, outputFD: pty.slaveFD)
            try await scopedBackend.enterRawMode()
            #expect(currentSigwinchHandlerAddress() != sentinelAddr)
        }
        #expect(currentSigwinchHandlerAddress() == sentinelAddr)
    }
}

#endif
