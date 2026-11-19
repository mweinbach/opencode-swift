import OpenCodePlatform
import Synchronization
import Testing
import OpenCodeClient
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView

@Suite("Real Upstream OpenCode 2.3.2 TUI Parity")
struct TUIRealParityTests {

    // MARK: - 1. OSC 11 & COLORFGBG Auto Light/Dark Theme Detection

    @Test("OSC 11 detection classifies white as light and dark as dark (BEL and ST terminators)")
    func osc11Detection() {
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;rgb:ffff/ffff/ffff\u{07}") == .light)
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\") == .light)
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;rgb:f8f8/f8f8/fafa\u{07}") == .light)
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;#ffffff\u{07}") == .light)

        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;rgb:1212/1212/1212\u{07}") == .dark)
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;rgb:0a0a/0a0a/0a0a\u{1B}\\") == .dark)
        #expect(TerminalThemeDetector.parseOSC11Response("\u{1B}]11;#0a0a0a\u{07}") == .dark)
        #expect(TerminalThemeDetector.parseOSC11Response("plain text") == nil)
    }

    @Test("OSC 11 extractor strips probe reply while preserving type-ahead user keystrokes")
    func osc11ExtractorPreservesLeftoverBytes() {
        let payload = Array("hi\u{1B}]11;rgb:ffff/ffff/ffff\u{07}!".utf8)
        let extracted = TerminalThemeDetector.extractOSC11(from: payload)
        #expect(extracted.mode == .light)
        #expect(String(decoding: extracted.remaining, as: UTF8.self) == "hi!")
    }

    @Test("COLORFGBG environment fallback detects light and dark terminals")
    func colorfgbgFallbackDetection() {
        #expect(TerminalThemeDetector.detectFromEnvironment(["COLORFGBG": "0;15"]) == .light)
        #expect(TerminalThemeDetector.detectFromEnvironment(["COLORFGBG": "0;default;15"]) == .light)
        #expect(TerminalThemeDetector.detectFromEnvironment(["COLORFGBG": "0;7"]) == .light)
        #expect(TerminalThemeDetector.detectFromEnvironment(["COLORFGBG": "15;0"]) == .dark)
        #expect(TerminalThemeDetector.detectFromEnvironment(["COLORFGBG": "15;8"]) == .dark)
        #expect(TerminalThemeDetector.detectFromEnvironment([:]) == nil)
    }

    // MARK: - 2. Home Screen Visual Parity (Light & Dark Modes)

    @Test("Home screen in Light Mode matches upstream 2.3.2 layout, dual-tone logo, left-bordered prompt, and white canvas")
    func homeScreenLightModeVisualParity() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Exact dual-tone 3D shadow `opencode` block logo present and centered
        #expect(frame.contains("█▀▀█"))
        #expect(frame.contains("█▀▀▄"))
        #expect(frame.contains("█▀▀▀"))
        #expect(frame.contains("▀▀▀▀"))
        if let logoRow = lines.first(where: { $0.contains("█▀▀█") && $0.contains("█▀▀▄") }) {
            let leadingSpaces = logoRow.prefix(while: { $0 == " " }).count
            #expect(leadingSpaces >= 20, "Logo should be centered horizontally on 100-col canvas, got leading=\(leadingSpaces)")
        } else {
            Issue.record("Expected wide opencode logo row in frame:\n\(frame)")
        }

        // Exact left-only bordered prompt box (`┃` + `╹` cap + `▀` bottom edge, NO 4-sided rounded box!)
        #expect(frame.contains("┃"))
        #expect(frame.contains("╹"))
        #expect(frame.contains("▀"))
        #expect(!frame.contains("╭"))
        #expect(!frame.contains("╮"))
        #expect(!frame.contains("╰"))
        #expect(!frame.contains("╯"))

        // Prompt placeholder + metadata row (`Build · Claude Sonnet 4.5 Anthropic`)
        #expect(frame.contains("Ask anything…"))
        #expect(frame.contains("What is the tech stack of this project?"))
        #expect(frame.contains("Build"))
        #expect(frame.contains("Claude Sonnet 4.5"))
        #expect(frame.contains("Anthropic"))

        // Single clean info row directly beneath prompt box
        #expect(frame.contains("~/.t3/projects/swift-opencode:main"))
        #expect(frame.contains("shift+tab agents"))
        #expect(frame.contains("ctrl+p commands"))

        // Minimal bottom-edge footer
        #expect(frame.contains("⊙ 3 MCP"))
        #expect(frame.contains("/mcps"))
        #expect(frame.contains("2.3.2"))

        // NO legacy debug dashboard chrome!
        #expect(!frame.contains("OPENCODE SWIFT"))
        #expect(!frame.contains("Recent Sessions"))
        #expect(!frame.contains("100% Parity Native Swift"))

        // Light Mode root canvas background RGBA is crisp white (#ffffff) with zero stray dark cells!
        let lightTheme = state.resolveTheme()
        let expectedWhite = lightTheme.background.base
        let expectedPromptBg = lightTheme.decrease(lightTheme.background.raised.base)
        let expectedAgentColor = state.agentColor(theme: lightTheme)
        #expect(expectedWhite == RGBA.fromHex("#ffffff"))
        #expect(expectedPromptBg == RGBA.fromHex("#f5f5f5"))
        #expect(expectedAgentColor == RGBA.fromHex("#7b5bb6"))
        #expect(harness.cellBackground(x: 0, y: 0) == expectedWhite)
        #expect(harness.cellBackground(x: 99, y: 0) == expectedWhite)
        #expect(harness.cellBackground(x: 0, y: 33) == expectedWhite)
        #expect(harness.cellBackground(x: 99, y: 33) == expectedWhite)

        // Verify left border `┃` uses purple agent color, inner prompt fill uses `#f5f5f5`,
        // and bottom cap `▀` uses `#f5f5f5` fg over `#ffffff` bg!
        if let promptRowIdx = lines.firstIndex(where: { $0.contains("Ask anything…") }),
           let barCol = lines[promptRowIdx].firstIndex(of: "┃") {
            let x = lines[promptRowIdx].distance(from: lines[promptRowIdx].startIndex, to: barCol)
            #expect(harness.cellForeground(x: x, y: promptRowIdx) == expectedAgentColor)
            #expect(harness.cellBackground(x: x, y: promptRowIdx) == expectedWhite)
            #expect(harness.cellBackground(x: x + 2, y: promptRowIdx) == expectedPromptBg)
        } else {
            Issue.record("Expected prompt row with left vertical rail ┃")
        }

        if let capRowIdx = lines.firstIndex(where: { $0.contains("╹▀") }),
           let capCol = lines[capRowIdx].firstIndex(of: "╹") {
            let x = lines[capRowIdx].distance(from: lines[capRowIdx].startIndex, to: capCol)
            #expect(harness.cellForeground(x: x, y: capRowIdx) == expectedAgentColor)
            #expect(harness.cellForeground(x: x + 1, y: capRowIdx) == expectedPromptBg)
            #expect(harness.cellBackground(x: x + 1, y: capRowIdx) == expectedWhite)
        } else {
            Issue.record("Expected prompt bottom cap row with ╹▀")
        }

        // Verify 3D shadow cell (`_`) in opencode logo uses exact `tint(bg, muted, 0.25)`
        if let shadowRowIdx = lines.firstIndex(where: { $0.contains("█  █ █  █ █▀▀▀") }),
           let firstBlock = lines[shadowRowIdx].firstIndex(of: "█") {
            let x = lines[shadowRowIdx].distance(from: lines[shadowRowIdx].startIndex, to: firstBlock)
            let expectedShadow = TUIThemeBridge.tint(lightTheme.background.base, overlay: lightTheme.text.muted, alpha: 0.25)
            #expect(harness.cellBackground(x: x + 1, y: shadowRowIdx) == expectedShadow)
        } else {
            Issue.record("Expected opencode logo shadow row")
        }
    }

    @Test("Home screen in Dark Mode renders dark background canvas and hides MCP indicator when 0 MCPs exist")
    func homeScreenDarkModeAndZeroMCP() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .dark, mcpServers: [])
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        let darkTheme = state.resolveTheme()
        #expect(harness.cellBackground(x: 0, y: 0) == darkTheme.background.base)
        #expect(harness.cellBackground(x: 0, y: 0) == RGBA.fromHex("#0a0a0a"))

        // 0 MCPs -> hidden from footer, version still visible
        #expect(!frame.contains("MCP"))
        #expect(frame.contains("2.3.2"))
        #expect(frame.contains("shift+tab agents"))
        #expect(frame.contains("ctrl+p commands"))
    }

    @Test("Home screen footer shows failed MCP count when any MCP server failed")
    func homeFooterFailedMCP() {
        let state = TUIRealParityFixtures.makeHomeState(
            width: 100,
            height: 34,
            mode: .light,
            mcpServers: [
                TUIMCPServerItem(name: "github", status: .connected),
                TUIMCPServerItem(name: "broken", status: .failed("connection refused")),
            ]
        )
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(frame.contains("⊙ 1 MCP failed"))
        #expect(frame.contains("/mcps"))
    }

    @Test("Logo obeys exact upstream responsive breakpoints (<12 hidden, <22 compact, <44 stacked, >=44 wide)")
    func logoResponsiveBreakpoints() {
        // Hidden when height < 12
        let shortFrame = TUIInteractiveLoop.renderPreviewFrame(
            width: 80,
            height: 10,
            mode: .light,
            state: TUIRealParityFixtures.makeHomeState(width: 80, height: 10, mode: .light)
        )
        #expect(!shortFrame.contains("█▀▀▄"))

        // Compact when width < 22
        let compactFrame = TUIInteractiveLoop.renderPreviewFrame(
            width: 20,
            height: 20,
            mode: .light,
            state: TUIRealParityFixtures.makeHomeState(width: 20, height: 20, mode: .light)
        )
        #expect(compactFrame.contains("█▀▀█"))
        #expect(!compactFrame.contains("█▀▀▄"))

        // Stacked when 22 <= width < 44
        let stackedFrame = TUIInteractiveLoop.renderPreviewFrame(
            width: 36,
            height: 24,
            mode: .light,
            state: TUIRealParityFixtures.makeHomeState(width: 36, height: 24, mode: .light)
        )
        #expect(stackedFrame.contains("█▀▀▄"))
        #expect(stackedFrame.contains("█▀▀▀"))
        // On stacked layout, left ("█▀▀▄") and right ("█▀▀▀") appear on distinct lines
        let stackedLines = stackedFrame.split(separator: "\n").map(String.init)
        #expect(stackedLines.contains(where: { $0.contains("█▀▀▄") && !$0.contains("█▀▀▀ █▀▀█") }))
    }

    // MARK: - 3. Session Screen Visual Parity (Transcript, Markdown, Tools, Sidebar, Running Spinner)

    @Test("Session screen renders header, user accent bar, reasoning, tool call row, markdown, sidebar, and prompt")
    func sessionScreenVisualParity() {
        let state = TUIRealParityFixtures.makeSessionState(width: 124, height: 34, mode: .light, running: false)
        let harness = TUIRealParityHarness(width: 124, height: 34, state: state)
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(frame.contains("# Port OpenCode to Swift 6.2"))
        #expect(frame.contains("Check parity status across all Swift targets."))
        #expect(frame.contains("Thought"))
        #expect(frame.contains("⚙ read parity/report.json"))
        #expect(frame.contains("9404/9404 symbols implemented"))
        #expect(frame.contains("15 OpenCode packages"))
        #expect(frame.contains("Context"))
        #expect(frame.contains("12.4K tokens"))
        #expect(frame.contains("$0.04 spent"))
        #expect(frame.contains("MCP"))
        #expect(frame.contains("github"))
        #expect(frame.contains("Modified Files"))
        #expect(frame.contains("TUIInteractiveLoop.swift"))
        #expect(frame.contains("+142"))
        #expect(frame.contains("-48"))
        #expect(frame.contains("┃"))
        #expect(frame.contains("╹"))
        // Reasoning rail is indented to align with assistant parts (3 cols deeper than user message rail)
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let userRow = lines.first(where: { $0.contains("Check parity status") }),
           let thoughtRow = lines.first(where: { $0.contains("Thought") }),
           let uBar = userRow.firstIndex(of: "┃"),
           let tBar = thoughtRow.firstIndex(of: "┃") {
            let uCol = userRow.distance(from: userRow.startIndex, to: uBar)
            let tCol = thoughtRow.distance(from: thoughtRow.startIndex, to: tBar)
            #expect(tCol == uCol + 3)
        } else {
            Issue.record("Expected aligned user and reasoning rails in session frame")
        }
    }

    @Test("Session screen shows running spinner and double-Esc interrupt flow")
    func sessionRunningAndDoubleEscInterrupt() {
        let state = TUIRealParityFixtures.makeSessionState(width: 100, height: 30, mode: .dark, running: true)
        let harness = TUIRealParityHarness(width: 100, height: 30, state: state)
        defer { harness.destroy() }

        let runningFrame = harness.frame()
        #expect(runningFrame.contains("esc interrupt"))

        // First Esc arms interrupt confirmation
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().interruptArmed == true)
        #expect(harness.store.snapshot().sessionStatus.isRunning == true)
        let armedFrame = harness.frame()
        #expect(armedFrame.contains("press esc again to interrupt"))

        // Second Esc interrupts the session cleanly
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().interruptArmed == false)
        #expect(harness.store.snapshot().sessionStatus == .idle)
    }

    // MARK: - 4. Interactive Keyboard Transitions & Floating Dialog Overlays

    @Test("Shift+Tab cycles agents and updates left-border highlight color")
    func shiftTabCyclesAgentsAndColor() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        let initialTheme = harness.store.snapshot().resolveTheme()
        let buildColor = harness.store.snapshot().agentColor(theme: initialTheme)
        #expect(harness.store.snapshot().activeAgent.displayName == "Build")
        #expect(harness.frame().contains("Build · Claude Sonnet 4.5"))

        // Press Shift+Tab -> switches to Plan
        harness.testRenderer.mockInput.pressTab(modifiers: MockKeyModifiers(shift: true))
        let afterSnap = harness.store.snapshot()
        let planColor = afterSnap.agentColor(theme: initialTheme)
        #expect(afterSnap.activeAgent.displayName == "Plan")
        #expect(planColor != buildColor)
        #expect(harness.frame().contains("Plan · Claude Sonnet 4.5"))

        // Press Shift+Tab again -> wraps back to Build
        harness.testRenderer.mockInput.pressTab(modifiers: MockKeyModifiers(shift: true))
        #expect(harness.store.snapshot().activeAgent.displayName == "Build")
    }

    @Test("Ctrl+P opens floating Command Palette, typing filters items, and Esc closes it")
    func ctrlPOpensCommandPalette() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        harness.testRenderer.mockInput.pressKey("p", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().activeDialog == .commandPalette)
        let paletteFrame = harness.frame()
        #expect(paletteFrame.contains("Commands"))
        #expect(paletteFrame.contains("Switch session"))
        #expect(paletteFrame.contains("Switch model"))
        #expect(paletteFrame.contains("Switch theme"))
        #expect(paletteFrame.contains("MCP servers"))

        // Filter palette by typing "model"
        harness.testRenderer.mockInput.typeText("model")
        let filteredFrame = harness.frame()
        #expect(filteredFrame.contains("Switch model"))
        #expect(!filteredFrame.contains("MCP servers"))

        // Pressing Enter opens Model Picker dialog!
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .modelPicker)
        let modelFrame = harness.frame()
        #expect(modelFrame.contains("Select model"))
        #expect(modelFrame.contains("Claude Sonnet 4.5"))
        #expect(modelFrame.contains("GPT-5.3 Codex"))

        // Move down to GPT-5.3 Codex and select it
        harness.testRenderer.mockInput.pressArrow(.down)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == nil)
        #expect(harness.store.snapshot().selectedModel?.id == "gpt-5.3-codex")
        #expect(harness.frame().contains("GPT-5.3 Codex"))
    }

    @Test("Ctrl+T toggles Light and Dark themes immediately and updates canvas RGBA")
    func ctrlTTogglesThemeMode() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        #expect(harness.store.snapshot().effectiveMode == .light)
        #expect(harness.cellBackground(x: 0, y: 0) == RGBA.fromHex("#ffffff"))

        harness.testRenderer.mockInput.pressKey("t", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().effectiveMode == .dark)
        #expect(harness.cellBackground(x: 0, y: 0) == RGBA.fromHex("#0a0a0a"))

        harness.testRenderer.mockInput.pressKey("t", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().effectiveMode == .light)
        #expect(harness.cellBackground(x: 0, y: 0) == RGBA.fromHex("#ffffff"))
    }

    @Test("Ctrl+B toggles collapsible right Sidebar on Session screen")
    func ctrlBTogglesSidebar() {
        let state = TUIRealParityFixtures.makeSessionState(width: 124, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 124, height: 34, state: state)
        defer { harness.destroy() }

        #expect(harness.store.snapshot().effectiveShowSidebar == true)
        #expect(harness.frame().contains("Modified Files"))

        harness.testRenderer.mockInput.pressKey("b", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().effectiveShowSidebar == false)
        #expect(!harness.frame().contains("Modified Files"))

        harness.testRenderer.mockInput.pressKey("b", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().effectiveShowSidebar == true)
        #expect(harness.frame().contains("Modified Files"))
    }

    @Test("Typing slash opens live autocomplete popover and executes /sessions, /themes (with live preview), and /mcps")
    func slashAutocompleteAndDialogs() {
        let state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state)
        defer { harness.destroy() }

        // Typing "/" shows live slash autocomplete popover
        harness.testRenderer.mockInput.typeText("/")
        #expect(harness.store.snapshot().isSlashAutocompleteVisible == true)
        let autoFrame = harness.frame()
        #expect(autoFrame.contains("/models"))
        #expect(autoFrame.contains("/sessions"))
        #expect(autoFrame.contains("/themes"))
        #expect(autoFrame.contains("/mcps"))

        // Narrow to "/sess" and press Enter -> opens Session List dialog
        harness.testRenderer.mockInput.typeText("sess")
        harness.render()
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .sessionList)
        let sessionsFrame = harness.frame()
        #expect(sessionsFrame.contains("Sessions"))
        #expect(sessionsFrame.contains("Port OpenCode to Swift 6.2"))
        #expect(sessionsFrame.contains("Verify OpenTUI 100% Parity"))

        // Close and open /themes -> verify live preview on Down arrow and revert on Esc
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().activeDialog == nil)

        harness.controller.openDialog(.themePicker)
        let beforeMode = harness.store.snapshot().effectiveMode
        #expect(beforeMode == .light)
        let themeFrame = harness.frame()
        #expect(themeFrame.contains("Select theme"))
        #expect(themeFrame.contains("Appearance: Dark"))

        // Move to "Appearance: Dark" (index 2) -> live preview switches to dark
        harness.testRenderer.mockInput.pressArrow(.down)
        harness.testRenderer.mockInput.pressArrow(.down)
        #expect(harness.store.snapshot().effectiveMode == .dark)

        // Pressing Esc restores previous light mode
        harness.pressEscapeAndFlush()
        #expect(harness.store.snapshot().activeDialog == nil)
        #expect(harness.store.snapshot().effectiveMode == .light)
    }

    // MARK: - 5. Live SSE Event Reducer

    @Test("Live SSE events stream reasoning, text deltas, tool calls, status, usage, and VCS updates")
    func liveSSEEventReducer() {
        var state = TUIRealParityFixtures.makeSessionState(width: 120, height: 34, mode: .light)
        state.messages = []
        state.sessionStatus = .idle

        let sid = "ses_demo01"

        // 1. Execution starts
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.status", data: [
                "sessionID": .string(sid),
                "status": .object(["type": .string("busy")]),
            ]),
            to: &state
        )
        #expect(state.sessionStatus == .running)

        // 2. Reasoning delta streams
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.reasoning.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "ordinal": .int(0),
                "delta": .string("Checking SwiftPM targets..."),
            ]),
            to: &state
        )

        // 3. Tool input started -> called -> success
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.tool.input.started", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "id": .string("call_1"),
                "name": .string("shell"),
            ]),
            to: &state
        )
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.tool.called", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "id": .string("call_1"),
                "input": .object(["command": .string("swift test")]),
            ]),
            to: &state
        )
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.tool.success", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "id": .string("call_1"),
                "content": .array([.object(["type": .string("text"), "text": .string("All tests passed!")])]),
            ]),
            to: &state
        )

        // 4. Text delta streams
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.text.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "ordinal": .int(1),
                "delta": .string("Everything builds "),
            ]),
            to: &state
        )
        _ = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.text.delta", data: [
                "sessionID": .string(sid),
                "assistantMessageID": .string("msg_live_1"),
                "ordinal": .int(1),
                "delta": .string("cleanly!"),
            ]),
            to: &state
        )

        // 5. VCS branch and MCP updates
        let vcsEffect = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "vcs.branch.updated", data: [
                "branch": .string("feat/tui-parity"),
            ]),
            to: &state
        )
        #expect(state.gitBranch == "feat/tui-parity")
        #expect(vcsEffect.refreshVCS == true)

        let mcpEffect = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "mcp.status.changed", data: [:]),
            to: &state
        )
        #expect(mcpEffect.refreshMCP == true)

        // 6. Session returns idle
        let idleEffect = TUIInteractiveClient.applyServerEvent(
            TUIRealParityFixtures.makeEvent(type: "session.idle", data: ["sessionID": .string(sid)]),
            to: &state
        )
        #expect(state.sessionStatus == .idle)
        #expect(idleEffect.refreshMessagesForSession == sid)

        // Verify assembled assistant message renders live parts cleanly
        #expect(state.messages.count == 1)
        if case .assistant(_, _, _, let parts, let completed, _) = state.messages[0] {
            #expect(completed == true)
            #expect(parts.count == 3)
            if case .reasoning(_, let rText, let rDone) = parts[0] {
                #expect(rText == "Checking SwiftPM targets...")
                #expect(rDone == true)
            } else {
                Issue.record("Expected reasoning part first")
            }
            if case .tool(_, let tName, let tStatus, let tSummary, let tPreview, _) = parts[1] {
                #expect(tName == "shell")
                #expect(tStatus == .completed)
                #expect(tSummary == "swift test")
                #expect(tPreview == "All tests passed!")
            } else {
                Issue.record("Expected completed shell tool part second")
            }
            if case .text(_, let body) = parts[2] {
                #expect(body == "Everything builds cleanly!")
            } else {
                Issue.record("Expected streamed text part third")
            }
        } else {
            Issue.record("Expected single assembled assistant message")
        }
    }

    // MARK: - 6. Cmd+P / Cmd+A, Leader Chords, Provider Connect Flow, Agents & Variants

    @Test("Cmd+P (Kitty CSI u super+p), Cmd+K, and Ctrl+X leader chords open Commands, Models, Agents, and Connect Provider")
    func superShortcutsAndLeaderChords() {
        var state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        state.promptText = ""
        let harness = TUIRealParityHarness(width: 100, height: 34, state: state, kittyKeyboard: true)
        defer { harness.destroy() }

        // Raw Kitty CSI u Cmd+P (`\x1b[112;9u`) toggles Command Palette
        harness.testRenderer.renderer.feedInput("\u{1B}[112;9u")
        #expect(harness.store.snapshot().activeDialog == .commandPalette)
        #expect(harness.frame().contains("Connect a provider"))
        #expect(harness.frame().contains("Switch agent"))

        // Pressing Cmd+P again closes Command Palette
        harness.testRenderer.renderer.feedInput("\u{1B}[112;9u")
        #expect(harness.store.snapshot().activeDialog == nil)

        // Raw Kitty CSI u Cmd+A (`\x1b[97;9u`) on empty prompt opens Agent Picker
        harness.testRenderer.renderer.feedInput("\u{1B}[97;9u")
        #expect(harness.store.snapshot().activeDialog == .agentPicker)
        let agentFrame = harness.frame()
        #expect(agentFrame.contains("Select agent"))
        #expect(agentFrame.contains("Build"))
        #expect(agentFrame.contains("Plan"))

        // Select Plan agent and confirm
        harness.testRenderer.mockInput.pressArrow(.down)
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == nil)
        #expect(harness.store.snapshot().activeAgent.id == "plan")

        // `<leader>m` (Ctrl+X then m) opens Model Picker
        harness.testRenderer.mockInput.pressKey("x", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().leaderArmed == true)
        #expect(harness.frame().contains("m models"))
        harness.testRenderer.mockInput.pressKey("m")
        #expect(harness.store.snapshot().leaderArmed == false)
        #expect(harness.store.snapshot().activeDialog == .modelPicker)

        // Inside Model Picker: Ctrl+F favorites selected model (`★`), Ctrl+A / Cmd+A opens Connect Provider
        harness.testRenderer.mockInput.pressKey("f", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().favoriteModels.contains("anthropic/claude-sonnet-4-5"))
        #expect(harness.frame().contains("★"))
        #expect(harness.frame().contains("ctrl+a connect"))

        // Raw Kitty CSI u Cmd+A inside Model Picker opens Connect Provider
        harness.testRenderer.renderer.feedInput("\u{1B}[97;9u")
        #expect(harness.store.snapshot().activeDialog == .connectProvider)
        let connectFrame = harness.frame()
        #expect(connectFrame.contains("Connect a provider"))
        #expect(connectFrame.contains("Anthropic"))
        #expect(connectFrame.contains("OpenAI"))
        #expect(connectFrame.contains("Google"))

        // Close and open Variant Picker via `<leader>v`
        harness.pressEscapeAndFlush()
        harness.testRenderer.mockInput.pressKey("x", modifiers: MockKeyModifiers(ctrl: true))
        harness.testRenderer.mockInput.pressKey("v")
        #expect(harness.store.snapshot().activeDialog == .variantPicker)
        let variantFrame = harness.frame()
        #expect(variantFrame.contains("Select variant"))
        #expect(variantFrame.contains("high"))
        #expect(variantFrame.contains("xhigh"))
        harness.testRenderer.mockInput.pressArrow(.down) // "high"
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().selectedVariant == "high")
    }

    @Test("Connecting a provider API key calls /api/integration/:id/connect/key and unlocks its models in Select Model")
    func connectProviderAPIKeyEndToEnd() async throws {
        var state = TUIRealParityFixtures.makeHomeState(width: 100, height: 34, mode: .light)
        state.models = []
        state.selectedModel = nil
        state.providers = [:]
        state.integrations = [
            TUIIntegrationItem(
                id: "google",
                name: "Google",
                methods: [.key(label: "API key"), .env(names: ["GEMINI_API_KEY"])],
                connections: []
            ),
        ]

        let isConnected = Mutex(false)
        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/integration/google/connect/key") {
                isConnected.withLock { $0 = true }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            let connectedNow = isConnected.withLock { $0 }
            if req.method == "GET" && req.url.contains("/api/integration") {
                let conns = connectedNow
                    ? #"[{"type":"credential","id":"cred_g1","label":"Google API key","method":"key"}]"#
                    : "[]"
                let json = """
                {"location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"data":[{"id":"google","name":"Google","methods":[{"type":"key","label":"API key"}],"connections":\(conns)}]}
                """
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "GET" && req.url.contains("/api/provider") {
                let data = connectedNow
                    ? #"[{"id":"google","name":"Google","activation":"auto","package":"@opencode/ai/providers/google"}]"#
                    : "[]"
                let json = """
                {"location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"data":\(data)}
                """
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "GET" && req.url.contains("/api/model/default") {
                let data = connectedNow
                    ? #"{"id":"gemini-2.5-pro","modelID":"gemini-2.5-pro","providerID":"google","type":"chat","name":"Gemini 2.5 Pro","capabilities":{"tools":true,"input":["text"],"output":["text"],"temperature":true},"variants":[],"time":{"released":1750118400000},"cost":[],"status":"active","enabled":true,"limit":{"context":1048576,"output":65536}}"#
                    : "null"
                let json = """
                {"location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"data":\(data)}
                """
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "GET" && req.url.contains("/api/model") {
                let data = connectedNow
                    ? #"[{"id":"gemini-2.5-pro","modelID":"gemini-2.5-pro","providerID":"google","type":"chat","name":"Gemini 2.5 Pro","capabilities":{"tools":true,"input":["text"],"output":["text"],"temperature":true},"variants":[],"time":{"released":1750118400000},"cost":[],"status":"active","enabled":true,"limit":{"context":1048576,"output":65536}}]"#
                    : "[]"
                let json = """
                {"location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"data":\(data)}
                """
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array("{}".utf8))
        }

        let harness = TUIRealParityHarness(width: 100, height: 34, state: state, transport: transport)
        defer { harness.destroy() }

        // Empty Model Picker shows direct "+ Connect a provider" row
        harness.controller.openModelPicker()
        let emptyModelFrame = harness.frame()
        #expect(emptyModelFrame.contains("+ Connect a provider"))

        // Pressing Enter on "+ Connect a provider" opens Connect Provider list
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .connectProvider)
        #expect(harness.frame().contains("Google"))

        // Pressing Enter on Google opens the API key prompt dialog
        harness.testRenderer.mockInput.pressEnter()
        #expect(harness.store.snapshot().activeDialog == .connectAPIKey)
        let keyPromptFrame = harness.frame()
        #expect(keyPromptFrame.contains("Connect Google"))
        #expect(keyPromptFrame.contains("Enter your API key"))

        // Type API key and submit
        harness.testRenderer.mockInput.typeText("AIzaSyTestKey123")
        harness.testRenderer.mockInput.pressEnter()

        // Wait briefly for async connect/key -> refresh -> model picker transition
        for _ in 0..<40 {
            if harness.store.snapshot().activeDialog == .modelPicker && !harness.store.snapshot().models.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let after = harness.store.snapshot()
        #expect(after.activeDialog == .modelPicker)
        #expect(after.modelPickerProviderID == "google")
        #expect(after.models.contains(where: { $0.id == "gemini-2.5-pro" && $0.providerID == "google" }))
        #expect(after.selectedModel?.id == "gemini-2.5-pro")
        let unlockedFrame = harness.frame()
        #expect(unlockedFrame.contains("Gemini 2.5 Pro"))

        let recorded = transport.recordedRequests
        let connectReq = recorded.first(where: { $0.method == "POST" && $0.url.contains("/api/integration/google/connect/key") })
        #expect(connectReq != nil)
        if let body = connectReq?.body {
            #expect(String(decoding: body, as: UTF8.self).contains("AIzaSyTestKey123"))
        }
    }

    // MARK: - 7. Full Wave 2 Parity: Permissions, Forms, ! Shell, @ Mentions, Settings, Diff, QR Pair & History

    @Test("Inline PermissionPrompt and FormPrompt handle SSE arrival, keyboard navigation, and live HTTP replies")
    func inlinePermissionAndFormPromptsEndToEnd() async throws {
        let state = TUIRealParityFixtures.makeSessionState(width: 110, height: 34, mode: .light)
        let permReplied = Mutex<String?>(nil)
        let formReplied = Mutex<String?>(nil)

        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/permission/perm_1/reply") {
                permReplied.withLock { $0 = req.body.map { String(decoding: $0, as: UTF8.self) } }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "POST" && req.url.contains("/form/form_1/reply") {
                formReplied.withLock { $0 = req.body.map { String(decoding: $0, as: UTF8.self) } }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "GET" && req.url.contains("/api/permission/request") {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(#"{"location":{"directory":"/workspace"},"data":[]}"#.utf8))
            }
            if req.method == "GET" && req.url.contains("/api/form") {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(#"{"location":{"directory":"/workspace"},"data":[]}"#.utf8))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array("{}".utf8))
        }

        let harness = TUIRealParityHarness(width: 110, height: 34, state: state, transport: transport)
        defer { harness.destroy() }

        // 1. Arrive permission.asked over SSE reducer
        harness.store.withLock { st in
            _ = TUIInteractiveClient.applyServerEvent(
                TUIRealParityFixtures.makeEvent(type: "permission.asked", data: [
                    "id": .string("perm_1"),
                    "sessionID": .string("ses_demo01"),
                    "action": .string("shell"),
                    "resources": .array([.string("rm -rf build/")]),
                    "metadata": .object(["command": .string("rm -rf build/")]),
                ]),
                to: &st
            )
        }
        let permFrame = harness.frame()
        #expect(permFrame.contains("Allow once"))
        #expect(permFrame.contains("Allow always"))
        #expect(permFrame.contains("Reject"))
        #expect(permFrame.contains("rm -rf build/"))

        // Move right to "Allow always" and confirm with Enter
        harness.testRenderer.mockInput.pressArrow(.right)
        harness.testRenderer.mockInput.pressEnter()
        for _ in 0..<25 {
            if permReplied.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(permReplied.withLock { $0 }?.contains("always") == true)
        #expect(harness.store.snapshot().activePermission == nil)

        // 2. Arrive singleSelect FormPrompt and answer via Enter
        harness.store.withLock { st in
            st.pendingForms = [
                TUIPendingFormItem(
                    id: "form_1",
                    sessionID: "ses_demo01",
                    title: "Target Platform",
                    fields: [
                        TUIFormFieldItem(
                            key: "os",
                            label: "Choose OS",
                            kind: .singleSelect([
                                TUIFormOptionItem(label: "macOS", value: "darwin"),
                                TUIFormOptionItem(label: "Linux", value: "linux"),
                            ])
                        ),
                    ]
                ),
            ]
        }
        let formFrame = harness.frame()
        #expect(formFrame.contains("Choose OS"))
        #expect(formFrame.contains("macOS"))
        #expect(formFrame.contains("Linux"))

        harness.testRenderer.mockInput.pressArrow(.down) // Linux
        harness.testRenderer.mockInput.pressEnter()
        for _ in 0..<25 {
            if formReplied.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(formReplied.withLock { $0 }?.contains("linux") == true)
        #expect(harness.store.snapshot().activeForm == nil)
    }

    @Test("Shell mode (!), @ mentions, prompt history, /settings cycling, /diff, /pair QR, /status, /debug, and /help work end-to-end")
    func fullWave2ComposerAndOverlaysEndToEnd() async throws {
        var state = TUIRealParityFixtures.makeHomeState(width: 110, height: 34, mode: .light)
        state.mentionFiles = ["Sources/OpenCodeTUI/App/TUIScreens.swift", "Package.swift"]
        state.historyNavigator = TUIPromptHistoryNavigator(entries: [
            TUIPromptHistoryEntry(input: "first historical prompt", mode: "normal"),
            TUIPromptHistoryEntry(input: "second historical prompt", mode: "normal"),
        ])

        let shellCalled = Mutex<String?>(nil)
        let transport = MockHTTPTransport { req in
            if req.method == "POST" && req.url.contains("/api/session") && !req.url.contains("/shell") {
                let json = #"{"data":{"id":"ses_shell01","projectID":"proj_1","title":"$ ls -la","location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"agent":"build","time":{"created":1,"updated":1}}}"#
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "POST" && req.url.contains("/shell") {
                shellCalled.withLock { $0 = req.body.map { String(decoding: $0, as: UTF8.self) } }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }
            if req.method == "GET" && req.url.contains("/api/info") {
                let json = #"{"version":"2.3.2","urls":["http://127.0.0.1:4096"],"hostname":"localhost","pid":1234,"paths":{"tmp":"/tmp"},"capabilities":{"persistentPty":true}}"#
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "POST" && req.url.contains("/api/pair") {
                let json = #"{"code":"PAIR-9999","expires_in":300}"#
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            if req.method == "GET" && req.url.contains("/api/vcs/diff") {
                let json = #"{"location":{"directory":"/Users/dev/.t3/projects/swift-opencode"},"data":[{"file":"Package.swift","patch":"--- a/Package.swift\n+++ b/Package.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n","additions":1,"deletions":1,"status":"modified"}]}"#
                return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(json.utf8))
            }
            return HTTPResponse(head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]), body: Array(#"{"data":[]}"#.utf8))
        }

        let harness = TUIRealParityHarness(width: 110, height: 34, state: state, transport: transport)
        defer { harness.destroy() }

        // 1. Prompt history Up / Down on Home
        harness.testRenderer.mockInput.pressArrow(.up)
        #expect(harness.store.snapshot().promptText == "second historical prompt")
        harness.testRenderer.mockInput.pressArrow(.up)
        #expect(harness.store.snapshot().promptText == "first historical prompt")
        harness.testRenderer.mockInput.pressArrow(.down)
        #expect(harness.store.snapshot().promptText == "second historical prompt")
        harness.testRenderer.mockInput.pressArrow(.down)
        #expect(harness.store.snapshot().promptText == "")

        // 2. `@` mention autocomplete suggests files + agents and Tab replaces cleanly
        harness.testRenderer.mockInput.typeText("inspect @Pack")
        #expect(harness.store.snapshot().isMentionAutocompleteVisible == true)
        #expect(harness.frame().contains("@Package.swift"))
        harness.testRenderer.mockInput.pressTab()
        #expect(harness.store.snapshot().promptText == "inspect @Package.swift ")

        // Clear prompt, enter `!` Shell mode, submit shell command
        harness.testRenderer.mockInput.pressKey("c", modifiers: MockKeyModifiers(ctrl: true))
        #expect(harness.store.snapshot().promptText == "")
        harness.testRenderer.mockInput.typeText("!")
        #expect(harness.store.snapshot().shellMode == true)
        #expect(harness.frame().contains("! Shell"))
        harness.testRenderer.mockInput.typeText("ls -la")
        harness.testRenderer.mockInput.pressEnter()
        for _ in 0..<30 {
            if shellCalled.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(shellCalled.withLock { $0 }?.contains("ls -la") == true)

        // 3. `/settings` cycles live preferences
        let initialPref = harness.store.snapshot().preferences.themePreference
        harness.controller.openSettingsDialog()
        #expect(harness.store.snapshot().activeDialog == .settings)
        #expect(harness.frame().contains("Settings"))
        harness.testRenderer.mockInput.pressArrow(.down) // Color mode
        harness.testRenderer.mockInput.pressArrow(.right)
        #expect(harness.store.snapshot().preferences.themePreference != initialPref)
        harness.pressEscapeAndFlush()

        // 4. `/diff` viewer loads working diff & toggles split view with `v`
        harness.controller.openDiffViewer()
        for _ in 0..<25 {
            if !harness.store.snapshot().diffViewerState.files.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let diffFrame = harness.frame()
        #expect(diffFrame.contains("Diff Viewer"))
        #expect(diffFrame.contains("Package.swift"))
        let beforeSplit = harness.store.snapshot().diffViewerState.splitView
        harness.testRenderer.mockInput.pressKey("v")
        #expect(harness.store.snapshot().diffViewerState.splitView == !beforeSplit)
        harness.testRenderer.mockInput.pressKey("q")
        #expect(harness.store.snapshot().activeDialog == nil)

        // 5. `/pair` renders real QR code from server.pair()
        harness.controller.openPairDialog()
        for _ in 0..<25 {
            if harness.store.snapshot().pairingInfo != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pairFrame = harness.frame()
        #expect(pairFrame.contains("PAIR-9999"))
        #expect(pairFrame.contains("▀") || pairFrame.contains("▄") || pairFrame.contains("█"))
        harness.pressEscapeAndFlush()

        // 6. `/status`, `/debug`, and `/help` overlays render cleanly
        harness.controller.openStatusDialog()
        #expect(harness.frame().contains("Status"))
        harness.pressEscapeAndFlush()

        harness.controller.openDebugDialog()
        #expect(harness.frame().contains("Debug"))
        harness.pressEscapeAndFlush()

        harness.controller.openHelpDialog()
        #expect(harness.frame().contains("Ctrl+P"))
        harness.pressEscapeAndFlush()
    }
}
