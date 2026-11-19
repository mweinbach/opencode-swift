#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView

// MARK: - OSC 11 / COLORFGBG Terminal Theme Auto-Detection

/// Probing and parsing utilities for automatic terminal Light/Dark detection via OSC 11 and `COLORFGBG`.
public enum TerminalThemeDetector {
    private final class ProbeHost: RendererThemeModeHost {
        func queryThemeColors() -> Bool { false }
    }

    /// Parses an OSC 11 background color reply (`\x1b]11;rgb:RRRR/GGGG/BBBB\x07`, `\x1b]11;rgb:RRRR/GGGG/BBBB\x1b\\`,
    /// or `\x1b]11;#RRGGBB\x07`) into `.light` or `.dark` using `OpenTUICore.RendererThemeMode` luminance classification.
    public static func parseOSC11Response(_ raw: String) -> ThemeMode? {
        guard !raw.isEmpty else { return nil }
        let host = ProbeHost()
        let state = RendererThemeMode(host: host, clock: ManualClock())
        let result = state.handleSequence(raw)
        return result.changedMode ?? state.themeMode
    }

    /// Parses raw bytes containing an OSC 11 reply into `.light` or `.dark`.
    public static func parseOSC11Response(_ bytes: [UInt8]) -> ThemeMode? {
        guard !bytes.isEmpty else { return nil }
        return parseOSC11Response(String(decoding: bytes, as: UTF8.self))
    }

    /// Extracts an OSC 11 mode from buffered raw bytes while preserving any unrelated non-OSC bytes
    /// (such as early user keystrokes typed during startup).
    public static func extractOSC11(from bytes: [UInt8]) -> (mode: ThemeMode?, remaining: [UInt8]) {
        guard !bytes.isEmpty else { return (nil, []) }
        var remaining: [UInt8] = []
        remaining.reserveCapacity(bytes.count)
        var detected: ThemeMode? = nil

        var i = 0
        while i < bytes.count {
            if i + 4 < bytes.count,
               bytes[i] == 0x1B, // ESC
               bytes[i + 1] == 0x5D, // ']'
               bytes[i + 2] == 0x31, // '1'
               (bytes[i + 3] == 0x30 || bytes[i + 3] == 0x31), // '0' or '1'
               bytes[i + 4] == 0x3B // ';'
            {
                // Find BEL (0x07) or ST (ESC \)
                var end = i + 5
                var foundTermEnd: Int? = nil
                while end < bytes.count {
                    if bytes[end] == 0x07 {
                        foundTermEnd = end + 1
                        break
                    }
                    if end + 1 < bytes.count && bytes[end] == 0x1B && bytes[end + 1] == 0x5C {
                        foundTermEnd = end + 2
                        break
                    }
                    end += 1
                }
                if let termEnd = foundTermEnd {
                    let seq = String(decoding: bytes[i..<termEnd], as: UTF8.self)
                    if let parsed = parseOSC11Response(seq) {
                        detected = parsed
                    }
                    i = termEnd
                    continue
                }
            }
            remaining.append(bytes[i])
            i += 1
        }
        return (detected, remaining)
    }

    /// Infers terminal light/dark mode from the `COLORFGBG` environment variable (e.g., `"0;15"` -> `.light`, `"15;0"` -> `.dark`).
    public static func detectFromEnvironment(_ environment: [String: String]) -> ThemeMode? {
        guard let raw = environment["COLORFGBG"], !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ";")
        guard let last = parts.last, let bgCode = Int(last.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        guard bgCode >= 0 && bgCode <= 255 else { return nil }
        let rgba = TUIThemeBridge.ansiToRgba(bgCode)
        let (r, g, b, _) = rgba.toInts()
        return inferThemeModeFromRGB(r: r, g: g, b: b)
    }

    /// Queries a live terminal (already in raw mode) with OSC 11 (`\x1b]11;?\x07`), polling non-blocking
    /// for up to `timeoutMs` ms before falling back to `COLORFGBG` and finally `.dark`.
    public static func probeLiveTerminal(
        backend: PlatformTerminalBackend,
        environment: [String: String],
        timeoutMs: Int = 120
    ) async -> (mode: ThemeMode, leftoverBytes: [UInt8]) {
        let query = Array("\u{1B}]11;?\u{07}".utf8)
        try? await backend.write(query)

        let deadline = ContinuousClock.now + .milliseconds(max(1, timeoutMs))
        var accumulated: [UInt8] = []

        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let remMs = max(1, Int32(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            let chunk = (try? backend.pollRead(maxBytes: 1024, timeoutMs: min(remMs, 20))) ?? []
            if !chunk.isEmpty {
                accumulated.append(contentsOf: chunk)
                let extracted = extractOSC11(from: accumulated)
                if let mode = extracted.mode {
                    return (mode, extracted.remaining)
                }
            }
        }

        let extracted = extractOSC11(from: accumulated)
        if let mode = extracted.mode {
            return (mode, extracted.remaining)
        }
        if let envMode = detectFromEnvironment(environment) {
            return (envMode, extracted.remaining)
        }
        return (.dark, extracted.remaining)
    }
}

// MARK: - Live Interactive OpenCode TUI Loop

/// Live interactive terminal UI runtime for `swift-opencode`, built directly on `Packages/OpenTUI`
/// (`OpenTUIView` + `OpenTUIRenderables` + `OpenTUITerminal`), `ThemeDefaults`/`ThemeResolver`,
/// and `OpenCodeClient`, matching upstream OpenCode 2.3.2 visually and interactively.
public enum TUIInteractiveLoop {
    public struct TranscriptMessage: Equatable, Sendable {
        public let id: String
        public let role: String
        public let text: String
        public let detail: String?

        public init(id: String, role: String, text: String, detail: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.detail = detail
        }
    }

    public struct SessionSummary: Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private static let doubleEscInterruptWindowMs: Double = 2_000
    private static let leaderTimeoutWindowMs: Double = 1_500
    private static let spinnerFrameIntervalMs: Double = 80

    /// Runs the live interactive terminal UI loop over `PlatformTerminalBackend` with automatic
    /// OSC 11 light/dark theme detection and live SSE `/api/event` streaming.
    public static func runInteractive(
        input: TUIApp.TuiInput,
        resolved: TUIConfig.Resolved,
        initialRoute: TUIContext.Route
    ) async throws -> TUIApp.RunResult {
        let backend = PlatformTerminalBackend(defaultSize: TerminalSize(width: 100, height: 34))
        let initialSize = await backend.size
        let directory = input.environment["OPENCODE_CWD"]
            ?? input.environment["PWD"]
            ?? Global.Path.home
        let homeDirectory = input.environment["HOME"] ?? Global.Path.home

        let themePreference: TUIThemePreference
        switch resolved.theme?.mode {
        case .light: themePreference = .light
        case .dark: themePreference = .dark
        case .system, .none: themePreference = .auto
        }

        let initialDetected = TerminalThemeDetector.detectFromEnvironment(input.environment) ?? .dark
        let initialSessionID: String?
        if case .session(let sr) = initialRoute {
            initialSessionID = sr.sessionID
        } else {
            initialSessionID = nil
        }

        let initialState = TUIInteractiveState(
            route: initialRoute,
            themeName: resolved.theme?.name ?? "opencode",
            themePreference: themePreference,
            detectedMode: initialDetected,
            cols: initialSize.width,
            rows: initialSize.height,
            serverVersion: input.app.version.isEmpty ? "2.3.2" : input.app.version,
            serverURL: input.server.baseUrl,
            directory: directory,
            homeDirectory: homeDirectory,
            activeSessionID: initialSessionID,
            promptText: input.args.prompt ?? ""
        )

        let store = TUIInteractiveStore(initialState)

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: input.server.baseUrl,
            transport: URLSessionHTTPTransport.shared,
            headers: input.server.headers
        ))

        let clock = ManualClock()
        let initialTheme = initialState.resolveTheme()
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: initialSize.width,
                height: initialSize.height,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: resolved.mouse,
                useKittyKeyboard: KittyKeyboardOptions(disambiguate: true, alternateKeys: true),
                backgroundColor: initialTheme.background.base,
                clock: clock
            )
        )

        let dirty = Mutex(true)
        @Sendable func markDirty() { dirty.withLock { $0 = true } }
        let editorRequested = Mutex(false)

        let persistenceStore = TUIPersistenceStore(
            stateDirectory: Global.make(environment: DictionaryEnvironment(variables: input.environment)).state,
            fileSystem: LocalFileSystem.shared
        )
        store.withLock { state in
            state.kittyKeyboardFlags = renderer.activeKittyKeyboardFlags
        }

        let controller = TUIInteractiveClient(
            client: client,
            store: store,
            directory: directory,
            persistence: persistenceStore,
            onRequestExternalEditor: {
                editorRequested.withLock { $0 = true }
                markDirty()
            },
            markDirty: markDirty
        )

        try await runWithTerminalBackend(
            renderer: renderer,
            backend: backend,
            options: TerminalBackendRunOptions(
                enterRawMode: true,
                manageTerminalModes: true,
                initialRender: false,
                destroyOnExit: true,
                enableMouseMovement: resolved.mouse
            )
        ) { liveRenderer, session in
            // 1. Auto-detect Light/Dark terminal background via OSC 11 before first paint (120ms max wait)
            var startupLeftoverBytes: [UInt8] = []
            if themePreference == .auto {
                let probe = await TerminalThemeDetector.probeLiveTerminal(
                    backend: backend,
                    environment: input.environment,
                    timeoutMs: 120
                )
                startupLeftoverBytes = probe.leftoverBytes
                store.withLock { state in
                    state.detectedMode = probe.mode
                }
            }

            // Subscribe to live OS/terminal theme changes (DSR ?997 / late OSC 11 replies)
            _ = liveRenderer.onThemeMode { mode in
                store.withLock { state in
                    state.detectedMode = mode
                }
                markDirty()
            }

            // 2. Sync initial theme background and mount view
            let bootTheme = store.snapshot().resolveTheme()
            liveRenderer.setBackgroundColor(bootTheme.background.base)

            let viewRoot = mountInteractiveView(
                on: liveRenderer,
                store: store,
                clientController: controller,
                markDirty: markDirty
            )
            defer { viewRoot.unmount() }

            // 3. Kick off non-blocking server bootstrap (including startup CLI args) and live SSE `/api/event` subscription
            controller.bootstrap(startupArgs: input.args)
            let sseTask = controller.startEventStream()
            defer { sseTask.cancel() }

            // 4. First crisp paint + initial OSC 2 terminal title
            var lastWindowTitle = ""
            await session.renderNow(force: true)
            dirty.withLock { $0 = false }

            if !startupLeftoverBytes.isEmpty {
                session.feedInput(startupLeftoverBytes)
            }

            // 5. Responsive ~60fps event loop
            var lastSize = initialSize
            var lastLoopInstant = ContinuousClock.now
            var spinnerAccumMs: Double = 0

            while !store.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
                let nowInstant = ContinuousClock.now
                let elapsed = lastLoopInstant.duration(to: nowInstant)
                lastLoopInstant = nowInstant
                let dtMs = max(0.0, Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0)
                if dtMs > 0 {
                    clock.advance(by: dtMs)
                }

                // Handle external `$EDITOR` request cleanly by temporarily leaving raw/alt-screen
                let shouldRunEditor = editorRequested.withLock { flag -> Bool in
                    if !flag { return false }
                    flag = false
                    return true
                }
                if shouldRunEditor {
                    let initialDraft = store.withLock { $0.promptText }
                    let leaveSeq = "\u{1B}[<u\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l"
                    try? await backend.write(Array(leaveSeq.utf8))
                    try? await backend.exitRawMode()
                    let edited = try? TUIExternalEditor.editInExternalEditor(
                        initialText: initialDraft,
                        environment: input.environment,
                        tempDir: Global.make(environment: DictionaryEnvironment(variables: input.environment)).tmp
                    )
                    try? await backend.enterRawMode()
                    let kitty = liveRenderer.activeKittyKeyboardFlags
                    let reenterSeq = "\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[?2004h" + (kitty != 0 ? "\u{1B}[>\(kitty)u" : "")
                    try? await backend.write(Array(reenterSeq.utf8))
                    if let edited {
                        store.withLock { state in
                            state.promptText = edited.trimmingCharacters(in: .newlines)
                            state.slashAutocompleteDismissed = false
                        }
                    }
                    viewRoot.invalidate()
                    await session.renderNow(force: true)
                    dirty.withLock { $0 = false }
                    continue
                }

                // Sync OSC 2 terminal window title (`OpenCode` on Home, `OC | <title>` on Session)
                let desiredTitle: String = store.withLock { state in
                    if state.isHome { return "OpenCode" }
                    let t = state.activeSessionTitle
                    if t.count > 40 { return "OC | \(t.prefix(37))…" }
                    return "OC | \(t)"
                }
                if desiredTitle != lastWindowTitle {
                    lastWindowTitle = desiredTitle
                    let osc2 = "\u{1B}]2;\(desiredTitle)\u{07}"
                    try? await backend.write(Array(osc2.utf8))
                }

                // Check terminal resize
                let currentSize = await backend.size
                if currentSize != lastSize {
                    lastSize = currentSize
                    store.withLock {
                        $0.cols = currentSize.width
                        $0.rows = currentSize.height
                    }
                    _ = await session.syncSize()
                    viewRoot.invalidate()
                    await session.renderNow(force: true)
                    dirty.withLock { $0 = false }
                }

                // Poll terminal input (~60fps cadence)
                let bytes = (try? backend.pollRead(maxBytes: 4096, timeoutMs: 16)) ?? []
                if !bytes.isEmpty {
                    session.feedInput(bytes)
                }

                // Advance live spinner animation & auto-disarm timers
                let clockNow = clock.now()
                let tickDirty = store.withLock { state -> Bool in
                    var changed = false
                    if state.interruptArmed && (clockNow - state.interruptArmedAtMs >= doubleEscInterruptWindowMs) {
                        state.interruptArmed = false
                        changed = true
                    }
                    if state.leaderArmed && (clockNow - state.leaderArmedAtMs >= leaderTimeoutWindowMs) {
                        state.leaderArmed = false
                        changed = true
                    }
                    if state.preferences.animations && (state.sessionStatus.isRunning || state.sseReconnecting) {
                        spinnerAccumMs += dtMs
                        if spinnerAccumMs >= spinnerFrameIntervalMs {
                            spinnerAccumMs = spinnerAccumMs.truncatingRemainder(dividingBy: spinnerFrameIntervalMs)
                            state.spinnerTick &+= 1
                            changed = true
                        }
                    } else {
                        spinnerAccumMs = 0
                    }
                    return changed
                }
                if tickDirty {
                    markDirty()
                }

                let needsRender = dirty.withLock { flag -> Bool in
                    if !flag { return false }
                    flag = false
                    return true
                }
                if needsRender && !store.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
                    let theme = store.snapshot().resolveTheme()
                    liveRenderer.setBackgroundColor(theme.background.base)
                    viewRoot.invalidate()
                    await session.renderNow(force: false)
                } else if bytes.isEmpty {
                    await Task.yield()
                }
            }
        }

        let finalSnap = store.withLock { ($0.route, $0.exitReason) }
        return TUIApp.RunResult(
            resolvedConfig: resolved,
            initialRoute: finalSnap.0,
            updatedVersion: nil,
            exitReason: finalSnap.1 ?? "user_exit"
        )
    }

    /// Renders a headless OpenTUI text snapshot of either the Home or Session view for testing and non-TTY previews.
    public static func renderPreviewFrame(
        width: Int = 100,
        height: Int = 34,
        route: TUIContext.Route = .home(TUIContext.HomeRoute()),
        mode: ThemeMode = .dark,
        serverURL: String = "http://127.0.0.1:4096",
        directory: String = "/workspace",
        state overrideState: TUIInteractiveState? = nil
    ) -> String {
        let initial = overrideState ?? makeDefaultPreviewState(
            width: width,
            height: height,
            route: route,
            mode: mode,
            serverURL: serverURL,
            directory: directory
        )
        let theme = initial.resolveTheme()
        let test = createTestRenderer(width: width, height: height, backgroundColor: theme.background.base)
        defer { test.destroy() }
        let store = TUIInteractiveStore(initial)
        let client = OpenCodeClient(options: ClientOptions(baseUrl: serverURL, transport: MockHTTPTransport()))
        let controller = TUIInteractiveClient(client: client, store: store, directory: directory, markDirty: {})
        let root = mountInteractiveView(
            on: test.renderer,
            store: store,
            clientController: controller,
            markDirty: {}
        )
        test.renderOnce(force: true)
        let frame = test.captureCharFrame()
        root.unmount()
        return frame
    }

    public static func makeDefaultPreviewState(
        width: Int = 100,
        height: Int = 34,
        route: TUIContext.Route = .home(TUIContext.HomeRoute()),
        mode: ThemeMode = .dark,
        serverURL: String = "http://127.0.0.1:4096",
        directory: String = "/Users/dev/.t3/projects/swift-opencode",
        homeDirectory: String = "/Users/dev"
    ) -> TUIInteractiveState {
        let claude = TUIModelItem(
            id: "claude-sonnet-4-5",
            providerID: "anthropic",
            name: "Claude Sonnet 4.5",
            providerName: "Anthropic",
            variants: ["high", "xhigh"],
            contextLimit: 200_000
        )
        let gpt = TUIModelItem(
            id: "gpt-5.3-codex",
            providerID: "openai",
            name: "GPT-5.3 Codex",
            providerName: "OpenAI",
            variants: ["medium", "high"],
            contextLimit: 256_000
        )
        return TUIInteractiveState(
            route: route,
            themeName: "opencode",
            themePreference: mode == .light ? .light : .dark,
            detectedMode: mode,
            cols: width,
            rows: height,
            serverVersion: "2.3.2",
            serverURL: serverURL,
            directory: directory,
            homeDirectory: homeDirectory,
            gitBranch: "main",
            agents: TUIAgentItem.defaultFallback,
            selectedAgentIndex: 0,
            providers: ["anthropic": "Anthropic", "openai": "OpenAI"],
            models: [claude, gpt],
            selectedModel: claude,
            integrations: [
                TUIIntegrationItem(
                    id: "opencode",
                    name: "OpenCode",
                    methods: [.key(label: "API key"), .env(names: ["OPENCODE_API_KEY"])]
                ),
                TUIIntegrationItem(
                    id: "openai",
                    name: "OpenAI",
                    methods: [.key(label: "API key"), .env(names: ["OPENAI_API_KEY"])],
                    connections: [.env(name: "OPENAI_API_KEY", statusMessage: nil)]
                ),
                TUIIntegrationItem(
                    id: "anthropic",
                    name: "Anthropic",
                    methods: [.key(label: "API key"), .env(names: ["ANTHROPIC_API_KEY"])],
                    connections: [.env(name: "ANTHROPIC_API_KEY", statusMessage: nil)]
                ),
                TUIIntegrationItem(
                    id: "google",
                    name: "Google",
                    methods: [.key(label: "API key"), .env(names: ["GEMINI_API_KEY"])]
                ),
                TUIIntegrationItem(
                    id: "openrouter",
                    name: "OpenRouter",
                    methods: [.key(label: "API key"), .env(names: ["OPENROUTER_API_KEY"])]
                ),
            ],
            mcpServers: [
                TUIMCPServerItem(name: "github", status: .connected),
                TUIMCPServerItem(name: "linear", status: .connected),
                TUIMCPServerItem(name: "postgres", status: .connected),
            ],
            sessions: [
                TUISessionItem(id: "ses_demo01", title: "Port OpenCode to Swift 6.2", directory: directory),
                TUISessionItem(id: "ses_demo02", title: "Verify OpenTUI 100% Parity", directory: directory),
            ],
            activeSessionID: "ses_demo01",
            activeSessionTitle: "Port OpenCode to Swift 6.2",
            contextTokens: 12_400,
            contextLimit: 200_000,
            sessionCost: 0.04,
            modifiedFiles: [
                TUIModifiedFileItem(path: "Sources/OpenCodeTUI/App/TUIInteractiveLoop.swift", additions: 142, deletions: 48, status: "modified"),
            ],
            messages: [
                .user(id: "msg_1", text: "Check parity status across all Swift targets.", agentName: "Build", isOptimistic: false),
                .assistant(
                    id: "msg_2",
                    agentName: "Build",
                    modelLabel: "Claude Sonnet 4.5",
                    parts: [
                        .reasoning(id: "r_1", text: "Inspecting the parity manifest and test targets.", completed: true),
                        .tool(id: "t_1", name: "read", status: .completed, summary: "parity/report.json", outputPreview: "9404/9404 symbols implemented", error: nil),
                        .text(id: "p_1", text: "All **15 OpenCode packages** (9,404 symbols) and **5 OpenTUI packages** are at **100.0% parity**."),
                    ],
                    completed: true,
                    error: nil
                ),
            ]
        )
    }

    // MARK: - View Composition & Keyboard Routing

    /// Mounts the complete upstream-parity interactive TUI view tree and keyboard router onto `renderer`.
    public static func mountInteractiveView(
        on renderer: CliRenderer,
        store: TUIInteractiveStore,
        clientController: TUIInteractiveClient,
        markDirty: @escaping @Sendable () -> Void
    ) -> TUIViewRoot {
        let viewRoot = TUIViewRoot(renderer: renderer)
        viewRoot.autoRenderOnInvalidate = false

        let actions = TUIScreenActions(
            onPromptInput: { value in
                var mentionQueryToRun: String? = nil
                store.withLock { state in
                    if !state.shellMode && TUIShellMode.isShellTrigger(value) {
                        state.shellMode = true
                        state.promptText = ""
                        state.slashAutocompleteDismissed = false
                        state.mentionAutocompleteDismissed = false
                        return
                    }
                    state.promptText = value
                    state.slashAutocompleteDismissed = false
                    state.slashAutocompleteIndex = 0
                    state.mentionAutocompleteDismissed = false
                    state.mentionAutocompleteIndex = 0
                    state.historyNavigator.reset()
                    if let trigger = state.activeMentionTrigger {
                        mentionQueryToRun = trigger.query
                    }
                }
                if let query = mentionQueryToRun {
                    clientController.queryFilesForMention(query)
                }
                markDirty()
            },
            onPromptSubmit: { value in
                clientController.submitPrompt(rawText: value)
            },
            onDialogFilterInput: { value in
                store.withLock { state in
                    state.dialogFilter = value
                    state.dialogSelectedIndex = 0
                    state.connectErrorMessage = nil
                    state.pendingDeleteCredentialID = nil
                    state.pendingDeleteSessionID = nil
                }
                clientController.previewThemeRowIfNeeded()
                markDirty()
            },
            onDialogSubmit: {
                clientController.confirmSelectedDialogRow()
            },
            onDialogClose: {
                clientController.navigateBackFromSubDialog()
            },
            onOpenMCPDialog: {
                clientController.openDialog(.mcpStatus)
            },
            onPermissionRejectInput: { value in
                store.withLock { state in
                    state.permissionPromptState.rejectFeedback = value
                }
                markDirty()
            },
            onPermissionRejectSubmit: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                clientController.replyActivePermission(decision: .reject, message: trimmed.isEmpty ? nil : trimmed)
            },
            onFormTextInput: { value in
                store.withLock { state in
                    state.formPromptState.customText = value
                    state.formPromptState.errorMessage = nil
                }
                markDirty()
            },
            onFormTextSubmit: { _ in
                let readyToSubmit = store.withLock { state -> Bool in
                    guard let form = state.activeForm else { return false }
                    return state.formPromptState.toggleOrSelectCurrent(form: form)
                }
                markDirty()
                if readyToSubmit {
                    clientController.submitActiveForm()
                }
            },
            onRenameInput: { value in
                store.withLock { state in
                    state.renameDraft = value
                }
                markDirty()
            },
            onRenameSubmit: { value in
                clientController.submitRenameSession(value)
            }
        )

        _ = renderer.keyInput.onKeypress { [weak renderer] event in
            let snap = store.snapshot()
            let keyName = event.name.lowercased()
            let isSuper = (event.`super` == true)
            let isCtrlOrSuper = event.ctrl || isSuper

            // Ctrl+D: contextual delete in dialogs, half-page down in diff viewer, otherwise exit cleanly
            if event.ctrl && keyName == "d" {
                switch snap.activeDialog {
                case .manageConnections:
                    clientController.requestRemoveSelectedCredential()
                    event.preventDefault()
                    return
                case .sessionList:
                    clientController.requestDeleteSelectedSession()
                    event.preventDefault()
                    return
                case .stashList:
                    clientController.deleteSelectedStashEntry()
                    event.preventDefault()
                    return
                case .diffViewer:
                    if let scrollBox = renderer?.root.findDescendantById("diff-viewer-scrollbox") as? ScrollBoxRenderable {
                        scrollBox.scrollBy(Double(max(4, (snap.rows - 8) / 2)))
                        markDirty()
                    }
                    event.preventDefault()
                    return
                default:
                    break
                }
                store.withLock {
                    $0.shouldQuit = true
                    $0.exitReason = "ctrl_d"
                }
                event.preventDefault()
                markDirty()
                return
            }

            // Ctrl+C: close/clear dialog filter, clear non-empty prompt / shell mode, or quit
            if event.ctrl && keyName == "c" {
                if snap.leaderArmed {
                    store.withLock { $0.leaderArmed = false }
                    event.preventDefault()
                    markDirty()
                    return
                }
                if snap.activeDialog != nil {
                    if !snap.dialogFilter.isEmpty {
                        store.withLock {
                            $0.dialogFilter = ""
                            $0.dialogSelectedIndex = 0
                        }
                        markDirty()
                    } else {
                        clientController.closeDialog(commitTheme: false)
                    }
                    event.preventDefault()
                    return
                }
                if snap.shellMode {
                    store.withLock {
                        $0.shellMode = false
                        $0.promptText = ""
                    }
                    event.preventDefault()
                    markDirty()
                    return
                }
                if !snap.promptText.isEmpty {
                    store.withLock {
                        $0.promptText = ""
                        $0.slashAutocompleteDismissed = false
                        $0.mentionAutocompleteDismissed = false
                    }
                    event.preventDefault()
                    markDirty()
                    return
                }
                store.withLock {
                    $0.shouldQuit = true
                    $0.exitReason = "ctrl_c"
                }
                event.preventDefault()
                markDirty()
                return
            }

            // Ctrl+P / Cmd+P / Cmd+K toggles Command Palette
            if (isCtrlOrSuper && keyName == "p") || (isSuper && keyName == "k") {
                if snap.activeDialog == .commandPalette {
                    clientController.closeDialog(commitTheme: false)
                } else {
                    clientController.openDialog(.commandPalette)
                }
                event.preventDefault()
                return
            }

            // Modal Dialog & Overlay Keyboard Handling
            if let activeDialog = snap.activeDialog {
                // Full Diff Viewer Keyboard Navigation
                if activeDialog == .diffViewer {
                    let scrollBox = renderer?.root.findDescendantById("diff-viewer-scrollbox") as? ScrollBoxRenderable
                    let halfPage = Double(max(4, (snap.rows - 8) / 2))
                    if event.ctrl && keyName == "u" {
                        scrollBox?.scrollBy(-halfPage)
                        event.preventDefault()
                        markDirty()
                        return
                    }
                    switch keyName {
                    case "escape", "q":
                        clientController.closeDialog(commitTheme: true)
                    case "n":
                        store.withLock { state in
                            let count = state.diffViewerState.files.count
                            if count > 0 {
                                state.diffViewerState.selectedFileIndex = (state.diffViewerState.selectedFileIndex + 1) % count
                            }
                        }
                        markDirty()
                    case "p":
                        store.withLock { state in
                            let count = state.diffViewerState.files.count
                            if count > 0 {
                                state.diffViewerState.selectedFileIndex = (state.diffViewerState.selectedFileIndex - 1 + count) % count
                            }
                        }
                        markDirty()
                    case "v":
                        store.withLock { $0.diffViewerState.splitView.toggle() }
                        markDirty()
                    case "b":
                        store.withLock { $0.diffViewerState.showFileTree.toggle() }
                        markDirty()
                    case "f":
                        store.withLock { $0.diffViewerState.fullscreen.toggle() }
                        markDirty()
                    case "j", "down":
                        scrollBox?.scrollBy(3)
                        markDirty()
                    case "k", "up":
                        scrollBox?.scrollBy(-3)
                        markDirty()
                    case "pagedown":
                        scrollBox?.scrollBy(halfPage * 2)
                        markDirty()
                    case "pageup":
                        scrollBox?.scrollBy(-halfPage * 2)
                        markDirty()
                    default:
                        break
                    }
                    event.preventDefault()
                    return
                }

                // Read-Only Info Overlays (Pair, Status, Usage, Help, Debug)
                if activeDialog == .pair || activeDialog == .status || activeDialog == .usage || activeDialog == .help || activeDialog == .debug {
                    switch keyName {
                    case "escape", "q", "return", "enter":
                        clientController.closeDialog(commitTheme: true)
                        event.preventDefault()
                        return
                    case "c":
                        if activeDialog == .debug {
                            clientController.copyDebugSnapshot()
                            event.preventDefault()
                            return
                        }
                    case "up":
                        if activeDialog == .usage {
                            store.withLock { state in
                                let count = max(1, state.usageLimits.count)
                                state.dialogSelectedIndex = (state.dialogSelectedIndex - 1 + count) % count
                            }
                            markDirty()
                            event.preventDefault()
                            return
                        }
                    case "down":
                        if activeDialog == .usage {
                            store.withLock { state in
                                let count = max(1, state.usageLimits.count)
                                state.dialogSelectedIndex = (state.dialogSelectedIndex + 1) % count
                            }
                            markDirty()
                            event.preventDefault()
                            return
                        }
                    default:
                        break
                    }
                    event.preventDefault()
                    return
                }

                // Inside Model Picker: Ctrl+A / Cmd+A opens Connect Provider; Ctrl+F / Cmd+F toggles Favorite
                if activeDialog == .modelPicker {
                    if isCtrlOrSuper && keyName == "a" {
                        clientController.openConnectProvider()
                        event.preventDefault()
                        return
                    }
                    if isCtrlOrSuper && keyName == "f" {
                        clientController.toggleFavoriteSelectedModel()
                        event.preventDefault()
                        return
                    }
                }

                // Inside Session List: Ctrl+R renames selected session; Ctrl+F pins/unpins selected session
                if activeDialog == .sessionList {
                    if isCtrlOrSuper && keyName == "r" {
                        let rows = snap.dialogRows()
                        if !rows.isEmpty {
                            let idx = min(max(0, snap.dialogSelectedIndex), rows.count - 1)
                            clientController.openRenameSessionDialog(sessionID: rows[idx].id, currentTitle: rows[idx].title)
                        }
                        event.preventDefault()
                        return
                    }
                    if isCtrlOrSuper && keyName == "f" {
                        clientController.togglePinSelectedSession()
                        event.preventDefault()
                        return
                    }
                }

                // Inside Timeline: Ctrl+F forks session at selected user message
                if activeDialog == .timeline && isCtrlOrSuper && keyName == "f" {
                    let rows = snap.dialogRows()
                    if !rows.isEmpty {
                        let idx = min(max(0, snap.dialogSelectedIndex), rows.count - 1)
                        let msgID = rows[idx].id
                        clientController.closeDialog(commitTheme: true)
                        clientController.forkActiveSession(beforeMessageID: msgID)
                    }
                    event.preventDefault()
                    return
                }

                // Inside Settings: Left/Right arrows cycle the selected setting immediately
                if activeDialog == .settings {
                    if keyName == "left" {
                        clientController.cycleSelectedSetting(direction: -1)
                        event.preventDefault()
                        return
                    }
                    if keyName == "right" {
                        clientController.cycleSelectedSetting(direction: 1)
                        event.preventDefault()
                        return
                    }
                }

                // Input prompt dialogs (API Key / OAuth Code / Rename Session): let editing & paste pass through
                if activeDialog.isInputPrompt {
                    switch keyName {
                    case "escape":
                        clientController.navigateBackFromSubDialog()
                        event.preventDefault()
                        return
                    case "return", "enter":
                        clientController.confirmSelectedDialogRow()
                        event.preventDefault()
                        return
                    default:
                        return
                    }
                }

                switch keyName {
                case "escape":
                    clientController.navigateBackFromSubDialog()
                    event.preventDefault()
                    return

                case "up":
                    moveDialogSelection(by: -1, store: store, controller: clientController, markDirty: markDirty)
                    event.preventDefault()
                    return

                case "down":
                    moveDialogSelection(by: 1, store: store, controller: clientController, markDirty: markDirty)
                    event.preventDefault()
                    return

                case "pageup":
                    moveDialogSelection(by: -5, store: store, controller: clientController, markDirty: markDirty)
                    event.preventDefault()
                    return

                case "pagedown":
                    moveDialogSelection(by: 5, store: store, controller: clientController, markDirty: markDirty)
                    event.preventDefault()
                    return

                case "return", "enter":
                    clientController.confirmSelectedDialogRow()
                    event.preventDefault()
                    return

                default:
                    // Let focused filter TUIInput receive printable typing & editing keys
                    return
                }
            }

            // Inline Permission Prompt Keyboard Handling (`routes/session/permission.tsx`)
            if snap.activePermission != nil {
                if snap.permissionPromptState.isRejectingWithFeedback {
                    switch keyName {
                    case "escape":
                        store.withLock { state in
                            state.permissionPromptState.isRejectingWithFeedback = false
                            state.permissionPromptState.rejectFeedback = ""
                        }
                        markDirty()
                        event.preventDefault()
                        return
                    case "return", "enter":
                        clientController.confirmSelectedPermissionOption()
                        event.preventDefault()
                        return
                    default:
                        return
                    }
                } else {
                    switch keyName {
                    case "left":
                        store.withLock { $0.permissionPromptState.selectPrevious() }
                        markDirty()
                    case "right", "tab":
                        store.withLock { $0.permissionPromptState.selectNext() }
                        markDirty()
                    case "return", "enter":
                        clientController.confirmSelectedPermissionOption()
                    case "y", "1":
                        clientController.replyActivePermission(decision: .once)
                    case "a", "2":
                        clientController.replyActivePermission(decision: .always)
                    case "r", "n", "3":
                        store.withLock { state in
                            state.permissionPromptState.selectedOption = .reject
                            state.permissionPromptState.isRejectingWithFeedback = true
                            state.permissionPromptState.rejectFeedback = ""
                        }
                        markDirty()
                    case "escape":
                        clientController.replyActivePermission(decision: .reject)
                    default:
                        break
                    }
                    event.preventDefault()
                    return
                }
            }

            // Inline Form / Question Prompt Keyboard Handling (`routes/session/form.tsx`)
            if let activeForm = snap.activeForm {
                if snap.formPromptState.editingCustom {
                    switch keyName {
                    case "escape":
                        store.withLock { state in
                            state.formPromptState.editingCustom = false
                        }
                        markDirty()
                        event.preventDefault()
                        return
                    case "return", "enter":
                        let ready = store.withLock { state in
                            state.formPromptState.toggleOrSelectCurrent(form: activeForm)
                        }
                        markDirty()
                        if ready {
                            clientController.submitActiveForm()
                        }
                        event.preventDefault()
                        return
                    default:
                        return
                    }
                } else {
                    switch keyName {
                    case "up":
                        store.withLock { $0.formPromptState.moveRow(by: -1, form: activeForm) }
                        markDirty()
                    case "down":
                        store.withLock { $0.formPromptState.moveRow(by: 1, form: activeForm) }
                        markDirty()
                    case "left":
                        store.withLock { $0.formPromptState.prevField(form: activeForm) }
                        markDirty()
                    case "right", "tab":
                        store.withLock { $0.formPromptState.nextField(form: activeForm) }
                        markDirty()
                    case "space", "return", "enter":
                        let ready = store.withLock { state in
                            state.formPromptState.toggleOrSelectCurrent(form: activeForm)
                        }
                        markDirty()
                        if ready {
                            clientController.submitActiveForm()
                        }
                    case "escape":
                        clientController.cancelActiveForm()
                    default:
                        break
                    }
                    event.preventDefault()
                    return
                }
            }

            // Leader Chord Handling (`Ctrl+X` followed by action key)
            if snap.leaderArmed {
                store.withLock { $0.leaderArmed = false }
                switch keyName {
                case "m":
                    clientController.openModelPicker(providerID: nil)
                case "a":
                    clientController.openAgentPicker()
                case "p", "k":
                    clientController.openConnectProvider()
                case "l":
                    clientController.openDialog(.sessionList)
                    Task { await clientController.refreshSessions() }
                case "n":
                    clientController.startNewSession()
                case "b":
                    clientController.toggleSidebar()
                case "c":
                    clientController.compactActiveSession()
                case "t":
                    clientController.openDialog(.themePicker)
                case "v":
                    clientController.openVariantPicker()
                case "g":
                    clientController.openTimelineDialog()
                case "u":
                    clientController.undoLastUserMessage()
                case "r":
                    clientController.redoRevertedMessage()
                case "d":
                    clientController.openDiffViewer()
                case "s":
                    clientController.openStatusDialog()
                case "e":
                    clientController.requestExternalEditor()
                case "w":
                    clientController.closeCurrentSessionTab()
                case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    if let n = Int(keyName) {
                        clientController.selectSessionTab(index: n - 1)
                    }
                case "q":
                    store.withLock {
                        $0.shouldQuit = true
                        $0.exitReason = "leader_quit"
                    }
                    markDirty()
                default:
                    markDirty()
                }
                event.preventDefault()
                return
            }

            // Arm `<leader>` (`Ctrl+X`)
            if event.ctrl && !event.shift && keyName == "x" {
                let nowMs = renderer?.clock.now() ?? 0
                store.withLock { state in
                    state.leaderArmed = true
                    state.leaderArmedAtMs = nowMs
                }
                event.preventDefault()
                markDirty()
                return
            }

            // Shell mode exit via Backspace / Escape on empty prompt
            if snap.shellMode && snap.promptText.isEmpty && (keyName == "backspace" || keyName == "escape") {
                store.withLock { $0.shellMode = false }
                event.preventDefault()
                markDirty()
                return
            }

            // Session tab cycling (`Ctrl+Tab`, `Ctrl+Shift+Tab`, `Alt+Down`, `Alt+Up`, `Ctrl+Shift+T`)
            if (event.ctrl && keyName == "tab") || (event.meta && (keyName == "down" || keyName == "up")) {
                let dir = (event.shift || keyName == "up") ? -1 : 1
                clientController.cycleSessionTab(direction: dir)
                event.preventDefault()
                return
            }
            if event.ctrl && event.shift && keyName == "t" {
                clientController.reopenClosedSessionTab()
                event.preventDefault()
                return
            }

            // Ctrl+R renames active session (upstream `session.rename`)
            if event.ctrl && keyName == "r" && snap.activeSessionID != nil {
                clientController.openRenameSessionDialog()
                event.preventDefault()
                return
            }

            // Cmd+M opens Model Picker directly
            if isSuper && keyName == "m" {
                clientController.openModelPicker(providerID: nil)
                event.preventDefault()
                return
            }

            // Cmd+A when prompt is empty opens Agent Picker (when prompt has text, let TUIInput select all)
            if isSuper && keyName == "a" && snap.promptText.isEmpty {
                clientController.openAgentPicker()
                event.preventDefault()
                return
            }

            // Ctrl+O / Cmd+O opens Session List (upstream `open.menu`)
            if isCtrlOrSuper && keyName == "o" {
                clientController.openDialog(.sessionList)
                Task { await clientController.refreshSessions() }
                event.preventDefault()
                return
            }

            // F2 / Shift+F2 cycles recent models (upstream `model.cycle_recent`)
            if keyName == "f2" {
                clientController.cycleRecentModel(direction: event.shift ? -1 : 1)
                event.preventDefault()
                return
            }

            // Ctrl+T toggles Light / Dark theme mode
            if event.ctrl && !event.shift && keyName == "t" {
                clientController.toggleThemeMode()
                if let r = renderer {
                    r.setBackgroundColor(store.snapshot().resolveTheme().background.base)
                }
                event.preventDefault()
                return
            }

            // Ctrl+B toggles right Session Sidebar
            if event.ctrl && keyName == "b" {
                clientController.toggleSidebar()
                event.preventDefault()
                return
            }

            // Ctrl+N / Cmd+N starts a new session
            if isCtrlOrSuper && keyName == "n" {
                clientController.startNewSession()
                event.preventDefault()
                return
            }

            // Shift+Tab cycles active agent (`Build` <-> `Plan` <-> server agents)
            if keyName == "tab" && event.shift {
                clientController.cycleAgent(direction: 1)
                event.preventDefault()
                return
            }

            // Live `/` Slash Command Autocomplete Navigation
            if snap.isSlashAutocompleteVisible {
                let matches = snap.slashMatches
                switch event.name {
                case "up":
                    store.withLock { state in
                        let count = max(1, matches.count)
                        state.slashAutocompleteIndex = (state.slashAutocompleteIndex - 1 + count) % count
                    }
                    event.preventDefault()
                    markDirty()
                    return

                case "down":
                    store.withLock { state in
                        let count = max(1, matches.count)
                        state.slashAutocompleteIndex = (state.slashAutocompleteIndex + 1) % count
                    }
                    event.preventDefault()
                    markDirty()
                    return

                case "tab":
                    let idx = min(max(0, snap.slashAutocompleteIndex), matches.count - 1)
                    let chosen = matches[idx]
                    store.withLock { state in
                        state.promptText = chosen.name
                        state.slashAutocompleteIndex = 0
                    }
                    event.preventDefault()
                    markDirty()
                    return

                case "escape":
                    store.withLock { state in
                        state.slashAutocompleteDismissed = true
                    }
                    event.preventDefault()
                    markDirty()
                    return

                case "return", "enter":
                    let idx = min(max(0, snap.slashAutocompleteIndex), matches.count - 1)
                    let chosen = matches[idx]
                    event.preventDefault()
                    clientController.submitPrompt(rawText: chosen.name)
                    return

                default:
                    break
                }
            }

            // Live `@` File & Agent Mention Autocomplete Navigation
            if snap.isMentionAutocompleteVisible, let trigger = snap.activeMentionTrigger {
                let matches = snap.mentionSuggestions
                switch keyName {
                case "up":
                    store.withLock { state in
                        let count = max(1, matches.count)
                        state.mentionAutocompleteIndex = (state.mentionAutocompleteIndex - 1 + count) % count
                    }
                    event.preventDefault()
                    markDirty()
                    return
                case "down":
                    store.withLock { state in
                        let count = max(1, matches.count)
                        state.mentionAutocompleteIndex = (state.mentionAutocompleteIndex + 1) % count
                    }
                    event.preventDefault()
                    markDirty()
                    return
                case "tab", "return", "enter":
                    let idx = min(max(0, snap.mentionAutocompleteIndex), matches.count - 1)
                    let chosen = matches[idx]
                    store.withLock { state in
                        state.promptText = applyMention(chosen, to: state.promptText, trigger: trigger)
                        state.mentionAutocompleteIndex = 0
                    }
                    event.preventDefault()
                    markDirty()
                    return
                case "escape":
                    store.withLock { $0.mentionAutocompleteDismissed = true }
                    event.preventDefault()
                    markDirty()
                    return
                default:
                    break
                }
            }

            // Prompt History Navigation (`↑` / `↓` on Home, or when history cursor is active)
            if (snap.isHome || snap.historyNavigator.cursor != nil) && !snap.historyNavigator.entries.isEmpty {
                if keyName == "up" {
                    let updated = store.withLock { state -> Bool in
                        guard let nextText = state.historyNavigator.navigateUp(currentInput: state.promptText) else {
                            return false
                        }
                        state.promptText = nextText
                        state.slashAutocompleteDismissed = true
                        state.mentionAutocompleteDismissed = true
                        return true
                    }
                    if updated {
                        event.preventDefault()
                        markDirty()
                        return
                    }
                }
                if keyName == "down" && snap.historyNavigator.cursor != nil {
                    let updated = store.withLock { state -> Bool in
                        guard let nextText = state.historyNavigator.navigateDown() else {
                            return false
                        }
                        state.promptText = nextText
                        return true
                    }
                    if updated {
                        event.preventDefault()
                        markDirty()
                        return
                    }
                }
            }

            // Smooth Session Transcript Scrolling (PageUp / PageDown / Up & Down when prompt empty)
            if !snap.isHome, let scrollBox = renderer?.root.findDescendantById("session-scrollbox") as? ScrollBoxRenderable {
                let pageStep = Double(max(4, snap.rows - 10))
                if event.name == "pageup" {
                    scrollBox.scrollBy(-pageStep)
                    event.preventDefault()
                    markDirty()
                    return
                }
                if event.name == "pagedown" {
                    scrollBox.scrollBy(pageStep)
                    event.preventDefault()
                    markDirty()
                    return
                }
                if snap.promptText.isEmpty && event.name == "up" {
                    scrollBox.scrollBy(-3)
                    event.preventDefault()
                    markDirty()
                    return
                }
                if snap.promptText.isEmpty && event.name == "down" {
                    scrollBox.scrollBy(3)
                    event.preventDefault()
                    markDirty()
                    return
                }
            }

            // Escape on Session: double-Esc interrupts running execution, or returns Home when idle
            if event.name == "escape" {
                if !snap.isHome {
                    if snap.sessionStatus.isRunning {
                        let nowMs = renderer?.clock.now() ?? 0
                        if snap.interruptArmed && (nowMs - snap.interruptArmedAtMs < doubleEscInterruptWindowMs) {
                            clientController.interruptActiveSession()
                        } else {
                            store.withLock { state in
                                state.interruptArmed = true
                                state.interruptArmedAtMs = nowMs
                            }
                            markDirty()
                        }
                        event.preventDefault()
                        return
                    }
                    store.withLock { state in
                        state.route = .home(TUIContext.HomeRoute())
                    }
                    event.preventDefault()
                    markDirty()
                    return
                }
            }
        }

        viewRoot.render { [weak renderer] in
            let snap = store.snapshot()
            let resolvedTheme = snap.resolveTheme()
            renderer?.setBackgroundColor(resolvedTheme.background.base)
            return TUIScreens.buildRootView(state: snap, actions: actions)
        }

        return viewRoot
    }

    private static func moveDialogSelection(
        by delta: Int,
        store: TUIInteractiveStore,
        controller: TUIInteractiveClient,
        markDirty: @escaping @Sendable () -> Void
    ) {
        store.withLock { state in
            state.pendingDeleteCredentialID = nil
            let count = state.dialogRows().count
            guard count > 0 else {
                state.dialogSelectedIndex = 0
                return
            }
            if abs(delta) == 1 {
                state.dialogSelectedIndex = ((state.dialogSelectedIndex + delta) % count + count) % count
            } else {
                state.dialogSelectedIndex = min(max(0, state.dialogSelectedIndex + delta), count - 1)
            }
        }
        controller.previewThemeRowIfNeeded()
        markDirty()
    }
}
