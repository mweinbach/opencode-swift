import Testing
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables

// Ports of the upstream opencode TUI changes between 3aaac77 and 85951cb (new designs on by default, the new
// "opencode" theme, the composer Scripts tab, chip data, restored mention cells, mini markdown, dialogs, marquee).

@Suite("Upstream TUI sync: config, theme, experiments")
struct UpstreamSyncConfigThemeTests {
    @Test("Keybind definitions include the composer script commands")
    func scriptKeybinds() {
        let defs = TUIConfig.Keybind.Definitions
        #expect(defs["composer.script.up"] != nil)
        #expect(defs["composer.script.down"] != nil)
        #expect(defs["composer.script.cancel"] != nil)
    }

    @Test("The new-designs experiment is on unless the config turns it off")
    func newDesignsDefaultOn() async throws {
        let store = TUIComponent.ExperimentsStore()
        #expect(store.isEnabled("new-designs"))
        #expect(!store.isEnabled("client-mcp"))
        let next = try await store.toggle("new-designs")
        #expect(next == false)
        #expect(!store.isEnabled("new-designs"))
        let off = TUIComponent.ExperimentsStore(flags: ["new-designs": false])
        #expect(!off.isEnabled("new-designs"))
    }

    @Test("opencode is the new theme, with the light grays from upstream; the old one is opencode-classic")
    func opencodeThemeSwap() throws {
        let light = try resolveThemeDocument(TUIThemeBridge.getOpenCodeTheme(), mode: .light)
        #expect(light.hue.scales["gray"]?[.s500] == RGBA.fromHex("#e6e6e6"))
        #expect(light.hue.scales["gray"]?[.s600] == RGBA.fromHex("#eeeeee"))
        let dark = try resolveThemeDocument(TUIThemeBridge.getOpenCodeTheme(), mode: .dark)
        #expect(dark.background.base == RGBA.fromHex("#080808"))
        let classic = try resolveThemeDocument(TUIThemeBridge.getOpenCodeClassicTheme(), mode: .dark)
        #expect(classic.background.base == RGBA.fromHex("#0a0a0a"))
        #expect(TUIThemeBridge.allThemes()["opencode-classic"] != nil)
        #expect(ThemeDefaults.opencode2 == ThemeDefaults.opencode)
    }

    @Test("The theme service resolves opencode2 to opencode and offers opencode-classic")
    func themeAlias() {
        let service = TUIContext.ThemeService()
        #expect(service.has("opencode-classic"))
        #expect(service.has("opencode2"))
        #expect(service.set("opencode2"))
        #expect(service.selected == "opencode")
        #expect(service.set("opencode-classic"))
        #expect(service.selected == "opencode-classic")
        #expect(!service.set(""))
    }
}

@Suite("Upstream TUI sync: composer tabs and scripts")
struct UpstreamSyncComposerTests {
    private func tab(_ id: String) -> TUIRoutes.ComposerTab {
        TUIRoutes.ComposerTab(id: id, label: id.capitalized)
    }

    @Test("Composer tabs keep a canonical order and the active tab while Scripts comes and goes")
    func canonicalOrder() {
        let tabs = TUIRoutes.createComposerTabs()
        _ = tabs.register(tab("terminals"))
        _ = tabs.register(tab("subagents"))
        _ = tabs.register(tab("shell"))
        tabs.setInputs(open: true, defaultTab: nil)
        #expect(tabs.active == "subagents")
        tabs.setActive("shell")

        let remove = tabs.register(tab("scripts"))
        #expect(tabs.list.map(\.id) == ["subagents", "shell", "scripts", "terminals"])
        #expect(tabs.active == "shell")
        remove()
        #expect(tabs.active == "shell")

        let again = tabs.register(tab("scripts"))
        tabs.setActive("scripts")
        again()
        #expect(tabs.active == "subagents")
    }

    @Test("Composer tabs open on the requested tab")
    func requestedTab() {
        let tabs = TUIRoutes.createComposerTabs(defaultTab: "scripts")
        _ = tabs.register(tab("subagents"))
        _ = tabs.register(tab("scripts"))
        tabs.setInputs(open: true, defaultTab: "scripts")
        #expect(tabs.active == "scripts")
    }

    @Test("Composer tabs switch to the requested tab once it registers, until the user picks one")
    func lateRequestedTab() {
        let tabs = TUIRoutes.createComposerTabs()
        _ = tabs.register(tab("subagents"))
        tabs.setInputs(open: true, defaultTab: "shell")
        #expect(tabs.active == "subagents")
        _ = tabs.register(tab("shell"))
        #expect(tabs.active == "shell")
        _ = tabs.register(tab("scripts"))
        #expect(tabs.active == "shell")
        tabs.setActive("subagents")
        _ = tabs.register(tab("terminals"))
        #expect(tabs.active == "subagents")
    }

    @Test("The picker opens on the first busy tab, else Subagents")
    func busyTab() throws {
        let script = try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"job_1","sessionID":"ses_root","status":"running","time":{"started":1}}"#)
        func counts(_ jobs: [JobSchema.Info], _ shells: [String?]) -> TUIRoutes.BusyCounts {
            TUIRoutes.busyCounts(
                sessionID: "ses_root",
                jobs: jobs,
                family: ["ses_root", "ses_child"],
                status: { _ in "idle" },
                parentID: { _ in nil },
                shellSessionIDs: shells
            )
        }
        let scripts = counts([script], [])
        #expect(scripts == TUIRoutes.BusyCounts(scripts: 1, subagents: 0, shells: 0))
        #expect(TUIRoutes.busyTab(scripts) == "scripts")
        let shells = counts([], ["ses_root", "ses_other"])
        #expect(shells == TUIRoutes.BusyCounts(scripts: 0, subagents: 0, shells: 1))
        #expect(TUIRoutes.busyTab(shells) == "shell")
        #expect(TUIRoutes.busyTab(counts([], [])) == "subagents")
    }

    @Test("ownedJobs follows a subagent job to its child when the child's parent is not loaded")
    func ownedJobs() throws {
        let parents = ["ses_child": "ses_session"]
        let jobs = [
            try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"cm_grandchild","sessionID":"ses_grandchild","status":"running","time":{"started":1}}"#),
            try UpstreamSyncTUIHelper.job(#"{"kind":"subagent","id":"sub_nested","sessionID":"ses_child","childSessionID":"ses_grandchild","agent":"general","description":"Nested","status":"running","time":{"started":1}}"#),
        ]
        let ids = { (session: String) in
            TUIUtil.ownedJobs(jobs, sessionID: session, parentID: { parents[$0] }).map { TUIUtil.JobFields($0).id }
        }
        #expect(ids("ses_child") == ["sub_nested"])
        #expect(ids("ses_session") == ["sub_nested"])
        #expect(ids("ses_grandchild") == ["cm_grandchild", "sub_nested"])
    }

    @Test("scriptLabel names a script by its first line of code, then its title")
    func scriptLabel() throws {
        let job = try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"cm_1","sessionID":"ses_session","status":"running","time":{"started":1}}"#)
        let titled = try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"cm_1","sessionID":"ses_session","status":"running","title":"Build","time":{"started":1}}"#)
        let messages = [try UpstreamSyncTUIHelper.executeMessage(code: "\n  // Build both\r\nawait 1", jobID: "cm_1")]
        #expect(TUIUtil.scriptLabel(messages, job: job) == "// Build both")
        #expect(TUIUtil.scriptLabel([], job: titled) == "Build")
        #expect(TUIUtil.scriptLabel([], job: job) == "Script")
        let other = [try UpstreamSyncTUIHelper.executeMessage(code: "await 2", jobID: "cm_2")]
        #expect(TUIUtil.scriptLabel(other, job: job) == "Script")
    }

    @Test("Scripts show for the main session only; up on the first row closes, down wraps, cancel targets the row")
    func scriptsTabModel() throws {
        let job = try UpstreamSyncTUIHelper.job(#"{"kind":"codemode","id":"cm_1","sessionID":"ses","status":"running","time":{"started":1}}"#)
        let shell = try UpstreamSyncTUIHelper.job(#"{"kind":"shell","id":"sh_1","sessionID":"ses","status":"running","time":{"started":1},"shellID":"s","command":"ls"}"#)
        let scripts = TUIRoutes.runningScripts(sessionID: "ses", parentID: nil, jobs: [job, shell])
        #expect(scripts.count == 1)
        #expect(TUIRoutes.runningScripts(sessionID: "ses", parentID: "ses_parent", jobs: [job]).isEmpty)

        let model = TUIRoutes.ScriptsTabModel()
        var closed = false
        model.up { closed = true }
        #expect(closed)
        model.down(count: 1)
        #expect(model.selected == 0)
        #expect(model.cancelTarget(scripts) == "cm_1")
        #expect(model.hints(scripts, cancelShortcut: "ctrl+d") == [TUIRoutes.ComposerHint(label: "cancel", shortcut: "ctrl+d")])
        #expect(model.hints([], cancelShortcut: "ctrl+d").isEmpty)

        let tabs = TUIRoutes.createComposerTabs(open: true)
        #expect(model.register(in: tabs, scripts: { [] }, cancelShortcut: { nil }) == nil)
        let remove = model.register(in: tabs, scripts: { scripts }, cancelShortcut: { "ctrl+d" })
        #expect(tabs.list.map(\.id) == ["scripts"])
        remove?()
        #expect(tabs.list.isEmpty)

        #expect(TUIRoutes.scriptElapsed(started: 1_000, now: 43_500) == "42s")
        #expect(TUIRoutes.scriptElapsed(started: 5_000, now: 1_000) == "0s")
    }
}

@Suite("Upstream TUI sync: prompt content, chips, restored mentions")
struct UpstreamSyncPromptTests {
    // The web composer writes string indexes, the TUI writes cells; in "\t中 @f x" they are 3..5 and 5..7.
    @Test(
        "Restored mentions come back in cells",
        arguments: [
            ("\t中 @f x", "@f", 3, 5, 5, 7),
            ("\t中 @f x", "@f", 5, 7, 5, 7),
            ("see @f x", "@f", 4, 6, 4, 6),
            // "@@" is at string index 2 and at cell 2.
            ("\t@@@", "@@", 2, 4, 2, 4),
            ("\t中 @f x", "@f", 0, 2, 0, 2),
        ] as [(String, String, Int, Int, Int, Int)]
    )
    func promptMentionsToCells(text: String, label: String, start: Int, end: Int, cellStart: Int, cellEnd: Int) {
        let mention = PromptSchema.PromptMention(start: start, end: end, text: label)
        let prompt = PromptInputSchema.Prompt(
            text: text,
            files: [PromptInputSchema.FileAttachment(uri: "file:///f", mention: mention)],
            agents: [PromptSchema.AgentAttachment(name: "f", mention: mention)]
        )
        let cells = PromptSchema.PromptMention(start: cellStart, end: cellEnd, text: label)
        let converted = TUIPrompt.promptMentionsToCells(prompt, widthMethod: .unicode)
        #expect(converted == PromptInputSchema.Prompt(
            text: text,
            files: [PromptInputSchema.FileAttachment(uri: "file:///f", mention: cells)],
            agents: [PromptSchema.AgentAttachment(name: "f", mention: cells)]
        ))
    }

    @Test("deleteCells deletes document cells across lines and wide characters")
    func deleteCells() {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let area = TextareaRenderable(ctx: test.renderer, options: TextareaOptions(initialValue: "a中b\ncd"))
        test.root.add(area)
        // "a" (1) + "中" (2) + "b" (1) + newline (1): cells [1, 6) are "中b\nc".
        TUIPrompt.deleteCells(area, start: 1, end: 6)
        #expect(area.plainText == "ad")
    }

    @Test("A restored chip rebinds to a copy of its part; a file already attached is not added again")
    func rebindChip() {
        var prompt = TUIPrompt.PromptInfo(text: "@a.ts @build")
        let file = TUIPrompt.PromptFile(uri: "file:///a.ts", mention: PromptSchema.PromptMention(start: 0, end: 5, text: "@a.ts"))
        let agent = PromptSchema.AgentAttachment(name: "build", mention: PromptSchema.PromptMention(start: 6, end: 12, text: "@build"))
        #expect(TUIComponent.rebindChip(&prompt, data: TUIPrompt.ChipData(file: file)) == TUIPrompt.PromptPartRef(type: .file, index: 0))
        #expect(TUIComponent.rebindChip(&prompt, data: TUIPrompt.ChipData(file: file)) == nil)
        #expect(TUIComponent.rebindChip(&prompt, data: TUIPrompt.ChipData(agent: agent)) == TUIPrompt.PromptPartRef(type: .agent, index: 0))
        #expect(TUIComponent.rebindChip(&prompt, data: nil) == nil)
        #expect(prompt.files == [file])
        #expect(TUIComponent.chipData(for: TUIPrompt.PromptPartRef(type: .agent, index: 0), in: prompt) == TUIPrompt.ChipData(agent: agent))
    }

    @Test("Editor context is sent as a system-update note")
    func editorContext() {
        let opened = TUIContext.EditorSelection(filePath: "/a.ts", ranges: [])
        #expect(TUIComponent.formatEditorContext(opened)
            == "<system-update>Note: The user opened the file \"/a.ts\". This may or may not be relevant to the current task.</system-update>\n")
        let range = TUIContext.EditorSelectionRange(
            text: "x",
            selection: TUIContext.EditorSelectionSpan(
                start: TUIContext.EditorPosition(line: 3, character: 0),
                end: TUIContext.EditorPosition(line: 5, character: 1)
            )
        )
        let selected = TUIContext.EditorSelection(filePath: "/a.ts", ranges: [range])
        #expect(TUIComponent.formatEditorContext(selected)
            == "<system-update>Note: The user selected #3-5 from \"/a.ts\". ```x```\n\n This may or may not be relevant to the current task.</system-update>\n")
    }
}

@Suite("Upstream TUI sync: mini scrollback and footer")
struct UpstreamSyncMiniTests {
    private func reasoning(_ text: String) -> TUIMini.StreamCommit {
        TUIMini.StreamCommit(kind: .reasoning, text: text, phase: .progress, source: .reasoning)
    }

    @Test("Rendered reasoning is native Markdown; source reasoning stays highlighted Markdown source")
    func reasoningBody() {
        let rendered = TUIMini.entryBody(reasoning("Thinking: plan"), options: TUIMini.ScrollbackOptions())
        #expect(rendered == .markdown(content: "_Thinking:_ plan"))
        let source = TUIMini.entryBody(reasoning("Thinking: plan"), options: TUIMini.ScrollbackOptions(markdown: "source"))
        #expect(source == .code(content: "_Thinking:_ plan", filetype: "markdown"))
        let plain = TUIMini.entryBody(reasoning("plan"), options: TUIMini.ScrollbackOptions(markdown: "rendered"))
        #expect(plain == .markdown(content: "plan"))
        let mono = TUIMini.entryBody(reasoning("Thinking: plan"), options: TUIMini.ScrollbackOptions(mono: true))
        #expect(mono == .text(content: "Thinking: plan"))
    }

    @Test("Mono Markdown keeps prose on the hooked path and writes task boxes in ASCII")
    func monoMarkdownHook() {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let md = MarkdownRenderable(ctx: test.renderer, options: MarkdownOptions(content: "- [x] done “ok”"))
        TUIMini.monoMarkdownRenderable(md)
        #expect(md.inlineHook != nil)
        test.root.add(md)
        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("[x] done \"ok\""))
    }
}

@Suite("Upstream TUI sync: dialogs, marquee, title shimmer, session links")
struct UpstreamSyncComponentsTests {
    @Test("DialogButtons shows hints on the left; a hint without a key takes its command's shortcut or is dropped")
    func dialogButtonHints() throws {
        let test = createTestRenderer(width: 60, height: 4)
        defer { test.destroy() }
        let theme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let row = TUIPrimitive.DialogButtons(
            ctx: test.renderer,
            buttons: [TUIPrimitive.DialogButton(label: "Submit") {}],
            active: 0,
            theme: theme,
            hints: [
                TUIPrimitive.DialogFooterAction(title: "browse", command: "dialog.browse"),
                TUIPrimitive.DialogFooterAction(title: "unbound", command: "dialog.none"),
                TUIPrimitive.DialogFooterAction(title: "keyed", key: "tab"),
            ],
            shortcut: { $0 == "dialog.browse" ? "ctrl+o" : nil }
        )
        test.root.add(row)
        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("browse ctrl+o"))
        #expect(frame.contains("keyed tab"))
        #expect(!frame.contains("unbound"))
        #expect(frame.contains("Submit"))
        #expect(row.getChildren().count == 2)
    }

    @Test("DialogSelect has no footer without actions, and new designs draw the active bar in the row's background")
    func dialogSelectFooterAndBar() throws {
        let test = createTestRenderer(width: 60, height: 10)
        defer { test.destroy() }
        let theme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let dialog = TUIPrimitive.DialogContext()
        let red = RGBA.fromHex("#ff0000")
        let options = [TUIPrimitive.DialogSelectOption(title: "Delete", value: "delete", bg: red)]
        let empty = TUIPrimitive.DialogSelect(
            ctx: test.renderer,
            props: TUIPrimitive.DialogSelectProps(title: "Confirm", options: options, footerActions: TUIPrimitive.DialogFooterActions()),
            dialog: dialog,
            theme: theme,
            newDesigns: true
        )
        // Header and list only.
        #expect(empty.getChildren().count == 2)
        test.root.add(empty)
        test.renderOnce()
        let spans = test.captureSpans()
        let bar = spans.lines.flatMap(\.spans).first { $0.text.contains("┃") }
        #expect(bar?.fg == red)
    }

    @Test("The marquee waits for begin(), scrolls by clock ticks, and stops after one cycle")
    func marquee() {
        let marquee = TUIComponent.createMarquee()
        let title = "A very long session title that overflows"
        marquee.enter(sessionID: "ses", title: title, width: 10)
        #expect(marquee.delayPending)
        #expect(marquee.animationFps == nil)
        marquee.tick()
        #expect(marquee.offset == 0)
        marquee.begin()
        #expect(marquee.offset == 1)
        #expect(marquee.animationFps == 1000 / TUIComponent.MarqueeController.interval)
        marquee.tick(3)
        #expect(marquee.offset == 4)
        marquee.tick(10_000)
        #expect(marquee.offset == 0)
        #expect(!marquee.scrolling)
        marquee.leave(sessionID: "ses")
        #expect(marquee.active == nil)
    }

    @Test("A pending rename animates at 60 fps on the shared clock and fades its blend in")
    func titleShimmerTicks() {
        let test = createTestRenderer(width: 40, height: 2)
        defer { test.destroy() }
        let title = TUIComponent.TitleShimmerRenderable(
            ctx: test.renderer, text: "Session", fg: RGBA.fromHex("#ffffff"), renameTitle: "Session", renamePending: true
        )
        #expect(title.animationFps == 60)
        title.onAnimationTick(deltaTime: 120, ticks: 1, time: 0)
        #expect(title.blend == 0.5)
        #expect(title.elapsed == 120)
        title.renamePending = false
        title.onAnimationTick(deltaTime: 240, ticks: 1, time: 0)
        #expect(title.blend == 0)
        #expect(title.animationFps == nil)
    }

    @Test("Session links use the inline hook: labels, exact-ID code spans, table cells, and targets")
    func sessionLinkSpans() {
        let id = "ses_" + String(repeating: "a", count: 26)
        let links = TUIPrimitive.useSessionLinks(currentSessionID: nil) { $0 == id ? "Refactor" : nil }
        let style = SyntaxStyle.create()
        let prose = MarkdownInlineContext(source: "see \(id)", conceal: true, syntaxStyle: style, tableCell: false)
        let out = links.linkSpans([MarkdownInlineSpan(text: "see \(id) now")], prose)
        #expect(out.map(\.text) == ["see ", "@Refactor", " now"])
        #expect(out[1].target == id)
        #expect(((out[1].attributes ?? 0) & TextAttributes.underline) != 0)

        let raw = MarkdownInlineContext(source: id, conceal: false, syntaxStyle: style, tableCell: false)
        #expect(links.linkSpans([MarkdownInlineSpan(text: id)], raw).first?.text == id)

        let code = links.linkSpans([MarkdownInlineSpan(text: "`opencode --session \(id)`", code: true)], prose)
        #expect(code.count == 1 && code[0].target == nil)
        let exact = links.linkSpans([MarkdownInlineSpan(text: "`\(id)`", code: true)], prose)
        #expect(exact.contains { $0.target == id })

        let cell = MarkdownInlineContext(source: id, conceal: true, syntaxStyle: style, tableCell: true)
        #expect(links.linkSpans([MarkdownInlineSpan(text: id)], cell) == [MarkdownInlineSpan(text: id)])
        #expect(links.inlineHookFilter == ["ses_"])
    }
}
