import Testing
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables

@Suite("TUI Multiline, Paste Summaries, Session Tabs, Queued Prompts, Embedded Terminal & Mouse (Full Parity P4)")
struct TUIMultilineTabsTerminalTests {

    // MARK: - 1. Multiline Prompt Editing & Auto-Growing Composer

    @Test("Shift+Return (Kitty), Ctrl+Return, Alt+Return, and Ctrl+J insert real newlines and render multiline composer cleanly")
    func multilineNewlineInsertionAndRendering() async {
        // Test Shift+Return and Ctrl+Return in Kitty keyboard mode
        let kittyState = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light)
        let kittyHarness = P4InteractiveHarness(width: 100, height: 34, state: kittyState, kittyKeyboard: true)
        defer { kittyHarness.destroy() }

        kittyHarness.testRenderer.mockInput.typeText("First line")
        kittyHarness.testRenderer.mockInput.pressReturn(modifiers: MockKeyModifiers(shift: true))
        kittyHarness.testRenderer.mockInput.typeText("Second line")
        kittyHarness.testRenderer.mockInput.pressReturn(modifiers: MockKeyModifiers(ctrl: true))
        kittyHarness.testRenderer.mockInput.typeText("Third line")

        let draft = kittyHarness.store.snapshot().promptText
        #expect(draft == "First line\nSecond line\nThird line")

        let frame = kittyHarness.frame()
        #expect(frame.contains("First line"))
        #expect(frame.contains("Second line"))
        #expect(frame.contains("Third line"))

        // Plain Return submits the FULL multiline prompt cleanly to the server!
        kittyHarness.testRenderer.mockInput.pressReturn()
        let submitted = await kittyHarness.waitUntil {
            kittyHarness.mockServer.recordedRequests().contains {
                $0.method == "POST" && $0.url.hasSuffix("/prompt")
            }
        }
        #expect(submitted == true)
        let promptReq = kittyHarness.mockServer.recordedRequests().first {
            $0.method == "POST" && $0.url.hasSuffix("/prompt")
        }
        #expect(promptReq?.body.contains("First line\\nSecond line\\nThird line") == true)
        #expect(kittyHarness.store.snapshot().promptText.isEmpty)

        // Test Ctrl+J (legacy 0x0A -> linefeed) and Alt+Return in standard non-Kitty mode
        let legacyState = P4Fixtures.makeHomeState(width: 100, height: 34, mode: .dark)
        let legacyHarness = P4InteractiveHarness(width: 100, height: 34, state: legacyState, kittyKeyboard: false)
        defer { legacyHarness.destroy() }

        legacyHarness.testRenderer.mockInput.typeText("Alpha")
        legacyHarness.testRenderer.mockInput.pressKey("j", modifiers: MockKeyModifiers(ctrl: true))
        legacyHarness.testRenderer.mockInput.typeText("Beta")
        legacyHarness.testRenderer.mockInput.pressReturn(modifiers: MockKeyModifiers(meta: true))
        legacyHarness.testRenderer.mockInput.typeText("Gamma")
        #expect(legacyHarness.store.snapshot().promptText == "Alpha\nBeta\nGamma")

        let legacyFrame = legacyHarness.frame()
        #expect(legacyFrame.contains("Alpha"))
        #expect(legacyFrame.contains("Beta"))
        #expect(legacyFrame.contains("Gamma"))

        // Backspace on an empty bottom line merges back onto the prior line
        legacyHarness.testRenderer.mockInput.pressKey("j", modifiers: MockKeyModifiers(ctrl: true))
        #expect(legacyHarness.store.snapshot().promptText == "Alpha\nBeta\nGamma\n")
        legacyHarness.testRenderer.mockInput.pressBackspace()
        #expect(legacyHarness.store.snapshot().promptText == "Alpha\nBeta\nGamma")
    }

    @Test("Multiline composer auto-grows up to 6 visible lines and shows overflow indicator above 6 lines")
    func multilineAutoGrowCapAtSixLines() {
        var state = P4Fixtures.makeHomeState(width: 100, height: 34, mode: .light)
        state.promptText = (1...8).map { "DraftLine\($0)" }.joined(separator: "\n")
        let harness = P4InteractiveHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        // 8 lines total -> 5 visible prefix lines (lines 3..7) + active line (line 8), 2 hidden lines
        #expect(frame.contains("↑ 2 more lines"))
        #expect(!frame.contains("DraftLine1"))
        #expect(!frame.contains("DraftLine2"))
        #expect(frame.contains("DraftLine3"))
        #expect(frame.contains("DraftLine7"))
        #expect(frame.contains("DraftLine8"))
    }

    // MARK: - 2. Large Paste Summaries (`TUIPasteManager` & Bracketed Paste)

    @Test("TUIPasteManager detects large pastes (>=4 lines or >=300 chars), stores blocks, expands duplicates safely, and prunes deleted tokens")
    func pasteManagerUnitBehavior() {
        var blocks: [TUIPastedBlock] = []

        // Short paste (<4 lines and <300 chars) is inserted directly even when pasteSummary=true
        let shortResult = TUIPasteManager.preparePaste("line 1\nline 2\nline 3", pasteSummaryEnabled: true, blocks: &blocks)
        #expect(shortResult == "line 1\nline 2\nline 3")
        #expect(blocks.isEmpty)

        // Large paste (>=4 lines) with ANSI + CRLF is normalized and summarized
        let firstPayload = "\u{1B}[31malpha\u{1B}[0m\r\nbeta\r\ngamma\r\ndelta"
        let firstToken = TUIPasteManager.preparePaste(firstPayload, pasteSummaryEnabled: true, blocks: &blocks)
        #expect(firstToken == "[Pasted ~4 lines]")
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "alpha\nbeta\ngamma\ndelta")
        #expect(blocks[0].lineCount == 4)

        // Second paste with the SAME line count (4 lines) gets its own block and expands accurately in order
        let secondPayload = "one\ntwo\nthree\nfour"
        let secondToken = TUIPasteManager.preparePaste(secondPayload, pasteSummaryEnabled: true, blocks: &blocks)
        #expect(secondToken == "[Pasted ~4 lines]")
        #expect(blocks.count == 2)

        let combined = "First: \(firstToken) | Second: \(secondToken)"
        let expanded = TUIPasteManager.expand(combined, blocks: blocks)
        #expect(expanded == "First: alpha\nbeta\ngamma\ndelta | Second: one\ntwo\nthree\nfour")

        // Single-line >=300 chars triggers summary too
        let longLine = String(repeating: "x", count: 310)
        var longBlocks: [TUIPastedBlock] = []
        let longToken = TUIPasteManager.preparePaste(longLine, pasteSummaryEnabled: true, blocks: &longBlocks)
        #expect(longToken == "[Pasted ~1 lines]")
        #expect(TUIPasteManager.expand("Check \(longToken)", blocks: longBlocks) == "Check \(longLine)")

        // Deleting one token prunes unused block
        TUIPasteManager.pruneUnusedBlocks(in: "Only one [Pasted ~4 lines] left", blocks: &blocks)
        #expect(blocks.count == 1)
        TUIPasteManager.pruneUnusedBlocks(in: "All removed", blocks: &blocks)
        #expect(blocks.isEmpty)
    }

    @Test("Bracketed paste summarizes large pastes into [Pasted ~N lines] chips and expands full text on submit")
    func bracketedPasteSummaryAndExpandEndToEnd() async {
        var state = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light)
        state.preferences.pasteSummary = true
        let harness = P4InteractiveHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        harness.testRenderer.mockInput.typeText("Explain: ")
        let sixLines = "func a() {}\nfunc b() {}\nfunc c() {}\nfunc d() {}\nfunc e() {}\nfunc f() {}"
        harness.testRenderer.mockInput.pasteBracketedText(sixLines)

        let snap = harness.store.snapshot()
        #expect(snap.promptText == "Explain: [Pasted ~6 lines]")
        #expect(snap.pastedBlocks.count == 1)
        #expect(snap.pastedBlocks[0].text == sixLines)

        let frame = harness.frame()
        #expect(frame.contains("[Pasted ~6 lines]"))

        // Submit expands [Pasted ~6 lines] back to exact full text!
        harness.testRenderer.mockInput.pressReturn()
        let submitted = await harness.waitUntil {
            harness.mockServer.recordedRequests().contains {
                $0.method == "POST" && $0.url.hasSuffix("/prompt")
            }
        }
        #expect(submitted == true)
        let req = harness.mockServer.recordedRequests().first { $0.method == "POST" && $0.url.hasSuffix("/prompt") }
        #expect(req?.body.contains("func a() {}\\nfunc b() {}") == true)
        #expect(req?.body.contains("func f() {}") == true)
        #expect(req?.body.contains("[Pasted ~6 lines]") == false)
        #expect(harness.store.snapshot().pastedBlocks.isEmpty)

        // When pasteSummary == false, large paste flows directly as multiline text
        harness.store.withLock { $0.preferences.pasteSummary = false }
        harness.testRenderer.mockInput.pasteBracketedText("raw1\nraw2\nraw3\nraw4")
        #expect(harness.store.snapshot().promptText == "raw1\nraw2\nraw3\nraw4")
        #expect(harness.store.snapshot().pastedBlocks.isEmpty)
        let rawFrame = harness.frame()
        #expect(rawFrame.contains("raw1"))
        #expect(rawFrame.contains("raw4"))
    }

    @Test("Bracketed paste flows cleanly into API Key and Rename Session dialogs")
    func bracketedPasteIntoDialogs() {
        let state = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light)
        let harness = P4InteractiveHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        // Paste into API Key dialog strips trailing newline
        harness.store.withLock { s in
            s.connectTargetIntegrationID = "openai"
            s.connectTargetIntegrationName = "OpenAI"
            s.activeDialog = .connectAPIKey
            s.dialogFilter = ""
        }
        harness.render()
        harness.testRenderer.mockInput.pasteBracketedText("sk-live-secret-123\n")
        #expect(harness.store.snapshot().dialogFilter == "sk-live-secret-123")

        // Paste into Rename Session dialog
        harness.controller.openRenameSessionDialog(sessionID: "ses_demo01", currentTitle: "")
        harness.render()
        harness.testRenderer.mockInput.pasteBracketedText("Refactored Auth Flow")
        #expect(harness.store.snapshot().renameDraft == "Refactored Auth Flow")
    }

    // MARK: - 3. Top Session Tabs Strip & Tab Cycling

    @Test("Session Tabs bar is hidden when <=1 tab open, renders when >=2 tabs open, and supports cycling, leader 1..2, close, reopen, and click")
    func sessionTabsBarAndNavigation() {
        // 1 tab -> tab bar hidden
        let singleState = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light, openTabs: ["ses_demo01"])
        let singleHarness = P4InteractiveHarness(width: 100, height: 34, state: singleState)
        defer { singleHarness.destroy() }
        #expect(singleHarness.testRenderer.root.findDescendantById("opencode-session-tabs") == nil)

        // 2 tabs -> tab bar visible right above session header
        let multiState = P4Fixtures.makeSessionState(
            width: 100,
            height: 34,
            mode: .light,
            openTabs: ["ses_demo01", "ses_demo02"]
        )
        let harness = P4InteractiveHarness(width: 100, height: 34, state: multiState, kittyKeyboard: true)
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(harness.testRenderer.root.findDescendantById("opencode-session-tabs") != nil)
        #expect(frame.contains("1 Port OpenCode"))
        #expect(frame.contains("2 Verify OpenTUI"))
        #expect(frame.contains(" + "))

        // Verify tab strip sits above `# Port OpenCode to Swift 6.2` header
        let tabNode = harness.testRenderer.root.findDescendantById("opencode-session-tabs")
        let headerNode = harness.testRenderer.root.findDescendantById("opencode-session-header")
        #expect((tabNode?.y ?? 99) < (headerNode?.y ?? 0))

        // Active tab has highlighted background distinct from inactive tab
        let tab0Node = harness.testRenderer.root.findDescendantById("session-tab-0")
        let tab1Node = harness.testRenderer.root.findDescendantById("session-tab-1")
        if let t0 = tab0Node, let t1 = tab1Node {
            #expect(harness.cellBackground(x: t0.x + 1, y: t0.y) != harness.cellBackground(x: t1.x + 1, y: t1.y))
        }

        // Ctrl+Tab cycles to tab 2
        harness.testRenderer.mockInput.pressTab(modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().activeSessionID == "ses_demo02")

        // <leader>1 jumps directly back to tab 1
        harness.pressLeader("1")
        #expect(harness.store.snapshot().activeSessionID == "ses_demo01")

        // <leader>2 jumps to tab 2
        harness.pressLeader("2")
        #expect(harness.store.snapshot().activeSessionID == "ses_demo02")

        // <leader>w closes tab 2 and falls back to tab 1
        harness.pressLeader("w")
        #expect(harness.store.snapshot().activeSessionID == "ses_demo01")
        #expect(harness.store.snapshot().openSessionTabs == ["ses_demo01"])
        #expect(harness.store.snapshot().closedSessionTabs.contains("ses_demo02"))

        // Ctrl+Shift+T reopens the closed tab!
        harness.testRenderer.mockInput.pressKey("t", modifiers: MockKeyModifiers(shift: true, ctrl: true))
        #expect(harness.store.snapshot().activeSessionID == "ses_demo02")
        #expect(harness.store.snapshot().openSessionTabs == ["ses_demo01", "ses_demo02"])

        // Mouse click on tab 1 switches back to ses_demo01
        #expect(harness.clickRenderable(id: "session-tab-0") == true)
        #expect(harness.store.snapshot().activeSessionID == "ses_demo01")

        // Mouse click on '+' starts a new session on Home
        #expect(harness.clickRenderable(id: "session-tab-new") == true)
        #expect(harness.store.snapshot().isHome == true)
        #expect(harness.store.snapshot().activeSessionID == nil)
    }

    @Test("Session Tabs bar truncates cleanly and displays overflow count on narrow widths")
    func sessionTabsNarrowWidthTruncation() {
        let extras = [
            TUISessionItem(id: "ses_3", title: "Long Session Title Number Three"),
            TUISessionItem(id: "ses_4", title: "Long Session Title Number Four"),
            TUISessionItem(id: "ses_5", title: "Long Session Title Number Five"),
        ]
        let state = P4Fixtures.makeSessionState(
            width: 48,
            height: 24,
            mode: .dark,
            openTabs: ["ses_demo01", "ses_demo02", "ses_3", "ses_4", "ses_5"],
            extraSessions: extras
        )
        let harness = P4InteractiveHarness(width: 48, height: 24, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(harness.testRenderer.root.findDescendantById("opencode-session-tabs") != nil)
        #expect(frame.contains("1 "))
        #expect(frame.contains(">"))
    }

    // MARK: - 4. Queued Prompts Management (`<leader>return` & `<leader>q`)

    @Test("Queued prompts flow: <leader>return queues prompt, renders badge, <leader>q opens dialog, Ctrl+U undoes to composer, Ctrl+D deletes")
    func queuedPromptsEndToEnd() async {
        let state = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light, running: true)
        let harness = P4InteractiveHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        // Type first prompt while running and press <leader>return -> queues via delivery: .queue
        harness.testRenderer.mockInput.typeText("Follow up check tests")
        harness.pressLeaderReturn()

        let queuedFirst = await harness.waitUntil {
            harness.mockServer.recordedRequests().contains {
                $0.method == "POST" && $0.url.hasSuffix("/prompt") && $0.body.contains("\"queue\"")
            }
        }
        #expect(queuedFirst == true)
        #expect(harness.store.snapshot().promptText.isEmpty)
        #expect(harness.store.snapshot().queuedPrompts.count == 1)
        #expect(harness.store.snapshot().queuedPrompts[0].text == "Follow up check tests")

        // Subtle queued count badge renders above composer
        let badgeFrame = harness.frame()
        #expect(badgeFrame.contains("1 queued prompt · ctrl+x q to manage"))

        // Queue a second prompt
        harness.testRenderer.mockInput.typeText("Then update docs")
        harness.pressLeaderReturn()
        let queuedSecond = await harness.waitUntil {
            harness.store.snapshot().queuedPrompts.count == 2
                && harness.store.snapshot().queuedPrompts.allSatisfy { $0.id.hasPrefix("msg_p4_") }
        }
        #expect(queuedSecond == true)
        #expect(harness.frame().contains("2 queued prompts · ctrl+x q to manage"))

        // Open Queued Prompts dialog via <leader>q
        harness.pressLeader("q")
        #expect(harness.store.snapshot().activeDialog == .queuedPrompts)
        let dialogFrame = harness.frame()
        #expect(dialogFrame.contains("Queued prompts"))
        #expect(dialogFrame.contains("Follow up check tests"))
        #expect(dialogFrame.contains("Then update docs"))
        #expect(dialogFrame.contains("ctrl+u undo"))
        #expect(dialogFrame.contains("ctrl+d delete"))

        // Ctrl+D deletes the selected first queued prompt via DELETE /api/session/:id/inbox/:inboxID
        let firstID = harness.store.snapshot().queuedPrompts[0].id
        harness.testRenderer.mockInput.pressKey("d", modifiers: MockKeyModifiers(ctrl: true))
        let deleted = await harness.waitUntil {
            harness.mockServer.recordedRequests().contains {
                $0.method == "DELETE" && $0.url.contains("/inbox/\(firstID)")
            }
        }
        #expect(deleted == true)
        #expect(harness.store.snapshot().queuedPrompts.count == 1)
        #expect(harness.store.snapshot().queuedPrompts[0].text == "Then update docs")

        // Ctrl+U undoes the remaining queued prompt: cancels inbox item and restores text into promptText!
        let secondID = harness.store.snapshot().queuedPrompts[0].id
        harness.testRenderer.mockInput.pressKey("u", modifiers: MockKeyModifiers(ctrl: true))
        let undone = await harness.waitUntil {
            harness.mockServer.recordedRequests().contains {
                $0.method == "DELETE" && $0.url.contains("/inbox/\(secondID)")
            }
        }
        #expect(undone == true)
        #expect(harness.store.snapshot().activeDialog == nil)
        #expect(harness.store.snapshot().queuedPrompts.isEmpty)
        #expect(harness.store.snapshot().promptText == "Then update docs")
        let restoredFrame = harness.frame()
        #expect(!restoredFrame.contains("ctrl+x q to manage"))
        #expect(harness.testRenderer.root.findDescendantById("opencode-queued-badge") == nil)
        #expect(restoredFrame.contains("Then update docs"))
    }

    @Test("/queue slash command and Command Palette 'Manage queued prompts' open dialog and sync from server inbox")
    func queuedPromptsSlashCommandAndPaletteSync() async {
        let server = P4MockServer(initialInbox: [
            P4MockServer.P4InboxMockItem(
                id: "msg_inbox_remote_1",
                sessionID: "ses_demo01",
                text: "Remote queued task",
                delivery: "queue"
            ),
        ])
        let state = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .dark, running: true)
        let harness = P4InteractiveHarness(width: 100, height: 34, state: state, mockServer: server)
        defer { harness.destroy() }

        // Open via /queue slash command -> syncs from GET /api/session/ses_demo01/inbox
        harness.controller.submitPrompt(rawText: "/queue")
        #expect(harness.store.snapshot().activeDialog == .queuedPrompts)
        let synced = await harness.waitUntil {
            harness.store.snapshot().queuedPrompts.contains { $0.id == "msg_inbox_remote_1" }
        }
        #expect(synced == true)
        #expect(harness.frame().contains("Remote queued task"))

        // Close and open via Command Palette
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().activeDialog == nil)
        harness.testRenderer.mockInput.pressKey("p", modifiers: MockKeyModifiers(ctrl: true))
        harness.testRenderer.mockInput.typeText("queued")
        let paletteFrame = harness.frame()
        #expect(paletteFrame.contains("Manage queued prompts"))
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .queuedPrompts)

        // SSE session.inbox.delivered removes item from queuedPrompts
        var s = harness.store.snapshot()
        _ = TUIInteractiveClient.applyServerEvent(
            P4Fixtures.makeEvent(type: "session.inbox.delivered", data: [
                "sessionID": .string("ses_demo01"),
                "id": .string("msg_inbox_remote_1"),
            ]),
            to: &s
        )
        #expect(s.queuedPrompts.isEmpty)
    }

    // MARK: - 5. Embedded Live Terminal Pane (`<leader>t`, `<leader>up`, `<leader>left/right`, `/terminal`)

    @Test("Embedded Terminal pane toggles with <leader>t, runs commands, switches focus with <leader>left/right, closes with <leader>up, and renders in Light & Dark modes")
    func embeddedTerminalPaneLifecycleAndThemeParity() async {
        let lightState = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light)
        let harness = P4InteractiveHarness(width: 100, height: 34, state: lightState)
        defer { harness.destroy() }

        #expect(harness.store.snapshot().terminalPane.isOpen == false)

        // <leader>t opens embedded terminal pane and calls POST /api/pty
        harness.pressLeader("t")
        #expect(harness.store.snapshot().terminalPane.isOpen == true)
        #expect(harness.store.snapshot().terminalPane.isFocused == true)

        let ptyCreated = await harness.waitUntil {
            harness.store.snapshot().terminalPane.ptyID != nil
        }
        #expect(ptyCreated == true)

        let lightFrame = harness.frame()
        #expect(lightFrame.contains("Terminal"))
        #expect(lightFrame.contains("ctrl+x ↑ close"))
        #expect(lightFrame.contains("● pty"))

        // Light mode surface color check
        if let paneNode = harness.testRenderer.root.findDescendantById("terminal-pane-output") {
            let lightTheme = harness.store.snapshot().resolveTheme()
            #expect(harness.cellBackground(x: paneNode.x + 1, y: paneNode.y) == lightTheme.background.raised.base)
        } else {
            Issue.record("Expected terminal-pane-output renderable in light mode")
        }

        // Type & submit command inside focused terminal pane
        harness.testRenderer.mockInput.typeText("echo hello")
        harness.testRenderer.mockInput.pressReturn()
        let gotOutput = await harness.waitUntil {
            harness.store.snapshot().terminalPane.outputLines.contains("hello from embedded terminal")
        }
        #expect(gotOutput == true)
        let outputFrame = harness.frame()
        #expect(outputFrame.contains("$ echo hello"))
        #expect(outputFrame.contains("hello from embedded terminal"))

        // Switch to Dark Mode and verify pane renders crisply with Dark theme raised background
        harness.controller.toggleThemeMode()
        let darkFrame = harness.frame()
        #expect(darkFrame.contains("Terminal"))
        #expect(darkFrame.contains("hello from embedded terminal"))
        if let paneNode = harness.testRenderer.root.findDescendantById("terminal-pane-output") {
            let darkTheme = harness.store.snapshot().resolveTheme()
            #expect(harness.cellBackground(x: paneNode.x + 1, y: paneNode.y) == darkTheme.background.raised.base)
        }

        // <leader>left returns focus to session prompt; <leader>right returns focus to terminal
        harness.pressLeaderArrow(.left)
        #expect(harness.store.snapshot().terminalPane.isFocused == false)
        harness.pressLeaderArrow(.right)
        #expect(harness.store.snapshot().terminalPane.isFocused == true)

        // <leader>up closes terminal pane and calls DELETE /api/pty/:id
        let activePtyID = harness.store.snapshot().terminalPane.ptyID ?? ""
        harness.pressLeaderArrow(.up)
        #expect(harness.store.snapshot().terminalPane.isOpen == false)
        #expect(harness.store.snapshot().terminalPane.isFocused == false)
        let ptyRemoved = await harness.waitUntil {
            harness.mockServer.recordedRequests().contains {
                $0.method == "DELETE" && $0.url.contains("/api/pty/\(activePtyID)")
            }
        }
        #expect(ptyRemoved == true)

        // /terminal slash command reopens the terminal pane
        harness.controller.submitPrompt(rawText: "/terminal")
        #expect(harness.store.snapshot().terminalPane.isOpen == true)
        // Clicking 'ctrl+x ↑ close' closes the pane cleanly
        #expect(harness.clickRenderable(id: "terminal-pane-close") == true)
        #expect(harness.store.snapshot().terminalPane.isOpen == false)

        // Command Palette 'Toggle terminal pane' opens pane; 'clear' clears output; 'exit' closes pane
        harness.testRenderer.mockInput.pressKey("p", modifiers: MockKeyModifiers(ctrl: true))
        harness.testRenderer.mockInput.typeText("terminal")
        #expect(harness.frame().contains("Toggle terminal pane"))
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().terminalPane.isOpen == true)
        harness.controller.appendTerminalOutput("transient line")
        #expect(harness.store.snapshot().terminalPane.outputLines.contains("transient line"))
        harness.controller.submitTerminalCommand("clear")
        #expect(harness.store.snapshot().terminalPane.outputLines.isEmpty)
        harness.controller.submitTerminalCommand("exit")
        #expect(harness.store.snapshot().terminalPane.isOpen == false)
    }

    // MARK: - 6. Interactive Mouse Click Support

    @Test("Mouse clicks confirm dialog rows, open Home footer MCP dialog, open queued prompts badge, steer queued prompt, and refocus prompt composer")
    func interactiveMouseClicks() async {
        // 1. Clicking Home footer MCP badge opens .mcpStatus dialog
        let homeState = P4Fixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let homeHarness = P4InteractiveHarness(width: 100, height: 34, state: homeState)
        defer { homeHarness.destroy() }

        #expect(homeHarness.clickText("⊙ 3 MCP") == true)
        #expect(homeHarness.store.snapshot().activeDialog == .mcpStatus)
        homeHarness.pressEscapeAndFlush()
        #expect(homeHarness.store.snapshot().activeDialog == nil)

        // 2. Clicking row 1 ("GPT-5.3 Codex") in Model Picker selects & confirms that model!
        homeHarness.controller.openModelPicker(providerID: nil)
        homeHarness.render()
        #expect(homeHarness.store.snapshot().selectedModel?.id == "claude-sonnet-4-5")
        #expect(homeHarness.clickRenderable(id: "dialog-row-1") == true)
        #expect(homeHarness.store.snapshot().activeDialog == nil)
        #expect(homeHarness.store.snapshot().selectedModel?.id == "gpt-5.3-codex")

        // 3. Clicking row 1 ("Plan") in Agent Picker selects & confirms Plan agent!
        homeHarness.controller.openAgentPicker()
        homeHarness.render()
        #expect(homeHarness.store.snapshot().activeAgent.id == "build")
        #expect(homeHarness.clickRenderable(id: "dialog-row-1") == true)
        #expect(homeHarness.store.snapshot().activeDialog == nil)
        #expect(homeHarness.store.snapshot().activeAgent.id == "plan")

        // 4. Clicking prompt composer when terminal pane is focused refocuses the prompt composer!
        homeHarness.controller.toggleTerminalPane()
        homeHarness.render()
        #expect(homeHarness.store.snapshot().terminalPane.isFocused == true)
        #expect(homeHarness.clickRenderable(id: "opencode-prompt-box") == true)
        #expect(homeHarness.store.snapshot().terminalPane.isFocused == false)

        // 5. Clicking queued prompt badge opens .queuedPrompts and clicking row 0 steers it via PATCH /inbox/:id
        let server = P4MockServer(initialInbox: [
            P4MockServer.P4InboxMockItem(
                id: "msg_click_steer",
                sessionID: "ses_demo01",
                text: "Promote me now",
                delivery: "queue"
            ),
        ])
        var sessionState = P4Fixtures.makeSessionState(width: 100, height: 34, mode: .light, running: true)
        sessionState.queuedPrompts = [TUIQueuedPromptItem(id: "msg_click_steer", text: "Promote me now", delivery: "queue")]
        let sessionHarness = P4InteractiveHarness(width: 100, height: 34, state: sessionState, mockServer: server)
        defer { sessionHarness.destroy() }

        #expect(sessionHarness.clickRenderable(id: "opencode-queued-badge") == true)
        #expect(sessionHarness.store.snapshot().activeDialog == .queuedPrompts)
        #expect(sessionHarness.clickRenderable(id: "dialog-row-0") == true)
        let steered = await sessionHarness.waitUntil {
            sessionHarness.mockServer.recordedRequests().contains {
                $0.method == "PATCH" && $0.url.contains("/inbox/msg_click_steer") && $0.body.contains("\"steer\"")
            }
        }
        #expect(steered == true)
        #expect(sessionHarness.store.snapshot().activeDialog == nil)
    }
}
