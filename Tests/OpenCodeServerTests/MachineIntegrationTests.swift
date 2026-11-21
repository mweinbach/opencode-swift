import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

private typealias Helper = MachineIntegrationHelper

@Suite("Machine, EnvFS & Server Application-Service Integration")
struct MachineIntegrationTests {

    // MARK: 1. Worker joins through server Noise link endpoint and hello is served

    @Test("Worker joins through /api/machine/link using Noise XX, hello is served, and reconnect works")
    func workerJoinsThroughServerNoiseLink() async throws {
        let fs = InMemoryFileSystem(initialFiles: ["/workspace/README.md": Helper.utf8Bytes("ok\n")])
        let runtime = try await ServerAppRuntime.make(
            options: ServerOptions(password: "top-secret-password"),
            fileSystem: fs,
            defaultDirectory: "/workspace"
        )
        let router = ServerRouter(runtime: runtime)
        defer { Task { await runtime.close() } }

        // Endpoint is exempt from HTTP password auth because Noise XX + join secret / paired key authenticates it.
        let nonUpgrade = await router.handle(ServerHTTPRequest(method: "GET", url: MACHINE_LINK_PATH))
        #expect(nonUpgrade.statusCode == 426)

        // Add machine and generate a one-time join string.
        let id = try await runtime.machines.add("gpu")
        #expect(id == "gpu")
        let joinString = try await runtime.machines.invite(
            "gpu",
            options: Machines.InviteOptions(reach: [.url("ws://127.0.0.1:4096\(MACHINE_LINK_PATH)")])
        )
        let join = try #require(MachineJoin.decode(joinString))

        // Worker dials the server endpoint with the join secret and sends its encrypted hello.
        let worker = try await Helper.InProcessWorker(
            name: "gpu",
            home: "/home/gpu",
            os: "linux",
            arch: "arm64",
            instance: "run-1",
            seed: [UInt8](repeating: 11, count: 32)
        )
        let welcomedAs = try await worker.dial(router: router, homeKey: join.home, secret: join.secret)
        #expect(welcomedAs == "gpu")

        let becameOnline = await Helper.eventually {
            let list = await runtime.machines.list()
            return list.first(where: { $0.id == "gpu" })?.online == true
        }
        #expect(becameOnline)

        let list = await runtime.machines.list()
        let gpuInfo = try #require(list.first(where: { $0.id == "gpu" }))
        #expect(gpuInfo.online == true)
        #expect(gpuInfo.paired == true)
        #expect(gpuInfo.os == "linux")
        #expect(gpuInfo.arch == "arm64")
        #expect(gpuInfo.connection == MachineDriver.ConnectionInfo(kind: .websocket))
        #expect(try await runtime.machines.home("gpu") == "/home/gpu")

        // The machine's environment reports its own ID (not "local").
        let gpuEnv = try await runtime.machines.get("gpu")
        #expect(gpuEnv.id == CoreLocation.Environment.ID.make("gpu"))

        // Disconnect and verify offline, then reconnect WITHOUT the join secret using the paired worker key.
        await worker.disconnect()
        let wentOffline = await Helper.eventually {
            let list = await runtime.machines.list()
            return list.first(where: { $0.id == "gpu" })?.online == false
        }
        #expect(wentOffline)

        let reconnected = try await worker.dial(router: router, homeKey: join.home, secret: nil)
        #expect(reconnected == "gpu")
        let backOnline = await Helper.eventually {
            let list = await runtime.machines.list()
            return list.first(where: { $0.id == "gpu" })?.online == true
        }
        #expect(backOnline)
        await worker.disconnect()
    }

    // MARK: 2. Read, Write, Edit, Patch, Shell on gpu:/path go through driver; Formatter local-only; Grep/Glob refuse remote; MachineInstructions wired

    @Test("Read, write, edit, patch and shell on gpu:/path go through the driver; search refuses remote; formatter skips remote")
    func toolsAndShellThroughMachineDriver() async throws {
        let localFS = InMemoryFileSystem(initialFiles: [
            "/workspace/local.txt": Helper.utf8Bytes("local-only\n"),
        ])
        let env = DictionaryEnvironment(variables: ["OPENCODE_FLAGS": "machines,-full_codemode"])
        let runtime = try await ServerAppRuntime.make(
            options: ServerOptions(password: "pw"),
            fileSystem: localFS,
            environment: env,
            defaultDirectory: "/workspace"
        )
        defer { Task { await runtime.close() } }

        _ = try await runtime.machines.add("gpu")

        let worker = try await Helper.InProcessWorker(
            name: "gpu",
            home: "/home/gpu",
            os: "linux",
            arch: "x64",
            initialFiles: [
                "/work/train.py": "epochs = 10\n",
                "/home/gpu/notes.txt": "remote home note\n",
            ],
            onRun: { run in
                (Helper.utf8Bytes("GPU-0: A100 cwd=\(run.cwd) cmd=\(run.argv.last ?? "")\n"), 0)
            }
        )
        worker.connectDirectly(to: runtime.machines)
        defer { Task { await worker.disconnect() } }

        let online = await Helper.eventually {
            await runtime.machines.list().first(where: { $0.id == "gpu" })?.online == true
        }
        #expect(online)

        // Resolve Location bundle from the server runtime (with machines flag ON).
        let locRef = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"))
        let bundle = try await runtime.resolveLocation(locRef)
        let snapshot = await bundle.tool.snapshot(permissions: Helper.allowAllRules())

        func execTool(_ name: String, _ args: [String: JSONValue]) async throws -> CoreTool.NormalizedResult {
            try await Helper.executeTool(snapshot: snapshot, name: name, args: args)
        }

        // 1) Read gpu:/work/train.py through driver
        let readRes = try await execTool("read", ["path": .string("gpu:/work/train.py")])
        #expect(Helper.firstText(from: readRes).contains("epochs = 10"))

        // 2) Read gpu:~/notes.txt resolves ~ through machines.home("gpu")
        let homeRead = try await execTool("read", ["path": .string("gpu:~/notes.txt")])
        #expect(Helper.firstText(from: homeRead).contains("remote home note"))

        // 3) Shell command with workdir gpu:/work runs on the worker via `sh -c`
        let shellRes = try await execTool("shell", [
            "command": .string("nvidia-smi"),
            "workdir": .string("gpu:/work"),
        ])
        let shellText = Helper.firstText(from: shellRes)
        #expect(shellText.contains("GPU-0: A100 cwd=/work cmd=nvidia-smi"))
        #expect(worker.recordedRuns.count == 1)
        #expect(worker.recordedRuns[0].argv == ["sh", "-c", "nvidia-smi"])
        #expect(worker.recordedRuns[0].cwd == "/work")

        // 4) Write, Edit, Patch on gpu:/work go through the driver and never touch localFS
        _ = try await execTool("write", [
            "path": .string("gpu:/work/out.txt"),
            "content": .string("alpha\nbeta\n"),
        ])
        #expect(!(await localFS.exists(at: "/work/out.txt")))
        let writtenBytes = try await worker.files.read("/work/out.txt", range: nil).bytes
        #expect(Helper.utf8String(writtenBytes) == "alpha\nbeta\n")

        _ = try await execTool("edit", [
            "path": .string("gpu:/work/out.txt"),
            "oldString": .string("alpha"),
            "newString": .string("ALPHA"),
        ])
        let editedBytes = try await worker.files.read("/work/out.txt", range: nil).bytes
        #expect(Helper.utf8String(editedBytes) == "ALPHA\nbeta\n")

        let patchText = """
        *** Begin Patch
        *** Update File: gpu:/work/out.txt
        @@
         ALPHA
        -beta
        +BETA
        *** End Patch
        """
        _ = try await execTool("patch", ["patchText": .string(patchText)])
        let patchedBytes = try await worker.files.read("/work/out.txt", range: nil).bytes
        #expect(Helper.utf8String(patchedBytes) == "ALPHA\nBETA\n")

        // 5) Grep and Glob refuse remote paths with upstream's exact message
        let globErr = await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("glob", ["pattern": .string("*.py"), "path": .string("gpu:/work")])
        }
        #expect(globErr?.message == "Search is not available on gpu yet.")

        let grepErr = await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("grep", ["pattern": .string("epochs"), "path": .string("gpu:/work")])
        }
        #expect(grepErr?.message == "Search is not available on gpu yet.")

        // 6) Formatter skips remote targets
        let formatter = CoreFormatter.Service(directory: "/workspace")
        _ = await formatter.transform { editor in
            editor.set(CoreFormatter.Info(name: "always-on", extensions: [".py"], enabled: { ["true"] }))
        }
        let gpuEnv = try await runtime.machines.get("gpu")
        let remoteTarget = CoreFilesystem.FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/work/train.py"),
            resource: "gpu:/work/train.py",
            environment: gpuEnv
        )
        #expect(await formatter.file(remoteTarget) == false)
    }

    @Test("MachineInstructions appear in session instructions behind the machines flag")
    func machineInstructionsRespectFlag() async throws {
        // Flag ON: gpu appears in model system prompt
        let harnessOn = try await LiveExecutionFixture.makeHarness(
            env: [
                "ANTHROPIC_API_KEY": "sk-ant-live-secret",
                "OPENCODE_FLAGS": "machines",
            ],
            responses: [LiveExecutionFixture.anthropicTextStepSSE(chunks: ["ok"])]
        )
        defer { Task { await harnessOn.close() } }
        _ = try await harnessOn.runtime.machines.add("gpu")

        let sessionOn = try await harnessOn.client.session.create(SessionCreateInput(title: "Machines on"))
        _ = try await harnessOn.client.session.prompt(SessionPromptInput(sessionID: sessionOn.id.rawValue, text: "hi"))
        await harnessOn.runtime.sessionExecution.awaitIdle(sessionOn.id)

        let reqOn = try #require(harnessOn.mockTransport.recordedRequests.first)
        let sysOn = Helper.flattenStrings(try Helper.decodeJSON(reqOn.body ?? [])["system"]).joined(separator: "\n")
        #expect(sysOn.contains("Other machines are available: gpu."))
        #expect(sysOn.contains("Name one in a path, as in gpu:/work/file"))

        // Flag OFF: machines section omitted even when machines exist
        let harnessOff = try await LiveExecutionFixture.makeHarness(
            env: [
                "ANTHROPIC_API_KEY": "sk-ant-live-secret",
                "OPENCODE_FLAGS": "-machines",
            ],
            responses: [LiveExecutionFixture.anthropicTextStepSSE(chunks: ["ok"])]
        )
        defer { Task { await harnessOff.close() } }
        _ = try await harnessOff.runtime.machines.add("gpu")

        let sessionOff = try await harnessOff.client.session.create(SessionCreateInput(title: "Machines off"))
        _ = try await harnessOff.client.session.prompt(SessionPromptInput(sessionID: sessionOff.id.rawValue, text: "hi"))
        await harnessOff.runtime.sessionExecution.awaitIdle(sessionOff.id)

        let reqOff = try #require(harnessOff.mockTransport.recordedRequests.first)
        let sysOff = Helper.flattenStrings(try Helper.decodeJSON(reqOff.body ?? [])["system"]).joined(separator: "\n")
        #expect(!sysOff.contains("Other machines are available:"))
    }

    // MARK: 3. Offline machine error text as both tool error and session error

    @Test("Offline, unknown and non-absolute machine errors match upstream as tool errors and session errors")
    func offlineMachineProducesUpstreamErrorText() async throws {
        let localFS = InMemoryFileSystem(initialFiles: [
            "/workspace/README.md": Helper.utf8Bytes("ok\n"),
        ])
        let runtime = try await ServerAppRuntime.make(
            options: ServerOptions(password: "pw"),
            fileSystem: localFS,
            environment: DictionaryEnvironment(variables: ["OPENCODE_FLAGS": "machines,-full_codemode"]),
            defaultDirectory: "/workspace"
        )
        defer { Task { await runtime.close() } }

        // Add gpu without connecting any worker -> offline.
        _ = try await runtime.machines.add("gpu")

        let locRef = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace"))
        let bundle = try await runtime.resolveLocation(locRef)
        let snapshot = await bundle.tool.snapshot(permissions: Helper.allowAllRules())

        func execTool(_ name: String, _ args: [String: JSONValue]) async throws -> CoreTool.NormalizedResult {
            try await Helper.executeTool(snapshot: snapshot, name: name, args: args)
        }

        // Read on offline machine
        let readErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("read", ["path": .string("gpu:/work/a.txt")])
        })
        #expect(readErr.message == "gpu is offline, command not sent")
        #expect(
            CoreSessionErrorMapping.toSessionError(readErr)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is offline, command not sent")
        )

        // Write on offline machine (both absolute and home path)
        let writeErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("write", ["path": .string("gpu:/work/new.txt"), "content": .string("hi\n")])
        })
        #expect(writeErr.message == "gpu is offline, command not sent")
        #expect(
            CoreSessionErrorMapping.toSessionError(writeErr)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is offline, command not sent")
        )

        let homeWriteErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("write", ["path": .string("gpu:~/new.txt"), "content": .string("hi\n")])
        })
        #expect(homeWriteErr.message == "gpu is offline, command not sent")
        #expect(
            CoreSessionErrorMapping.toSessionError(homeWriteErr)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is offline, command not sent")
        )

        // Shell on offline machine
        let shellErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("shell", ["command": .string("nvidia-smi"), "workdir": .string("gpu:/work")])
        })
        #expect(shellErr.message == "gpu is offline, command not sent")
        #expect(
            CoreSessionErrorMapping.toSessionError(shellErr)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is offline, command not sent")
        )

        // Unknown machine
        let unknownErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("read", ["path": .string("tpu:/work/a.txt")])
        })
        #expect(unknownErr.message == #"No machine named "tpu"."#)
        #expect(
            CoreSessionErrorMapping.toSessionError(unknownErr)
                == SessionErrorSchema.Error(type: "tool.execution", message: #"No machine named "tpu"."#)
        )

        // Non-absolute machine path (~other)
        let nonAbsErr = try #require(await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await execTool("read", ["path": .string("gpu:~other/x")])
        })
        let expectedNotAbs = "Machine paths are absolute or start with ~/: write gpu:/… or gpu:~/… (for a local folder with that name, start with ./)"
        #expect(nonAbsErr.message == expectedNotAbs)
        #expect(
            CoreSessionErrorMapping.toSessionError(nonAbsErr)
                == SessionErrorSchema.Error(
                    type: "tool.execution",
                    message: expectedNotAbs
                )
        )

        // Direct session error mapping across every MachineFailure + CauseWrapping wrapper
        let wrappedNotSent = ToolSchema.ToolError(
            message: "Unable to read gpu:/work/a.txt",
            cause: CoreLocation.Environment.Files.Failed(path: "/work/a.txt", cause: MachineDriver.NotSent(machine: "gpu"))
        )
        #expect(
            CoreSessionErrorMapping.toSessionError(wrappedNotSent)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is offline, command not sent")
        )

        let wrappedUnknown = ToolSchema.ToolError(
            message: "Unable to execute command",
            cause: AppProcess.AppProcessError(command: "nvidia-smi", cause: MachineDriver.Unknown(machine: "gpu"))
        )
        #expect(
            CoreSessionErrorMapping.toSessionError(wrappedUnknown)
                == SessionErrorSchema.Error(
                    type: "tool.execution",
                    message: "Lost connection to gpu. The command may or may not have started."
                )
        )

        let wrappedLost = ToolSchema.ToolError(
            message: "Command failed",
            cause: AppProcess.AppProcessError(command: "train", cause: MachineDriver.ProcessLost(machine: "gpu", restarted: true))
        )
        #expect(
            CoreSessionErrorMapping.toSessionError(wrappedLost)
                == SessionErrorSchema.Error(type: "tool.execution", message: "gpu's worker restarted, the process was lost")
        )

        // Local file failures keep their curated tool message rather than leaking raw wrapper text.
        let localFailure = ToolSchema.ToolError(
            message: "Unable to write blocker/child.txt",
            cause: CoreLocation.Environment.Files.Failed(path: "/workspace/blocker/child.txt", message: "ENOTDIR")
        )
        #expect(
            CoreSessionErrorMapping.toSessionError(localFailure)
                == SessionErrorSchema.Error(type: "tool.execution", message: "Unable to write blocker/child.txt")
        )
    }

    // MARK: 4. Automation's run starts with the server and stops on close

    @Test("ServerProcess starts Automation.run and stops it cleanly on close")
    func automationRunStartsWithServerAndStopsOnClose() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/README.md": Helper.utf8Bytes("ok\n"),
            "/workspace/opencode.json": Helper.utf8Bytes(#"{"experimental":{"automations":true,"mcp_events":true}}"#),
        ])
        let server = try await ServerProcess.start(
            options: ServerOptions(hostname: "127.0.0.1", port: 0, password: "server-password"),
            fileSystem: fs,
            defaultDirectory: "/workspace"
        )

        // Automation.run started automatically via ServerProcess.defaultApplicationRuns.
        let started = await Helper.eventually {
            server.router.runtime.automation.isRunning
        }
        #expect(started)

        // Verify /api/machine/link is exempt from password auth at the ServerProcess HTTP dispatch layer too.
        let linkCheck = try await server.transport.send(HTTPRequest(
            method: "GET",
            url: "\(server.address.urlString)\(MACHINE_LINK_PATH)"
        ))
        #expect(linkCheck.head.statusCode == 426)

        // Create a real session so Automation.run can deliver the due prompt to it.
        let targetSession = try await server.router.runtime.session.create(CoreSession.CreateInput(
            location: OpenCodeLocation(directory: "/workspace"),
            permissions: [SessionSchema.PermissionRule(action: "*", resource: "*", effect: .allow)]
        ))

        // Insert a due automation row and wake the loop: Automation.run must fire it without any manual tick().
        let autoID = "aut_server_run_test"
        try Helper.insertDueAutomation(
            db: server.router.runtime.db,
            id: autoID,
            projectID: targetSession.projectID.rawValue,
            sessionID: targetSession.id.rawValue,
            directory: "/workspace",
            name: "due-job",
            nowMs: Flock.currentEpochMs()
        )
        server.router.runtime.automation.wake()

        let fired = await Helper.eventually {
            guard let id = AutomationSchema.ID(rawValue: autoID),
                  let info = try? await server.router.runtime.automation.get(id)
            else { return false }
            return info.runCount.rawValue == 1 && info.status == .done
        }
        #expect(fired)

        // Also start an event-triggered automation backed by CoreBus and verify server.stop() cancels its watch.
        let locOut = try await server.router.runtime.locations.get(
            CoreLocation.ServiceMap.canonical(LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace")))
        )
        let bundle = try #require(ServerLocationBundle.from(locOut))
        let busEvents = CoreMCP.Client.BusEvents(
            server: "ci",
            types: [
                CoreMCP.Client.EventType(
                    name: "deploy.done",
                    delivery: ["push"],
                    inputSchema: ["type": .string("object"), "additionalProperties": .bool(false)],
                    payloadSchema: ["type": .string("object"), "properties": .object(["env": .object(["type": .string("string")])]), "required": .array([.string("env")])]
                ),
            ],
            bus: server.router.runtime.bus
        )
        let mcpRegistry = try #require(bundle.mcp as? CoreMCP.Registry.Service)
        mcpRegistry.registerEvents(server: "ci", events: busEvents)
        let eventAuto = try await server.router.runtime.automation.create(
            AutomationSchema.CreateInput(
                sessionID: targetSession.id,
                name: "watch-deploy",
                trigger: .event(.init(server: "ci", event: "deploy.done")),
                action: .prompt(.init(prompt: "Deploy finished"))
            ),
            projectID: targetSession.projectID,
            directory: "/workspace",
            invocation: CoreAutomation.Author.Invocation(sessionID: targetSession.id, agent: CoreAgent.Agent.defaultID)
        )
        let watching = await Helper.eventually {
            server.router.runtime.automation.activeWatchIDs.contains(eventAuto.id)
        }
        #expect(watching)

        // Closing the server cancels and awaits Automation.run, cancels active watches, and releases the leader lease.
        await server.stop()
        #expect(server.router.runtime.automation.isRunning == false)
        #expect(server.router.runtime.automation.activeWatchIDs.isEmpty)
        #expect(Helper.automationLeaderRowExists(db: server.router.runtime.db) == false)
    }

    // MARK: 5. Path parsing has a single source of truth

    @Test("FileAccess delegates machine path parsing and errors to MachinePath and Machines")
    func pathParsingSingleSourceOfTruth() async throws {
        let client = try SQLiteDatabaseFactory.open(path: ":memory:")
        let dbService = try CoreDatabaseStore.bootstrap(client: client)
        let identity = MachineIdentity.Service(state: "/state", fileSystem: InMemoryFileSystem())
        let machines = try Machines.Service(database: dbService.db, identity: identity)
        _ = try await machines.add("gpu")

        let flags = CoreFlag.Service(
            config: CoreConfig.Test(),
            overrides: CoreFlag.Overrides.fromEnvironment(DictionaryEnvironment(variables: ["OPENCODE_FLAGS": "machines"]))
        )
        let access = CoreFilesystem.FileAccess.Service(
            directory: "/workspace",
            fileSystem: InMemoryFileSystem(),
            home: "/home/local",
            flags: flags,
            machines: machines
        )

        // Valid machine paths match MachinePath.parse directly.
        let parsed = try #require(MachinePath.parse("gpu:/work/../work/a.txt"))
        #expect(parsed.machine == "gpu")
        #expect(parsed.path == "/work/../work/a.txt")
        let located = try await access.locate("gpu:/work/../work/a.txt", base: nil as CoreFilesystem.FileAccess.Place?)
        #expect(located.environment.id == CoreLocation.Environment.ID.make(parsed.machine))
        #expect(located.absolute.rawValue == "/work/a.txt")

        // Non-machine strings rejected by MachinePath.parse resolve locally.
        for nonMachine in ["C:/Windows/win.ini", "local:/etc/hosts", "https://example.com/a", "gpu:relative", "Gpu:/work", "gpu://host/share"] {
            #expect(MachinePath.parse(nonMachine) == nil)
            let localPlace = try await access.locate(nonMachine, base: nil as CoreFilesystem.FileAccess.Place?)
            #expect(localPlace.environment.id == CoreLocation.Environment.localID)
        }

        // Invalid ~other path wraps MachinePath.NotAbsolute (the single error type from MachineJoinPathSQL.swift).
        let notAbs = await #expect(throws: CoreLocation.Environment.Files.Failed.self) {
            _ = try await access.locate("gpu:~other/file", base: nil as CoreFilesystem.FileAccess.Place?)
        }
        #expect(notAbs?.cause as? MachinePath.NotAbsolute == MachinePath.NotAbsolute(machine: "gpu"))

        // Unknown machine wraps Machines.NotFound (the single error type from Machines.swift).
        let notFound = await #expect(throws: CoreLocation.Environment.Files.Failed.self) {
            _ = try await access.resolve(CoreFilesystem.FileAccess.ResolveInput(path: "unknown:/work/a"))
        }
        #expect(notFound?.cause as? Machines.NotFound == Machines.NotFound(machine: "unknown"))
    }
}
