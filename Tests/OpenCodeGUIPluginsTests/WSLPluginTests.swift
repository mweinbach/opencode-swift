import Testing
import OpenCodeGUIPlugins

private actor StubWSLDriver: WSLBackendDriver {
    var hostJobs: [WSLMachine.HostJob] = []
    var spawned: [String] = []
    var persisted: [[WSLServerConfig]] = []

    func performHostJob(attempt: String, job: WSLMachine.HostJob) async {
        hostJobs.append(job)
    }
    func probeDistro(distro: String, attempt: String) async {}
    func inspectCLI(distro: String, attempt: String) async {}
    func installDistro(distro: String, attempt: String) async {}
    func installCLI(distro: String, attempt: String) async {}
    func stopServer(distro: String, attempt: String, server: String) async {}
    func spawnServer(distro: String, attempt: String) async { spawned.append(distro) }
    func checkCLI(distro: String) async {}
    func persistServers(_ servers: [WSLServerConfig]) async { persisted.append(servers) }
}

@Suite("WSL Plugin Domain & State Machines")
struct WSLPluginTests {
    @Test("wslArgs, path conversion, UTF-16LE detection, and distro parsers match upstream")
    func runtimeHelpersAndParsers() {
        #expect(
            WSLRuntimeHelper.wslArgs(["sh", "-lc", "printf hi"], distro: "Debian")
                == ["-d", "Debian", "--exec", "sh", "-lc", "printf hi"]
        )
        #expect(
            WSLRuntimeHelper.wslArgs(["bash", "-se"], distro: "Debian", user: "root")
                == ["-d", "Debian", "--user", "root", "--exec", "bash", "-se"]
        )

        #expect(WSLRuntimeHelper.windowsPathToWSL(#"C:\Users\dev\repo"#) == "/mnt/c/Users/dev/repo")
        #expect(WSLRuntimeHelper.wslPathToWindows("/home/dev/repo", distro: "Ubuntu") == #"\\wsl.localhost\Ubuntu\home\dev\repo"#)
        #expect(WSLRuntimeHelper.wslPathToWindows("/mnt/d/work", distro: "Ubuntu") == #"D:\work"#)

        // UTF-16LE with BOM ("OK")
        let utf16Bytes: [UInt8] = [0xFF, 0xFE, 0x4F, 0x00, 0x4B, 0x00]
        #expect(WSLRuntimeHelper.detectOutputEncoding(utf16Bytes) == .utf16le)
        #expect(WSLRuntimeHelper.decodeOutput(utf16Bytes) == "OK")

        let installedOutput = """
          NAME                   STATE           VERSION
        * Ubuntu-24.04           Running         2
          Debian                 Stopped         2
          Legacy                 Stopped         1
        """
        let installed = WSLRuntimeHelper.parseInstalledDistros(installedOutput)
        #expect(installed == [
            WSLInstalledDistro(name: "Ubuntu-24.04", version: 2, isDefault: true),
            WSLInstalledDistro(name: "Debian", version: 2, isDefault: false),
            WSLInstalledDistro(name: "Legacy", version: 1, isDefault: false),
        ])

        let onlineOutput = """
        NAME               FRIENDLY NAME
        Ubuntu             Ubuntu
        Ubuntu-24.04       Ubuntu 24.04 LTS
        Debian             Debian GNU/Linux
        """
        let online = WSLRuntimeHelper.parseOnlineDistros(onlineOutput)
        #expect(online == [
            WSLOnlineDistro(name: "Ubuntu", label: "Ubuntu"),
            WSLOnlineDistro(name: "Ubuntu-24.04", label: "Ubuntu 24.04 LTS"),
            WSLOnlineDistro(name: "Debian", label: "Debian GNU/Linux"),
        ])
    }

    @Test("WSL add & dialog machines navigate main/catalog views and settle server additions")
    func addAndDialogMachines() {
        let add1: GUIStateTransition<WSLAddMachine.State, WSLAddMachine.Effect<String>> = WSLAddMachine.reduce(
            state: WSLAddMachine.initialState,
            event: .addRequested
        )
        #expect(add1.effects == [.load(attempt: 1)])
        let add2: GUIStateTransition<WSLAddMachine.State, WSLAddMachine.Effect<String>> = WSLAddMachine.reduce(
            state: add1.state,
            event: .addLoaded(attempt: 1, module: "WSLDialog")
        )
        #expect(add2.state == .idle(issued: 1))
        #expect(add2.effects == [.open(module: "WSLDialog")])

        var dialog = WSLDialogMachine.createState()
        dialog = WSLDialogMachine.reduce(state: dialog, event: .catalogOpened(defaultTarget: "Debian", busy: false)).state
        #expect(WSLDialogMachine.selectView(dialog) == .catalog)
        dialog = WSLDialogMachine.reduce(state: dialog, event: .catalogSearchChanged("deb")).state
        #expect(WSLDialogMachine.selectCatalogSearch(dialog) == "deb")

        let installStep = WSLDialogMachine.reduce(state: dialog, event: .catalogInstallRequested(distro: "Debian", busy: false))
        dialog = installStep.state
        #expect(WSLDialogMachine.selectInstallingCatalog(dialog))
        #expect(installStep.effects == [
            .probesReset,
            .actionRun(attempt: 1, action: .installDistro(distro: "Debian"), timeoutMs: WSLDialogMachine.installTimeoutMs),
        ])

        // Successful catalog install returns to main view
        dialog = WSLDialogMachine.reduce(state: dialog, event: .actionSucceeded(attempt: 1)).state
        #expect(WSLDialogMachine.selectView(dialog) == .main)

        // Adding server completes and closes dialog
        let addStep = WSLDialogMachine.reduce(state: dialog, event: .primaryRequested(distro: "Debian", action: .add, disabled: false))
        #expect(WSLDialogMachine.selectAdding(addStep.state))
        let done = WSLDialogMachine.reduce(state: addStep.state, event: .actionSucceeded(attempt: 2))
        #expect(done.effects == [.actionAbort(attempt: 2), .dialogClose])
    }

    @Test("WSL main machine, probe machine, view model, and actor controller track lifecycle end-to-end")
    func mainMachineViewModelAndController() async throws {
        var state = WSLMachine.createState()
        let t1 = WSLMachine.reduce(state: state, event: .host(attempt: "a1", job: .probeRuntime))
        state = t1.state
        #expect(t1.effects == [.host(attempt: "a1", job: .probeRuntime)])

        let runtime = WSLRuntimeCheck(available: true, version: "2.4.0", error: nil)
        state = WSLMachine.reduce(state: state, event: .runtimeProbed(attempt: "a1", runtime: runtime)).state
        state = WSLMachine.reduce(state: state, event: .host(attempt: "a2", job: .refreshDistros)).state
        state = WSLMachine.reduce(
            state: state,
            event: .distrosListed(
                attempt: "a2",
                installed: [
                    WSLInstalledDistro(name: "docker-desktop", version: 2, isDefault: false),
                    WSLInstalledDistro(name: "Ubuntu-24.04", version: 2, isDefault: true),
                ],
                online: [
                    WSLOnlineDistro(name: "Ubuntu", label: "Ubuntu"),
                    WSLOnlineDistro(name: "Ubuntu-24.04", label: "Ubuntu 24.04 LTS"),
                    WSLOnlineDistro(name: "Debian", label: "Debian GNU/Linux"),
                ]
            )
        ).state

        // View model hides docker-desktop and plain Ubuntu when versioned Ubuntu exists
        let serversSnapshot = WSLMachine.toServersState(state)
        let vm = WSLViewModel.buildAddServerViewModel(
            state: serversSnapshot,
            dialog: WSLDialogMachine.createState(),
            probingAddable: false
        )
        #expect(vm.visibleInstalledDistros.map(\.name) == ["Ubuntu-24.04"])
        #expect(vm.selectedDistro == "Ubuntu-24.04")
        #expect(vm.installableDistros.map(\.name) == ["Debian"])

        // Probe plan requests addable probe for Ubuntu-24.04
        let plan = WSLViewModel.addServerProbePlan(
            state: serversSnapshot,
            view: .main,
            busy: false,
            selectedDistro: vm.selectedDistro,
            addableInstalledDistros: vm.addableInstalledDistros
        )
        #expect(plan == .addable(key: "distro:Ubuntu-24.04", distros: ["Ubuntu-24.04"]))

        // Probe machine schedules & completes
        var probeState = WSLProbeMachine.createState()
        let p1 = WSLProbeMachine.reduce(state: probeState, event: .synced(WSLProbeMachine.Input(plan: plan, busy: false, available: true)))
        probeState = p1.state
        #expect(WSLProbeMachine.selectProbingAddable(probeState))
        #expect(p1.effects == [.probeRun(attempt: 1, command: plan!, timeoutMs: WSLProbeMachine.timeoutMs)])

        // Controller adds a server and persists config
        let driver = StubWSLDriver()
        let controller = WSLController(driver: driver)
        try await controller.addServer(WSLServerConfig(id: "wsl-1", distro: "Ubuntu-24.04"))
        #expect(await driver.spawned == ["Ubuntu-24.04"])
        #expect(await driver.persisted.last?.count == 1)

        await controller.report(.serverSpawned(distro: "Ubuntu-24.04", attempt: "wsl-1", url: "http://127.0.0.1:4123", password: "pw"))
        let liveServers = await controller.serversState()
        #expect(liveServers.servers.first?.runtime == .ready(url: "http://127.0.0.1:4123", password: "pw"))
    }

    @Test("WSL main machine stops running server for update, handles server exit, and renders row view")
    func wslUpdateExitAndRowView() {
        let cfg = WSLServerConfig(id: "w1", distro: "Ubuntu")
        var state = WSLMachine.createState(configured: [cfg])
        let s1 = WSLMachine.reduce(state: state, event: .start(id: "w1", attempt: "st1"))
        state = s1.state
        #expect(s1.effects == [.spawn(distro: "Ubuntu", attempt: "st1"), .checkCLI(distro: "Ubuntu")])

        state = WSLMachine.reduce(
            state: state,
            event: .serverSpawned(distro: "Ubuntu", attempt: "st1", url: "http://127.0.0.1:5000", password: "p")
        ).state
        state = WSLMachine.reduce(
            state: state,
            event: .cliChecked(
                distro: "Ubuntu",
                check: WSLOpenCodeCheck(
                    distro: "Ubuntu",
                    resolvedPath: "/home/u/.opencode/bin/opencode",
                    version: "1.9.0",
                    expectedVersion: "2.0.0",
                    matchesDesktop: false,
                    error: nil
                )
            )
        ).state

        let rowBefore = WSLViewModel.rowView(state: WSLMachine.toServersState(state), distro: "Ubuntu")
        #expect(rowBefore.version == "1.9.0")
        #expect(rowBefore.button == WSLRowView.Button(label: "onboarding.updateOpencode", disabled: false))
        #expect(!rowBefore.retry)
        #expect(rowBefore.removable)

        // Update stops ready server first, then installs CLI once stopped, then respawns
        let upd1 = WSLMachine.reduce(state: state, event: .update(distro: "Ubuntu", attempt: "u1"))
        state = upd1.state
        #expect(upd1.effects == [.stop(distro: "Ubuntu", attempt: "u1", server: "st1")])
        let upd2 = WSLMachine.reduce(state: state, event: .serverStopped(distro: "Ubuntu", attempt: "u1"))
        state = upd2.state
        #expect(upd2.effects == [.installCLI(distro: "Ubuntu", attempt: "u1")])
        let updatedCheck = WSLOpenCodeCheck(
            distro: "Ubuntu",
            resolvedPath: "/home/u/.opencode/bin/opencode",
            version: "2.0.0",
            expectedVersion: "2.0.0",
            matchesDesktop: true,
            error: nil
        )
        let upd3 = WSLMachine.reduce(state: state, event: .cliInstalled(distro: "Ubuntu", attempt: "u1", check: updatedCheck))
        state = upd3.state
        #expect(upd3.effects == [.spawn(distro: "Ubuntu", attempt: "u1")])

        // Live server exiting unexpectedly transitions runtime to .failed and enables retry
        state = WSLMachine.reduce(state: state, event: .serverSpawned(distro: "Ubuntu", attempt: "u1", url: "http://127.0.0.1:5001", password: "p")).state
        state = WSLMachine.reduce(state: state, event: .serverExited(distro: "Ubuntu", attempt: "u1", code: 137, signal: "SIGKILL", message: "killed")).state
        let rowAfterExit = WSLViewModel.rowView(state: WSLMachine.toServersState(state), distro: "Ubuntu")
        #expect(rowAfterExit.retry)
    }
}
