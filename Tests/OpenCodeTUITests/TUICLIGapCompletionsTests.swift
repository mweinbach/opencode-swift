import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

// MARK: - 1. TUI Context Providers & Hooks

@Suite("TUI Context Providers & Destructured Hooks")
struct TUIContextProvidersTests {
    @Test("ArgsProvider and useArgs track single-use newSessionID with restore")
    func argsProviderLifecycle() throws {
        #expect(throws: TUIConfig.ConfigError.self) {
            _ = try TUIContext.useArgs()
        }
        try TUIContext.ArgsProvider(TUIContext.Args(model: "anthropic/claude", newSessionID: "ses_init", auto: true)) {
            let args = try TUIContext.useArgs()
            #expect(args.model == "anthropic/claude")
            #expect(args.auto == true)
            #expect(args.takeNewSessionID() == "ses_init")
            #expect(args.takeNewSessionID() == nil)
            args.restoreNewSessionID("ses_restored")
            #expect(args.takeNewSessionID() == "ses_restored")
            args.restoreNewSessionID("ses_a")
            args.restoreNewSessionID("ses_b")
            #expect(args.takeNewSessionID() == "ses_a")
        }
    }

    @Test("ClientContext, ClientProvider, useClient, DataProvider, and useData wire real ClientDataStore")
    func clientAndDataProviders() throws {
        let transport = MockTUIHTTPTransport()
        let api = OpenCodeClient(options: ClientOptions(baseUrl: "http://127.0.0.1:4096", transport: transport))
        let service = TUIContext.ClientService(api: api, url: "http://127.0.0.1:4096", headers: ["x-test": "1"])

        try TUIContext.ClientProvider(service) {
            let resolved = try TUIContext.useClient()
            #expect(resolved.url == "http://127.0.0.1:4096")
            #expect(resolved.headers?["x-test"] == "1")
            #expect(TUIContext.ClientContext.useOptional()?.url == "http://127.0.0.1:4096")

            try TUIContext.DataProvider(directory: "/tmp/workspace") {
                let data = try TUIContext.useData()
                #expect(data.directory == "/tmp/workspace")
                #expect(data.store.listSessions().isEmpty)
            }
        }
    }

    @Test("EditorContextProvider and useEditorContext track selection, sent state, and current mention")
    func editorContextProvider() throws {
        try TUIContext.EditorContextProvider {
            let editor = try TUIContext.useEditorContext()
            #expect(editor.selection == nil)
            #expect(editor.labelState == .none)
            #expect(editor.currentMention() == nil)

            let sel = TUIContext.EditorSelection(
                filePath: "/repo/Sources/Main.swift",
                source: .zed,
                ranges: [
                    TUIContext.EditorSelectionRange(
                        text: "let x = 1",
                        selection: TUIContext.EditorSelectionSpan(
                            start: TUIContext.EditorPosition(line: 9, character: 0),
                            end: TUIContext.EditorPosition(line: 11, character: 9)
                        )
                    ),
                ]
            )
            editor.setSelection(sel, connected: true, editorName: "Zed")
            #expect(editor.connected == true)
            #expect(editor.editorName == "Zed")
            #expect(editor.labelState == .pending)
            #expect(editor.currentMention() == TUIContext.EditorMention(filePath: "/repo/Sources/Main.swift", lineStart: 10, lineEnd: 12))

            editor.markSent()
            #expect(editor.labelState == .sent)
            editor.setSelection(sel)
            #expect(editor.labelState == .sent)

            editor.clearSelection()
            #expect(editor.selection == nil)
            #expect(editor.labelState == .none)
        }
    }

    @Test("EpilogueProvider, ExitProvider, PermissionProvider, and PromptRefProvider propagate scoped state")
    func epilogueExitPermissionAndPromptRef() throws {
        let recordedSession = Mutex<String?>(nil)
        let recordedUpdate = Mutex<String?>(nil)
        let recordedExit = Mutex<String?>(nil)

        let epilogue = TUIContext.Epilogue(
            session: { info in recordedSession.withLock { $0 = info?.sessionID } },
            updatedVersion: { v in recordedUpdate.withLock { $0 = v } }
        )

        try TUIContext.EpilogueProvider(value: epilogue) {
            let e = try TUIContext.useEpilogue()
            e.session(TUIContext.SessionEpilogueInfo(sessionID: "ses_42", title: "Demo"))
            e.updatedVersion("2.1.0")
        }
        #expect(recordedSession.withLock { $0 } == "ses_42")
        #expect(recordedUpdate.withLock { $0 } == "2.1.0")

        try TUIContext.ExitProvider(exit: { reason in recordedExit.withLock { $0 = reason } }) {
            let exit = try TUIContext.useExit()
            exit("done")
        }
        #expect(recordedExit.withLock { $0 } == "done")

        try TUIContext.ArgsProvider(TUIContext.Args(auto: true)) {
            try TUIContext.PermissionProvider {
                let mode = try TUIContext.usePermission().mode
                #expect(mode == .autoaccept)
            }
        }
        try TUIContext.PermissionProvider(mode: .prompt) {
            let mode = try TUIContext.usePermission().mode
            #expect(mode == .prompt)
        }

        try TUIContext.PromptRefProvider {
            let box = try TUIContext.usePromptRef()
            #expect(box.current == nil)
            let ref = TUIComponent.PromptRef()
            box.set(ref)
            #expect(box.current === ref)
            box.set(nil)
            #expect(box.current == nil)
        }
    }

    @Test("LocalProvider and useLocal manage agents, recent/favorite models, and variants")
    func localProviderState() throws {
        try TUIContext.LocalProvider(controller: TUIContext.LocalStateController(agents: ["build", "plan", "review"])) {
            let local = try TUIContext.useLocal()
            #expect(local.currentAgent == "build")
            #expect(local.moveAgent(1) == "plan")
            #expect(local.moveAgent(-2) == "review")

            let m1 = TUIModelPreference.ModelPreferenceModel(providerID: "anthropic", modelID: "claude-sonnet")
            let m2 = TUIModelPreference.ModelPreferenceModel(providerID: "openai", modelID: "gpt-5")
            local.setModel(m1)
            local.setModel(m2)
            #expect(local.currentModel == m2)
            #expect(local.recentModels.first == m2)
            #expect(local.recentModels.count == 2)

            local.toggleFavorite(m2)
            #expect(local.favoriteModels == [m2])
            local.toggleFavorite(m2)
            #expect(local.favoriteModels.isEmpty)

            #expect(local.cycleVariant(available: ["low", "high"]) == "low")
            #expect(local.variant() == "low")
            #expect(local.cycleVariant(available: ["low", "high"]) == "high")
            #expect(local.cycleVariant(available: ["low", "high"]) == nil)
        }
    }

    @Test("RouteProvider, SessionTabsProvider, SessionTerminalsProvider, and UpdateNotificationProvider")
    func routeTabsTerminalsAndUpdates() async throws {
        let routeController = TUIContext.RouteController(initial: .home(TUIContext.HomeRoute()))
        try TUIContext.RouteProvider(controller: routeController) {
            let r = try TUIContext.useRoute()
            #expect(try TUIContext.useRouteData().typeName == "home")
            r.navigate(.session(TUIContext.SessionRoute(sessionID: "ses_1")))
            #expect(try TUIContext.useRouteData().typeName == "session")
            #expect(r.navigationHistory.count == 2)
        }

        try TUIContext.SessionTabsProvider {
            let tabs = try TUIContext.useSessionTabs()
            tabs.open(TUIContext.SessionTab(sessionID: "s1", title: "One"))
            tabs.open(TUIContext.SessionTab(sessionID: "s2", title: "Two"))
            tabs.open(TUIContext.SessionTab(sessionID: "s3", title: "Three"))
            #expect(tabs.tabs.count == 3)
            #expect(tabs.activeSessionID == "s3")

            let cycled = tabs.cycle(direction: 1)
            #expect(cycled?.sessionID == "s1")
            let nextAfterClose = tabs.close(sessionID: "s1")
            #expect(nextAfterClose == "s2")
            #expect(tabs.tabs.count == 2)
            let reopened = tabs.reopen()
            #expect(reopened == "s1")
            #expect(tabs.tabs.count == 3)

            tabs.move(sessionID: "s3", to: 0)
            #expect(tabs.tabs.first?.sessionID == "s3")
            let layout = tabs.layout(available: 80)
            #expect(layout.tabs.count == 3)
            let anchor = TUIContext.ScrollAnchor(target: .group(groupID: "grp_1"), screenY: 4)
            tabs.setScrollAnchor(anchor, for: "s1")
            #expect(tabs.scrollAnchor(for: "s1") == anchor)
        }

        try TUIContext.SessionTerminalsProvider {
            let terms = try TUIContext.useSessionTerminals()
            terms.setAvailable(true)
            terms.setTerminal("pty_1", for: "s1")
            terms.setFocus("pty_1")
            #expect(terms.available == true)
            #expect(terms.terminalID(for: "s1") == "pty_1")
            #expect(terms.focus == "pty_1")

            // Buffered write before writer attaches is drained immediately on attach
            terms.write(terminalID: "pty_1", data: Array("hello".utf8))
            let received = Mutex<[[UInt8]]>([])
            let detach = terms.attachWriter(terminalID: "pty_1") { chunk in
                received.withLock { $0.append(chunk) }
            }
            terms.write(terminalID: "pty_1", data: Array(" world".utf8))
            #expect(received.withLock { $0.map { String(decoding: $0, as: UTF8.self) } } == ["hello", " world"])
            detach()
        }

        let appliedVersion = Mutex<String?>(nil)
        let source = TUIContext.UpdateSource(
            remote: false,
            check: { _, _ in .notice(TUIContext.ClientUpdateNotice(type: .available, version: "2.3.0")) },
            apply: { v in appliedVersion.withLock { $0 = v } }
        )
        let updates = TUIContext.UpdateNotificationController(source: source)
        try TUIContext.UpdateNotificationProvider(controller: updates) {
            let ctx = try TUIContext.useUpdateNotification()
            #expect(ctx.state == nil)
            ctx.notify(TUIContext.ClientUpdateNotice(type: .available, version: "2.2.0"))
            #expect(ctx.visibleState == .available(version: "2.2.0"))
            ctx.dismiss()
            #expect(ctx.visibleState == nil)
        }
        await updates.check()
        #expect(updates.visibleState == .available(version: "2.3.0"))
        await updates.apply(version: "2.3.0")
        #expect(appliedVersion.withLock { $0 } == "2.3.0")
        #expect(updates.state == .installed(version: "2.3.0"))
    }

    @Test("PromptHistoryProvider, FrecencyProvider, and PromptStashProvider scope prompt stores")
    func promptStoreProviders() throws {
        let hist = TUIPrompt.PromptHistoryController(initial: [TUIPrompt.PromptInfo(text: "first")])
        TUIPrompt.PromptHistoryProvider(controller: hist) {
            let resolved = TUIPrompt.usePromptHistory()
            #expect(resolved === hist)
            resolved.append(TUIPrompt.PromptInfo(text: "second"))
            #expect(resolved.entries.count == 2)
        }

        try TUIPrompt.FrecencyProvider(store: TUIPrompt.FrecencyStore(cwd: "/repo")) {
            let frecency = try TUIPrompt.useFrecency()
            frecency.updateFrecency("src/app.swift", nowMs: 1_000_000)
            #expect(frecency.getFrecency("src/app.swift", nowMs: 1_000_000) == 1.0)
        }

        try TUIPrompt.PromptStashProvider {
            let stash = try TUIPrompt.usePromptStash()
            stash.push(TUIPrompt.PromptInfo(text: "stashed prompt"), timestamp: 42)
            #expect(stash.list().count == 1)
            #expect(stash.pop()?.prompt.text == "stashed prompt")
            #expect(stash.list().isEmpty)
        }
    }
}

// MARK: - 2. Feature Plugins, DiffViewerContent, Parsers Config & Sounds

@Suite("TUI Feature Plugins, DiffViewerContent, Discovery & Parsers")
struct TUIFeaturePluginsAndDiffViewerTests {
    @Test("DiffViewerContent renders file tree, split/unified view, single-patch, and image previews")
    func diffViewerContentRendering() throws {
        let tr = createTestRenderer(width: 140, height: 30)
        let theme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let files = [
            TUIFeaturePlugin.DiffFile(
                file: "Sources/App.swift",
                patch: "@@ -1,2 +1,3 @@\n let a = 1\n-let b = 2\n+let b = 3\n+let c = 4",
                additions: 2,
                deletions: 1,
                status: .modified
            ),
            TUIFeaturePlugin.DiffFile(
                file: "Assets/logo.png",
                patch: nil,
                additions: 0,
                deletions: 0,
                status: .added
            ),
        ]

        // Wide non-docked layout renders file tree + both patch cards (including DiffViewerImage)
        let full = TUIFeaturePlugin.DiffViewerContent(
            ctx: tr.renderer,
            props: TUIFeaturePlugin.DiffViewerContentProps(
                files: files,
                mode: .working,
                sources: [.working, .branch],
                sourceDetail: "main",
                width: 140,
                docked: false,
                preferences: TUIFeaturePlugin.DiffPreferences(tree: true, single: false, view: "split")
            ),
            theme: theme
        )
        #expect(full.id == "diff-viewer-content")
        let body = try #require(full.getChildren().first { $0.id == "diff-viewer-body" })
        #expect(body.getChildren().count == 2) // file tree + patches pane

        // Single-patch docked mode hides file tree and renders only the selected file card
        let single = TUIFeaturePlugin.DiffViewerContent(
            ctx: tr.renderer,
            props: TUIFeaturePlugin.DiffViewerContentProps(
                files: files,
                mode: .session,
                width: 70,
                docked: true,
                selectedFileIndex: 1,
                preferences: TUIFeaturePlugin.DiffPreferences(tree: true, single: true)
            ),
            theme: theme
        )
        let singleBody = try #require(single.getChildren().first { $0.id == "diff-viewer-body" })
        #expect(singleBody.getChildren().count == 1) // no tree in docked compact mode
        let patchesPane = try #require(singleBody.getChildren().first { $0.id == "diff-viewer-patches" })
        #expect(patchesPane.getChildren().count == 1)
        #expect(patchesPane.getChildren().first?.id == "diff-file-1")

        // Loading / error / empty states return compact status roots
        let loading = TUIFeaturePlugin.DiffViewerContent(
            ctx: tr.renderer,
            props: TUIFeaturePlugin.DiffViewerContentProps(files: [], loading: true),
            theme: theme
        )
        #expect(loading.getChildren().count == 2)
    }

    @Test("All 13 built-in FeaturePluginModules register their slots, routes, and cleanups cleanly")
    func allBuiltinFeaturePluginModules() throws {
        let tr = createTestRenderer(width: 100, height: 30)
        let hub = TUIContext.EventHub()
        let toast = TUIPrimitive.ToastContext()
        let host = TUIPluginHost.HostServices(version: "2.5.0", channel: "dev", homeDirectory: "/Users/test", toast: toast)

        #expect(TUIFeaturePlugin.builtinFeaturePlugins.count == 13)

        try TUIContext.EventProvider(hub: hub) {
            var cleanups: [@Sendable () -> Void] = []
            var registriesByID: [String: TUIPluginHost.Registry] = [:]

            for plugin in TUIFeaturePlugin.builtinFeaturePlugins {
                let registry = TUIPluginHost.Registry()
                let ctx = TUIPluginHost.createPluginContext(host: host, id: plugin.id, registry: registry)
                if let cleanup = plugin.setup(ctx) {
                    cleanups.append(cleanup)
                }
                registriesByID[plugin.id] = registry
            }

            // Verify key slots & routes registered
            #expect(registriesByID["opencode.home.footer"]?.allSlots().first?.slot.placement.target == "home.footer")
            #expect(registriesByID["opencode.prompt.footer"]?.allSlots().first?.slot.placement.target == "prompt.footer")
            #expect(registriesByID["opencode.btw"]?.allSlots().count == 2)
            #expect(registriesByID["opencode.sidebar.context"]?.allSlots().first?.slot.placement.target == "sidebar.content")
            #expect(registriesByID["opencode.sidebar.footer"]?.allSlots().first?.slot.placement.target == "sidebar.footer")
            #expect(registriesByID["opencode.sidebar.limit"]?.allSlots().first?.slot.placement.target == "sidebar.content")
            #expect(registriesByID["opencode.sidebar.mcp"]?.allSlots().first?.slot.placement.target == "sidebar.content")
            #expect(registriesByID["opencode.sidebar.todo"]?.allSlots().first?.slot.placement.target == "sidebar.content")
            #expect(registriesByID["opencode.diffs"]?.hasRoute("diffs") == true)
            #expect(registriesByID["opencode.stats"]?.hasRoute("stats") == true)
            #expect(registriesByID["opencode.storybook"]?.hasRoute("storybook") == true)

            // Render storybook route with and without a specific story ID
            let sbRoute = try #require(registriesByID["opencode.storybook"]?.route("storybook"))
            let sbIndex = sbRoute.render(tr.renderer, [:])
            #expect(sbIndex.id == "storybook-index")
            let sbStory = sbRoute.render(tr.renderer, ["story": .string("todo")])
            #expect(sbStory.id == "story-footer")

            // Verify notificationsPlugin suppresses provider.free-limit and toasts real failures
            hub.emit(PluginSDK.EventPayload(
                type: "session.execution.failed",
                data: ["error": .object(["type": .string("provider.free-limit"), "message": .string("limit")])]
            ))
            #expect(toast.currentToast == nil)
            hub.emit(PluginSDK.EventPayload(
                type: "session.execution.failed",
                data: ["error": .object(["type": .string("unknown"), "message": .string("boom")])]
            ))
            #expect(toast.currentToast?.message == "boom")

            for cleanup in cleanups { cleanup() }
            #expect(registriesByID["opencode.diffs"]?.hasRoute("diffs") == false)
            #expect(registriesByID["opencode.stats"]?.hasRoute("stats") == false)
        }
    }

    @Test("localSource, parsers-config catalog, BunSounds, and executeCallSummary match upstream")
    func discoveryParsersSoundsAndExecuteSummary() {
        #expect(TUIPluginHost.localSource("npm-pkg", directory: "/repo") == nil)
        #expect(TUIPluginHost.localSource("./plugins/foo", directory: "/repo")?.path == "/repo/plugins/foo")
        #expect(TUIPluginHost.localSource("file:///opt/plug", directory: "/repo")?.absoluteString == "file:///opt/plug")

        let merged = TUIPluginHost.mergePluginTargets([
            TUIPluginHost.PluginTargetEntry(spec: "./p", install: false),
            TUIPluginHost.PluginTargetEntry(spec: "/repo/p", install: true),
        ], directory: "/repo")
        #expect(merged.count == 1)
        #expect(merged[0].install == true)

        #expect(TUIParsersConfig.defaultConfig.parsers.count == 34)
        let diffParser = TUIParsersConfig.defaultConfig.parsers.first { $0.filetype == "diff" }
        #expect(diffParser?.aliases == ["udiff", "patch"])
        let makeParser = TUIParsersConfig.defaultConfig.parsers.first { $0.filetype == "make" }
        #expect(makeParser?.aliases == ["makefile"])

        #expect(TUIAttention.BunSounds.defaultSoundPath == TUIAttention.defaultSoundPath)
        #expect(TUIAttention.BunSounds.questionSoundPath == TUIAttention.questionSoundPath)
        #expect(TUIAttention.BunSounds.permissionSoundPath == TUIAttention.permissionSoundPath)
        #expect(TUIAttention.BunSounds.errorSoundPath == TUIAttention.errorSoundPath)
        #expect(TUIAttention.BunSounds.subagentDoneSoundPath == TUIAttention.subagentDoneSoundPath)

        let call = TUIUtil.ExecuteCall(tool: "read", status: .completed, input: ["filePath": .string("README.md")])
        #expect(TUIRoutes.executeCallSummary(call) == TUIUtil.executeCallSummary(call))
    }
}

// MARK: - 3. TUI Renderable & Mini Runtime Class Methods

@Suite("TUI Renderables & Mini Runtime Class Methods")
struct TUIRenderablesAndMiniMethodsTests {
    @Test("GoUpsellArtRenderable, TitleShimmerRenderable, RetryProviderRenderable, SpinnerRenderable & CustomSpeedScroll")
    func renderableAndScrollMethods() {
        let tr = createTestRenderer(width: 60, height: 12)

        let art = TUIComponent.GoUpsellArtRenderable(ctx: tr.renderer, animate: true)
        art.background = RGBA.fromInts(10, 20, 30)
        art.primary = RGBA.fromHex("#ffaa00")
        art.logoBase = RGBA.fromInts(240, 240, 240)
        let anchor = BoxRenderable(ctx: tr.renderer, options: BoxOptions(id: "anchor"))
        art.logoAnchor = anchor
        #expect(art.logoAnchor === anchor)
        art.animate = false
        #expect(art.elapsedMs == 2300.0)

        let shimmer = TUIComponent.TitleShimmerRenderable(ctx: tr.renderer, text: "Chat", fg: RGBA.fromInts(255, 255, 255))
        shimmer.rename = TUIComponent.TitleShimmerRenderable.RenameState(title: "Chat", pending: true)
        #expect(shimmer.isShimmering == true)
        shimmer.backdrop = RGBA.fromInts(255, 0, 0)
        #expect(shimmer.backdropMatrix[3] > 0.9)
        shimmer.enabled = false
        #expect(shimmer.isShimmering == false)

        let retry = TUIComponent.RetryProviderRenderable(ctx: tr.renderer, provider: "exa")
        retry.value = TUIComponent.RetryProviderRenderable.Value(id: "t1", provider: "exa", running: true)
        retry.value = TUIComponent.RetryProviderRenderable.Value(id: "t1", provider: "tavily", running: true)
        retry.onAnimationTick(deltaTime: 40, ticks: 1, time: 40)
        #expect(retry.transitionOpacity < 1.0)
        let mergedStyle = retry.mergeStyles(TextNodeStyle(fg: RGBA.fromValues(1, 1, 1, 1), bg: nil, attributes: 0))
        #expect((mergedStyle.fg?.a ?? 1.0) < 1.0)
        retry.enabled = false
        #expect(retry.transitionOpacity == 1.0)
        retry.destroyRecursively()

        let spinner = TUIComponent.SpinnerRenderable(ctx: tr.renderer)
        spinner.frames = ["-", "\\", "|", "/"]
        spinner.interval = 120
        spinner.autoplay = false
        spinner.color = .fixed(RGBA.fromHex("#00ff00"))
        spinner.backgroundColor = RGBA.fromInts(0, 0, 0, 0)
        #expect(spinner.frames == ["-", "\\", "|", "/"])
        #expect(spinner.interval == 120)
        #expect(spinner.autoplay == false)

        var scroll = TUIUtil.CustomSpeedScroll(speed: 4.5)
        #expect(scroll.tick(now: 100) == 4.5)
        scroll.reset()
        #expect(scroll.tick(now: 200) == 4.5)
    }

    @Test("RunScrollbackStream, RunFooter, and Mini shared re-exports work end-to-end")
    func miniScrollbackFooterAndReexports() async {
        let tr = createTestRenderer(width: 80, height: 24)
        defer { tr.destroy() }
        let sb = TUIMini.RunScrollbackStream(renderer: tr.renderer)
        sb.setMono(true)
        sb.setTheme(TUIMini.RUN_THEME_FALLBACK)
        sb.append(TUIMini.StreamCommit(kind: .assistant, text: "Hello world", phase: .progress, source: .assistant))
        await sb.writeTurnSummary(agent: "build", model: "claude", duration: "1.2s")
        #expect(sb.committed.count == 2)
        await sb.complete(trailingNewline: true)
        sb.destroy()

        let footer = TUIMini.RunFooter(
            renderer: tr.renderer,
            modelLabel: "claude",
            agent: "build",
            startup: TUIMini.RunFooter.StartupSplash(version: "2.0.0", detail: "/repo")
        )
        #expect(footer.isClosed == false)
        #expect(footer.currentMiniSettings().mono == false)
        #expect(footer.currentTheme().splash.left == TUIMini.RUN_THEME_FALLBACK.splash.left)

        footer.finishStartup()
        let prompts = Mutex<[String]>([])
        let offPrompt = footer.onPrompt { p in prompts.withLock { $0.append(p.text) } }
        footer.submitPrompt(TUIMini.RunPrompt(text: "hi"))
        #expect(prompts.withLock { $0 } == ["hi"])
        offPrompt()

        footer.event(.turnSend)
        #expect(footer.currentState.phase == .running)
        footer.append(TUIMini.StreamCommit(kind: .assistant, text: "reply", phase: .final, source: .assistant))
        footer.event(.turnIdle)
        await footer.idle()
        await footer.refreshTheme()
        footer.resetForReplay(wrote: true)
        #expect(footer.committedScrollback.isEmpty)

        let closedCount = Mutex<Int>(0)
        _ = footer.onClose { closedCount.withLock { $0 += 1 } }
        #expect(footer.requestExit() == true)
        #expect(footer.isClosed == true)
        #expect(closedCount.withLock { $0 } == 1)
        // Registering onClose after close invokes callback immediately
        _ = footer.onClose { closedCount.withLock { $0 += 1 } }
        #expect(closedCount.withLock { $0 } == 2)
        footer.destroy()

        // Mini shared re-exports
        let lines = TUIMini.permissionAlwaysLines(action: "bash", save: ["git status"])
        #expect(!lines.isEmpty)
        let field = TUIUtil.FormField.string(
            key: "name",
            title: "Name",
            required: true,
            defaultValue: nil,
            options: nil,
            custom: false
        )
        #expect(TUIMini.formLabel(field) == "Name")
        #expect(TUIMini.formTextual(field) == true)
        #expect(TUIMini.formCustom(field) == false)
        #expect(TUIMini.formRows(field).isEmpty)
        #expect(TUIMini.formValidateValue(field, value: nil) != nil)
    }
}

// MARK: - 4. Patchmark Class Methods & Theme Resolver Parity

@Suite("Patchmark Class Methods & Theme Parity")
struct PatchmarkAndThemeMethodsTests {
    @Test("BNode, BlockParser, and PatchmarkStream class methods operate incrementally")
    func patchmarkClassMethods() throws {
        let parser = BlockParser(options: ParserOptions(gfm: true, math: true))
        #expect(parser.canContain(.document, .paragraph) == true)
        #expect(parser.canContain(.list, .item) == true)
        #expect(parser.canContain(.list, .paragraph) == false)
        #expect(parser.acceptsLines(.paragraph) == true)
        #expect(parser.acceptsLines(.thematicBreak) == false)

        parser.incorporateLine("# Heading")
        parser.incorporateLine("")
        parser.incorporateLine("- item one")
        parser.incorporateLine("- item two")
        parser.incorporateLine("")
        parser.incorporateLine("[ref]: https://example.com \"Example\"")

        let forked = parser.fork()
        forked.incorporateLine("tail paragraph")
        forked.finish()
        #expect(forked.doc.children.count >= 1)

        parser.finish()
        #expect(parser.doc.lastChild != nil)
        #expect(parser.refmap[normalizeReference("[ref]")]?.href == "https://example.com")

        let cloned = parser.doc.shallowClone(cloneChildren: true)
        #expect(cloned.forked == true)
        #expect(cloned.children.count == parser.doc.children.count)

        let manual = BlockParser(options: ParserOptions())
        let child = manual.newNode(.paragraph, startLine: 1)
        #expect(child.type == .paragraph)
        _ = manual.addChild(.paragraph, offset: 0)
        manual.incorporateLine("  hello")
        manual.findNextNonspace()
        manual.advanceNextNonspace()
        manual.advanceOffset(2, columns: true)
        manual.closeUnmatchedBlocks()
        manual.finish()

        let stream = PatchmarkStream(StreamOptions(gfm: true, math: true, heal: true, renderHtml: true))
        let f1 = stream.append("# Title\n\n**bold")
        #expect(stream.getText() == "# Title\n\n**bold")
        #expect(f1.blocks.count == 2)
        let f2 = stream.update("# Title\n\n**bold** text\n", streaming: true)
        #expect(f2.blocks.count == 2)
        let f3 = stream.finalize()
        #expect(f3.blocks.allSatisfy { $0.status == .settled })
        #expect(stream.getBlocks().count == 2)
        stream.reset()
        #expect(stream.getBlocks().isEmpty)
        #expect(stream.getText().isEmpty)
    }

    @Test("themeDecodeError and generateSyntax match upstream diagnostics and syntax rules")
    func themeDecodeErrorAndGenerateSyntax() throws {
        let wrapped = themeDecodeError(ThemeError("Expected color, got \"not-a-color\""), name: "custom")
        #expect(wrapped.message == "Invalid theme: custom \"not-a-color\" is an invalid value")

        let resolved = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let syntax = generateSyntax(resolved)
        #expect(syntax.getStyle("keyword") != nil)
        #expect(syntax.getStyle("markup.heading.1") != nil)
        #expect(syntax.getStyle("diff.plus") != nil)
        #expect(syntax.getStyle("extmark.paste") != nil)
    }
}

// MARK: - Test Helper

private final class MockTUIHTTPTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
            body: Array("{\"data\":[]}".utf8)
        )
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        HTTPStreamingResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            chunks: AsyncThrowingStream { $0.finish() }
        )
    }
}
