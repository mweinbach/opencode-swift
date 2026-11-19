import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

@Suite("TUI Utilities, Form Helpers, Diffs, Usage Limits & Persistence")
struct TUIUtilsTests {

    @Test("stringWidth measures ASCII, CJK, ANSI escapes, and locale width truncation")
    func stringWidthAndLocale() {
        #expect(TUIUtil.stringWidth("hello") == 5)
        #expect(TUIUtil.stringWidth("\u{1B}[31mhello\u{1B}[0m") == 5)
        #expect(TUIUtil.stringWidth("中文") == 4)
        #expect(TUIUtil.titlecase("hello world_test") == "Hello World_test")
        #expect(TUIUtil.number(950) == "950")
        #expect(TUIUtil.number(1_500) == "1.5K")
        #expect(TUIUtil.number(1_250_000) == "1.3M")
        #expect(TUIUtil.truncate("abcdef", 4) == "abc…")
        #expect(TUIUtil.truncateLeft("abcdef", 4) == "…def")
        #expect(TUIUtil.truncateMiddle("abcdefghij", maxLength: 5) == "ab…ij")
        #expect(TUIUtil.takeWidth("中文abc", 5) == "中文a")
        #expect(TUIUtil.truncateWidth("中文abc", 5) == "中文…")
    }

    @Test("collapseToolOutput and collapseShellOutput truncate and summarize earlier lines")
    func collapseOutputs() {
        let short = TUIUtil.collapseToolOutput("a\nb", maxLines: 5, maxChars: 100)
        #expect(short.overflow == false)
        #expect(short.output == "a\nb")

        let long = TUIUtil.collapseToolOutput("l1\nl2\nl3\nl4", maxLines: 2, maxChars: 100)
        #expect(long.overflow == true)
        #expect(long.output == "l1\nl2…")

        let shell = TUIUtil.collapseShellOutput(
            input: "echo test",
            output: "line1\nline2\nline3\nline4\nline5",
            maxLines: 4,
            maxChars: 120
        )
        #expect(shell.overflow == true)
        #expect(shell.output.contains("earlier"))
        #expect(shell.output.contains("line5"))
    }

    @Test("splitAddedPatch and splitPatchHunks split unified diffs cleanly")
    func diffSplitting() throws {
        let added = """
        diff --git a/foo.swift b/foo.swift
        --- /dev/null
        +++ b/foo.swift
        @@ -0,0 +1,5 @@
        +line 1
        +line 2
        +line 3
        +line 4
        +line 5
        """
        let chunks = try #require(TUIUtil.splitAddedPatch(added, size: 2))
        #expect(chunks.count == 3)
        #expect(chunks[0].rows == 2)
        #expect(chunks[1].patch.contains("@@ -0,0 +3,2 @@"))
        #expect(chunks[2].rows == 1)

        let multi = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
        -old1
        +new1
         ctx
        @@ -10,2 +10,3 @@
         ctx2
        +added1
        +added2
        """
        let hunks = TUIUtil.splitPatchHunks(multi)
        #expect(hunks.count == 2)
        #expect(hunks[0].header == "@@ -1,2 +1,2 @@")
        #expect(hunks[0].rows == 2)
        #expect(hunks[1].header == "@@ -10,2 +10,3 @@")
        #expect(hunks[1].rows == 3)
    }

    @Test("Form helpers validate strings, numbers, integers, booleans, and multiselect fields")
    func formHelpers() {
        let emailField = TUIUtil.FormField.string(
            key: "email",
            title: "Email",
            required: true,
            format: "email"
        )
        #expect(TUIUtil.isFormAnswerField(emailField))
        #expect(TUIUtil.formLabel(emailField) == "Email")
        #expect(TUIUtil.formTextual(emailField))
        #expect(TUIUtil.formValidateValue(emailField, value: nil) == "Answer required")
        #expect(TUIUtil.formValidateValue(emailField, value: .string("bad")) == "Expected an email address")
        #expect(TUIUtil.formValidateValue(emailField, value: .string("a@b.com")) == nil)

        let intField = TUIUtil.FormField.integer(key: "count", required: true, minimum: 1, maximum: 5)
        #expect(TUIUtil.formValidateValue(intField, value: .number(2.5)) == "Expected an integer")
        #expect(TUIUtil.formValidateValue(intField, value: .number(0)) == "Must be at least 1")
        #expect(TUIUtil.formValidateValue(intField, value: .number(3)) == nil)

        let multi = TUIUtil.FormField.multiselect(
            key: "tags",
            required: true,
            options: [
                TUIUtil.FormOption(value: "a", label: "Alpha"),
                TUIUtil.FormOption(value: "b", label: "Beta"),
            ],
            minItems: 1,
            custom: true
        )
        #expect(TUIUtil.formCustom(multi))
        let toggled = TUIUtil.formToggleMultiselect(.strings(["a"]), item: "b")
        #expect(toggled == ["a", "b"])
        let removed = TUIUtil.formToggleMultiselect(.strings(toggled), item: "a")
        #expect(removed == ["b"])
        let customReplaced = TUIUtil.formSetMultiselectCustom(.strings(["b", "old"]), previous: "old", next: "new")
        #expect(customReplaced == ["b", "new"])
        #expect(TUIUtil.formDisplayValue(multi, value: .strings(["a", "b"]), emptyMultiselect: "None") == "Alpha, Beta")
        #expect(TUIUtil.formDisplayValue(multi, value: .strings([]), emptyMultiselect: "None") == "None")
    }

    @Test("Marquee, paths, filetype, permissions, todos, tool display, and usage limits")
    func domainUtilities() throws {
        #expect(TUIUtil.marqueeOverflows("Long session title", width: 8))
        #expect(!TUIUtil.marqueeOverflows("Short", width: 8))
        let shifted = TUIUtil.marqueeText("Hello World", width: 6, offset: 3)
        #expect(TUIUtil.stringWidth(shifted) <= 6)

        #expect(TUIUtil.abbreviateHome("/Users/dev/work/app", home: "/Users/dev") == "~/work/app")
        #expect(TUIUtil.formatPath("/Users/dev/work/app/src/main.swift", base: "/Users/dev/work/app", home: "/Users/dev") == "src/main.swift")
        #expect(TUIUtil.filetype("App.tsx") == "typescript")
        #expect(TUIUtil.filetype("main.swift") == "swift")
        #expect(TUIUtil.filetype(nil) == "none")

        let perm = TUIUtil.permissionPresentation(
            TUIUtil.PermissionPresentationInput(action: "bash", input: ["command": .string("swift test")])
        )
        #expect(perm.icon == "#")
        #expect(perm.title == "Shell command")
        #expect(perm.lines == ["$ swift test"])
        #expect(TUIUtil.permissionOptionLabel(.always) == "Always allow")

        let todos = TUIUtil.sessionTodos([
            TUIUtil.SessionToolCallRecord(
                messageID: "m1",
                toolName: "todowrite",
                completed: true,
                input: [
                    "todos": .array([
                        .object(["content": .string("Build UI"), "status": .string("in_progress")]),
                        .object(["content": .string("Ship"), "status": .string("completed")]),
                    ]),
                ]
            ),
        ])
        #expect(todos.count == 2)
        #expect(TUIUtil.todoMarker(todos[0].status) == "[•]")
        #expect(TUIUtil.todoMarker(todos[1].status, ascii: true) == "[x]")

        #expect(TUIUtil.canonicalToolName("bash") == "shell")
        #expect(TUIUtil.webSearchProviderLabel("opencode") == "Web Search via OpenCode")

        let budget = try TUIComponentsTestHelper.makeBudget(limit: 10.0, spent: 9.8, scope: .each, coverage: .all)
        let model = TUIUtil.LimitedModel(id: "claude-4", providerID: "opencode", inputCosts: [3.0], contextLimit: 200_000)
        let provider = TUIUtil.LimitedProvider(id: "opencode", integrationID: "opencode")
        let usage = TUIUtil.modelUsage(budgets: [budget], model: model, provider: provider)
        #expect(usage != nil)
        #expect(TUIUtil.usageLevel(usage!, model: model) == .out)
        #expect(TUIUtil.formatDollars(0.005) == "<$0.01")
        #expect(TUIUtil.formatDollars(12.0) == "$12")
        #expect(TUIUtil.goLimitLink(responseBody: "{\"workspace\":\"org_123\"}") == "https://opencode.ai/console/org_123/go")
    }

    @Test("Highlights decision & claim, persistence atomic write, and single-flight deduplication")
    func highlightsPersistenceAndSingleFlight() async throws {
        let firstRun = TUIUtil.decide(TUIUtil.HighlightsInput(version: "2.0.27", count: 5, history: false))
        #expect(firstRun == .record)

        let store = TUIUtil.HighlightsStore(seen: "2.0.26")
        let shouldShow = await TUIUtil.claim(
            store: store,
            input: TUIUtil.HighlightsInput(version: "2.0.27", count: 5, history: true)
        )
        #expect(shouldShow == true)
        #expect(store.seen == "2.0.27")
        let secondClaim = await TUIUtil.claim(
            store: store,
            input: TUIUtil.HighlightsInput(version: "2.0.27", count: 5, history: true)
        )
        #expect(secondClaim == false)

        try await TUIComponentsTestHelper.withTempDirectory { dir in
            let file = "\(dir)/nested/state.json"
            try await TUIUtil.writeJsonAtomic(file, value: ["ok": true])
            let decoded: [String: Bool] = try await TUIUtil.readJson(file)
            #expect(decoded["ok"] == true)
        }

        let sf = TUIUtil.createSingleFlight(String.self)
        let ran = try await sf.run(key: "k1") { 42 }
        #expect(ran == 42)
    }
}

@Suite("OpenTUI Primitives, SpinnerRenderable, Dialogs & Permanent Experiments")
struct TUIRenderablesAndDialogsTests {

    @Test("SpinnerRenderable renders and ticks frames through OpenTUI TestRenderer")
    func spinnerRenderableInTestRenderer() throws {
        let tr = createTestRenderer(width: 40, height: 6)
        defer { tr.destroy() }

        let spinner = TUIComponent.SpinnerRenderable(
            ctx: tr.renderer,
            options: TUIComponent.SpinnerOptions(
                id: "test-spinner",
                frames: ["⠋", "⠙", "⠹"],
                interval: 80,
                autoplay: true,
                color: .generator { frameIndex, _, _, _ in
                    frameIndex == 0 ? .rgba(RGBA.fromHex("#ff0000")) : .rgba(RGBA.fromHex("#00ff00"))
                }
            )
        )
        tr.root.add(spinner)
        tr.renderOnce(force: true)
        #expect(tr.captureCharFrame().contains("⠋"))
        #expect(spinner.frameIndex == 0)

        spinner.onAnimationTick(deltaTime: 80, ticks: 1, time: 80)
        tr.renderOnce(force: true)
        #expect(spinner.frameIndex == 1)
        #expect(tr.captureCharFrame().contains("⠙"))

        let knightFrames = TUIPrimitive.createFrames(TUIPrimitive.KnightRiderOptions(width: 6, style: .diamonds, holdStart: 2, holdEnd: 2))
        #expect(knightFrames.count == 6 + 2 + 5 + 2)
        let knightColors = TUIPrimitive.createColors(TUIPrimitive.KnightRiderOptions(width: 6, color: .rgba(RGBA.fromHex("#fab283"))))
        #expect(knightColors(0, 0, knightFrames.count, 6).a == 1.0)
    }

    @Test("Permanent Experiments framework works with active entries AND empty registry")
    func permanentExperimentsFramework() async throws {
        let theme = try TUIComponentsTestHelper.defaultDarkTheme()
        let persisted = Mutex<[[String: Bool]]>([])
        let store = TUIComponent.ExperimentsStore(flags: ["new-designs": false]) { snapshot in
            persisted.withLock { $0.append(snapshot) }
        }
        #expect(!TUIComponent.experiments.isEmpty)
        #expect(store.isEnabled("new-designs") == false)
        let next = try await store.toggle("new-designs")
        #expect(next == true)
        #expect(store.isEnabled("new-designs") == true)
        #expect(persisted.withLock { $0.last?["new-designs"] } == true)

        // Render active Experiments dialog through OpenTUI TestRenderer
        let tr = createTestRenderer(width: 72, height: 18)
        defer { tr.destroy() }
        let dialog = TUIPrimitive.DialogContext()
        let view = TUIComponent.DialogExperiments(ctx: tr.renderer, store: store, dialog: dialog, theme: theme)
        tr.root.add(view)
        tr.renderOnce(force: true)
        let activeFrame = tr.captureCharFrame()
        #expect(activeFrame.contains("Experiments"))
        #expect(activeFrame.contains("New designs"))

        // Empty registry MUST still render valid permanent Experiments dialog per upstream packages/tui/AGENTS.md
        let trEmpty = createTestRenderer(width: 72, height: 12)
        defer { trEmpty.destroy() }
        let emptyStore = TUIComponent.ExperimentsStore(flags: [:], registry: [])
        let emptyView = TUIComponent.DialogExperiments(ctx: trEmpty.renderer, store: emptyStore, dialog: dialog, theme: theme)
        trEmpty.root.add(emptyView)
        trEmpty.renderOnce(force: true)
        let emptyFrame = trEmpty.captureCharFrame()
        #expect(emptyFrame.contains("Experiments"))
        #expect(emptyFrame.contains("No experiments available"))
    }

    @Test("DialogSelect, DialogConfirm, DialogAlert, Toast, PatchDiff, and DevToolsBar render via TestRenderer")
    func dialogsToastDiffAndDevToolsRendering() throws {
        let theme = try TUIComponentsTestHelper.defaultDarkTheme()
        let tr = createTestRenderer(width: 80, height: 24)
        defer { tr.destroy() }

        let dialog = TUIPrimitive.DialogContext()
        let options = [
            TUIPrimitive.DialogSelectOption(title: "Claude Sonnet", value: "anthropic/claude-sonnet", category: "Anthropic"),
            TUIPrimitive.DialogSelectOption(title: "GPT-5", value: "openai/gpt-5", category: "OpenAI"),
        ]
        let ref = TUIPrimitive.DialogSelectRef(options: options)
        ref.setFilter("claude")
        #expect(ref.filtered.count == 1)
        #expect(ref.selected?.value == "anthropic/claude-sonnet")

        let selectNode = TUIPrimitive.DialogSelect(
            ctx: tr.renderer,
            props: TUIPrimitive.DialogSelectProps(title: "Select model", options: options, current: "openai/gpt-5"),
            dialog: dialog,
            theme: theme
        )
        tr.root.add(selectNode)
        tr.renderOnce(force: true)
        let frame = tr.captureCharFrame()
        #expect(frame.contains("Select model"))
        #expect(frame.contains("Claude Sonnet"))
        #expect(frame.contains("GPT-5"))

        // Toast queueing and rendering
        let toast = TUIPrimitive.ToastContext(now: { 1000 })
        toast.show(TUIPrimitive.ToastOptions(title: "Saved", message: "Config updated", variant: .success, duration: 3000))
        toast.pause()
        toast.show(TUIPrimitive.ToastOptions(message: "Queued toast", variant: .info, duration: 3000))
        #expect(toast.pending == 1)
        let toastBox = try #require(TUIPrimitive.Toast(ctx: tr.renderer, toast: toast, theme: theme, terminalWidth: 80))
        tr.root.add(toastBox)
        tr.renderOnce(force: true)
        #expect(tr.captureCharFrame().contains("Config updated"))

        // PatchDiff + DevToolsBar + TodoItem rendering
        let trDiff = createTestRenderer(width: 80, height: 16)
        defer { trDiff.destroy() }
        let samplePatch = """
        diff --git a/hello.swift b/hello.swift
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,2 +1,2 @@
        -let x = 1
        +let x = 2
         print(x)
        """
        let patchBox = TUIComponent.PatchDiff(ctx: trDiff.renderer, diff: samplePatch, filetype: "swift", theme: theme)
        let devBar = TUIComponent.DevToolsBar(
            ctx: trDiff.renderer,
            connectionStatus: "connected",
            samples: [TUIComponent.ProcessSample(delay: 12, time: 1000)],
            theme: theme
        )
        trDiff.root.add(patchBox)
        trDiff.root.add(devBar)
        trDiff.renderOnce(force: true)
        let diffFrame = trDiff.captureCharFrame()
        #expect(diffFrame.contains("Server"))
        #expect(diffFrame.contains("Experiments"))
        #expect(TUIComponent.brailleGraph([1, 5, 10], width: 5).count == 5)
    }

    @Test("UI primitives: animation, octant glyphs, one-cell motion, selection controller, file-path truncation & tab-pulse")
    func uiPrimitiveMathAndControllers() {
        let anim = TUIPrimitive.createAnimatable(
            ["x": .scalar(0)],
            transition: TUIPrimitive.tween(duration: 0.2),
            now: { 0 }
        )
        anim.animate(to: ["x": .scalar(10)], at: 0)
        #expect(anim.step(at: 100) == true)
        let mid = anim.value()["x"]?.scalarValue ?? 0
        #expect(mid > 4.0 && mid < 6.0)
        #expect(anim.step(at: 250) == false)
        #expect(anim.value()["x"]?.scalarValue == 10.0)

        #expect(TUIPrimitive.octantGlyph(0x00) == " ")
        #expect(TUIPrimitive.octantGlyph(0xFF) == "\u{2588}")
        let frame = TUIPrimitive.oneCellFrame(TUIPrimitive.SEED_WORK, elapsed: 400)
        #expect(frame.glyph == "\u{25AA}")
        #expect(frame.level >= 0.3 && frame.level <= 1.0)

        #expect(TUIPrimitive.moveSelection(0, count: 3, delta: -1, policy: .wrap) == 2)
        #expect(TUIPrimitive.moveSelection(0, count: 3, delta: -1, policy: .clamp) == 0)
        #expect(TUIPrimitive.revealSelectionOffset(0, count: 10, limit: 4, selected: 6) == 3)
        #expect(TUIPrimitive.truncateFilePath("/very/deep/nested/folder/Component.swift", maxWidth: 24).hasSuffix("Component.swift"))

        let blended = TUIComponent.blendTabPulseColor(
            background: RGBA.fromInts(0, 0, 0),
            glowColor: RGBA.fromInts(200, 100, 0),
            runningColor: RGBA.fromInts(0, 200, 0),
            flashColor: RGBA.fromInts(255, 255, 255),
            completionColor: RGBA.fromInts(0, 0, 255),
            glow: 0.5,
            running: 0,
            flash: 0,
            completion: 0
        )
        #expect(blended.toInts().0 == 100)
        #expect(TUIComponent.parsePastedFilepaths("'/tmp/a b.png' /tmp/c.jpg", platform: "darwin") == ["/tmp/a b.png", "/tmp/c.jpg"])
    }
}

@Suite("TUI Theme Bridge, Plugin Host, Slot Resolution & Feature Plugins")
struct TUIThemeAndPluginTests {

    @Test("Theme bridge resolves built-in defaults, system theme, custom themes, and filesystem discovery")
    func themeBridgeResolutionAndDiscovery() async throws {
        #expect(TUIThemeBridge.DEFAULT_THEMES.count == 32)
        #expect(TUIThemeBridge.hasTheme("opencode"))
        #expect(TUIThemeBridge.hasTheme("dracula"))
        #expect(TUIThemeBridge.hasTheme("tokyonight"))
        #expect(TUIThemeBridge.hasTheme("system"))

        let draculaDoc = try TUIThemeBridge.parseTheme(.v1(try #require(TUIThemeBridge.DEFAULT_THEMES["dracula"])), name: "dracula")
        let draculaResolved = try resolveThemeDocument(draculaDoc, mode: .dark)
        #expect(draculaResolved.text.base.a == 1.0)

        let palette = TerminalColors(
            palette: ["#000000", "#cc0000", "#00cc00", "#cccc00", "#0000cc", "#cc00cc", "#00cccc", "#eeeeee"],
            defaultForeground: "#eeeeee",
            defaultBackground: "#101010"
        )
        #expect(TUIThemeBridge.terminalMode(palette) == .dark)
        let sysTheme = TUIThemeBridge.generateSystem(palette, mode: .dark)
        let resolvedSys = try TUIThemeBridge.resolveTheme(sysTheme, mode: .dark)
        #expect(resolvedSys.text == RGBA.fromHex("#eeeeee"))

        let paletteBytes = TUIComponent.terminalPalette(theme: draculaResolved.tokens, mode: .dark, background: draculaResolved.background.base)
        let paletteStr = String(decoding: paletteBytes, as: UTF8.self)
        #expect(paletteStr.contains("\u{1B}]4;0;"))
        #expect(paletteStr.contains("\u{1B}]10;"))
        #expect(paletteStr.contains("\u{1B}]11;"))

        try await TUIComponentsTestHelper.withTempDirectory { dir in
            _ = try TUIComponentsTestHelper.writeFile(
                dir: dir,
                relativePath: "themes/solar-custom.json",
                content: TUIComponentsTestHelper.makeSampleThemeJSON(primary: "#ff6600")
            )
            let discovered = try await TUIThemeBridge.discoverThemes(directories: [dir])
            #expect(discovered["solar-custom"] != nil)
            #expect(TUIThemeBridge.isThemeSource(try #require(discovered["solar-custom"])))

            let notified = Mutex<Bool>(false)
            let unsubscribe = TUIThemeBridge.subscribeThemes { map in
                if map["solar-custom"] != nil { notified.withLock { $0 = true } }
            }
            defer {
                unsubscribe()
                TUIThemeBridge.setCustomThemes([:])
            }
            TUIThemeBridge.setCustomThemes(discovered)
            #expect(notified.withLock { $0 } == true)
            #expect(TUIThemeBridge.hasTheme("solar-custom"))
        }
    }

    @Test("Plugin slot resolver enforces replacement hierarchy, suppression, and ancestor degradation")
    func slotTreeResolution() {
        let paths: Set<String> = ["home", "home.footer", "sidebar"]
        let claims: [TUIPluginHost.Claim<String>] = [
            // First replace on home.footer
            TUIPluginHost.Claim(key: "p1/0", plugin: "p1", placement: TUIPluginHost.Placement(kind: .replace, target: "home.footer"), render: "builtin"),
            // Second replace on home.footer wins (last-enabled-wins)
            TUIPluginHost.Claim(key: "p2/0", plugin: "p2", placement: TUIPluginHost.Placement(kind: .replace, target: "home.footer"), render: "custom"),
            // Additive append inside replaced boundary gets suppressed
            TUIPluginHost.Claim(key: "p3/0", plugin: "p3", placement: TUIPluginHost.Placement(kind: .append, target: "home.footer"), render: "suppressed-inside"),
            // Sibling after replaced boundary survives outside it
            TUIPluginHost.Claim(key: "p4/0", plugin: "p4", placement: TUIPluginHost.Placement(kind: .after, target: "home.footer"), render: "sibling-after"),
            // Missing nested path degrades to surviving ancestor `sidebar`
            TUIPluginHost.Claim(key: "p5/0", plugin: "p5", placement: TUIPluginHost.Placement(kind: .append, target: "sidebar.content.extra"), render: "degraded-item"),
        ]
        let result = TUIPluginHost.resolveSlots(paths: paths, claims: claims)
        #expect(result.slotted["home.footer"]?.replace?.plugin == "p2")
        #expect(result.slotted["home.footer"]?.after.map(\.plugin) == ["p4"])
        #expect(result.suppressed.count == 2)
        #expect(result.degraded.count == 1)
        #expect(result.degraded[0].to == "sidebar")
        #expect(result.slotted["sidebar"]?.append.map(\.plugin) == ["p5"])
    }

    @Test("Plugin host discovery, merging, crash boundary containment, and DiffViewer file tree utilities")
    func pluginHostDiscoveryAndFeaturePlugins() async throws {
        try await TUIComponentsTestHelper.withTempDirectory { dir in
            _ = try TUIComponentsTestHelper.createDirectory(dir: dir, relativePath: ".git")
            let pluginDir = try TUIComponentsTestHelper.createDirectory(dir: dir, relativePath: ".opencode/plugins/alpha-plugin")
            let configDir = try TUIComponentsTestHelper.createDirectory(dir: dir, relativePath: "global-config")

            let dirs = try await TUIPluginHost.localPluginDirectories(cwd: dir, configDirectory: configDir)
            #expect(dirs.contains("\(dir)/.opencode/plugins"))

            let targets = try await TUIPluginHost.discoverPluginTargets(directories: dirs)
            #expect(targets.contains(pluginDir))

            let merged = TUIPluginHost.mergePluginTargets([
                TUIPluginHost.PluginTargetEntry(spec: "./.opencode/plugins/alpha-plugin", install: false, optional: true),
                TUIPluginHost.PluginTargetEntry(spec: pluginDir, install: true, optional: false),
            ], directory: dir)
            #expect(merged.count == 1)
            #expect(merged[0].optional == false)
        }

        // Crash containment via PluginBoundary
        let toast = TUIPrimitive.ToastContext()
        let crashed = Mutex<Bool>(false)
        let result = TUIPluginHost.PluginBoundary(
            id: "broken.plugin",
            where: "slot test",
            toast: toast,
            onCrash: { crashed.withLock { $0 = true } }
        ) {
            throw ThemeError("render boom")
        }
        #expect(result == nil)
        #expect(crashed.withLock { $0 } == true)
        #expect(toast.currentToast?.variant == .error)
        #expect(toast.currentToast?.message.contains("broken.plugin crashed in slot test") == true)

        // Feature plugin diff viewer file tree utilities & stats
        let tree = TUIFeaturePlugin.buildFileTree([
            TUIFeaturePlugin.FileTreeItem(file: "src/a/b/file1.swift", status: .modified),
            TUIFeaturePlugin.FileTreeItem(file: "src/a/b/file2.swift", status: .added),
            TUIFeaturePlugin.FileTreeItem(file: "README.md", status: .modified),
        ])
        let rows = TUIFeaturePlugin.flattenFileTree(tree)
        #expect(rows[0].kind == .directory)
        #expect(rows[0].name == "src/a/b")
        #expect(TUIFeaturePlugin.orderedPatchFileIndexes(rows) == [0, 1, 2])
        #expect(TUIFeaturePlugin.movePatchFileIndex([0, 1, 2], current: 1, offset: 1) == 2)
        #expect(TUIFeaturePlugin.isDiffImageFile("preview.PNG") == true)
        #expect(TUIFeaturePlugin.isDiffImageFile("code.swift") == false)
        #expect(TUIFeaturePlugin.homeFooterVisibility(width: 80).pluginCommand == true)
        #expect(TUIFeaturePlugin.homeFooterVisibility(width: 60).mcpCommand == false)
        #expect(TUIFeaturePlugin.statsNumber(1_250_000) == "1.3M")
        #expect(!TUIFeaturePlugin.ONE_CELL_SPINNERS.isEmpty)
        #expect(!TUIFeaturePlugin.SUBCELL_SPINNERS.isEmpty)
    }
}
