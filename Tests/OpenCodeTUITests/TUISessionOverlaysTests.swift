import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView
import Synchronization
import Testing

@Suite("TUI Session Overlays & Dialogs (Full Parity P3)")
struct TUISessionOverlaysTests {

    // MARK: - 1. Interactive Permission Prompt

    @Test("Permission prompt renders warning accent bar, patterns, command preview, pills, and footer in Light & Dark modes")
    func permissionPromptChoiceStageLightAndDark() throws {
        let request = TUISessionOverlaysFixtures.shellPermissionRequest()

        for mode in [ThemeMode.light, ThemeMode.dark] {
            let theme = TUISessionOverlaysFixtures.theme(mode: mode)
            let syntax = TUISessionOverlaysFixtures.syntaxStyle(mode: mode)
            var promptState = TUIPermissionPromptState(selectedOption: .once)

            let harness = OverlayRenderHarness(width: 100, height: 24, mode: mode) {
                TUISessionOverlays.buildPermissionPrompt(
                    request: request,
                    state: promptState,
                    theme: theme,
                    syntaxStyle: syntax,
                    columnWidth: 100
                )
            }
            defer { harness.destroy() }

            let frame = harness.frame()
            #expect(frame.contains("Permission required: shell"))
            #expect(frame.contains("git status"))
            #expect(frame.contains("swift test"))
            #expect(frame.contains("$ swift test --filter OpenCodeTUITests"))
            #expect(frame.contains("Allow once"))
            #expect(frame.contains("Allow always"))
            #expect(frame.contains("Reject"))
            #expect(frame.contains("←/→ select"))
            #expect(frame.contains("enter confirm"))
            #expect(frame.contains("a always"))
            #expect(frame.contains("r reject"))

            // Left vertical border `┃` uses exact warning feedback accent RGBA
            let barPos = try #require(harness.findChar("┃", onLineContaining: "Permission required: shell"))
            #expect(harness.cellForeground(x: barPos.x, y: barPos.y) == theme.text.feedback.warning.base)

            // Focused pill ("Allow once") uses action.primary.focused bg & fg RGBA
            let oncePos = try #require(harness.findSubstring("Allow once"))
            #expect(harness.cellBackground(x: oncePos.x, y: oncePos.y) == theme.background.action.primary.focused)
            #expect(harness.cellForeground(x: oncePos.x, y: oncePos.y) == theme.text.action.primary.focused)

            // Unfocused pill ("Reject") composites transparently over recessed footer bar
            let rejectPos = try #require(harness.findSubstring("Reject"))
            let expectedFooterBg = theme.decrease(theme.background.raised.base)
            #expect(harness.cellBackground(x: rejectPos.x, y: rejectPos.y) == expectedFooterBg)
            #expect(harness.cellBackground(x: rejectPos.x, y: rejectPos.y) != theme.background.action.primary.focused)
            #expect(harness.cellForeground(x: rejectPos.x, y: rejectPos.y) == theme.text.action.primary.base)

            // Cycle to `.always` and verify alwaysPatterns scope + highlight move
            promptState.selectNext()
            #expect(promptState.selectedOption == .always)
            let alwaysFrame = harness.frame()
            #expect(alwaysFrame.contains("Always allow:"))
            #expect(alwaysFrame.contains("swift test *"))
            let alwaysPos = try #require(harness.findSubstring("Allow always"))
            #expect(harness.cellBackground(x: alwaysPos.x, y: alwaysPos.y) == theme.background.action.primary.focused)
        }
    }

    @Test("Permission prompt renders inline TUIDiff preview when diffPatch is present")
    func permissionPromptDiffPatchPreview() {
        let request = TUISessionOverlaysFixtures.editPermissionRequest()
        let theme = TUISessionOverlaysFixtures.theme(mode: .dark)
        let syntax = TUISessionOverlaysFixtures.syntaxStyle(mode: .dark)
        let state = TUIPermissionPromptState(selectedOption: .once)

        let harness = OverlayRenderHarness(width: 100, height: 24, mode: .dark) {
            TUISessionOverlays.buildPermissionPrompt(
                request: request,
                state: state,
                theme: theme,
                syntaxStyle: syntax,
                columnWidth: 100
            )
        }
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(!frame.contains("Error parsing diff"))
        #expect(frame.contains("Permission required: edit"))
        #expect(frame.contains("Sources/App/Greeter.swift"))
        #expect(frame.contains("Greeter"))
        #expect(frame.contains("greet(name: String)"))
        #expect(frame.contains("version = 2"))
        #expect(frame.contains("Allow once"))
    }

    @Test("Permission prompt reject-with-feedback stage renders error rail, focused TUIInput, and fires callbacks")
    func permissionPromptRejectFeedbackStage() throws {
        let request = TUISessionOverlaysFixtures.shellPermissionRequest()
        let theme = TUISessionOverlaysFixtures.theme(mode: .light)
        let syntax = TUISessionOverlaysFixtures.syntaxStyle(mode: .light)

        var state = TUIPermissionPromptState()
        state.beginRejectWithFeedback()
        #expect(state.isRejectingWithFeedback == true)
        #expect(state.selectedOption == .reject)

        let typedCapture = Mutex<String>("")
        let submittedCapture = Mutex<String>("")

        let harness = OverlayRenderHarness(width: 96, height: 20, mode: .light) {
            TUISessionOverlays.buildPermissionPrompt(
                request: request,
                state: state,
                theme: theme,
                syntaxStyle: syntax,
                columnWidth: 96,
                onRejectInput: { value in
                    typedCapture.withLock { $0 = value }
                },
                onRejectSubmit: { value in
                    submittedCapture.withLock { $0 = value }
                }
            )
        }
        defer { harness.destroy() }

        let initialFrame = harness.frame()
        #expect(initialFrame.contains("Reject permission: shell"))
        #expect(initialFrame.contains("Tell the model what to do instead…"))
        #expect(initialFrame.contains("enter reject with feedback"))
        #expect(initialFrame.contains("esc back"))

        // Reject stage uses error feedback accent bar
        let barPos = try #require(harness.findChar("┃", onLineContaining: "Reject permission: shell"))
        #expect(harness.cellForeground(x: barPos.x, y: barPos.y) == theme.text.feedback.error.base)

        // Type feedback into focused TUIInput and submit with Enter
        harness.testRenderer.mockInput.typeText("Use swift build instead")
        harness.testRenderer.mockInput.pressEnter()
        #expect(typedCapture.withLock { $0 } == "Use swift build instead")
        #expect(submittedCapture.withLock { $0 } == "Use swift build instead")

        state.cancelRejectWithFeedback()
        #expect(state.isRejectingWithFeedback == false)
    }

    // MARK: - 2. Interactive Form / Question Prompt

    @Test("Single-field singleSelect form transitions, submits immediately, and renders radio markers")
    func formPromptSingleSelectTransitionsAndRender() throws {
        let form = TUISessionOverlaysFixtures.singleSelectForm()
        var state = TUIFormPromptState()

        // Navigate across 2 options + 1 custom row with wrap-around
        state.moveRow(by: 1, form: form)
        #expect(state.selectedRowIndex == 1)
        state.moveRow(by: 1, form: form)
        #expect(state.selectedRowIndex == 2) // custom row
        state.moveRow(by: 1, form: form)
        #expect(state.selectedRowIndex == 0)
        state.moveRow(by: -1, form: form)
        #expect(state.selectedRowIndex == 2)

        // Entering custom row enables custom editing without submitting yet
        let readyOnCustomOpen = state.toggleOrSelectCurrent(form: form)
        #expect(readyOnCustomOpen == false)
        #expect(state.editingCustom == true)

        // Render while editing custom input
        let theme = TUISessionOverlaysFixtures.theme(mode: .light)
        let customHarness = OverlayRenderHarness(width: 90, height: 22, mode: .light) {
            TUISessionOverlays.buildFormPrompt(
                form: form,
                state: state,
                theme: theme,
                columnWidth: 90
            )
        }
        defer { customHarness.destroy() }
        let customFrame = customHarness.frame()
        #expect(customFrame.contains("Deployment Target"))
        #expect(customFrame.contains("○ Staging"))
        #expect(customFrame.contains("○ Production"))
        #expect(customFrame.contains("Type your own answer…"))
        #expect(customFrame.contains("↑↓ select"))
        #expect(customFrame.contains("enter confirm"))
        #expect(customFrame.contains("tab next"))
        #expect(customFrame.contains("esc dismiss"))

        // Left border accent check
        let railPos = try #require(customHarness.findChar("┃", onLineContaining: "Deployment Target"))
        #expect(customHarness.cellForeground(x: railPos.x, y: railPos.y) == theme.background.action.primary.focused)

        // Move back to Production and select -> single-field immediate submit returns true!
        state.moveRow(by: -1, form: form)
        #expect(state.selectedRowIndex == 1)
        #expect(state.editingCustom == false)
        let readyImmediate = state.toggleOrSelectCurrent(form: form)
        #expect(readyImmediate == true)
        #expect(state.encodedAnswer(for: form.fields[0]) == .string("prod"))
        #expect(state.encodedAnswer(for: form) == ["target": .string("prod")])

        // Re-render to verify filled radio marker `● Production`
        let selectedFrame = customHarness.frame()
        #expect(selectedFrame.contains("● Production"))
    }

    @Test("Multi-field form handles singleSelect, multiSelect checkboxes, text, boolean, tabs, validation, and Submit review")
    func formPromptMultiFieldStateAndRendering() {
        let form = TUISessionOverlaysFixtures.multiFieldForm()
        var state = TUIFormPromptState()
        let theme = TUISessionOverlaysFixtures.theme(mode: .dark)

        let harness = OverlayRenderHarness(width: 100, height: 24, mode: .dark) {
            TUISessionOverlays.buildFormPrompt(
                form: form,
                state: state,
                theme: theme,
                columnWidth: 100
            )
        }
        defer { harness.destroy() }

        // Tab 0 (singleSelect): shows all tabs + Submit tab
        let tab0Frame = harness.frame()
        #expect(tab0Frame.contains("Framework"))
        #expect(tab0Frame.contains("Features"))
        #expect(tab0Frame.contains("Notes"))
        #expect(tab0Frame.contains("Enable CI"))
        #expect(tab0Frame.contains("Submit"))

        // Select "SwiftPM" -> advances to Tab 1 (multiSelect), does not submit yet
        #expect(state.toggleOrSelectCurrent(form: form) == false)
        #expect(state.activeFieldIndex == 1)
        #expect(state.answers["framework"] == .string("swiftpm"))

        // Tab 1 (multiSelect): toggle item 0 and item 2
        #expect(state.toggleOrSelectCurrent(form: form) == false) // testing on
        state.moveRow(by: 2, form: form)
        #expect(state.toggleOrSelectCurrent(form: form) == false) // cli on
        #expect(state.answers["features"] == .array([.string("testing"), .string("cli")]))

        let multiFrame = harness.frame()
        #expect(multiFrame.contains("☑ Swift Testing"))
        #expect(multiFrame.contains("☐ Strict Concurrency"))
        #expect(multiFrame.contains("☑ CLI Entrypoint"))

        // Toggle item 2 off again
        #expect(state.toggleOrSelectCurrent(form: form) == false)
        #expect(state.answers["features"] == .array([.string("testing")]))

        // Tab 2 (text): advance via nextField, enter text, confirm
        state.nextField(form: form)
        #expect(state.activeFieldIndex == 2)
        state.customText = "Ship v2.3.2"
        let textFrame = harness.frame()
        #expect(textFrame.contains("Ship v2.3.2"))
        #expect(state.toggleOrSelectCurrent(form: form) == false)
        #expect(state.answers["notes"] == .string("Ship v2.3.2"))
        #expect(state.activeFieldIndex == 3) // boolean field

        // Skip boolean -> go to Submit review tab and verify required validation error
        state.nextField(form: form)
        #expect(state.isOnReviewTab(form: form) == true)
        #expect(state.toggleOrSelectCurrent(form: form) == false)
        #expect(state.errorMessage == "Enable CI is required")

        let errorFrame = harness.frame()
        #expect(errorFrame.contains("Enable CI is required"))
        #expect(errorFrame.contains("(required)"))
        #expect(errorFrame.contains("SwiftPM"))
        #expect(errorFrame.contains("Swift Testing"))
        #expect(errorFrame.contains("Ship v2.3.2"))

        // Go back to boolean via prevField, pick Yes, advance to Submit, and submit!
        state.prevField(form: form)
        #expect(state.activeFieldIndex == 3)
        #expect(state.toggleOrSelectCurrent(form: form) == false) // saves true, moves to review
        #expect(state.isOnReviewTab(form: form) == true)
        #expect(state.toggleOrSelectCurrent(form: form) == true)
        #expect(state.errorMessage == nil)

        let encoded = state.encodedAnswer(for: form)
        #expect(encoded["framework"] == .string("swiftpm"))
        #expect(encoded["features"] == .array([.string("testing")]))
        #expect(encoded["notes"] == .string("Ship v2.3.2"))
        #expect(encoded["ci"] == .bool(true))
    }

    // MARK: - 3. Full Diff Viewer Overlay

    @Test("Diff viewer renders unified & split modes, file tree, file switching, fullscreen, and empty state")
    func diffViewerUnifiedSplitAndFullscreen() {
        for mode in [ThemeMode.light, ThemeMode.dark] {
            let theme = TUISessionOverlaysFixtures.theme(mode: mode)
            let syntax = TUISessionOverlaysFixtures.syntaxStyle(mode: mode)
            var diffState = TUISessionOverlaysFixtures.sampleDiffViewerState(
                splitView: false,
                fullscreen: false,
                showFileTree: true
            )

            let harness = OverlayRenderHarness(width: 120, height: 32, mode: mode) {
                TUISessionOverlays.buildDiffViewerOverlay(
                    state: diffState,
                    cols: 120,
                    rows: 32,
                    theme: theme,
                    syntaxStyle: syntax
                )
            }
            defer { harness.destroy() }

            // Unified centered modal with file tree
            let unifiedFrame = harness.frame()
            #expect(!unifiedFrame.contains("Error parsing diff"))
            #expect(unifiedFrame.contains("Diff Viewer"))
            #expect(unifiedFrame.contains("2 files"))
            #expect(unifiedFrame.contains("+4 -2"))
            #expect(unifiedFrame.contains("unified"))
            #expect(unifiedFrame.contains("Files (2)"))
            #expect(unifiedFrame.contains("Greeter.swift"))
            #expect(unifiedFrame.contains("README.md"))
            #expect(unifiedFrame.contains("greet(name: String)"))
            #expect(unifiedFrame.contains("version = 2"))
            #expect(unifiedFrame.contains("n/p file"))
            #expect(unifiedFrame.contains("v split/unified"))
            #expect(unifiedFrame.contains("f fullscreen"))
            #expect(unifiedFrame.contains("q/esc close"))

            // Switch to split mode — verify genuine side-by-side old & new columns on the same rows!
            diffState.toggleSplitView()
            #expect(diffState.splitView == true)
            let splitFrame = harness.frame()
            #expect(!splitFrame.contains("Error parsing diff"))
            #expect(splitFrame.contains("split"))
            #expect(splitFrame.contains("func greet()"))
            #expect(splitFrame.contains("func greet(name:"))
            #expect(splitFrame.contains("let version = 2"))
            let splitLines = splitFrame.split(separator: "\n").map(String.init)
            #expect(splitLines.contains(where: { $0.contains("2 -") && $0.contains("2 +") && $0.contains("func greet()") && $0.contains("func greet(name:") }))

            // Switch to next file (README.md) and hide file tree
            diffState.selectNextFile()
            diffState.toggleFileTree()
            let secondFileFrame = harness.frame()
            #expect(!secondFileFrame.contains("Error parsing diff"))
            #expect(!secondFileFrame.contains("Files (2)"))
            #expect(secondFileFrame.contains("Production Swift 6.2 port"))
            #expect(secondFileFrame.contains("Cross-platform TUI overlays"))

            // Fullscreen fills edge-to-edge on theme.background.base
            diffState.toggleFullscreen()
            _ = harness.frame()
            #expect(harness.cellBackground(x: 0, y: 0) == theme.background.base)

            // Empty diff state
            diffState.files = []
            let emptyFrame = harness.frame()
            #expect(emptyFrame.contains("No changes to display."))
        }
    }

    // MARK: - 4a. Pair Dialog Overlay (Real QR Code)

    @Test("Pair dialog renders real OpenCodeUtil.QR Unicode half-block QR code, links, expiry, and states")
    func pairDialogWithRealQRCode() {
        let info = TUISessionOverlaysFixtures.samplePairingInfo()
        let expectedQRLines = TUISessionOverlaysFixtures.expectedQRLines(for: info.links[0])
        #expect(!expectedQRLines.isEmpty)

        for mode in [ThemeMode.light, ThemeMode.dark] {
            let theme = TUISessionOverlaysFixtures.theme(mode: mode)
            let harness = OverlayRenderHarness(width: 110, height: 34, mode: mode) {
                TUISessionOverlays.buildPairDialogOverlay(
                    info: info,
                    cols: 110,
                    rows: 34,
                    theme: theme
                )
            }
            defer { harness.destroy() }

            let frame = harness.frame()
            #expect(frame.contains("Pair"))
            #expect(frame.contains("This device"))
            #expect(frame.contains("PAIR99"))
            #expect(frame.contains("expire in 10"))
            #expect(frame.contains("minutes."))
            #expect(frame.contains("opencode service set"))
            #expect(frame.contains("hostname 0.0.0.0"))

            // Verify genuine half-block QR glyphs (`▀`, `▄`, `█`) and exact first QR line
            #expect(frame.contains("▀"))
            #expect(frame.contains("▄"))
            #expect(frame.contains("█"))
            if let firstQRLine = expectedQRLines.first {
                #expect(frame.contains(firstQRLine))
            }
        }

        // Narrow stacked Pair layout (<96 cols) still renders full QR code
        let narrowHarness = OverlayRenderHarness(width: 72, height: 38, mode: .light) {
            TUISessionOverlays.buildPairDialogOverlay(
                info: info,
                cols: 72,
                rows: 38,
                theme: TUISessionOverlaysFixtures.theme(mode: .light)
            )
        }
        defer { narrowHarness.destroy() }
        let narrowFrame = narrowHarness.frame()
        #expect(narrowHarness.collapsedText().contains("expire in 10 minutes"))
        if let firstQRLine = expectedQRLines.first {
            #expect(narrowFrame.contains(firstQRLine))
        }

        // Loading & Error states
        let darkTheme = TUISessionOverlaysFixtures.theme(mode: .dark)
        let loadingHarness = OverlayRenderHarness(width: 80, height: 24, mode: .dark) {
            TUISessionOverlays.buildPairDialogOverlay(info: nil, cols: 80, rows: 24, theme: darkTheme)
        }
        defer { loadingHarness.destroy() }
        #expect(loadingHarness.frame().contains("Loading server information…"))

        let errorInfo = TUIPairingInfo(links: [], errorMessage: "Server unreachable")
        let errorHarness = OverlayRenderHarness(width: 80, height: 24, mode: .dark) {
            TUISessionOverlays.buildPairDialogOverlay(info: errorInfo, cols: 80, rows: 24, theme: darkTheme)
        }
        defer { errorHarness.destroy() }
        let errFrame = errorHarness.frame()
        #expect(errFrame.contains("Could not load server information"))
        #expect(errFrame.contains("Server unreachable"))
    }

    // MARK: - 4b. Status Dialog Overlay

    @Test("Status dialog renders server info, directory/branch, providers, skills/commands, and colored MCP status dots")
    func statusDialogOverlay() throws {
        let snapshot = TUISessionOverlaysFixtures.sampleStatusSnapshot()

        for mode in [ThemeMode.light, ThemeMode.dark] {
            let theme = TUISessionOverlaysFixtures.theme(mode: mode)
            let dialogTheme = theme.surface(.dialog)
            let harness = OverlayRenderHarness(width: 100, height: 30, mode: mode) {
                TUISessionOverlays.buildStatusDialogOverlay(
                    snapshot: snapshot,
                    cols: 100,
                    rows: 30,
                    theme: theme
                )
            }
            defer { harness.destroy() }

            let frame = harness.frame()
            #expect(frame.contains("Status"))
            #expect(frame.contains("http://127.0.0.1:4096 (v2.3.2)"))
            #expect(frame.contains("/workspace/swift-opencode (main)"))
            #expect(frame.contains("3 connected · 14 models"))
            #expect(frame.contains("5 skills · 18 commands"))
            #expect(frame.contains("4 MCP servers"))
            #expect(frame.contains("github Connected"))
            #expect(frame.contains("postgres connection refused"))
            #expect(frame.contains("linear Needs authentication: OAuth token expired"))
            #expect(frame.contains("sentry Disabled in configuration"))

            // Verify colored MCP status dots in dialog theme
            let githubDot = try #require(harness.findChar("•", onLineContaining: "github Connected"))
            #expect(harness.cellForeground(x: githubDot.x, y: githubDot.y) == dialogTheme.text.feedback.success.base)

            let postgresDot = try #require(harness.findChar("•", onLineContaining: "postgres connection refused"))
            #expect(harness.cellForeground(x: postgresDot.x, y: postgresDot.y) == dialogTheme.text.feedback.error.base)

            let linearDot = try #require(harness.findChar("•", onLineContaining: "linear Needs authentication"))
            #expect(harness.cellForeground(x: linearDot.x, y: linearDot.y) == dialogTheme.text.feedback.warning.base)
        }
    }

    // MARK: - 4c. Usage Dialog Overlay

    @Test("Usage dialog renders limits, remaining dollars/percent, resets, and signed-out empty state")
    func usageDialogOverlay() throws {
        let rows = TUISessionOverlaysFixtures.sampleUsageRows()
        let lightTheme = TUISessionOverlaysFixtures.theme(mode: .light)
        let dialogTheme = lightTheme.surface(.dialog)

        let harness = OverlayRenderHarness(width: 100, height: 30, mode: .light) {
            TUISessionOverlays.buildUsageDialogOverlay(
                workspaceName: "Acme Engineering",
                isSignedIn: true,
                limits: rows,
                selectedIndex: 0,
                cols: 100,
                rows: 30,
                theme: lightTheme
            )
        }
        defer { harness.destroy() }

        let frame = harness.frame()
        let collapsed = harness.collapsedText()
        #expect(frame.contains("Usage"))
        #expect(frame.contains("Workspace: Acme Engineering"))
        #expect(frame.contains("Claude Sonnet 4.5"))
        #expect(frame.contains("$12.50 left (63%)"))
        #expect(frame.contains("$7.50 used of $20"))
        #expect(collapsed.contains("Resets 5:00 PM today"))
        #expect(frame.contains("GPT-5.3 Codex"))
        #expect(frame.contains("Limit reached"))
        #expect(frame.contains("Resets 12:00 AM tomorrow"))

        // Selected row uses action.primary.focused background RGBA
        let selPos = try #require(harness.findSubstring("Claude Sonnet 4.5"))
        #expect(harness.cellBackground(x: selPos.x, y: selPos.y) == dialogTheme.background.action.primary.focused)

        // Signed-out empty state
        let signedOutHarness = OverlayRenderHarness(width: 90, height: 24, mode: .dark) {
            TUISessionOverlays.buildUsageDialogOverlay(
                workspaceName: nil,
                isSignedIn: false,
                limits: [],
                cols: 90,
                rows: 24,
                theme: TUISessionOverlaysFixtures.theme(mode: .dark)
            )
        }
        defer { signedOutHarness.destroy() }
        #expect(signedOutHarness.frame().contains("Sign in to OpenCode Console with /connect"))
    }

    // MARK: - 4d. Debug Dialog Overlay

    @Test("Debug dialog renders live diagnostics including SSE state colors, terminal size, theme, Kitty flags, and counts")
    func debugDialogOverlay() throws {
        let theme = TUISessionOverlaysFixtures.theme(mode: .dark)
        let dialogTheme = theme.surface(.dialog)
        var snapshot = TUISessionOverlaysFixtures.sampleDebugSnapshot(sseConnected: true, sseReconnecting: false)

        let harness = OverlayRenderHarness(width: 100, height: 30, mode: .dark) {
            TUISessionOverlays.buildDebugDialogOverlay(
                snapshot: snapshot,
                cols: 100,
                rows: 30,
                theme: theme
            )
        }
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(frame.contains("Debug"))
        #expect(frame.contains("Share this when reporting an issue"))
        #expect(frame.contains("http://127.0.0.1:4096"))
        #expect(frame.contains("2.3.2"))
        #expect(frame.contains("ses_debug_99"))
        #expect(frame.contains("Connected"))
        #expect(frame.contains("120×40"))
        #expect(frame.contains("opencode (dark)"))
        #expect(frame.contains("enabled (flags=3)"))
        #expect(frame.contains("3 providers · 14 models · 4 agents"))
        #expect(frame.contains("18 commands · 5 skills · 22 tools"))

        let connPos = try #require(harness.findSubstring("Connected"))
        #expect(harness.cellForeground(x: connPos.x, y: connPos.y) == dialogTheme.text.feedback.success.base)

        // Reconnecting state uses warning color
        snapshot = TUISessionOverlaysFixtures.sampleDebugSnapshot(sseConnected: false, sseReconnecting: true)
        let reconnFrame = harness.frame()
        #expect(reconnFrame.contains("Reconnecting…"))
        let reconnPos = try #require(harness.findSubstring("Reconnecting…"))
        #expect(harness.cellForeground(x: reconnPos.x, y: reconnPos.y) == dialogTheme.text.feedback.warning.base)
    }

    // MARK: - 4e. Help Dialog Overlay

    @Test("Help dialog renders grouped keyboard shortcuts, prompt prefixes, and slash commands")
    func helpDialogOverlay() {
        let theme = TUISessionOverlaysFixtures.theme(mode: .light)
        let harness = OverlayRenderHarness(width: 100, height: 34, mode: .light) {
            TUISessionOverlays.buildHelpDialogOverlay(cols: 100, rows: 34, theme: theme)
        }
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(frame.contains("Help"))
        #expect(frame.contains("Keyboard Shortcuts"))
        #expect(frame.contains("Ctrl+P / Cmd+P"))
        #expect(frame.contains("Ctrl+A / Cmd+A"))
        #expect(frame.contains("Ctrl+X"))
        #expect(frame.contains("Shift+Tab"))
        #expect(frame.contains("F2"))
        #expect(frame.contains("! <command>"))
        #expect(frame.contains("@ <path>"))
        #expect(frame.contains("/connect"))
        #expect(frame.contains("/models"))
        #expect(frame.contains("/agents"))
        #expect(frame.contains("/diff"))
        #expect(frame.contains("/timeline"))
        #expect(frame.contains("/undo"))
        #expect(frame.contains("/redo"))
        #expect(frame.contains("/fork"))
        #expect(frame.contains("/pair"))
        #expect(frame.contains("/settings"))
    }

    // MARK: - 4f. Rename Session Dialog Overlay

    @Test("Rename session dialog pre-fills current title and handles input and Enter submit")
    func renameSessionDialogOverlay() {
        let theme = TUISessionOverlaysFixtures.theme(mode: .dark)
        let draft = Mutex<String>("Initial Session Title")
        let submitted = Mutex<String>("")

        let harness = OverlayRenderHarness(width: 90, height: 24, mode: .dark) {
            TUISessionOverlays.buildRenameSessionDialogOverlay(
                currentTitle: "Initial Session Title",
                draftTitle: draft.withLock { $0 },
                cols: 90,
                rows: 24,
                theme: theme,
                onInput: { val in draft.withLock { $0 = val } },
                onSubmit: { val in submitted.withLock { $0 = val } }
            )
        }
        defer { harness.destroy() }

        let frame = harness.frame()
        #expect(frame.contains("Rename session"))
        #expect(frame.contains("Initial Session Title"))
        #expect(frame.contains("enter save"))
        #expect(frame.contains("esc cancel"))

        harness.testRenderer.mockInput.typeText(" v2")
        harness.testRenderer.mockInput.pressEnter()
        #expect(submitted.withLock { $0 } == "Initial Session Title v2")
    }

    // MARK: - 4g. Reconnecting Pill Overlay

    @Test("Reconnecting overlay renders centered pill with warning rail and spinner across Light & Dark modes")
    func reconnectingOverlay() throws {
        for mode in [ThemeMode.light, ThemeMode.dark] {
            let theme = TUISessionOverlaysFixtures.theme(mode: mode)
            let harness = OverlayRenderHarness(width: 90, height: 24, mode: mode) {
                TUISessionOverlays.buildReconnectingOverlay(managed: false, spinnerTick: 2, theme: theme)
            }
            defer { harness.destroy() }

            let frame = harness.frame()
            #expect(frame.contains("Reconnecting to server…"))
            #expect(frame.contains("Reconnecting to the server automatically."))
            #expect(frame.contains("⠹"))

            let barPos = try #require(harness.findChar("┃", onLineContaining: "Reconnecting to server…"))
            #expect(harness.cellForeground(x: barPos.x, y: barPos.y) == theme.text.feedback.warning.base)
        }

        let managedHarness = OverlayRenderHarness(width: 90, height: 24, mode: .dark) {
            TUISessionOverlays.buildReconnectingOverlay(
                managed: true,
                spinnerTick: 0,
                theme: TUISessionOverlaysFixtures.theme(mode: .dark)
            )
        }
        defer { managedHarness.destroy() }
        let managedFrame = managedHarness.frame()
        #expect(managedFrame.contains("Restarting service…"))
        #expect(managedFrame.contains("Your session will resume automatically."))
    }

    // MARK: - 4h. Session Sidebar Todo Section

    @Test("Sidebar todo section renders [✓], [◐], [ ], [-] checklist, colors, collapse toggle, and empty state")
    func sidebarTodoSection() throws {
        let items = TUISessionOverlaysFixtures.sampleTodoItems()
        let theme = TUISessionOverlaysFixtures.theme(mode: .light)
        var expanded = true

        let harness = OverlayRenderHarness(width: 44, height: 16, mode: .light) {
            AnyTUIView(
                TUIBox(border: false, backgroundColor: .rgba(theme.background.raised.base), shouldFill: true) {
                    TUISessionOverlays.buildSidebarTodoSection(
                        items: items,
                        expanded: expanded,
                        theme: theme,
                        background: theme.background.raised.base,
                        innerWidth: 40
                    )
                }
                .padding(1)
                .width(42)
            )
        }
        defer { harness.destroy() }

        let expandedFrame = harness.frame()
        #expect(expandedFrame.contains("▼ Todo"))
        #expect(expandedFrame.contains("[✓] Port permission prompt"))
        #expect(expandedFrame.contains("[◐] Verify diff viewer split mode"))
        #expect(expandedFrame.contains("[ ] Run full parity audit"))
        #expect(expandedFrame.contains("[-] Deprecated legacy widget"))

        // Verify semantic feedback colors for completed (`✓`) and in-progress (`◐`) markers
        let donePos = try #require(harness.findChar("✓", onLineContaining: "Port permission prompt"))
        #expect(harness.cellForeground(x: donePos.x, y: donePos.y) == theme.text.feedback.success.base)

        let wipPos = try #require(harness.findChar("◐", onLineContaining: "Verify diff viewer"))
        #expect(harness.cellForeground(x: wipPos.x, y: wipPos.y) == theme.text.feedback.warning.base)

        // Collapsed state shows disclosure arrow and remaining count (pending + inProgress = 2)
        expanded = false
        let collapsedFrame = harness.frame()
        #expect(collapsedFrame.contains("▶ Todo (2 remaining)"))
        #expect(!collapsedFrame.contains("Port permission prompt"))

        // Empty list renders cleanly without Todo heading
        let emptyHarness = OverlayRenderHarness(width: 40, height: 10, mode: .dark) {
            TUISessionOverlays.buildSidebarTodoSection(
                items: [],
                theme: TUISessionOverlaysFixtures.theme(mode: .dark)
            )
        }
        defer { emptyHarness.destroy() }
        #expect(!emptyHarness.frame().contains("Todo"))
    }

    @Test("Edge states: narrow permission footer, form custom answer switch, empty MCP status, unlimited usage, empty patch")
    func edgeStatesAcrossOverlays() {
        let darkTheme = TUISessionOverlaysFixtures.theme(mode: .dark)
        let darkSyntax = TUISessionOverlaysFixtures.syntaxStyle(mode: .dark)

        // 1. Narrow permission prompt (<90 cols) stacks pills above footer hints cleanly
        let narrowPerm = OverlayRenderHarness(width: 66, height: 18, mode: .dark) {
            TUISessionOverlays.buildPermissionPrompt(
                request: TUISessionOverlaysFixtures.shellPermissionRequest(),
                state: TUIPermissionPromptState(selectedOption: .reject),
                theme: darkTheme,
                syntaxStyle: darkSyntax,
                columnWidth: 66
            )
        }
        defer { narrowPerm.destroy() }
        let narrowPermFrame = narrowPerm.frame()
        #expect(narrowPermFrame.contains("Allow once"))
        #expect(narrowPermFrame.contains("Allow always"))
        #expect(narrowPermFrame.contains("Reject"))
        #expect(narrowPermFrame.contains("←/→ select  enter confirm  a always  r reject"))

        // 2. Switching from custom value back to preset option clears filled radio marker on custom row
        let singleForm = TUISessionOverlaysFixtures.singleSelectForm()
        var formState = TUIFormPromptState(
            activeFieldIndex: 0,
            selectedRowIndex: 2,
            answers: ["target": .string("canary")],
            customText: "canary",
            editingCustom: false
        )
        formState.moveRow(by: -2, form: singleForm) // index 0 ("Staging")
        #expect(formState.toggleOrSelectCurrent(form: singleForm) == true)
        let formHarness = OverlayRenderHarness(width: 80, height: 18, mode: .dark) {
            TUISessionOverlays.buildFormPrompt(
                form: singleForm,
                state: formState,
                theme: darkTheme,
                columnWidth: 80
            )
        }
        defer { formHarness.destroy() }
        let formFrame = formHarness.frame()
        #expect(formFrame.contains("● Staging"))
        #expect(formFrame.contains("○ canary"))

        // 3. Status dialog with 0 MCP servers
        let emptyStatus = TUIStatusSnapshot(
            serverURL: "http://127.0.0.1:4096",
            serverVersion: "v2.3.2",
            directory: "/tmp/empty",
            connectedProvidersCount: 0,
            mcpServers: []
        )
        let statusHarness = OverlayRenderHarness(width: 80, height: 22, mode: .dark) {
            TUISessionOverlays.buildStatusDialogOverlay(
                snapshot: emptyStatus,
                cols: 80,
                rows: 22,
                theme: darkTheme
            )
        }
        defer { statusHarness.destroy() }
        let statusFrame = statusHarness.frame()
        #expect(statusFrame.contains("No MCP servers"))
        #expect(statusFrame.contains("(v2.3.2)"))
        #expect(!statusFrame.contains("(vv2.3.2)"))

        // 4. Signed-in usage dialog with no limits
        let unlimitedHarness = OverlayRenderHarness(width: 84, height: 22, mode: .dark) {
            TUISessionOverlays.buildUsageDialogOverlay(
                workspaceName: "Personal",
                isSignedIn: true,
                limits: [],
                cols: 84,
                rows: 22,
                theme: darkTheme
            )
        }
        defer { unlimitedHarness.destroy() }
        #expect(unlimitedHarness.collapsedText().contains("No limits apply to your models."))

        // 5. Diff viewer entry with empty patch renders graceful fallback
        let emptyPatchState = TUIDiffViewerState(
            files: [TUIDiffFileEntry(path: "assets/logo.png", additions: 0, deletions: 0, status: "added", patch: "")]
        )
        let diffHarness = OverlayRenderHarness(width: 96, height: 22, mode: .dark) {
            TUISessionOverlays.buildDiffViewerOverlay(
                state: emptyPatchState,
                cols: 96,
                rows: 22,
                theme: darkTheme,
                syntaxStyle: darkSyntax
            )
        }
        defer { diffHarness.destroy() }
        #expect(diffHarness.frame().contains("No patch content for this file."))
    }
}
