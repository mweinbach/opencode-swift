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
        #expect(hex(dark.background) == "#0a0a0a")
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
        try await store.connectEmbedded(directory: dir, configContent: configJSON, subscribeEvents: false)
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
        try await store.connectEmbedded(directory: dir, subscribeEvents: false)
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
        try await store.connectEmbedded(directory: dir, subscribeEvents: false)
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

        await store.disconnect()
    }
}
