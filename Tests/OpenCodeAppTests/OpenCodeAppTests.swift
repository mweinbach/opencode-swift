import Synchronization
import Testing
import OpenCodeApp
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore

@Suite("OpenCodeApp Identity Assets")
struct OpenCodeIdentityAssetsTests {
    @Test("All upstream identity brand assets are bundled and readable via Bundle.module")
    func allBundledIdentityAssetsLoad() throws {
        for asset in OpenCodeIdentityAssets.Asset.allCases {
            let path = OpenCodeAppTestHelper.assetURLPath(asset)
            #expect(path != nil, "Missing bundled asset \(asset.rawValue)")
            let bytes = OpenCodeIdentityAssets.data(for: asset)
            #expect(OpenCodeAppTestHelper.dataByteCount(bytes) > 0, "Empty asset \(asset.rawValue)")
        }

        let darkSVG = try #require(OpenCodeIdentityAssets.svgString(lightMode: false))
        #expect(darkSVG.contains("<svg"))
        #expect(darkSVG.contains("#131010"))

        let lightSVG = try #require(OpenCodeIdentityAssets.svgString(lightMode: true))
        #expect(lightSVG.contains("<svg"))
        #expect(lightSVG.contains("#FDFCFC"))

        for size in OpenCodeIdentityAssets.MarkSize.allCases {
            let darkPNG = OpenCodeIdentityAssets.pngData(size: size, lightMode: false)
            #expect(OpenCodeAppTestHelper.hasPNGMagicBytes(darkPNG))
        }
        let light512PNG = OpenCodeIdentityAssets.pngData(size: .px512, lightMode: true)
        #expect(OpenCodeAppTestHelper.hasPNGMagicBytes(light512PNG))

        #if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
        #expect(OpenCodeIdentityAssets.swiftUIImage(size: .px512, lightMode: false) != nil)
        #expect(OpenCodeIdentityAssets.swiftUIImage(size: .px512, lightMode: true) != nil)
        #endif
    }
}

@Suite("OpenCodeApp Theme Bridge & Rendering")
struct OpenCodeAppThemeAndRenderingTests {
    @Test("ThemeDefaults resolves distinct dark and light palettes and bridges RGBA tokens")
    func themeDefaultsLightAndDarkResolution() {
        let dark = AppResolvedPalette(themeName: "opencode", mode: .dark)
        let light = AppResolvedPalette(themeName: "opencode", mode: .light)

        #expect(dark.isDark == true)
        #expect(light.isDark == false)
        #expect(dark.background != light.background)
        #expect(dark.textPrimary != light.textPrimary)
        #expect(hex(dark.background) == "#080808") // "opencode" is the new default theme (upstream 85951cb)
        #expect(hex(light.background) == "#ffffff")

        let opencode2Dark = AppResolvedPalette(themeName: "opencode2", mode: .dark)
        #expect(opencode2Dark.isDark == true)
        #expect(hex(opencode2Dark.background) == "#080808")

        let available = AppResolvedPalette.availableThemeNames
        #expect(available.contains("opencode"))
        #expect(available.contains("opencode2"))

        // System mode tracks systemIsDark; explicit light/dark ignores systemIsDark
        #expect(AppThemeMode.system.resolvedMode(systemIsDark: true) == .dark)
        #expect(AppThemeMode.system.resolvedMode(systemIsDark: false) == .light)
        #expect(AppThemeMode.light.resolvedMode(systemIsDark: true) == .light)
        #expect(AppThemeMode.dark.resolvedMode(systemIsDark: false) == .dark)
    }

    @Test("Markdown bridge renders Patchmark blocks, Merman Mermaid diagrams, and LaTeX math")
    func markdownMermaidAndLatexRendering() {
        let md = """
        # Architecture Overview

        Inline math $x^2 + y^2 = z^2$ and **bold** text.

        ```mermaid
        flowchart LR
            A[SwiftUI] --> B[OpenCodeSDK]
            B --> C[ServerRouter]
        ```

        ```latex
        \\frac{a + b}{c}
        ```

        - [x] Copy brand assets
        - [ ] Ship release
        """

        let palette = AppResolvedPalette(themeName: "opencode", mode: .dark)
        let blocks = OpenCodeAppMarkdown.renderBlocks(md, palette: palette, streaming: false)

        let hasHeading = blocks.contains {
            if case .heading(_, 1, let text) = $0 { return text == "Architecture Overview" }
            return false
        }
        #expect(hasHeading)

        let mermaidBlock = blocks.first {
            if case .mermaid = $0 { return true }
            return false
        }
        if case let .mermaid(_, kind, _, rendered)? = mermaidBlock {
            #expect(kind == "flowchart")
            #expect(rendered?.contains("SwiftUI") == true)
            #expect(rendered?.contains("ServerRouter") == true)
        } else {
            Issue.record("Expected Mermaid block to be parsed and rendered by Merman")
        }

        let mathBlock = blocks.first {
            if case .math = $0 { return true }
            return false
        }
        if case let .math(_, source, rendered)? = mathBlock {
            #expect(source.contains("\\frac"))
            #expect(!rendered.isEmpty)
        } else {
            Issue.record("Expected LaTeX math block to be parsed and rendered")
        }

        let listBlock = blocks.first {
            if case .list = $0 { return true }
            return false
        }
        if case let .list(_, ordered, _, items)? = listBlock {
            #expect(!ordered)
            #expect(items.count == 2)
            #expect(items[0].checked == true)
            #expect(items[1].checked == false)
        } else {
            Issue.record("Expected GFM task list block")
        }
    }

    @Test("Unified & Split Diff parser handles hunk line numbers and paired side-by-side rows")
    func diffParsingUnifiedAndSplit() {
        let patch = """
        @@ -10,4 +10,4 @@
         let unchanged = 1
        -let oldValue = "before"
        +let newValue = "after"
         let tail = 2
        """
        let diff = AppFileDiffItem(path: "Sources/Demo.swift", status: "modified", additions: 1, deletions: 1, patch: patch)
        #expect(diff.unifiedLines.count == 5)
        #expect(diff.unifiedLines[0].kind == .header)
        #expect(diff.unifiedLines[1].oldLineNumber == 10)
        #expect(diff.unifiedLines[1].newLineNumber == 10)
        #expect(diff.unifiedLines[2].kind == .removed)
        #expect(diff.unifiedLines[2].oldLineNumber == 11)
        #expect(diff.unifiedLines[3].kind == .added)
        #expect(diff.unifiedLines[3].newLineNumber == 11)

        // Split view pairs removed & added on the same row
        #expect(diff.splitRows.count == 4)
        #expect(diff.splitRows[2].left?.kind == .removed)
        #expect(diff.splitRows[2].right?.kind == .added)
    }
}

@Suite("OpenCodeApp Commands, Mentions & Launch Config")
struct OpenCodeAppCommandsTests {
    @Test("Command Palette filtering ranks exact, prefix, and keyword matches accurately")
    func commandPaletteFiltering() {
        let all = AppCommandRegistry.filterCommands(query: "")
        #expect(all.count == AppCommandRegistry.builtInCommands.count)

        let qrResults = AppCommandRegistry.filterCommands(query: "qr")
        #expect(qrResults.first?.id == .pairDevice)

        let diffResults = AppCommandRegistry.filterCommands(query: "/diff")
        #expect(diffResults.first?.id == .openDiffReview)

        let themeResults = AppCommandRegistry.filterCommands(query: "dark")
        #expect(themeResults.contains { $0.id == .toggleThemeMode })

        let empty = AppCommandRegistry.filterCommands(query: "nonexistent-command-xyz")
        #expect(empty.isEmpty)
    }

    @Test("Composer parses ! shell commands, / slash commands, and @ file/agent/session mentions")
    func composerInputParsingAndMentions() {
        #expect(AppCommandRegistry.parseComposerInput("!git status", shellMode: false) == .shell(command: "git status"))
        #expect(AppCommandRegistry.parseComposerInput("ls -la", shellMode: true) == .shell(command: "ls -la"))
        #expect(AppCommandRegistry.parseComposerInput("/rename My Sprint", shellMode: false) == .slash(name: "rename", arguments: "My Sprint"))

        let sessionID = SessionID.create().rawValue
        let promptParsed = AppCommandRegistry.parseComposerInput(
            "Ask @plan to check @Sources/App.swift and @session:\(sessionID)",
            shellMode: false,
            knownAgentIDs: ["build", "plan"]
        )
        if case let .prompt(text, files, agents, sessionRefs) = promptParsed {
            #expect(text.contains("@plan"))
            #expect(files == ["Sources/App.swift"])
            #expect(agents == ["plan"])
            #expect(sessionRefs == [sessionID])
        } else {
            Issue.record("Expected parsed prompt with mentions")
        }

        // Mention trigger detection & replacement
        let draft = "Review @Sou"
        let trigger = AppCommandRegistry.detectMentionTrigger(in: draft)
        #expect(trigger?.query == "Sou")
        if let trigger {
            let suggestion = AppMentionItem(kind: .file, value: "Sources/OpenCodeApp/Core/OpenCodeAppStore.swift")
            let applied = AppCommandRegistry.applyMention(suggestion, to: draft, trigger: trigger)
            #expect(applied == "Review @Sources/OpenCodeApp/Core/OpenCodeAppStore.swift ")
        }
    }

    @Test("Session grouping buckets Today, Yesterday, Previous 7 Days, Earlier and excludes archived")
    func sessionGrouping() {
        let now: Int64 = 1_750_000_000_000
        let day: Int64 = 86_400_000
        let items = [
            AppSessionSummary(id: "s1", title: "Today", updatedMs: now - 1_000),
            AppSessionSummary(id: "s2", title: "Yesterday", updatedMs: now - day - 1_000),
            AppSessionSummary(id: "s3", title: "Week", updatedMs: now - day * 4),
            AppSessionSummary(id: "s4", title: "Older", updatedMs: now - day * 20),
            AppSessionSummary(id: "s5", title: "Archived", updatedMs: now - 500, archived: true),
        ]
        let groups = AppSessionGroup.group(items, nowMs: now)
        #expect(groups.map(\.id) == ["today", "yesterday", "week", "earlier"])
        #expect(groups.flatMap(\.sessions).contains { $0.id == "s5" } == false)
    }

    @Test("Launch configuration parses CLI flags and Basic/Bearer credentials")
    func launchConfigurationParsing() {
        let basicCfg = OpenCodeAppLaunchConfiguration.fromProcess(
            arguments: ["opencode-app", "--server", "http://127.0.0.1:4096", "--dir", "/tmp/work"],
            environment: ["OPENCODE_SERVER_USERNAME": "alice", "OPENCODE_SERVER_PASSWORD": "secret"]
        )
        #expect(basicCfg.serverURL == "http://127.0.0.1:4096")
        #expect(basicCfg.workspaceDirectory == "/tmp/work")
        #expect(basicCfg.credentials == .basic(username: "alice", password: "secret"))
        #expect(basicCfg.credentials.authorizationHeader?.hasPrefix("Basic ") == true)

        let bearerCfg = OpenCodeAppLaunchConfiguration.fromProcess(
            arguments: ["opencode-app"],
            environment: ["OPENCODE_SERVER_URL": "https://box.local", "OPENCODE_SERVER_TOKEN": "tok_123"]
        )
        #expect(bearerCfg.serverURL == "https://box.local")
        #expect(bearerCfg.credentials == .bearer(token: "tok_123"))
        #expect(bearerCfg.credentials.authorizationHeader == "Bearer tok_123")
    }
}

@Suite("OpenCodeAppStore Live Embedded SDK & SSE Integration")
struct OpenCodeAppStoreLiveTests {
    @Test("Live embedded OpenCodeSDK session CRUD, prompt admission, model/agent switch, slash commands & QR pairing")
    @MainActor
    func liveEmbeddedSDKWorkflow() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-store")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let configJSON = """
        {
          "default_agent": "build",
          "providers": {
            "local-test": {
              "name": "Local Test Provider",
              "settings": { "baseURL": "http://127.0.0.1:11434/v1" },
              "models": {
                "swift-coder": {
                  "name": "Swift Coder",
                  "limit": { "context": 128000, "output": 16384 }
                }
              }
            }
          }
        }
        """

        let store = OpenCodeAppStore()
        try await store.connectEmbedded(
            directory: dir,
            databasePath: ":memory:",
            configContent: configJSON,
            subscribeEvents: false
        )
        defer {
            Task { @MainActor in await store.disconnect() }
        }

        #expect(store.connectionState.isConnected)
        #expect(store.workspaceDirectory == dir)
        #expect(store.agents.contains { $0.id == "build" })
        #expect(store.agents.contains { $0.id == "plan" })
        #expect(store.models.contains { $0.providerID == "local-test" && $0.modelID == "swift-coder" })

        // 1. Create, rename, and select session
        let created = try await store.createSession(title: "Initial Session")
        #expect(store.activeSessionID == created.id)
        #expect(store.sessions.contains { $0.id == created.id })

        try await store.renameSession(created.id, title: "Renamed Live Session")
        #expect(store.activeSession?.title == "Renamed Live Session")

        // 2. Switch agent & model on live session
        let planAgent = try #require(store.agents.first { $0.id == "plan" })
        try await store.selectAgent(planAgent)
        #expect(store.selectedAgentID == "plan")

        let model = try #require(store.models.first { $0.modelID == "swift-coder" })
        try await store.selectModel(model)
        #expect(store.selectedModel?.modelID == "swift-coder")

        // 3. Admit user prompt (resume: false tests real durable admission cleanly without external network LLM)
        try await store.sendPrompt("Explain OpenCodeAppStore", resume: false)
        #expect(store.messages.contains {
            if case .user(_, let text, _, _, _) = $0 { return text == "Explain OpenCodeAppStore" }
            return false
        })

        // 4. Fork session & verify separate session created
        let forked = try await store.forkSession(created.id)
        #expect(forked.id != created.id)
        #expect(store.activeSessionID == forked.id)

        // 5. Slash commands (/theme, /rename, /inspector)
        store.composerText = "/theme light"
        try await store.submitComposer()
        #expect(store.settings.themeMode == .light)
        #expect(store.resolvedPalette.isDark == false)

        store.composerText = "/rename Forked Sprint"
        try await store.submitComposer()
        #expect(store.activeSession?.title == "Forked Sprint")

        // 6. Generate real Pairing QR payload backed by /api/pair + OpenCodeUtil.QR.encode
        let pairing = try await store.generatePairingQR()
        #expect(!pairing.code.isEmpty)
        #expect(pairing.primaryLink.contains("/auth/connect/\(pairing.code)"))
        #expect(pairing.qrMatrix.count >= 21)
        #expect(pairing.qrMatrix.count == pairing.qrMatrix[0].count)
        let expectedMatrix = try QR.encode(pairing.primaryLink)
        #expect(pairing.qrMatrix == expectedMatrix)
        #expect(pairing.qrSVG?.contains("<svg") == true)

        // 7. Delete forked session
        try await store.deleteSession(forked.id)
        #expect(!store.sessions.contains { $0.id == forked.id })
        #expect(store.activeSessionID == created.id)

        await store.disconnect()
        #expect(store.connectionState == .disconnected)
    }

    @Test("Live Permission & Form creation and replies against embedded ServerRouter")
    @MainActor
    func livePermissionAndFormWorkflow() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-perm-form")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let store = OpenCodeAppStore()
        try await store.connectEmbedded(directory: dir, databasePath: ":memory:", subscribeEvents: false)
        defer {
            Task { @MainActor in await store.disconnect() }
        }

        let session = try await store.createSession(title: "Approvals Test")
        let client = try #require(store.activeClient)

        // Create a real server-side permission request on the session
        let permOut = try await client.permission.create(PermissionCreateInput(
            sessionID: session.id,
            action: "bash",
            resources: ["git status"],
            save: ["git status"],
            metadata: ["command": .string("git status")]
        ))

        // Project permission.asked event & verify session badge turns blocked
        store.applyServerEvent(OpenCodeAppTestHelper.makeEvent(
            type: "permission.asked",
            data: [
                "id": .string(permOut.id.rawValue),
                "sessionID": .string(session.id),
                "action": .string("bash"),
                "resources": .array([.string("git status")]),
                "metadata": .object(["command": .string("git status")]),
            ]
        ))
        #expect(store.activePermission?.id == permOut.id.rawValue)
        #expect(store.activeSessionStatus == .blocked(permissions: 1, forms: 0))

        let pendingPerm = try #require(store.activePermission)
        try await store.replyPermission(pendingPerm, decision: .once)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.activeSessionStatus == .idle)

        // Create a real server-side interactive form on the session
        let formFieldsJSON: JSONValue = .array([
            .object([
                "type": .string("string"),
                "key": .string("framework"),
                "title": .string("Target Framework"),
                "options": .array([
                    .object(["value": .string("swiftui"), "label": .string("SwiftUI")]),
                    .object(["value": .string("appkit"), "label": .string("AppKit")]),
                ]),
            ]),
            .object([
                "type": .string("boolean"),
                "key": .string("strict"),
                "title": .string("Enable Swift 6 Strict Concurrency"),
                "default": .bool(true),
            ]),
        ])
        let createdForm = try await client.session.form.create(SessionFormCreateInput(
            sessionID: session.id,
            title: "Project Setup",
            fields: formFieldsJSON
        ))

        await store.refreshPermissionsAndForms()
        let formItem = try #require(store.activePendingForm)
        #expect(formItem.id == createdForm.id.rawValue)
        #expect(formItem.fields.count == 2)
        #expect(store.activeSessionStatus == .blocked(permissions: 0, forms: 1))

        var answers = formItem.defaultDraftAnswers()
        answers["framework"] = .string("swiftui")
        answers["strict"] = .bool(true)
        try await store.replyForm(formItem, answer: answers)
        #expect(store.pendingForms.isEmpty)
        #expect(store.activeSessionStatus == .idle)

        await store.disconnect()
    }

    @Test("Real-time SSE stream projection of reasoning, tool lifecycle, assistant text deltas, todos & VCS")
    @MainActor
    func liveSSEStreamProjection() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-sse")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let sdk = try await OpenCode.create(
            OpenCode.CreateOptions(
                app: .init(version: "app-sse-test"),
                config: .init(directory: dir, project: false)
            )
        )
        defer { Task { await sdk.close() } }

        let created = try await sdk.session.create(SessionCreateInput(
            title: "SSE Live Projection",
            location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))
        ))
        let sid = created.id.rawValue
        let assistantMsgID = SessionMessageSchema.ID.create().rawValue

        let events: [OpenCodeEvent] = [
            OpenCodeAppTestHelper.makeEvent(type: "server.connected", data: [:]),
            OpenCodeAppTestHelper.makeEvent(type: "session.execution.started", data: ["sessionID": .string(sid)]),
            OpenCodeAppTestHelper.makeEvent(type: "session.step.started", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "agent": .string("build"),
                "model": .object(["id": .string("claude-sonnet-4-6"), "providerID": .string("anthropic")]),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.reasoning.started", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.reasoning.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
                "delta": .string("Checking workspace layout…"),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.reasoning.ended", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.tool.input.started", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "id": .string("call_1"),
                "name": .string("read"),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.tool.called", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "id": .string("call_1"),
                "name": .string("read"),
                "input": .object(["path": .string("Package.swift")]),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.tool.success", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "id": .string("call_1"),
                "content": .array([.object(["type": .string("text"), "text": .string("// swift-tools-version: 6.2")])]),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.text.started", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.text.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
                "delta": .string("Hello "),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.text.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
                "ordinal": .int(0),
                "delta": .string("from live SSE!"),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.usage.updated", data: [
                "sessionID": .string(sid),
                "cost": .double(0.0125),
                "tokens": .object(["input": .int(1200), "output": .int(350), "reasoning": .int(150)]),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "vcs.branch.updated", data: [
                "branch": .string("feat/native-swiftui"),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "todo.updated", data: [
                "sessionID": .string(sid),
                "todos": .array([
                    .object(["id": .string("t1"), "content": .string("Build native app"), "status": .string("completed")]),
                    .object(["id": .string("t2"), "content": .string("Verify tests"), "status": .string("in_progress")]),
                ]),
            ]),
            OpenCodeAppTestHelper.makeEvent(type: "session.step.ended", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string(assistantMsgID),
            ]),
        ]

        let transport = OpenCodeAppTestHelper.makeLiveSSETransport(
            forwardingTo: sdk.host.fetch,
            sseEvents: events
        )
        let store = OpenCodeAppStore()
        try await store.connectRemote(
            url: "http://opencode.local",
            credentials: .bearer(token: "live-test-token"),
            transport: transport,
            subscribeEvents: false
        )
        await store.selectSession(sid)

        // Drive the real SSE `/api/event` stream through the OpenCodeClient SSE parser
        let activeClient = try #require(store.activeClient)
        for try await event in activeClient.event.subscribe() {
            store.applyServerEvent(event)
        }

        #expect(store.sseConnected == true)
        #expect(store.gitBranch == "feat/native-swiftui")
        #expect(store.todos.count == 2)
        #expect(store.todos[0].status == .completed)
        #expect(store.todos[1].status == .inProgress)
        #expect(store.activeSessionCost == 0.0125)
        #expect(store.activeSessionTokens == 1700)

        let assistant = store.messages.first { $0.id == assistantMsgID }
        if case let .assistant(_, agent, model, parts, completed, _, _, _, _)? = assistant {
            #expect(agent == "Build")
            #expect(model == "claude-sonnet-4-6")
            #expect(completed == true)
            #expect(parts.count == 3)

            if case let .reasoning(_, text, done) = parts[0] {
                #expect(text == "Checking workspace layout…")
                #expect(done == true)
            } else {
                Issue.record("Expected reasoning part first")
            }

            if case let .tool(_, name, status, summary, _, output, _) = parts[1] {
                #expect(name == "read")
                #expect(status == .completed)
                #expect(summary == "Package.swift")
                #expect(output?.contains("swift-tools-version") == true)
            } else {
                Issue.record("Expected completed tool part second")
            }

            if case let .text(_, text) = parts[2] {
                #expect(text == "Hello from live SSE!")
            } else {
                Issue.record("Expected accumulated assistant text delta part third")
            }
        } else {
            Issue.record("Expected assistant message projected from live SSE stream")
        }

        await store.disconnect()
    }

    @Test("Remote connection enforces Basic Auth and pairAndConnect exchanges pairing code for Bearer session on real ServerRouter")
    @MainActor
    func remoteAuthAndPairingHandshake() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-remote")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let handle = try await OpenCodeAppTestHelper.makeAuthenticatedServerHandle(
            password: "super-secret-password",
            version: "remote-auth-test",
            directory: dir
        )
        defer { Task { await handle.close() } }

        let recording = OpenCodeAppTestHelper.HeaderRecordingTransport(inner: handle.transport)
        let store = OpenCodeAppStore()

        // 1. Remote connect with Basic credentials against real password-protected ServerRouter
        try await store.connectRemote(
            url: "http://opencode.local",
            credentials: .basic(username: "opencode", password: "super-secret-password"),
            transport: recording,
            subscribeEvents: false
        )
        #expect(store.connectionState == .connected(serverVersion: "remote-auth-test", modeLabel: "Remote"))
        #expect(recording.authorizationHeaders.contains { $0.hasPrefix("Basic ") })

        // 2. Mint a real pairing code via authenticated client and complete pairAndConnect -> signed Bearer token!
        let pairing = try await store.generatePairingQR()
        #expect(!pairing.code.isEmpty)
        #expect(pairing.qrMatrix.count >= 21)

        try await store.pairAndConnect(
            serverURL: "http://opencode.local",
            code: pairing.code,
            transport: recording,
            subscribeEvents: false
        )
        #expect(store.connectionState == .connected(serverVersion: "remote-auth-test", modeLabel: "Remote"))
        #expect(recording.authorizationHeaders.contains { $0.hasPrefix("Bearer ") })

        await store.disconnect()
    }

    @Test("Command Palette executeCommand, theme mode/name bridging & provider API key connection")
    @MainActor
    func commandPaletteActionsAndThemeBridging() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-commands")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let store = OpenCodeAppStore(systemIsDark: true)
        try await store.connectEmbedded(directory: dir, databasePath: ":memory:", subscribeEvents: false)
        defer {
            Task { @MainActor in await store.disconnect() }
        }

        // Theme bridging tracks system appearance in .system mode and respects explicit light/dark toggles
        #expect(store.settings.themeMode == .system)
        #expect(store.resolvedPalette.isDark == true)
        store.updateSystemAppearance(isDark: false)
        #expect(store.resolvedPalette.isDark == false)

        await store.executeCommand(.toggleThemeMode)
        #expect(store.settings.themeMode == .dark)
        #expect(store.resolvedPalette.isDark == true)

        await store.executeCommand(.toggleThemeMode)
        #expect(store.settings.themeMode == .light)
        #expect(store.resolvedPalette.isDark == false)

        store.setThemeName("opencode2")
        #expect(store.resolvedPalette.themeName == "opencode2")

        // Command palette actions toggle UI panels & execute session actions
        await store.executeCommand(.newSession)
        #expect(store.activeSessionID != nil)

        await store.executeCommand(.showMCPInspector)
        #expect(store.settings.showInspector == true)
        #expect(store.selectedInspectorTab == .mcp)

        await store.executeCommand(.openDiffReview)
        #expect(store.isDiffReviewPresented == true)

        await store.executeCommand(.openSettings)
        #expect(store.isSettingsPresented == true)

        await store.executeCommand(.toggleShellMode)
        #expect(store.isShellMode == true)

        // Connect provider API key against live embedded server
        try await store.connectProviderAPIKey(integrationID: "anthropic", apiKey: "sk-ant-test-key-123", label: "Test Key")
        #expect(store.toast?.message.contains("anthropic") == true)

        // OpenCodeGUIPlugins registry & state machines wired onto OpenCodeAppStore
        #expect(store.guiPluginRegistry.plugins.count == 15)
        #expect(store.activeGUIPlugins.contains { $0.id == "ssh" })
        #expect(store.activeGUIPlugins.contains { $0.id == "review" })
        #expect(store.activeGUIPlugins.contains { $0.id == "pairing" })

        await store.disconnect()
    }
}

@Suite("OpenCodeAppStore Database Resolution & Interactive OAuth")
struct OpenCodeAppOAuthAndDatabaseTests {
    @Test("resolveDefaultDatabasePath honors OPENCODE_DB, release/local channels, and opencode.db fallback without touching user home")
    func databasePathResolutionRules() {
        let fakeData = "/tmp/opencode-isolated-data"

        // 1. Explicit OPENCODE_DB (absolute, relative, and :memory:)
        let explicitAbs = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_DB": "/tmp/custom-dir/my.db"]),
            fileExists: { _ in false }
        )
        #expect(explicitAbs == "/tmp/custom-dir/my.db")

        let explicitRel = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_DB": "custom.db"]),
            fileExists: { _ in false }
        )
        #expect(explicitRel == "\(fakeData)/custom.db")

        let explicitMem = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_DB": ":memory:"]),
            fileExists: { _ in false }
        )
        #expect(explicitMem == ":memory:")

        // 2. Standard release channels & OPENCODE_DISABLE_CHANNEL_DB -> opencode.db
        for releaseChannel in ["latest", "dev", "beta", "next", "prod", "release"] {
            let resolved = OpenCodeAppStore.resolveDefaultDatabasePath(
                dataDirectory: fakeData,
                environment: DictionaryEnvironment(variables: ["OPENCODE_CHANNEL": releaseChannel]),
                fileExists: { _ in false }
            )
            #expect(resolved == "\(fakeData)/opencode.db")
        }

        let disabledChannel = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: [
                "OPENCODE_CHANNEL": "local",
                "OPENCODE_DISABLE_CHANNEL_DB": "1",
            ]),
            fileExists: { _ in false }
        )
        #expect(disabledChannel == "\(fakeData)/opencode.db")

        // 3. Default / local channel when neither file exists -> opencode-local.db
        let freshLocal = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: [:]),
            fileExists: { _ in false }
        )
        #expect(freshLocal == "\(fakeData)/opencode-local.db")

        // 4. Local channel falls back to existing opencode.db when opencode-local.db does not exist
        let fallbackToRelease = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_CHANNEL": "local"]),
            fileExists: { path in path == "\(fakeData)/opencode.db" }
        )
        #expect(fallbackToRelease == "\(fakeData)/opencode.db")

        // 5. Local channel stays on opencode-local.db when opencode-local.db already exists alongside opencode.db
        let preferExistingLocal = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_CHANNEL": "local"]),
            fileExists: { path in
                path == "\(fakeData)/opencode.db" || path == "\(fakeData)/opencode-local.db"
            }
        )
        #expect(preferExistingLocal == "\(fakeData)/opencode-local.db")

        // 6. Custom channel sanitization
        let sanitizedChannel = OpenCodeAppStore.resolveDefaultDatabasePath(
            dataDirectory: fakeData,
            environment: DictionaryEnvironment(variables: ["OPENCODE_CHANNEL": "feat/swift app"]),
            fileExists: { _ in false }
        )
        #expect(sanitizedChannel == "\(fakeData)/opencode-feat-swift-app.db")

        // 7. Resolves under Global.make(environment:).data when dataDirectory is nil (isolated XDG_DATA_HOME)
        let isolatedEnv = DictionaryEnvironment(
            variables: ["XDG_DATA_HOME": "/tmp/opencode-xdg-isolated", "OPENCODE_CHANNEL": "latest"],
            homeDirectory: "/tmp/opencode-home-isolated"
        )
        let expectedGlobalData = Global.make(environment: isolatedEnv).data
        let resolvedFromGlobal = OpenCodeAppStore.resolveDefaultDatabasePath(
            environment: isolatedEnv,
            fileExists: { _ in false }
        )
        #expect(resolvedFromGlobal == "\(expectedGlobalData)/opencode.db")
    }

    @Test("connectEmbedded persists sessions across restarts when given an isolated on-disk temp SQLite databasePath")
    @MainActor
    func onDiskDatabasePersistenceIsolatedTempPath() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-diskdb")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }
        let dbFile = "\(dir)/data/opencode-test.db"

        let firstStore = OpenCodeAppStore()
        try await firstStore.connectEmbedded(
            directory: dir,
            databasePath: dbFile,
            subscribeEvents: false
        )
        #expect(firstStore.activeDatabasePath == dbFile)
        let created = try await firstStore.createSession(title: "Persisted On-Disk Session")
        await firstStore.disconnect()
        #expect(firstStore.activeDatabasePath == nil)

        // Boot a second store pointing at the exact same isolated temp SQLite database file
        let secondStore = OpenCodeAppStore()
        try await secondStore.connectEmbedded(
            directory: dir,
            databasePath: dbFile,
            subscribeEvents: false
        )
        defer {
            Task { @MainActor in await secondStore.disconnect() }
        }
        #expect(secondStore.activeDatabasePath == dbFile)
        #expect(secondStore.sessions.contains { $0.id == created.id && $0.title == "Persisted On-Disk Session" })
        await secondStore.disconnect()
    }

    private static func jsonResponse<T: Encodable>(_ value: T, statusCode: Int = 200) throws -> HTTPResponse {
        let text = try ClientCodec.encodeString(value)
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": "application/json"]),
            body: Array(text.utf8)
        )
    }

    @Test("OAuth start -> URL open hook -> polling -> completion -> live model refresh, failure & cancel")
    @MainActor
    func oauthStartURLOpenPollingCompletionAndLiveModelRefresh() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-oauth-poll")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let sdk = try await OpenCode.create(
            OpenCode.CreateOptions(
                app: .init(version: "oauth-poll-test"),
                database: CoreDatabaseStore.Options(path: ":memory:"),
                config: .init(directory: dir, project: false)
            )
        )
        defer { Task { await sdk.close() } }

        struct MockOAuthServerState: Sendable {
            var pollCount = 0
            var failNextAttempt = false
            var connected = false
            var reloadCalls = 0
            var cancelledAttemptIDs: [String] = []
            var startedPayloads: [String] = []
        }

        let serverState = Mutex(MockOAuthServerState())
        let locationRef = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: dir))

        let transport = MockHTTPTransport { request in
            let path = request.url.split(separator: "?").first.map(String.init) ?? request.url

            let method = request.method.uppercased()

            if method == "POST" && path.hasSuffix("/api/location/reload") {
                serverState.withLock { $0.reloadCalls += 1 }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }

            if method == "GET" && path.hasSuffix("/api/integration") {
                let isConnected = serverState.withLock { $0.connected }
                let connections: [ConnectionSchema.Info] = isConnected
                    ? [.credential(ConnectionSchema.CredentialInfo(
                        id: CredentialSchema.ID(rawValue: "cred_copilot_1"),
                        label: "GitHub Copilot",
                        method: .oauth
                    ))]
                    : []
                let copilotForm = FormSchema.Fields([
                    .string(FormSchema.StringField(
                        key: "deployment",
                        title: "Deployment",
                        defaultValue: "github.com",
                        options: [
                            FormSchema.Option(value: "github.com", label: "GitHub.com"),
                            FormSchema.Option(value: "enterprise", label: "GitHub Enterprise"),
                        ]
                    )),
                ])
                let list: [IntegrationSchema.Info] = [
                    IntegrationSchema.Info(
                        id: IntegrationID(rawValue: "opencode"),
                        name: "OpenCode Console",
                        methods: [
                            .oauth(IntegrationSchema.OAuthMethod(
                                id: IntegrationMethodID(rawValue: "console"),
                                label: "OpenCode Console account"
                            )),
                            .key(IntegrationSchema.KeyMethod(label: "API key")),
                        ],
                        connections: []
                    ),
                    IntegrationSchema.Info(
                        id: IntegrationID(rawValue: "github-copilot"),
                        name: "GitHub Copilot",
                        methods: [
                            .oauth(IntegrationSchema.OAuthMethod(
                                id: IntegrationMethodID(rawValue: "copilot-oauth"),
                                label: "Login with GitHub Copilot",
                                form: copilotForm
                            )),
                            .external(IntegrationSchema.ExternalMethod(
                                id: IntegrationMethodID(rawValue: "gh-cli"),
                                label: "GitHub CLI"
                            )),
                        ],
                        connections: connections
                    ),
                ]
                return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: list))
            }

            if method == "POST" && path.hasSuffix("/api/integration/github-copilot/connect/oauth") {
                let bodyText = String(decoding: request.body ?? [], as: UTF8.self)
                let attemptID: String = serverState.withLock { s in
                    s.startedPayloads.append(bodyText)
                    s.pollCount = 0
                    return s.failNextAttempt ? "att_copilot_fail" : "att_copilot_ok"
                }
                let attempt = IntegrationSchema.Attempt(
                    attemptID: IntegrationSchema.AttemptID(rawValue: attemptID),
                    url: "https://github.com/login/device",
                    instructions: "Open https://github.com/login/device and enter code WDJB-MJHT to connect GitHub Copilot.",
                    mode: .auto,
                    paste: true,
                    time: IntegrationSchema.AttemptTime(created: 1_000, expires: 301_000)
                )
                return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: attempt))
            }

            if method == "GET" && path.contains("/api/integration/github-copilot/connect/oauth/") {
                let attemptID = path.split(separator: "/").last.map(String.init) ?? ""
                let time = IntegrationSchema.AttemptTime(created: 1_000, expires: 301_000)
                if attemptID == "att_copilot_fail" {
                    let status = IntegrationSchema.AttemptStatus.failed(message: "Access denied by user", time: time)
                    return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: status))
                }
                let step = serverState.withLock { s -> Int in
                    s.pollCount += 1
                    if s.pollCount >= 2 {
                        s.connected = true
                    }
                    return s.pollCount
                }
                let status: IntegrationSchema.AttemptStatus = step >= 2 ? .complete(time: time) : .pending(time: time)
                return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: status))
            }

            if method == "DELETE" && path.contains("/api/integration/github-copilot/connect/oauth/") {
                let attemptID = path.split(separator: "/").last.map(String.init) ?? ""
                serverState.withLock { $0.cancelledAttemptIDs.append(attemptID) }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204), body: [])
            }

            if method == "GET" && path.hasSuffix("/api/provider") {
                let isConnected = serverState.withLock { $0.connected }
                let providers: [ProviderSchema.Info] = isConnected
                    ? [ProviderSchema.Info(
                        id: ProviderSchema.ID(rawValue: "github-copilot"),
                        integrationID: IntegrationID(rawValue: "github-copilot"),
                        name: "GitHub Copilot",
                        activation: .auto,
                        package: "@opencode/ai/providers/openai-compatible"
                    )]
                    : []
                return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: providers))
            }

            if method == "GET" && path.hasSuffix("/api/model") {
                let isConnected = serverState.withLock { $0.connected }
                let models: [ModelSchema.Info] = isConnected
                    ? [
                        ModelSchema.Info.default(
                            providerID: ProviderSchema.ID(rawValue: "github-copilot"),
                            id: ModelSchema.ID(rawValue: "gpt-5.4")
                        ),
                    ]
                    : []
                return try Self.jsonResponse(LocationSchema.response(location: locationRef, data: models))
            }

            return try await sdk.host.fetch.send(request)
        }

        var openedURLs: [String] = []
        let store = OpenCodeAppStore(
            oauthPollInterval: .milliseconds(15),
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )
        try await store.connectRemote(
            url: "http://opencode.local",
            transport: transport,
            subscribeEvents: false
        )

        // Verify auth methods metadata is retained for ConnectProviderSheet
        let copilotMethods = store.authMethods(for: "github-copilot")
        #expect(copilotMethods.count == 2)
        #expect(store.models.isEmpty)

        // 1. Start OAuth -> opens URL via injectable urlOpener -> populates activeOAuthAttempt -> polls to .complete -> reloads & refreshes models!
        let attempt = try await store.startOAuth(
            integrationID: "github-copilot",
            methodID: "copilot-oauth",
            answer: ["deployment": .string("github.com")],
            label: "Work Copilot"
        )
        #expect(openedURLs == ["https://github.com/login/device"])
        #expect(attempt.integrationID == "github-copilot")
        #expect(attempt.integrationName == "GitHub Copilot")
        #expect(attempt.methodID == "copilot-oauth")
        #expect(attempt.attemptID == "att_copilot_ok")
        #expect(attempt.mode == .auto)
        #expect(attempt.supportsPaste == true)
        #expect(attempt.isPolling == true)
        #expect(attempt.extractedDeviceCode == "WDJB-MJHT")
        #expect(AppOAuthAttempt.extractDeviceCode(from: "Enter code: ABCD-12345") == "ABCD-12345")
        #expect(AppOAuthAttempt.extractDeviceCode(from: "Open https://accounts.x.ai/device on any device and enter code: A1B2C3D4") == "A1B2C3D4")
        #expect(AppOAuthAttempt.extractDeviceCode(from: "Complete authorization in your browser. This window will close automatically.") == nil)
        #expect(store.activeOAuthAttempt?.attemptID == "att_copilot_ok")
        let startedPayload = serverState.withLock { $0.startedPayloads.first ?? "" }
        #expect(startedPayload.contains("copilot-oauth"))
        #expect(startedPayload.contains("github.com"))

        // Wait for polling (.pending -> .complete) to finish and refresh live models
        for _ in 0..<100 where store.activeOAuthAttempt != nil {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.activeOAuthAttempt == nil)
        #expect(store.models.contains { $0.providerID == "github-copilot" && $0.modelID == "gpt-5.4" })
        #expect(store.integrations.first { $0.id == "github-copilot" }?.isConnected == true)
        #expect(store.toast?.message.contains("GitHub Copilot") == true)
        #expect(store.toast?.isError == false)
        #expect(serverState.withLock { $0.reloadCalls } >= 1)

        // 2. Explicit refreshLiveModels() triggers POST /api/location/reload and refreshes catalogs
        let reloadsBefore = serverState.withLock { $0.reloadCalls }
        await store.refreshLiveModels()
        #expect(serverState.withLock { $0.reloadCalls } == reloadsBefore + 1)
        #expect(store.toast?.message.contains("1 models") == true)

        // 3. Polling failure surfaces errorMessage and stops polling
        serverState.withLock { $0.failNextAttempt = true }
        let failedAttempt = try await store.startOAuth(
            integrationID: "github-copilot",
            methodID: "copilot-oauth"
        )
        #expect(failedAttempt.attemptID == "att_copilot_fail")
        for _ in 0..<100 where store.activeOAuthAttempt?.isPolling == true {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.activeOAuthAttempt?.isPolling == false)
        #expect(store.activeOAuthAttempt?.errorMessage == "Access denied by user")
        #expect(store.toast?.isError == true)

        // 4. Cancel active OAuth sends DELETE and clears activeOAuthAttempt
        await store.cancelOAuth()
        #expect(store.activeOAuthAttempt == nil)
        #expect(serverState.withLock { $0.cancelledAttemptIDs }.contains("att_copilot_fail"))

        await store.disconnect()
    }

    @Test("Manual OAuth code completion against live embedded OpenCodeSDK stores credential and refreshes integrations")
    @MainActor
    func manualOAuthCodeCompletionAgainstEmbeddedServer() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-oauth-manual")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        var openedURLs: [String] = []
        let store = OpenCodeAppStore(
            oauthPollInterval: .seconds(60),
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )
        try await store.connectEmbedded(
            directory: dir,
            databasePath: ":memory:",
            subscribeEvents: false
        )
        defer {
            Task { @MainActor in await store.disconnect() }
        }

        // Calling completeOAuth with no active attempt fails cleanly
        do {
            try await store.completeOAuth(code: "orphan-code")
            Issue.record("Expected noActiveOAuthAttempt error")
        } catch let error as OpenCodeAppStoreError {
            #expect(error == .noActiveOAuthAttempt)
        }

        // Start a real OAuth attempt on the embedded ServerRouter
        let attempt = try await store.startOAuth(
            integrationID: "anthropic",
            methodID: "oauth-code",
            label: "Manual OAuth Test"
        )
        #expect(openedURLs == [attempt.url])
        #expect(attempt.mode == .code)
        #expect(store.activeOAuthAttempt?.attemptID == attempt.attemptID)

        // Whitespace-only code is rejected without clearing the attempt
        do {
            try await store.completeOAuth(code: "   ")
            Issue.record("Expected emptyInput error")
        } catch let error as OpenCodeAppStoreError {
            #expect(error == .emptyInput)
        }
        #expect(store.activeOAuthAttempt?.attemptID == attempt.attemptID)

        // Submit manual authorization code -> completes on real embedded server, saves credential, refreshes integrations
        try await store.completeOAuth(code: "manual-oauth-code-12345")
        #expect(store.activeOAuthAttempt == nil)
        #expect(store.integrations.first { $0.id == "anthropic" }?.isConnected == true)
        #expect(store.toast?.isError == false)
        #expect(store.toast?.message.contains("Connected") == true)

        await store.disconnect()
    }

    @Test("refreshMessages reverses desc pages chronologically and reconciles active running status")
    @MainActor
    func refreshMessagesChronologicalOrderAndActiveStatusReconciliation() async throws {
        let dir = try OpenCodeAppTestHelper.makeTempDirectory(prefix: "opencode-app-chron")
        defer { OpenCodeAppTestHelper.removeDirectory(dir) }

        let sdk = try await OpenCode.create(
            OpenCode.CreateOptions(
                app: .init(version: "app-chron-test"),
                database: CoreDatabaseStore.Options(path: ":memory:"),
                config: .init(directory: dir, project: false)
            )
        )
        defer {
            Task { await sdk.close() }
        }

        let capturedMsgURL = Mutex<String?>(nil)
        let capturedListURL = Mutex<String?>(nil)
        let modelRef = SessionSchema.ModelRef(id: "claude-sonnet-4-5", providerID: "anthropic")
        let descMessages: [SessionMessageSchema.Info] = [
            .assistant(SessionMessageSchema.Assistant(
                id: try #require(SessionMessageSchema.ID(rawValue: "msg_a2")),
                agent: "build",
                model: modelRef,
                content: [.text(SessionMessageSchema.AssistantText(text: "Second reply"))],
                cost: 0.02,
                tokens: SessionSchema.TokenUsage(input: 5000, output: 500, reasoning: 0, cache: .init(read: 0, write: 0)),
                time: .init(created: 4000, completed: 4500)
            )),
            .user(SessionMessageSchema.User(
                id: try #require(SessionMessageSchema.ID(rawValue: "msg_u2")),
                time: .init(created: 3000),
                text: "Second prompt"
            )),
            .assistant(SessionMessageSchema.Assistant(
                id: try #require(SessionMessageSchema.ID(rawValue: "msg_a1")),
                agent: "build",
                model: modelRef,
                content: [.text(SessionMessageSchema.AssistantText(text: "First reply"))],
                cost: 0.01,
                tokens: SessionSchema.TokenUsage(input: 1000, output: 100, reasoning: 0, cache: .init(read: 0, write: 0)),
                time: .init(created: 2000, completed: 2500)
            )),
            .user(SessionMessageSchema.User(
                id: try #require(SessionMessageSchema.ID(rawValue: "msg_u1")),
                time: .init(created: 1000),
                text: "First prompt"
            )),
        ]
        struct SessionEnvelope: Encodable { let data: SessionSchema.Info }
        let sessionInfo = SessionSchema.Info(
            id: try #require(SessionID(rawValue: "ses_app_chron")),
            projectID: ProjectID(rawValue: "global"),
            cost: 0.03,
            tokens: SessionSchema.TokenUsage(input: 6000, output: 600, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: .init(created: 1000, updated: 4500),
            title: "App Chronological Test",
            location: OpenCodeLocation(directory: dir)
        )

        let transport = MockHTTPTransport { request in
            let path = request.url.split(separator: "?").first.map(String.init) ?? request.url
            if request.method == "GET" && path.hasSuffix("/api/session/ses_app_chron/message") {
                capturedMsgURL.withLock { $0 = request.url }
                return try Self.jsonResponse(SessionMessagesResponse(data: descMessages))
            }
            if request.method == "GET" && path.hasSuffix("/api/session/active") {
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(#"{"data":{}}"#.utf8)
                )
            }
            if request.method == "GET" && path.hasSuffix("/api/session/ses_app_chron") {
                return try Self.jsonResponse(SessionEnvelope(data: sessionInfo))
            }
            if request.method == "GET" && path.hasSuffix("/api/session") {
                capturedListURL.withLock { $0 = request.url }
                return try Self.jsonResponse(SessionsResponse(data: [sessionInfo]))
            }
            return try await sdk.host.fetch.send(request)
        }

        let store = OpenCodeAppStore()
        try await store.connectRemote(url: "http://opencode.local", transport: transport, subscribeEvents: false)
        // Simulate a running event before refreshing messages
        _ = store.applyServerEvent(OpenCodeEvent(
            id: "evt_run",
            type: "session.shell.started",
            data: .object(["sessionID": .string("ses_app_chron")])
        ))
        #expect(store.isActiveSessionWorking == true)

        await store.refreshMessages(for: "ses_app_chron")

        #expect(capturedMsgURL.withLock { $0 }?.contains("order=desc") == true)
        #expect(capturedListURL.withLock { $0 }?.contains("order=desc") == true)
        #expect(capturedListURL.withLock { $0 }?.contains("parentID=null") == true)
        #expect(capturedListURL.withLock { $0 }?.contains("archived=false") == true)
        // Reconciled back to idle via /api/session/active
        #expect(store.isActiveSessionWorking == false)
        // Strict oldest -> newest chronological order
        #expect(store.messages.map(\.id) == ["msg_u1", "msg_a1", "msg_u2", "msg_a2"])
        // Latest tokens read from newest assistant message (5500), not oldest (1100)
        #expect(store.activeSessionTokens == 5_500)

        await store.disconnect()
    }
}
