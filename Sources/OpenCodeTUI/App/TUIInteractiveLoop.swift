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

/// Live interactive terminal UI runtime for `swift-opencode`, built directly on `Packages/OpenTUI`
/// (`OpenTUIView` + `OpenTUIRenderables` + `OpenTUITerminal`), `ThemeDefaults`/`ThemeResolver`,
/// and `OpenCodeClient`.
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

    private struct UIState: Sendable {
        var route: TUIContext.Route
        var mode: ThemeMode
        var showSidebar: Bool = true
        var showPalette: Bool = false
        var paletteIndex: Int = 0
        var sessionSelectIndex: Int = 0
        var focusOnSessions: Bool = false
        var promptText: String = ""
        var serverVersion: String = "connecting…"
        var serverURL: String
        var directory: String
        var statusLine: String = "Connected — type a prompt and press Enter, or Ctrl+P for commands"
        var sessions: [SessionSummary] = []
        var activeSessionID: String? = nil
        var activeSessionTitle: String = "New Session"
        var messages: [TranscriptMessage] = []
        var cols: Int = 100
        var rows: Int = 30
        var shouldQuit: Bool = false
        var exitReason: String? = nil

        var isHome: Bool {
            if case .home = route { return true }
            return false
        }
    }

    private final class Store: Sendable {
        private let state: Mutex<UIState>
        init(_ initial: UIState) { self.state = Mutex(initial) }
        func withLock<R>(_ body: (inout UIState) -> sending R) -> sending R { state.withLock(body) }
    }

    private static let paletteOptions: [SelectOption] = [
        SelectOption(name: "New Session", description: "Start a fresh conversation (/new)"),
        SelectOption(name: "Go to Home", description: "Return to the home dashboard (/home)"),
        SelectOption(name: "Toggle Sidebar", description: "Show or hide session metadata sidebar (Ctrl+B)"),
        SelectOption(name: "Toggle Theme (Dark / Light)", description: "Switch OpenCode semantic theme mode (Ctrl+T)"),
        SelectOption(name: "Refresh Sessions", description: "Reload sessions & messages from server"),
        SelectOption(name: "Quit OpenCode", description: "Exit the terminal UI cleanly (Ctrl+C)"),
    ]

    /// Runs the live interactive terminal UI loop over `PlatformTerminalBackend`.
    public static func runInteractive(
        input: TUIApp.TuiInput,
        resolved: TUIConfig.Resolved,
        initialRoute: TUIContext.Route
    ) async throws -> TUIApp.RunResult {
        let backend = PlatformTerminalBackend(defaultSize: TerminalSize(width: 100, height: 30))
        let initialSize = await backend.size
        let directory = input.environment["OPENCODE_CWD"]
            ?? input.environment["PWD"]
            ?? Global.Path.home

        let initialMode: ThemeMode = (resolved.theme?.mode == .light) ? .light : .dark
        let initialSessionID: String?
        if case .session(let sr) = initialRoute {
            initialSessionID = sr.sessionID
        } else {
            initialSessionID = nil
        }

        let store = Store(UIState(
            route: initialRoute,
            mode: initialMode,
            promptText: input.args.prompt ?? "",
            serverURL: input.server.baseUrl,
            directory: directory,
            activeSessionID: initialSessionID,
            cols: initialSize.width,
            rows: initialSize.height
        ))

        let client = OpenCodeClient(options: ClientOptions(
            baseUrl: input.server.baseUrl,
            transport: URLSessionHTTPTransport.shared,
            headers: input.server.headers
        ))

        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: initialSize.width,
                height: initialSize.height,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: resolved.mouse,
                clock: ManualClock()
            )
        )

        let dirty = Mutex(true)
        @Sendable func markDirty() { dirty.withLock { $0 = true } }

        // Background initial server bootstrap (non-blocking — TUI renders immediately!)
        let refreshSessions: @Sendable () -> Void = {
            Task {
                if let info = try? await client.server.info() {
                    store.withLock {
                        $0.serverVersion = info.version
                    }
                    markDirty()
                }
                if let list = try? await client.session.list(SessionListInput(limit: 20)) {
                    let summaries = list.data.map { s in
                        SessionSummary(
                            id: s.id.rawValue,
                            title: SessionTitleFallback.displayLabel(title: s.title, parentID: s.parentID?.rawValue)
                        )
                    }
                    store.withLock {
                        $0.sessions = summaries
                        if let activeID = $0.activeSessionID,
                           let matched = summaries.first(where: { $0.id == activeID }) {
                            $0.activeSessionTitle = matched.title
                        }
                    }
                    markDirty()
                }
                if let activeID = store.withLock({ $0.activeSessionID }) {
                    await loadMessages(sessionID: activeID, client: client, store: store, markDirty: markDirty)
                }
            }
        }
        refreshSessions()

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
            let viewRoot = mountInteractiveView(
                on: liveRenderer,
                store: store,
                client: client,
                directory: directory,
                refreshSessions: refreshSessions,
                markDirty: markDirty
            )
            defer { viewRoot.unmount() }

            await session.renderNow(force: true)

            var lastSize = initialSize
            while !store.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
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

                let bytes = (try? backend.pollRead(maxBytes: 4096, timeoutMs: 16)) ?? []
                if !bytes.isEmpty {
                    session.feedInput(bytes)
                }

                let needsRender = dirty.withLock { flag -> Bool in
                    if !flag { return false }
                    flag = false
                    return true
                }
                if needsRender && !store.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
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
        height: Int = 30,
        route: TUIContext.Route = .home(TUIContext.HomeRoute()),
        mode: ThemeMode = .dark,
        serverURL: String = "http://127.0.0.1:4096",
        directory: String = "/workspace"
    ) -> String {
        let test = createTestRenderer(width: width, height: height)
        defer { test.destroy() }
        let store = Store(UIState(
            route: route,
            mode: mode,
            serverVersion: "swift-opencode 2.0",
            serverURL: serverURL,
            directory: directory,
            sessions: [
                SessionSummary(id: "ses_demo01", title: "Port OpenCode to Swift 6.2"),
                SessionSummary(id: "ses_demo02", title: "Verify OpenTUI 100% Parity"),
            ],
            activeSessionID: "ses_demo01",
            activeSessionTitle: "Port OpenCode to Swift 6.2",
            messages: [
                TranscriptMessage(id: "msg_1", role: "user", text: "Check parity status across all Swift targets."),
                TranscriptMessage(id: "msg_2", role: "assistant", text: "All **15 OpenCode packages** (9,404 symbols) and **5 OpenTUI packages** (5,679 symbols) are at **100.0% parity**."),
            ],
            cols: width,
            rows: height
        ))
        let client = OpenCodeClient(options: ClientOptions(baseUrl: serverURL, transport: MockHTTPTransport()))
        let root = mountInteractiveView(
            on: test.renderer,
            store: store,
            client: client,
            directory: directory,
            refreshSessions: {},
            markDirty: {}
        )
        test.renderOnce(force: true)
        let frame = test.captureCharFrame()
        root.unmount()
        return frame
    }

    // MARK: - View Composition & Event Wiring

    private static func loadMessages(
        sessionID: String,
        client: OpenCodeClient,
        store: Store,
        markDirty: @escaping @Sendable () -> Void
    ) async {
        guard let resp = try? await client.message.list(MessageListInput(sessionID: sessionID, limit: 50)) else {
            return
        }
        let mapped: [TranscriptMessage] = resp.data.compactMap { msg in
            switch msg {
            case .user(let u):
                return TranscriptMessage(id: u.id.rawValue, role: "user", text: u.text)
            case .synthetic(let s):
                return TranscriptMessage(id: s.id.rawValue, role: "system", text: s.text)
            case .assistant(let a):
                let parts = a.content.compactMap { part -> String? in
                    switch part {
                    case .text(let t): return t.text
                    case .reasoning(let r): return r.text.isEmpty ? nil : "_Thinking:_ \(r.text)"
                    case .tool(let tl): return "`tool:\(tl.name)`"
                    }
                }
                let combined = parts.joined(separator: "\n")
                return combined.isEmpty ? nil : TranscriptMessage(id: a.id.rawValue, role: "assistant", text: combined)
            default:
                return nil
            }
        }
        store.withLock {
            if $0.activeSessionID == sessionID {
                $0.messages = mapped
            }
        }
        markDirty()
    }

    private static func submitPrompt(
        rawText: String,
        store: Store,
        client: OpenCodeClient,
        directory: String,
        refreshSessions: @escaping @Sendable () -> Void,
        markDirty: @escaping @Sendable () -> Void
    ) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Handle slash commands directly in the TUI
        switch trimmed.lowercased() {
        case "/quit", "/exit", "/q":
            store.withLock { $0.shouldQuit = true; $0.exitReason = "slash_quit" }
            markDirty()
            return
        case "/home":
            store.withLock {
                $0.route = .home(TUIContext.HomeRoute())
                $0.promptText = ""
                $0.statusLine = "Home — type a prompt or pick a session"
            }
            markDirty()
            return
        case "/new":
            store.withLock {
                $0.activeSessionID = nil
                $0.activeSessionTitle = "New Session"
                $0.messages = []
                $0.route = .home(TUIContext.HomeRoute())
                $0.promptText = ""
                $0.statusLine = "Started fresh session draft"
            }
            markDirty()
            return
        case "/theme":
            store.withLock {
                $0.mode = ($0.mode == .dark) ? .light : .dark
                $0.promptText = ""
                $0.statusLine = "Switched theme to \($0.mode.rawValue) mode"
            }
            markDirty()
            return
        case "/sidebar":
            store.withLock {
                $0.showSidebar.toggle()
                $0.promptText = ""
                $0.statusLine = $0.showSidebar ? "Sidebar visible" : "Sidebar hidden"
            }
            markDirty()
            return
        case "/help", "/commands":
            store.withLock {
                $0.showPalette = true
                $0.promptText = ""
            }
            markDirty()
            return
        default:
            break
        }

        let currentSessionID = store.withLock { s -> String? in
            s.promptText = ""
            s.messages.append(TranscriptMessage(id: "local-\(s.messages.count + 1)", role: "user", text: trimmed))
            s.statusLine = "Sending prompt to \(s.serverURL)…"
            return s.activeSessionID
        }
        markDirty()

        Task {
            do {
                let targetSessionID: String
                if let existing = currentSessionID {
                    targetSessionID = existing
                } else {
                    let title = String(trimmed.prefix(48))
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: directory))
                    let created = try await client.session.create(SessionCreateInput(
                        title: title,
                        location: loc
                    ))
                    targetSessionID = created.id.rawValue
                    store.withLock {
                        $0.activeSessionID = targetSessionID
                        $0.activeSessionTitle = title
                        $0.route = .session(TUIContext.SessionRoute(sessionID: targetSessionID))
                    }
                    markDirty()
                }
                _ = try await client.session.prompt(SessionPromptInput(
                    sessionID: targetSessionID,
                    text: trimmed
                ))
                store.withLock {
                    $0.route = .session(TUIContext.SessionRoute(sessionID: targetSessionID))
                    $0.statusLine = "Prompt admitted on session \(targetSessionID)"
                }
                await loadMessages(sessionID: targetSessionID, client: client, store: store, markDirty: markDirty)
                refreshSessions()
            } catch {
                store.withLock {
                    $0.messages.append(TranscriptMessage(
                        id: "err-\($0.messages.count + 1)",
                        role: "system",
                        text: "Server response: \(error)"
                    ))
                    $0.statusLine = "Error: \(error)"
                }
                markDirty()
            }
        }
    }

    private static func mountInteractiveView(
        on renderer: CliRenderer,
        store: Store,
        client: OpenCodeClient,
        directory: String,
        refreshSessions: @escaping @Sendable () -> Void,
        markDirty: @escaping @Sendable () -> Void
    ) -> TUIViewRoot {
        let viewRoot = TUIViewRoot(renderer: renderer)
        viewRoot.autoRenderOnInvalidate = false

        let executePaletteAction: @Sendable (Int) -> Void = { index in
            store.withLock { $0.showPalette = false }
            switch index {
            case 0:
                submitPrompt(rawText: "/new", store: store, client: client, directory: directory, refreshSessions: refreshSessions, markDirty: markDirty)
            case 1:
                submitPrompt(rawText: "/home", store: store, client: client, directory: directory, refreshSessions: refreshSessions, markDirty: markDirty)
            case 2:
                submitPrompt(rawText: "/sidebar", store: store, client: client, directory: directory, refreshSessions: refreshSessions, markDirty: markDirty)
            case 3:
                submitPrompt(rawText: "/theme", store: store, client: client, directory: directory, refreshSessions: refreshSessions, markDirty: markDirty)
            case 4:
                store.withLock { $0.statusLine = "Refreshing sessions from server…" }
                refreshSessions()
            case 5:
                store.withLock { $0.shouldQuit = true; $0.exitReason = "palette_quit" }
            default:
                break
            }
            markDirty()
        }

        _ = renderer.keyInput.onKeypress { event in
            let snap = store.withLock { $0 }
            if event.ctrl && (event.name == "c" || event.name == "d") {
                store.withLock { $0.shouldQuit = true; $0.exitReason = "ctrl_c" }
                event.preventDefault()
                markDirty()
                return
            }
            if event.ctrl && event.name == "p" {
                store.withLock { $0.showPalette.toggle() }
                event.preventDefault()
                markDirty()
                return
            }
            if event.ctrl && event.name == "t" {
                store.withLock {
                    $0.mode = ($0.mode == .dark) ? .light : .dark
                    $0.statusLine = "Theme: \($0.mode.rawValue)"
                }
                event.preventDefault()
                markDirty()
                return
            }
            if event.ctrl && event.name == "b" {
                store.withLock {
                    $0.showSidebar.toggle()
                    $0.statusLine = $0.showSidebar ? "Sidebar shown" : "Sidebar hidden"
                }
                event.preventDefault()
                markDirty()
                return
            }
            if event.ctrl && event.name == "n" {
                submitPrompt(rawText: "/new", store: store, client: client, directory: directory, refreshSessions: refreshSessions, markDirty: markDirty)
                event.preventDefault()
                return
            }
            if event.name == "escape" {
                if snap.showPalette {
                    store.withLock { $0.showPalette = false }
                    event.preventDefault()
                    markDirty()
                    return
                }
                if snap.focusOnSessions {
                    store.withLock { $0.focusOnSessions = false }
                    event.preventDefault()
                    markDirty()
                    return
                }
                if case .session = snap.route {
                    store.withLock { $0.route = .home(TUIContext.HomeRoute()) }
                    event.preventDefault()
                    markDirty()
                    return
                }
            }
            if event.name == "tab" && !snap.showPalette {
                if case .home = snap.route, !snap.sessions.isEmpty {
                    store.withLock { $0.focusOnSessions.toggle() }
                    event.preventDefault()
                    markDirty()
                    return
                }
            }
        }

        viewRoot.render {
            let snap = store.withLock { $0 }
            let resolvedTheme = ThemeDefaults.resolveOrDefault(nil, mode: snap.mode)
            let tokens = resolvedTheme.tokens
            let syntaxStyle = generateSyntax(resolvedTheme)
            let bgRoot = Color.rgba(tokens.background.base)
            let bgPanel = Color.rgba(tokens.background.raised.base)
            let fgText = Color.rgba(tokens.text.base)
            let fgMuted = Color.rgba(tokens.text.muted)
            let fgAccent = Color.rgba(tokens.text.action.primary.base)
            let borderCol = Color.rgba(tokens.border.base)
            let borderFocus = Color.rgba(tokens.text.formfield.focused)

            let sessionSelectOpts: [SelectOption] = snap.sessions.isEmpty
                ? [SelectOption(name: "No sessions yet", description: "Type a prompt above and press Enter to start one")]
                : snap.sessions.map { SelectOption(name: $0.title, description: $0.id) }

            let isHome = snap.isHome

            VStack(spacing: 0) {
                // Top Header Bar
                TUIBox(
                    border: false,
                    backgroundColor: bgPanel,
                    shouldFill: true
                ) {
                    HStack(spacing: 2) {
                        TUIText(" ◆ OPENCODE SWIFT ", fg: fgAccent, attributes: createTextAttributes(bold: true))
                        TUIText(isHome ? "Home" : "Session: \(snap.activeSessionTitle)", fg: fgText)
                        TUISpacer()
                        TUIText("● \(snap.serverURL) (\(snap.serverVersion)) ", fg: fgMuted)
                    }
                }
                .width(.percent(100))
                .height(1)

                if snap.showPalette {
                    // Command Palette Overlay
                    VStack(spacing: 1) {
                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: borderFocus,
                            backgroundColor: bgPanel,
                            shouldFill: true,
                            title: " Command Palette (↑/↓ Enter, Esc close) "
                        ) {
                            TUISelect(
                                options: paletteOptions,
                                selectedIndex: snap.paletteIndex,
                                wrapSelection: true,
                                showDescription: true,
                                selectedTextColor: bgRoot,
                                selectedBackgroundColor: fgAccent,
                                onChange: { idx, _ in
                                    store.withLock { $0.paletteIndex = idx }
                                    markDirty()
                                },
                                onSelect: { idx, _ in
                                    executePaletteAction(idx)
                                }
                            )
                            .key("opencode-palette")
                            .width(.percent(100))
                            .height(12)
                            .focused(true)
                        }
                        .width(.percent(100))
                        .flexGrow(1)
                    }
                    .padding(top: 1, right: 2, bottom: 1, left: 2)
                    .width(.percent(100))
                    .flexGrow(1)
                } else if isHome {
                    // Home Screen
                    VStack(spacing: 1) {
                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: borderCol,
                            backgroundColor: bgPanel,
                            shouldFill: true,
                            title: " swift-opencode • 100% Parity Native Swift 6.2 "
                        ) {
                            VStack(spacing: 0) {
                                TUIASCIIFont("OPENCODE", font: .tiny, color: fgAccent)
                                TUIText("Directory: \(snap.directory)", fg: fgMuted)
                                TUIText("Commands: /new • /theme • /sidebar • /help • /quit", fg: fgMuted)
                            }
                        }
                        .width(.percent(100))
                        .height(7)

                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: !snap.focusOnSessions ? borderFocus : borderCol,
                            backgroundColor: bgPanel,
                            shouldFill: true,
                            title: " Ask anything (Enter to send • Tab to switch to Sessions) "
                        ) {
                            TUIInput(
                                value: snap.promptText,
                                placeholder: "Type a message or /help...",
                                maxLength: 500,
                                onInput: { val in
                                    store.withLock { $0.promptText = val }
                                    markDirty()
                                },
                                onSubmit: { val in
                                    submitPrompt(
                                        rawText: val,
                                        store: store,
                                        client: client,
                                        directory: directory,
                                        refreshSessions: refreshSessions,
                                        markDirty: markDirty
                                    )
                                }
                            )
                            .key("home-prompt-input")
                            .width(.percent(100))
                            .focused(!snap.focusOnSessions)
                        }
                        .width(.percent(100))
                        .height(3)

                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: snap.focusOnSessions ? borderFocus : borderCol,
                            backgroundColor: bgPanel,
                            shouldFill: true,
                            title: " Recent Sessions (\(snap.sessions.count)) "
                        ) {
                            TUISelect(
                                options: sessionSelectOpts,
                                selectedIndex: min(snap.sessionSelectIndex, max(0, sessionSelectOpts.count - 1)),
                                wrapSelection: true,
                                showDescription: true,
                                selectedTextColor: bgRoot,
                                selectedBackgroundColor: fgAccent,
                                onChange: { idx, _ in
                                    store.withLock { $0.sessionSelectIndex = idx }
                                    markDirty()
                                },
                                onSelect: { idx, _ in
                                    let picked = store.withLock { s -> SessionSummary? in
                                        guard idx >= 0 && idx < s.sessions.count else { return nil }
                                        let chosen = s.sessions[idx]
                                        s.activeSessionID = chosen.id
                                        s.activeSessionTitle = chosen.title
                                        s.route = .session(TUIContext.SessionRoute(sessionID: chosen.id))
                                        s.focusOnSessions = false
                                        s.statusLine = "Opened session \(chosen.id)"
                                        return chosen
                                    }
                                    markDirty()
                                    if let picked {
                                        Task {
                                            await loadMessages(sessionID: picked.id, client: client, store: store, markDirty: markDirty)
                                        }
                                    }
                                }
                            )
                            .key("home-sessions-list")
                            .width(.percent(100))
                            .flexGrow(1)
                            .focused(snap.focusOnSessions)
                        }
                        .width(.percent(100))
                        .flexGrow(1)
                    }
                    .padding(top: 1, right: 1, bottom: 0, left: 1)
                    .width(.percent(100))
                    .flexGrow(1)
                } else {
                    // Session Screen (Transcript + Optional Sidebar + Prompt Composer)
                    VStack(spacing: 1) {
                        HStack(spacing: 1) {
                            TUIBox(
                                border: true,
                                borderStyle: .rounded,
                                borderColor: borderCol,
                                backgroundColor: bgRoot,
                                shouldFill: true,
                                title: " Transcript (\(snap.messages.count) messages) "
                            ) {
                                let markdownBody: String = snap.messages.isEmpty
                                    ? "_No messages yet. Type below and press Enter to send a prompt._"
                                    : snap.messages.map { m in
                                        let badge = m.role == "user" ? "**You**" : (m.role == "assistant" ? "**OpenCode**" : "_System_")
                                        return "\(badge)\n\n\(m.text)"
                                    }.joined(separator: "\n\n---\n\n")

                                TUIMarkdown(markdownBody, syntaxStyle: syntaxStyle)
                                    .key("session-transcript")
                                    .width(.percent(100))
                                    .flexGrow(1)
                            }
                            .flexGrow(1)

                            if snap.showSidebar {
                                TUIBox(
                                    border: true,
                                    borderStyle: .rounded,
                                    borderColor: borderCol,
                                    backgroundColor: bgPanel,
                                    shouldFill: true,
                                    title: " Session Info "
                                ) {
                                    VStack(spacing: 1) {
                                        TUIText("ID: \(snap.activeSessionID ?? "draft")", fg: fgAccent)
                                        TUIText("Dir: \(snap.directory)", fg: fgMuted)
                                        TUIText("Server: \(snap.serverURL)", fg: fgMuted)
                                        TUIText("Theme: \(snap.mode.rawValue)", fg: fgText)
                                        TUIText("Messages: \(snap.messages.count)", fg: fgText)
                                    }
                                }
                                .width(32)
                            }
                        }
                        .width(.percent(100))
                        .flexGrow(1)

                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: borderFocus,
                            backgroundColor: bgPanel,
                            shouldFill: true,
                            title: " Message (Enter send • Esc home • Ctrl+P commands) "
                        ) {
                            TUIInput(
                                value: snap.promptText,
                                placeholder: "Send a message or /home, /new, /quit...",
                                maxLength: 500,
                                onInput: { val in
                                    store.withLock { $0.promptText = val }
                                    markDirty()
                                },
                                onSubmit: { val in
                                    submitPrompt(
                                        rawText: val,
                                        store: store,
                                        client: client,
                                        directory: directory,
                                        refreshSessions: refreshSessions,
                                        markDirty: markDirty
                                    )
                                }
                            )
                            .key("session-prompt-input")
                            .width(.percent(100))
                            .focused(true)
                        }
                        .width(.percent(100))
                        .height(3)
                    }
                    .padding(top: 1, right: 1, bottom: 0, left: 1)
                    .width(.percent(100))
                    .flexGrow(1)
                }

                // Bottom Status Bar
                TUIBox(
                    border: false,
                    backgroundColor: bgPanel,
                    shouldFill: true
                ) {
                    HStack(spacing: 2) {
                        TUIText(" ● \(snap.statusLine)", fg: fgAccent)
                        TUISpacer()
                        TUIText("Ctrl+P Palette • Ctrl+T Theme • Ctrl+B Sidebar • Ctrl+C Quit ", fg: fgMuted)
                    }
                }
                .width(.percent(100))
                .height(1)
            }
            .width(.percent(100))
            .height(.percent(100))
        }

        return viewRoot
    }
}
