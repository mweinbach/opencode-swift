import Testing
import OpenCodeGUIPlugins
import OpenCodeClient
import OpenCodeSchema

private func makePtyInfo(
    id: String,
    title: String = "Terminal 1",
    userTitle: String? = nil,
    sessionID: String = "ses_1"
) -> PersistentPtySchema.Info {
    PersistentPtySchema.Info(
        id: PtySchema.ID(rawValue: id)!,
        title: title,
        command: "/bin/zsh",
        args: [],
        cwd: "/repo",
        status: .running,
        pid: SchemaPrimitive.NonNegativeInt(rawValue: 100)!,
        exitCode: nil,
        sessionID: SessionID(rawValue: sessionID)!,
        userTitle: userTitle,
        foregroundProcess: nil,
        size: PersistentPtySchema.Size(
            cols: SchemaPrimitive.PositiveInt(rawValue: 80)!,
            rows: SchemaPrimitive.PositiveInt(rawValue: 24)!
        ),
        output: PersistentPtySchema.OutputRange(
            head: SchemaPrimitive.NonNegativeInt(rawValue: 0)!,
            tail: SchemaPrimitive.NonNegativeInt(rawValue: 0)!
        )
    )
}

private actor RecordingFocusHost: TerminalFocusHost {
    var focusedIDs: [String] = []
    func focusTerminal(id: String) async -> Bool {
        focusedIDs.append(id)
        return true
    }
}

@Suite("Terminal Plugin Domain & State Machines")
struct TerminalPluginTests {
    @Test("connection machine buffers input until replay drains and enforces inputProtocol v1")
    func connectionMachineProtocol() {
        var state = TerminalConnectionMachine.createState(attachmentID: "att-1")

        // Outdated protocol fails immediately
        let badProto = TerminalConnectionMachine.reduce(
            state: state,
            event: .socketMessage(text: #"{"type":"attached","inputProtocol":2,"info":{"size":{"cols":80,"rows":24}},"role":"controller"}"#)
        )
        #expect(badProto.state == .failed(failure: .outdated))
        #expect(badProto.effects == [.fail(failure: .outdated)])

        // Snapshot restore while restoring queues resize + checkpoint
        let snap = TerminalConnectionMachine.reduce(
            state: state,
            event: .snapshotRestored(size: TerminalSize(cols: 100, rows: 30), checkpoint: "aGk=")
        )
        #expect(snap.effects == [.queueResize(size: TerminalSize(cols: 100, rows: 30), checkpoint: "aGk=", reset: false)])

        // Size & input while attaching are buffered
        state = TerminalConnectionMachine.reduce(state: state, event: .sizeChanged(size: TerminalSize(cols: 120, rows: 40))).state
        state = TerminalConnectionMachine.reduce(state: state, event: .input(data: [108, 115])).state

        // Attached protocol v1 -> replaying
        let attached = TerminalConnectionMachine.reduce(
            state: state,
            event: .socketMessage(text: #"{"type":"attached","inputProtocol":1,"info":{"size":{"cols":80,"rows":24}},"role":"observer"}"#)
        )
        state = attached.state
        #expect(attached.effects == [.queueResize(size: TerminalSize(cols: 80, rows: 24), checkpoint: nil, reset: false)])

        // replay_complete -> queueReplayEnd
        let complete = TerminalConnectionMachine.reduce(state: state, event: .socketMessage(text: #"{"type":"replay_complete"}"#))
        state = complete.state
        #expect(complete.effects == [.queueReplayEnd])

        // replayDrained flushes buffered input at desired size
        let drained = TerminalConnectionMachine.reduce(state: state, event: .replayDrained)
        state = drained.state
        #expect(drained.effects == [.send(frame: persistentPtyFrame(cols: 120, rows: 40, data: [108, 115]))])

        // Exited shell ignores subsequent socket close
        state = TerminalConnectionMachine.reduce(state: state, event: .socketMessage(text: #"{"type":"exited","exitCode":0}"#)).state
        let afterClose = TerminalConnectionMachine.reduce(state: state, event: .socketClosed)
        #expect(afterClose.state == .exited)
        #expect(afterClose.effects.isEmpty)
    }

    @Test("terminal writer coalesces adjacent chunks and driver suppresses emulator query echo")
    func writerAndConnectionDriver() {
        var writes: [[UInt8]] = []
        var sentFrames: [[UInt8]] = []
        var resizes: [TerminalSize] = []

        var driverRef: TerminalConnectionDriver?
        let driver = TerminalConnectionDriver(
            attachmentID: "att-2",
            write: { bytes, done in
                writes.append(bytes)
                // Simulate ghostty-web emitting a synchronous device-attributes query reply while writing
                driverRef?.input("\u{1b}[?1;2c")
                done()
            },
            resize: { resizes.append($0) },
            send: { sentFrames.append($0) },
            fail: { _ in }
        )
        driverRef = driver

        driver.resize(TerminalSize(cols: 90, rows: 25))
        driver.message(#"{"type":"attached","inputProtocol":1,"info":{"size":{"cols":80,"rows":24}},"role":"controller"}"#)
        driver.output([65, 66])
        driver.message(#"{"type":"replay_complete"}"#)

        #expect(resizes == [TerminalSize(cols: 80, rows: 24)])
        #expect(writes == [[65, 66]])
        // Only the size-control frame was sent — the synchronous write-echo was suppressed!
        #expect(sentFrames == [persistentPtyFrame(cols: 90, rows: 25, data: nil)])
    }

    @Test("focus machine preserves overlay return once and cancels on external pointer press")
    func focusMachineAndController() async {
        var focus = TerminalFocusMachine.initialState
        focus = TerminalFocusMachine.reduce(state: focus, event: .requestPending(session: "s1", overlay: true))
        #expect(TerminalFocusMachine.hasFocusRequest(focus))
        // First outside focus return from closing overlay strips overlay flag without cancelling
        focus = TerminalFocusMachine.reduce(state: focus, event: .focusMoved(into: .outside, leavingOverlay: true))
        #expect(TerminalFocusMachine.hasFocusRequest(focus))
        // Resolve pending into target terminal id
        focus = TerminalFocusMachine.reduce(state: focus, event: .pendingResolved(request: 1, id: "pty_1"))
        #expect(TerminalFocusMachine.isFocusRequested(focus, session: "s1", id: "pty_1"))
        #expect(TerminalFocusMachine.focusRequestToken(focus, session: "s1", id: "pty_1") == 1)

        // Controller applies focus and consumes the request
        let host = RecordingFocusHost()
        let controller = TerminalController(focusHost: host)
        _ = await controller.dispatchFocus(.requestTarget(session: "s1", id: "pty_1", overlay: false))
        let applied = await controller.applyFocusIfRequested(session: "s1", id: "pty_1")
        #expect(applied)
        #expect(await host.focusedIDs == ["pty_1"])
        #expect(!TerminalFocusMachine.hasFocusRequest(await controller.currentFocus()))
    }

    @Test("multi-terminal session machine manages reconnects, create/close, and optimistic rename overlay")
    func sessionMachineLifecycle() {
        var state = TerminalSessionMachine.initialState
        let t1 = TerminalSessionMachine.reduce(state: state, event: .sessionLoaded(sessionID: "ses_1"))
        state = t1.state
        #expect(t1.effects == [.checkCapability(attempt: 1)])

        let t2 = TerminalSessionMachine.reduce(state: state, event: .capabilityChecked(attempt: 1, supported: true))
        state = t2.state
        #expect(t2.effects == [.loadList(sessionID: "ses_1", attempt: 2)])

        let pty1 = makePtyInfo(id: "pty_1", title: "Terminal 1")
        let t3 = TerminalSessionMachine.reduce(state: state, event: .listLoaded(sessionID: "ses_1", attempt: 2, items: [pty1]))
        state = t3.state
        #expect(t3.effects == [.syncTabs(sessionID: "ses_1", items: [pty1])])
        #expect(TerminalSessionMachine.sessionConnection(state, sessionID: "ses_1") == 1)

        // Optimistic rename overlays title immediately before server responds
        let r1 = TerminalSessionMachine.reduce(state: state, event: .renameRequested(sessionID: "ses_1", ptyID: "pty_1", title: "Logs"))
        state = r1.state
        #expect(r1.effects == [.renameTerminal(sessionID: "ses_1", ptyID: "pty_1", title: "Logs", attempt: 3)])
        if case .ready(let items) = TerminalSessionMachine.sessionView(state, sessionID: "ses_1") {
            #expect(items.first?.title == "Logs")
        } else {
            Issue.record("Expected ready session view")
        }

        // Closing terminal cancels pending rename
        let c1 = TerminalSessionMachine.reduce(state: state, event: .closeRequested(sessionID: "ses_1", ptyID: "pty_1"))
        #expect(c1.effects == [.abort(attempts: [3]), .closeTerminal(sessionID: "ses_1", ptyID: "pty_1", attempt: 4)])

        // Reconnect increments connection count while keeping ready items visible
        let reconnected = TerminalSessionMachine.reduce(state: state, event: .serverConnected)
        #expect(TerminalSessionMachine.sessionView(reconnected.state, sessionID: "ses_1") == TerminalSessionMachine.sessionView(state, sessionID: "ses_1"))
    }

    @Test("pane, surface, rename, quote machines and localized title parser behave deterministically")
    func companionMachinesAndTitles() {
        // Pane machine
        var pane: TerminalPaneMachine.State<String> = .idle
        let p1: GUIStateTransition<TerminalPaneMachine.State<String>, TerminalPaneMachine.Effect<String>> =
            TerminalPaneMachine.reduce(state: pane, event: .mounted)
        pane = p1.state
        let p2: GUIStateTransition<TerminalPaneMachine.State<String>, TerminalPaneMachine.Effect<String>> =
            TerminalPaneMachine.reduce(state: pane, event: .ghosttyLoaded(loaded: "wasm"))
        pane = p2.state
        let p3: GUIStateTransition<TerminalPaneMachine.State<String>, TerminalPaneMachine.Effect<String>> =
            TerminalPaneMachine.reduce(state: pane, event: .terminalOpened(term: "term-1", initialSize: TerminalSize(cols: 80, rows: 24)))
        pane = p3.state
        #expect(!TerminalPaneMachine.paneRevealed(pane))
        pane = TerminalPaneMachine.reduce(state: pane, event: .screenWritten as TerminalPaneMachine.Event<String, String>).state
        #expect(TerminalPaneMachine.paneRevealed(pane))

        // Surface machine seeds mobile empty session once and remounts failed terminal on reconnect
        var surface = TerminalSurfaceMachine.initialState
        let s1 = TerminalSurfaceMachine.reduce(
            state: surface,
            event: .sync(session: "ses_1", ready: true, connection: 1, opened: true, mobile: true, active: nil, terminalIDs: [], elsewhere: [])
        )
        surface = s1.state
        #expect(s1.effects == [.createTerminal])

        // Rename machine ignores blur while arming and saves trimmed title once editing
        var rename = TerminalRenameMachine.initialState
        rename = TerminalRenameMachine.reduce(state: rename, event: .start(title: "Old", source: .pointer, enabled: true)).state
        rename = TerminalRenameMachine.reduce(state: rename, event: .blur).state
        #expect(TerminalRenameMachine.isRenaming(rename))
        rename = TerminalRenameMachine.reduce(state: rename, event: .armed(attempt: 1)).state
        rename = TerminalRenameMachine.reduce(state: rename, event: .change(value: "  Build  ")).state
        let saved = TerminalRenameMachine.reduce(state: rename, event: .blur)
        #expect(saved.effects == [.save(title: "Build")])

        // Quote machine & title localization
        #expect(TerminalTitle.titleNumber("Terminal 3") == 3)
        #expect(TerminalTitle.titleNumber("终端 7") == 7)
        #expect(TerminalTitle.titleNumber("ターミナル 12") == 12)
        #expect(TerminalTitle.titleNumber("Custom Shell") == nil)
        #expect(TerminalTitle.tabLabel(title: "Terminal 2", numberedFormat: { "Shell #\($0)" }, fallbackTitle: "Terminal") == "Shell #2")

        let place = TerminalQuoteMachine.quotePosition(
            size: TerminalQuoteMachine.Size(width: 100, height: 30),
            bounds: TerminalQuoteMachine.Rect(top: 0, bottom: 400, left: 0, right: 600, width: 600, height: 400),
            anchor: TerminalQuoteMachine.Anchor(top: 100, bottom: 120, start: 50, end: 150, single: true)
        )
        #expect(place == TerminalQuoteMachine.Place(top: 62, left: 50))
    }
}
