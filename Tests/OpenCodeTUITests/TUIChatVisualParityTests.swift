import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView
import Testing

@Suite("TUI Session Conversation Visual Parity (Upstream 2.3.2)")
struct TUIChatVisualParityTests {

    // MARK: - Pure-Swift Frame Inspection Helpers (no Foundation import)

    private static func frameLines(_ frame: String) -> [String] {
        frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func lineIndex(containing needle: String, in lines: [String]) -> Int? {
        lines.firstIndex(where: { $0.contains(needle) })
    }

    private static func findSubstring(_ needle: String, in lines: [String]) -> (x: Int, y: Int)? {
        let needleChars = Array(needle)
        guard !needleChars.isEmpty else { return nil }
        for (y, line) in lines.enumerated() {
            let rowChars = Array(line)
            guard rowChars.count >= needleChars.count else { continue }
            for x in 0...(rowChars.count - needleChars.count) {
                var matched = true
                for offset in 0..<needleChars.count {
                    if rowChars[x + offset] != needleChars[offset] {
                        matched = false
                        break
                    }
                }
                if matched {
                    return (x, y)
                }
            }
        }
        return nil
    }

    private static func makeSessionState(
        width: Int = 110,
        height: Int = 40,
        mode: ThemeMode = .dark,
        status: TUISessionRunStatus = .idle,
        messages: [TUITranscriptItem]
    ) -> TUIInteractiveState {
        var state = TUIRealParityFixtures.makeSessionState(
            width: width,
            height: height,
            mode: mode,
            running: status.isRunning
        )
        state.sidebarExplicitOverride = false
        state.sessionStatus = status
        state.messages = messages
        return state
    }

    // MARK: - 1. Multi-Step Chronological Conversation & Turn-End Footer

    @Test("Multi-step conversation renders chronological order, shell card, compact read without raw dump, and single turn-end footer")
    func multiStepChronologicalConversationAndFooter() throws {
        let messages: [TUITranscriptItem] = [
            .user(
                id: "u1",
                text: "Check git status and inspect TUIScreens.swift.",
                agentName: "Build",
                isOptimistic: false
            ),
            .assistant(
                id: "a_step1",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .tool(
                        id: "t_shell",
                        name: "shell",
                        status: .completed,
                        summary: "git status -s",
                        outputPreview: "M Sources/OpenCodeTUI/App/TUIScreens.swift\n?? Tests/OpenCodeTUITests/TUIChatVisualParityTests.swift",
                        error: nil
                    ),
                ],
                completed: true,
                error: nil
            ),
            .assistant(
                id: "a_step2",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .tool(
                        id: "t_read",
                        name: "read",
                        status: .completed,
                        summary: "Sources/OpenCodeTUI/App/TUIScreens.swift",
                        outputPreview: "1: import OpenCodeSchema\n2: import OpenCodeUtil\n3: public enum TUIScreens {",
                        error: nil
                    ),
                ],
                completed: true,
                error: nil
            ),
            .assistant(
                id: "a_step3",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .text(
                        id: "p_final",
                        text: "The repository is clean and ready for visual parity checks."
                    ),
                ],
                completed: true,
                error: nil
            ),
        ]

        for mode in [ThemeMode.light, ThemeMode.dark] {
            let state = Self.makeSessionState(width: 110, height: 42, mode: mode, status: .idle, messages: messages)
            let theme = state.resolveTheme()
            let expectedAgentColor = state.agentColor(theme: theme)
            let harness = TUIRealParityHarness(width: 110, height: 42, state: state)
            defer { harness.destroy() }

            let frame = harness.frame()
            let lines = Self.frameLines(frame)

            // All steps present with upstream formatting
            let userRow = try #require(Self.lineIndex(containing: "Check git status and inspect TUIScreens.swift.", in: lines))
            let shellCmdRow = try #require(Self.lineIndex(containing: "$ git status -s", in: lines))
            let shellOutRow = try #require(Self.lineIndex(containing: "M Sources/OpenCodeTUI/App/TUIScreens.swift", in: lines))
            let readRow = try #require(Self.lineIndex(containing: "→ Read Sources/OpenCodeTUI/App/TUIScreens.swift", in: lines))
            let finalTextRow = try #require(Self.lineIndex(containing: "The repository is clean and ready for visual parity checks.", in: lines))
            let footerRow = try #require(Self.lineIndex(containing: "▣ Build · Claude Sonnet 4.5", in: lines))

            // Strict chronological top-to-bottom ordering: User -> Step 1 Shell -> Step 2 Read -> Step 3 Text -> Footer
            #expect(userRow < shellCmdRow)
            #expect(shellCmdRow < shellOutRow)
            #expect(shellOutRow < readRow)
            #expect(readRow < finalTextRow)
            #expect(finalTextRow < footerRow)

            // Read tool NEVER dumps raw line-numbered file content previews when completed
            #expect(!frame.contains("1: import OpenCodeSchema"))
            #expect(!frame.contains("2: import OpenCodeUtil"))
            #expect(!frame.contains("public enum TUIScreens"))

            // Turn-end footer appears ONCE for the whole 3-step assistant turn (not between steps)
            let footerOccurrences = lines.filter { $0.contains("▣ Build") }.count
            #expect(footerOccurrences == 1)

            // Verify shell card raised-surface background RGBA and foreground colors
            let shellPos = try #require(Self.findSubstring("$ git status -s", in: lines))
            #expect(harness.cellBackground(x: shellPos.x, y: shellPos.y) == theme.background.raised.base)
            #expect(harness.cellForeground(x: shellPos.x, y: shellPos.y) == theme.text.base)

            let shellOutPos = try #require(Self.findSubstring("M Sources/OpenCodeTUI/App/TUIScreens.swift", in: lines))
            #expect(harness.cellBackground(x: shellOutPos.x, y: shellOutPos.y) == theme.background.raised.base)
            #expect(harness.cellForeground(x: shellOutPos.x, y: shellOutPos.y) == theme.text.muted)

            // Verify turn-end footer exact RGBA tokens ('▣ ' agentColor, agentName text.base, ' · <model>' text.muted)
            let glyphPos = try #require(Self.findSubstring("▣", in: lines))
            let agentPos = try #require(Self.findSubstring("Build", in: [lines[footerRow]]))
            let modelPos = try #require(Self.findSubstring("Claude Sonnet 4.5", in: [lines[footerRow]]))
            #expect(harness.cellForeground(x: glyphPos.x, y: glyphPos.y) == expectedAgentColor)
            #expect(harness.cellForeground(x: agentPos.x, y: footerRow) == theme.text.base)
            #expect(harness.cellForeground(x: modelPos.x, y: footerRow) == theme.text.muted)

            // Footer is left-padded by 3 relative to the transcript column (aligns with read tool & markdown)
            let readPos = try #require(Self.findSubstring("→ Read", in: lines))
            #expect(glyphPos.x == readPos.x)
        }
    }

    @Test("Turn-end footer respects working state, multi-turn boundaries, system messages, and missing modelLabel")
    func turnEndFooterBoundaryConditions() {
        // 1. Running session hides footer on the trailing assistant message, while preserving completed previous turn's footer
        let runningMessages: [TUITranscriptItem] = [
            .user(id: "u1", text: "First prompt", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a1",
                agentName: "Plan",
                modelLabel: "GPT-5.3 Codex",
                parts: [.text(id: "t1", text: "First turn complete.")],
                completed: true,
                error: nil
            ),
            .user(id: "u2", text: "Second prompt", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a2",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [.text(id: "t2", text: "Still working on second turn...")],
                completed: true,
                error: nil
            ),
        ]
        let runningState = Self.makeSessionState(width: 110, height: 38, mode: .dark, status: .running, messages: runningMessages)
        let runningHarness = TUIRealParityHarness(width: 110, height: 38, state: runningState)
        defer { runningHarness.destroy() }

        let runningFrame = runningHarness.frame()
        #expect(runningFrame.contains("▣ Plan · GPT-5.3 Codex"))
        #expect(!runningFrame.contains("▣ Build · Claude Sonnet 4.5"))

        // 2. Assistant followed by .system renders footer; nil/empty modelLabel omits " · "
        let systemFollowMessages: [TUITranscriptItem] = [
            .user(id: "u3", text: "Run shell command", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a3",
                agentName: "Shell",
                modelLabel: nil,
                parts: [.tool(id: "sh1", name: "shell", status: .completed, summary: "echo hi", outputPreview: "hi", error: nil)],
                completed: true,
                error: nil
            ),
            .system(id: "sys1", text: "Session compacted.", isError: false),
        ]
        let sysState = Self.makeSessionState(width: 110, height: 32, mode: .light, status: .running, messages: systemFollowMessages)
        let sysHarness = TUIRealParityHarness(width: 110, height: 32, state: sysState)
        defer { sysHarness.destroy() }

        let sysFrame = sysHarness.frame()
        #expect(sysFrame.contains("▣ Shell"))
        #expect(!sysFrame.contains("▣ Shell ·"))
        #expect(sysFrame.contains("Session compacted."))
    }

    // MARK: - 2. Compact Inline Tools & Error Display

    @Test("Compact inline tools render upstream single-line icons without dumping previews and show error text when failed")
    func compactInlineToolsAndErrorDisplay() throws {
        let messages: [TUITranscriptItem] = [
            .user(id: "u1", text: "Inspect workspace", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a1",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .tool(id: "t1", name: "read", status: .completed, summary: "Package.swift", outputPreview: "1: // swift-tools-version: 6.2", error: nil),
                    .tool(id: "t2", name: "fs_read", status: .completed, summary: "README.md", outputPreview: "1: # swift-opencode", error: nil),
                    .tool(id: "t3", name: "glob", status: .completed, summary: "Sources/**/*.swift", outputPreview: "Sources/A.swift\nSources/B.swift", error: nil),
                    .tool(id: "t4", name: "grep", status: .completed, summary: "buildSessionScreen", outputPreview: "TUIScreens.swift:953", error: nil),
                    .tool(id: "t5", name: "list", status: .completed, summary: "Sources/OpenCodeTUI", outputPreview: "App/\nTheme/", error: nil),
                    .tool(id: "t6", name: "webfetch", status: .completed, summary: "https://opencode.ai/docs", outputPreview: "<html>Raw HTML dump</html>", error: nil),
                    .tool(id: "t7", name: "websearch", status: .completed, summary: "Swift 6.2 concurrency", outputPreview: "Result 1 snippet", error: nil),
                    .tool(id: "t8", name: "skill", status: .completed, summary: "opencode", outputPreview: "Loaded skill body", error: nil),
                    .tool(id: "t9", name: "todowrite", status: .completed, summary: "2 tasks", outputPreview: "Todo raw JSON", error: nil),
                    .tool(id: "t10", name: "question", status: .completed, summary: "Confirm target?", outputPreview: "Question raw JSON", error: nil),
                    .tool(id: "t11", name: "read", status: .error, summary: "missing.swift", outputPreview: nil, error: "ENOENT: no such file"),
                ],
                completed: true,
                error: nil
            ),
        ]

        let state = Self.makeSessionState(width: 110, height: 48, mode: .dark, status: .idle, messages: messages)
        let theme = state.resolveTheme()
        let harness = TUIRealParityHarness(width: 110, height: 48, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        let lines = Self.frameLines(frame)

        #expect(frame.contains("→ Read Package.swift"))
        #expect(frame.contains("→ Read README.md"))
        #expect(frame.contains("✱ Glob Sources/**/*.swift"))
        #expect(frame.contains("✱ Grep buildSessionScreen"))
        #expect(frame.contains("→ List Sources/OpenCodeTUI"))
        #expect(frame.contains("◈ Webfetch https://opencode.ai/docs"))
        #expect(frame.contains("◈ Websearch Swift 6.2 concurrency"))
        #expect(frame.contains("→ Skill opencode"))
        #expect(frame.contains("⚙ Todos 2 tasks"))
        #expect(frame.contains("→ Question Confirm target?"))

        // None of the completed compact tool previews should leak into the transcript
        #expect(!frame.contains("swift-tools-version"))
        #expect(!frame.contains("# swift-opencode"))
        #expect(!frame.contains("Raw HTML dump"))
        #expect(!frame.contains("Loaded skill body"))
        #expect(!frame.contains("Todo raw JSON"))

        // Failed read shows error icon, tool name, and error message in feedback error color
        #expect(frame.contains("✗ Read missing.swift"))
        #expect(frame.contains("ENOENT: no such file"))
        let errPos = try #require(Self.findSubstring("ENOENT: no such file", in: lines))
        #expect(harness.cellForeground(x: errPos.x, y: errPos.y) == theme.text.feedback.error.base)
    }

    // MARK: - 3. Shell / Bash Card & Edit / Write Diff Card

    @Test("Shell error card and Edit/Write/Patch diff cards render raised surfaces and semantic diff colors")
    func shellAndEditDiffCards() throws {
        let diffPreview = """
        @@ -10,3 +10,4 @@
         struct Greeter {
        -    let greeting = "hi"
        +    let greeting = "hello"
        +    let version = 2
         }
        """

        let messages: [TUITranscriptItem] = [
            .user(id: "u1", text: "Update Greeter and run tests", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a1",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .tool(
                        id: "t_edit",
                        name: "edit",
                        status: .completed,
                        summary: "Sources/App/Greeter.swift",
                        outputPreview: diffPreview,
                        error: nil
                    ),
                    .tool(
                        id: "t_write",
                        name: "write",
                        status: .completed,
                        summary: "Sources/App/Notes.md",
                        outputPreview: nil,
                        error: nil
                    ),
                    .tool(
                        id: "t_bash_fail",
                        name: "bash",
                        status: .error,
                        summary: "swift test --filter GreeterTests",
                        outputPreview: "Compiling GreeterTests...",
                        error: "Exited with code 1"
                    ),
                ],
                completed: true,
                error: nil
            ),
        ]

        let state = Self.makeSessionState(width: 110, height: 42, mode: .dark, status: .idle, messages: messages)
        let theme = state.resolveTheme()
        let harness = TUIRealParityHarness(width: 110, height: 42, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        let lines = Self.frameLines(frame)

        // Edit card header & diff lines
        #expect(frame.contains("← Edit Sources/App/Greeter.swift"))
        #expect(frame.contains("← Write Sources/App/Notes.md"))
        #expect(frame.contains("@@ -10,3 +10,4 @@"))
        #expect(frame.contains("-    let greeting = \"hi\""))
        #expect(frame.contains("+    let greeting = \"hello\""))

        let editHeaderPos = try #require(Self.findSubstring("← Edit Sources/App/Greeter.swift", in: lines))
        #expect(harness.cellBackground(x: editHeaderPos.x, y: editHeaderPos.y) == theme.background.raised.base)

        let hunkPos = try #require(Self.findSubstring("@@ -10,3 +10,4 @@", in: lines))
        #expect(harness.cellForeground(x: hunkPos.x, y: hunkPos.y) == theme.diff.text.hunkHeader)
        #expect(harness.cellBackground(x: hunkPos.x, y: hunkPos.y) == theme.background.raised.base)

        let removedPos = try #require(Self.findSubstring("-    let greeting = \"hi\"", in: lines))
        #expect(harness.cellForeground(x: removedPos.x, y: removedPos.y) == theme.diff.text.removed)
        #expect(harness.cellBackground(x: removedPos.x, y: removedPos.y) == theme.diff.background.removed)

        let addedPos = try #require(Self.findSubstring("+    let greeting = \"hello\"", in: lines))
        #expect(harness.cellForeground(x: addedPos.x, y: addedPos.y) == theme.diff.text.added)
        #expect(harness.cellBackground(x: addedPos.x, y: addedPos.y) == theme.diff.background.added)

        // Bash failed card renders '$ <cmd>', output, and error in error color on raised surface
        let bashCmdPos = try #require(Self.findSubstring("$ swift test --filter GreeterTests", in: lines))
        #expect(harness.cellBackground(x: bashCmdPos.x, y: bashCmdPos.y) == theme.background.raised.base)
        #expect(harness.cellForeground(x: bashCmdPos.x, y: bashCmdPos.y) == theme.text.feedback.error.base)

        let bashErrPos = try #require(Self.findSubstring("Exited with code 1", in: lines))
        #expect(harness.cellBackground(x: bashErrPos.x, y: bashErrPos.y) == theme.background.raised.base)
        #expect(harness.cellForeground(x: bashErrPos.x, y: bashErrPos.y) == theme.text.feedback.error.base)
    }

    // MARK: - 4. Public toolIcon Signature & Upstream Glyph Mapping

    @Test("Shell running/overflow cards, exec/patch/apply_patch, and remaining compact inline aliases render cleanly")
    func shellOverflowRunningAndToolAliases() throws {
        let manyLines = (1...16).map { "log line \($0)" }.joined(separator: "\n")
        let patchDiff = """
        @@ -1,2 +1,2 @@
        -oldValue
        +newValue
        """
        let messages: [TUITranscriptItem] = [
            .user(id: "u1", text: "Check logs and patch file", agentName: "Build", isOptimistic: false),
            .assistant(
                id: "a1",
                agentName: "Build",
                modelLabel: "Claude Sonnet 4.5",
                parts: [
                    .tool(id: "sh_run", name: "exec", status: .running, summary: "swift build", outputPreview: nil, error: nil),
                    .tool(id: "sh_big", name: "shell", status: .completed, summary: "cat build.log", outputPreview: manyLines, error: nil),
                    .tool(id: "p1", name: "apply_patch", status: .completed, summary: "Sources/App.swift", outputPreview: patchDiff, error: nil),
                    .tool(id: "c1", name: "search", status: .completed, summary: "ToolDisplayStyle", outputPreview: "secret search preview", error: nil),
                    .tool(id: "c2", name: "ls", status: .completed, summary: "Sources/", outputPreview: "secret ls preview", error: nil),
                    .tool(id: "c3", name: "todo", status: .completed, summary: "1 item", outputPreview: "secret todo preview", error: nil),
                ],
                completed: true,
                error: nil
            ),
        ]

        let state = Self.makeSessionState(width: 110, height: 54, mode: .light, status: .idle, messages: messages)
        let theme = state.resolveTheme()
        let harness = TUIRealParityHarness(width: 110, height: 54, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        let lines = Self.frameLines(frame)

        // Running exec shows spinner + $ command on raised card
        #expect(frame.contains("⠋ $ swift build"))
        let runPos = try #require(Self.findSubstring("⠋ $ swift build", in: lines))
        #expect(harness.cellBackground(x: runPos.x, y: runPos.y) == theme.background.raised.base)

        // Overflowing shell output is bounded via collapseShellOutput with "(N earlier lines)" summary
        #expect(frame.contains("$ cat build.log"))
        #expect(frame.contains("earlier lines)"))
        #expect(frame.contains("log line 16"))
        #expect(!frame.contains("log line 1\n"))

        // apply_patch renders Patch header with colored diff lines
        #expect(frame.contains("← Patch Sources/App.swift"))
        let minusPos = try #require(Self.findSubstring("-oldValue", in: lines))
        #expect(harness.cellForeground(x: minusPos.x, y: minusPos.y) == theme.diff.text.removed)
        let plusPos = try #require(Self.findSubstring("+newValue", in: lines))
        #expect(harness.cellForeground(x: plusPos.x, y: plusPos.y) == theme.diff.text.added)

        // Compact aliases render cleanly without dumping outputPreview
        #expect(frame.contains("✱ Search ToolDisplayStyle"))
        #expect(frame.contains("→ List Sources/"))
        #expect(frame.contains("⚙ Todos 1 item"))
        #expect(!frame.contains("secret search preview"))
        #expect(!frame.contains("secret ls preview"))
        #expect(!frame.contains("secret todo preview"))

        // Column alignment: shell command, compact read/search, and turn footer share exact vertical spine
        let shellPos = try #require(Self.findSubstring("$ cat build.log", in: lines))
        let searchPos = try #require(Self.findSubstring("✱ Search", in: lines))
        let footerPos = try #require(Self.findSubstring("▣ Build", in: lines))
        #expect(shellPos.x == searchPos.x)
        #expect(footerPos.x == searchPos.x)
    }

    @Test("toolIcon preserves public signature and maps upstream glyphs across running, error, and completed states")
    func toolIconUpstreamGlyphMapping() {
        #expect(TUIScreens.toolIcon(for: "read", status: .completed, spinnerTick: 0) == "→")
        #expect(TUIScreens.toolIcon(for: "fs_read", status: .completed, spinnerTick: 0) == "→")
        #expect(TUIScreens.toolIcon(for: "glob", status: .completed, spinnerTick: 0) == "✱")
        #expect(TUIScreens.toolIcon(for: "grep", status: .completed, spinnerTick: 0) == "✱")
        #expect(TUIScreens.toolIcon(for: "webfetch", status: .completed, spinnerTick: 0) == "◈")
        #expect(TUIScreens.toolIcon(for: "websearch", status: .completed, spinnerTick: 0) == "◈")
        #expect(TUIScreens.toolIcon(for: "shell", status: .completed, spinnerTick: 0) == "$")
        #expect(TUIScreens.toolIcon(for: "bash", status: .completed, spinnerTick: 0) == "$")
        #expect(TUIScreens.toolIcon(for: "edit", status: .completed, spinnerTick: 0) == "←")
        #expect(TUIScreens.toolIcon(for: "write", status: .completed, spinnerTick: 0) == "←")
        #expect(TUIScreens.toolIcon(for: "apply_patch", status: .completed, spinnerTick: 0) == "←")
        #expect(TUIScreens.toolIcon(for: "read", status: .error, spinnerTick: 0) == "✗")
        #expect(TUIScreens.toolIcon(for: "shell", status: .running, spinnerTick: 0) == "⠋")
        #expect(TUIScreens.toolIcon(for: "read", status: .streaming, spinnerTick: 1) == "⠙")
    }
}
