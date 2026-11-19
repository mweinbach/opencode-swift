import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView

/// Action callbacks bridged from declarative `TUIScreens` views into `TUIInteractiveClient` / `TUIInteractiveLoop`.
public struct TUIScreenActions: Sendable {
    public let onPromptInput: @Sendable (String) -> Void
    public let onPromptSubmit: @Sendable (String) -> Void
    public let onDialogFilterInput: @Sendable (String) -> Void
    public let onDialogSubmit: @Sendable () -> Void
    public let onDialogClose: @Sendable () -> Void
    public let onSelectDialogRow: @Sendable (Int) -> Void
    public let onOpenMCPDialog: @Sendable () -> Void
    public let onPermissionRejectInput: @Sendable (String) -> Void
    public let onPermissionRejectSubmit: @Sendable (String) -> Void
    public let onFormTextInput: @Sendable (String) -> Void
    public let onFormTextSubmit: @Sendable (String) -> Void
    public let onRenameInput: @Sendable (String) -> Void
    public let onRenameSubmit: @Sendable (String) -> Void
    public let onSelectSessionTab: @Sendable (String) -> Void
    public let onNewSessionTab: @Sendable () -> Void
    public let onFocusPrompt: @Sendable () -> Void
    public let onOpenQueuedPrompts: @Sendable () -> Void
    public let onCloseTerminalPane: @Sendable () -> Void
    public let onFocusTerminalPane: @Sendable () -> Void
    public let onTerminalInput: @Sendable (String) -> Void
    public let onTerminalSubmit: @Sendable (String) -> Void

    public init(
        onPromptInput: @escaping @Sendable (String) -> Void = { _ in },
        onPromptSubmit: @escaping @Sendable (String) -> Void = { _ in },
        onDialogFilterInput: @escaping @Sendable (String) -> Void = { _ in },
        onDialogSubmit: @escaping @Sendable () -> Void = {},
        onDialogClose: @escaping @Sendable () -> Void = {},
        onSelectDialogRow: @escaping @Sendable (Int) -> Void = { _ in },
        onOpenMCPDialog: @escaping @Sendable () -> Void = {},
        onPermissionRejectInput: @escaping @Sendable (String) -> Void = { _ in },
        onPermissionRejectSubmit: @escaping @Sendable (String) -> Void = { _ in },
        onFormTextInput: @escaping @Sendable (String) -> Void = { _ in },
        onFormTextSubmit: @escaping @Sendable (String) -> Void = { _ in },
        onRenameInput: @escaping @Sendable (String) -> Void = { _ in },
        onRenameSubmit: @escaping @Sendable (String) -> Void = { _ in },
        onSelectSessionTab: @escaping @Sendable (String) -> Void = { _ in },
        onNewSessionTab: @escaping @Sendable () -> Void = {},
        onFocusPrompt: @escaping @Sendable () -> Void = {},
        onOpenQueuedPrompts: @escaping @Sendable () -> Void = {},
        onCloseTerminalPane: @escaping @Sendable () -> Void = {},
        onFocusTerminalPane: @escaping @Sendable () -> Void = {},
        onTerminalInput: @escaping @Sendable (String) -> Void = { _ in },
        onTerminalSubmit: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onPromptInput = onPromptInput
        self.onPromptSubmit = onPromptSubmit
        self.onDialogFilterInput = onDialogFilterInput
        self.onDialogSubmit = onDialogSubmit
        self.onDialogClose = onDialogClose
        self.onSelectDialogRow = onSelectDialogRow
        self.onOpenMCPDialog = onOpenMCPDialog
        self.onPermissionRejectInput = onPermissionRejectInput
        self.onPermissionRejectSubmit = onPermissionRejectSubmit
        self.onFormTextInput = onFormTextInput
        self.onFormTextSubmit = onFormTextSubmit
        self.onRenameInput = onRenameInput
        self.onRenameSubmit = onRenameSubmit
        self.onSelectSessionTab = onSelectSessionTab
        self.onNewSessionTab = onNewSessionTab
        self.onFocusPrompt = onFocusPrompt
        self.onOpenQueuedPrompts = onOpenQueuedPrompts
        self.onCloseTerminalPane = onCloseTerminalPane
        self.onFocusTerminalPane = onFocusTerminalPane
        self.onTerminalInput = onTerminalInput
        self.onTerminalSubmit = onTerminalSubmit
    }
}

/// Declarative OpenTUI screen and component builders matching upstream OpenCode 2.3.2
/// (`routes/home.tsx`, `component/logo.tsx`, `component/prompt/index.tsx`, `component/prompt/metadata.tsx`,
/// `feature-plugins/home/footer.tsx`, `routes/session/index.tsx`, `routes/session/sidebar.tsx`, `ui/dialog.tsx`).
public enum TUIScreens {
    // MARK: - Border Character Sets (`src/ui/border.ts` + `src/component/prompt/index.tsx`)

    private static let transparent = RGBA.fromInts(0, 0, 0, 0)

    /// Vertical heavy left rail (`┃`) with bottom-left cap (`╹`), matching `SplitBorder` + prompt override.
    public static let promptBorderChars = BorderCharacters(
        topLeft: " ", topRight: " ", bottomLeft: "╹", bottomRight: " ",
        horizontal: " ", vertical: "┃",
        topT: " ", bottomT: " ", leftT: " ", rightT: " ", cross: " "
    )

    /// Left-only vertical bar (`┃`) for user messages and reasoning rails (`SplitBorder`).
    public static let splitBorderChars = BorderCharacters(
        topLeft: " ", topRight: " ", bottomLeft: " ", bottomRight: " ",
        horizontal: " ", vertical: "┃",
        topT: " ", bottomT: " ", leftT: " ", rightT: " ", cross: " "
    )

    /// Bottom-left 1-row prompt cap (`╹`), matching `prompt/index.tsx` line 1888.
    public static let promptBottomCapLeftChars = BorderCharacters(
        topLeft: " ", topRight: " ", bottomLeft: "╹", bottomRight: " ",
        horizontal: " ", vertical: "╹",
        topT: " ", bottomT: " ", leftT: " ", rightT: " ", cross: " "
    )

    /// Bottom half-block edge (`▀`) in `promptBg`, matching `prompt/index.tsx` line 1899.
    public static let promptBottomCapEdgeChars = BorderCharacters(
        topLeft: " ", topRight: " ", bottomLeft: " ", bottomRight: " ",
        horizontal: "▀", vertical: " ",
        topT: " ", bottomT: " ", leftT: " ", rightT: " ", cross: " "
    )

    /// Upstream-inspired block spinner frames for active running state.
    private static let spinnerFrames: [String] = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    // MARK: - Root Screen Composition

    public static func buildRootView(
        state: TUIInteractiveState,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let theme = state.resolveTheme()
        let syntaxStyle = generateSyntax(theme)
        let bgBase = Color.rgba(theme.background.base)

        return AnyTUIView(
            ZStack(alignment: .stretch, justify: .flexStart) {
                // Full-screen solid background canvas (crisp white #ffffff in Light Mode, #0a0a0a in Dark Mode)
                TUIBox(
                    border: false,
                    backgroundColor: bgBase,
                    shouldFill: true
                ) {
                    if state.isHome {
                        buildHomeScreen(state: state, theme: theme, actions: actions)
                    } else {
                        buildSessionScreen(state: state, theme: theme, syntaxStyle: syntaxStyle, actions: actions)
                    }
                }
                .id("opencode-root-canvas")
                .width(.percent(100))
                .height(.percent(100))

                // Floating centered modal dialog / full overlay
                if let dialog = state.activeDialog {
                    buildDialogOverlay(dialog: dialog, state: state, theme: theme, syntaxStyle: syntaxStyle, actions: actions)
                }

                // Live SSE Reconnecting overlay (`component/reconnecting.tsx`)
                if state.sseReconnecting && state.activeDialog == nil {
                    TUISessionOverlays.buildReconnectingOverlay(
                        managed: false,
                        spinnerTick: state.spinnerTick,
                        theme: theme
                    )
                }

                // Subtle bottom-right toast banner when active
                if let toast = state.toastMessage, !toast.isEmpty, state.activeDialog == nil {
                    buildToastBanner(message: toast, isError: state.toastIsError, theme: theme)
                }
            }
            .width(.percent(100))
            .height(.percent(100))
        )
    }

    // MARK: - Dual-Tone 3D Shadow Logo (`src/logo.ts` + `src/component/logo.tsx`)

    public static func buildLogo(
        cols: Int,
        rows: Int,
        theme: ResolvedTheme
    ) -> AnyTUIView {
        guard rows >= 12 else {
            return AnyTUIView(EmptyTUIView())
        }

        func renderLogoChunks(_ line: String, fg: RGBA, bold: Bool) -> [TextChunk] {
            let shadow = TUIThemeBridge.tint(theme.background.base, overlay: fg, alpha: 0.25)
            let attrs = bold ? TextAttributes.bold : TextAttributes.none
            return line.map { ch in
                switch ch {
                case "_":
                    return TextChunk(text: " ", fg: fg, bg: shadow, attributes: attrs)
                case "^":
                    return TextChunk(text: "▀", fg: fg, bg: shadow, attributes: attrs)
                case "~":
                    return TextChunk(text: "▀", fg: shadow, attributes: attrs)
                case ",":
                    return TextChunk(text: "▄", fg: shadow, attributes: attrs)
                default:
                    return TextChunk(text: String(ch), fg: fg, attributes: attrs)
                }
            }
        }

        if cols < 22 {
            let lines = Array(TUILogo.go.right.dropFirst())
            return AnyTUIView(
                VStack(spacing: 0, alignment: .center) {
                    for (idx, line) in lines.enumerated() {
                        TUIText(
                            StyledText(chunks: renderLogoChunks(line, fg: theme.text.base, bold: true)),
                            wrapMode: TextWrapMode.none,
                            selectable: false
                        )
                        .key("logo-compact-\(idx)")
                    }
                }
                .id("opencode-logo")
                .flexShrink(0)
            )
        }

        if cols < 44 {
            let leftLines = Array(TUILogo.logo.left.dropFirst())
            let rightLines = TUILogo.logo.right
            return AnyTUIView(
                VStack(spacing: 0, alignment: .center) {
                    for (idx, line) in leftLines.enumerated() {
                        TUIText(
                            StyledText(chunks: renderLogoChunks(line, fg: theme.text.muted, bold: false)),
                            wrapMode: TextWrapMode.none,
                            selectable: false
                        )
                        .key("logo-stack-l-\(idx)")
                    }
                    for (idx, line) in rightLines.enumerated() {
                        TUIText(
                            StyledText(chunks: renderLogoChunks(line, fg: theme.text.base, bold: true)),
                            wrapMode: TextWrapMode.none,
                            selectable: false
                        )
                        .key("logo-stack-r-\(idx)")
                    }
                }
                .id("opencode-logo")
                .flexShrink(0)
            )
        }

        let count = min(TUILogo.logo.left.count, TUILogo.logo.right.count)
        return AnyTUIView(
            VStack(spacing: 0, alignment: .center) {
                for idx in 0..<count {
                    let combined = renderLogoChunks(TUILogo.logo.left[idx], fg: theme.text.muted, bold: false)
                        + [TextChunk(text: " ", fg: theme.text.muted)]
                        + renderLogoChunks(TUILogo.logo.right[idx], fg: theme.text.base, bold: true)
                    TUIText(
                        StyledText(chunks: combined),
                        wrapMode: TextWrapMode.none,
                        selectable: false
                    )
                    .key("logo-wide-\(idx)")
                }
            }
            .id("opencode-logo")
            .flexShrink(0)
        )
    }

    // MARK: - Home Screen (`src/routes/home.tsx` + `src/feature-plugins/home/footer.tsx`)

    public static func buildHomeScreen(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let padX = state.cols < 44 ? 1 : 2
        let composerWidth = min(75, max(20, state.cols - padX * 2))
        let showFooter = state.rows >= 14 && state.cols >= 44
        let footerPadY = state.rows < 16 ? 0 : 1

        return AnyTUIView(
            VStack(spacing: 0) {
                // Centered Hero Column (Logo + Left-Bordered Prompt Composer)
                VStack(spacing: 0, alignment: .center) {
                    TUISpacer()

                    if state.rows >= 22 && !state.isSlashAutocompleteVisible {
                        TUIBox(border: false, shouldFill: false)
                            .height(2)
                            .minHeight(0)
                            .flexShrink(1)
                    }

                    buildLogo(cols: state.cols, rows: state.rows, theme: theme)

                    if state.rows >= 12 {
                        TUIBox(border: false, shouldFill: false)
                            .height(1)
                            .flexShrink(0)
                    }

                    VStack(spacing: 0) {
                        if state.isSlashAutocompleteVisible {
                            buildSlashAutocomplete(
                                state: state,
                                theme: theme,
                                maxWidth: composerWidth
                            )
                        } else if state.isMentionAutocompleteVisible {
                            buildMentionAutocomplete(
                                state: state,
                                theme: theme,
                                maxWidth: composerWidth
                            )
                        }
                        buildPromptComposer(
                            state: state,
                            theme: theme,
                            isHome: true,
                            columnWidth: composerWidth,
                            actions: actions
                        )
                    }
                    .width(composerWidth)
                    .padding(top: 1)
                    .flexShrink(0)

                    TUISpacer()
                }
                .padding(right: .point(Float(padX)), left: .point(Float(padX)))
                .width(.percent(100))
                .flexGrow(1)

                // Embedded Live Terminal Pane (`<leader>t`)
                if state.terminalPane.isOpen {
                    TUIEmbeddedTerminalPane.buildEmbeddedTerminalPane(
                        state: state.terminalPane,
                        theme: theme,
                        height: TUIEmbeddedTerminalPane.paneHeight(forRows: state.rows),
                        onClose: actions.onCloseTerminalPane,
                        onFocus: actions.onFocusTerminalPane,
                        onInput: actions.onTerminalInput,
                        onSubmit: actions.onTerminalSubmit
                    )
                }

                // Minimal Bottom-Edge Home Footer (`feature-plugins/home/footer.tsx`)
                if showFooter {
                    buildHomeFooter(state: state, theme: theme, padY: footerPadY, actions: actions)
                }
            }
            .width(.percent(100))
            .height(.percent(100))
        )
    }

    private static func buildHomeFooter(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        padY: Int,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let mcpCount = state.mcpServers.count
        let connectedCount = state.mcpServers.filter { $0.status.isConnected }.count
        let failedCount = state.mcpServers.filter { $0.status.isFailed }.count
        let showMcpCommand = state.cols >= 64
        let showVersion = state.cols >= 64

        return AnyTUIView(
            HStack(spacing: 2, alignment: .center) {
                if mcpCount > 0 {
                    HStack(spacing: 1) {
                        if failedCount > 0 {
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: "⊙ ", fg: theme.text.feedback.error.base),
                                    TextChunk(text: "\(failedCount) MCP failed", fg: theme.text.base),
                                ]),
                                wrapMode: TextWrapMode.none
                            )
                        } else {
                            let dotColor = connectedCount > 0 ? theme.text.feedback.success.base : theme.text.muted
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: "⊙ ", fg: dotColor),
                                    TextChunk(text: "\(connectedCount) MCP", fg: theme.text.base),
                                ]),
                                wrapMode: TextWrapMode.none
                            )
                        }
                        if showMcpCommand {
                            TUIText("/mcps", fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)
                        }
                    }
                    .flexShrink(0)
                    .onMouseUp { _ in
                        actions.onOpenMCPDialog()
                    }
                }

                TUISpacer()

                if showVersion && !state.serverVersion.isEmpty {
                    TUIText(state.serverVersion, fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)
                        .flexShrink(0)
                }
            }
            .id("opencode-home-footer")
            .padding(
                top: .point(Float(padY)),
                right: 2,
                bottom: .point(Float(padY)),
                left: 2
            )
            .width(.percent(100))
            .flexShrink(0)
        )
    }

    // MARK: - Left-Bordered Prompt Composer (`component/prompt/index.tsx` + `metadata.tsx`)

    public static func buildPromptComposer(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        isHome: Bool,
        columnWidth: Int,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let promptBg = theme.decrease(theme.background.raised.base)
        let agentColor = state.shellMode ? theme.text.feedback.warning.base : state.agentColor(theme: theme)
        let innerPadX = state.cols < 44 ? 1 : 2
        let inputAvailWidth = max(8, columnWidth - 1 - innerPadX * 2)
        let rawPlaceholder = state.shellMode ? "Run a shell command… (esc to exit)" : state.currentPlaceholder
        let placeholderText = TUIUtil.takeWidth(rawPlaceholder, inputAvailWidth)
            .trimmingCharacters(in: .whitespaces)
        let inputKey = isHome ? "home-prompt-input" : "session-prompt-input"
        let inputFocused = state.activeDialog == nil
            && state.activePermission == nil
            && state.activeForm == nil
            && !(state.terminalPane.isOpen && state.terminalPane.isFocused)
        let split = TUIMultilinePrompt.splitLines(state.promptText)
        let prefixLines = split.prefixLines
        let activeLine = split.activeLine
        let isMultiline = !prefixLines.isEmpty
        let visiblePrefix = TUIMultilinePrompt.visiblePrefixSlice(prefixLines)

        return AnyTUIView(
            VStack(spacing: 0) {
                // Subtle Queued Prompts Badge above the composer (`<leader>q`)
                if !state.queuedPrompts.isEmpty {
                    let count = state.queuedPrompts.count
                    let label = count == 1 ? "1 queued prompt" : "\(count) queued prompts"
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(transparent),
                        shouldFill: false
                    ) {
                        TUIText(
                            StyledText(chunks: [
                                TextChunk(text: "↳ \(label)", fg: agentColor, attributes: TextAttributes.bold),
                                TextChunk(text: " · ", fg: theme.text.muted),
                                TextChunk(text: "ctrl+x q", fg: theme.text.base),
                                TextChunk(text: " to manage", fg: theme.text.muted),
                            ]),
                            wrapMode: TextWrapMode.none,
                            selectable: false,
                            truncate: true
                        )
                        .width(.percent(100))
                    }
                    .id("opencode-queued-badge")
                    .padding(left: 1)
                    .height(1)
                    .width(.percent(100))
                    .onMouseUp { _ in
                        actions.onOpenQueuedPrompts()
                    }
                }

                // Main left-bordered prompt box (left-only heavy vertical rail `┃`, NO 4-sided box!)
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(agentColor),
                    backgroundColor: .rgba(transparent),
                    shouldFill: false,
                    customBorderChars: promptBorderChars
                ) {
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(promptBg),
                        shouldFill: true
                    ) {
                        VStack(spacing: 0) {
                            // Preceding lines for multiline drafts (auto-growing up to 6 visible lines)
                            if isMultiline {
                                VStack(spacing: 0) {
                                    if visiblePrefix.hiddenCount > 0 {
                                        let moreLabel = visiblePrefix.hiddenCount == 1
                                            ? "↑ 1 more line"
                                            : "↑ \(visiblePrefix.hiddenCount) more lines"
                                        TUIText(
                                            moreLabel,
                                            fg: .rgba(theme.text.faint),
                                            bg: .rgba(promptBg),
                                            attributes: TextAttributes.italic,
                                            wrapMode: TextWrapMode.none,
                                            truncate: true
                                        )
                                        .key("prompt-multiline-overflow")
                                        .width(.percent(100))
                                        .height(1)
                                    }
                                    for (idx, line) in visiblePrefix.visible.enumerated() {
                                        TUIText(
                                            line.isEmpty ? " " : line,
                                            fg: .rgba(theme.text.base),
                                            bg: .rgba(promptBg),
                                            wrapMode: TextWrapMode.none,
                                            truncate: true
                                        )
                                        .key("prompt-multiline-\(idx)")
                                        .width(.percent(100))
                                        .height(1)
                                    }
                                }
                                .key("prompt-multiline-prefix")
                                .width(.percent(100))
                            }

                            TUIInput(
                                value: activeLine,
                                placeholder: isMultiline ? "" : placeholderText,
                                placeholderColor: .rgba(theme.text.muted),
                                maxLength: 4000,
                                textColor: .rgba(theme.text.base),
                                backgroundColor: .rgba(promptBg),
                                focusedTextColor: .rgba(theme.text.base),
                                focusedBackgroundColor: .rgba(promptBg),
                                showCursor: inputFocused,
                                cursorColor: .rgba(theme.text.base),
                                onInput: actions.onPromptInput,
                                onSubmit: actions.onPromptSubmit
                            )
                            .key(inputKey)
                            .id(inputKey)
                            .width(.percent(100))
                            .focused(inputFocused)

                            // Subtle paste attachment chips when large pastes are summarized
                            if !state.pastedBlocks.isEmpty {
                                buildPasteChipsRow(
                                    blocks: state.pastedBlocks,
                                    theme: theme,
                                    promptBg: promptBg
                                )
                            }

                            // 1-row spacer + Metadata Row (`Build · Model Name Provider Name · variant`)
                            buildPromptMetadataRow(
                                state: state,
                                theme: theme,
                                agentColor: agentColor,
                                promptBg: promptBg,
                                availableWidth: inputAvailWidth
                            )
                            .padding(top: 1)
                        }
                        .width(.percent(100))
                    }
                    .padding(
                        top: 1,
                        right: .point(Float(innerPadX)),
                        bottom: 0,
                        left: .point(Float(innerPadX))
                    )
                    .width(.percent(100))
                    .flexGrow(1)
                }
                .id("opencode-prompt-box")
                .width(.percent(100))
                .onMouseUp { _ in
                    actions.onFocusPrompt()
                }

                // Bottom half-block cap row (`╹` on left + `▀` edge in promptBg)
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(agentColor),
                    backgroundColor: .rgba(transparent),
                    shouldFill: false,
                    customBorderChars: promptBottomCapLeftChars
                ) {
                    TUIBox(
                        border: .sides([.bottom]),
                        borderColor: .rgba(promptBg),
                        backgroundColor: .rgba(transparent),
                        shouldFill: false,
                        customBorderChars: promptBottomCapEdgeChars
                    )
                    .height(1)
                    .width(.percent(100))
                }
                .height(1)
                .width(.percent(100))

                // Single clean info row right beneath the prompt box
                buildPromptFooterRow(
                    state: state,
                    theme: theme,
                    agentColor: agentColor,
                    isHome: isHome,
                    columnWidth: columnWidth
                )
            }
            .width(.percent(100))
            .flexShrink(0)
        )
    }

    private static func buildPasteChipsRow(
        blocks: [TUIPastedBlock],
        theme: ResolvedTheme,
        promptBg: RGBA
    ) -> AnyTUIView {
        let chipBg = theme.background.raised.high
        var chunks: [TextChunk] = []
        for (idx, block) in blocks.enumerated() {
            if idx > 0 {
                chunks.append(TextChunk(text: " ", fg: theme.text.muted, bg: promptBg))
            }
            chunks.append(TextChunk(
                text: " \(block.label) ",
                fg: theme.text.action.primary.selected,
                bg: chipBg
            ))
        }
        return AnyTUIView(
            TUIText(
                StyledText(chunks: chunks),
                bg: .rgba(promptBg),
                wrapMode: TextWrapMode.none,
                truncate: true
            )
            .key("prompt-paste-chips")
            .id("opencode-paste-chips")
            .width(.percent(100))
            .height(1)
        )
    }

    private static func buildPromptMetadataRow(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        agentColor: RGBA,
        promptBg: RGBA,
        availableWidth: Int
    ) -> AnyTUIView {
        let narrow = state.cols < 44
        if state.shellMode {
            let chunks: [TextChunk] = [
                TextChunk(text: "! Shell", fg: theme.text.feedback.warning.base, bg: promptBg, attributes: TextAttributes.bold),
                TextChunk(text: " · Enter to run command · Esc to exit", fg: theme.text.muted, bg: promptBg),
            ]
            return AnyTUIView(
                TUIText(
                    StyledText(chunks: chunks),
                    bg: .rgba(promptBg),
                    wrapMode: TextWrapMode.none,
                    truncate: true
                )
                .width(.percent(100))
            )
        }
        let agentName = narrow ? "" : state.activeAgent.displayName
        let modelName = state.activeModelLabel
        let providerName = narrow ? "" : state.activeProviderLabel
        let variant = state.selectedVariant

        var chunks: [TextChunk] = []
        if !agentName.isEmpty {
            chunks.append(TextChunk(text: agentName, fg: agentColor, bg: promptBg))
        }
        if !modelName.isEmpty {
            if !agentName.isEmpty {
                chunks.append(TextChunk(text: " · ", fg: theme.text.muted, bg: promptBg))
            }
            let prefixLen = agentName.isEmpty ? 0 : (TUIUtil.stringWidth(agentName) + 3)
            let provLen = providerName.isEmpty ? 0 : (TUIUtil.stringWidth(providerName) + 1)
            let varLen = variant.map { TUIUtil.stringWidth($0) + 3 } ?? 0
            let showProvider = !providerName.isEmpty && (prefixLen + TUIUtil.stringWidth(modelName) + provLen + varLen <= availableWidth)
            let budget = max(8, availableWidth - prefixLen - (showProvider ? provLen : 0) - varLen)
            let fittedModel = TUIUtil.truncateWidth(modelName, budget)
            chunks.append(TextChunk(text: fittedModel, fg: theme.text.base, bg: promptBg))
            if showProvider {
                chunks.append(TextChunk(text: " \(providerName)", fg: theme.text.muted, bg: promptBg))
            }
            if let variant, !variant.isEmpty {
                chunks.append(TextChunk(text: " · ", fg: theme.text.muted, bg: promptBg))
                chunks.append(TextChunk(text: variant, fg: theme.text.feedback.warning.base, bg: promptBg, attributes: TextAttributes.bold))
            }
        }

        return AnyTUIView(
            TUIText(
                StyledText(chunks: chunks),
                bg: .rgba(promptBg),
                wrapMode: TextWrapMode.none,
                truncate: true
            )
            .width(.percent(100))
        )
    }

    private static func buildPromptFooterRow(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        agentColor: RGBA,
        isHome: Bool,
        columnWidth: Int
    ) -> AnyTUIView {
        let showShortcuts = state.cols >= 44
        let showUsageOnSession = !isHome && (state.contextTokens > 0 || state.sessionCost > 0)

        let rightTextWidth: Int
        if !showShortcuts {
            rightTextWidth = 0
        } else if showUsageOnSession {
            rightTextWidth = 28
        } else {
            rightTextWidth = 34 // "shift+tab agents  ctrl+p commands"
        }
        let leftBudget = max(12, columnWidth - rightTextWidth - 2)

        return AnyTUIView(
            HStack(spacing: 2, alignment: .center) {
                // Left side: Leader chord hint OR Running spinner + esc interrupt OR abbreviated path:branch
                if state.leaderArmed {
                    let leaderHints = TUIUtil.truncateWidth(
                        "m models  a agents  p connect  l sessions  t term  q queue  n new  b sidebar",
                        max(16, columnWidth - 10)
                    )
                    TUIText(
                        StyledText(chunks: [
                            TextChunk(text: "ctrl+x ", fg: agentColor, attributes: TextAttributes.bold),
                            TextChunk(text: leaderHints, fg: theme.text.muted),
                        ]),
                        wrapMode: TextWrapMode.none,
                        truncate: true
                    )
                    .id("prompt-footer-leader")
                    .flexShrink(1)
                } else if !isHome && state.sessionStatus.isRunning {
                    buildRunningPromptStatus(
                        state: state,
                        theme: theme,
                        agentColor: agentColor,
                        leftBudget: leftBudget
                    )
                } else {
                    let loc = TUIUtil.truncateMiddle(state.locationDisplayLabel, maxLength: leftBudget)
                    TUIText(loc, fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none, truncate: true)
                        .id("prompt-footer-location")
                        .flexShrink(1)
                }

                TUISpacer()

                // Right side: shift+tab agents   ctrl+p commands (or context/cost + ctrl+p commands)
                if showShortcuts && !state.leaderArmed {
                    if showUsageOnSession {
                        HStack(spacing: 2) {
                            let usageParts: [String] = [
                                state.contextTokens > 0
                                    ? (state.contextPercent.map { "\(TUIInteractiveState.formatTokenCount(state.contextTokens)) (\($0)%)" }
                                        ?? TUIInteractiveState.formatTokenCount(state.contextTokens))
                                    : nil,
                                state.sessionCost > 0 ? TUIInteractiveState.formatUSD(state.sessionCost) : nil,
                            ].compactMap { $0 }
                            if !usageParts.isEmpty {
                                TUIText(usageParts.joined(separator: " · "), fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)
                            }
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: "ctrl+p ", fg: theme.text.base),
                                    TextChunk(text: "commands", fg: theme.text.muted),
                                ]),
                                wrapMode: TextWrapMode.none
                            )
                        }
                        .flexShrink(0)
                    } else {
                        HStack(spacing: 2) {
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: "shift+tab ", fg: theme.text.base),
                                    TextChunk(text: "agents", fg: theme.text.muted),
                                ]),
                                wrapMode: TextWrapMode.none
                            )
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: "ctrl+p ", fg: theme.text.base),
                                    TextChunk(text: "commands", fg: theme.text.muted),
                                ]),
                                wrapMode: TextWrapMode.none
                            )
                        }
                        .flexShrink(0)
                    }
                }
            }
            .width(.percent(100))
            .height(1)
        )
    }

    // MARK: - Live `/` Slash Command Autocomplete Popover (`component/prompt/autocomplete.tsx`)

    private static func buildSlashAutocomplete(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        maxWidth: Int
    ) -> AnyTUIView {
        let matches = state.slashMatches
        let maxVisible = min(matches.count, max(1, min(6, state.rows - 14)))
        let selected = min(max(0, state.slashAutocompleteIndex), max(0, matches.count - 1))
        let startIdx = max(0, min(selected - maxVisible + 1, matches.count - maxVisible))
        let visibleSlice = Array(matches[startIdx..<min(matches.count, startIdx + maxVisible)])
        let bgSurface = theme.background.raised.high
        let selBg = theme.background.action.primary.focused
        let selFg = theme.text.action.primary.focused

        return AnyTUIView(
            TUIBox(
                border: .sides([.left, .right]),
                borderColor: .rgba(theme.border.base),
                backgroundColor: .rgba(bgSurface),
                shouldFill: true,
                customBorderChars: splitBorderChars
            ) {
                VStack(spacing: 0) {
                    for (offset, cmd) in visibleSlice.enumerated() {
                        let actualIndex = startIdx + offset
                        let isSel = actualIndex == selected
                        let rowBg = isSel ? selBg : bgSurface
                        let nameFg = isSel ? selFg : theme.text.base
                        let descFg = isSel ? selFg : theme.text.muted
                        let descBudget = max(10, maxWidth - 20)

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(rowBg),
                            shouldFill: true
                        ) {
                            HStack(spacing: 2) {
                                TUIText(cmd.name, fg: .rgba(nameFg), bg: .rgba(rowBg), attributes: isSel ? TextAttributes.bold : TextAttributes.none, wrapMode: TextWrapMode.none)
                                    .width(12)
                                TUIText(
                                    TUIUtil.truncateWidth(cmd.description, descBudget),
                                    fg: .rgba(descFg),
                                    bg: .rgba(rowBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .flexGrow(1)
                            }
                            .padding(right: 1, left: 1)
                            .width(.percent(100))
                        }
                        .key("slash-cmd-\(cmd.name)")
                        .width(.percent(100))
                        .height(1)
                    }
                }
                .width(.percent(100))
            }
            .id("opencode-slash-autocomplete")
            .width(.percent(100))
            .margin(bottom: 0)
            .flexShrink(0)
        )
    }

    // MARK: - Live `@` File & Agent Mention Autocomplete Popover (`component/prompt/autocomplete.tsx`)

    private static func buildMentionAutocomplete(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        maxWidth: Int
    ) -> AnyTUIView {
        let matches = state.mentionSuggestions
        let maxVisible = min(matches.count, max(1, min(6, state.rows - 14)))
        let selected = min(max(0, state.mentionAutocompleteIndex), max(0, matches.count - 1))
        let startIdx = max(0, min(selected - maxVisible + 1, matches.count - maxVisible))
        let visibleSlice = Array(matches[startIdx..<min(matches.count, startIdx + maxVisible)])
        let bgSurface = theme.background.raised.high
        let selBg = theme.background.action.primary.focused
        let selFg = theme.text.action.primary.focused

        return AnyTUIView(
            TUIBox(
                border: .sides([.left, .right]),
                borderColor: .rgba(theme.border.base),
                backgroundColor: .rgba(bgSurface),
                shouldFill: true,
                customBorderChars: splitBorderChars
            ) {
                VStack(spacing: 0) {
                    for (offset, item) in visibleSlice.enumerated() {
                        let actualIndex = startIdx + offset
                        let isSel = actualIndex == selected
                        let rowBg = isSel ? selBg : bgSurface
                        let nameFg = isSel ? selFg : theme.text.base
                        let subFg = isSel ? selFg : theme.text.muted
                        let kindTag = item.kind == .agent ? "agent" : "file"
                        let valBudget = max(12, maxWidth - 14)

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(rowBg),
                            shouldFill: true
                        ) {
                            HStack(spacing: 2) {
                                TUIText(
                                    TUIUtil.truncateWidth("@\(item.value)", valBudget),
                                    fg: .rgba(nameFg),
                                    bg: .rgba(rowBg),
                                    attributes: isSel ? TextAttributes.bold : TextAttributes.none,
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .flexGrow(1)
                                TUIText(kindTag, fg: .rgba(subFg), bg: .rgba(rowBg), wrapMode: TextWrapMode.none)
                                    .flexShrink(0)
                            }
                            .padding(right: 1, left: 1)
                            .width(.percent(100))
                        }
                        .key("mention-item-\(item.value)")
                        .width(.percent(100))
                        .height(1)
                    }
                }
                .width(.percent(100))
            }
            .id("opencode-mention-autocomplete")
            .width(.percent(100))
            .margin(bottom: 0)
            .flexShrink(0)
        )
    }

    // MARK: - Session Screen (`routes/session/index.tsx` + `sidebar.tsx` + `message-parts.tsx`)

    public static func buildSessionScreen(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let showSidebar = state.effectiveShowSidebar && state.cols >= 68
        let sidebarWidth = showSidebar ? min(40, max(28, state.cols / 3)) : 0
        let padX = state.cols < 44 ? 1 : 2
        let mainColWidth = max(24, state.cols - sidebarWidth - padX * 2)
        let agentColor = state.agentColor(theme: theme)

        return AnyTUIView(
            HStack(spacing: 0) {
                // Main Session Column: Session Tabs (when >=2) + Compact Header + Scrollable Transcript + Bottom-Pinned Prompt Composer + Optional Terminal Pane
                VStack(spacing: 0) {
                    if state.openSessionTabs.count >= 2 {
                        TUISessionTabsBar.buildSessionTabsBar(
                            tabs: state.openSessionTabs,
                            activeSessionID: state.activeSessionID,
                            sessions: state.sessions,
                            cols: mainColWidth,
                            theme: theme,
                            onSelectTab: actions.onSelectSessionTab,
                            onNewTab: actions.onNewSessionTab
                        )
                    }

                    buildSessionHeader(state: state, theme: theme, maxWidth: mainColWidth)

                    TUIScrollBox(
                        stickyScroll: state.preferences.scrollOnSend != "keep",
                        stickyStart: .bottom,
                        scrollX: false,
                        scrollY: true,
                        viewportCulling: true,
                        showVerticalScrollbar: state.preferences.showScrollbar,
                        showHorizontalScrollbar: false,
                        border: false,
                        backgroundColor: .rgba(theme.background.base),
                        verticalScrollbarOptions: ScrollBarOptions(
                            trackOptions: ScrollBarTrackStyleOptions(
                                foregroundColor: .rgba(theme.scrollbar.base),
                                backgroundColor: .rgba(theme.background.base)
                            )
                        )
                    ) {
                        VStack(spacing: 1) {
                            if state.messages.isEmpty {
                                TUIBox(border: false, shouldFill: false) {
                                    TUIText(
                                        "No messages yet. Ask a question below to begin.",
                                        fg: .rgba(theme.text.muted),
                                        attributes: TextAttributes.italic
                                    )
                                }
                                .padding(top: 1, left: 3)
                            } else {
                                for item in state.messages {
                                    buildTranscriptItem(
                                        item,
                                        state: state,
                                        theme: theme,
                                        syntaxStyle: syntaxStyle,
                                        agentColor: agentColor
                                    )
                                }
                            }
                        }
                        .padding(top: 1, right: 1, bottom: 1, left: 0)
                        .width(.percent(100))
                    }
                    .key("session-scrollbox")
                    .id("session-scrollbox")
                    .width(.percent(100))
                    .flexGrow(1)

                    // Docked Interactive Permission Prompt (`routes/session/permission.tsx`) or Form Prompt (`routes/session/form.tsx`)
                    if let perm = state.activePermission {
                        TUISessionOverlays.buildPermissionPrompt(
                            request: perm,
                            state: state.permissionPromptState,
                            theme: theme,
                            syntaxStyle: syntaxStyle,
                            columnWidth: mainColWidth,
                            onRejectInput: actions.onPermissionRejectInput,
                            onRejectSubmit: actions.onPermissionRejectSubmit
                        )
                    } else if let form = state.activeForm {
                        TUISessionOverlays.buildFormPrompt(
                            form: form,
                            state: state.formPromptState,
                            theme: theme,
                            columnWidth: mainColWidth,
                            onTextInput: actions.onFormTextInput,
                            onTextSubmit: actions.onFormTextSubmit
                        )
                    } else if state.isSlashAutocompleteVisible {
                        buildSlashAutocomplete(state: state, theme: theme, maxWidth: mainColWidth)
                    } else if state.isMentionAutocompleteVisible {
                        buildMentionAutocomplete(state: state, theme: theme, maxWidth: mainColWidth)
                    }

                    // Bottom-pinned exact left-bordered Prompt Composer
                    buildPromptComposer(
                        state: state,
                        theme: theme,
                        isHome: false,
                        columnWidth: mainColWidth,
                        actions: actions
                    )

                    // Bottom-docked Embedded Live Terminal Pane (`<leader>t`)
                    if state.terminalPane.isOpen {
                        TUIEmbeddedTerminalPane.buildEmbeddedTerminalPane(
                            state: state.terminalPane,
                            theme: theme,
                            height: TUIEmbeddedTerminalPane.paneHeight(forRows: state.rows),
                            onClose: actions.onCloseTerminalPane,
                            onFocus: actions.onFocusTerminalPane,
                            onInput: actions.onTerminalInput,
                            onSubmit: actions.onTerminalSubmit
                        )
                    }
                }
                .padding(right: .point(Float(padX)), bottom: 1, left: .point(Float(padX)))
                .flexGrow(1)
                .minWidth(0)
                .height(.percent(100))

                // Collapsible Right Sidebar (`Ctrl+B`, matching `routes/session/sidebar.tsx`)
                if showSidebar {
                    buildSessionSidebar(state: state, theme: theme, width: sidebarWidth)
                }
            }
            .width(.percent(100))
            .height(.percent(100))
        )
    }

    private static func buildSessionHeader(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        maxWidth: Int
    ) -> AnyTUIView {
        var metaParts: [String] = []
        if state.contextTokens > 0 {
            let tok = TUIInteractiveState.formatTokenCount(state.contextTokens)
            if let pct = state.contextPercent {
                metaParts.append("\(tok) (\(pct)%)")
            } else {
                metaParts.append("\(tok) tokens")
            }
        }
        if state.sessionCost > 0 {
            metaParts.append(TUIInteractiveState.formatUSD(state.sessionCost))
        }
        let metaText = metaParts.joined(separator: " · ")
        let titleBudget = max(12, maxWidth - TUIUtil.stringWidth(metaText) - 6)
        let title = TUIUtil.truncateWidth(state.activeSessionTitle, titleBudget)

        return AnyTUIView(
            HStack(spacing: 2, alignment: .center) {
                TUIText(
                    StyledText(chunks: [
                        TextChunk(text: "# ", fg: theme.text.muted),
                        TextChunk(text: title, fg: theme.text.base, attributes: TextAttributes.bold),
                    ]),
                    wrapMode: TextWrapMode.none,
                    truncate: true
                )
                .flexShrink(1)

                TUISpacer()

                if !metaText.isEmpty {
                    TUIText(metaText, fg: .rgba(theme.text.muted), wrapMode: TextWrapMode.none)
                        .flexShrink(0)
                }
            }
            .id("opencode-session-header")
            .padding(top: 1, bottom: 0)
            .width(.percent(100))
            .flexShrink(0)
        )
    }

    private static func buildTranscriptItem(
        _ item: TUITranscriptItem,
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle,
        agentColor: RGBA
    ) -> AnyTUIView {
        switch item {
        case .user(let id, let text, _, _):
            let userBg = theme.background.raised.base
            return AnyTUIView(
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(agentColor),
                    backgroundColor: .rgba(transparent),
                    shouldFill: false,
                    customBorderChars: splitBorderChars
                ) {
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(userBg),
                        shouldFill: true
                    ) {
                        TUIText(text, fg: .rgba(theme.text.base), bg: .rgba(userBg), wrapMode: .word)
                            .width(.percent(100))
                    }
                    .padding(top: 1, right: 2, bottom: 1, left: 2)
                    .width(.percent(100))
                }
                .key("msg-user-\(id)")
                .width(.percent(100))
                .flexShrink(0)
            )

        case .assistant(let id, _, _, let parts, let completed, let error):
            return AnyTUIView(
                VStack(spacing: 1) {
                    for part in parts {
                        buildAssistantPart(
                            part,
                            completed: completed,
                            state: state,
                            theme: theme,
                            syntaxStyle: syntaxStyle,
                            agentColor: agentColor
                        )
                    }
                    if let error, !error.isEmpty {
                        TUIText("Error: \(error)", fg: .rgba(theme.text.feedback.error.base), wrapMode: .word)
                            .padding(left: 3)
                    }
                }
                .key("msg-assistant-\(id)")
                .width(.percent(100))
                .flexShrink(0)
            )

        case .system(let id, let text, let isError):
            return AnyTUIView(
                TUIText(
                    text,
                    fg: .rgba(isError ? theme.text.feedback.error.base : theme.text.muted),
                    attributes: isError ? TextAttributes.none : TextAttributes.italic,
                    wrapMode: .word
                )
                .key("msg-system-\(id)")
                .padding(left: 3)
                .width(.percent(100))
                .flexShrink(0)
            )
        }
    }

    private static func buildAssistantPart(
        _ part: TUIAssistantPartItem,
        completed: Bool,
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle,
        agentColor: RGBA
    ) -> AnyTUIView {
        switch part {
        case .reasoning(let id, let text, let partDone):
            guard state.preferences.showThinking else { return AnyTUIView(EmptyTUIView()) }
            let header = partDone ? "Thought" : "\(spinnerFrames[state.spinnerTick % spinnerFrames.count]) Thinking"
            let railColor = theme.decrease(theme.background.base)
            return AnyTUIView(
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(railColor),
                    backgroundColor: .rgba(transparent),
                    shouldFill: false,
                    customBorderChars: splitBorderChars
                ) {
                    VStack(spacing: 0) {
                        TUIText(
                            header,
                            fg: .rgba(theme.text.feedback.warning.base),
                            attributes: TextAttributes.italic,
                            wrapMode: TextWrapMode.none
                        )
                        if !text.isEmpty {
                            TUIText(
                                text,
                                fg: .rgba(theme.text.muted),
                                attributes: TextAttributes.italic,
                                wrapMode: .word
                            )
                            .width(.percent(100))
                        }
                    }
                    .padding(left: 1)
                    .width(.percent(100))
                }
                .key("part-reasoning-\(id)")
                .margin(left: 3)
                .width(.percent(100))
                .flexShrink(0)
            )

        case .text(let id, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return AnyTUIView(EmptyTUIView()) }
            let activeTheme = theme
            let activeMode: Mode = state.effectiveMode == .light ? .light : .dark
            return AnyTUIView(
                TUIMarkdown(
                    trimmed,
                    syntaxStyle: syntaxStyle,
                    conceal: state.preferences.concealMarkdown,
                    streaming: !completed,
                    fg: .rgba(theme.markdown.text),
                    bg: .rgba(theme.background.base),
                    renderNodeProvider: { ctx in
                        var renderers = LatexPlugin.createCodeBlockRenderers(context: ctx) { activeTheme }
                        let palette = Merman.resolveOpenCodeDiagramPalette(theme: activeTheme, mode: activeMode)
                        renderers["mermaid"] = Merman.createMermaidCodeBlockRenderer(
                            ctx: ctx,
                            options: Merman.MermaidMarkdownRendererOptions(colors: palette.asColorOverrides())
                        )
                        return createMarkdownCodeBlockRenderer(renderers)
                    }
                )
                .key("part-text-\(id)")
                .padding(left: 3)
                .width(.percent(100))
                .flexShrink(0)
            )

        case .tool(let id, let name, let status, let summary, let outputPreview, let error):
            let icon = toolIcon(for: name, status: status, spinnerTick: state.spinnerTick)
            let iconColor: RGBA
            switch status {
            case .streaming, .running:
                iconColor = agentColor
            case .completed:
                iconColor = theme.text.muted
            case .error:
                iconColor = theme.text.feedback.error.base
            }
            let textColor = status == .error ? theme.text.feedback.error.base : theme.text.muted
            var chunks: [TextChunk] = [
                TextChunk(text: "\(icon) ", fg: iconColor),
                TextChunk(text: name, fg: status == .error ? theme.text.feedback.error.base : theme.text.base),
            ]
            if !summary.isEmpty {
                chunks.append(TextChunk(text: " \(summary)", fg: textColor))
            }

            return AnyTUIView(
                VStack(spacing: 0) {
                    TUIText(StyledText(chunks: chunks), wrapMode: TextWrapMode.none, truncate: true)
                        .width(.percent(100))
                    if let error, !error.isEmpty {
                        TUIText("  \(error)", fg: .rgba(theme.text.feedback.error.base), wrapMode: .word)
                            .width(.percent(100))
                    } else if let preview = outputPreview, !preview.isEmpty {
                        TUIText(preview, fg: .rgba(theme.text.faint), wrapMode: .word)
                            .padding(left: 2)
                            .width(.percent(100))
                    }
                }
                .key("part-tool-\(id)")
                .padding(left: 3)
                .width(.percent(100))
                .flexShrink(0)
            )
        }
    }

    public static func toolIcon(for name: String, status: TUIToolRunStatus, spinnerTick: Int) -> String {
        if status == .streaming || status == .running {
            return spinnerFrames[spinnerTick % spinnerFrames.count]
        }
        if status == .error {
            return "✗"
        }
        switch name.lowercased() {
        case "read", "fs_read":
            return "⚙"
        case "edit", "write", "patch", "apply_patch":
            return "✎"
        case "shell", "bash", "exec":
            return "$"
        case "glob", "grep", "search":
            return "⌕"
        case "webfetch", "websearch":
            return "◈"
        default:
            return "⚙"
        }
    }

    // MARK: - Collapsible Session Sidebar (`routes/session/sidebar.tsx` + `feature-plugins/sidebar/*`)

    private static func buildSessionSidebar(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        width: Int
    ) -> AnyTUIView {
        let bg = theme.background.raised.base
        let innerWidth = max(12, width - 4)

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(bg),
                shouldFill: true
            ) {
                VStack(spacing: 1) {
                    // Session Title
                    TUIText(
                        TUIUtil.truncateWidth(state.activeSessionTitle, innerWidth),
                        fg: .rgba(theme.text.base),
                        bg: .rgba(bg),
                        attributes: TextAttributes.bold,
                        wrapMode: .word
                    )

                    // Context Section (`feature-plugins/sidebar/context.tsx`)
                    VStack(spacing: 0) {
                        TUIText("Context", fg: .rgba(theme.text.base), bg: .rgba(bg), attributes: TextAttributes.bold)
                        TUIText(
                            "\(TUIInteractiveState.formatTokenCount(state.contextTokens)) tokens",
                            fg: .rgba(theme.text.muted),
                            bg: .rgba(bg)
                        )
                        if let pct = state.contextPercent {
                            TUIText("\(pct)% used", fg: .rgba(theme.text.muted), bg: .rgba(bg))
                        }
                        if state.sessionCost > 0 {
                            TUIText(
                                "\(TUIInteractiveState.formatUSD(state.sessionCost)) spent",
                                fg: .rgba(theme.text.muted),
                                bg: .rgba(bg)
                            )
                        }
                    }

                    // MCP Section (`feature-plugins/sidebar/mcp.tsx`)
                    if !state.mcpServers.isEmpty {
                        VStack(spacing: 0) {
                            TUIText("MCP", fg: .rgba(theme.text.base), bg: .rgba(bg), attributes: TextAttributes.bold)
                            for server in state.mcpServers.prefix(8) {
                                buildSidebarMCPRow(server: server, theme: theme, bg: bg, innerWidth: innerWidth)
                            }
                        }
                    }

                    // Todo Checklist Section (`feature-plugins/sidebar/todo.tsx`)
                    if !state.todos.isEmpty {
                        TUISessionOverlays.buildSidebarTodoSection(
                            items: state.todos,
                            expanded: true,
                            theme: theme,
                            background: bg,
                            innerWidth: innerWidth
                        )
                    }

                    // Modified Files Section
                    if !state.modifiedFiles.isEmpty {
                        VStack(spacing: 0) {
                            TUIText("Modified Files", fg: .rgba(theme.text.base), bg: .rgba(bg), attributes: TextAttributes.bold)
                            for file in state.modifiedFiles.prefix(8) {
                                buildSidebarFileRow(file: file, theme: theme, bg: bg, innerWidth: innerWidth)
                            }
                        }
                    }

                    TUISpacer()

                    // Bottom Directory + Git Branch (`feature-plugins/sidebar/footer.tsx`)
                    TUIText(
                        TUIUtil.truncateMiddle(state.locationDisplayLabel, maxLength: innerWidth),
                        fg: .rgba(theme.text.muted),
                        bg: .rgba(bg),
                        wrapMode: TextWrapMode.none,
                        truncate: true
                    )
                }
                .width(.percent(100))
                .height(.percent(100))
            }
            .id("opencode-session-sidebar")
            .padding(top: 1, right: 2, bottom: 1, left: 2)
            .width(width)
            .height(.percent(100))
            .flexShrink(0)
        )
    }

    // MARK: - Floating Centered Modal Dialog (`ui/dialog.tsx` + `ui/dialog-select.tsx`)

    public static func buildDialogOverlay(
        dialog: TUIActiveDialog,
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle? = nil,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        switch dialog {
        case .diffViewer:
            return TUISessionOverlays.buildDiffViewerOverlay(
                state: state.diffViewerState,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                syntaxStyle: syntaxStyle ?? generateSyntax(theme),
                onClose: actions.onDialogClose
            )
        case .pair:
            return TUISessionOverlays.buildPairDialogOverlay(
                info: state.pairingInfo,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onClose: actions.onDialogClose
            )
        case .status:
            return TUISessionOverlays.buildStatusDialogOverlay(
                snapshot: state.statusSnapshot,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onClose: actions.onDialogClose
            )
        case .usage:
            return TUISessionOverlays.buildUsageDialogOverlay(
                workspaceName: state.usageWorkspaceName,
                isSignedIn: state.usageSignedIn,
                limits: state.usageLimits,
                selectedIndex: state.dialogSelectedIndex,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onClose: actions.onDialogClose
            )
        case .debug:
            return TUISessionOverlays.buildDebugDialogOverlay(
                snapshot: state.debugSnapshot,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onClose: actions.onDialogClose
            )
        case .help:
            return TUISessionOverlays.buildHelpDialogOverlay(
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onClose: actions.onDialogClose
            )
        case .renameSession:
            return TUISessionOverlays.buildRenameSessionDialogOverlay(
                currentTitle: state.activeSessionTitle,
                draftTitle: state.renameDraft,
                cols: state.cols,
                rows: state.rows,
                theme: theme,
                onInput: actions.onRenameInput,
                onSubmit: actions.onRenameSubmit,
                onClose: actions.onDialogClose
            )
        default:
            break
        }

        let dialogTheme = theme.surface(.dialog)
        let cardWidth = min(66, max(36, state.cols - 4))
        let innerWidth = max(24, cardWidth - 6)
        let topPad = max(2, state.rows / 5)
        let cardBg = dialogTheme.background.base

        if dialog == .connectAPIKey {
            return buildAPIKeyDialogOverlay(
                state: state,
                dialogTheme: dialogTheme,
                cardBg: cardBg,
                cardWidth: cardWidth,
                topPad: topPad,
                actions: actions
            )
        }
        if dialog == .connectOAuth {
            return buildOAuthDialogOverlay(
                state: state,
                dialogTheme: dialogTheme,
                cardBg: cardBg,
                cardWidth: cardWidth,
                topPad: topPad,
                actions: actions
            )
        }

        let rows = state.dialogRows()
        let maxVisible = max(4, min(11, state.rows - topPad - 8))
        let selectedIndex = rows.isEmpty ? 0 : min(max(0, state.dialogSelectedIndex), rows.count - 1)
        let startIdx = rows.count <= maxVisible
            ? 0
            : max(0, min(selectedIndex - maxVisible / 2, rows.count - maxVisible))
        let visibleRows = Array(rows[startIdx..<min(rows.count, startIdx + maxVisible)])

        let title: String
        let searchPlaceholder: String
        let emptyMessage: String
        switch dialog {
        case .commandPalette:
            title = "Commands"
            searchPlaceholder = "Search commands"
            emptyMessage = "No matching commands"
        case .modelPicker:
            if let pid = state.modelPickerProviderID, !pid.isEmpty {
                title = state.providers[pid] ?? state.integrations.first(where: { $0.id == pid })?.name ?? TUIUtil.titlecase(pid)
            } else {
                title = "Select model"
            }
            searchPlaceholder = "Search models"
            emptyMessage = state.models.isEmpty ? "No models connected — press ctrl+a to connect a provider" : "No matching models"
        case .connectProvider:
            title = "Connect a provider"
            searchPlaceholder = "Search providers"
            emptyMessage = state.visibleProviderIntegrations.isEmpty ? "No providers available" : "No matching providers"
        case .connectMethod:
            title = "Connect \(state.connectTargetIntegrationName)"
            searchPlaceholder = "Select method"
            emptyMessage = "No connection methods available"
        case .manageConnections:
            title = state.connectTargetIntegrationName.isEmpty ? "Connected accounts" : state.connectTargetIntegrationName
            searchPlaceholder = "Filter accounts"
            emptyMessage = "No connected accounts"
        case .agentPicker:
            title = "Select agent"
            searchPlaceholder = "Search agents"
            emptyMessage = "No matching agents"
        case .variantPicker:
            title = "Select variant"
            searchPlaceholder = "Search variants"
            emptyMessage = "No variants available"
        case .sessionList:
            title = "Sessions"
            searchPlaceholder = "Search sessions"
            emptyMessage = state.sessions.isEmpty ? "No sessions yet" : "No matching sessions"
        case .themePicker:
            title = "Select theme"
            searchPlaceholder = "Search themes"
            emptyMessage = "No matching themes"
        case .mcpStatus:
            title = "MCP Servers"
            searchPlaceholder = "Filter MCP servers"
            emptyMessage = "No MCP servers configured"
        case .settings:
            title = "Settings"
            searchPlaceholder = "Search settings"
            emptyMessage = "No matching settings"
        case .skills:
            title = "Skills"
            searchPlaceholder = "Search skills"
            emptyMessage = state.skills.isEmpty ? "No skills available" : "No matching skills"
        case .timeline:
            title = "Timeline"
            searchPlaceholder = "Search timeline"
            emptyMessage = "No user messages in this session"
        case .stashList:
            title = "Prompt Stash"
            searchPlaceholder = "Search stashed prompts"
            emptyMessage = "No stashed prompts"
        case .workspaces:
            title = "Workspaces"
            searchPlaceholder = "Filter workspaces"
            emptyMessage = "No workspaces found"
        case .queuedPrompts:
            title = "Queued prompts"
            searchPlaceholder = "Search queued prompts"
            emptyMessage = "No queued prompts"
        case .connectAPIKey, .connectOAuth, .status, .usage, .pair, .help, .debug, .renameSession, .diffViewer:
            title = "Dialog"
            searchPlaceholder = ""
            emptyMessage = ""
        }

        let selBg = dialogTheme.background.action.primary.focused
        let selFg = dialogTheme.text.action.primary.focused

        let footerChunks: [TextChunk]
        switch dialog {
        case .modelPicker:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "select", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  ctrl+a ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "connect", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  ctrl+f ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "favorite", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .sessionList:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "open", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  ctrl+r ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "rename", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  ctrl+f ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "pin", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "  ctrl+d ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "delete", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .settings:
            footerChunks = [
                TextChunk(text: "←/→/enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "change", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ↑↓ ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "navigate", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .stashList:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "pop", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ctrl+d ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "delete", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .timeline:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "revert", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ctrl+f ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "fork here", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .connectProvider:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "connect", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ↑↓ ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "navigate", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .manageConnections:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "select", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ctrl+d ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "remove", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "back", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .connectMethod:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "select", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "back", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .mcpStatus:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "toggle", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ↑↓ ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "navigate", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        case .queuedPrompts:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "steer", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ctrl+u ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "undo", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ctrl+d ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "delete", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        default:
            footerChunks = [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "select", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   ↑↓ ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "navigate", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ]
        }

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(RGBA.fromInts(0, 0, 0, 140)),
                shouldFill: true
            ) {
                TUIBox(
                    border: false,
                    backgroundColor: .rgba(cardBg),
                    shouldFill: true
                ) {
                    VStack(spacing: 1) {
                        // Header Row (`Title` bold + `esc`)
                        HStack(spacing: 2) {
                            TUIText(
                                title,
                                fg: .rgba(dialogTheme.text.base),
                                bg: .rgba(cardBg),
                                attributes: TextAttributes.bold,
                                wrapMode: TextWrapMode.none
                            )
                            TUISpacer()
                            TUIText("esc", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg), wrapMode: TextWrapMode.none)
                                .onMouseUp { _ in actions.onDialogClose() }
                        }
                        .width(.percent(100))

                        // Search Filter Input
                        TUIInput(
                            value: state.dialogFilter,
                            placeholder: searchPlaceholder,
                            placeholderColor: .rgba(dialogTheme.text.muted),
                            maxLength: 120,
                            textColor: .rgba(dialogTheme.text.base),
                            backgroundColor: .rgba(cardBg),
                            focusedTextColor: .rgba(dialogTheme.text.formfield.focused),
                            focusedBackgroundColor: .rgba(cardBg),
                            showCursor: true,
                            cursorColor: .rgba(dialogTheme.text.formfield.focused),
                            onInput: actions.onDialogFilterInput,
                            onSubmit: { _ in actions.onDialogSubmit() }
                        )
                        .key("dialog-filter-input-\(dialog.rawValue)")
                        .id("dialog-filter-input")
                        .width(.percent(100))
                        .focused(true)

                        // Scrollable List Body
                        VStack(spacing: 0) {
                            if visibleRows.isEmpty {
                                TUIText(
                                    emptyMessage,
                                    fg: .rgba(dialogTheme.text.muted),
                                    bg: .rgba(cardBg)
                                )
                                .padding(top: 0, bottom: 0)
                            } else {
                                for (offset, row) in visibleRows.enumerated() {
                                    let actualIndex = startIdx + offset
                                    buildDialogRowView(
                                        dialog: dialog,
                                        row: row,
                                        rowIndex: actualIndex,
                                        isSelected: actualIndex == selectedIndex,
                                        dialogTheme: dialogTheme,
                                        cardBg: cardBg,
                                        selBg: selBg,
                                        selFg: selFg,
                                        innerWidth: innerWidth,
                                        onSelectRow: actions.onSelectDialogRow
                                    )
                                }
                            }
                        }
                        .width(.percent(100))

                        // Footer Hints
                        TUIText(
                            StyledText(chunks: footerChunks),
                            bg: .rgba(cardBg),
                            wrapMode: TextWrapMode.none,
                            truncate: true
                        )
                    }
                    .width(.percent(100))
                }
                .id("opencode-dialog-card")
                .padding(top: 1, right: 3, bottom: 1, left: 3)
                .width(cardWidth)
            }
            .id("opencode-dialog-backdrop")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.flexStart)
            .padding(top: .point(Float(topPad)))
            .zIndex(3000)
        )
    }

    private static func buildAPIKeyDialogOverlay(
        state: TUIInteractiveState,
        dialogTheme: ResolvedTheme,
        cardBg: RGBA,
        cardWidth: Int,
        topPad: Int,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let title = "Connect \(state.connectTargetIntegrationName)"
        let inputBg = dialogTheme.decrease(cardBg)

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(RGBA.fromInts(0, 0, 0, 140)),
                shouldFill: true
            ) {
                TUIBox(
                    border: false,
                    backgroundColor: .rgba(cardBg),
                    shouldFill: true
                ) {
                    VStack(spacing: 1) {
                        HStack(spacing: 2) {
                            TUIText(
                                title,
                                fg: .rgba(dialogTheme.text.base),
                                bg: .rgba(cardBg),
                                attributes: TextAttributes.bold,
                                wrapMode: TextWrapMode.none
                            )
                            TUISpacer()
                            TUIText("esc", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg), wrapMode: TextWrapMode.none)
                                .onMouseUp { _ in actions.onDialogClose() }
                        }
                        .width(.percent(100))

                        TUIText(
                            "Enter your \(state.connectMethodLabel) to connect \(state.connectTargetIntegrationName).",
                            fg: .rgba(dialogTheme.text.muted),
                            bg: .rgba(cardBg),
                            wrapMode: .word
                        )
                        .width(.percent(100))

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(inputBg),
                            shouldFill: true
                        ) {
                            TUIInput(
                                value: state.dialogFilter,
                                placeholder: "Paste API key…",
                                placeholderColor: .rgba(dialogTheme.text.muted),
                                maxLength: 512,
                                textColor: .rgba(dialogTheme.text.base),
                                backgroundColor: .rgba(inputBg),
                                focusedTextColor: .rgba(dialogTheme.text.formfield.focused),
                                focusedBackgroundColor: .rgba(inputBg),
                                showCursor: !state.connectSubmitting,
                                cursorColor: .rgba(dialogTheme.text.formfield.focused),
                                onInput: actions.onDialogFilterInput,
                                onSubmit: { _ in actions.onDialogSubmit() }
                            )
                            .key("dialog-apikey-input")
                            .id("dialog-apikey-input")
                            .width(.percent(100))
                            .focused(true)
                        }
                        .padding(top: 0, right: 1, bottom: 0, left: 1)
                        .width(.percent(100))

                        if state.connectSubmitting {
                            TUIText("Connecting…", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg))
                        } else if let err = state.connectErrorMessage, !err.isEmpty {
                            TUIText(err, fg: .rgba(dialogTheme.text.feedback.error.base), bg: .rgba(cardBg), wrapMode: .word)
                                .width(.percent(100))
                        }

                        TUIText(
                            StyledText(chunks: [
                                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                                TextChunk(text: "connect", fg: dialogTheme.text.muted, bg: cardBg),
                                TextChunk(text: "   esc ", fg: dialogTheme.text.base, bg: cardBg),
                                TextChunk(text: "back", fg: dialogTheme.text.muted, bg: cardBg),
                            ]),
                            bg: .rgba(cardBg),
                            wrapMode: TextWrapMode.none
                        )
                    }
                    .width(.percent(100))
                }
                .id("opencode-dialog-card")
                .padding(top: 1, right: 3, bottom: 1, left: 3)
                .width(cardWidth)
            }
            .id("opencode-dialog-backdrop")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.flexStart)
            .padding(top: .point(Float(topPad)))
            .zIndex(3000)
        )
    }

    private static func buildOAuthDialogOverlay(
        state: TUIInteractiveState,
        dialogTheme: ResolvedTheme,
        cardBg: RGBA,
        cardWidth: Int,
        topPad: Int,
        actions: TUIScreenActions
    ) -> AnyTUIView {
        let title = "Connect \(state.connectTargetIntegrationName)"
        let inputBg = dialogTheme.decrease(cardBg)

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(RGBA.fromInts(0, 0, 0, 140)),
                shouldFill: true
            ) {
                TUIBox(
                    border: false,
                    backgroundColor: .rgba(cardBg),
                    shouldFill: true
                ) {
                    VStack(spacing: 1) {
                        HStack(spacing: 2) {
                            TUIText(
                                title,
                                fg: .rgba(dialogTheme.text.base),
                                bg: .rgba(cardBg),
                                attributes: TextAttributes.bold,
                                wrapMode: TextWrapMode.none
                            )
                            TUISpacer()
                            TUIText("esc", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg), wrapMode: TextWrapMode.none)
                                .onMouseUp { _ in actions.onDialogClose() }
                        }
                        .width(.percent(100))

                        if let url = state.connectOAuthURL, !url.isEmpty {
                            TUIText(
                                url,
                                fg: .rgba(dialogTheme.text.action.primary.selected),
                                bg: .rgba(cardBg),
                                wrapMode: .word
                            )
                            .width(.percent(100))
                        }

                        if let instructions = state.connectOAuthInstructions, !instructions.isEmpty {
                            TUIText(
                                instructions,
                                fg: .rgba(dialogTheme.text.muted),
                                bg: .rgba(cardBg),
                                wrapMode: .word
                            )
                            .width(.percent(100))
                        }

                        if state.connectOAuthNeedsCode {
                            TUIBox(
                                border: false,
                                backgroundColor: .rgba(inputBg),
                                shouldFill: true
                            ) {
                                TUIInput(
                                    value: state.dialogFilter,
                                    placeholder: "Paste authorization code…",
                                    placeholderColor: .rgba(dialogTheme.text.muted),
                                    maxLength: 512,
                                    textColor: .rgba(dialogTheme.text.base),
                                    backgroundColor: .rgba(inputBg),
                                    focusedTextColor: .rgba(dialogTheme.text.formfield.focused),
                                    focusedBackgroundColor: .rgba(inputBg),
                                    showCursor: !state.connectSubmitting,
                                    cursorColor: .rgba(dialogTheme.text.formfield.focused),
                                    onInput: actions.onDialogFilterInput,
                                    onSubmit: { _ in actions.onDialogSubmit() }
                                )
                                .key("dialog-oauth-input")
                                .id("dialog-oauth-input")
                                .width(.percent(100))
                                .focused(true)
                            }
                            .padding(top: 0, right: 1, bottom: 0, left: 1)
                            .width(.percent(100))
                        } else if state.connectErrorMessage == nil {
                            TUIText("Waiting for authorization…", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg))
                        }

                        if let err = state.connectErrorMessage, !err.isEmpty {
                            TUIText(err, fg: .rgba(dialogTheme.text.feedback.error.base), bg: .rgba(cardBg), wrapMode: .word)
                                .width(.percent(100))
                        }

                        TUIText(
                            StyledText(chunks: [
                                TextChunk(text: state.connectOAuthNeedsCode ? "enter " : "", fg: dialogTheme.text.base, bg: cardBg),
                                TextChunk(text: state.connectOAuthNeedsCode ? "complete   " : "", fg: dialogTheme.text.muted, bg: cardBg),
                                TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg),
                                TextChunk(text: "cancel", fg: dialogTheme.text.muted, bg: cardBg),
                            ]),
                            bg: .rgba(cardBg),
                            wrapMode: TextWrapMode.none
                        )
                    }
                    .width(.percent(100))
                }
                .id("opencode-dialog-card")
                .padding(top: 1, right: 3, bottom: 1, left: 3)
                .width(cardWidth)
            }
            .id("opencode-dialog-backdrop")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.flexStart)
            .padding(top: .point(Float(topPad)))
            .zIndex(3000)
        )
    }

    // MARK: - Extracted Row Helpers

    private static func buildRunningPromptStatus(
        state: TUIInteractiveState,
        theme: ResolvedTheme,
        agentColor: RGBA,
        leftBudget: Int
    ) -> AnyTUIView {
        let glyph = spinnerFrames[state.spinnerTick % spinnerFrames.count]
        let statusChunks: [TextChunk]
        if state.interruptArmed {
            statusChunks = [
                TextChunk(text: "\(glyph) ", fg: agentColor),
                TextChunk(text: "press esc again to interrupt", fg: theme.text.feedback.warning.base, attributes: TextAttributes.bold),
            ]
        } else if case .retry(let msg) = state.sessionStatus {
            statusChunks = [
                TextChunk(text: "\(glyph) ", fg: theme.text.feedback.warning.base),
                TextChunk(text: TUIUtil.truncateWidth(msg, max(10, leftBudget - 16)), fg: theme.text.feedback.warning.base),
                TextChunk(text: "  esc ", fg: theme.text.base),
                TextChunk(text: "interrupt", fg: theme.text.muted),
            ]
        } else {
            statusChunks = [
                TextChunk(text: "\(glyph) ", fg: agentColor),
                TextChunk(text: "esc ", fg: theme.text.base),
                TextChunk(text: "interrupt", fg: theme.text.muted),
            ]
        }
        return AnyTUIView(
            TUIText(StyledText(chunks: statusChunks), wrapMode: TextWrapMode.none)
                .flexShrink(1)
        )
    }

    private static func buildSidebarMCPRow(
        server: TUIMCPServerItem,
        theme: ResolvedTheme,
        bg: RGBA,
        innerWidth: Int
    ) -> AnyTUIView {
        let dotColor: RGBA
        switch server.status {
        case .connected: dotColor = theme.text.feedback.success.base
        case .failed: dotColor = theme.text.feedback.error.base
        case .needsAuth: dotColor = theme.text.feedback.warning.base
        case .pending, .disabled: dotColor = theme.text.muted
        }
        let statusColor = server.status.isFailed ? theme.text.feedback.error.base : theme.text.muted
        return AnyTUIView(
            HStack(spacing: 1) {
                TUIText(
                    StyledText(chunks: [
                        TextChunk(text: "• ", fg: dotColor, bg: bg),
                        TextChunk(
                            text: TUIUtil.truncateWidth(server.name, max(8, innerWidth - 12)),
                            fg: theme.text.base,
                            bg: bg,
                            attributes: TextAttributes.bold
                        ),
                    ]),
                    bg: .rgba(bg),
                    wrapMode: TextWrapMode.none
                )
                .flexGrow(1)
                TUIText(server.status.label, fg: .rgba(statusColor), bg: .rgba(bg), wrapMode: TextWrapMode.none)
                    .flexShrink(0)
            }
            .key("sidebar-mcp-\(server.name)")
            .width(.percent(100))
        )
    }

    private static func buildSidebarFileRow(
        file: TUIModifiedFileItem,
        theme: ResolvedTheme,
        bg: RGBA,
        innerWidth: Int
    ) -> AnyTUIView {
        var chunks: [TextChunk] = [
            TextChunk(text: TUIUtil.truncateLeft(file.path, max(10, innerWidth - 10)), fg: theme.text.base, bg: bg),
        ]
        if file.additions > 0 {
            chunks.append(TextChunk(text: " +\(file.additions)", fg: theme.diff.text.added, bg: bg))
        }
        if file.deletions > 0 {
            chunks.append(TextChunk(text: " -\(file.deletions)", fg: theme.diff.text.removed, bg: bg))
        }
        return AnyTUIView(
            TUIText(StyledText(chunks: chunks), bg: .rgba(bg), wrapMode: TextWrapMode.none, truncate: true)
                .key("sidebar-file-\(file.path)")
        )
    }

    private static func buildDialogRowView(
        dialog: TUIActiveDialog,
        row: TUIDialogRow,
        rowIndex: Int,
        isSelected: Bool,
        dialogTheme: ResolvedTheme,
        cardBg: RGBA,
        selBg: RGBA,
        selFg: RGBA,
        innerWidth: Int,
        onSelectRow: @escaping @Sendable (Int) -> Void
    ) -> AnyTUIView {
        let rowBg = isSelected ? selBg : cardBg
        let fgMain = isSelected ? selFg : dialogTheme.text.base
        let fgMuted = isSelected ? selFg : dialogTheme.text.muted
        let trailingStr = row.trailing ?? ""
        let trailingWidth = TUIUtil.stringWidth(trailingStr)
        let prefixMarker: String
        let markerColor: RGBA
        if let kind = row.badgeColorKind {
            prefixMarker = "● "
            if isSelected {
                markerColor = selFg
            } else {
                switch kind {
                case .success: markerColor = dialogTheme.text.feedback.success.base
                case .error: markerColor = dialogTheme.text.feedback.error.base
                case .warning: markerColor = dialogTheme.text.feedback.warning.base
                case .muted: markerColor = dialogTheme.text.muted
                }
            }
        } else if row.isActive {
            prefixMarker = "● "
            markerColor = isSelected ? selFg : dialogTheme.text.action.primary.selected
        } else {
            prefixMarker = "  "
            markerColor = fgMuted
        }

        let titleBudget = max(10, innerWidth - trailingWidth - 4)
        var leftChunks: [TextChunk] = [
            TextChunk(text: prefixMarker, fg: markerColor, bg: rowBg),
            TextChunk(
                text: TUIUtil.truncateWidth(row.title, titleBudget),
                fg: fgMain,
                bg: rowBg,
                attributes: isSelected ? TextAttributes.bold : TextAttributes.none
            ),
        ]
        if let sub = row.subtitle, !sub.isEmpty {
            let used = TUIUtil.stringWidth(row.title) + 2
            let subBudget = titleBudget - used
            if subBudget >= 6 {
                leftChunks.append(TextChunk(
                    text: " \(TUIUtil.truncateWidth(sub, subBudget))",
                    fg: fgMuted,
                    bg: rowBg
                ))
            }
        }

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(rowBg),
                shouldFill: true
            ) {
                HStack(spacing: 1) {
                    TUIText(StyledText(chunks: leftChunks), bg: .rgba(rowBg), wrapMode: TextWrapMode.none, truncate: true)
                        .flexGrow(1)
                    if !trailingStr.isEmpty {
                        TUIText(trailingStr, fg: .rgba(fgMuted), bg: .rgba(rowBg), wrapMode: TextWrapMode.none)
                            .flexShrink(0)
                    }
                }
                .padding(right: 1, left: 0)
                .width(.percent(100))
            }
            .key("dialog-row-\(dialog.rawValue)-\(row.id)")
            .id("dialog-row-\(rowIndex)")
            .width(.percent(100))
            .height(1)
            .onMouseUp { event in
                event.stopPropagation()
                onSelectRow(rowIndex)
            }
        )
    }

    // MARK: - Subtle Floating Toast

    private static func buildToastBanner(
        message: String,
        isError: Bool,
        theme: ResolvedTheme
    ) -> AnyTUIView {
        let bg = theme.background.raised.high
        let border = isError ? theme.text.feedback.error.base : theme.text.feedback.info.base
        return AnyTUIView(
            TUIBox(
                border: .sides([.left]),
                borderColor: .rgba(border),
                backgroundColor: .rgba(bg),
                shouldFill: true,
                customBorderChars: splitBorderChars
            ) {
                TUIText(
                    TUIUtil.truncateWidth(message, 56),
                    fg: .rgba(isError ? theme.text.feedback.error.base : theme.text.base),
                    bg: .rgba(bg),
                    wrapMode: TextWrapMode.none
                )
                .padding(right: 2, left: 1)
            }
            .position(.absolute, top: 1, right: 2)
            .zIndex(2500)
        )
    }
}
