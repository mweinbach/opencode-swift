import Synchronization
import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

private typealias Environment = CoreLocation.Environment
private typealias FileAccess = CoreFilesystem.FileAccess
private typealias FileMutation = CoreFilesystem.FileMutation
private typealias Helper = Sync3FsShellEnvHelper
private typealias EnvHelper = EnvironmentFilesystemHelper

@Suite("Upstream sync #3: fs-shell-env parity")
struct Sync3FsShellEnvTests {

    // MARK: - Environment Facts, Place, local, workingDirectory, node

    @Test("Environment.Place, Facts, local, make, workingDirectory, and FileAccess.Place alias")
    func environmentFactsAndPlace() throws {
        // FileAccess.Place is a deprecated typealias to Environment.Place.
        let envPlace = Environment.Place(absolute: "/repo/src", environment: Environment.localID)
        let accessPlace: FileAccess.Place = envPlace
        #expect(accessPlace == envPlace)

        let encoded = try Helper.encodeJSONPreservingOrder(envPlace)
        let decoded = try Helper.decodeJSON(encoded, as: Environment.Place.self)
        #expect(decoded == envPlace)

        // Environment.local carries hostsServer=true and searchable=true.
        let localEnv = Environment.local()
        #expect(localEnv.id == Environment.localID)
        #expect(localEnv.hostsServer == true)
        #expect(localEnv.searchable == true)
        #expect(localEnv.path == nil)
        #expect(localEnv.shell == nil)

        // Environment.make defaults absent facts to nil and preserves explicit facts.
        let bare = Environment.make("bare", Environment.Driver(spawner: Environment.unavailableSpawner))
        #expect(bare.hostsServer == nil)
        #expect(bare.searchable == nil)
        #expect(bare.path == nil)
        #expect(bare.shell == nil)

        let custom = Environment.make(
            "wrk_custom",
            Environment.Driver(spawner: Environment.unavailableSpawner),
            facts: Environment.Facts(path: .posix, shell: "sh", hostsServer: false, searchable: true)
        )
        #expect(custom.id == "wrk_custom")
        #expect(custom.path == .posix)
        #expect(custom.shell == "sh")
        #expect(custom.hostsServer == false)
        #expect(custom.searchable == true)

        // Environment.workingDirectory returns the Location's directory paired with its environment.
        let location = Helper.makeLocation(directory: "/repo/app")
        let wd = Environment.workingDirectory(location: location, environment: localEnv)
        #expect(wd.absolute.rawValue == "/repo/app")
        #expect(wd.environment.id == Environment.localID)
        #expect(wd.place == Environment.Place(absolute: "/repo/app", environment: Environment.localID))
    }

    @Test("Environment.node marks host as hostsServer+searchable and workspace as searchable-only")
    func environmentNodeFacts() async throws {
        let hostLocation = Helper.makeLocation(directory: "/repo", workspaceID: nil)
        let hostCompiled = try LayerNode.compile(
            Environment.node,
            options: LayerNode.CompileOptions(replacements: [
                CoreLocation.Location.node.replace(
                    with: .succeed(key: CoreLocation.Location.Service.serviceKey, value: hostLocation)
                )
            ])
        )
        let hostOut = try await hostCompiled.build()
        let hostEnv = try #require(hostOut.get(Environment.Service.serviceKey, as: (any CoreLocation.Environment.Interface).self))
        #expect(hostEnv.id == Environment.localID)
        #expect(hostEnv.hostsServer == true)
        #expect(hostEnv.searchable == true)

        let wsID = WorkspaceID(rawValue: "wrk_remote_1")!
        let wsLocation = Helper.makeLocation(directory: "/workspace", workspaceID: wsID)
        let wsCompiled = try LayerNode.compile(
            Environment.node,
            options: LayerNode.CompileOptions(replacements: [
                CoreLocation.Location.node.replace(
                    with: .succeed(key: CoreLocation.Location.Service.serviceKey, value: wsLocation)
                )
            ])
        )
        let wsOut = try await wsCompiled.build()
        let wsEnv = try #require(wsOut.get(Environment.Service.serviceKey, as: (any CoreLocation.Environment.Interface).self))
        #expect(wsEnv.id == "wrk_remote_1")
        #expect(wsEnv.hostsServer == nil)
        #expect(wsEnv.searchable == true)
    }

    // MARK: - MachineDriver.make & MachinePath

    @Test("MachineDriver.make sets POSIX path rules and sh shell facts without hostsServer or searchable")
    func machineDriverFacts() {
        let driver = MachineDriver.make("gpu")
        #expect(driver.environment.id == "gpu")
        #expect(driver.environment.path == .posix)
        #expect(driver.environment.shell == "sh")
        #expect(driver.environment.hostsServer == nil)
        #expect(driver.environment.searchable == nil)
    }

    @Test("MachinePath parse, typed, format, and local handle machine prefixes and edge cases")
    func machinePathHelpers() async throws {
        // format & parse round-trip
        let gpuID = Environment.ID.make("gpu")
        let formatted = MachinePath.format(gpuID, "/work/train.py")
        #expect(formatted == "gpu:/work/train.py")
        #expect(MachinePath.parse(formatted) == MachinePath.Parsed(machine: "gpu", path: "/work/train.py"))
        #expect(MachinePath.format(gpuID, "*") == "gpu:*")

        // local protects local folders whose names look like a machine path
        #expect(MachinePath.local("gpu:/work/a") == "./gpu:/work/a")
        #expect(MachinePath.local("gpu:~/a") == "./gpu:~/a")
        #expect(MachinePath.local("src/main.swift") == "src/main.swift")
        #expect(MachinePath.local("gpu:relative") == "gpu:relative")
        #expect(MachinePath.local("https://example.com") == "https://example.com")

        // typed accepts rooted machine paths, rejects relative paths for known machines, allows unknown names and URLs
        let gpuEnv = try await EnvHelper.memoryEnvironment("gpu")
        let machines = EnvHelper.StubMachines(environments: ["gpu": gpuEnv], homes: ["gpu": "/home/gpu"])
        #expect(try await MachinePath.typed("gpu:/work/a", machines: machines) == MachinePath.Parsed(machine: "gpu", path: "/work/a"))
        #expect(try await MachinePath.typed("gpu:~/a", machines: machines) == MachinePath.Parsed(machine: "gpu", path: "~/a"))
        // Relative path to a known machine throws NotAbsolute
        let err = await #expect(throws: MachinePath.NotAbsolute.self) {
            _ = try await MachinePath.typed("gpu:work/a", machines: machines)
        }
        #expect(err?.machine == "gpu")
        // Relative path to an unknown name stays local (nil)
        #expect(try await MachinePath.typed("other:work/a", machines: machines) == nil)
        // Double-slash URL-like syntax with known machine name is rooted, so typed returns nil (not NotAbsolute)
        #expect(try await MachinePath.typed("gpu://example.com/a", machines: machines) == nil)
        // Windows drive stays local
        #expect(try await MachinePath.typed("C:/Users/me", machines: machines) == nil)
    }

    @Test("FileAccess.always uses MachinePath.format and FileAccess.resolve protects machine-like local paths")
    func fileAccessMachinePathWiring() async throws {
        let gpuEnv = try await EnvHelper.memoryEnvironment("gpu")
        let machines = EnvHelper.StubMachines(environments: ["gpu": gpuEnv], homes: ["gpu": "/home/gpu"])
        let flags = CoreFlag.Service(config: CoreConfig.Test(), channel: "local")
        let fs = InMemoryFileSystem(initialFiles: ["/repo/gpu:/sub/file.txt": Array("hi".utf8)])
        let access = FileAccess.Service(
            directory: "/repo",
            fileSystem: fs,
            environment: Environment.local(fileSystem: fs),
            flags: flags,
            machines: machines
        )
        // Internal local path matching machine-path syntax gets `./` via MachinePath.local when machines flag is on.
        let localTarget = try await access.resolve(FileAccess.ResolveInput(path: "./gpu:/sub/file.txt"))
        #expect(localTarget.resource == "./gpu:/sub/file.txt")
        #expect(FileAccess.always(localTarget) == "*")

        let remoteTarget = try await access.resolve(FileAccess.ResolveInput(path: "gpu:/work/a.py", kind: .file))
        #expect(remoteTarget.resource == "gpu:/work/a.py")
        #expect(remoteTarget.externalDirectory?.resource == "gpu:/work/*")
        #expect(remoteTarget.externalDirectory?.save == "gpu:/work/*")
        #expect(FileAccess.always(remoteTarget) == "gpu:*")
    }

    // MARK: - Formatter hostsServer

    @Test("Formatter checks target.environment.hostsServer rather than environment.id")
    func formatterChecksHostsServer() async throws {
        let spawner = EnvHelper.RecordingSpawner()
        let formatter = CoreFormatter.Service(directory: "/repo", processes: AppProcess.Service(spawner: spawner))
        _ = await formatter.transform { editor in
            editor.set(CoreFormatter.Info(name: "fake", extensions: [".ts"], enabled: { ["true"] }))
        }
        // Even with id == localID, hostsServer: false skips formatting.
        let nonHostLocal = Environment.make(
            Environment.localID,
            Environment.Driver(spawner: Environment.unavailableSpawner),
            facts: Environment.Facts(hostsServer: false, searchable: true)
        )
        let targetNoHost = FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/repo/a.ts"),
            resource: "a.ts",
            environment: nonHostLocal
        )
        #expect(await formatter.file(targetNoHost) == false)
        #expect(spawner.recorded.isEmpty)

        // With hostsServer: true, formatter runs.
        let hostTarget = FileAccess.Target(
            absolute: SchemaPrimitive.AbsolutePath(rawValue: "/repo/a.ts"),
            resource: "a.ts",
            environment: Environment.local()
        )
        #expect(await formatter.file(hostTarget) == true)
        #expect(spawner.recorded.count == 1)
    }

    // MARK: - ShellParse.OpaqueError & ShellPermissions.UnverifiableError

    @Test("ShellParse.scan throws OpaqueError with exact reason and message")
    func shellParseOpaqueError() {
        let sub = #expect(throws: CoreShell.Parse.OpaqueError.self) {
            _ = try CoreShell.Parse.scan(command: "echo $(id)", shell: "sh", cwd: "/repo")
        }
        #expect(sub?.reason == "command-substitution")
        #expect(sub?.message == "Portable shell scanner cannot analyze command: command-substitution")

        let dyn = #expect(throws: CoreShell.Parse.OpaqueError.self) {
            _ = try CoreShell.Parse.scan(command: "alias p=true; p", shell: "sh", cwd: "/repo")
        }
        #expect(dyn?.reason == "dynamic-execution")
        #expect(dyn?.message == "Portable shell scanner cannot analyze command: dynamic-execution")

        let quote = #expect(throws: CoreShell.Parse.OpaqueError.self) {
            _ = try CoreShell.Parse.scan(command: "echo \"unterminated", shell: "sh", cwd: "/repo")
        }
        #expect(quote?.reason == "unterminated-quote")
        #expect(quote?.message == "Portable shell scanner cannot analyze command: unterminated-quote")
    }

    @Test("CoreShellPermissions.requests evaluates rules lazily, throws UnverifiableError on shell deny, and requests wildcard+exact command otherwise")
    func shellPermissionsOpaqueHandling() async throws {
        let access = FileAccess.Service(directory: "/repo", fileSystem: InMemoryFileSystem(), home: "/home/me")
        let localTarget = try await access.resolve(FileAccess.ResolveInput(path: ".", kind: .directory))

        // 1. Analyzable command never invokes the lazy rules closure.
        final class Counter: Sendable {
            private let box = Mutex(0)
            func inc() { box.withLock { $0 += 1 } }
            var value: Int { box.withLock { $0 } }
        }
        let rulesCounter = Counter()
        let okReqs = try await CoreShellPermissions.requests(
            access: access,
            input: CoreShellPermissions.RequestInput(
                command: "ls -la",
                program: "sh",
                target: localTarget,
                rules: {
                    rulesCounter.inc()
                    return [PermissionSchema.Rule(action: "shell", resource: "rm *", effect: .deny)]
                }
            )
        )
        #expect(rulesCounter.value == 0)
        #expect(okReqs.count == 1)
        #expect(okReqs[0].action == "shell")

        // 2. Opaque command with a shell deny rule throws UnverifiableError.
        let unverifiable = await #expect(throws: CoreShellPermissions.UnverifiableError.self) {
            _ = try await CoreShellPermissions.requests(
                access: access,
                input: CoreShellPermissions.RequestInput(
                    command: "alias p=true; printf hello",
                    program: "sh",
                    target: localTarget,
                    rules: {
                        [
                            PermissionSchema.Rule(action: "*", resource: "*", effect: .allow),
                            PermissionSchema.Rule(action: "shell", resource: "rm *", effect: .deny),
                        ]
                    }
                )
            )
        }
        #expect(unverifiable?.reason == "dynamic-execution")
        #expect(
            unverifiable?.message
                == "Portable shell scanner cannot analyze command: dynamic-execution. A shell deny rule is configured and the command cannot be checked against it; rewrite it without eval or other dynamic execution."
        )

        // 3. Opaque command with wildcard deny ("*") also throws UnverifiableError.
        await #expect(throws: CoreShellPermissions.UnverifiableError.self) {
            _ = try await CoreShellPermissions.requests(
                access: access,
                input: CoreShellPermissions.RequestInput(
                    command: "echo $(id)",
                    program: "sh",
                    target: localTarget,
                    rules: { [PermissionSchema.Rule(action: "*", resource: "*", effect: .deny)] }
                )
            )
        }

        // 4. Opaque command with NO shell deny rule (only unrelated read deny + allow rules) returns external_directory("*") + shell(exact, metadata: reason), both save: nil.
        let cmd = "alias p=true; printf hello"
        let opaqueReqs = try await CoreShellPermissions.requests(
            access: access,
            input: CoreShellPermissions.RequestInput(
                command: cmd,
                program: "sh",
                target: localTarget,
                rules: { [PermissionSchema.Rule(action: "read", resource: "*.env", effect: .deny)] }
            )
        )
        #expect(opaqueReqs.count == 2)
        #expect(opaqueReqs[0] == FileAccess.PermissionRequest(action: "external_directory", resources: ["*"], save: nil))
        #expect(opaqueReqs[1] == FileAccess.PermissionRequest(
            action: "shell",
            resources: [cmd],
            save: nil,
            metadata: ["reason": .string("dynamic-execution")]
        ))

        // 5. Target with machine != nil leaves `~` unexpanded so locating resolves it on that machine.
        let gpuEnv = try await EnvHelper.memoryEnvironment("gpu", files: ["/home/gpu/proj/a.txt": "ok"])
        let machines = EnvHelper.StubMachines(environments: ["gpu": gpuEnv], homes: ["gpu": "/home/gpu"])
        let flags = CoreFlag.Service(config: CoreConfig.Test(), channel: "local")
        let machineAccess = FileAccess.Service(
            directory: "/repo",
            fileSystem: InMemoryFileSystem(),
            home: "/home/server",
            flags: flags,
            machines: machines
        )
        let gpuTarget = try await machineAccess.resolve(FileAccess.ResolveInput(path: "gpu:/work", kind: .directory))
        let gpuReqs = try await CoreShellPermissions.requests(
            access: machineAccess,
            input: CoreShellPermissions.RequestInput(
                command: "cd ~/proj && ls",
                program: "sh",
                target: gpuTarget
            )
        )
        #expect(gpuReqs.first?.action == "external_directory")
        #expect(gpuReqs.first?.resources.contains("gpu:/home/gpu/proj/*") == true)
    }

    // MARK: - ShellTool.Plugin opaque permissions, agents+session rules merge, and metadata forwarding

    @Test("ShellTool.Plugin blocks unanalyzable commands on agent/session shell deny rule and forwards metadata otherwise")
    func shellToolPluginOpaqueRules() async throws {
        let fs = InMemoryFileSystem()
        try await fs.makeDirectory(at: "/repo", recursive: true)
        let spawner = EnvHelper.RecordingSpawner(output: ProcessOutput(exitCode: 0, stdout: Array("ok\n".utf8), stderr: []))
        let (sessionSvc, sessionID) = try await Helper.openSessionService(
            directory: "/repo",
            permissions: [SessionSchema.PermissionRule(action: "shell", resource: "rm *", effect: .deny)]
        )
        let agents = CoreAgent.Agent.Service()
        let perm = Helper.RecordingPermission()
        let env = CoreTool.BuiltinEnvironment(
            directory: "/repo",
            fileSystem: fs,
            environment: Environment.local(fileSystem: fs, spawner: spawner),
            permission: perm,
            shell: CoreShell.Service(
                directory: "/repo",
                fileSystem: fs,
                processes: AppProcess.Service(spawner: spawner),
                environment: Environment.local(fileSystem: fs, spawner: spawner)
            ),
            processes: AppProcess.Service(spawner: spawner),
            session: sessionSvc,
            agent: agents
        )
        let registry = CoreTool.Service()
        _ = await registry.transform { editor in
            CoreTool.ShellTool.Plugin.register(editor, env)
        }
        let shellTool = try #require(await registry.list().first(where: { $0.name == "shell" }))
        let ctx = Helper.makeToolContext(sessionID: sessionID)

        // Session has a shell deny rule -> fails with UnverifiableError without prompting permission or spawning.
        let failure = await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await shellTool.execute(.object(["command": .string("alias p=true; echo hi")]), ctx)
        }
        #expect(failure?.message.contains("Portable shell scanner cannot analyze command: dynamic-execution. A shell deny rule is configured") == true)
        #expect(perm.recorded.isEmpty)
        #expect(spawner.recorded.isEmpty)

        // Without any shell deny rule, asks for external_directory("*") + shell(exact, metadata: reason) and executes.
        let (allowSessionSvc, allowSessionID) = try await Helper.openSessionService(directory: "/repo")
        let allowPerm = Helper.RecordingPermission()
        let allowEnv = CoreTool.BuiltinEnvironment(
            directory: "/repo",
            fileSystem: fs,
            environment: Environment.local(fileSystem: fs, spawner: spawner),
            permission: allowPerm,
            shell: CoreShell.Service(
                directory: "/repo",
                fileSystem: fs,
                processes: AppProcess.Service(spawner: spawner),
                environment: Environment.local(fileSystem: fs, spawner: spawner)
            ),
            processes: AppProcess.Service(spawner: spawner),
            session: allowSessionSvc,
            agent: agents
        )
        let allowRegistry = CoreTool.Service()
        _ = await allowRegistry.transform { editor in
            CoreTool.ShellTool.Plugin.register(editor, allowEnv)
        }
        let allowShellTool = try #require(await allowRegistry.list().first(where: { $0.name == "shell" }))
        let allowCtx = Helper.makeToolContext(sessionID: allowSessionID)
        let opaqueCmd = "alias p=true; echo hi"
        let res = try await allowShellTool.execute(.object(["command": .string(opaqueCmd)]), allowCtx)
        #expect(res.metadata?["status"] == .string("completed"))
        #expect(allowPerm.recorded.count == 2)
        #expect(allowPerm.recorded[0].action == "external_directory")
        #expect(allowPerm.recorded[0].resources == ["*"])
        #expect(allowPerm.recorded[0].save == nil)
        #expect(allowPerm.recorded[1].action == "shell")
        #expect(allowPerm.recorded[1].resources == [opaqueCmd])
        #expect(allowPerm.recorded[1].save == nil)
        #expect(allowPerm.recorded[1].metadata == ["reason": .string("dynamic-execution")])

        // When permission denies "shell" on malformed syntax, error reports "Permission denied: shell" and doesn't execute.
        let denyPerm = Helper.RecordingPermission(denyAction: "shell")
        let denySpawner = EnvHelper.RecordingSpawner()
        let denyEnv = CoreTool.BuiltinEnvironment(
            directory: "/repo",
            fileSystem: fs,
            environment: Environment.local(fileSystem: fs, spawner: denySpawner),
            permission: denyPerm,
            shell: CoreShell.Service(
                directory: "/repo",
                fileSystem: fs,
                processes: AppProcess.Service(spawner: denySpawner),
                environment: Environment.local(fileSystem: fs, spawner: denySpawner)
            ),
            processes: AppProcess.Service(spawner: denySpawner),
            session: allowSessionSvc,
            agent: agents
        )
        let denyRegistry = CoreTool.Service()
        _ = await denyRegistry.transform { editor in
            CoreTool.ShellTool.Plugin.register(editor, denyEnv)
        }
        let denyShellTool = try #require(await denyRegistry.list().first(where: { $0.name == "shell" }))
        let malformed = "printf hello > marker\necho \""
        let blocked = await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await denyShellTool.execute(.object(["command": .string(malformed)]), allowCtx)
        }
        #expect(blocked?.message.contains("Permission denied: shell") == true)
        #expect(denyPerm.recorded.count == 2)
        #expect(denyPerm.recorded[1].metadata == ["reason": .string("unterminated-quote")])
        #expect(denySpawner.recorded.isEmpty)
    }

    // MARK: - ToolSearch.available, GlobTool, GrepTool, ReadTool, Shell.Service facts

    @Test("ToolSearch.available, GlobTool, and GrepTool gate on environment.searchable")
    func searchAvailableChecksSearchableFact() async throws {
        let nonSearchable = try await EnvHelper.memoryEnvironment("gpu", files: ["/work/a.swift": "let hit = 1\n"])
        let err = #expect(throws: AISchema.ToolFailure.self) {
            try CoreToolOutput.Search.available(nonSearchable)
        }
        #expect(err?.message == "Search is not available on gpu yet.")

        let searchableWs = try await EnvHelper.memoryEnvironment(
            "wrk_search",
            files: ["/work/a.swift": "let hit = 1\n"],
            facts: Environment.Facts(searchable: true)
        )
        try CoreToolOutput.Search.available(searchableWs)

        // GlobTool & GrepTool succeed on a searchable workspace environment, and fail on a non-searchable machine.
        let localFS = InMemoryFileSystem()
        let baseAccess = FileAccess.Service(directory: "/work", fileSystem: localFS)
        let perm = Helper.RecordingPermission()
        let ctx = Helper.makeToolContext(sessionID: SessionID.create())

        let wsEnv = CoreTool.BuiltinEnvironment(
            directory: "/work",
            fileSystem: localFS,
            fileAccess: Helper.ElsewhereFileAccess(inner: baseAccess, environment: searchableWs),
            permission: perm
        )
        let wsRegistry = CoreTool.Service()
        _ = await wsRegistry.transform { editor in
            CoreTool.GlobTool.Plugin.register(editor, wsEnv)
            CoreTool.GrepTool.Plugin.register(editor, wsEnv)
        }
        let globTool = try #require(await wsRegistry.list().first(where: { $0.name == "glob" }))
        let grepTool = try #require(await wsRegistry.list().first(where: { $0.name == "grep" }))
        let globRes = try await globTool.execute(.object(["pattern": .string("*.swift")]), ctx)
        #expect(globRes.metadata?["count"] == .int(1))
        let grepRes = try await grepTool.execute(.object(["pattern": .string("hit"), "literal": .bool(true)]), ctx)
        #expect(grepRes.metadata?["matches"] == .int(1))

        let gpuEnv = CoreTool.BuiltinEnvironment(
            directory: "/work",
            fileSystem: localFS,
            fileAccess: Helper.ElsewhereFileAccess(inner: baseAccess, environment: nonSearchable),
            permission: perm
        )
        let gpuRegistry = CoreTool.Service()
        _ = await gpuRegistry.transform { editor in
            CoreTool.GlobTool.Plugin.register(editor, gpuEnv)
            CoreTool.GrepTool.Plugin.register(editor, gpuEnv)
        }
        let gpuGlob = try #require(await gpuRegistry.list().first(where: { $0.name == "glob" }))
        let gpuGrep = try #require(await gpuRegistry.list().first(where: { $0.name == "grep" }))
        let globFail = await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await gpuGlob.execute(.object(["pattern": .string("*.swift")]), ctx)
        }
        #expect(globFail?.message == "Search is not available on gpu yet.")
        let grepFail = await #expect(throws: AISchema.ToolFailure.self) {
            _ = try await gpuGrep.execute(.object(["pattern": .string("hit")]), ctx)
        }
        #expect(grepFail?.message == "Search is not available on gpu yet.")
    }

    @Test("ReadTool alternatePath uses target.environment.path rules")
    func readToolUsesEnvironmentPathRules() async throws {
        // File has curly apostrophe; input asks with ASCII apostrophe; remote environment declares POSIX path rules.
        let gpu = try await EnvHelper.memoryEnvironment(
            "gpu",
            files: ["/work/don\u{2019}t.txt": "recovered content"],
            facts: Environment.Facts(path: .posix, shell: "sh")
        )
        let localFS = InMemoryFileSystem()
        let machines = EnvHelper.StubMachines(environments: ["gpu": gpu], homes: ["gpu": "/home/gpu"])
        let baseAccess = FileAccess.Service(directory: "/work", fileSystem: localFS, machines: machines)
        let perm = Helper.RecordingPermission()
        let env = CoreTool.BuiltinEnvironment(
            directory: "/work",
            fileSystem: localFS,
            fileAccess: Helper.ElsewhereFileAccess(inner: baseAccess, environment: gpu),
            permission: perm
        )
        let registry = CoreTool.Service()
        _ = await registry.transform { editor in
            CoreTool.ReadTool.Plugin.register(editor, env)
        }
        let readTool = try #require(await registry.list().first(where: { $0.name == "read" }))
        let ctx = Helper.makeToolContext(sessionID: SessionID.create())
        let res = try await readTool.execute(.object(["path": .string("/work/don't.txt")]), ctx)
        if case .object(let obj) = res.output {
            #expect(obj["type"] == .string("text"))
            #expect(obj["content"] == .string("recovered content"))
        } else {
            Issue.record("Expected structured text output from read tool")
        }
    }

    @Test("CoreShell.Service uses target.shell and target.hostsServer facts")
    func shellServiceUsesTargetFacts() async throws {
        let spawner = EnvHelper.RecordingSpawner()
        // Workspace: hostsServer=nil, shell=nil -> preserves caller's shell, keeps relative cwd, runs via target.spawner.
        let workspace = try await EnvHelper.memoryEnvironment(
            "wrk_1",
            spawner: spawner,
            facts: Environment.Facts(searchable: true)
        )
        let shell = CoreShell.Service(directory: "/repo", fileSystem: InMemoryFileSystem())
        let wsStarted = try await shell.create(
            CoreShell.CreateRequest(command: "pwd", cwd: "sub", shell: "/bin/bash", environment: workspace),
            before: nil
        )
        #expect(wsStarted.shell == "/bin/bash")
        #expect(wsStarted.cwd == "sub")
        _ = await shell.result(wsStarted, waitMs: nil)
        #expect(spawner.recorded.last?.executable == "/bin/bash")
        #expect(spawner.recorded.last?.workingDirectory == "sub")

        // Machine: shell="sh" -> overrides caller's shell.
        let machine = try await EnvHelper.memoryEnvironment(
            "gpu",
            spawner: spawner,
            facts: Environment.Facts(path: .posix, shell: "sh")
        )
        let gpuStarted = try await shell.create(
            CoreShell.CreateRequest(command: "nvidia-smi", cwd: "/work", shell: "/bin/zsh", environment: machine),
            before: nil
        )
        #expect(gpuStarted.shell == "sh")
        _ = await shell.result(gpuStarted, waitMs: nil)
        #expect(spawner.recorded.last?.executable == "sh")
    }

    // MARK: - Shell.DaemonInterface & CommandHost

    @Test("CoreShell.Daemon.at recovers matching Location runs, persists stop metadata, and reports host.lost on process failure")
    func shellDaemonCommandHostLifecycle() async throws {
        let existingID = ShellSchema.ID.create()
        let otherID = ShellSchema.ID.create()
        let existingProc = Helper.StubCommandProcess(
            info: CoreShell.CommandInfo(
                pid: 111,
                cwd: "/repo",
                lifecycle: .running,
                outputPath: "/tmp/existing.out",
                outputLines: 0,
                outputError: nil,
                metadata: [
                    "id": .string(existingID.rawValue),
                    "command": .string("sleep 60"),
                    "shell": .string("/bin/sh"),
                    "directory": .string("/repo"),
                    "metadata": .object([:]),
                ],
                startedAt: 1_000,
                exitedAt: nil
            )
        )
        let otherProc = Helper.StubCommandProcess(
            info: CoreShell.CommandInfo(
                pid: 222,
                cwd: "/other",
                lifecycle: .running,
                outputPath: "/tmp/other.out",
                outputLines: 0,
                outputError: nil,
                metadata: [
                    "id": .string(otherID.rawValue),
                    "command": .string("sleep 60"),
                    "shell": .string("/bin/sh"),
                    "directory": .string("/other"),
                    "metadata": .object([:]),
                ],
                startedAt: 1_000,
                exitedAt: nil
            )
        )
        let host = Helper.StubCommandHost(lost: "daemon vanished", existing: [existingProc, otherProc])
        let daemon = CoreShell.Daemon(host: host, handoffPrepared: { true })
        #expect(daemon.handoffPrepared() == true)

        let loc = Helper.makeLocation(directory: "/repo")
        let runs = try #require(await daemon.at(loc))
        // Only the matching Location's run is recovered.
        #expect(runs.list().map(\.info.id) == [existingID])
        #expect(runs.get(otherID) == nil)

        // Losing the recovered process records host.lost as killed.
        existingProc.finish(.failure(Helper.HostLostError()))
        for _ in 0..<20 {
            if runs.get(existingID)?.killed != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runs.get(existingID)?.killed == "daemon vanished")
        #expect(runs.get(existingID)?.info.status == .killed)

        // Create a new run, stop it, and remove it.
        let newID = ShellSchema.ID.create()
        let created = try await runs.create(CoreShell.RunCreateInput(
            info: ShellSchema.Info(
                id: newID,
                status: .running,
                command: "echo hi",
                cwd: "/repo",
                shell: "/bin/sh",
                file: "/tmp/new.out",
                pid: nil,
                exit: nil,
                signal: nil,
                metadata: [:],
                time: ShellSchema.Time(started: 500, completed: nil)
            ),
            args: ["-c", "echo hi"],
            env: [:],
            timeout: 0,
            toolCall: nil,
            waited: true
        ))
        #expect(created.pid?.rawValue == 4242)
        let createdProc = try #require(host.createdProcesses.first?.1)
        await runs.stop(newID, reason: .killed)
        #expect(createdProc.sentSignals == [.term])
        #expect(createdProc.storedMetadata.last?["stopReason"] == .string("killed"))

        await runs.remove(newID)
        #expect(createdProc.wasRemoved == true)
        #expect(runs.get(newID) == nil)
    }

    // MARK: - JSON Field Ordering for Truncation Survival

    @Test("SessionSearch, ReadFilesystem, and ShellTool outputs emit metadata fields before large payload fields")
    func truncationSafeJSONFieldOrder() throws {
        // 1. SessionSearch.SearchOutput: next precedes results / sessions
        let summary = SessionSearch.SessionSummary(
            sessionID: SessionID.create(),
            title: "t",
            directory: "/repo",
            created: "2026-01-01T00:00:00.000Z",
            updated: "2026-01-01T00:00:00.000Z"
        )
        #expect(try Helper.encodedTopLevelKeys(SessionSearch.SearchOutput(sessions: [summary], next: 20)) == ["next", "sessions"])
        #expect(try Helper.encodedTopLevelKeys(SessionSearch.SearchOutput(sessions: [summary], next: nil)) == ["next", "sessions"])
        let sessionsJSON = try Helper.encodeJSONPreservingOrder(SessionSearch.SearchOutput(sessions: [summary], next: nil))
        #expect(sessionsJSON.contains("\"next\":null"))

        // 2. SessionSearch.CallDetail: name, status, error, input, output
        let callDetail = SessionSearch.CallDetail(
            name: "shell",
            status: "error",
            input: "{\"command\":\"false\"}",
            output: "long output",
            error: "boom"
        )
        #expect(try Helper.encodedTopLevelKeys(callDetail) == ["name", "status", "error", "input", "output"])
        #expect(try Helper.decodeJSON(Helper.encodeJSONPreservingOrder(callDetail), as: SessionSearch.CallDetail.self) == callDetail)

        // 3. ReadFilesystem.TextContent: type, offset, lineCount, next, content
        let textContent = CoreToolOutput.ReadFilesystem.TextContent(
            content: "hello",
            offset: 1,
            lineCount: 1,
            next: 2
        )
        #expect(try Helper.encodedTopLevelKeys(textContent) == ["type", "offset", "lineCount", "next", "content"])
        #expect(try Helper.decodeJSON(Helper.encodeJSONPreservingOrder(textContent), as: CoreToolOutput.ReadFilesystem.TextContent.self) == textContent)

        // 4. ReadFilesystem.DirectoryContent: type, next, entries
        let dirContent = CoreToolOutput.ReadFilesystem.DirectoryContent(
            entries: ["a.swift", "b.swift"],
            next: 3
        )
        #expect(try Helper.encodedTopLevelKeys(dirContent) == ["type", "next", "entries"])
        #expect(try Helper.decodeJSON(Helper.encodeJSONPreservingOrder(dirContent), as: CoreToolOutput.ReadFilesystem.DirectoryContent.self) == dirContent)

        // 5. ReadFilesystem.MediaContent: type, mime, name, uri
        let mediaContent = CoreToolOutput.ReadFilesystem.MediaContent(
            uri: "data:image/png;base64,AAA",
            mime: "image/png",
            name: "pic.png"
        )
        #expect(try Helper.encodedTopLevelKeys(mediaContent) == ["type", "mime", "name", "uri"])
        #expect(try Helper.decodeJSON(Helper.encodeJSONPreservingOrder(mediaContent), as: CoreToolOutput.ReadFilesystem.MediaContent.self) == mediaContent)

        // 6. ShellTool.StructuredOutput: shellID, exitCode, signal, killed, outputPath, pid, wallTimeSeconds precede output
        let shellOut = CoreTool.ShellTool.StructuredOutput(
            shellID: nil,
            exitCode: 3,
            signal: nil,
            killed: nil,
            outputPath: "/tmp/sh_1.out",
            pid: nil,
            wallTimeSeconds: 1.5,
            output: "very long output"
        )
        #expect(try Helper.encodedTopLevelKeys(shellOut) == ["exitCode", "outputPath", "wallTimeSeconds", "output"])
        #expect(try Helper.decodeJSON(Helper.encodeJSONPreservingOrder(shellOut), as: CoreTool.ShellTool.StructuredOutput.self) == shellOut)
    }
}
