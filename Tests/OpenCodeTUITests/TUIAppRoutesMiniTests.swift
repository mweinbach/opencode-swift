import Testing
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Suite 1: Config, Keybinds & V1 Migration

@Suite("TUI Config, Keybinds & V1 Compatibility")
struct TUIConfigKeybindTests {
    @Test("Keybind parsing validates known commands and rejects unrecognized keys")
    func keybindParseAndUnknownKeys() throws {
        let parsed = try TUIConfig.Keybind.parse([
            "leader": "ctrl+space",
            "session.new": "<leader>t",
            "app.debug": .disabled,
        ])
        #expect(parsed["leader"] == .item(.sequence("ctrl+space")))
        #expect(parsed["session.new"] == .item(.sequence("<leader>t")))
        #expect(parsed["app.debug"] == .disabled)
        #expect(parsed["command.palette.show"] == .item(.sequence("ctrl+p")))
        #expect(TUIConfig.Keybind.Descriptions["command.palette.show"] == "List available commands")

        let unknown = TUIConfig.Keybind.unknownKeys([
            "session.new": "<leader>n",
            "nonexistent.cmd": "ctrl+q",
        ])
        #expect(unknown == ["nonexistent.cmd"])

        do {
            _ = try TUIConfig.Keybind.parse(["bogus.key": "ctrl+k"])
            Issue.record("Expected unrecognizedKeybinds error")
        } catch {
            #expect(error == .unrecognizedKeybinds(["bogus.key"]))
        }
    }

    @Test("TUIConfig.resolve disables terminal.suspend and adds ctrl+z to input.undo when terminalSuspend is false")
    func resolveWithoutTerminalSuspend() {
        let resolved = TUIConfig.resolve(
            TUIConfig.Info(),
            options: TUIConfig.ResolveOptions(
                terminalSuspend: false,
                environment: ["HERDR_ENV": "1"]
            )
        )
        #expect(resolved.keybinds.rawKeybinds["terminal.suspend"] == .disabled)
        #expect(resolved.keybinds.rawKeybinds["input.undo"]?.stringValue == "ctrl+z,ctrl+-,super+z")
        #expect(resolved.keybinds.has("command.palette.show"))
        #expect(resolved.leaderTimeout == 2000)
        #expect(resolved.cursor == TUIConfig.ResolvedCursor(style: .block, blinking: true))
        #expect(resolved.tabs.mode == .auto)
        #expect(resolved.tabs.enabled == false) // disabled under HERDR_ENV=1
        #expect(resolved.session.newLocation == .launch)
        #expect(resolved.session.permissions == .prompt)
        #expect(resolved.session.tps == true)
    }

    @Test("V1 config resolves snake_case keybinds via CommandMap and migrates cleanly to V2")
    func v1ConfigAndKeybindMigration() throws {
        let v1Info = TUIConfig.V1.Info(
            theme: "tokyonight",
            keybinds: [
                "command_list": "ctrl+k",
                "session_new": "<leader>s",
                "messages_page_up": "ctrl+u",
            ],
            plugin: [.name("my-plugin"), .tuple(name: "configured", options: ["enabled": .bool(true)])],
            leaderTimeout: 3500,
            attention: TUIConfig.V1.Attention(enabled: true, notifications: true, sound: false, volume: 0.75),
            scrollSpeed: 2.5,
            scrollAcceleration: TUIConfig.V1.ScrollAcceleration(enabled: true),
            diffStyle: .stacked,
            mouse: false,
            cursor: TUIConfig.Cursor(style: .line, blinking: false)
        )
        let v1Resolved = TUIConfig.V1.resolve(v1Info, options: TUIConfig.V1.ResolveOptions(terminalSuspend: true))
        #expect(v1Resolved.leaderTimeout == 3500)
        #expect(v1Resolved.mouse == false)
        #expect(v1Resolved.keybinds.has("command.palette.show"))
        #expect(v1Resolved.keybinds.has("session.new"))
        #expect(v1Resolved.keybinds.has("session.page.up"))
        #expect(TUIConfig.V1.Keybind.CommandMap["command_list"] == "command.palette.show")
        #expect(TUIConfig.V1.Keybind.CommandMap["messages_page_up"] == "session.page.up")

        let migrated = v1Resolved.migrateToV2()
        #expect(migrated.theme?.name == "tokyonight")
        #expect(migrated.leader?.timeout == 3500)
        #expect(migrated.diffs?.view == "unified")
        #expect(migrated.attention?.notifications == true)
        #expect(migrated.attention?.sound == false)
        #expect(migrated.attention?.volume == 0.75)
        #expect(migrated.keybinds?["command.palette.show"] == .item(.sequence("ctrl+k")))
        #expect(migrated.keybinds?["session.new"] == .item(.sequence("<leader>s")))
        #expect(migrated.keybinds?["session.page.up"] == .item(.sequence("ctrl+u")))
        #expect(migrated.cursor == TUIConfig.Cursor(style: .line, blinking: false))

        let v2Resolved = TUIConfig.resolve(migrated)
        #expect(v2Resolved.cursor.style == .line)
        #expect(v2Resolved.cursor.blinking == false)
        #expect(v2Resolved.mouse == false)
    }

    @Test("newSessionLocation respects launch vs inherit and skips unavailable locations")
    func newSessionLocationResolution() {
        let active = LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/work/repo"))
        let launch = "/launch/dir"

        let launchResult = TUIConfig.newSessionLocation(mode: .launch, launchDirectory: launch, current: active)
        #expect(launchResult.directory.rawValue == launch)

        let inheritResult = TUIConfig.newSessionLocation(mode: .inherit, launchDirectory: launch, current: active)
        #expect(inheritResult.directory.rawValue == "/work/repo")

        let fallbackResult = TUIConfig.newSessionLocation(
            mode: .inherit,
            launchDirectory: launch,
            current: active,
            unavailable: active
        )
        #expect(fallbackResult.directory.rawValue == launch)
    }

    @Test("TUIContext.DefaultKeymapRuntime matches leader strokes and manages nested modes")
    func keymapRuntimeLeaderAndModes() {
        let config = TUIConfig.resolve(TUIConfig.Info(keybinds: ["leader": "ctrl+x"]))
        let keymap = TUIContext.DefaultKeymapRuntime(config: config.keybinds)

        #expect(keymap.isLeader(OpenTUIKeyEventAdapter(name: "x", ctrl: true)))
        #expect(!keymap.isLeader(OpenTUIKeyEventAdapter(name: "x", ctrl: false)))
        #expect(keymap.mode.current() == "base")

        let popForm = keymap.mode.push("form", nil)
        #expect(keymap.mode.current() == "form")
        let popDisabled = keymap.mode.push("composer") { false }
        #expect(keymap.mode.current() == "form")
        popDisabled()
        popForm()
        #expect(keymap.mode.current() == "base")
    }
}

// MARK: - Suite 2: Model Preferences, Attention, DevTools & App Platform

@Suite("TUI Model Preferences, Attention & Platform")
struct TUIPlatformAndModelTests {
    @Test("Model preference recent/favorite/variant resolution and repository persistence")
    func modelPreferenceResolutionAndPersistence() async throws {
        let claude = TUIModelPreference.ModelPreferenceModel(providerID: "anthropic", modelID: "claude-sonnet-4")
        let gpt = TUIModelPreference.ModelPreferenceModel(providerID: "openai", modelID: "gpt-5")

        #expect(TUIModelPreference.modelPreferenceKey(claude) == "anthropic/claude-sonnet-4")
        #expect(TUIModelPreference.normalizeModelVariant("default") == nil)
        #expect(TUIModelPreference.normalizeModelVariant("high") == "high")

        // Recent deduplication + max 10 cap
        var recent: [TUIModelPreference.ModelPreferenceModel] = []
        for i in 0..<12 {
            recent = TUIModelPreference.recentModels(
                TUIModelPreference.ModelPreferenceModel(providerID: "p", modelID: "m\(i)"),
                recent: recent
            )
        }
        #expect(recent.count == 10)
        #expect(recent.first?.modelID == "m11")
        recent = TUIModelPreference.recentModels(claude, recent: recent)
        recent = TUIModelPreference.recentModels(claude, recent: recent)
        #expect(recent.filter { $0 == claude }.count == 1)

        // Favorites toggle
        let fav1 = TUIModelPreference.favoriteModels(claude, favorite: [], enabled: true)
        let fav2 = TUIModelPreference.favoriteModels(gpt, favorite: fav1, enabled: true)
        #expect(fav2 == [gpt, claude])
        let fav3 = TUIModelPreference.favoriteModels(gpt, favorite: fav2, enabled: false)
        #expect(fav3 == [claude])

        // Variant cycling
        let variants = ["default", "low", "medium", "high"]
        #expect(TUIModelPreference.cycleModelVariant(nil, variants: variants) == "low")
        #expect(TUIModelPreference.cycleModelVariant("low", variants: variants) == "medium")
        #expect(TUIModelPreference.cycleModelVariant("high", variants: variants) == nil)

        // Decode preserves extra fields
        let raw = try TUIAppTestHelper.decodeJSON(#"""
        {
          "customFlag": true,
          "recent": [{"providerID": "anthropic", "modelID": "claude-sonnet-4"}, {"providerID": "", "modelID": "bad"}],
          "favorite": [{"providerID": "openai", "modelID": "gpt-5"}],
          "variant": {"anthropic/claude-sonnet-4": "high", "openai/gpt-5": "default"}
        }
        """#)
        let doc = TUIModelPreference.decodeModelPreference(raw)
        #expect(doc.recent == [claude])
        #expect(doc.favorite == [gpt])
        #expect(doc.variant["anthropic/claude-sonnet-4"] == "high")
        #expect(doc.variant["openai/gpt-5"] == "default")
        #expect(doc.extra["customFlag"] == .bool(true))

        // Mini variant priority: CLI input > session > saved
        #expect(TUIMini.resolveVariant(input: "max", session: "high", saved: "low", variants: ["low", "high", "max"]) == "max")
        #expect(TUIMini.resolveVariant(input: nil, session: "high", saved: "low", variants: ["low", "high"]) == "high")
        #expect(TUIMini.resolveVariant(input: nil, session: "stale", saved: "low", variants: ["low", "high"]) == "low")
        #expect(TUIMini.resolveVariant(input: "default", session: "high", saved: "low", variants: ["low", "high"]) == nil)

        // Repository persistence using InMemoryFileSystem + temp lock dir
        let dir = try TUIAppTestHelper.tempDirectory(prefix: "tui-model-pref")
        defer { TUIAppTestHelper.removePath(dir) }
        let memFS = InMemoryFileSystem()
        let repo = TUIModelPreference.createModelPreferenceRepository("\(dir)/model.json", fs: memFS)
        try await repo.addRecent(claude)
        try await repo.setFavorite(gpt, enabled: true)
        try await repo.saveVariant(claude, value: "high")
        let loaded = await repo.load()
        #expect(loaded.recent == [claude])
        #expect(loaded.favorite == [gpt])
        #expect(await repo.resolveVariant(for: claude) == "high")
    }

    @Test("Attention respects focus transitions, ANSI normalization, and sound fallback")
    func attentionFocusAndNormalization() async {
        final class MockAttentionRenderer: TUIAttention.AttentionRenderer, @unchecked Sendable {
            var isDestroyed = false
            let focusListeners = Mutex<[@Sendable () -> Void]>([])
            let blurListeners = Mutex<[@Sendable () -> Void]>([])
            let notifications = Mutex<[(message: String, title: String?)]>([])

            func addFocusListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
                focusListeners.withLock { $0.append(listener) }
                return {}
            }
            func addBlurListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
                blurListeners.withLock { $0.append(listener) }
                return {}
            }
            func triggerNotification(_ message: String, title: String?) -> Bool {
                notifications.withLock { $0.append((message, title)) }
                return true
            }
            func emitBlur() { for fn in blurListeners.withLock({ $0 }) { fn() } }
            func emitFocus() { for fn in focusListeners.withLock({ $0 }) { fn() } }
        }

        let mock = MockAttentionRenderer()
        let cfg = TUIConfig.ResolvedAttention(notifications: true, sound: false, volume: 0.5)
        let host = TUIAttention.createTuiAttention(renderer: mock, config: cfg)

        // Focus unknown initially -> skipped for default "blurred"
        let r1 = await host.notify(PluginTui.AttentionNotifyOptions(message: "Task done"))
        #expect(r1.ok == false)
        #expect(r1.skipped == .focusUnknown)

        // Blur -> notification delivers with ANSI stripped & whitespace collapsed
        mock.emitBlur()
        let r2 = await host.notify(PluginTui.AttentionNotifyOptions(title: "  Build\nStatus ", message: "\u{1B}[31mDone\u{1B}[0m\nnow"))
        #expect(r2.ok == true)
        #expect(r2.notification == true)
        let delivered = mock.notifications.withLock { $0 }
        #expect(delivered.count == 1)
        #expect(delivered[0].title == "Build Status")
        #expect(delivered[0].message == "Done now")

        // Focused -> skipped
        mock.emitFocus()
        let r3 = await host.notify(PluginTui.AttentionNotifyOptions(message: "Still focused"))
        #expect(r3.skipped == .focused)

        host.dispose()
        let r4 = await host.notify(PluginTui.AttentionNotifyOptions(message: "After dispose"))
        #expect(r4.skipped == .rendererDestroyed)
    }

    @Test("ProgramStatus OSC 7501 reports aggregate blocked/working/idle sessions and hash long IDs")
    func programStatusReportsTest() {
        let idle = TUIContext.programStatusReports([])
        #expect(idle[""]?.state == .idle)
        #expect(idle[""]?.app == "opencode")

        let longID = "ses_" + String(repeating: "a", count: 40)
        let reports = TUIContext.programStatusReports([
            TUIContext.PendingSession(id: "ses_short", title: "Short\nTitle", state: .working),
            TUIContext.PendingSession(id: longID, title: "Blocked", state: .blocked(kind: .permission, message: "Approve shell")),
        ])
        #expect(reports[""]?.state == .blocked)
        #expect(reports[""]?.kind == .permission)
        #expect(reports["ses_short"]?.title == "Short Title")
        #expect(reports.keys.contains(where: { $0.hasPrefix("ses_") && $0.count == 20 }))
    }

    @Test("SessionTabsModel handles open, close, reopen, move, cycle, history, and adaptive layout")
    func sessionTabsModelOperations() {
        var tabs: [TUIContext.SessionTab] = []
        tabs = TUIContext.openSessionTab(tabs, .init(sessionID: "s1", title: "Alpha"))
        tabs = TUIContext.openSessionTab(tabs, .init(sessionID: "s2", title: "Beta"))
        tabs = TUIContext.openSessionTab(tabs, .init(sessionID: "s3", title: "Gamma"))
        #expect(tabs.count == 3)

        // Move s3 to index 0
        tabs = TUIContext.moveSessionTab(tabs, sessionID: "s3", index: 0)
        #expect(tabs.map(\.sessionID) == ["s3", "s1", "s2"])

        // Cycle forward and backward
        #expect(TUIContext.cycleSessionTab(tabs, active: "s3", direction: 1)?.sessionID == "s1")
        #expect(TUIContext.cycleSessionTab(tabs, active: "s3", direction: -1)?.sessionID == "s2")

        // Close & reopen stack
        let closed = TUIContext.closeSessionTab(tabs, sessionID: "s1")
        #expect(closed.tabs.map(\.sessionID) == ["s3", "s2"])
        #expect(closed.next == "s2")
        let stack = TUIContext.recordClosedSessionTab([], tab: .init(sessionID: "s1", title: "Alpha"), index: 1)
        let reopened = TUIContext.reopenSessionTab(stack, tabs: closed.tabs)
        #expect(reopened.sessionID == "s1")
        #expect(reopened.tabs?.map(\.sessionID) == ["s3", "s1", "s2"])

        // Navigation history
        var history = TUIContext.SessionTabHistory()
        history = TUIContext.recordSessionTabHistory(history, sessionID: "s3")
        history = TUIContext.recordSessionTabHistory(history, sessionID: "s1")
        history = TUIContext.recordSessionTabHistory(history, sessionID: "s2")
        let back = TUIContext.moveSessionTabHistory(history, tabs: tabs, active: "s2", direction: -1)
        #expect(back.sessionID == "s1")

        // Adaptive layout under tight width
        let layout = TUIContext.adaptiveSessionTabLayout(tabs: tabs, active: "s2", available: 38)
        #expect(layout.tabs.contains(where: { $0.sessionID == "s2" }))
        #expect(layout.widths.reduce(0, +) <= 38)
    }

    @Test("TUIApp.run bootstraps config and initial route cleanly")
    func appRunBootstrap() async throws {
        let cfgService = TUIConfig.InMemoryConfigService(initial: TUIConfig.Info(mouse: false))
        let result = try await TUIApp.run(TUIApp.TuiInput(
            app: TUIContext.TuiApp(name: "opencode", version: "2.0.0", channel: "dev"),
            server: TUIApp.ServerEndpointConfig(baseUrl: "http://127.0.0.1:4096"),
            args: TUIContext.Args(sessionID: "ses_123"),
            config: cfgService
        ))
        #expect(result.resolvedConfig.mouse == false)
        #expect(result.initialRoute == .session(TUIContext.SessionRoute(sessionID: "ses_123")))
    }
}

// MARK: - Suite 3: Prompt History, Stash, Frecency, Mentions & Autocomplete

@Suite("TUI Prompt Composer, History, Stash, Frecency & Autocomplete")
struct TUIPromptTests {
    @Test("Prompt history navigation saves draft, deduplicates, and parses JSONL")
    func promptHistoryNavigationAndJSONL() throws {
        let p1 = TUIPrompt.PromptInfo(text: "Explain Package.swift")
        let p2 = TUIPrompt.PromptInfo(text: "Run parity audit")
        let jsonl = try TUIAppTestHelper.encodePromptJSONL([p1, p2]) + "\n{corrupt json}\n"
        let parsed = TUIPrompt.parsePromptHistory(jsonl)
        #expect(parsed == [p1, p2])

        let ctrl = TUIPrompt.usePromptHistory(initial: parsed)
        ctrl.append(p2) // duplicate ignored
        #expect(ctrl.entries.count == 2)

        let back1 = ctrl.move(direction: -1, input: "my draft")
        #expect(back1?.text == "Run parity audit")
        let back2 = ctrl.move(direction: -1, input: "Run parity audit")
        #expect(back2?.text == "Explain Package.swift")
        let fwd1 = ctrl.move(direction: 1, input: "Explain Package.swift")
        #expect(fwd1?.text == "Run parity audit")
        let restored = ctrl.move(direction: 1, input: "Run parity audit")
        #expect(restored?.text == "my draft")
    }

    @Test("Prompt stash push, pop, remove, and JSONL parsing")
    func promptStashLifecycle() throws {
        let entry1 = TUIPrompt.StashEntry(prompt: TUIPrompt.PromptInfo(text: "WIP refactor"), timestamp: 1000)
        let entry2 = TUIPrompt.StashEntry(prompt: TUIPrompt.PromptInfo(text: "Second draft"), timestamp: 2000)
        let jsonl = try TUIAppTestHelper.encodeStashJSONL([entry1, entry2])
        let parsed = TUIPrompt.parsePromptStash(jsonl)
        #expect(parsed == [entry1, entry2])

        let store = TUIPrompt.PromptStashStore(initial: parsed)
        #expect(store.list().count == 2)
        let popped = store.pop()
        #expect(popped?.prompt.text == "Second draft")
        #expect(store.list().count == 1)
        store.push(TUIPrompt.PromptInfo(text: "Third"), timestamp: 3000)
        store.remove(at: 0)
        #expect(store.list().map(\.prompt.text) == ["Third"])
    }

    @Test("Frecency scoring parses JSONL and weights recent + frequent files higher")
    func frecencyScoring() throws {
        let now: Int64 = 10_000_000_000
        let dayMs: Int64 = 86_400_000
        let raw = try TUIAppTestHelper.encodeFrecencyJSONL([
            TUIPrompt.FrecencyEntry(path: "/repo/old.swift", frequency: 5, lastOpen: now - 10 * dayMs),
            TUIPrompt.FrecencyEntry(path: "/repo/hot.swift", frequency: 5, lastOpen: now),
        ])
        let entries = TUIPrompt.parseFrecency(raw)
        #expect(entries.first?.path == "/repo/hot.swift")

        let store = TUIPrompt.FrecencyStore(cwd: "/repo", initial: entries)
        let hotScore = store.getFrecency("hot.swift", nowMs: now)
        let oldScore = store.getFrecency("old.swift", nowMs: now)
        #expect(hotScore > oldScore)
        store.updateFrecency("hot.swift", nowMs: now)
        #expect(store.getFrecency("hot.swift", nowMs: now) > hotScore)
    }

    @Test("Mention realignment, paste expansion, attachment labels, and directory autocomplete")
    func mentionsPasteAttachmentsAndAutocomplete() async throws {
        // Line range & slash parsing
        let range = TUIPrompt.parseFileLineRange("Sources/App.swift#10-25")
        #expect(range.base == "Sources/App.swift")
        #expect(range.lineRange == TUIPrompt.FileLineRange(startLine: 10, endLine: 25))
        #expect(TUIPrompt.stripFileLineRange("Sources/App.swift#10-25") == "Sources/App.swift")
        let slash = TUIPrompt.parseSlashHead("/cd ~/projects/app")
        #expect(slash?.name == "cd")
        #expect(slash?.arguments == "~/projects/app")

        // Trigger detection
        #expect(TUIPrompt.mentionTriggerIndex("hello @src/main") == 6)
        #expect(TUIPrompt.mentionTriggerIndex("user@example.com") == nil)
        #expect(TUIPrompt.slashTriggerIndex("/compact") == 0)
        #expect(TUIPrompt.slashTriggerIndex("foo /bar") == 4)

        // Mention realignment after prefix edit
        let original = PromptSchema.PromptMention(start: 6, end: 15, text: "@App.swift")
        let realigned = TUIPrompt.realignPromptMentions("please check @App.swift now", mentions: [original])
        #expect(realigned.first??.start == 13)
        #expect(realigned.first??.end == 23)

        // Paste expansion shifts mentions
        let expanded = TUIPrompt.expandPastedTextPlaceholders(
            "See [Pasted 1] end",
            pasted: [TUIPrompt.PastedText(text: "LINE1\nLINE2", source: .init(start: 4, end: 14, text: "[Pasted 1]"))]
        )
        #expect(expanded == "See LINE1\nLINE2 end")

        // Attachment labeling & dedup
        let img1 = PromptInputSchema.FileAttachment(
            uri: "data:image/png;base64,AAAA",
            mention: PromptSchema.PromptMention(start: 0, end: 9, text: "[Image 1]")
        )
        #expect(try TUIPrompt.promptAttachmentLabel([img1], uri: "data:image/png;base64,AAAA") == "[Image 1]")
        #expect(try TUIPrompt.promptAttachmentLabel([img1], uri: "data:image/png;base64,BBBB") == "[Image 2]")
        let deduped = TUIPrompt.deduplicatePromptImages([img1, img1])
        #expect(deduped?.count == 1)

        // Directory autocomplete
        let search = TUIPrompt.directoryAutocompleteSearch("~/src/op", directory: "/repo", home: "/Users/me")
        #expect(search.directory == "/Users/me/src")
        #expect(search.prefix == "~/src/")
        #expect(search.query == "op")
        #expect(TUIPrompt.directoryAutocompleteMatches("opencode", query: "op") == true)
        #expect(TUIPrompt.directoryAutocompleteMatches(".git", query: "") == false)
        #expect(TUIPrompt.directoryRecentValue("/Users/me/work/app", home: "/Users/me") == "~/work/app")

        let completions = try await TUIPrompt.directoryAutocomplete(
            listDirectories: { _ in ["opencode", "opentui", ".hidden"] },
            locationDirectory: "/repo",
            query: "open",
            home: "/Users/me"
        )
        #expect(completions.map(\.value) == ["opencode/", "opentui/"])

        // Prompt traits
        let normalAuto = TUIPrompt.computePromptTraits(.init(mode: .normal, autocompleteVisible: true))
        #expect(normalAuto.capture == ["escape", "navigate", "submit", "tab"])
        let shellTraits = TUIPrompt.computePromptTraits(.init(mode: .shell, autocompleteVisible: false))
        #expect(shellTraits.status == "SHELL")
        #expect(shellTraits.capture == nil)
    }
}

// MARK: - Suite 4: Routes, Grouping, Mini State Machines & OpenTUI TestRenderer Frames

@Suite("TUI Routes, Grouping, Mini Runtime & OpenTUI TestRenderer Frames")
struct TUIRoutesAndMiniRenderTests {
    @Test("Route navigation, transcript grouping tree, and mount budget calculations")
    func routesGroupingAndMountBudget() throws {
        // RouteController navigation
        let router = TUIContext.RouteController(initial: .home(TUIContext.HomeRoute()))
        #expect(router.data.typeName == "home")
        router.navigate(.session(TUIContext.SessionRoute(sessionID: "ses_42")))
        #expect(router.data.typeName == "session")
        router.navigate(.plugin(TUIContext.PluginRoute(id: "p1", name: "storybook")))
        #expect(router.data.typeName == "plugin")
        #expect(router.navigationHistory.count == 3)

        // Transcript grouping (low verbosity wraps reasoning + exploration tools into activity group)
        var rows: [TUIRoutes.SessionRow] = []
        TUIRoutes.append(&rows, ref: .init(messageID: "m1", partID: "reasoning:0"), part: .reasoning(completedAt: 100), verbosity: .low)
        TUIRoutes.append(&rows, ref: .init(messageID: "m1", partID: "t1"), part: .tool(name: "read"), verbosity: .low)
        TUIRoutes.append(&rows, ref: .init(messageID: "m1", partID: "t2"), part: .tool(name: "grep"), verbosity: .low)
        TUIRoutes.append(&rows, ref: .init(messageID: "m1", partID: "text:0"), part: .text, verbosity: .low)
        #expect(rows.count == 2)
        if case .group(let activity) = rows[0] {
            #expect(activity.kind == .activity)
            #expect(activity.size == 3)
            #expect(activity.completed == true)
            #expect(TUIRoutes.groupRefs(activity).count == 3)
        } else {
            Issue.record("Expected leading activity group")
        }
        #expect(TUIRoutes.hasPart(rows, ref: .init(messageID: "m1", partID: "t1")))

        // Tree split and seam merge round-trip
        let grouped = TUIRoutes.groupEntries(["a", "b", "c"]) { _ in ["activity", "exploration"] }
        let (left, right) = try TUIRoutes.splitGroups(grouped, count: 2)
        let merged = TUIRoutes.mergeGroups(left, right)
        #expect(merged == grouped)

        // Mount budget
        let weights = [1, 3, 2, 1, 4]
        #expect(TUIRoutes.rowsBefore(weights, end: 5, budget: 5) == 3)
        #expect(TUIRoutes.rowsAfter(weights, start: 0, budget: 4) == 2)

        // Reasoning summary extraction
        let summary = TUIContext.reasoningSummary("**Inspecting build**\n\nChecking Package.swift targets.")
        #expect(summary.title == "Inspecting build")
        #expect(summary.body == "Checking Package.swift targets.")
        #expect(TUIContext.nextThinkingMode(.show) == .hide)
    }

    @Test("Mini runtime verbosity, fragment reconciler, permission/form machines, and statusline policy")
    func miniStateMachines() throws {
        // Verbosity presets
        var settings = TUIMini.resolveMiniSettings(nil)
        #expect(TUIMini.matchMiniVerbosity(settings) == .default)
        if let change = TUIMini.verbosityChange(settings, direction: 1) {
            settings = TUIMini.applyMiniSettingChange(settings, change)
        }
        #expect(TUIMini.matchMiniVerbosity(settings) == .everything)
        #expect(settings.shellOutput == .show)

        // Monochrome transforms
        #expect(TUIMini.monoPrefix("→ Read file", mono: true) == "-> Read file")
        #expect(TUIMini.monoToolText("patch · 12ms", mono: true) == "patch - 12ms")
        #expect(TUIMini.monoShortcut("ctrl+→", mono: true) == "ctrl+right")
        #expect(TUIMini.monoTruncate("abcdefghij", width: 7, mono: true) == "abcd...")

        // Fragment reconciler dedup & restore
        let reconciler = TUIMini.createFragmentReconciler()
        let ref = TUIMini.fragmentRef(messageID: "msg_1", kind: "text", ordinal: 0)
        _ = reconciler.project(ref, text: "Hello ", visible: true)
        #expect(reconciler.delta(ref, "Hello ") == nil) // covered by projection
        let upd = reconciler.delta(ref, "world")
        #expect(upd?.text == "Hello world")
        #expect(reconciler.restore(ref, text: "Hello world!") == .append(suffix: "!"))
        #expect(reconciler.restore(ref, text: "Hello") == .covered)
        #expect(reconciler.restore(ref, text: "Diverged") == .conflict)

        // Permission state machine
        let permReq = TUIMini.MiniPermissionRequest(
            request: PermissionSchema.Request(
                id: try PermissionSchema.ID(validating: "per_01"),
                sessionID: try SessionID(validating: "ses_01"),
                action: "shell",
                resources: ["git status"],
                save: ["git status"]
            )
        )
        var pState = TUIMini.createPermissionBodyState(permReq)
        pState = TUIMini.permissionShift(pState, dir: 1)
        #expect(pState.selected == .always)
        let step1 = TUIMini.permissionRun(pState, requestID: permReq.id, option: .always)
        #expect(step1.state.stage == .always)
        #expect(step1.reply == nil)
        let step2 = TUIMini.permissionRun(step1.state, requestID: permReq.id, option: .confirm)
        #expect(step2.reply?.decision == .always)

        // Form state machine
        let formInfo = FormSchema.Info(
            id: try FormSchema.ID(validating: "frm_01"),
            sessionID: "ses_01",
            title: "Deploy Options",
            fields: FormSchema.Fields(first: .string(FormSchema.StringField(key: "env", title: "Environment", required: true)))
        )
        var fState = TUIMini.createFormBodyState(formInfo)
        #expect(TUIMini.formValidate(formInfo, state: fState) != nil)
        fState = TUIMini.formCommitInput(fState, form: formInfo, text: "production")
        #expect(TUIMini.formValidate(formInfo, state: fState) == nil)
        let reply = TUIMini.formReply(TUIMini.MiniFormRequest(form: formInfo), state: fState)
        #expect(reply?.answer["env"] == .string("production"))

        // Footer statusline width budget
        let narrow = TUIMini.footerStatuslinePolicy(
            width: 24,
            status: (text: "thinking", expanded: nil),
            model: (name: "Claude Sonnet 4", variant: "high"),
            agent: "build",
            cost: "$0.04",
            provider: "Anthropic"
        )
        #expect(stringWidth(narrow.text) <= 24)
        #expect(narrow.text.contains("thinking"))

        let wide = TUIMini.footerStatuslinePolicy(
            width: 120,
            status: (text: "thinking", expanded: nil),
            model: (name: "Claude Sonnet 4", variant: "high"),
            agent: "build",
            cost: "$0.04",
            provider: "Anthropic"
        )
        #expect(wide.text.contains("Claude Sonnet 4 [high]"))
        #expect(wide.text.contains("$0.04"))
        #expect(wide.text.contains("Anthropic"))

        // Splash layout & prompt history
        let splash = TUIMini.entrySplashLayout(width: 60, version: "2.0.0", detail: "/Users/dev/swift-opencode")
        #expect(splash.label.contains("oc mini"))
        #expect(splash.version == "2.0.0")
        #expect(TUIMini.isExitCommand("/quit"))
        #expect(TUIMini.isNewCommand("/new"))
        #expect(TUIMini.isCompactCommand("/compact"))
    }

    @Test("OpenTUI TestRenderer renders Home, Session+Sidebar, Permission, and Mini Footer/Splash frames")
    func openTUITestRendererFrames() async throws {
        let darkTheme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)

        // 1. Home route frame
        let homeHarness = TestRenderer(options: TestRendererOptions(width: 80, height: 24))
        let homeView = TUIRoutes.Home(
            ctx: homeHarness.renderer,
            theme: darkTheme,
            promptText: "Port OpenCode TUI to Swift",
            updateNotice: "/update to install v2.1.0",
            footerText: "swift-opencode • ready"
        )
        homeHarness.root.add(homeView)
        homeHarness.renderOnce(force: true)
        let homeFrame = homeHarness.captureCharFrame()
        #expect(homeFrame.contains("Port OpenCode TUI to Swift"))
        #expect(homeFrame.contains("/update to install v2.1.0"))
        #expect(homeFrame.contains("swift-opencode"))
        homeHarness.destroy()

        // 2. Session route + Sidebar frame
        let sessionHarness = TestRenderer(options: TestRendererOptions(width: 100, height: 24))
        let userMsg = SessionMessageSchema.Info.user(SessionMessageSchema.User(
            id: try SessionMessageSchema.ID(validating: "msg_01"),
            time: SessionMessageSchema.TimeCreated(created: 1000),
            text: "Inspect build status"
        ))
        let asstMsg = SessionMessageSchema.Info.assistant(SessionMessageSchema.Assistant(
            id: try SessionMessageSchema.ID(validating: "msg_02"),
            agent: "build",
            model: SessionSchema.ModelRef(id: "claude-sonnet-4", providerID: "anthropic"),
            content: [
                .reasoning(SessionMessageSchema.AssistantReasoning(text: "**Checking targets**\n\nInspecting Package.swift")),
                .tool(SessionMessageSchema.AssistantTool(
                    id: "call_1",
                    name: "shell",
                    state: .completed(SessionMessageSchema.ToolStateCompleted(
                        input: ["command": .string("swift build")],
                        content: [.text("Build complete!")],
                        metadata: [:]
                    )),
                    time: SessionMessageSchema.AssistantTool.Time(created: 1001, ran: 1002, completed: 1005)
                )),
                .text(SessionMessageSchema.AssistantText(text: "All Swift targets compiled cleanly.")),
            ],
            finish: .stop,
            time: SessionMessageSchema.Assistant.Time(created: 1001, completed: 1010)
        ))
        let sessionView = TUIRoutes.Session(
            ctx: sessionHarness.renderer,
            sessionID: "ses_render_1",
            title: "Swift TUI Port",
            messages: [userMsg, asstMsg],
            showSidebar: true,
            promptText: "Run tests next",
            theme: darkTheme
        )
        sessionHarness.root.add(sessionView)
        sessionHarness.renderOnce(force: true)
        let sessionFrame = sessionHarness.captureCharFrame()
        #expect(sessionFrame.contains("Swift TUI Port"))
        #expect(sessionFrame.contains("Inspect build status"))
        #expect(sessionFrame.contains("Thought: Checking targets"))
        #expect(sessionFrame.contains("All Swift targets compiled cleanly."))
        #expect(sessionFrame.contains("Run tests next"))
        sessionHarness.destroy()

        // 3. PermissionPrompt frame
        let permHarness = TestRenderer(options: TestRendererOptions(width: 80, height: 12))
        let permView = TUIRoutes.PermissionPrompt(
            ctx: permHarness.renderer,
            request: PermissionSchema.Request(
                id: try PermissionSchema.ID(validating: "per_frame"),
                sessionID: try SessionID(validating: "ses_render_1"),
                action: "shell",
                resources: ["swift test"],
                save: ["swift test"]
            ),
            theme: darkTheme
        )
        permHarness.root.add(permView)
        permHarness.renderOnce(force: true)
        let permFrame = permHarness.captureCharFrame()
        #expect(permFrame.contains("Permission required"))
        #expect(permFrame.contains("swift test"))
        #expect(permFrame.contains("[Allow once]"))
        permHarness.destroy()

        // 4. Mini TUI Footer View + Demo Deferred Mode scrollback frame
        let miniHarness = TestRenderer(options: TestRendererOptions(
            width: 80,
            height: 20,
            screenMode: .splitFooter,
            footerHeight: 6
        ))
        let miniFooterView = TUIMini.RunFooterView(
            ctx: miniHarness.renderer,
            state: TUIMini.FooterState(phase: .running, status: "thinking", model: "Claude Sonnet 4"),
            view: .prompt,
            promptText: "Hello mini TUI",
            agent: "build",
            width: 80
        )
        miniHarness.root.add(miniFooterView)
        miniHarness.renderOnce(force: true)
        let miniFrame = miniHarness.captureCharFrame()
        #expect(miniFrame.contains("Hello mini TUI"))
        #expect(miniFrame.contains("thinking"))
        #expect(miniFrame.contains("Claude Sonnet 4"))

        // Run deferred mini demo end-to-end against split-footer CliRenderer
        await TUIMini.runMiniFrontend(TUIMini.MiniFrontendInput(
            host: TUIMini.MiniHost(version: "2.0.0"),
            renderer: miniHarness.renderer,
            directory: "/work/swift-opencode",
            agent: "build",
            model: TUIMini.PromptModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4"),
            initialInput: "Verify mini demo",
            demo: true
        ))
        miniHarness.destroy()
    }
}
