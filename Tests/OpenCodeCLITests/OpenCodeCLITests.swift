import Testing
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil

@Suite("OpenCodeCLI Core Utilities, Archive & Node Targets")
struct CLIUtilAndArchiveTests {
    @Test("OpenCodeCLIKit module metadata and version flags")
    func moduleMetadata() {
        #expect(OpenCodeCLIKitModule.upstreamPackage == "cli")
        #expect(OpenCodeCLIKitModule.serverModulePackage == "server")
        #expect(OpenCodeCLIKitModule.sdkModulePackage == "sdk")
        #expect(CLIUtil.Version.OPENCODE_LOCAL == true)
        #expect(CLIUtil.errorMessage(CLIError("boom")) == "boom")
    }

    @Test("Env.password honors OPENCODE_PASSWORD over legacy OPENCODE_SERVER_PASSWORD and Env.session strips secrets")
    func environmentSecrets() {
        let (ctx1, _, _) = CLITestFixtures.makeContext(env: [
            "OPENCODE_PASSWORD": "primary",
            "OPENCODE_SERVER_PASSWORD": "legacy",
            "PATH": "/usr/bin",
        ])
        #expect(CLIUtil.Env.password(ctx1)?.value == "primary")
        #expect(CLIUtil.Env.password(ctx1)?.description == "<redacted>")

        let (ctx2, _, _) = CLITestFixtures.makeContext(env: [
            "OPENCODE_SERVER_PASSWORD": "legacy-only",
        ])
        #expect(CLIUtil.Env.password(ctx2)?.value == "legacy-only")

        let safe = CLIUtil.Env.session(environment: [
            "HOME": "/tmp/home",
            "OPENCODE_PASSWORD": "secret",
            "OPENCODE_SERVER_PASSWORD": "legacy-secret",
            "TERM": "xterm-256color",
        ])
        #expect(safe["HOME"] == "/tmp/home")
        #expect(safe["TERM"] == "xterm-256color")
        #expect(safe["OPENCODE_PASSWORD"] == nil)
        #expect(safe["OPENCODE_SERVER_PASSWORD"] == nil)
    }

    @Test("databasePath resolves standard channels, custom channels, :memory:, and overrides")
    func databasePathResolution() {
        let emptyEnv = DictionaryEnvironment()
        #expect(CLIUtil.databasePath("/data", channel: "latest", environment: emptyEnv) == "/data/opencode.db")
        #expect(CLIUtil.databasePath("/data", channel: "dev", environment: emptyEnv) == "/data/opencode.db")
        #expect(CLIUtil.databasePath("/data", channel: "local", environment: emptyEnv) == "/data/opencode-local.db")
        #expect(CLIUtil.databasePath("/data", channel: "feat/my branch", environment: emptyEnv) == "/data/opencode-feat-my-branch.db")

        let disabledEnv = DictionaryEnvironment(variables: ["OPENCODE_DISABLE_CHANNEL_DB": "1"])
        #expect(CLIUtil.databasePath("/data", channel: "local", environment: disabledEnv) == "/data/opencode.db")

        let memEnv = DictionaryEnvironment(variables: ["OPENCODE_DB": ":memory:"])
        #expect(CLIUtil.databasePath("/data", channel: "local", environment: memEnv) == ":memory:")

        let customEnv = DictionaryEnvironment(variables: ["OPENCODE_DB": "custom.sqlite"])
        #expect(CLIUtil.databasePath("/data", channel: "latest", environment: customEnv) == "/data/custom.sqlite")
    }

    @Test("selfCommand handles compiled binary, bun, and node with execArgv filtering")
    func selfCommandResolution() throws {
        #expect(try CLIUtil.selfCommand(execPath: "/usr/local/bin/opencode") == ["/usr/local/bin/opencode"])
        #expect(try CLIUtil.selfCommand(execPath: "/opt/bun/bin/bun", entrypoint: "/app/cli.ts") == ["/opt/bun/bin/bun", "/app/cli.ts"])
        let nodeCmd = try CLIUtil.selfCommand(
            execPath: "/usr/bin/node",
            entrypoint: "/app/cli.js",
            execArgv: ["--conditions", "development", "--use-system-ca", "--inspect", "--disable-warning=ExperimentalWarning"]
        )
        #expect(nodeCmd == ["/usr/bin/node", "--conditions", "development", "--use-system-ca", "--disable-warning=ExperimentalWarning", "/app/cli.js"])

        #expect(throws: CLIError.self) {
            _ = try CLIUtil.selfCommand(execPath: "/usr/bin/node", entrypoint: nil)
        }
    }

    @Test("AppArchive encodes and decodes binary archives with little-endian u32 header")
    func appArchiveRoundtrip() throws {
        let entries: [(String, [UInt8])] = [
            ("index.html", Array("<html>hello</html>".utf8)),
            ("_assets/app.bin", [0x00, 0x01, 0xFE, 0xFF, 0x42]),
        ]
        let encoded = try CLIUtil.AppArchive.encode(entries)
        #expect(encoded.count > 4)
        let decoded = try CLIUtil.AppArchive.decode(encoded)
        #expect(decoded["index.html"] == Array("<html>hello</html>".utf8))
        #expect(decoded["_assets/app.bin"] == [0x00, 0x01, 0xFE, 0xFF, 0x42])

        #expect(throws: CLIError.self) {
            _ = try CLIUtil.AppArchive.decode([1, 2])
        }
    }

    @Test("AppAssets loads embedded archives and local source directories skipping source maps")
    func appAssetsLoading() async throws {
        let archive = try CLIUtil.AppArchive.encode([
            ("index.html", Array("<h1>OpenCode</h1>".utf8)),
            ("_assets/icon.png", [0x89, 0x50, 0x4E, 0x47]),
        ])
        let loaded = try await CLIUtil.AppAssets.load(embeddedArchive: archive, isLocal: false)
        #expect(loaded.files["index.html"] == .text("<h1>OpenCode</h1>"))
        #expect(loaded.files["_assets/icon.png"] == .binary([0x89, 0x50, 0x4E, 0x47]))
        #expect(loaded.brotli?["index.html"] != nil)

        let fs = InMemoryFileSystem(initialFiles: [
            "/dist/index.html": Array("<html/>".utf8),
            "/dist/app.js.map": Array("{}".utf8),
        ])
        let fromDisk = try await CLIUtil.AppAssets.load(sourceRoot: "/dist", isLocal: true, fileSystem: fs)
        #expect(fromDisk.files["index.html"] == .text("<html/>"))
        #expect(fromDisk.files["app.js.map"] == nil)

        await #expect(throws: CLIError.self) {
            _ = try await CLIUtil.AppAssets.load(embeddedArchive: nil, isLocal: false)
        }
    }

    @Test("NodeTarget builds platform-specific asset coordinates and validates inputs")
    func nodeTargetCoordinates() throws {
        let mac = try CLIUtil.Node.nodeTarget(platform: "darwin", arch: "arm64")
        #expect(mac.fffAsset == "@ff-labs/fff-bin-darwin-arm64/libfff_c.dylib")
        #expect(mac.opencodePtyAsset == "opencode-pty/opencode-pty")

        let linux = try CLIUtil.Node.nodeTarget(platform: "linux", arch: "x64")
        #expect(linux.parcelWatcherPackage == "@parcel/watcher-linux-x64-glibc")
        #expect(linux.fffFfiAsset.hasSuffix("-gnu.node"))

        let win = try CLIUtil.Node.nodeTarget(platform: "win32", arch: "x64")
        #expect(win.fffAsset.hasSuffix("fff_c.dll"))
        #expect(win.opencodePtyAsset == "opencode-pty/opencode-pty.exe")
        #expect(CLIUtil.Node.photonWasmAsset.hasSuffix(".wasm"))
        #expect(CLIUtil.Node.nodeExecArgv.contains("--use-system-ca"))
        #expect(CLIUtil.Node.attentionSoundAssets.count == 5)

        #expect(throws: CLIError.self) {
            _ = try CLIUtil.Node.nodeTarget(platform: "freebsd", arch: "x64")
        }
    }

    @Test("SSHAskpass exchanges JSON request/response and handles null/invalid ports")
    func sshAskpassProtocol() async {
        let (ctx, output, _) = CLITestFixtures.makeContext(
            env: [
                "OPENCODE_SSH_ASKPASS_PORT": "51234",
                "OPENCODE_SSH_ASKPASS_TOKEN": "tok-123",
                "SSH_ASKPASS_PROMPT": "confirm",
            ],
            rawArguments: ["Are", "you", "sure?"]
        )
        let code = await CLIUtil.SSHAskpass.askpass(ctx) { port, payload in
            #expect(port == 51234)
            #expect(payload.contains("\"token\":\"tok-123\""))
            #expect(payload.contains("\"confirm\":true"))
            #expect(payload.contains("\"text\":\"Are you sure?\""))
            return "{\"value\":\"yes\"}"
        }
        #expect(code == 0)
        #expect(output.stdout == "yes\n")

        let nullCode = await CLIUtil.SSHAskpass.askpass(ctx) { _, _ in "{\"value\":null}" }
        #expect(nullCode == 1)

        let (badCtx, _, _) = CLITestFixtures.makeContext(env: ["OPENCODE_SSH_ASKPASS_PORT": "99999"])
        let badCode = await CLIUtil.SSHAskpass.askpass(badCtx, nil)
        #expect(badCode == 1)
    }

    @Test("Heap and CpuProfile listeners write diagnostic artifacts into global.log")
    func diagnosticListeners() async {
        let (ctx, _, fs) = CLITestFixtures.makeContext()
        let heap = CLIUtil.Heap.listen(ctx)
        let snapshot = await heap.captureNow()
        heap.stop()
        #expect(snapshot != nil)
        if let path = snapshot?.path {
            #expect(await fs.exists(at: path))
        }

        let cpu = CLIUtil.CpuProfile.listen(ctx)
        let profilePath = await cpu.captureNow()
        cpu.stop()
        #expect(profilePath != nil)
        if let profilePath {
            #expect(await fs.exists(at: profilePath))
        }

        let guardHandle = CLIUtil.ShutdownDeadline.install(.seconds(5), ctx) { _ in }
        #expect(guardHandle.handleSignal("SIGTERM") == nil)
        let second = guardHandle.handleSignal("SIGINT")
        #expect(second?.contains("received SIGINT again during shutdown") == true)
        guardHandle.release()
    }
}

@Suite("CLIFramework Argument Parsing & Help Rendering")
struct CLIFrameworkTests {
    @Test("optionalValue parses -w and --worktree=name without consuming next positional")
    func optionalValueWorktreeParsing() throws {
        let runNode = try #require(CLICommands.Commands.commands["run"])

        let flagOnly = try CLIFramework.Runtime.parseCommandInput(
            node: runNode,
            commandPath: ["run"],
            globalDefinitions: [CLICommands.PrintLogs, CLICommands.Standalone, CLICommands.Server],
            tokens: ["-w", "fix it"]
        )
        #expect(flagOnly.optionalFlag("worktree") == .flagOnly)
        #expect(flagOnly.args("message") == ["fix it"])

        let named = try CLIFramework.Runtime.parseCommandInput(
            node: runNode,
            commandPath: ["run"],
            globalDefinitions: [CLICommands.PrintLogs, CLICommands.Standalone, CLICommands.Server],
            tokens: ["--worktree=feat-x", "fix it", "-f", "a.txt", "-f", "b.txt"]
        )
        #expect(named.optionalFlag("worktree") == .value("feat-x"))
        #expect(named.args("message") == ["fix it"])
        #expect(named.stringsList("file") == ["a.txt", "b.txt"])

        let emptyEq = try CLIFramework.Runtime.parseCommandInput(
            node: runNode,
            commandPath: ["run"],
            globalDefinitions: [],
            tokens: ["--worktree=", "hello"]
        )
        #expect(emptyEq.optionalFlag("worktree") == .flagOnly)
        #expect(emptyEq.args("message") == ["hello"])
    }

    @Test("CLIFramework parses --no-replay negation, key-value pairs, and -- passthrough")
    func flagVariantsAndPassthrough() throws {
        let miniNode = try #require(CLICommands.Commands.commands["mini"])
        let parsedMini = try CLIFramework.Runtime.parseCommandInput(
            node: miniNode,
            commandPath: ["mini"],
            globalDefinitions: [],
            tokens: ["--no-replay", "--replay-limit", "50", "-m", "anthropic/claude-sonnet-4"]
        )
        #expect(parsedMini.optionalBool("replay") == false)
        #expect(parsedMini.integer("replay-limit") == 50)
        #expect(parsedMini.string("model") == "anthropic/claude-sonnet-4")

        let mcpAdd = try #require(CLICommands.Commands.commands["mcp"]?.commands["add"])
        let parsedMcp = try CLIFramework.Runtime.parseCommandInput(
            node: mcpAdd,
            commandPath: ["mcp", "add"],
            globalDefinitions: [],
            tokens: ["my-mcp", "--env", "FOO=bar", "--", "npx", "-y", "server"]
        )
        #expect(parsedMcp.arg("name") == "my-mcp")
        #expect(parsedMcp.keyValueMap("env") == ["FOO": "bar"])
        #expect(parsedMcp.passthrough == ["npx", "-y", "server"])
    }
}

@Suite("CLIConfig & V1 Migration")
struct CLIConfigTests {
    @Test("normalizeLegacyTabs converts tabs.enabled into tabs.mode and clears enabled")
    func normalizeTabs() {
        let raw = CLIConfig.Info(tui: TUIConfig.Info(tabs: TUIConfig.TabsConfig(mode: nil, enabled: false)))
        let normalized = CLIConfig.normalizeLegacyTabs(raw)
        #expect(normalized?.tabs?.mode == .off)
        #expect(normalized?.tabs?.enabled == nil)

        let explicit = CLIConfig.Info(tui: TUIConfig.Info(tabs: TUIConfig.TabsConfig(mode: .auto, enabled: true)))
        let kept = CLIConfig.normalizeLegacyTabs(explicit)
        #expect(kept?.tabs?.mode == .auto)
        #expect(kept?.tabs?.enabled == nil)
    }

    @Test("migrateV1 maps legacy tui.json and kv.json settings into V2 CLIConfig.Info")
    func v1Migration() {
        let legacy = TUIConfig.V1.Info(
            theme: "tokyonight",
            keybinds: [
                "app_exit": "ctrl+q",
                "unknown_keybind_removed": "ctrl+k",
            ],
            plugin: [.name("acme-plugin")],
            pluginEnabled: ["builtin-foo": false],
            leaderTimeout: 1500,
            scrollSpeed: 2.0,
            scrollAcceleration: TUIConfig.V1.ScrollAcceleration(enabled: true),
            diffStyle: .stacked,
            mouse: false
        )
        let kv: [String: JSONValue] = [
            "theme_mode_lock": .string("dark"),
            "terminal_title_enabled": .bool(true),
            "paste_summary_enabled": .bool(true),
            "thinking_visibility": .bool(false),
            "exploration_grouping": .bool(true),
            "animations_enabled": .bool(false),
        ]
        let migrated = CLIConfig.Migration.migrateV1(legacy, kv: kv)
        #expect(migrated.theme?.name == "tokyonight")
        #expect(migrated.theme?.mode == .dark)
        #expect(migrated.keybinds?["app.exit"] == "ctrl+q")
        #expect(migrated.keybinds?["unknown_keybind_removed"] == nil)
        #expect(migrated.plugins == [.specifier("acme-plugin"), .specifier("-builtin-foo")])
        #expect(migrated.leader?.timeout == 1500)
        #expect(migrated.scroll?.speed == 2.0)
        #expect(migrated.scroll?.acceleration == true)
        #expect(migrated.diffs?.view == "unified")
        #expect(migrated.terminal?.title == true)
        #expect(migrated.prompt?.paste == "compact")
        #expect(migrated.session?.thinking == .hide)
        #expect(migrated.session?.grouping == "auto")
        #expect(migrated.animations == false)
        #expect(migrated.mouse == false)
    }

    @Test("CLIConfig.Service migrates legacy copy_on_select, merges env overlay, and persists surgical comment-preserving updates")
    func configServiceReadWriteAndMigrate() async throws {
        let initial = """
        {
          // legacy copy_on_select should migrate to terminal.copy = "select"
          "terminal": { "copy_on_select": true },
          "keybinds": {
            "app_exit": "ctrl+q",
            "app_heap_snapshot": "ctrl+h" /* keep orphan comment */
          },
        }
        """
        let (ctx, _, fs) = CLITestFixtures.makeContext(
            env: ["OPENCODE_CLI_CONFIG_CONTENT": "{\"animations\":false}"],
            files: ["/home/tester/.config/opencode/cli.json": initial]
        )
        let service = CLIConfig.Service(context: ctx)
        let loaded = try await service.get()
        #expect(loaded.terminal?.copy == "select")
        #expect(loaded.keybinds?["app.exit"] == "ctrl+q")
        #expect(loaded.keybinds?["app_heap_snapshot"] == nil)
        #expect(loaded.animations == false)

        let afterMigrate = String(decoding: try await fs.readFile(at: service.path), as: UTF8.self)
        #expect(afterMigrate.contains("// legacy copy_on_select should migrate to terminal.copy = \"select\""))
        #expect(afterMigrate.contains("/* keep orphan comment */"))
        #expect(!afterMigrate.contains("\"copy_on_select\""))
        #expect(!afterMigrate.contains("\"app_heap_snapshot\""))
        #expect(afterMigrate.contains("\"app.exit\": \"ctrl+q\""))

        let updated = try await service.update { draft in
            draft.mouse = false
        }
        #expect(updated.mouse == false)
        let persisted = String(decoding: try await fs.readFile(at: service.path), as: UTF8.self)
        #expect(persisted.contains("// legacy copy_on_select should migrate to terminal.copy = \"select\""))
        #expect(persisted.contains("/* keep orphan comment */"))
        #expect(persisted.contains("\"mouse\": false"))

        // Creating a fresh cli.json (when none exists) includes the published `$schema`.
        let (freshCtx, _, freshFs) = CLITestFixtures.makeContext()
        let freshService = CLIConfig.Service(context: freshCtx)
        let created = try await freshService.update { draft in
            draft.animations = false
        }
        #expect(created.schema == CLIConfig.SchemaURL)
        #expect(created.animations == false)
        let createdText = String(decoding: try await freshFs.readFile(at: freshService.path), as: UTF8.self)
        #expect(createdText.contains("\"$schema\": \"\(CLIConfig.SchemaURL)\""))
        #expect(createdText.contains("\"animations\": false"))
    }

    @Test("CLICommands MCP add and Plugin add/remove preserve JSONC comments and formatting")
    func mcpAndPluginWritesPreserveComments() async throws {
        let initial = """
        // User OpenCode config
        {
          /* keep me */
          "username": "alice",
          "plugins": [
            "@acme/existing"
          ]
        }
        """ + "\n"

        // 1. Plugin add & remove on commented opencode.jsonc
        let pluginFs = InMemoryFileSystem(initialFiles: [
            "/home/tester/.config/opencode/opencode.jsonc": Array(initial.utf8),
        ])
        let cfg = "/home/tester/.config/opencode/opencode.jsonc"
        #expect(try await CLICommands.Plugin.writePluginConfig(configPath: cfg, spec: "@acme/added", fileSystem: pluginFs) == true)
        let afterAdd = String(decoding: try await pluginFs.readFile(at: cfg), as: UTF8.self)
        #expect(afterAdd.contains("// User OpenCode config"))
        #expect(afterAdd.contains("/* keep me */"))
        #expect(afterAdd.contains("\"username\": \"alice\""))
        #expect(afterAdd.contains("\"@acme/added\""))

        #expect(try await CLICommands.Plugin.removePluginConfig(configPath: cfg, spec: "@acme/added", fileSystem: pluginFs) == true)
        let afterRemove = String(decoding: try await pluginFs.readFile(at: cfg), as: UTF8.self)
        #expect(afterRemove.contains("// User OpenCode config"))
        #expect(afterRemove.contains("/* keep me */"))
        #expect(afterRemove.contains("\"@acme/existing\""))
        #expect(!afterRemove.contains("\"@acme/added\""))

        // 2. MCP add on commented opencode.jsonc
        let (mcpCtx, _, mcpFs) = CLITestFixtures.makeContext(
            files: ["/work/opencode.jsonc": initial],
            cwd: "/work"
        )
        let input = CLIFramework.Runtime.Input(
            strings: ["url": "https://mcp.linear.app/sse"],
            positionals: ["linear"],
            namedArguments: ["name": ["linear"]]
        )
        try await CLICommands.MCP.runAdd(input, context: mcpCtx)
        let afterMcp = String(decoding: try await mcpFs.readFile(at: "/work/opencode.jsonc"), as: UTF8.self)
        #expect(afterMcp.contains("// User OpenCode config"))
        #expect(afterMcp.contains("/* keep me */"))
        #expect(afterMcp.contains("\"username\": \"alice\""))
        #expect(afterMcp.contains("\"linear\""))
        #expect(afterMcp.contains("https://mcp.linear.app/sse"))
    }
}

@Suite("CLIUI Prompts, Picker & Timeline")
struct CLIUITests {
    @Test("Integration picker filters and renders category groups")
    func integrationPickerRendering() {
        let choices: [CLIUI.IntegrationChoice] = [
            CLIUI.IntegrationChoice(value: "mcp-1", label: "Linear", category: .mcp, connected: true, hint: "active"),
            CLIUI.IntegrationChoice(value: "anthropic", label: "Anthropic", category: .popular, connected: false),
        ]
        #expect(CLIUI.filterIntegrationChoices(choices, search: "lin").count == 1)
        let frame = CLIUI.renderIntegrationPickerFrame(choices: choices, cursor: 0, columns: 40, rows: 24)
        #expect(frame.contains("MCP"))
        #expect(frame.contains("Popular"))
        #expect(frame.contains("Linear ✓ (active)"))
        #expect(frame.contains("↑/↓ navigate • Enter select"))
    }

    @Test("TimelineHost writes non-TTY rows and rejects writes after close")
    func timelineHostLifecycle() async throws {
        let (ctx, output, _) = CLITestFixtures.makeContext(isStdinTTY: false, isStdoutTTY: false)
        let host = await CLIUI.createTimelineHost(context: ctx)
        try await host.intro("Starting")
        try await host.item("Step 1")
        try await host.pending("Working")
        try await host.success("Finished")
        try await host.outro("Done")
        await host.close()

        #expect(output.stdout.contains("┌ Starting\n│\n"))
        #expect(output.stdout.contains("● Step 1\n│\n"))
        #expect(output.stdout.contains(". Working\n"))
        #expect(output.stdout.contains("◇ Finished\n│\n"))
        #expect(output.stdout.contains("└ Done\n"))

        await #expect(throws: CLIError.self) {
            try await host.item("Too late")
        }
    }

    @Test("Prompt.handlePromptErrors sets exit code 130 on cancel and 1 on error")
    func promptErrorHandling() async {
        let (ctx1, out1, _) = CLITestFixtures.makeContext()
        let cancelled: String? = await CLIUI.Prompt.handlePromptErrors(context: ctx1) {
            throw CLIUI.Prompt.CancelledError()
        }
        #expect(cancelled == nil)
        #expect(ctx1.exitCode.value == 130)
        #expect(out1.stderr.contains("Cancelled"))

        let (ctx2, out2, _) = CLITestFixtures.makeContext()
        let failed: String? = await CLIUI.Prompt.handlePromptErrors(context: ctx2) {
            throw CLIError("bad input")
        }
        #expect(failed == nil)
        #expect(ctx2.exitCode.value == 1)
        #expect(out2.stderr.contains("bad input"))
    }
}

@Suite("CLIServices: ServiceConfig, Updater, WebUi, PortOwner, ServerConnection & SessionTarget")
struct CLIServicesTests {
    @Test("ServiceConfig channel filenames, ports, Windows remapping, and versionBelongsToChannel")
    func serviceConfigHelpers() {
        #expect(CLIServices.ServiceConfig.filename(channel: "latest") == "service.json")
        #expect(CLIServices.ServiceConfig.filename(channel: "local") == "service-local.json")
        #expect(CLIServices.ServiceConfig.filename(channel: "pr/123") == "service-pr-123.json")
        #expect(CLIServices.ServiceConfig.legacyFilename(channel: "latest") == nil)
        #expect(CLIServices.ServiceConfig.legacyFilename(channel: "local") == nil)
        #expect(CLIServices.ServiceConfig.legacyFilename(channel: "beta")?.hasPrefix("service-") == true)

        #expect(CLIServices.ServiceConfig.defaultPort(channel: "latest", platform: .macOS) == 0xC0DE)
        #expect(CLIServices.ServiceConfig.defaultPort(channel: "local", platform: .linux) == 0xC0DF)
        #expect(CLIServices.ServiceConfig.defaultPort(channel: "latest", platform: .windows) == 0x70DE)
        #expect(CLIServices.ServiceConfig.defaultPort(channel: "local", platform: .windows) == 0x70DF)

        #expect(CLIServices.ServiceConfig.versionBelongsToChannel("2.1.0", channel: "latest", installedVersion: "2.1.0") == true)
        #expect(CLIServices.ServiceConfig.versionBelongsToChannel("0.0.0-dev-20260401.1", channel: "dev", installedVersion: "0.0.0-dev-20260402.1") == true)
        #expect(CLIServices.ServiceConfig.versionBelongsToChannel("0.0.0-beta-1", channel: "dev", installedVersion: "2.0.0") == false)
        #expect(CLIServices.ServiceConfig.versionBelongsToChannel(nil, channel: "dev", installedVersion: "2.0.0") == false)

        let env = CLIServices.ServiceConfig.processEnv(["XDG_STATE_HOME": "/bad", "FOO": "bar"])
        #expect(env == ["FOO": "bar"])
    }

    @Test("ServiceConfig get, set, unset, password redaction, and CORS validation")
    func serviceConfigCRUD() async throws {
        let (ctx, _, _) = CLITestFixtures.makeContext()
        try await CLIServices.ServiceConfig.set(key: "port", value: "9090", context: ctx)
        try await CLIServices.ServiceConfig.set(key: "hostname", value: "0.0.0.0", context: ctx)
        try await CLIServices.ServiceConfig.set(key: "cors", value: "https://app.opencode.ai, http://localhost:3000", context: ctx)
        try await CLIServices.ServiceConfig.set(key: "env", value: "FOO", nestedValue: "bar", context: ctx)
        _ = try await CLIServices.ServiceConfig.password("top-secret-pw", context: ctx)

        #expect(try await CLIServices.ServiceConfig.get(key: "port", context: ctx) == "9090")
        #expect(try await CLIServices.ServiceConfig.get(key: "hostname", context: ctx) == "0.0.0.0")
        #expect(try await CLIServices.ServiceConfig.get(key: "env", name: "FOO", context: ctx) == "bar")
        #expect(try await CLIServices.ServiceConfig.get(key: "password", context: ctx) == "top-secret-pw")

        let all = try await CLIServices.ServiceConfig.get(context: ctx)
        #expect(!all.contains("top-secret-pw"))
        #expect(all.contains("9090"))

        try await CLIServices.ServiceConfig.unset(key: "env", name: "FOO", context: ctx)
        #expect(try await CLIServices.ServiceConfig.get(key: "env", name: "FOO", context: ctx) == "")

        await #expect(throws: CLIError.self) {
            try await CLIServices.ServiceConfig.set(key: "cors", value: "https://bad.example/path/", context: ctx)
        }
        await #expect(throws: CLIError.self) {
            try await CLIServices.ServiceConfig.set(key: "port", value: "99999", context: ctx)
        }
    }

    @Test("PortOwner parses lsof and ps output and handles wildcard listeners")
    func portOwnerDescribe() async {
        let spawner = MockCLIProcessSpawner { spec in
            if spec.executable == "lsof" {
                return ProcessOutput(exitCode: 0, stdout: Array("p1234\nn*:49374\n".utf8), stderr: [])
            }
            if spec.executable == "ps" {
                return ProcessOutput(exitCode: 0, stdout: Array("opencode serve --service\n".utf8), stderr: [])
            }
            return ProcessOutput(exitCode: 1, stdout: [], stderr: [])
        }
        let (ctx, _, _) = CLITestFixtures.makeContext(spawner: spawner)
        let owner = await CLIServices.PortOwner.describe(49374, "127.0.0.1", ctx)
        #expect(owner == "PID 1234 (opencode serve --service)")

        let (winCtx, _, _) = CLITestFixtures.makeContext(platformOS: .windows, spawner: spawner)
        #expect(await CLIServices.PortOwner.describe(49374, "127.0.0.1", winCtx) == nil)
    }

    @Test("UpdaterAction semver parsing, policy evaluation, and Updater.decodePolicy")
    func updaterSemverAndPolicy() {
        let v1 = CLIServices.UpdaterAction.parseReleaseVersion("v2.1.0-beta.1+build.42")
        #expect(v1?.core == "2.1.0")
        #expect(v1?.prerelease == ["beta", "1"])
        #expect(CLIServices.UpdaterAction.parseReleaseVersion("01.2.3") == nil)
        #expect(CLIServices.UpdaterAction.parseReleaseVersion("1.2.3-01") == nil)
        #expect(CLIServices.UpdaterAction.parseReleaseVersion("9007199254740992.0.0") == nil)

        #expect(CLIServices.UpdaterAction.action(current: "2.0.0", latest: "2.1.0", policy: .auto) == .auto)
        #expect(CLIServices.UpdaterAction.action(current: "2.0.0", latest: "2.1.0", policy: .notify) == .notify)
        #expect(CLIServices.UpdaterAction.action(current: "2.0.0", latest: "2.1.0", policy: .disable) == .none)
        #expect(CLIServices.UpdaterAction.action(current: "2.1.0", latest: "v2.1.0", policy: .auto) == .none)

        #expect(CLIServices.Updater.decodePolicy("{\"update\":\"auto\"}") == .auto)
        #expect(CLIServices.Updater.decodePolicy("// comment\n{\"autoupdate\":false,}") == .disable)
        #expect(CLIServices.Updater.decodePolicy("{\"autoupdate\":\"notify\"}") == .notify)
        #expect(CLIServices.Updater.decodePolicy("{\"autoupdate\":true}") == .auto)
    }

    @Test("WebUi.handler routes API passthrough, brotli negotiation, SPA fallback, and CSP inline script hash")
    func webUiHandler() async throws {
        let html = "<!doctype html><html><head><script id=\"oc-theme-preload-script\">window.__t=1;</script></head></html>"
        let middleware = try await CLIServices.WebUi.handler(
            options: CLIServices.WebUi.Options(
                assets: [
                    "index.html": .text(html),
                    "_assets/app.js": .text("console.log(1)"),
                ],
                brotli: [
                    "_assets/app.js": [0xAA, 0xBB, 0xCC],
                ]
            )
        )

        // API routes pass through
        let apiResp = try await middleware(CLIServices.WebUi.WebRequest(method: "GET", url: "/api/info")) { _ in
            CLIServices.WebUi.WebResponse(status: 200, body: Array("{\"ok\":true}".utf8))
        }
        #expect(apiResp.status == 200)
        #expect(String(decoding: apiResp.body, as: UTF8.self) == "{\"ok\":true}")

        // Missing _assets/ returns 404 with no-store
        let missingAsset = try await middleware(CLIServices.WebUi.WebRequest(method: "GET", url: "/_assets/missing.js")) { _ in nil }
        #expect(missingAsset.status == 404)
        #expect(missingAsset.headers["cache-control"] == "no-store")

        // Brotli accepted serves compressed bytes with content-encoding: br and vary
        let brResp = try await middleware(CLIServices.WebUi.WebRequest(method: "GET", url: "/_assets/app.js", headers: ["accept-encoding": "gzip, br"])) { _ in nil }
        #expect(brResp.status == 200)
        #expect(brResp.headers["content-encoding"] == "br")
        #expect(brResp.headers["vary"] == "accept-encoding")
        #expect(brResp.body == [0xAA, 0xBB, 0xCC])

        // Brotli q=0 falls back to uncompressed
        let plainResp = try await middleware(CLIServices.WebUi.WebRequest(method: "GET", url: "/_assets/app.js", headers: ["accept-encoding": "br;q=0, gzip"])) { _ in nil }
        #expect(plainResp.headers["content-encoding"] == nil)
        #expect(String(decoding: plainResp.body, as: UTF8.self) == "console.log(1)")

        // SPA route falls back to index.html with CSP sha256 digest of oc-theme-preload-script
        let spaResp = try await middleware(CLIServices.WebUi.WebRequest(method: "GET", url: "/sessions/abc")) { _ in nil }
        #expect(spaResp.status == 200)
        #expect(spaResp.headers["cache-control"] == "no-cache")
        #expect(spaResp.headers["content-security-policy"]?.contains("'sha256-") == true)

        // Non-GET/HEAD returns 405
        let methodResp = try await middleware(CLIServices.WebUi.WebRequest(method: "POST", url: "/sessions/abc")) { _ in nil }
        #expect(methodResp.status == 405)
    }

    @Test("ServerConnection rejects --server + --standalone and warns on version mismatch")
    func serverConnectionResolution() async throws {
        let transport = MockCLIHTTPTransport { _ in
            CLITestFixtures.jsonResponse(200, json: "{\"version\":\"1.9.0\",\"pid\":99,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}")
        }
        let (ctx, output, _) = CLITestFixtures.makeContext(env: ["OPENCODE_PASSWORD": "pw"], version: "2.1.0", transport: transport)

        await #expect(throws: CLIError.self) {
            _ = try await CLIServices.ServerConnection.resolve(
                CLIServices.ServerConnection.Args(server: "http://127.0.0.1:49374", standalone: true),
                context: ctx
            )
        }

        let resolved = try await CLIServices.ServerConnection.resolve(
            CLIServices.ServerConnection.Args(server: "http://127.0.0.1:49374"),
            context: ctx
        )
        #expect(resolved.endpoint.url == "http://127.0.0.1:49374")
        #expect(resolved.endpoint.auth?.password == "pw")
        #expect(output.stderr.contains("has version 1.9.0; this client is 2.1.0"))
    }

    @Test("ServerConnection restarts stale local background daemon when executable is newer than service-local.json")
    func serverConnectionRestartsStaleLocalBinary() async throws {
        let fixture = try CLITestFixtures.makeStaleLocalServiceFixture(oldPID: 70920, newPID: 81234)
        defer { CLITestFixtures.removeTempPath(fixture.tempRoot) }

        let resolved = try await CLIServices.ServerConnection.resolve(
            CLIServices.ServerConnection.Args(),
            context: fixture.context
        )
        #expect(fixture.signaler.signals.contains(where: { $0.0 == 70920 && $0.1 == "SIGTERM" }))
        #expect(fixture.spawnCount() == 1)
        #expect(resolved.endpoint.url == "http://127.0.0.1:49376")
    }

    @Test("ServerProcess.run outputs URL + password in default mode and JSON in stdio mode")
    func serverProcessModes() async throws {
        let starter: CLIServices.ServerProcess.Starter = { req in
            CLIServices.ServerProcess.StartedServer(
                url: "http://\(req.hostname):\(req.port == 0 ? 55123 : req.port)",
                hostname: req.hostname,
                port: req.port == 0 ? 55123 : req.port,
                waitForShutdown: {},
                shutdown: {}
            )
        }
        let (ctxDefault, outDefault, _) = CLITestFixtures.makeContext(serverStarter: starter)
        try await CLIServices.ServerProcess.run(CLIServices.ServerProcess.Options(mode: .default, hostname: "127.0.0.1", port: 4444), ctxDefault)
        #expect(outDefault.stdout.contains("server listening on http://127.0.0.1:4444"))
        #expect(outDefault.stdout.contains("server password "))

        let (ctxStdio, outStdio, _) = CLITestFixtures.makeContext(serverStarter: starter)
        try await CLIServices.ServerProcess.run(CLIServices.ServerProcess.Options(mode: .stdio, hostname: "127.0.0.1", port: 0), ctxStdio)
        #expect(outStdio.stdout.contains("{\"url\":\"http://127.0.0.1:55123\"}"))
    }

    @Test("RetainedImage.installed detects npm, winget, and curl paths")
    func retainedImageDetection() {
        #expect(CLIServices.RetainedImage.installed(home: "/Users/me", execPath: "/usr/local/bin/bun") == false)
        #expect(CLIServices.RetainedImage.installed(home: "/Users/me", execPath: "/opt/node_modules/@opencode/cli/bin/opencode.exe") == true)
        #expect(CLIServices.RetainedImage.installed(home: "C:/Users/me", execPath: "C:/Users/me/AppData/Local/Microsoft/WinGet/Packages/Anomaly.OpenCode_x64/opencode.exe") == true)
        #expect(CLIServices.RetainedImage.installed(home: "/Users/me", execPath: "/Users/me/.opencode/bin/opencode.exe") == true)
    }
}

@Suite("CLIRun, Mini & SessionTarget")
struct CLIRunAndMiniTests {
    @Test("CLIRun.mergeInput, parseRunModel, UI.error, and Mini.mergeInput")
    func runAndMiniHelpers() throws {
        #expect(CLIRun.mergeInput(message: "hello", piped: "world") == "hello\nworld")
        #expect(CLIRun.mergeInput(message: nil, piped: "piped") == "piped")
        #expect(CLIRun.mergeInput(message: "only", piped: nil) == "only")

        let parsed = try CLIRun.parseRunModel("anthropic/claude-sonnet-4#high")
        #expect(parsed == CLIRun.ParsedRunModel(providerID: "anthropic", modelID: "claude-sonnet-4", variant: "high"))

        #expect(CLIRun.Mini.mergeInput(piped: "diff", prompt: "explain") == "diff\nexplain")

        let (ctx, output, _) = CLITestFixtures.makeContext()
        CLIRun.UI.error("Error: duplicate prefix", context: ctx)
        #expect(output.stderr.contains("Error: "))
        #expect(!output.stderr.contains("Error: Error:"))

        CLIRun.reportRunError(format: .json, message: "boom", sessionID: "ses_1", context: ctx)
        #expect(ctx.exitCode.value == 1)
        #expect(output.stdout.contains("\"type\":\"error\""))
        #expect(output.stdout.contains("\"sessionID\":\"ses_1\""))
    }

    @Test("MiniHost.usingInteractiveStdin guarantees cleanup even on thrown errors")
    func interactiveStdinCleanup() async {
        let cleaned = CLIExitCode(0)
        await #expect(throws: CLIError.self) {
            let _: Int = try await CLIRun.MiniHost.usingInteractiveStdin(
                resolve: {
                    CLIRun.MiniHost.InteractiveStdin(devicePath: "/dev/tty", isTTY: true) {
                        cleaned.value = 1
                    }
                }
            ) { _ in
                throw CLIError("fail inside")
            }
        }
        #expect(cleaned.value == 1)
    }

    @Test("Mini.validateMiniTerminal fails without TTY and succeeds with TTY")
    func miniTerminalValidation() throws {
        let (nonTTY, _, _) = CLITestFixtures.makeContext(isStdoutTTY: false)
        #expect(throws: CLIError.self) {
            try CLIRun.Mini.validateMiniTerminal(context: nonTTY)
        }
        let (tty, _, _) = CLITestFixtures.makeContext(isStdoutTTY: true)
        try CLIRun.Mini.validateMiniTerminal(context: tty)
    }
}

@Suite("CLICommands & CLIEntrypoint End-to-End")
struct CLICommandsAndEntrypointTests {
    @Test("CLICommands.API rawRequest and resolveOperation interpolate path and query params")
    func apiOperationResolution() throws {
        #expect(CLICommands.API.rawRequest(["get", "/api/info"]) == CLICommands.API.ResolvedRequest(method: "GET", path: "/api/info"))
        #expect(CLICommands.API.rawRequest(["invalid", "/api/info"]) == nil)
        #expect(CLICommands.API.rawRequest(["get", "relative"]) == nil)

        let spec = CLICommands.API.OpenAPIDocument(paths: [
            "/api/session/{sessionID}/message": [
                "get": CLICommands.API.OpenAPIOperation(operationId: "message.list"),
            ],
        ])
        let resolved = try CLICommands.API.resolveOperation(
            spec: spec,
            operationID: "message.list",
            params: ["sessionID": "ses/123", "limit": "20", "order": "desc"]
        )
        #expect(resolved.method == "GET")
        #expect(resolved.path == "/api/session/ses%2F123/message?limit=20&order=desc")

        #expect(throws: CLIError.self) {
            _ = try CLICommands.API.resolveOperation(spec: spec, operationID: "missing.op")
        }
        #expect(throws: CLIError.self) {
            _ = try CLICommands.API.resolveOperation(spec: spec, operationID: "message.list", params: [:])
        }
    }

    @Test("CLICommands.Debug.redactConfig masks secrets, headers, and credentialed URLs")
    func debugConfigRedaction() {
        let input: JSONValue = .object([
            "apiKey": .string("sk-live-12345"),
            "safe": .string("hello"),
            "endpoint": .string("https://user:pass@example.com/v1"),
            "tokenUrl": .string("https://example.com/hook?api_key=abc"),
            "publicUrl": .string("https://api.openai.com/v1"),
            "headers": .object([
                "X-Custom": .string("must-be-masked"),
            ]),
        ])
        let redacted = CLICommands.Debug.redactConfig(input)
        guard case .object(let dict) = redacted else {
            Issue.record("Expected object")
            return
        }
        #expect(dict["apiKey"] == .string("***"))
        #expect(dict["safe"] == .string("hello"))
        #expect(dict["endpoint"] == .string("***"))
        #expect(dict["tokenUrl"] == .string("***"))
        #expect(dict["publicUrl"] == .string("https://api.openai.com/v1"))
        if case .object(let hdrs) = dict["headers"] {
            #expect(hdrs["X-Custom"] == .string("***"))
        } else {
            Issue.record("Expected headers object")
        }
    }

    @Test("CLICommands.Auth helpers resolve integrations, methods, choices, and form answers")
    func authHelpers() async throws {
        let integrations = CLITestFixtures.sampleIntegrations()
        #expect(try CLICommands.Auth.resolveIntegration(integrations, target: "openai").name == "OpenAI")
        #expect(try CLICommands.Auth.resolveIntegration(integrations, target: "OpenAI/").id.rawValue == "openai")

        let openai = try CLICommands.Auth.resolveIntegration(integrations, target: "openai")
        let methods = CLICommands.Auth.connectMethods(openai)
        #expect(methods.count == 2)
        #expect(methods[0].isKey == false) // OAuth sorted before API key
        #expect(methods[1].isKey == true)
        #expect(try CLICommands.Auth.resolveMethod(methods, target: "key").isKey == true)
        #expect(try CLICommands.Auth.resolveMethod(methods, target: "chatgpt").methodID == "chatgpt")

        let choices = CLICommands.Auth.loginChoices(integrations)
        #expect(choices.first?.category == .mcp)
        #expect(choices.first?.value == "mcp-linear")
        #expect(choices[1].value == "opencode-go")
        #expect(choices[1].category == .popular)

        // Form answers with conditional `when`
        let fields = try #require(FormSchema.Fields([
            .string(FormSchema.StringField(key: "region", required: true)),
            .boolean(FormSchema.BooleanField(key: "enterprise", defaultValue: false)),
            .string(FormSchema.StringField(
                key: "domain",
                when: [FormSchema.When(key: "enterprise", op: .eq, value: .bool(true))]
            )),
        ]))
        let answers = try await CLICommands.Auth.answerForm(fields, input: ["region=us-east-1", "enterprise=true", "domain=corp.local"])
        #expect(answers?["region"] == .string("us-east-1"))
        #expect(answers?["enterprise"] == .bool(true))
        #expect(answers?["domain"] == .string("corp.local"))
    }

    @Test("CLICommands.MCP resolveConfigPath, mcpAuthChoices, and add command")
    func mcpCommandsAndHelpers() async throws {
        let (ctx, output, fs) = CLITestFixtures.makeContext(files: [
            "/workspace/project/.opencode/opencode.jsonc": "{}",
        ])
        let resolved = await CLICommands.MCP.resolveConfigPath("/workspace/project", fileSystem: fs)
        #expect(resolved == "/workspace/project/.opencode/opencode.jsonc")

        let exitCode = await CLIEntrypoint.run(
            arguments: ["mcp", "add", "linear", "--url", "https://mcp.linear.app/sse", "--header", "Authorization=Bearer tok"],
            context: ctx
        )
        #expect(exitCode == 0)
        #expect(output.stdout.contains("MCP server \"linear\" added"))
        let saved = String(decoding: try await fs.readFile(at: resolved), as: UTF8.self)
        #expect(saved.contains("https://mcp.linear.app/sse"))

        let integrations = CLITestFixtures.sampleIntegrations()
        let servers = [
            McpSchema.Server(name: "linear", status: .needsAuth(error: "expired"), integrationID: IntegrationID(rawValue: "mcp-linear")),
        ]
        let authChoices = CLICommands.MCP.mcpAuthChoices(servers: servers, integrations: integrations)
        #expect(authChoices.count == 1)
        #expect(authChoices[0].label == "linear")
        #expect(authChoices[0].hint == "needs authentication")
    }

    @Test("CLICommands.Plugin target classification, config read/write/remove, and formatting")
    func pluginHelpers() async throws {
        #expect(CLICommands.Plugin.configurationTarget(PluginContract.Host.Entrypoints(server: "/s.js", tui: "/t.js")) == .server)
        #expect(CLICommands.Plugin.configurationTarget(PluginContract.Host.Entrypoints(tui: "/t.js")) == .tui)
        #expect(CLICommands.Plugin.configurationTarget(PluginContract.Host.Entrypoints()) == nil)

        #expect(CLICommands.Plugin.Inventory.displayVersion("0123456789abcdef0123456789abcdef01234567") == "0123456")
        #expect(CLICommands.Plugin.Inventory.displayVersion("1.2.3") == "1.2.3")

        let fs = InMemoryFileSystem()
        let cfg = "/home/tester/.config/opencode/opencode.json"
        #expect(try await CLICommands.Plugin.writePluginConfig(configPath: cfg, spec: "@acme/plugin", fileSystem: fs) == true)
        #expect(try await CLICommands.Plugin.writePluginConfig(configPath: cfg, spec: "@acme/plugin", fileSystem: fs) == false)
        #expect(try await CLICommands.Plugin.removePluginConfig(configPath: cfg, spec: "@acme/plugin", fileSystem: fs) == true)
        #expect(try await CLICommands.Plugin.removePluginConfig(configPath: cfg, spec: "@acme/plugin", fileSystem: fs) == false)

        let invText = CLICommands.Plugin.Inventory.format([
            CLICommands.Plugin.Inventory.Item(runtime: .server, target: "@acme/a", name: "a", version: "1.0.0", outdated: true),
            CLICommands.Plugin.Inventory.Item(runtime: .tui, target: "@acme/b", name: "b", version: "2.0.0", outdated: false),
        ])
        #expect(invText.contains("Server"))
        #expect(invText.contains("a 1.0.0 (update available)"))
        #expect(invText.contains("TUI"))
        #expect(invText.contains("b 2.0.0 (current)"))

        let listText = CLICommands.Plugin.format(
            plugins: [
                PluginSchema.Info(
                    id: PluginSchema.ID(rawValue: "acme"),
                    source: .package(target: "@acme/a", version: "1.0.0"),
                    features: PluginSchema.Features(server: true),
                    state: .active
                ),
            ],
            tui: [CLICommands.Plugin.TUIPluginSummary(target: "@acme/tui-only", version: "0.5.0")]
        )
        #expect(listText.contains("ID"))
        #expect(listText.contains("acme"))
        #expect(listText.contains("@acme/tui-only"))
    }

    @Test("CLICommands.Pair.remoteConsent enforces non-interactive --yes and remembers acceptance")
    func pairRemoteConsent() async throws {
        let (ctx1, out1, _) = CLITestFixtures.makeContext(isStdinTTY: false, isStdoutTTY: false)
        let denied = try await CLICommands.Pair.remoteConsent(
            config: CLIServices.ServiceConfig.Info(),
            yes: false,
            terminal: MockConsentPrompt(isInteractive: false, confirmAnswer: nil),
            context: ctx1
        )
        #expect(denied == false)
        #expect(ctx1.exitCode.value == 1)
        #expect(out1.stderr.contains("pass --yes to continue"))

        let (ctx2, _, _) = CLITestFixtures.makeContext()
        let accepted = try await CLICommands.Pair.remoteConsent(
            config: CLIServices.ServiceConfig.Info(),
            yes: true,
            terminal: MockConsentPrompt(isInteractive: false, confirmAnswer: nil),
            context: ctx2
        )
        #expect(accepted == true)
        let saved = try await CLIServices.ServiceConfig.read(context: ctx2)
        #expect(saved.remoteAccepted == true)
    }

    @Test("CLICommands.Stats.renderStats renders empty range, summary, cost, models, and tools")
    func statsRendering() {
        let emptyOutput = CLICommands.Stats.renderStats(
            CLITestFixtures.sampleStats(empty: true),
            options: CLICommands.Stats.RenderOptions(label: "today", scope: "all projects")
        )
        #expect(emptyOutput.contains("opencode stats"))
        #expect(emptyOutput.contains("no activity in this range"))

        let fullOutput = CLICommands.Stats.renderStats(
            CLITestFixtures.sampleStats(empty: false),
            options: CLICommands.Stats.RenderOptions(
                label: "2025",
                scope: "all projects",
                models: true,
                tools: true,
                cost: true,
                width: 80
            )
        )
        #expect(fullOutput.contains("COST & TOKENS"))
        #expect(fullOutput.contains("$1.45"))
        #expect(fullOutput.contains("MODELS"))
        #expect(fullOutput.contains("anthropic/claude-sonnet-4#high"))
        #expect(fullOutput.contains("TOOL RELIABILITY"))
        #expect(fullOutput.contains("bash"))
    }

    @Test("CLIEntrypoint runs --version, --help, debug paths, service config, models, reload, and acp")
    func entrypointEndToEnd() async {
        // --version
        let (vCtx, vOut, _) = CLITestFixtures.makeContext(version: "2.4.0")
        #expect(await CLIEntrypoint.run(arguments: ["--version"], context: vCtx) == 0)
        #expect(vOut.stdout == "2.4.0\n")

        // --help
        let (hCtx, hOut, _) = CLITestFixtures.makeContext()
        #expect(await CLIEntrypoint.run(arguments: ["--help"], context: hCtx) == 0)
        #expect(hOut.stdout.contains("USAGE"))
        #expect(hOut.stdout.contains("serve"))
        #expect(hOut.stdout.contains("session"))

        // debug paths db
        let (pCtx, pOut, _) = CLITestFixtures.makeContext(channel: "local")
        #expect(await CLIEntrypoint.run(arguments: ["debug", "paths", "db"], context: pCtx) == 0)
        #expect(pOut.stdout == "/home/tester/.local/share/opencode/opencode-local.db\n")

        // service set / get / status
        let (sCtx, sOut, _) = CLITestFixtures.makeContext()
        #expect(await CLIEntrypoint.run(arguments: ["service", "set", "port", "41234"], context: sCtx) == 0)
        #expect(await CLIEntrypoint.run(arguments: ["service", "get", "port"], context: sCtx) == 0)
        #expect(sOut.stdout == "41234\n")
        sOut.reset()
        #expect(await CLIEntrypoint.run(arguments: ["service", "status"], context: sCtx) == 0)
        #expect(sOut.stdout == "stopped\n")

        // models, reload, api, session list/delete against mocked server
        let modelsPayload = CLITestFixtures.sampleModelsEnvelopeJSON()
        let sessionItemJSON = CLITestFixtures.sampleSessionInfoJSON()
        let transport = MockCLIHTTPTransport { req in
            if req.url.contains("/api/info") {
                return CLITestFixtures.jsonResponse(200, json: "{\"version\":\"2.1.0\",\"pid\":1,\"urls\":[\"http://127.0.0.1:49374\"],\"paths\":{\"tmp\":\"/tmp\"}}")
            }
            if req.url.contains("/api/plugin") {
                return CLITestFixtures.jsonResponse(200, json: "{\"location\":{\"directory\":\"/workspace/project\"},\"data\":[{\"id\":\"p1\",\"source\":{\"type\":\"builtin\"},\"features\":{\"server\":true},\"state\":{\"status\":\"active\"}}]}")
            }
            if req.url.contains("/api/model") {
                return CLITestFixtures.jsonResponse(200, json: modelsPayload)
            }
            if req.url.contains("/api/location/reload") {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/location") {
                return CLITestFixtures.jsonResponse(200, json: "{\"directory\":\"/workspace/project\",\"project\":{\"id\":\"prj_test0001\",\"directory\":\"/workspace/project\",\"canonical\":\"/workspace/project\"}}")
            }
            if req.url.contains("/api/session/ses_test0001") && req.method == "DELETE" {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }
            if req.url.contains("/api/session") && req.method == "GET" {
                return CLITestFixtures.jsonResponse(200, json: "{\"data\":[\(sessionItemJSON)],\"cursor\":{\"next\":null,\"prev\":null}}")
            }
            return CLITestFixtures.jsonResponse(404, json: "{}")
        }
        let (mCtx, mOut, _) = CLITestFixtures.makeContext(transport: transport)
        #expect(await CLIEntrypoint.run(arguments: ["models", "--server", "http://127.0.0.1:49374"], context: mCtx) == 0)
        #expect(mOut.stdout == "anthropic/claude-sonnet-4\nopenai/gpt-5\n")

        mOut.reset()
        #expect(await CLIEntrypoint.run(arguments: ["reload", "--server", "http://127.0.0.1:49374"], context: mCtx) == 0)
        #expect(mOut.stdout == "Configuration reloaded\n")

        mOut.reset()
        #expect(await CLIEntrypoint.run(arguments: ["session", "list", "--format", "json", "--server", "http://127.0.0.1:49374"], context: mCtx) == 0)
        #expect(mOut.stdout.contains("ses_test0001"))
        #expect(mOut.stdout.contains("Demo session"))

        mOut.reset()
        #expect(await CLIEntrypoint.run(arguments: ["session", "delete", "ses_test0001", "--server", "http://127.0.0.1:49374"], context: mCtx) == 0)
        #expect(mOut.stdout == "Session ses_test0001 deleted\n")

        mOut.reset()
        #expect(await CLIEntrypoint.run(arguments: ["api", "GET", "/api/info", "--server", "http://127.0.0.1:49374"], context: mCtx) == 0)
        #expect(mOut.stdout.contains("\"version\":\"2.1.0\""))

        // acp delegates cleanly to injected acpRunner hook
        let (aCtx, _, _) = CLITestFixtures.makeContext(acpRunner: { _, _ in 0 })
        #expect(await CLIEntrypoint.run(arguments: ["acp"], context: aCtx) == 0)

        // serve --service --stdio fails cleanly
        let (badServeCtx, badServeOut, _) = CLITestFixtures.makeContext()
        #expect(await CLIEntrypoint.run(arguments: ["serve", "--service", "--stdio"], context: badServeCtx) == 1)
        #expect(badServeOut.stderr.contains("--service and --stdio cannot be combined"))

        // NO_PROXY merging deduplicates loopback hosts
        let noProxy = CLIEntrypoint.mergedNoProxy(upper: "corp.internal,localhost", lower: "127.0.0.1,other.local")
        #expect(noProxy == "corp.internal,localhost,127.0.0.1,other.local,::1")
    }
}
