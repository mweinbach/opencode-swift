import Synchronization
import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer

/// Server-level coverage for `core/src/session/context.ts#node`, `core/src/config/plugin/instruction.ts#Plugin`,
/// and `core/src/filesystem/file-watch.ts#node`: watcher-driven instruction discovery, debounced `<system-update>`
/// delivery with zero per-step rescans, URL fetch timeout, Location lifecycle teardown, and live `FileWatch`.
@Suite("Server session instruction baseline")
struct ServerSessionInstructionsTests {
    static let globalAgents = "/tmp/opencode-live-test/config/AGENTS.md"

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

    @Test("skills, discovered AGENTS.md and the Code Mode catalog reach the first request; an edit arrives as a <system-update>")
    func instructionsReachModel() async throws {
        let skill = """
        ---
        name: Tidy
        description: Tidies Swift sources before review
        ---
        Run swift format.
        """
        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Global rule v1: answer tersely."),
                "/tmp/opencode-live-test/config/skills/tidy/SKILL.md": LiveExecutionFixture.bytes(skill),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["First answer."]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Second answer."]),
            ]
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Instruction baseline"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Hello"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let first = try #require(harness.mockTransport.recordedRequests.first)
        let firstJSON = try LiveExecutionFixture.decodeJSON(first.body ?? [])
        let system = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(system.contains("Instructions from: \(Self.globalAgents)\nGlobal rule v1: answer tersely."))
        #expect(system.contains("<available_skills>"))
        #expect(system.contains("Tidies Swift sources before review"))
        #expect(system.contains("## Code Mode tools (call only inside `execute`)"))
        #expect(!Self.strings(firstJSON["messages"]).contains { $0.contains("<system-update>") })

        // Upstream's prompt-cache order: catalog and skills, then project instructions, then date and environment.
        let anchors = ["# Code Mode", "<available_skills>", "Instructions from:", "Today's date:", "<env>"]
        let positions = anchors.compactMap { system.range(of: $0)?.lowerBound }
        #expect(positions.count == anchors.count)
        #expect(positions == positions.sorted())

        // Editing AGENTS.md mid-session triggers watcher invalidation and reaches the next step as an update.
        let updated = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: harness.rootDir)
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Global rule v2: answer in full sentences."),
                to: Self.globalAgents,
                createDirectories: true
            )
        }
        #expect(updated)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Again"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let requests = harness.mockTransport.recordedRequests
        #expect(requests.count == 2)
        let second = try #require(requests.last)
        let secondJSON = try LiveExecutionFixture.decodeJSON(second.body ?? [])
        let secondSystem = Self.strings(secondJSON["system"]).joined(separator: "\n\n")
        #expect(secondSystem.contains("Global rule v1: answer tersely."))
        #expect(!secondSystem.contains("Global rule v2"))
        let updates = Self.strings(secondJSON["messages"]).filter { $0.contains("<system-update>") }
        #expect(updates.count == 1)
        #expect(updates.first?.contains(Self.globalAgents) == true)
        #expect(updates.first?.contains("Global rule v2: answer in full sentences.") == true)
    }

    @Test("editing global and project AGENTS.md produces exactly one <system-update> with no per-step rescan")
    func globalAndProjectEditsProduceSingleUpdateWithoutRescan() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let locationDir = "\(projectDir)/packages/core"
        let projectAgents = "\(projectDir)/AGENTS.md"

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Global v1"),
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectAgents: LiveExecutionFixture.bytes("Project v1"),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["One"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Two"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Three"]),
            ],
            rootDir: locationDir,
            homeDir: homeDir,
            project: true,
            claude: true
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Global + project"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 1"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let bundle = try await harness.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: locationDir))
        )
        let loader = try #require(bundle.instructionLoader)
        let countAfterStep1 = await loader.rescanCount
        #expect(countAfterStep1 == 1)

        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(harness.mockTransport.recordedRequests.first).body ?? [])
        let firstSystem = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(firstSystem.contains("Instructions from: \(Self.globalAgents)\nGlobal v1"))
        #expect(firstSystem.contains("Instructions from: \(projectAgents)\nProject v1"))

        // Step 2 with no edits must NOT trigger a rescan or emit any <system-update>.
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 2"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)
        #expect(await loader.rescanCount == countAfterStep1)
        let step2Updates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[1])
        #expect(step2Updates.isEmpty)

        // Burst-edit both global and project AGENTS.md -> 100ms debounce collapses them into one reload
        // and the next step receives exactly one <system-update> containing both edits, with no rescan on prompt.
        let updated = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: locationDir)
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Global v2"),
                to: Self.globalAgents,
                createDirectories: true
            )
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Project v2"),
                to: projectAgents,
                createDirectories: true
            )
        }
        #expect(updated)
        let countAfterWatch = await loader.rescanCount
        #expect(countAfterWatch == countAfterStep1 + 1)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 3"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        // Step 3 must not have triggered an extra rescan.
        #expect(await loader.rescanCount == countAfterWatch)
        let step3Updates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[2])
        #expect(step3Updates.count == 1)
        #expect(step3Updates[0].contains(Self.globalAgents))
        #expect(step3Updates[0].contains("Global v2"))
        #expect(step3Updates[0].contains(projectAgents))
        #expect(step3Updates[0].contains("Project v2"))
    }

    @Test("deleting an instruction file produces a removal update")
    func deletingFileProducesRemoval() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let projectAgents = "\(projectDir)/AGENTS.md"

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Global rule"),
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectAgents: LiveExecutionFixture.bytes("Project rule"),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["One"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Two"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Three"]),
            ],
            rootDir: projectDir,
            homeDir: homeDir,
            project: true,
            claude: true
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Removal test"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Start"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        // Delete project AGENTS.md -> partial removal update.
        let removedProject = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir)
        ) {
            try await harness.fileSystem.remove(at: projectAgents)
        }
        #expect(removedProject)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "After project delete"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let secondUpdates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[1])
        #expect(secondUpdates.count == 1)
        #expect(secondUpdates[0].contains("The instructions from \(projectAgents) no longer apply."))

        // Delete global AGENTS.md too -> full removal update.
        let removedGlobal = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir)
        ) {
            try await harness.fileSystem.remove(at: Self.globalAgents)
        }
        #expect(removedGlobal)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "After global delete"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let thirdUpdates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[2])
        #expect(thirdUpdates.count == 2)
        #expect(thirdUpdates.last?.contains("Previously loaded instructions no longer apply.") == true)
    }

    @Test("a new file created in the walked ancestor path is picked up")
    func newFileInWalkedPathIsPickedUp() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let sharedDir = "\(homeDir)/code"
        let projectDir = "\(sharedDir)/repo"
        let locationDir = "\(projectDir)/packages/core"
        let projectAgents = "\(projectDir)/AGENTS.md"
        let intermediateAgents = "\(projectDir)/packages/AGENTS.md"
        let sharedAgents = "\(sharedDir)/AGENTS.md"

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            initialFiles: [
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                projectAgents: LiveExecutionFixture.bytes("Repo rules"),
            ],
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["One"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Two"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Three"]),
            ],
            rootDir: locationDir,
            homeDir: homeDir,
            project: true,
            claude: true
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Walked path creation"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 1"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        // Create a brand-new AGENTS.md in an intermediate walked directory.
        let pickedUpIntermediate = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: locationDir)
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Packages rules"),
                to: intermediateAgents,
                createDirectories: true
            )
        }
        #expect(pickedUpIntermediate)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 2"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let secondUpdates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[1])
        #expect(secondUpdates.count == 1)
        #expect(secondUpdates[0].contains("New instructions apply from:\nInstructions from: \(intermediateAgents)\nPackages rules"))

        // Also create a new AGENTS.md above project root (up to home directory).
        let pickedUpShared = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: locationDir)
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Shared code rules"),
                to: sharedAgents,
                createDirectories: true
            )
        }
        #expect(pickedUpShared)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 3"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let thirdUpdates = try Self.systemUpdates(from: harness.mockTransport.recordedRequests[2])
        #expect(thirdUpdates.count == 2)
        #expect(thirdUpdates.last?.contains("New instructions apply from:\nInstructions from: \(sharedAgents)\nShared code rules") == true)
    }

    @Test("a configured glob gaining a match is picked up without re-fetching configured URLs")
    func configuredGlobGainingMatchIsPickedUp() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let locationDir = "\(projectDir)/packages/core"
        let ruleA = "\(projectDir)/rules/a.md"
        let ruleB = "\(projectDir)/rules/b.md"
        let remoteURL = "https://example.test/instructions.md"

        let llmMock = LiveExecutionMockTransport(responses: [
            LiveExecutionFixture.anthropicTextStepSSE(chunks: ["One"]),
            LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Two"]),
        ])
        let transport = LiveInstructionRoutingTransport(llm: llmMock) { request in
            if request.url == remoteURL {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200),
                    body: LiveExecutionFixture.bytes("Remote instruction body")
                )
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let configJSON = """
        {
          "instructions": ["rules/*.md", "\(remoteURL)"]
        }
        """

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            configContent: configJSON,
            initialFiles: [
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                ruleA: LiveExecutionFixture.bytes("Rule A"),
            ],
            rootDir: locationDir,
            homeDir: homeDir,
            project: true,
            claude: true,
            httpTransport: transport
        )
        defer { Task { await harness.close() } }

        let created = try await harness.client.session.create(SessionCreateInput(title: "Glob match"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 1"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(transport.recordedLLMRequests.first).body ?? [])
        let firstSystem = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(firstSystem.contains("Instructions from: \(ruleA)\nRule A"))
        #expect(firstSystem.contains("Instructions from: \(remoteURL)\nRemote instruction body"))
        #expect(transport.recordedRemoteRequests.count == 1)

        // Create rules/b.md so the configured glob `rules/*.md` gains a new match.
        let pickedUp = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: locationDir)
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Rule B newly matched"),
                to: ruleB,
                createDirectories: true
            )
        }
        #expect(pickedUp)

        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 2"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)

        let secondUpdates = try Self.systemUpdates(from: transport.recordedLLMRequests[1])
        #expect(secondUpdates.count == 1)
        #expect(secondUpdates[0].contains("New instructions apply from:\nInstructions from: \(ruleB)\nRule B newly matched"))
        // File-watch rescans reuse the fetched URL rather than requesting it again.
        #expect(transport.recordedRemoteRequests.count == 1)
    }

    @Test("URL fetch timeout is honored without blocking server handlers and keeps last good copy on reload")
    func urlFetchTimeoutIsHonored() async throws {
        // Default timeout matches upstream's 5 seconds.
        #expect(CoreConfigPlugin.Instruction.Loader.defaultURLFetchTimeout == .seconds(5))

        let slowURL = "https://slow.example.test/hang.md"
        let fastURL = "https://fast.example.test/ok.md"
        let failFastOnSecondLoad = Mutex(false)
        let slowCancelled = Mutex(false)
        let slowCompletedNormally = Mutex(false)

        // 1. Causal non-blocking proof: even with the full 5s default timeout and a parked URL fetch,
        // server handlers return before the slow instruction URL finishes or times out.
        let gateState = Mutex<(started: Bool, finished: Bool)>((false, false))
        let nonBlockingTransport = LiveInstructionRoutingTransport(llm: LiveExecutionMockTransport(responses: [])) { request in
            if request.url == slowURL {
                gateState.withLock { $0.started = true }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    gateState.withLock { $0.finished = true }
                    throw error
                }
                gateState.withLock { $0.finished = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveExecutionFixture.bytes("late"))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }
        let nonBlockingHarness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            configContent: "{ \"instructions\": [\"\(slowURL)\"] }",
            initialFiles: [Self.globalAgents: LiveExecutionFixture.bytes("Local rule")],
            httpTransport: nonBlockingTransport
        )
        let agents = try await nonBlockingHarness.client.agent.list()
        #expect(!agents.data.isEmpty)
        // The slow fetch (with 5s timeout) did not have to complete for `/agent` to respond.
        #expect(!gateState.withLock { $0.finished })
        await nonBlockingHarness.close()

        // 2. Timeout enforcement + last-good-copy retention on `config.updated`.
        let llmMock = LiveExecutionMockTransport(responses: [
            LiveExecutionFixture.anthropicTextStepSSE(chunks: ["First"]),
            LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Second"]),
        ])
        let transport = LiveInstructionRoutingTransport(llm: llmMock) { request in
            if request.url == slowURL {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    slowCancelled.withLock { $0 = true }
                    throw error
                }
                slowCompletedNormally.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveExecutionFixture.bytes("too late"))
            }
            if request.url == fastURL {
                if failFastOnSecondLoad.withLock({ $0 }) {
                    try await Task.sleep(for: .seconds(60))
                    return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveExecutionFixture.bytes("too late"))
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: LiveExecutionFixture.bytes("Fast remote v1"))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 404), body: [])
        }

        let configJSON = """
        {
          "instructions": ["\(slowURL)", "\(fastURL)"]
        }
        """

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            configContent: configJSON,
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Local AGENTS rule"),
            ],
            instructionURLTimeout: .milliseconds(150),
            httpTransport: transport
        )
        defer { Task { await harness.close() } }

        // Prompting waits for initial activation, which times out and cancels `slowURL` (~150ms, never 60s)
        // and still delivers local AGENTS.md + `fastURL`.
        let stepStart = Flock.currentEpochMs()
        let created = try await harness.client.session.create(SessionCreateInput(title: "URL timeout"))
        _ = try await harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Go"))
        await harness.runtime.sessionExecution.awaitIdle(created.id)
        let stepElapsedMs = Flock.currentEpochMs() - stepStart
        #expect(stepElapsedMs < 20_000)
        #expect(!slowCompletedNormally.withLock { $0 })
        #expect(slowCancelled.withLock { $0 })

        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(transport.recordedLLMRequests.first).body ?? [])
        let firstSystem = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(firstSystem.contains("Instructions from: \(Self.globalAgents)\nLocal AGENTS rule"))
        #expect(firstSystem.contains("Instructions from: \(fastURL)\nFast remote v1"))
        #expect(!firstSystem.contains(slowURL))

        // On `config.updated`, a timeout on `fastURL` preserves the last good copy rather than dropping it.
        failFastOnSecondLoad.withLock { $0 = true }
        let reloaded = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: harness.rootDir)
        ) {
            await harness.runtime.bus.emit(
                EventSchema.EphemeralDefinition<JSONValue>(type: ConfigSchema.Event.updated.type),
                data: JSONValue.object([:]),
                options: CoreBus.PublishOptions(location: OpenCodeLocation(directory: harness.rootDir))
            )
        }
        #expect(reloaded)

        let bundle = try await harness.runtime.resolveLocation(
            LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: harness.rootDir))
        )
        let listed = await bundle.instructionDiscovery.list()
        if case .files(let files) = listed {
            #expect(files.contains(CoreInstruction.Discovery.File(path: fastURL, content: "Fast remote v1")))
            #expect(!files.contains { $0.path == slowURL })
        } else {
            Issue.record("Expected available instruction files after URL timeout reload")
        }
    }

    @Test("watchers stop on Location close and emit no further updates")
    func watchersStopOnLocationClose() async throws {
        let homeDir = "/tmp/opencode-live-test/home"
        let projectDir = "\(homeDir)/repo"
        let locationDir = "\(projectDir)/pkg"
        let watcherTest = CoreFilesystem.Watcher.Test()

        let harness = try await LiveExecutionFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-live-secret"],
            configContent: """
            { "instructions": ["rules/*.md"] }
            """,
            initialFiles: [
                Self.globalAgents: LiveExecutionFixture.bytes("Global v1"),
                "\(projectDir)/.git/HEAD": LiveExecutionFixture.bytes("ref: refs/heads/main\n"),
                "\(projectDir)/AGENTS.md": LiveExecutionFixture.bytes("Project v1"),
                "\(projectDir)/rules/a.md": LiveExecutionFixture.bytes("Rule A"),
            ],
            rootDir: locationDir,
            homeDir: homeDir,
            project: true,
            claude: true,
            customWatcher: watcherTest,
            instructionDebounce: .milliseconds(25)
        )
        defer { Task { await harness.close() } }

        let ref = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: locationDir))
        let bundle = try await harness.runtime.resolveLocation(ref)
        let loader = try #require(bundle.instructionLoader)
        await loader.awaitReady()

        // Active watches cover global, ancestor walk candidates, matched configured files, and glob directory.
        #expect(watcherTest.activeSubscriptionCount() > 0)
        let rescanBeforeClose = await loader.rescanCount

        // Closing the Location cancels every instruction watcher task and releases all subscriptions.
        await harness.runtime.locations.invalidate(ref)
        // Give async AsyncStream.onTermination callbacks a brief turn to unwind.
        for _ in 0..<40 where watcherTest.activeSubscriptionCount() > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(watcherTest.activeSubscriptionCount() == 0)

        // Post-close events must not trigger rescans or discovery updates.
        let postCloseUpdate = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: locationDir),
            timeoutMs: 120
        ) {
            try await harness.fileSystem.writeFile(
                LiveExecutionFixture.bytes("Global v2 after close"),
                to: Self.globalAgents,
                createDirectories: true
            )
            await watcherTest.emit(CoreConfig.WatchUpdate(path: Self.globalAgents, type: .update))
        }
        #expect(!postCloseUpdate)
        #expect(await loader.rescanCount == rescanBeforeClose)
    }

    @Test("end-to-end real disk NativeFileWatcher handles edit, new walked file, glob match, delete, and close")
    func realDiskNativeWatcherEndToEnd() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let disk = try await LiveExecutionFixture.makeRealDiskInstructionHarness(
            configContent: """
            { "instructions": ["rules/*.md"] }
            """,
            responses: [
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["One"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Two"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Three"]),
                LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Four"]),
            ],
            instructionDebounce: .milliseconds(50)
        )
        defer { Task { await disk.cleanup() } }

        let globalAgents = "\(disk.configDir)/AGENTS.md"
        let projectAgents = "\(disk.projectDir)/AGENTS.md"
        let walkedAgents = "\(disk.projectDir)/packages/AGENTS.md"
        let ruleA = "\(disk.projectDir)/rules/a.md"
        let ruleB = "\(disk.projectDir)/rules/b.md"

        try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk global v1"), to: globalAgents, createDirectories: true)
        try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk project v1"), to: projectAgents, createDirectories: true)
        try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk rule A"), to: ruleA, createDirectories: true)

        let created = try await disk.harness.client.session.create(SessionCreateInput(title: "Real disk watch"))
        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 1"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)

        let firstJSON = try LiveExecutionFixture.decodeJSON(try #require(disk.harness.mockTransport.recordedRequests.first).body ?? [])
        let firstSystem = Self.strings(firstJSON["system"]).joined(separator: "\n\n")
        #expect(firstSystem.contains("Disk global v1"))
        #expect(firstSystem.contains("Disk project v1"))
        #expect(firstSystem.contains("Disk rule A"))

        // 1. Edit project AGENTS.md on real disk
        let edited = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: disk.harness.runtime.bus,
            location: OpenCodeLocation(directory: disk.locationDir),
            timeoutMs: 4_000
        ) {
            try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk project v2"), to: projectAgents, createDirectories: false)
        }
        #expect(edited)
        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 2"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)
        let step2Updates = try Self.systemUpdates(from: disk.harness.mockTransport.recordedRequests[1])
        #expect(step2Updates.count == 1)
        #expect(step2Updates[0].contains("Disk project v2"))

        // 2. Create new file in walked path AND new match for configured glob `rules/*.md`
        let addedWalked = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: disk.harness.runtime.bus,
            location: OpenCodeLocation(directory: disk.locationDir),
            timeoutMs: 4_000
        ) {
            try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk walked packages"), to: walkedAgents, createDirectories: true)
        }
        #expect(addedWalked)
        let addedGlob = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: disk.harness.runtime.bus,
            location: OpenCodeLocation(directory: disk.locationDir),
            timeoutMs: 4_000
        ) {
            try await LocalFileSystem.shared.writeFile(LiveExecutionFixture.bytes("Disk rule B"), to: ruleB, createDirectories: true)
        }
        #expect(addedGlob)

        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 3"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)
        let step3Updates = try Self.systemUpdates(from: disk.harness.mockTransport.recordedRequests[2])
        #expect(step3Updates.count == 2)
        #expect(step3Updates.last?.contains("Disk walked packages") == true)
        #expect(step3Updates.last?.contains("Disk rule B") == true)

        // 3. Delete ruleB on real disk -> removal update
        let deleted = try await LiveExecutionFixture.triggerAndWaitForInstructionUpdate(
            bus: disk.harness.runtime.bus,
            location: OpenCodeLocation(directory: disk.locationDir),
            timeoutMs: 4_000
        ) {
            try await LocalFileSystem.shared.remove(at: ruleB)
        }
        #expect(deleted)

        _ = try await disk.harness.client.session.prompt(SessionPromptInput(sessionID: created.id.rawValue, text: "Step 4"))
        await disk.harness.runtime.sessionExecution.awaitIdle(created.id)
        let step4Updates = try Self.systemUpdates(from: disk.harness.mockTransport.recordedRequests[3])
        #expect(step4Updates.count == 3)
        #expect(step4Updates.last?.contains("The instructions from \(ruleB) no longer apply.") == true)
        #endif
    }

    @Test("server FileWatch.node publishes filesystem.changed on edit/delete, stops on unwatch, and honors disabled/confinement/TTL/eviction")
    func serverFileWatchEndpointsAndBusEvents() async throws {
        let projectDir = "/workspace"
        let watchedFile = "\(projectDir)/a.ts"
        let outsideFile = "/outside.ts"

        // 1. Live FileWatch via HTTP endpoints `/api/experimental/fs/watch`
        let harness = try await LiveExecutionFixture.makeHarness(
            initialFiles: [
                watchedFile: LiveExecutionFixture.bytes("v1"),
                outsideFile: LiveExecutionFixture.bytes("secret"),
            ],
            rootDir: projectDir
        )
        defer { Task { await harness.close() } }

        func watchRequest(method: String, path: String) async -> ServerHTTPResponse {
            let body = LiveExecutionFixture.bytes("{\"path\":\"\(path)\"}")
            return await harness.handle.fetch(ServerHTTPRequest(
                method: method,
                url: "http://127.0.0.1:4096/api/experimental/fs/watch?location[directory]=\(projectDir)",
                headers: ["content-type": "application/json"],
                body: body
            ))
        }

        // Confinement & existence checks match upstream `server/test/fs.test.ts`
        let escapeResp = await watchRequest(method: "POST", path: "../outside.ts")
        #expect(escapeResp.statusCode == 404)
        let missingResp = await watchRequest(method: "POST", path: "missing.ts")
        #expect(missingResp.statusCode == 404)

        // Start watching `a.ts`
        let startResp = await watchRequest(method: "POST", path: "a.ts")
        #expect(startResp.statusCode == 204)

        // Editing `a.ts` publishes `filesystem.changed` with `event: "change"` on the watch's Location
        let changeEvent = try await LiveExecutionFixture.triggerAndWaitForFileChanged(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir),
            file: watchedFile
        ) {
            try await harness.fileSystem.writeFile(LiveExecutionFixture.bytes("v2"), to: watchedFile, createDirectories: false)
        }
        #expect(changeEvent == FileSystemSchema.Event.ChangedPayload(file: watchedFile, event: .change))

        // Deleting `a.ts` publishes `filesystem.changed` with `event: "unlink"`
        let unlinkEvent = try await LiveExecutionFixture.triggerAndWaitForFileChanged(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir),
            file: watchedFile
        ) {
            try await harness.fileSystem.remove(at: watchedFile)
        }
        #expect(unlinkEvent == FileSystemSchema.Event.ChangedPayload(file: watchedFile, event: .unlink))

        // Unwatch stops further `filesystem.changed` events
        let unwatchResp = await watchRequest(method: "DELETE", path: "a.ts")
        #expect(unwatchResp.statusCode == 204)
        let afterUnwatch = try await LiveExecutionFixture.triggerAndWaitForFileChanged(
            bus: harness.runtime.bus,
            location: OpenCodeLocation(directory: projectDir),
            file: watchedFile,
            timeoutMs: 120
        ) {
            try await harness.fileSystem.writeFile(LiveExecutionFixture.bytes("v3"), to: watchedFile, createDirectories: false)
        }
        #expect(afterUnwatch == nil)

        // 2. Disabled FileWatch returns 503 ServiceUnavailableError
        let disabledHarness = try await LiveExecutionFixture.makeHarness(
            initialFiles: [watchedFile: LiveExecutionFixture.bytes("v1")],
            rootDir: projectDir,
            filewatcher: false
        )
        defer { Task { await disabledHarness.close() } }
        let disabledResp = await disabledHarness.handle.fetch(ServerHTTPRequest(
            method: "POST",
            url: "http://127.0.0.1:4096/api/experimental/fs/watch?location[directory]=\(projectDir)",
            headers: ["content-type": "application/json"],
            body: LiveExecutionFixture.bytes("{\"path\":\"a.ts\"}")
        ))
        #expect(disabledResp.statusCode == 503)

        // 3. TTL expiry, deduplication, and MAX_PER_LOCATION eviction stop underlying watcher subscriptions
        let clockMs = Mutex<Int64>(1_000_000)
        let testWatcher = CoreFilesystem.Watcher.Test()
        let fw = CoreFilesystem.FileWatch.Service(
            enabled: true,
            watcher: testWatcher,
            fileSystem: InMemoryFileSystem(),
            nowMs: { clockMs.withLock { $0 } },
            sweepIntervalMs: 0
        )
        let locRef = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/proj"))
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/a.ts"))
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/a.ts"))
        #expect(await testWatcher.subscriptions().count == 1)

        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/b.ts"))
        #expect(await testWatcher.subscriptions().count == 2)

        // Advance 23h, refresh a.ts, advance 2h -> b.ts expires on sweep, a.ts survives
        clockMs.withLock { $0 += 23 * 60 * 60 * 1_000 }
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/a.ts"))
        clockMs.withLock { $0 += 2 * 60 * 60 * 1_000 }
        #expect(fw.sweepExpired() == 1)
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/a.ts"))
        #expect(await testWatcher.subscriptions().count == 2)
        try await fw.watch(CoreFilesystem.FileWatch.Input(location: locRef, file: "/proj/b.ts"))
        #expect(await testWatcher.subscriptions().count == 3)
        await fw.close()
        for _ in 0..<40 where testWatcher.activeSubscriptionCount() > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(testWatcher.activeSubscriptionCount() == 0)
    }
}
