import Synchronization
import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer

/// Server-level end-to-end tests for live `ConfigWatch` (`core/src/config.ts` / `config/watch.ts`),
/// `LocationWatcher` (`core/src/filesystem/location-watcher.ts`), `ConfigLocationWatcherPlugin`,
/// `Vcs` branch updates (`core/src/vcs.ts`), automatic `Instruction.Loader` reconfiguration on
/// `config.updated`, and Location-scoped cleanup on close.
@Suite("Server ConfigWatch and LocationWatcher live parity")
struct ServerConfigVcsWatchTests {
    static let globalConfig = "/tmp/opencode-live-test/config/opencode.json"

    static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let items): return items.flatMap { strings($0) }
        case .object(let object): return object.keys.sorted().flatMap { strings(object[$0]) }
        default: return []
        }
    }

    static func systemUpdates(from request: HTTPRequest) throws -> [String] {
        let json = try LiveExecutionFixture.decodeJSON(request.body ?? [])
        return strings(json["messages"]).filter { $0.contains("<system-update>") }
    }

    @Test("editing project and global config emits a single config.updated with new values; a no-op write emits nothing")
    func projectAndGlobalConfigEditsCoalesceAndSuppressNoOp() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let projectConfig = "\(projectDir)/opencode.json"
        let projectJsonc = "\(projectDir)/opencode.jsonc"

        let harness = try await LiveExecutionFixture.makeHarness(
            initialFiles: [
                Self.globalConfig: LiveExecutionFixture.bytes("""
                {
                  "username": "global-v1",
                  "shell": "/bin/sh"
                }
                """),
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectConfig: LiveExecutionFixture.bytes("""
                {
                  "username": "project-v1"
                }
                """),
            ],
            rootDir: projectDir,
            homeDir: homeDir,
            project: true,
            configDebounce: .milliseconds(250),
            instructionDebounce: .milliseconds(30)
        )
        defer { Task { await harness.close() } }

        let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: projectDir))
        let bundle = try await harness.runtime.resolveLocation(ref)
        let route = OpenCodeLocation(directory: projectDir)

        // Deterministically flush the initial readiness rescan before starting burst edits.
        if let service = bundle.config as? CoreConfig.Service {
            await service.reload()
        }

        let initialEntries = await bundle.config.entries()
        #expect(CoreConfig.latest(initialEntries, \.username) == "project-v1")
        #expect(CoreConfig.latest(initialEntries, \.shell) == "/bin/sh")

        // Burst-edit BOTH global and project config -> 250ms debounce collapses them into a single `config.updated`.
        let updates = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 3_000,
            settleMs: 400
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "username": "global-v2",
                  "shell": "/bin/zsh"
                }
                """),
                to: Self.globalConfig,
                createDirectories: true
            )
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "username": "project-v2"
                }
                """),
                to: projectConfig,
                createDirectories: true
            )
        }
        #expect(updates.count == 1)

        let updatedEntries = await bundle.config.entries()
        #expect(CoreConfig.latest(updatedEntries, \.username) == "project-v2")
        #expect(CoreConfig.latest(updatedEntries, \.shell) == "/bin/zsh")

        // Rewriting the exact same project config (semantic no-op) emits ZERO `config.updated` events.
        let noOpSameBytes = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 400,
            settleMs: 120
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "username": "project-v2"
                }
                """),
                to: projectConfig,
                createDirectories: false
            )
        }
        #expect(noOpSameBytes.isEmpty)

        // Adding a JSONC file with a real value emits once, then a comment-only rewrite emits nothing.
        let addedJsonc = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 3_000,
            settleMs: 350
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  // initial comment
                  "username": "jsonc-v1"
                }
                """),
                to: projectJsonc,
                createDirectories: false
            )
        }
        #expect(addedJsonc.count == 1)
        #expect(CoreConfig.latest(await bundle.config.entries(), \.username) == "jsonc-v1")

        let commentOnly = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 400,
            settleMs: 120
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  // updated comment with identical effective config
                  "username": "jsonc-v1"
                }
                """),
                to: projectJsonc,
                createDirectories: false
            )
        }
        #expect(commentOnly.isEmpty)
    }

    @Test("a config change that adds instructions reconfigures Instruction.Loader and produces <system-update> on the next step")
    func configChangeAddingInstructionsProducesSystemUpdate() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let projectConfig = "\(projectDir)/opencode.json"
        let extraRule = "\(projectDir)/guides/style.md"

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectConfig: LiveExecutionFixture.bytes("{}\n"),
                extraRule: LiveExecutionFixture.bytes("Always write concise Swift doc comments."),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Step 1 done."]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Step 2 done."]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Step 3 done."]),
            ],
            rootDir: projectDir,
            homeDir: homeDir,
            project: true,
            claude: true,
            configDebounce: .milliseconds(40),
            instructionDebounce: .milliseconds(40)
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Config instruction update"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "First"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(harness.mockTransport.recordedRequests.first).body ?? [])
        let firstSystem = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(!firstSystem.contains("Always write concise Swift doc comments."))
        #expect(try Self.systemUpdates(from: harness.mockTransport.recordedRequests[0]).isEmpty)

        // Edit project opencode.json to add `instructions: ["guides/*.md"]`.
        // ConfigWatch reloads -> emits `config.updated` -> Instruction.Loader automatically reconfigures
        // and emits `instruction-discovery.updated`.
        let instructionUpdated = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir),
            timeoutMs: 3_000
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "instructions": ["guides/*.md"]
                }
                """),
                to: projectConfig,
                createDirectories: false
            )
        }
        #expect(instructionUpdated)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Second"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let step2Updates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[1])
        #expect(step2Updates.count == 1)
        #expect(step2Updates[0].contains(extraRule))
        #expect(step2Updates[0].contains("Always write concise Swift doc comments."))

        // Subsequent edits to the newly added instruction file are also watched automatically.
        let editedRule = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir),
            timeoutMs: 3_000
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Updated Swift style rule v2."),
                to: extraRule,
                createDirectories: false
            )
        }
        #expect(editedRule)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Third"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let step3Updates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[2])
        #expect(step3Updates.count == 2)
        #expect(step3Updates.last?.contains("Updated Swift style rule v2.") == true)
    }

    @Test("switching git branches emits vcs.branch.updated and updates GET /api/vcs; watcher.ignore stops watching")
    func switchingGitBranchesUpdatesVcsAndHonorsIgnore() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let headFile = "\(projectDir)/.git/HEAD"
        let projectConfig = "\(projectDir)/opencode.json"

        let harness = try await LiveExecutionFixture.makeHarness(
            initialFiles: [
                headFile: LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectConfig: LiveExecutionFixture.bytes("{}\n"),
            ],
            rootDir: projectDir,
            homeDir: homeDir,
            project: true,
            configDebounce: .milliseconds(40),
            instructionDebounce: .milliseconds(30)
        )
        defer { Task { await harness.close() } }

        let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: projectDir))
        let bundle = try await harness.runtime.resolveLocation(ref)
        let locWatcher = try #require(bundle.locationWatcher)
        await locWatcher.awaitReady()
        #expect(locWatcher.activePath == headFile)

        let initialVcs = try await harness.client.vcs.get()
        #expect(initialVcs.data.provider == "git")
        #expect(initialVcs.data.branch.current == "main")

        // Switch branch by rewriting `.git/HEAD` -> emits `vcs.branch.updated` and updates `/api/vcs`.
        let route = OpenCodeLocation(directory: projectDir)
        let switched = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 3_000
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("ref: refs/heads/feat/live-branch\n"),
                to: headFile,
                createDirectories: false
            )
        }
        #expect(switched == VcsEventSchema.BranchUpdatedData(branch: "feat/live-branch"))

        let afterSwitch = try await harness.client.vcs.get()
        #expect(afterSwitch.data.branch.current == "feat/live-branch")

        // Rewriting `.git/HEAD` with the same branch emits NO `vcs.branch.updated`.
        let unchanged = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 180
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("ref: refs/heads/feat/live-branch\n"),
                to: headFile,
                createDirectories: false
            )
        }
        #expect(unchanged == nil)

        // Detaching HEAD emits `vcs.branch.updated` with `branch: nil` and `/api/vcs` clears `branch.current`.
        let detached = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 3_000
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("0123456789abcdef0123456789abcdef01234567\n"),
                to: headFile,
                createDirectories: false
            )
        }
        #expect(detached == VcsEventSchema.BranchUpdatedData(branch: nil))
        let afterDetach = try await harness.client.vcs.get()
        #expect(afterDetach.data.branch.current == nil)

        // Adding `watcher.ignore: [".git"]` via live config reload stops the `.git/HEAD` watch.
        let ignoredUpdate = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 3_000,
            settleMs: 120
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "watcher": { "ignore": [".git"] }
                }
                """),
                to: projectConfig,
                createDirectories: false
            )
        }
        #expect(ignoredUpdate.count == 1)
        for _ in 0..<40 where locWatcher.activePath != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(locWatcher.activePath == nil)

        let suppressed = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 180
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("ref: refs/heads/ignored-branch\n"),
                to: headFile,
                createDirectories: false
            )
        }
        #expect(suppressed == nil)
    }

    @Test("config, instruction, and LocationWatcher watches stop cleanly on Location close")
    func allLocationWatchesStopOnClose() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let projectConfig = "\(projectDir)/opencode.json"
        let headFile = "\(projectDir)/.git/HEAD"
        let watcherTest = CoreFilesystem.Watcher.Test()

        let harness = try await LiveExecutionFixture.makeHarness(
            initialFiles: [
                Self.globalConfig: LiveExecutionFixture.bytes("{\"username\":\"init\"}\n"),
                headFile: LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectConfig: LiveExecutionFixture.bytes("{\"instructions\":[\"rules/*.md\"]}\n"),
                "\(projectDir)/rules/a.md": LiveExecutionFixture.bytes("Rule A"),
            ],
            rootDir: projectDir,
            homeDir: homeDir,
            project: true,
            claude: true,
            customWatcher: watcherTest,
            configDebounce: .milliseconds(30),
            instructionDebounce: .milliseconds(30)
        )
        defer { Task { await harness.close() } }

        let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: projectDir))
        let bundle = try await harness.runtime.resolveLocation(ref)
        let loader = try #require(bundle.instructionLoader)
        let locWatcher = try #require(bundle.locationWatcher)
        await loader.awaitReady()
        await locWatcher.awaitReady()

        let recorded = await watcherTest.subscriptions()
        #expect(watcherTest.activeSubscriptionCount() > 0)
        #expect(recorded.contains(.file(path: headFile)))
        #expect(recorded.contains(where: { input in
            if case .entries(let path, let names) = input {
                return path == projectDir && names.contains("opencode.json")
            }
            return false
        }))

        // Close the Location and verify EVERY watch subscription releases cleanly.
        await harness.runtime.locations.invalidate(ref)
        for _ in 0..<50 where watcherTest.activeSubscriptionCount() > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(watcherTest.activeSubscriptionCount() == 0)

        // Post-close writes + synthetic watcher emissions must produce zero config or VCS bus events.
        let route = OpenCodeLocation(directory: projectDir)
        let postConfig = try await LiveExecutionFixture.triggerAndCollectConfigUpdates(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 150,
            settleMs: 50
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("{\"username\":\"after-close\"}\n"),
                to: projectConfig,
                createDirectories: false
            )
            await watcherTest.emit(CoreFilesystem.Watcher.Update(path: projectConfig, type: .update))
        }
        #expect(postConfig.isEmpty)

        let postBranch = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: harness.runtime.bus,
            location: route,
            timeoutMs: 150
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("ref: refs/heads/after-close\n"),
                to: headFile,
                createDirectories: false
            )
            await watcherTest.emit(CoreFilesystem.Watcher.Update(path: headFile, type: .update))
        }
        #expect(postBranch == nil)
    }

    @Test("end-to-end real disk NativeFileWatcher handles live config edit -> <system-update> and real git branch switch -> /api/vcs")
    func realDiskConfigAndVcsWatchEndToEnd() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let disk = try await LiveExecutionFixture.makeRealDiskGitConfigHarness(
            branchName: "main",
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["First disk reply."]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Second disk reply."]),
            ],
            configDebounce: .milliseconds(50),
            instructionDebounce: .milliseconds(50)
        )
        defer { Task { await disk.cleanup() } }

        let projectConfig = "\(disk.projectDir)/opencode.json"
        let diskRule = "\(disk.projectDir)/rules/live.md"
        try await LocalFileSystem.shared.writeFile(
            LiveExecutionFixture.bytes("{}\n"),
            to: projectConfig,
            createDirectories: true
        )
        try await LocalFileSystem.shared.writeFile(
            LiveExecutionFixture.bytes("Disk dynamic instruction rule from config reload."),
            to: diskRule,
            createDirectories: true
        )

        let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: disk.locationDir))
        let bundle = try await disk.harness.runtime.resolveLocation(ref)
        let locWatcher = try #require(bundle.locationWatcher)
        await locWatcher.awaitReady()

        // 1. Verify real git branch detection via `/api/vcs`.
        let initialVcs = try await disk.harness.client.vcs.get()
        #expect(initialVcs.data.provider == "git")
        #expect(initialVcs.data.branch.current == "main")

        // 2. Step 1 prompt: `rules/live.md` is not configured yet.
        let created = try await disk.harness.client.session.create(SessionCreateInput(title: "Real disk config+vcs"))
        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 1"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)
        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(disk.harness.mockTransport.recordedRequests.first).body ?? [])
        #expect(!Self.strings(firstJSON["system"]).joined(separator: "\n").contains("Disk dynamic instruction rule"))

        // 3. Edit project `opencode.json` on real disk to add `"instructions": ["rules/*.md"]`.
        let route = OpenCodeLocation(directory: disk.locationDir)
        let instrUpdated = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: disk.harness.runtime.bus,
            location: route,
            timeoutMs: 4_000
        ) {
            try await LocalFileSystem.shared.writeFile(
                LiveExecutionFixture.bytes("""
                {
                  "instructions": ["rules/*.md"]
                }
                """),
                to: projectConfig,
                createDirectories: false
            )
        }
        #expect(instrUpdated)

        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 2"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)
        let step2Updates = try Self.systemUpdates(from: disk.harness.mockTransport.recordedRequests[1])
        #expect(step2Updates.count == 1)
        #expect(step2Updates[0].contains("Disk dynamic instruction rule from config reload."))

        // 4. Switch real git branch with `git checkout -b feat/disk-switch` -> emits `vcs.branch.updated` and updates `/api/vcs`.
        let branchEvent = try await LiveExecutionFixture.triggerAndWaitForBranchUpdate(
            bus: disk.harness.runtime.bus,
            location: route,
            timeoutMs: 4_000
        ) {
            try await LiveExecutionFixture.runGit(in: disk.projectDir, args: ["checkout", "-b", "feat/disk-switch"])
        }
        #expect(branchEvent == VcsEventSchema.BranchUpdatedData(branch: "feat/disk-switch"))

        let afterBranch = try await disk.harness.client.vcs.get()
        #expect(afterBranch.data.branch.current == "feat/disk-switch")
        #endif
    }
}
