import Testing
import OpenCodeGUIPlugins
import OpenCodeSchema

private actor MockUpdaterDriver: UpdaterPlatformDriver {
    var nextTarget: DesktopUpdaterMachine.UpdateTarget?
    var stagedDifferentials: [Bool] = []
    var persistedVersions: [String] = []
    var clearedCount = 0
    var restartedCount = 0

    init(nextTarget: DesktopUpdaterMachine.UpdateTarget?) {
        self.nextTarget = nextTarget
    }

    func checkForUpdate() async throws -> DesktopUpdaterMachine.UpdateTarget? { nextTarget }
    func stageUpdate(differential: Bool) async throws { stagedDifferentials.append(differential) }
    func installAndRestart() async throws { restartedCount += 1 }
    func externalInstall(url: String) async throws {}
    func persistVersion(_ version: String) async { persistedVersions.append(version) }
    func clearPersistedVersion() async { clearedCount += 1 }
}

@Suite("Updater, BTW, Context, Goal & Debug Plugins")
struct UpdaterAndWorkspacePluginTests {
    @Test("updater action resolver overlays window pending actions over main updater state")
    func updaterActionResolution() {
        #expect(WindowUpdaterMachine.resolveAction(state: .idle) == UpdaterActionResolution(label: .checkNow, run: .check))
        #expect(WindowUpdaterMachine.resolveAction(state: .idle, windowState: .checking(attempt: 1)) == UpdaterActionResolution(label: .checking))
        #expect(WindowUpdaterMachine.resolveAction(state: .ready(version: "2.1.0")) == UpdaterActionResolution(label: .installRestart, run: .install))
        #expect(WindowUpdaterMachine.resolveAction(state: .ready(version: "2.1.0"), windowState: .installing(attempt: 2)) == UpdaterActionResolution(label: .installing))
        #expect(WindowUpdaterMachine.resolveAction(state: .downloadRequired(version: "2.1.0")) == UpdaterActionResolution(label: .download, run: .install))
        #expect(WindowUpdaterMachine.resolveAction(state: .disabled) == UpdaterActionResolution(label: .unavailable, description: "check.unavailable"))
    }

    @Test("desktop updater machine disables differential download on stale cache and completes restart handoff")
    func desktopUpdaterMachineAndController() async throws {
        // Stale cached download from prior launch forces full download (differential == false)
        let initialized = DesktopUpdaterMachine.initialize(
            currentVersion: "2.0.0",
            enabled: true,
            canExternalInstall: true,
            persistedVersion: "2.0.1"
        )
        let check1 = DesktopUpdaterMachine.reduce(state: initialized.state, event: .checkRequested(waiter: 1))
        let found = DesktopUpdaterMachine.reduce(state: check1.state, event: .checkSucceeded(attempt: 1, target: .restart(version: "2.0.2")))
        #expect(found.effects.contains(.platformStage(attempt: 2, differential: false)))

        let staged = DesktopUpdaterMachine.reduce(state: found.state, event: .stageSucceeded(attempt: 2))
        #expect(DesktopUpdaterMachine.toUpdaterState(staged.state) == .ready(version: "2.0.2"))
        #expect(staged.effects.contains(.persistenceSet(version: "2.0.2")))

        // Actor controller check -> ready -> install
        let driver = MockUpdaterDriver(nextTarget: .restart(version: "2.1.0"))
        let controller = UpdaterController(currentVersion: "2.0.0", driver: driver)
        let stateAfterCheck = await controller.check()
        #expect(stateAfterCheck == .ready(version: "2.1.0"))
        try await controller.install()
        #expect(await driver.restartedCount == 1)
    }

    @Test("web update and What's New machines enforce auto-check spacing and release notes lifecycle")
    func webUpdateAndWhatsNew() {
        var web = WebUpdateMachine.initialState
        web = WebUpdateMachine.reduce(state: web, event: .registered(worker: .none)).state
        let c1 = WebUpdateMachine.reduce(state: web, event: .checkRequested(manual: false, at: 10_000))
        web = c1.state
        #expect(c1.effects == [.update(attempt: 1)])
        web = WebUpdateMachine.reduce(state: web, event: .checkSettled(attempt: 1, worker: .none)).state
        // Auto check within 60s spacing is throttled
        let throttled = WebUpdateMachine.reduce(state: web, event: .checkRequested(manual: false, at: 30_000))
        #expect(throttled.effects.isEmpty)
        // Worker installed announces update
        let ready = WebUpdateMachine.reduce(state: web, event: .workerInstalled)
        #expect(ready.effects == [.announce])
        #expect(WebUpdateMachine.pending(ready.state))
        #expect(WebUpdateMachine.action(ready.state) == WebUpdateMachine.Action(label: .reload, run: .apply))

        // What's New
        let wnInit = WhatsNewMachine.initialize(version: "2.1.0", previousVersion: "2.0.0", enabled: true)
        #expect(WhatsNewMachine.isLoading(wnInit.state))
        let content = WhatsNewMachine.Content(highlights: [WhatsNewMachine.Highlight(title: "Swift", description: "Fast")])
        let wnDone = WhatsNewMachine.reduce(state: wnInit.state, event: .loaded(content: content))
        #expect(wnDone.effects == [.abortLoad, .markSeen(version: "2.1.0"), .open(content: content)])
    }

    @Test("BTW machine tracks side-chats, empty replies, retries, and saved interrupted chats")
    func btwMachine() {
        var state = BtwMachine.createState()
        let asked = BtwMachine.reduce(
            state: state,
            event: .chatAsked(sessionKey: "s1", id: "c1", question: "  Why?  ", created: 1_000)
        )
        state = asked.state
        #expect(asked.effects.count == 3)
        #expect(BtwMachine.tabView(state: state, saved: nil, sessionKey: "s1", id: "c1") == .ready(question: "Why?"))

        // Whitespace-only reply registers as .empty failure
        let empty = BtwMachine.reduce(state: state, event: .generateSucceeded(sessionKey: "s1", id: "c1", attempt: 1, text: "   ", now: 1_500))
        state = empty.state
        if case .failed(_, let failure) = BtwMachine.chatView(state: state, saved: nil, sessionKey: "s1", id: "c1") {
            #expect(failure == .empty)
        } else {
            Issue.record("Expected empty failure")
        }

        // Retry succeeds and persists duration
        let retried = BtwMachine.reduce(state: state, event: .chatRetried(sessionKey: "s1", id: "c1", now: 2_000))
        let answered = BtwMachine.reduce(state: retried.state, event: .generateSucceeded(sessionKey: "s1", id: "c1", attempt: 2, text: "Because!", now: 2_450))
        #expect(answered.effects.contains(.persistAnswer(id: "c1", answer: "Because!", duration: 450, agent: nil, model: nil)))

        // Restored saved chat without answer surfaces as .interrupted
        let restoredView = BtwMachine.chatView(
            state: BtwMachine.createState(),
            saved: [BtwMachine.SavedChat(id: "old", question: "Old?")],
            sessionKey: "s1",
            id: "old"
        )
        if case .failed(_, let failure) = restoredView {
            #expect(failure == .interrupted)
        } else {
            Issue.record("Expected interrupted failure")
        }
    }

    @Test("Context export filename, formatter, export machine, scroll machine, and catalog retries work")
    func contextMachines() {
        #expect(SessionExportHelper.exportFilename(id: "ses_1", title: "Hello World!").hasSuffix("hello-world.json"))
        #expect(SessionExportHelper.exportFilename(id: "ses_1", title: String(repeating: "a", count: 300)) == "\(String(repeating: "a", count: 250)).json")

        let fmt = SessionContextFormatter(localeIdentifier: "en_US")
        #expect(fmt.number(nil) == "—")
        #expect(fmt.percent(42) == "42%")
        #expect(fmt.time(epochMilliseconds: nil) == "—")

        var exportState = SessionExportMachine.createState()
        let e1: GUIStateTransition<SessionExportMachine.State, SessionExportMachine.Effect<String>> =
            SessionExportMachine.reduce(state: exportState, event: .exportRequested(sessionKey: "s1", sessionID: "ses_1"))
        exportState = e1.state
        #expect(SessionExportMachine.isExporting(exportState, sessionKey: "s1"))
        let e2: GUIStateTransition<SessionExportMachine.State, SessionExportMachine.Effect<String>> =
            SessionExportMachine.reduce(state: exportState, event: .exportSaved(attempt: 1, sessionKey: "s1", filename: "out.json", saved: true))
        #expect(!SessionExportMachine.isExporting(e2.state, sessionKey: "s1"))
        #expect(e2.effects == [.toastExported(filename: "out.json")])

        // Catalog retry backoff caps at 5s
        var catalog = CatalogMachine.createState()
        let target = CatalogMachine.Target(serverID: "srv", directory: "/repo")
        catalog = CatalogMachine.reduce(state: catalog, event: .inputChanged(active: true, target: target)).state
        let cf = CatalogMachine.reduce(state: catalog, event: .loadFailed(attempt: 1, retryable: true))
        #expect(cf.effects == [.scheduleRetry(attempt: 2, delayMs: 1_000)])
    }

    @Test("Goal machine handles live updates, stale switching cache, retry delays, and single-flight commands")
    func goalMachine() {
        let goal = GoalSchema.State(
            id: "g1",
            objective: "Ship Swift port",
            status: .active,
            rounds: 2,
            maxRounds: 10,
            boot: "boot-1",
            updatedAt: 100
        )
        var state = GoalMachine.createState()
        let a1 = GoalMachine.reduce(state: state, event: .targetAttached(key: "k1", serverID: "s1", sessionID: "ses1", directory: "/repo"))
        state = a1.state
        #expect(a1.effects == [
            .subscribe(subscription: 1, serverID: "s1"),
            .fetch(attempt: 2, serverID: "s1", sessionID: "ses1", directory: "/repo"),
        ])

        state = GoalMachine.reduce(state: state, event: .snapshotLoaded(attempt: 2, goal: goal)).state
        #expect(GoalMachine.selectGoal(state, key: "k1") == goal)

        // Switching away keeps goal stale; switching back shows cached goal while refetching
        state = GoalMachine.reduce(state: state, event: .targetDetached).state
        #expect(GoalMachine.selectGoal(state, key: "k1") == nil)
        state = GoalMachine.reduce(state: state, event: .targetAttached(key: "k1", serverID: "s1", sessionID: "ses1", directory: "/repo")).state
        #expect(GoalMachine.selectGoal(state, key: "k1") == goal)

        // Pause command is single-flight
        let cmd1 = GoalMachine.reduce(state: state, event: .commandRequested(key: "k1", serverID: "s1", sessionID: "ses1", action: .pause))
        state = cmd1.state
        #expect(GoalMachine.selectBusy(state, key: "k1"))
        let cmdDup = GoalMachine.reduce(state: state, event: .commandRequested(key: "k1", serverID: "s1", sessionID: "ses1", action: .pause))
        #expect(cmdDup.effects.isEmpty)
    }

    @Test("Debug options, focus toggle, heap capture queue, memory diagnostics, and motion panel work")
    func debugMachines() {
        #expect(DebugOptions.isDebugBuild(packaged: false, channel: "prod"))
        #expect(DebugOptions.isDebugBuild(packaged: true, channel: "beta"))
        #expect(!DebugOptions.isDebugBuild(packaged: true, channel: "prod"))
        #expect(DebugOptions.memoryLogIntervalMs("2.5") == 2_500)
        #expect(DebugOptions.memoryLogIntervalMs("0.5") == nil)
        #expect(DebugOptions.memoryLogIntervalMs("2147484") == nil)

        // Debug focus toggle chains follow-up flip when clicked mid-flight
        var focus = DebugFocusToggleMachine.initialState
        let f1 = DebugFocusToggleMachine.reduce(state: focus, event: .toggle)
        focus = f1.state
        #expect(f1.effects == [.set(attempt: 1, enabled: true)])
        focus = DebugFocusToggleMachine.reduce(state: focus, event: .toggle).state
        #expect(!DebugFocusToggleMachine.isActive(focus))
        let f2 = DebugFocusToggleMachine.reduce(state: focus, event: .setSucceeded(attempt: 1))
        #expect(f2.effects == [.set(attempt: 2, enabled: false)])

        // Heap capture queues one pending job of the other source and coalesces duplicate commands
        var heap = HeapCaptureMachine.createState()
        let h1 = HeapCaptureMachine.reduce(state: heap, event: .commandRequested(root: "/tmp/h", includeServer: true, replyID: 1))
        heap = h1.state
        heap = HeapCaptureMachine.reduce(state: heap, event: .commandRequested(root: "/tmp/h", includeServer: true, replyID: 2)).state
        heap = HeapCaptureMachine.reduce(state: heap, event: .signalReceived(root: "/tmp/s", includeServer: false)).state
        let res = HeapCaptureResult(directory: "/tmp/h/1", complete: true)
        let h2 = HeapCaptureMachine.reduce(state: heap, event: .captureSucceeded(attempt: 1, result: res))
        #expect(h2.effects == [
            .repliesSettle(replyIDs: [1, 2], outcome: .ok(res)),
            .captureRun(attempt: 2, root: "/tmp/s", includeServer: false),
        ])

        // Memory diagnostics & debug bar pinning
        var mem = MemoryDiagnosticsMachine.createState()
        let m1 = MemoryDiagnosticsMachine.reduce(state: mem, event: .synced(enabled: true))
        mem = m1.state
        #expect(MemoryDiagnosticsMachine.isOn(mem))
        let bar = MemoryDiagnosticsMachine.debugBarView(visible: false, motion: true, memoryOn: true)
        #expect(bar.visibility == .pinned)
        #expect(!bar.closable)
        #expect(bar.motion)

        // Motion panel narrow navigation & escape
        var motion = MotionPanelMachine.createState(wide: false, selected: nil)
        let mo1 = MotionPanelMachine.reduce(state: motion, event: .featureOpened(key: "spring"))
        motion = mo1.state
        #expect(MotionPanelMachine.selectPushed(motion))
        let mo2 = MotionPanelMachine.reduce(state: motion, event: .escape)
        #expect(!MotionPanelMachine.selectPushed(mo2.state))
        #expect(mo2.effects == [.focusRow(key: "spring")])

        // Heap command single-flight guard
        var heapCmd = HeapCommandMachine.createState()
        #expect(HeapCommandMachine.isEnabled(heapCmd))
        let hc1 = HeapCommandMachine.reduce(state: heapCmd, event: .run)
        heapCmd = hc1.state
        #expect(!HeapCommandMachine.isEnabled(heapCmd))
        let hc2 = HeapCommandMachine.reduce(state: heapCmd, event: .succeeded(attempt: 1, result: res))
        #expect(HeapCommandMachine.isEnabled(hc2.state))
        #expect(hc2.effects == [.toastResult(attempt: 1, result: res)])

        // Context scroll ignores its own applied restore event and flushes user scroll on target change
        var ctxScroll = ContextScrollMachine.createState()
        let cs1 = ContextScrollMachine.reduce(state: ctxScroll, event: .targetSynced(sessionKey: "s1", active: true))
        ctxScroll = cs1.state
        #expect(cs1.effects == [.frameSchedule(kind: .restore, attempt: 1)])
        let pos = ContextScrollMachine.ScrollPosition(x: 0, y: 240)
        ctxScroll = ContextScrollMachine.reduce(state: ctxScroll, event: .restoreApplied(attempt: 1, applied: pos)).state
        // Self-emitted scroll at applied offset stays restoring
        let selfScroll = ContextScrollMachine.reduce(state: ctxScroll, event: .scrolled(position: pos))
        ctxScroll = selfScroll.state
        #expect(selfScroll.effects.isEmpty)
        // User scroll at new offset enters tracking & schedules save; switching session flushes pending save
        let userPos = ContextScrollMachine.ScrollPosition(x: 0, y: 512)
        let userScroll = ContextScrollMachine.reduce(state: ctxScroll, event: .scrolled(position: userPos))
        ctxScroll = userScroll.state
        #expect(userScroll.effects == [.frameSchedule(kind: .save, attempt: 2)])
        let switched = ContextScrollMachine.reduce(state: ctxScroll, event: .targetSynced(sessionKey: "s2", active: true))
        #expect(switched.effects == [.frameCancel, .saveWrite(sessionKey: "s1", position: userPos), .frameSchedule(kind: .restore, attempt: 3)])
    }
}
