import Testing
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables

// Ports of upstream opencode TUI changes between 3aaac77 and 85951cb that the old prefix-only symbol hashes missed:
// spinners and animatables on the renderer's shared animation clock, chip data and `deleteCells` in the autocomplete,
// busy-aware Subagents tab and footer, Markdown answers and reasoning, and the theme row in Settings.

@Suite("Hidden drift: animation clock")
struct HiddenDriftAnimationTests {
    private func theme() throws -> ResolvedTheme {
        try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
    }

    @Test("A shimmer spinner advances its frame by elapsed ticks on the shared clock")
    func shimmerSpinnerTicks() throws {
        let test = createTestRenderer(width: 30, height: 2)
        defer { test.destroy() }
        let node = TUIComponent.Spinner(
            ctx: test.renderer, label: "Loading", shimmer: RGBA.fromHex("#ffffff"), theme: try theme()
        )
        let spinner = try #require(node as? TUIComponent.ShimmerSpinnerRenderable)
        #expect(spinner.animationFps == 1000.0 / 80.0)
        #expect(spinner.currentText == "⠋ Loading")
        spinner.onAnimationTick(deltaTime: 240, ticks: 3, time: 240)
        #expect(spinner.frame == 3)
        #expect(spinner.currentText == "⠸ Loading")
        spinner.onAnimationTick(deltaTime: 640, ticks: 8, time: 880)
        #expect(spinner.frame == 1)

        let plain = TUIComponent.Spinner(ctx: test.renderer, label: "Loading", theme: try theme())
        #expect(!(plain is TUIComponent.ShimmerSpinnerRenderable))
        let still = TUIComponent.Spinner(ctx: test.renderer, shimmer: RGBA.fromHex("#ffffff"), animations: false, theme: try theme())
        #expect(!(still is TUIComponent.ShimmerSpinnerRenderable))
    }

    @Test("A sequenced one-cell spinner steps elapsed by ticks x step x speed and stops once complete")
    func oneCellSpinnerTicks() throws {
        let test = createTestRenderer(width: 4, height: 2)
        defer { test.destroy() }
        let clip = TUIPrimitive.OneCellMotion(frames: ["a", "b", "c", "d"], interval: 100, once: true)
        let node = TUIComponent.OneCellSpinner(ctx: test.renderer, animation: clip, color: .rgba(RGBA.fromHex("#ffffff")))
        let spinner = try #require(node as? TUIComponent.OneCellSpinnerRenderable)
        // step = clamp(100ms, 1000/60 ... 40) = 40ms, so 25 fps.
        #expect(spinner.animationFps == 25)
        spinner.onAnimationTick(deltaTime: 120, ticks: 3, time: 120)
        #expect(spinner.elapsed == 120)
        #expect(spinner.currentGlyph == TUIPrimitive.oneCellFrame(clip, elapsed: 120).glyph)
        spinner.onAnimationTick(deltaTime: 2000, ticks: 50, time: 2120)
        #expect(spinner.currentFrame.complete)
        #expect(spinner.animationFps == nil)

        let fast = TUIComponent.OneCellSpinner(
            ctx: test.renderer, animation: clip, color: .rgba(RGBA.fromHex("#ffffff")), speed: 4
        ) as? TUIComponent.OneCellSpinnerRenderable
        // 100 / 4 = 25ms per step, 40 fps; each tick adds 25 x 4 = 100ms.
        #expect(fast?.animationFps == 40)
        fast?.onAnimationTick(deltaTime: 25, ticks: 1, time: 25)
        #expect(fast?.elapsed == 100)

        let paused = TUIComponent.OneCellSpinner(
            ctx: test.renderer, animation: clip, color: .rgba(RGBA.fromHex("#ffffff")), paused: true
        ) as? TUIComponent.OneCellSpinnerRenderable
        #expect(paused?.animationFps == nil)
        let looping = TUIComponent.OneCellSpinner(
            ctx: test.renderer, animation: TUIPrimitive.OneCellMotion(frames: ["a", "b"], interval: 100), color: .rgba(RGBA.fromHex("#ffffff"))
        ) as? TUIComponent.OneCellSpinnerRenderable
        #expect(looping?.animationFps == nil)
    }

    @Test("A renderer-bound animatable times itself with the renderer clock and steps on its animation ticks")
    func animatableOnRendererClock() {
        let test = createTestRenderer(width: 10, height: 2)
        defer { test.destroy() }
        test.advanceClock(by: 1_000)
        let anim = TUIPrimitive.createAnimatable(
            ["x": .scalar(0)],
            transition: TUIPrimitive.tween(duration: 0.1),
            renderer: test.renderer
        )
        anim.animate(to: ["x": .scalar(10)])
        #expect(anim.isAnimating)
        for _ in 0..<20 {
            test.advanceClock(by: 16)
            test.renderOnce()
        }
        #expect(!anim.isAnimating)
        #expect(anim.value()["x"]?.scalarValue == 10)

        anim.animate(to: ["x": .scalar(0)])
        #expect(anim.isAnimating)
        anim.jump(to: ["x": .scalar(5)])
        #expect(!anim.isAnimating)
        test.advanceClock(by: 200)
        test.renderOnce()
        #expect(anim.value()["x"]?.scalarValue == 5)
    }
}

@Suite("Hidden drift: prompt, footer, settings")
struct HiddenDriftPromptTests {
    private func theme() throws -> ResolvedTheme {
        try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
    }

    private func area(_ test: TestRenderer, _ text: String) -> TextareaRenderable {
        let area = TextareaRenderable(ctx: test.renderer, options: TextareaOptions(initialValue: text))
        test.root.add(area)
        area.cursorOffset = text.count
        return area
    }

    @Test("insertPart replaces the token with a chip that carries its part, and moves an attached file's mention")
    func autocompleteInsertPart() throws {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let input = area(test, "see @fo")
        var prompt = TUIPrompt.PromptInfo(text: "see @fo")
        let file = TUIPrompt.PromptFile(uri: "file:///foo.ts", mention: PromptSchema.PromptMention(start: 0, end: 0, text: ""))
        let inserted = try #require(TUIComponent.autocompleteInsertPart(
            input, index: 4, text: "foo.ts", part: .file(file, path: "foo.ts"), prompt: &prompt, styleId: 1, typeId: 2
        ))
        #expect(input.plainText == "see @foo.ts ")
        #expect(inserted.ref == TUIPrompt.PromptPartRef(type: .file, index: 0))
        #expect(inserted.frecencyPath == "foo.ts")
        let moved = PromptSchema.PromptMention(start: 4, end: 11, text: "@foo.ts")
        #expect(prompt.files.first?.mention == moved)
        let mark = try #require(input.extmarks.get(inserted.extmarkId))
        #expect(mark.virtual)
        #expect(mark.start == 4 && mark.end == 11)
        #expect(mark.typeId == 2)
        #expect((mark.data as? TUIPrompt.ChipData)?.file?.mention == moved)

        // The same file again moves the attached part's mention instead of adding another.
        input.insertText("@fo")
        let again = try #require(TUIComponent.autocompleteInsertPart(
            input, index: 12, text: "foo.ts", part: .file(file), prompt: &prompt, styleId: 1, typeId: 2
        ))
        #expect(again.ref == nil)
        #expect(prompt.files.count == 1)
        #expect(prompt.files.first?.mention == PromptSchema.PromptMention(start: 12, end: 19, text: "@foo.ts"))
    }

    @Test("insertPart cuts wide characters by cells, keeps a following space, and skips attached skills")
    func autocompleteInsertPartCells() throws {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        // "中" is two cells, so the "@b" token starts at cell 3.
        let input = area(test, "中 @b x")
        input.cursorOffset = 5
        var prompt = TUIPrompt.PromptInfo()
        let agent = PromptSchema.AgentAttachment(name: "build", mention: PromptSchema.PromptMention(start: 0, end: 0, text: ""))
        let inserted = try #require(TUIComponent.autocompleteInsertPart(
            input, index: 3, text: "build", part: .agent(agent), prompt: &prompt, styleId: 1, typeId: 2
        ))
        #expect(input.plainText == "中 @build x")
        #expect(inserted.ref == TUIPrompt.PromptPartRef(type: .agent, index: 0))
        #expect(prompt.agents.first?.mention == PromptSchema.PromptMention(start: 3, end: 9, text: "@build"))

        let skill = PromptInputSchema.SkillAttachment(id: "sk")
        let skipped = TUIComponent.autocompleteInsertPart(
            input, index: 0, text: "Skill", part: .skill(skill), prompt: &prompt, styleId: 1, typeId: 2, hasSkill: { $0 == "sk" }
        )
        #expect(skipped == nil)
        #expect(input.plainText == "中 @build x")
    }

    @Test("Directory expansion and command-token removal delete the token by cells")
    func autocompleteEdits() {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let mention = area(test, "@sr")
        TUIComponent.autocompleteExpandDirectory(mention, index: 0, selected: "@src ", directoryMode: false)
        #expect(mention.plainText == "@src/")

        let directory = area(test, "cd sr")
        TUIComponent.autocompleteExpandDirectory(directory, index: 3, selected: "src", directoryMode: true)
        #expect(directory.plainText == "cd src/")

        let command = area(test, "/he")
        var prompt = TUIPrompt.PromptInfo(text: "/he")
        TUIComponent.autocompleteRemoveCommandToken(command, index: 0, prompt: &prompt)
        #expect(command.plainText == "")
        #expect(prompt.text == "")
    }

    @Test("The footer lists busy scripts, subagents and shells, and a click opens the first busy tab")
    func promptFooterLive() throws {
        #expect(TUIFeaturePlugin.promptFooterLive(TUIRoutes.BusyCounts(scripts: 1, subagents: 2, shells: 1))
            == ["1 script", "2 subagents", "1 shell"])
        #expect(TUIFeaturePlugin.promptFooterLive(TUIRoutes.BusyCounts()).isEmpty)

        let test = createTestRenderer(width: 80, height: 2)
        defer { test.destroy() }
        let opened = OpenedTab()
        let footer = TUIFeaturePlugin.PromptFooter(
            ctx: test.renderer,
            usageText: "12k",
            subagentCount: 2,
            scriptCount: 1,
            childShortcut: "down",
            theme: try theme(),
            onOpenChild: { opened.set($0) }
        )
        test.root.add(footer)
        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("down 1 script · 2 subagents · 12k"))
        test.mockMouse.click(x: 2, y: 0)
        #expect(opened.value == "scripts")
    }

    @Test("The theme row shows the theme the theme context resolved, not the configured name")
    func settingsThemeRow() throws {
        let themeSetting = try #require(TUIComponent.settings.first { TUIComponent.settingID($0) == "theme.name" })
        #expect(TUIComponent.settingValue(themeSetting, values: ["theme.name": "opencode2"], selectedTheme: "opencode") == "opencode")
        #expect(TUIComponent.settingValue(themeSetting, values: ["theme.name": "missing"], selectedTheme: "opencode") == "opencode")
        #expect(TUIComponent.settingValue(themeSetting, values: [:]) == "opencode")
        let other = try #require(TUIComponent.settings.first { TUIComponent.settingID($0) != "theme.name" })
        #expect(TUIComponent.settingValue(other, values: [:], selectedTheme: "x") == other.defaultValue)
    }
}

/// Collects the tab a footer click asks for.
private final class OpenedTab: @unchecked Sendable {
    private(set) var value: String?
    func set(_ tab: String) { value = tab }
}

@Suite("Hidden drift: session route, subagents, Markdown")
struct HiddenDriftSessionTests {
    private func theme() throws -> ResolvedTheme {
        try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
    }

    @Test("session.child.first opens a named tab, toggles the picker, and opens on the busy tab")
    func sessionChildFirst() {
        let closed = TUIRoutes.SessionComposerState()
        let open = TUIRoutes.SessionComposerState(open: true, tab: "shell")
        #expect(TUIRoutes.sessionChildFirst(tab: "scripts", composer: open, hasParent: false) { "subagents" }
            == TUIRoutes.SessionComposerState(open: true, tab: "scripts"))
        #expect(TUIRoutes.sessionChildFirst(tab: nil, composer: open, hasParent: false) { "subagents" }
            == TUIRoutes.SessionComposerState(open: false, tab: "shell"))
        #expect(TUIRoutes.sessionChildFirst(tab: nil, composer: closed, hasParent: true) { "subagents" }
            == TUIRoutes.SessionComposerState(open: false, tab: nil))
        let busy = TUIRoutes.busyTab(TUIRoutes.BusyCounts(scripts: 1))
        #expect(TUIRoutes.sessionChildFirst(tab: nil, composer: closed, hasParent: false) { busy }
            == TUIRoutes.SessionComposerState(open: true, tab: "scripts"))
        #expect(TUIRoutes.sessionChildFirst(tab: "terminals", composer: closed, hasParent: false) { "shell" }
            == TUIRoutes.SessionComposerState(open: true, tab: "shell"))
    }

    @Test("A subagent that owns a running job is active, and interrupt cancels its jobs")
    func subagentEntries() throws {
        let family = TUIUtil.sessionFamily(
            sessions: [
                TUIUtil.SessionTreeNode(id: "ses_root"),
                TUIUtil.SessionTreeNode(id: "ses_a", parentID: "ses_root", title: "Explore (@explore subagent)"),
                TUIUtil.SessionTreeNode(id: "ses_b", parentID: "ses_root", title: "Idle"),
            ],
            sessionID: "ses_root"
        )
        let jobs = [
            try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"cm_a","sessionID":"ses_a","status":"running","time":{"started":1}}"#),
        ]
        let parents = ["ses_a": "ses_root", "ses_b": "ses_root"]
        func entries(_ active: Bool) -> [TUIRoutes.SubagentEntry] {
            TUIRoutes.subagentEntries(
                family: family,
                currentSessionID: "ses_root",
                jobs: jobs,
                active: active,
                status: { _ in "idle" },
                parentID: { parents[$0] }
            )
        }
        let active = entries(true)
        #expect(active.map(\.sessionID) == ["ses_a"])
        #expect(active.first?.agent == "Explore")
        #expect(active.first?.title == "Explore ()")
        #expect(active.first?.jobs == ["cm_a"])
        #expect(entries(false).map(\.sessionID) == ["ses_b"])

        let hints = TUIRoutes.subagentHints(selected: active.first, filterActive: true, interruptShortcut: "ctrl+x", toggleShortcut: "ctrl+a")
        #expect(hints.map(\.label) == ["interrupt", "show inactive"])
        #expect(TUIRoutes.subagentHints(selected: entries(false).first, filterActive: false, interruptShortcut: nil, toggleShortcut: nil).map(\.label)
            == ["show active"])

        var interrupted: [String] = []
        var cancelled: [String] = []
        TUIRoutes.interruptSubagent(active.first, interrupt: { interrupted.append($0) }, cancelJob: { cancelled.append($0) })
        #expect(interrupted.isEmpty)
        #expect(cancelled == ["cm_a"])
        let running = TUIRoutes.SubagentEntry(sessionID: "ses_c", agent: "General", title: "Run", status: "running", jobs: ["j"])
        TUIRoutes.interruptSubagent(running, interrupt: { interrupted.append($0) }, cancelJob: { cancelled.append($0) })
        #expect(interrupted == ["ses_c"])
        #expect(cancelled == ["cm_a", "j"])

        let test = createTestRenderer(width: 40, height: 6)
        defer { test.destroy() }
        let tab = TUIRoutes.SubagentsTab(ctx: test.renderer, sessionID: "ses_root", entries: [running], theme: try theme())
        test.root.add(tab)
        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("General: Run"))
        #expect(frame.contains("Running"))
        let empty = TUIRoutes.SubagentsTab(ctx: test.renderer, sessionID: "ses_x", entries: [], filterActive: false, theme: try theme())
        test.root.add(empty)
        test.renderOnce()
        #expect(test.captureCharFrame().contains("No inactive subagents"))
    }

    @Test("Answers and reasoning are Markdown; text streams until its message completes")
    func markdownParts() throws {
        let test = createTestRenderer(width: 60, height: 12)
        defer { test.destroy() }
        let streaming = try UpstreamSyncTUIHelper.assistant(text: "an **answer**", reasoning: "a *plan*", completed: false)
        guard case .text(let text) = streaming.content[1], case .reasoning(let reasoning) = streaming.content[0] else {
            Issue.record("unexpected parts")
            return
        }
        let part = TUIRoutes.TextPart(ctx: test.renderer, part: text, message: streaming, theme: try theme())
        let markdown = try #require(part.getChildren().first as? MarkdownRenderable)
        #expect(markdown.streaming)
        let done = try UpstreamSyncTUIHelper.assistant(text: "an **answer**", reasoning: "a *plan*", completed: true)
        let finished = TUIRoutes.TextPart(ctx: test.renderer, part: text, message: done, theme: try theme())
        #expect((finished.getChildren().first as? MarkdownRenderable)?.streaming == false)

        let thought = TUIRoutes.ReasoningPart(ctx: test.renderer, part: reasoning, message: streaming, theme: try theme())
        let body = try #require(thought.getChildren().last as? MarkdownRenderable)
        #expect(body.streaming)
        let source = TUIRoutes.ReasoningPart(ctx: test.renderer, part: reasoning, message: done, markdownMode: "source", theme: try theme())
        #expect(source.getChildren().last is CodeRenderable)
        let hidden = TUIRoutes.ReasoningPart(ctx: test.renderer, part: reasoning, message: done, thinkingMode: .hide, theme: try theme())
        #expect(hidden.getChildren().count == 1)

        let answer = TUIFeaturePlugin.Answer(ctx: test.renderer, question: "why?", answer: "because **bold**", theme: try theme())
        test.root.add(answer)
        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("because bold"))
        #expect(!frame.contains("**"))
    }
}
