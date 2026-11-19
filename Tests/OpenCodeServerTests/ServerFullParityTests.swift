import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

@Suite("OpenCodeServer Full Parity (Commands, Skills, ModelsDev Cache, Snapshots, Tools, Titles & Reload)")
struct ServerFullParityTests {

    @Test("Seeds built-in init/review commands and project/global markdown & config commands with frontmatter execution")
    func builtinAndCustomCommandsDiscoveryAndExecution() async throws {
        let deployCmd = """
        ---
        description: Deploy target environment
        agent: plan
        model: openai/gpt-5.4
        ---
        Deploy service to $1 with flags: $2 in ${path}
        """
        let lintCmd = """
        ---
        description: Run linter in subagent
        subtask: true
        ---
        Inspect lint issues for $ARGUMENTS
        """
        let globalConfigCmd = """
        ---
        description: Global config command
        ---
        Global note: $ARGUMENTS
        """
        let claudeGlobalCmd = """
        ---
        description: Claude home command
        ---
        Claude home: $ARGUMENTS
        """
        let configJSON = """
        {
          "commands": {
            "from-config": {
              "description": "Defined in opencode.json",
              "template": "Config task: $ARGUMENTS"
            }
          }
        }
        """

        let harness = try await FullParityFixture.makeHarness(
            configContent: configJSON,
            initialFiles: [
                "/workspace/.opencode/commands/deploy.md": FullParityFixture.bytes(deployCmd),
                "/workspace/.claude/commands/lint.md": FullParityFixture.bytes(lintCmd),
            ]
        )
        defer { Task { await harness.close() } }

        // Also seed global config & ~/.claude command markdown files before first location boot
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(globalConfigCmd),
            to: "\(harness.globalConfig)/commands/global-note.md",
            createDirectories: true
        )
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(claudeGlobalCmd),
            to: "\(harness.globalHome)/.claude/commands/claude-global.md",
            createDirectories: true
        )

        // 1. Verify GET /api/command lists built-in init/review + all discovered custom/config commands
        let cmdRes = try await harness.client.command.list()
        let byName = Dictionary(uniqueKeysWithValues: cmdRes.data.map { ($0.name, $0) })

        let initCmd = try #require(byName["init"])
        #expect(initCmd.description == "guided AGENTS.md setup")

        let reviewCmd = try #require(byName["review"])
        #expect(reviewCmd.description == "review changes [commit|branch|pr], defaults to uncommitted")

        let deployInfo = try #require(byName["deploy"])
        #expect(deployInfo.description == "Deploy target environment")

        let lintInfo = try #require(byName["lint"])
        #expect(lintInfo.description == "Run linter in subagent")

        #expect(byName["global-note"]?.description == "Global config command")
        #expect(byName["claude-global"]?.description == "Claude home command")
        #expect(byName["from-config"]?.description == "Defined in opencode.json")

        // 2. Execute built-in `/init` command via POST /api/session/:id/command
        let initSession = try await harness.client.session.create(SessionCreateInput(title: "Init Cmd Run"))
        try await harness.client.session.command(SessionCommandInput(
            sessionID: initSession.id.rawValue,
            name: "init",
            text: "focus on SwiftPM targets"
        ))
        await harness.runtime.sessionExecution.awaitIdle(initSession.id)

        let initMsgs = try await harness.client.message.list(
            MessageListInput(sessionID: initSession.id.rawValue, order: .asc)
        ).data
        let initUserText = initMsgs.compactMap { msg -> String? in
            if case .user(let u) = msg { return u.text }
            return nil
        }.first
        let renderedInit = try #require(initUserText)
        #expect(renderedInit.contains("focus on SwiftPM targets"))
        #expect(renderedInit.contains("/workspace"))
        #expect(!renderedInit.contains("${path}"))
        #expect(!renderedInit.contains("$ARGUMENTS"))

        // 3. Execute custom `deploy` command (verifies positional $1/$2, agent switch, model switch)
        let deploySession = try await harness.client.session.create(SessionCreateInput(title: "Deploy Cmd Run"))
        try await harness.client.session.command(SessionCommandInput(
            sessionID: deploySession.id.rawValue,
            name: "deploy",
            text: "staging --dry-run --verbose"
        ))
        await harness.runtime.sessionExecution.awaitIdle(deploySession.id)

        let updatedDeploySession = try await harness.client.session.get(SessionGetInput(sessionID: deploySession.id.rawValue))
        #expect(updatedDeploySession.agent == "plan")
        #expect(updatedDeploySession.model?.providerID == "openai")
        #expect(updatedDeploySession.model?.id == "gpt-5.4")

        let deployMsgs = try await harness.client.message.list(
            MessageListInput(sessionID: deploySession.id.rawValue, order: .asc)
        ).data
        let deployUserText = deployMsgs.compactMap { msg -> String? in
            if case .user(let u) = msg { return u.text }
            return nil
        }.first
        #expect(deployUserText == "Deploy service to staging with flags: --dry-run --verbose in /workspace")

        // 4. Execute `lint` command with `subtask: true` -> spawns a child subagent session
        let parentSession = try await harness.client.session.create(SessionCreateInput(title: "Parent For Subtask"))
        try await harness.client.session.command(SessionCommandInput(
            sessionID: parentSession.id.rawValue,
            name: "lint",
            text: "Sources/OpenCodeServer"
        ))
        let children = try await harness.client.session.list(
            SessionListInput(parentID: parentSession.id.rawValue)
        ).data
        let child = try #require(children.first)
        #expect(child.parentID == parentSession.id)
        #expect(child.title == "Run linter in subagent")
        await harness.runtime.sessionExecution.awaitIdle(child.id)
        let childMsgs = try await harness.client.message.list(
            MessageListInput(sessionID: child.id.rawValue, order: .asc)
        ).data
        let childUserText = childMsgs.compactMap { msg -> String? in
            if case .user(let u) = msg { return u.text }
            return nil
        }.first
        #expect(childUserText?.contains("Inspect lint issues for Sources/OpenCodeServer") == true)
    }

    @Test("Discovers project & global skills with sibling files and activates skills via POST /api/experimental/session/:id/skill")
    func projectAndGlobalSkillDiscoveryAndActivation() async throws {
        let projectSkillMD = """
        ---
        name: My Custom Skill
        description: Guides SwiftPM release verification
        ---
        # Release Checklist

        Always run `./scripts/test.sh` before tagging a release.
        """
        let claudeSkillMD = """
        ---
        name: Claude Project Skill
        description: Discovered from .claude/skills
        ---
        Claude project instructions.
        """
        let agentsSkillMD = """
        ---
        name: Agents Skill
        description: Discovered from .agents/skills
        ---
        Agents skill instructions.
        """
        let globalConfigSkillMD = """
        ---
        name: Global Config Skill
        description: Discovered from globalPaths.config/skills
        ---
        Global config skill body.
        """
        let homeClaudeSkillMD = """
        ---
        name: Home Claude Skill
        description: Discovered from ~/.claude/skills
        ---
        Home claude skill body.
        """

        let harness = try await FullParityFixture.makeHarness(
            initialFiles: [
                "/workspace/.opencode/skills/my-skill/SKILL.md": FullParityFixture.bytes(projectSkillMD),
                "/workspace/.opencode/skills/my-skill/reference/guide.md": FullParityFixture.bytes("Detailed release notes guide"),
                "/workspace/.opencode/skills/my-skill/scripts/verify.sh": FullParityFixture.bytes("#!/bin/sh\necho ok\n"),
                "/workspace/.claude/skills/claude-skill/SKILL.md": FullParityFixture.bytes(claudeSkillMD),
                "/workspace/.agents/skills/agent-skill/SKILL.md": FullParityFixture.bytes(agentsSkillMD),
            ]
        )
        defer { Task { await harness.close() } }

        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(globalConfigSkillMD),
            to: "\(harness.globalConfig)/skills/global-skill/SKILL.md",
            createDirectories: true
        )
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(homeClaudeSkillMD),
            to: "\(harness.globalHome)/.claude/skills/home-claude-skill/SKILL.md",
            createDirectories: true
        )

        // 1. Verify GET /api/skill discovers all 5 project + global skills
        let skillRes = try await harness.client.skill.list()
        let byID = Dictionary(uniqueKeysWithValues: skillRes.data.map { ($0.id.rawValue, $0) })

        let mySkill = try #require(byID["my-skill"])
        #expect(mySkill.name.rawValue == "My Custom Skill")
        #expect(mySkill.description == "Guides SwiftPM release verification")
        #expect(mySkill.content.contains("Always run `./scripts/test.sh`"))

        #expect(byID["claude-skill"]?.name.rawValue == "Claude Project Skill")
        #expect(byID["agent-skill"]?.name.rawValue == "Agents Skill")
        #expect(byID["global-skill"]?.name.rawValue == "Global Config Skill")
        #expect(byID["home-claude-skill"]?.name.rawValue == "Home Claude Skill")

        // 2. Verify sibling files were registered cleanly (excluding SKILL.md itself)
        let bundle = try await harness.resolveBundle()
        let siblingFiles = try #require(await bundle.skill.files(SkillSchema.ID(rawValue: "my-skill")))
        #expect(siblingFiles["reference/guide.md"] == "Detailed release notes guide")
        #expect(siblingFiles["scripts/verify.sh"] == "#!/bin/sh\necho ok\n")
        #expect(siblingFiles["SKILL.md"] == nil)

        // 3. Activate `my-skill` on a session via POST /api/experimental/session/:id/skill
        let session = try await harness.client.session.create(SessionCreateInput(title: "Skill Activation"))
        try await harness.client.session.skill(SessionSkillInput(
            sessionID: session.id.rawValue,
            id: "my-skill",
            resume: false
        ))

        let messages = try await harness.client.message.list(
            MessageListInput(sessionID: session.id.rawValue, order: .asc)
        ).data
        let activatedSkill = messages.compactMap { msg -> SessionMessageSchema.Skill? in
            if case .skill(let s) = msg { return s }
            return nil
        }.first
        let skillMsg = try #require(activatedSkill)
        #expect(skillMsg.skill == "my-skill")
        #expect(skillMsg.name == "My Custom Skill")
        #expect(skillMsg.text.contains("Always run `./scripts/test.sh`"))
    }

    @Test("Merges cached globalPaths.cache/models.json into integrations and models without overwriting built-in or config entries")
    func cachedModelsDevCatalogMergePreservesPrecedence() async throws {
        let configJSON = """
        {
          "providers": {
            "cohere": {
              "name": "Cohere Custom Config"
            }
          }
        }
        """
        let harness = try await FullParityFixture.makeHarness(
            env: [
                "ANTHROPIC_API_KEY": "sk-ant-cache-test",
                "COHERE_API_KEY": "cohere-cache-test-key",
            ],
            configContent: configJSON
        )
        defer { Task { await harness.close() } }

        // Populate `globalPaths.cache/models.json` before location boot
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(FullParityFixture.sampleModelsDevV2JSON),
            to: "\(harness.globalCache)/models.json",
            createDirectories: true
        )

        // 1. Verify GET /api/integration contains merged `cohere` with config-overridden name
        let integrations = try await harness.client.integration.list().data
        let cohereInt = try #require(integrations.first { $0.id.rawValue == "cohere" })
        #expect(cohereInt.name == "Cohere Custom Config")
        let anthropicInt = try #require(integrations.first { $0.id.rawValue == "anthropic" })
        #expect(anthropicInt.name == "Anthropic") // Built-in name preserved over stale cache

        // 2. Verify GET /api/model contains both new provider model & extra cached model on built-in provider
        let models = try await harness.client.model.list().data

        let cohereModel = try #require(models.first { $0.providerID.rawValue == "cohere" && $0.id.rawValue == "command-a" })
        #expect(cohereModel.name == "Command A")
        #expect(cohereModel.limit.context == 256_000)

        let extraAnthropicModel = try #require(models.first {
            $0.providerID == .anthropic && $0.id.rawValue == "claude-3-7-sonnet-cached"
        })
        #expect(extraAnthropicModel.name == "Claude 3.7 Sonnet (Cached)")

        // 3. Built-in model must NOT be overwritten by stale cached metadata
        let builtinSonnet = try #require(models.first {
            $0.providerID == .anthropic && $0.id.rawValue == "claude-sonnet-4-6"
        })
        #expect(builtinSonnet.name == "Claude Sonnet 4.6")
        #expect(builtinSonnet.limit.context == 200_000)
        #expect(builtinSonnet.limit.output == 64_000)
    }

    @Test("Wires CoreSessionLiveSnapshotBridge into bundle.sessionRunner and powers live session diff & revert stage/clear/commit")
    func liveSnapshotBridgeInSessionRunnerAndDiffRevertFlow() async throws {
        let step1SSE = LiveExecutionFixture.anthropicToolCallStepSSE(
            thinking: "Writing created.txt to workspace.",
            toolCallID: "toolu_write_snap_1",
            toolName: "write",
            inputChunks: ["{\"path\":\"created.txt\",\"content\":\"line 1\\nline 2\\n\"}"]
        )
        let step2SSE = LiveExecutionFixture.anthropicTextStepSSE(
            chunks: ["Created created.txt successfully."]
        )

        let harness = try await FullParityFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-snapshot-test"],
            responses: [step1SSE, step2SSE]
        )
        defer { Task { await harness.close() } }

        // 1. Verify CoreSessionLiveSnapshotBridge is wired directly onto bundle.sessionRunner
        let bundle = try await harness.resolveBundle()
        let liveRunner = try #require(bundle.sessionRunner as? ServerLiveRuntime.LiveSessionRunner)
        let liveBridge = try #require(liveRunner.snapshotBridge as? CoreSessionLiveSnapshotBridge)
        _ = liveBridge

        // Also verify workerdProfile disables snapshotBridge cleanly
        let workerdHarness = try await FullParityFixture.makeHarness(workerdProfile: true)
        defer { Task { await workerdHarness.close() } }
        let workerdBundle = try await workerdHarness.resolveBundle()
        let workerdRunner = try #require(workerdBundle.sessionRunner as? ServerLiveRuntime.LiveSessionRunner)
        #expect(workerdRunner.snapshotBridge == nil)

        // 2. Run a real 2-step tool-calling session that writes `created.txt`
        let session = try await harness.client.session.create(SessionCreateInput(title: "Snapshot Diff Test"))
        let userPrompt = try await harness.client.session.prompt(SessionPromptInput(
            sessionID: session.id.rawValue,
            text: "Create created.txt with two lines."
        ))
        await harness.runtime.sessionExecution.awaitIdle(session.id)

        // File was written on the workspace filesystem
        let writtenBytes = try await harness.fileSystem.readFile(at: "/workspace/created.txt")
        #expect(FullParityFixture.utf8(writtenBytes) == "line 1\nline 2\n")

        // Step 1 assistant message recorded real start/end snapshots + touched file list
        let messages = try await harness.client.message.list(
            MessageListInput(sessionID: session.id.rawValue, order: .asc)
        ).data
        let assistantSteps = messages.compactMap { msg -> SessionMessageSchema.Assistant? in
            if case .assistant(let a) = msg { return a }
            return nil
        }
        #expect(assistantSteps.count == 2)
        let step1Snap = try #require(assistantSteps[0].snapshot)
        #expect(step1Snap.start != nil)
        #expect(step1Snap.end != nil)
        #expect(step1Snap.start != step1Snap.end)
        #expect(step1Snap.files == ["created.txt"])

        // 3. GET /api/session/:id/diff returns real unified diff for the turn
        let diffs = try await harness.client.session.diff(SessionDiffInput(sessionID: session.id.rawValue))
        let createdDiff = try #require(diffs.first { $0.file == "created.txt" })
        #expect(createdDiff.status == .added)
        #expect(createdDiff.additions.rawValue == 2)
        #expect(createdDiff.patch.contains("+line 1"))

        // 4. POST /api/session/:id/revert/stage restores workspace files to pre-step snapshot (removes created.txt)
        let staged = try await harness.client.session.revert.stage(SessionRevertStageInput(
            sessionID: session.id.rawValue,
            messageID: userPrompt.id.rawValue,
            files: true
        ))
        #expect(staged.messageID == userPrompt.id)
        #expect(staged.snapshot != nil)
        #expect(!(await harness.fileSystem.exists(at: "/workspace/created.txt")))

        // 5. DELETE /api/session/:id/revert clears revert and restores created.txt back onto workspace
        try await harness.client.session.revert.clear(SessionRevertClearInput(sessionID: session.id.rawValue))
        #expect(await harness.fileSystem.exists(at: "/workspace/created.txt"))
        let restoredBytes = try await harness.fileSystem.readFile(at: "/workspace/created.txt")
        #expect(FullParityFixture.utf8(restoredBytes) == "line 1\nline 2\n")

        // 6. Stage again & POST /api/session/:id/revert/commit succeeds cleanly
        _ = try await harness.client.session.revert.stage(SessionRevertStageInput(
            sessionID: session.id.rawValue,
            messageID: userPrompt.id.rawValue,
            files: true
        ))
        try await harness.client.session.revert.commit(SessionRevertCommitInput(sessionID: session.id.rawValue))
        let afterCommit = try await harness.client.session.get(SessionGetInput(sessionID: session.id.rawValue))
        #expect(afterCommit.revert == nil)
    }

    @Test("Wires real session, sessionMove, and automation dependencies into built-in tools")
    func builtinToolsReceiveLiveSessionMoveAndAutomationDependencies() async throws {
        let configJSON = """
        {
          "experimental": {
            "automations": true
          }
        }
        """
        let harness = try await FullParityFixture.makeHarness(configContent: configJSON)
        defer { Task { await harness.close() } }

        try await harness.fileSystem.makeDirectory(at: "/workspace-moved", recursive: true)
        let session = try await harness.client.session.create(SessionCreateInput(title: "Tool Dependency Test"))
        let bundle = try await harness.resolveBundle()

        let allowAll: PermissionSchema.Ruleset = [
            PermissionSchema.Rule(action: "*", resource: "*", effect: .allow),
        ]
        let snap = await bundle.tool.snapshot(permissions: allowAll)

        // 1. Execute `opencode_automation_create` built-in tool directly -> proves real `automation` + `session` are wired
        let autoCreateResult = try await snap.execute(CoreTool.ExecuteCallInput(
            sessionID: session.id,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_tool_auto",
            callID: ToolSchema.CallID(rawValue: "call_auto_1"),
            name: "opencode_automation_create",
            input: .object([
                "name": .string("Hourly Health Check"),
                "trigger": .object(["type": .string("every"), "every": .string("1 hour")]),
                "action": .object(["type": .string("prompt"), "prompt": .string("Check service health")]),
            ])
        ))
        let autoText = autoCreateResult.content.compactMap { item -> String? in
            if case .text(let t) = item { return t.text }
            return nil
        }.joined()
        #expect(autoText.contains("Hourly Health Check"))

        // Confirm automation is persisted in the real process-global automation store
        let listedAutomations = try await harness.client.experimental.automation.list()
        #expect(listedAutomations.contains(where: { $0.name == "Hourly Health Check" }))

        // 2. Execute `opencode_session_move` built-in tool directly -> proves real `sessionMove` is wired
        let moveResult = try await snap.execute(CoreTool.ExecuteCallInput(
            sessionID: session.id,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_tool_move",
            callID: ToolSchema.CallID(rawValue: "call_move_1"),
            name: "opencode_session_move",
            input: .object([
                "directory": .string("/workspace-moved"),
            ])
        ))
        let moveText = moveResult.content.compactMap { item -> String? in
            if case .text(let t) = item { return t.text }
            return nil
        }.joined()
        #expect(moveText.contains("/workspace-moved"))

        // 3. Execute `subagent` built-in tool directly -> proves real `session` is wired
        let subagentResult = try await snap.execute(CoreTool.ExecuteCallInput(
            sessionID: session.id,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg_tool_subagent",
            callID: ToolSchema.CallID(rawValue: "call_subagent_1"),
            name: "subagent",
            input: .object([
                "agent": .string("explore"),
                "description": .string("Explore workspace files"),
                "prompt": .string("List files in workspace"),
            ])
        ))
        let subagentText = subagentResult.content.compactMap { item -> String? in
            if case .text(let t) = item { return t.text }
            return nil
        }.joined()
        #expect(subagentText.contains("ses_"))
        let childSessions = try await harness.client.session.list(
            SessionListInput(parentID: session.id.rawValue)
        ).data
        #expect(childSessions.contains(where: { $0.agent == "explore" }))
    }

    @Test("Wires live CoreSessionTitle onto ServerLocationBundle for auto-naming and clean no-op when unconfigured")
    func liveSessionTitleGenerationAndUnconfiguredNoop() async throws {
        // 1. Unconfigured provider: bundle.sessionTitle exists and PATCH title="" cleanly no-ops with 0 HTTP calls
        let noKeyHarness = try await FullParityFixture.makeHarness(env: [:], responses: [])
        defer { Task { await noKeyHarness.close() } }

        let noKeyBundle = try await noKeyHarness.resolveBundle()
        #expect(noKeyBundle.sessionTitle != nil)

        let noKeySession = try await noKeyHarness.client.session.create(SessionCreateInput(title: "Original Title"))
        _ = try await noKeyHarness.client.session.prompt(SessionPromptInput(
            sessionID: noKeySession.id.rawValue,
            text: "Debug failing Swift 6 build",
            resume: false
        ))
        try await noKeyHarness.client.session.update(SessionUpdateInput(
            sessionID: noKeySession.id.rawValue,
            title: ""
        ))
        #expect(noKeyHarness.mockTransport.recordedRequests.isEmpty)
        let unchanged = try await noKeyHarness.client.session.get(SessionGetInput(sessionID: noKeySession.id.rawValue))
        #expect(unchanged.title == "Original Title")

        // 2. Connected provider: PATCH title="" invokes title agent and renames the session
        let promptReplySSE = LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Here is the fix."])
        let titleSSE = LiveExecutionFixture.anthropicTextStepSSE(chunks: ["Swift 6 concurrency fix"])

        let liveHarness = try await FullParityFixture.makeHarness(
            env: ["ANTHROPIC_API_KEY": "sk-ant-title-test"],
            responses: [promptReplySSE, titleSSE]
        )
        defer { Task { await liveHarness.close() } }

        let liveSession = try await liveHarness.client.session.create(SessionCreateInput(title: "Initial Placeholder"))
        _ = try await liveHarness.client.session.prompt(SessionPromptInput(
            sessionID: liveSession.id.rawValue,
            text: "Help me fix a Swift 6 Sendable error in ServerModule.swift"
        ))
        await liveHarness.runtime.sessionExecution.awaitIdle(liveSession.id)

        // Trigger title regeneration via PATCH /api/session/:id with empty title
        try await liveHarness.client.session.update(SessionUpdateInput(
            sessionID: liveSession.id.rawValue,
            title: ""
        ))

        let renamed = try await liveHarness.client.session.get(SessionGetInput(sessionID: liveSession.id.rawValue))
        #expect(renamed.title == "Swift 6 concurrency fix")

        // Verify the second outbound request carried the built-in `title` agent's system prompt
        let requests = liveHarness.mockTransport.recordedRequests
        #expect(requests.count == 2)
        let titleReqBody = FullParityFixture.utf8(requests[1].body ?? [])
        #expect(titleReqBody.contains("You name conversations"))
    }

    @Test("POST /api/location/reload picks up newly added custom command and skill files on disk and emits update events")
    func locationReloadPicksUpNewCommandsAndSkillsAndEmitsEvents() async throws {
        let harness = try await FullParityFixture.makeHarness()
        defer { Task { await harness.close() } }

        // 1. Boot location before adding custom command/skill files
        let initialCommands = try await harness.client.command.list().data
        #expect(initialCommands.contains(where: { $0.name == "init" }))
        #expect(initialCommands.contains(where: { $0.name == "review" }))
        #expect(!initialCommands.contains(where: { $0.name == "hot-cmd" }))

        let initialSkills = try await harness.client.skill.list().data
        #expect(!initialSkills.contains(where: { $0.id.rawValue == "hot-skill" }))

        // 2. Write new custom command and skill files onto the workspace filesystem
        let hotCommandMD = """
        ---
        description: Dynamically added after boot
        ---
        Run hot check on $ARGUMENTS
        """
        let hotSkillMD = """
        ---
        name: Hot Reloaded Skill
        description: Added dynamically before reload
        ---
        Follow the hot-reloaded playbook.
        """
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(hotCommandMD),
            to: "/workspace/.opencode/commands/hot-cmd.md",
            createDirectories: true
        )
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes(hotSkillMD),
            to: "/workspace/.opencode/skills/hot-skill/SKILL.md",
            createDirectories: true
        )
        try await harness.fileSystem.writeFile(
            FullParityFixture.bytes("Extra helper doc"),
            to: "/workspace/.opencode/skills/hot-skill/notes.txt",
            createDirectories: true
        )

        // 3. Record CoreBus events during POST /api/location/reload
        let recorder = LiveExecutionFixture.EventRecorder(bus: harness.runtime.bus)
        defer { recorder.stop() }

        try await harness.client.location.reload()

        // 4. Verify newly added command & skill are immediately visible via HTTP API
        let reloadedCommands = try await harness.client.command.list().data
        let hotCmd = try #require(reloadedCommands.first { $0.name == "hot-cmd" })
        #expect(hotCmd.description == "Dynamically added after boot")

        let reloadedSkills = try await harness.client.skill.list().data
        let hotSkill = try #require(reloadedSkills.first { $0.id.rawValue == "hot-skill" })
        #expect(hotSkill.name.rawValue == "Hot Reloaded Skill")
        #expect(hotSkill.description == "Added dynamically before reload")
        #expect(hotSkill.content.contains("Follow the hot-reloaded playbook."))

        let reloadedBundle = try await harness.resolveBundle()
        let hotSiblings = try #require(await reloadedBundle.skill.files(SkillSchema.ID(rawValue: "hot-skill")))
        #expect(hotSiblings["notes.txt"] == "Extra helper doc")

        // 5. Verify bus emitted update events on reload
        let eventTypes = recorder.types()
        #expect(eventTypes.contains("agent.updated"))
        #expect(eventTypes.contains("command.updated"))
        #expect(eventTypes.contains("skill.updated"))
        #expect(eventTypes.contains("integration.updated"))
        #expect(eventTypes.contains("provider.updated"))
        #expect(eventTypes.contains("model.updated"))
    }
}
