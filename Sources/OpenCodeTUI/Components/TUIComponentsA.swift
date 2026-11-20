#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Synchronization

/// First half of TUI components (`packages/tui/src/component/*`):
/// spinners (`SpinnerRenderable`, `Spinner`, `OneCellSpinner`), dialogs, permanent Experiments framework,
/// DevTools bar, command palette, logo, usage limits, and overlay banners.
public enum TUIComponent {

    // MARK: - Spinner Frames & SpinnerRenderable (`src/component/spinner-frames.ts`, `spinner-renderable.ts`, `spinner.tsx`, `one-cell-spinner.tsx`)

    // parity: tui/src/component/spinner-frames.ts#SPINNER_FRAMES [status=implemented hash=5d8dd2525c25]
    public static let SPINNER_FRAMES: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    // parity: tui/src/component/spinner-renderable.ts#ColorGenerator [status=implemented hash=09bf08633e4a]
    public typealias ColorGenerator = @Sendable (Int, Int, Int, Int) -> Color

    public enum SpinnerColorSource: Sendable {
        case fixed(RGBA)
        case generator(ColorGenerator)
    }

    public struct SpinnerOptions: Sendable {
        public var id: String?
        public var frames: [String]
        public var interval: Double
        public var autoplay: Bool
        public var color: SpinnerColorSource
        public var backgroundColor: RGBA

        public init(
            id: String? = nil,
            frames: [String] = TUIComponent.SPINNER_FRAMES,
            interval: Double = 80,
            autoplay: Bool = true,
            color: SpinnerColorSource = .fixed(RGBA.fromInts(255, 255, 255)),
            backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0)
        ) {
            self.id = id
            self.frames = frames
            self.interval = interval
            self.autoplay = autoplay
            self.color = color
            self.backgroundColor = backgroundColor
        }
    }

    /// Animated frame-driven spinner renderable built directly on `OpenTUIRenderables.Renderable`.
    // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable [status=implemented hash=d7d6ab1807a2]
    public final class SpinnerRenderable: Renderable, @unchecked Sendable {
        private struct GlyphCell: Sendable {
            let char: String
            let width: Int
        }

        private var frameTexts: [String] = []
        private var glyphs: [[GlyphCell]] = []
        private var frameWidth: Int = 0
        private var _interval: Double
        private var _autoplay: Bool
        private var _color: SpinnerColorSource
        private var _backgroundColor: RGBA
        public private(set) var frameIndex: Int = 0

        public init(ctx: any RenderContext, options: SpinnerOptions = SpinnerOptions()) {
            self._interval = options.interval
            self._autoplay = options.autoplay
            self._color = options.color
            self._backgroundColor = options.backgroundColor
            super.init(ctx: ctx, options: RenderableOptions(id: options.id))
            self.setMeasureProvider { [weak self] _, _, _, _ in
                FlexSize(width: Float(self?.frameWidth ?? 0), height: 1)
            }
            self.frames = options.frames
        }

        // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable.frames [status=implemented hash=9bf1d5c0c781]
        public var frames: [String] {
            get { frameTexts }
            set {
                if newValue == frameTexts { return }
                frameTexts = newValue
                glyphs = newValue.map { frame in
                    TUIUtil.graphemes(frame).map { GlyphCell(char: $0, width: TUIUtil.stringWidth($0)) }
                }
                frameIndex = 0
                let width = glyphs.map { row in row.reduce(0) { $0 + $1.width } }.max() ?? 0
                if width != frameWidth {
                    frameWidth = width
                    invalidateIntrinsicSize()
                }
                restart()
            }
        }

        // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable.interval [status=implemented hash=329cca64a574]
        public var interval: Double {
            get { _interval }
            set {
                if newValue == _interval { return }
                _interval = newValue
                restart()
            }
        }

        // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable.autoplay [status=implemented hash=6eb180884f48]
        public var autoplay: Bool {
            get { _autoplay }
            set {
                if newValue == _autoplay { return }
                _autoplay = newValue
                restart()
            }
        }

        // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable.color [status=implemented hash=adf82e3d15aa]
        public var color: SpinnerColorSource {
            get { _color }
            set {
                _color = newValue
                requestRender()
            }
        }

        // parity: tui/src/component/spinner-renderable.ts#SpinnerRenderable.backgroundColor [status=implemented hash=c998a5afa84c]
        public var backgroundColor: RGBA {
            get { _backgroundColor }
            set {
                _backgroundColor = newValue
                requestRender()
            }
        }

        public var currentFrameText: String {
            guard !frameTexts.isEmpty else { return "" }
            return frameTexts[frameIndex % frameTexts.count]
        }

        private func restart() {
            animationFps = (_autoplay && glyphs.count > 1 && _interval > 0) ? (1000.0 / _interval) : nil
            requestRender()
        }

        public override func onAnimationTick(deltaTime: Double, ticks: Int, time: Double) {
            guard !glyphs.isEmpty else { return }
            frameIndex = (frameIndex + max(1, ticks)) % glyphs.count
            requestRender()
        }

        public override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
            guard glyphs.indices.contains(frameIndex) else { return }
            let row = glyphs[frameIndex]
            var x = screenX
            for (charIdx, glyph) in row.enumerated() {
                let fg: RGBA
                switch _color {
                case .fixed(let rgba):
                    fg = rgba
                case .generator(let gen):
                    fg = gen(frameIndex, charIdx, glyphs.count, row.count).resolved()
                }
                let bg: RGBA? = _backgroundColor.a > 0 ? _backgroundColor : nil
                buffer.drawText(glyph.char, x: x, y: screenY, fg: fg, bg: bg)
                x += glyph.width
            }
        }
    }

    /// Renders a spinner with optional label text (or static `⋯` fallback when animations are disabled).
    // parity: tui/src/component/spinner.tsx#Spinner [status=adapted hash=d2e8b20f939c]
    public static func Spinner(
        ctx: any RenderContext,
        label: String? = nil,
        color: RGBA? = nil,
        animations: Bool = true,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let fg = color ?? theme.text.muted
        let row = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(flexDirection: .row, gap: .point(1))
        )
        if !animations {
            let text = label.map { "⋯ \($0)" } ?? "⋯"
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(fg))))
            return row
        }
        let spin = SpinnerRenderable(
            ctx: ctx,
            options: SpinnerOptions(frames: SPINNER_FRAMES, interval: 80, autoplay: true, color: .fixed(fg))
        )
        row.add(spin)
        if let label, !label.isEmpty {
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(label), fg: .rgba(fg))))
        }
        return row
    }

    /// Renders a 1-cell `OneCellMotion` animated spinner into a 1x1 `BoxRenderable`.
    // parity: tui/src/component/one-cell-spinner.tsx#OneCellSpinner [status=adapted hash=f5a65509759c]
    public static func OneCellSpinner(
        ctx: any RenderContext,
        animation: TUIPrimitive.OneCellMotion,
        color: Color,
        animations: Bool = true,
        speed: Double = 1.0,
        paused: Bool = false,
        glow: Bool = true,
        elapsedMs: Double = 0,
        still: String = "\u{25AA}"
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(width: .point(1), height: .point(1), flexShrink: 0)
        )
        let base = color.resolved()
        if !animations {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(still), fg: .rgba(base))))
            return box
        }
        let sequenced = animation.intro != nil || animation.once == true || animation.pace != nil
        let frame = TUIPrimitive.oneCellFrame(animation, elapsed: elapsedMs)
        let colorSource: SpinnerColorSource
        if !glow {
            colorSource = .fixed(base)
        } else if sequenced {
            colorSource = .fixed(RGBA.fromValues(base.r, base.g, base.b, base.a * frame.level))
        } else if let levels = animation.levels {
            let palette = levels.map { RGBA.fromValues(base.r, base.g, base.b, base.a * $0) }
            colorSource = .generator { fIdx, _, _, _ in
                .rgba(palette[fIdx % max(1, palette.count)])
            }
        } else {
            colorSource = .fixed(base)
        }
        let spin = SpinnerRenderable(
            ctx: ctx,
            options: SpinnerOptions(
                frames: sequenced ? [frame.glyph] : animation.frames,
                interval: animation.interval / max(0.01, speed),
                autoplay: !paused && !sequenced,
                color: colorSource
            )
        )
        box.add(spin)
        return box
    }

    // MARK: - Permanent Experiments Framework (`src/component/dialog-experiments.tsx`)
    // Per upstream `packages/tui/AGENTS.md`:
    // The Experiments framework is permanent infrastructure. Keep the registry, dialog,
    // settings persistence, toggle handling, and UI entry point even when empty.

    public struct ExperimentDefinition: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let title: String
        public let description: String
        /// Whether the experiment is on when the config does not set it.
        public let `default`: Bool?

        public init(id: String, title: String, description: String, default: Bool? = nil) {
            self.id = id
            self.title = title
            self.description = description
            self.default = `default`
        }
    }

    /// Permanent opt-in UI experiments registry (`src/component/dialog-experiments.tsx#experiments`).
    // parity: tui/src/component/dialog-experiments.tsx#experiments [status=implemented hash=bceccc57d93c]
    public static let experiments: [ExperimentDefinition] = [
        ExperimentDefinition(
            id: "new-designs",
            title: "New designs",
            description: "Preview the new TUI designs",
            default: true
        ),
        ExperimentDefinition(
            id: "client-mcp",
            title: "TUI tools",
            description: "Let the agent open terminals in this TUI (requires server support)"
        ),
    ]

    /// Persistent toggle controller for the permanent Experiments framework.
    /// Works cleanly both with active experiments and when the registry is empty.
    public final class ExperimentsStore: Sendable {
        private struct State: Sendable {
            var flags: [String: Bool]
            var registry: [ExperimentDefinition]
        }

        private let state: Mutex<State>
        private let persistHandler: (@Sendable ([String: Bool]) async throws -> Void)?

        public init(
            flags: [String: Bool] = [:],
            registry: [ExperimentDefinition] = TUIComponent.experiments,
            onPersist: (@Sendable ([String: Bool]) async throws -> Void)? = nil
        ) {
            self.state = Mutex(State(flags: flags, registry: registry))
            self.persistHandler = onPersist
        }

        public var registry: [ExperimentDefinition] { state.withLock { $0.registry } }
        public var allFlags: [String: Bool] { state.withLock { $0.flags } }

        /// The configured flag, else the experiment's default, else off.
        public func isEnabled(_ id: String) -> Bool {
            state.withLock { Self.enabled(id, $0) }
        }

        private static func enabled(_ id: String, _ s: State) -> Bool {
            (s.flags[id] ?? s.registry.first { $0.id == id }?.default ?? false) == true
        }

        @discardableResult
        public func toggle(_ id: String) async throws -> Bool {
            let (next, snapshot) = state.withLock { s -> (Bool, [String: Bool]) in
                let value = !Self.enabled(id, s)
                s.flags[id] = value
                return (value, s.flags)
            }
            if let persistHandler {
                try await persistHandler(snapshot)
            }
            return next
        }

        public func set(_ id: String, enabled: Bool) async throws {
            let snapshot = state.withLock { s -> [String: Bool] in
                s.flags[id] = enabled
                return s.flags
            }
            if let persistHandler {
                try await persistHandler(snapshot)
            }
        }
    }

    /// Renders the permanent Experiments dialog (including empty-registry state), matching `dialog-experiments.tsx`.
    // parity: tui/src/component/dialog-experiments.tsx#DialogExperiments [status=adapted hash=0cba9634b987]
    public static func DialogExperiments(
        ctx: any RenderContext,
        store: ExperimentsStore,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        selectedIndex: Int = 0,
        onToggle: (@Sendable (ExperimentDefinition) -> Void)? = nil
    ) -> BoxRenderable {
        let items = store.registry
        let options: [TUIPrimitive.DialogSelectOption<ExperimentDefinition>] = items.map { exp in
            TUIPrimitive.DialogSelectOption(
                title: exp.title,
                value: exp,
                footer: store.isEnabled(exp.id) ? "on" : "off",
                searchText: exp.description,
                onSelect: { _ in onToggle?(exp) }
            )
        }
        if options.isEmpty {
            let surface = theme.surface(.dialog)
            return TUIPrimitive.DialogLayout(
                ctx: ctx,
                id: "dialog-experiments",
                header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Experiments", theme: theme, onClose: { dialog.clear() }),
                body: TextRenderable(
                    ctx: ctx,
                    options: TextOptions(content: .string("No experiments available"), fg: .rgba(surface.text.muted))
                )
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(
                title: "Experiments",
                options: options,
                renderFilter: !items.isEmpty,
                selectedIndex: selectedIndex,
                onSelect: { opt in onToggle?(opt.value) },
                footerActions: TUIPrimitive.DialogFooterActions(
                    secondary: [TUIPrimitive.DialogFooterAction(title: "change", key: "←/→")]
                )
            ),
            dialog: dialog,
            theme: theme
        )
    }

    // MARK: - Settings & Command Palette (`src/component/dialog-config.tsx`, `command-palette.tsx`)

    public struct SettingDefinition: Equatable, Hashable, Sendable {
        public let title: String
        public let category: String
        public let path: [String]
        public let description: String
        public let defaultValue: String
        public let values: [String]
        public let labels: [String]
        public let keywords: [String]
        public let opensPicker: Bool

        public init(
            title: String,
            category: String,
            path: [String],
            description: String,
            defaultValue: String,
            values: [String] = [],
            labels: [String] = [],
            keywords: [String] = [],
            opensPicker: Bool = false
        ) {
            self.title = title
            self.category = category
            self.path = path
            self.description = description
            self.defaultValue = defaultValue
            self.values = values
            self.labels = labels
            self.keywords = keywords
            self.opensPicker = opensPicker
        }
    }

    // parity: tui/src/component/dialog-config.tsx#settings [status=implemented hash=6b26c4219f4b]
    public static let settings: [SettingDefinition] = [
        SettingDefinition(title: "Theme", category: "Appearance", path: ["theme", "name"], description: "Color theme used across the interface", defaultValue: "opencode", keywords: ["color scheme", "colors"], opensPicker: true),
        SettingDefinition(title: "Color mode", category: "Appearance", path: ["theme", "mode"], description: "Dark or light variant, or follow the system", defaultValue: "system", values: ["system", "dark", "light"], keywords: ["dark mode", "light mode", "system theme"]),
        SettingDefinition(title: "Animations", category: "Appearance", path: ["animations"], description: "Whether spinners and transitions animate", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["motion", "effects"]),
        SettingDefinition(title: "Sidebar", category: "Session", path: ["session", "sidebar"], description: "Whether the sidebar shows when there is room", defaultValue: "auto", values: ["hide", "auto"], keywords: ["side panel"]),
        SettingDefinition(title: "Scrollbar", category: "Session", path: ["session", "scrollbar"], description: "Whether a scrollbar is shown next to the chat", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["scroll bar"]),
        SettingDefinition(title: "Scroll on send", category: "Session", path: ["session", "submit_scroll"], description: "Whether sending a prompt jumps to the latest message", defaultValue: "bottom", values: ["bottom", "keep"], labels: ["jump to latest", "keep position"], keywords: ["submit", "scroll position", "jump to latest", "follow"]),
        SettingDefinition(title: "Thinking", category: "Session", path: ["session", "thinking"], description: "Whether model thinking is shown in the chat", defaultValue: "hide", values: ["hide", "show"], keywords: ["reasoning", "chain of thought"]),
        SettingDefinition(title: "Markdown", category: "Session", path: ["session", "markdown"], description: "Whether chat markdown is rendered or shown as source", defaultValue: "rendered", values: ["source", "rendered"], keywords: ["syntax", "concealment", "rendering"]),
        SettingDefinition(title: "Tool grouping", category: "Session", path: ["session", "grouping"], description: "Whether consecutive reads and searches are grouped", defaultValue: "auto", values: ["none", "auto"], keywords: ["transcript", "messages", "reads", "searches"]),
        SettingDefinition(title: "Verbosity", category: "Session", path: ["session", "verbosity"], description: "How much tool activity is shown in the chat", defaultValue: "low", values: ["low", "medium", "high"], keywords: ["detail", "activity", "summary", "transcript"]),
        SettingDefinition(title: "Transcript images", category: "Session", path: ["session", "image_preview"], description: "Whether images are shown in the chat", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["attachments", "images", "tool output"]),
        SettingDefinition(title: "TPS", category: "Session", path: ["session", "tps"], description: "Whether tokens per second are shown for responses", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["tokens per second", "throughput"]),
        SettingDefinition(title: "New session location", category: "Session", path: ["session", "new_location"], description: "Directory new sessions start in", defaultValue: "launch", values: ["launch", "inherit"], labels: ["launch directory", "active session"], keywords: ["directory", "cwd", "inherit"]),
        SettingDefinition(title: "Permissions", category: "Session", path: ["session", "permissions"], description: "Whether permission requests ask you or auto accept", defaultValue: "prompt", values: ["prompt", "autoaccept"], labels: ["prompt", "auto accept"], keywords: ["approve", "accept", "permission requests"]),
        SettingDefinition(title: "Mode", category: "Tabs", path: ["tabs", "mode"], description: "Whether sessions open in tabs", defaultValue: "auto", values: ["off", "on", "auto"]),
        SettingDefinition(title: "Scope", category: "Tabs", path: ["tabs", "scope"], description: "Whether tabs are per directory or shared everywhere", defaultValue: "cwd", values: ["cwd", "global"], labels: ["current directory", "global"]),
        SettingDefinition(title: "Layout", category: "Tabs", path: ["tabs", "layout"], description: "Whether tabs run along the top or down the side", defaultValue: "horizontal", values: ["horizontal", "vertical"], keywords: ["sidebar", "orientation", "left"]),
        SettingDefinition(title: "Indicators", category: "Tabs", path: ["tabs", "indicators"], description: "Whether tabs show status icons or always numbers", defaultValue: "status", values: ["status", "numbers"], labels: ["status icons", "always show numbers"], keywords: ["tab numbers", "number mode", "status icons"]),
        SettingDefinition(title: "Layout", category: "Diffs", path: ["diffs", "view"], description: "Whether diffs are side by side or in one column", defaultValue: "auto", values: ["auto", "split", "unified"], keywords: ["diff layout", "split diff", "unified diff"]),
        SettingDefinition(title: "Wrapping", category: "Diffs", path: ["diffs", "wrap"], description: "Whether long lines in diffs wrap", defaultValue: "word", values: ["none", "word"], keywords: ["diff wrap", "word wrap", "line wrap"]),
        SettingDefinition(title: "File tree", category: "Diffs", path: ["diffs", "tree"], description: "Whether a file tree is shown next to diffs", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["diff files"]),
        SettingDefinition(title: "Single patch", category: "Diffs", path: ["diffs", "single"], description: "Whether diffs show one file at a time", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["one file", "selected file"]),
        SettingDefinition(title: "Scroll speed", category: "Input", path: ["scroll", "speed"], description: "How far each scroll step moves", defaultValue: "3.00", keywords: ["scrolling"]),
        SettingDefinition(title: "Acceleration", category: "Input", path: ["scroll", "acceleration"], description: "Whether scrolling speeds up the faster you scroll", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["scroll acceleration"]),
        SettingDefinition(title: "Mouse", category: "Input", path: ["mouse"], description: "Whether the interface responds to the mouse", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["mouse capture"]),
        SettingDefinition(title: "Editor context", category: "Input", path: ["prompt", "editor"], description: "Whether your editor's selection is added to prompts", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["file context", "prompt context", "editor selection"]),
        SettingDefinition(title: "Large pastes", category: "Input", path: ["prompt", "paste"], description: "Whether large pastes are summarized or shown in full", defaultValue: "compact", values: ["compact", "full"], keywords: ["paste summary", "clipboard", "pasted content"]),
        SettingDefinition(title: "Image previews", category: "Input", path: ["prompt", "image_preview"], description: "Whether attached images are previewed in the prompt", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["attachments", "clipboard", "images", "prompt"]),
        SettingDefinition(title: "Leader timeout", category: "Input", path: ["leader", "timeout"], description: "How long the leader key waits for the next key", defaultValue: "2000 ms", keywords: ["leader key", "shortcut timeout"]),
        SettingDefinition(title: "Notifications", category: "Alerts", path: ["attention", "notifications"], description: "Whether to notify when a session needs attention", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["system notifications", "desktop notifications", "alerts"]),
        SettingDefinition(title: "Sounds", category: "Alerts", path: ["attention", "sound"], description: "Whether a sound plays when a session needs attention", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["audio", "sound effects", "alerts"]),
        SettingDefinition(title: "Volume", category: "Alerts", path: ["attention", "volume"], description: "Volume of alert sounds", defaultValue: "40%", keywords: ["sound volume", "audio volume"]),
        SettingDefinition(title: "Release highlights", category: "Alerts", path: ["highlights"], description: "Whether release highlights are shown after an update", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["what's new", "changelog", "release notes"]),
        SettingDefinition(title: "Window title", category: "Terminal", path: ["terminal", "title"], description: "Whether the window title shows the current session", defaultValue: "true", values: ["false", "true"], labels: ["off", "on"], keywords: ["terminal title", "tab title"]),
        SettingDefinition(title: "Copy behavior", category: "Terminal", path: ["terminal", "copy"], description: "Whether selecting text copies it", defaultValue: "select", values: ["manual", "select"], keywords: ["selection", "clipboard"]),
        SettingDefinition(title: "Developer tools", category: "Debug", path: ["debug", "devtools"], description: "Whether the developer tools bar is shown", defaultValue: "false", values: ["false", "true"], labels: ["off", "on"], keywords: ["debug bar", "developer tools"]),
    ]

    // parity: tui/src/component/dialog-config.tsx#settingID [status=implemented hash=a60f15f766b1]
    public static func settingID(_ setting: SettingDefinition) -> String {
        setting.path.joined(separator: ".")
    }

    // parity: tui/src/component/dialog-config.tsx#DialogConfig [status=adapted hash=48377c529314]
    public static func DialogConfig(
        ctx: any RenderContext,
        current: String? = nil,
        values: [String: String] = [:],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (SettingDefinition) -> Void)? = nil
    ) -> BoxRenderable {
        let initialIdx = current.flatMap { cur in settings.firstIndex { settingID($0) == cur } } ?? 0
        let options = settings.map { setting -> TUIPrimitive.DialogSelectOption<String> in
            let id = settingID(setting)
            let rawVal = values[id] ?? setting.defaultValue
            let display: String
            if let idx = setting.values.firstIndex(of: rawVal), setting.labels.indices.contains(idx) {
                display = setting.labels[idx]
            } else {
                display = rawVal
            }
            return TUIPrimitive.DialogSelectOption(
                title: setting.title,
                value: id,
                footer: display,
                category: setting.category,
                searchText: setting.keywords.joined(separator: " "),
                detail: setting.description,
                onSelect: { _ in onSelect?(setting) }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(
                title: "Settings",
                placeholder: "Search settings",
                options: options,
                current: current,
                selectedIndex: initialIdx,
                footerActions: TUIPrimitive.DialogFooterActions(
                    secondary: [TUIPrimitive.DialogFooterAction(title: "change", key: "←/→")]
                )
            ),
            dialog: dialog,
            theme: theme
        )
    }

    public struct PaletteCommandItem: Sendable {
        public let id: String
        public let title: String
        public let description: String?
        public let group: String?
        public let shortcut: String?
        public let suggested: Bool
        public let run: @Sendable () -> Void

        public init(
            id: String,
            title: String,
            description: String? = nil,
            group: String? = nil,
            shortcut: String? = nil,
            suggested: Bool = false,
            run: @escaping @Sendable () -> Void
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.group = group
            self.shortcut = shortcut
            self.suggested = suggested
            self.run = run
        }
    }

    // parity: tui/src/component/command-palette.tsx#CommandPaletteDialog [status=adapted hash=6504f8be089d]
    public static func CommandPaletteDialog(
        ctx: any RenderContext,
        commands: [PaletteCommandItem],
        filter: String = "",
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let cmdOptions = commands.map { cmd -> TUIPrimitive.DialogSelectOption<String> in
            let searchFooter = [cmd.group, cmd.shortcut].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return TUIPrimitive.DialogSelectOption(
                title: cmd.title,
                value: cmd.id,
                description: cmd.description,
                footer: cmd.shortcut,
                searchFooter: searchFooter.isEmpty ? nil : searchFooter,
                category: cmd.group,
                searchText: [cmd.id, cmd.description].compactMap { $0 }.joined(separator: " "),
                onSelect: { dlg in
                    dlg.clear()
                    cmd.run()
                }
            )
        }
        let settingOptions = settings.map { s in
            TUIPrimitive.DialogSelectOption(
                title: s.title,
                value: "setting:\(settingID(s))",
                searchFooter: "Settings · \(s.category)",
                category: s.category,
                searchText: s.keywords.joined(separator: " ")
            )
        }
        let list: [TUIPrimitive.DialogSelectOption<String>]
        if !filter.isEmpty {
            list = cmdOptions + settingOptions
        } else {
            let suggested = commands.filter(\.suggested).map { cmd in
                TUIPrimitive.DialogSelectOption(
                    title: cmd.title,
                    value: "suggested:\(cmd.id)",
                    description: cmd.description,
                    footer: cmd.shortcut,
                    category: "Suggested",
                    onSelect: { dlg in
                        dlg.clear()
                        cmd.run()
                    }
                )
            }
            list = suggested + cmdOptions
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(
                title: "Commands",
                placeholder: "Search commands",
                options: list,
                flat: true,
                filter: filter
            ),
            dialog: dialog,
            theme: theme
        )
    }

    // MARK: - DevTools Bar (`src/component/devtools-bar.tsx`)

    // parity: tui/src/component/devtools-bar.tsx#RuntimeStatus [status=implemented hash=4839c0f16d15]
    public enum RuntimeStatus: String, Equatable, Hashable, Sendable {
        case normal
        case medium
        case high
    }

    public struct ProcessSample: Equatable, Hashable, Sendable {
        public let delay: Double
        public let time: Double

        public init(delay: Double, time: Double) {
            self.delay = delay
            self.time = time
        }
    }

    // parity: tui/src/component/devtools-bar.tsx#runtimeStatus [status=implemented hash=76082ec62b59]
    public static func runtimeStatus(_ samples: [ProcessSample]) -> RuntimeStatus {
        guard let latest = samples.last?.time else { return .normal }
        let maxDelay = samples
            .filter { $0.time > latest - 6_000 }
            .map(\.delay)
            .max() ?? 0
        if maxDelay >= 100 { return .high }
        if maxDelay >= 20 { return .medium }
        return .normal
    }

    // parity: tui/src/component/devtools-bar.tsx#statusIcon [status=implemented hash=2510be5b1585]
    public static func statusIcon(_ status: RuntimeStatus) -> String {
        switch status {
        case .high: return "●"
        case .medium: return "⦿"
        case .normal: return "○"
        }
    }

    public struct ConnectionIndicatorResult: Equatable, Hashable, Sendable {
        public let state: String
        public let icon: String

        public init(state: String, icon: String) {
            self.state = state
            self.icon = icon
        }
    }

    // parity: tui/src/component/devtools-bar.tsx#connectionIndicator [status=implemented hash=bdcf08959073]
    public static func connectionIndicator(status: String, attempt: Int) -> ConnectionIndicatorResult {
        if status == "connected" { return ConnectionIndicatorResult(state: "connected", icon: "✓") }
        if status == "reconnecting" && attempt >= 3 { return ConnectionIndicatorResult(state: "disconnected", icon: "×") }
        return ConnectionIndicatorResult(state: "reconnecting", icon: "↻")
    }

    // parity: tui/src/component/devtools-bar.tsx#brailleGraph [status=implemented hash=64fe3be3291c]
    public static func brailleGraph(_ values: [Double], width: Int = 23) -> String {
        guard width > 0 else { return "" }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 0
        let range = maxVal - minVal
        let totalPoints = width * 2
        var points: [Double?] = []
        if values.count < totalPoints {
            points.append(contentsOf: Array(repeating: values.first, count: totalPoints - values.count))
        }
        points.append(contentsOf: values.suffix(totalPoints).map(Optional.some))
        let dots = [[6, 2, 1, 0], [7, 5, 4, 3]]
        var out = ""
        for idx in 0..<width {
            var bits = 0
            for col in 0..<2 {
                if let val = points[idx * 2 + col] {
                    let norm = range == 0 ? 0.0 : (val - minVal) / range
                    let height = max(1, min(4, 1 + Int((norm * 3.0).rounded())))
                    for dot in dots[col].prefix(height) {
                        bits |= (1 << dot)
                    }
                }
            }
            out.append(Character(UnicodeScalar(0x2800 + bits)!))
        }
        return out
    }

    // parity: tui/src/component/devtools-bar.tsx#DevToolsBar [status=adapted hash=13431750a506]
    public static func DevToolsBar(
        ctx: any RenderContext,
        connectionStatus: String = "connected",
        reconnectAttempt: Int = 0,
        samples: [ProcessSample] = [],
        themeName: String = "opencode",
        theme: ResolvedTheme,
        onOpenExperiments: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let ind = connectionIndicator(status: connectionStatus, attempt: reconnectAttempt)
        let rt = runtimeStatus(samples)
        let bar = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "devtools-bar",
                width: .percent(100),
                height: .point(1),
                flexDirection: .row,
                gap: .point(2),
                backgroundColor: .rgba(theme.decrease(theme.background.base))
            )
        )
        bar.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(ind.icon) Server"), fg: .rgba(ind.state == "connected" ? theme.text.feedback.success.base : theme.text.feedback.error.base))))
        bar.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(statusIcon(rt)) UI"), fg: .rgba(rt == .high ? theme.text.feedback.error.base : theme.text.muted))))
        bar.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Theme (\(themeName))"), fg: .rgba(theme.text.muted))))
        bar.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Tools"), fg: .rgba(theme.text.muted))))
        let expItem = TextRenderable(ctx: ctx, options: TextOptions(id: "devtools-experiments", content: .string("Experiments"), fg: .rgba(theme.text.muted)))
        if let onOpenExperiments { expItem.onMouseUp = { _ in onOpenExperiments() } }
        bar.add(expItem)
        return bar
    }

    // MARK: - Core Picker & Info Dialogs

    public struct AgentItem: Equatable, Hashable, Sendable {
        public let id: String
        public let description: String?

        public init(id: String, description: String? = nil) {
            self.id = id
            self.description = description
        }
    }

    // parity: tui/src/component/dialog-agent.tsx#DialogAgent [status=adapted hash=b48a96e98fb6]
    public static func DialogAgent(
        ctx: any RenderContext,
        agents: [AgentItem],
        currentAgentID: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (String) -> Void)? = nil
    ) -> BoxRenderable {
        let options = agents.map { agent in
            TUIPrimitive.DialogSelectOption(
                title: agent.id,
                value: agent.id,
                description: agent.description,
                onSelect: { dlg in
                    onSelect?(agent.id)
                    dlg.clear()
                }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Select agent", placeholder: "Search agents", options: options, current: currentAgentID),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-debug.tsx#DialogDebug [status=adapted hash=b74840d0585e]
    public static func DialogDebug(
        ctx: any RenderContext,
        entries: [(label: String, value: String)],
        copied: Bool = false,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onCopy: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
        for entry in entries {
            let padded = entry.label + String(repeating: " ", count: max(0, 10 - entry.label.count))
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(padded) \(entry.value)"), fg: .rgba(surface.text.base), wrapMode: .word)))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-debug",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Debug", description: "Share this when reporting an issue", theme: theme, onClose: { dialog.clear() }),
            body: body,
            footer: TUIPrimitive.DialogFooter(
                ctx: ctx,
                props: TUIPrimitive.DialogFooterProps(
                    actions: TUIPrimitive.DialogFooterActions(
                        primary: [
                            TUIPrimitive.DialogFooterAction(
                                title: copied ? "✓ copied" : "copy",
                                key: "c",
                                onTrigger: onCopy,
                                color: copied ? surface.text.feedback.success.base : nil
                            ),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // parity: tui/src/component/dialog-error-details.tsx#DialogErrorDetails [status=adapted hash=1e7f79931a8a]
    public static func DialogErrorDetails(
        ctx: any RenderContext,
        title: String,
        error: String,
        source: String? = nil,
        context: String? = nil,
        diagnosticRef: String? = nil,
        copied: Bool = false,
        theme: ResolvedTheme,
        onBack: (@Sendable () -> Void)? = nil,
        onCopy: (@Sendable () -> Void)? = nil,
        onInvestigate: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let details = TUIUtil.errorDetails(title: title, error: error, context: context, diagnosticRef: diagnosticRef)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        if let source, !source.isEmpty {
            body.add(TUIPrimitive.FilePath(ctx: ctx, props: TUIPrimitive.FilePathProps(value: source, maxWidth: 50, fg: surface.text.muted)))
        }
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(details.text), fg: .rgba(surface.text.base), wrapMode: .word)))
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-error-details",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: title, theme: theme, onClose: onBack),
            body: body,
            footer: TUIPrimitive.DialogFooter(
                ctx: ctx,
                props: TUIPrimitive.DialogFooterProps(
                    actions: TUIPrimitive.DialogFooterActions(
                        primary: [
                            TUIPrimitive.DialogFooterAction(title: "investigate", key: "i", onTrigger: onInvestigate),
                            copied
                                ? TUIPrimitive.DialogFooterAction(title: "✓ copied", onTrigger: onCopy, color: surface.text.feedback.success.base)
                                : TUIPrimitive.DialogFooterAction(title: "copy details", key: "c", onTrigger: onCopy),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // MARK: - Go Upsell & Art (`src/component/dialog-go-upsell.tsx`, `go-upsell-art.ts`)

    // parity: tui/src/component/dialog-go-upsell.tsx#GO_URL [status=implemented hash=522d53d7a8e1]
    public static let GO_URL = "https://opencode.ai/go"

    private static let goUpsellWaiter = Mutex<Bool>(false)

    // parity: tui/src/component/dialog-go-upsell.tsx#waitForGoUpsellConnect [status=adapted hash=d7ff13d8310a]
    public static func waitForGoUpsellConnect() async {
        _ = goUpsellWaiter.withLock { $0 }
    }

    // parity: tui/src/component/dialog-go-upsell.tsx#DialogGoUpsell [status=adapted hash=632854028a84]
    public static func DialogGoUpsell(
        ctx: any RenderContext,
        resetText: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSubscribe: (@Sendable () -> Void)? = nil,
        onDontShowAgain: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Upgrade to OpenCode Go (\(GO_URL))"), fg: .rgba(surface.text.base), attributes: TextAttributes.bold)))
        if let resetText {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(resetText), fg: .rgba(surface.text.muted))))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-go-upsell",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "OpenCode Go", theme: theme, onClose: { dialog.clear() }),
            body: body,
            buttons: TUIPrimitive.DialogButtons(
                ctx: ctx,
                buttons: [
                    TUIPrimitive.DialogButton(label: "don't show again") { onDontShowAgain?(); dialog.clear() },
                    TUIPrimitive.DialogButton(label: "dismiss") { dialog.clear() },
                    TUIPrimitive.DialogButton(label: "subscribe") { onSubscribe?() },
                ],
                active: 2,
                theme: theme
            )
        )
    }

    /// Radiating shimmer background art renderable for OpenCode Go upsell (`go-upsell-art.ts`).
    // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable [status=adapted hash=ef2f24e4554d]
    public final class GoUpsellArtRenderable: Renderable, @unchecked Sendable {
        private static let periodMs: Double = 4600.0
        private static let stillMs: Double = 2300.0
        /// The art ticks at 30 fps; every cell changes each tick.
        private static let fps: Double = 30

        private var _animate: Bool
        private var _background: RGBA
        private var _primary: RGBA
        private var _logoBase: RGBA
        private var _logoAnchor: Renderable?
        private var drawnKey: String = ""
        public private(set) var elapsedMs: Double

        public init(
            ctx: any RenderContext,
            animate: Bool = true,
            background: RGBA = RGBA.fromInts(0, 0, 0),
            primary: RGBA = RGBA.fromHex("#fab283"),
            logoBase: RGBA = RGBA.fromInts(255, 255, 255),
            logoAnchor: Renderable? = nil
        ) {
            self._animate = animate
            self._background = background
            self._primary = primary
            self._logoBase = logoBase
            self._logoAnchor = logoAnchor
            self.elapsedMs = animate ? 0 : Self.stillMs
            // Ticks on the renderer's shared animation clock only while animating and drawn.
            super.init(ctx: ctx, options: RenderableOptions(id: "go-upsell-art", animationFps: animate ? Self.fps : nil))
        }

        // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable.animate [status=implemented hash=fd0fff2acbef]
        public var animate: Bool {
            get { _animate }
            set {
                guard newValue != _animate else { return }
                _animate = newValue
                animationFps = newValue ? Self.fps : nil
                if !newValue { elapsedMs = Self.stillMs }
                redraw()
            }
        }

        // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable.background [status=implemented hash=0cd9370aaf01]
        public var background: RGBA {
            get { _background }
            set {
                _background = newValue
                redraw()
            }
        }

        // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable.primary [status=implemented hash=6190a6f696ed]
        public var primary: RGBA {
            get { _primary }
            set {
                _primary = newValue
                redraw()
            }
        }

        // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable.logoBase [status=implemented hash=5d409d5c5e6a]
        public var logoBase: RGBA {
            get { _logoBase }
            set {
                _logoBase = newValue
                redraw()
            }
        }

        // parity: tui/src/component/go-upsell-art.ts#GoUpsellArtRenderable.logoAnchor [status=implemented hash=e413e00e3e0a]
        public var logoAnchor: Renderable? {
            get { _logoAnchor }
            set {
                _logoAnchor = newValue
                redraw()
            }
        }

        public var backgroundColor: RGBA {
            get { _background }
            set { background = newValue }
        }

        public var primaryColor: RGBA {
            get { _primary }
            set { primary = newValue }
        }

        public var logoBaseColor: RGBA {
            get { _logoBase }
            set { logoBase = newValue }
        }

        private func redraw() {
            drawnKey = ""
            requestRender()
        }

        public override func onAnimationTick(deltaTime: Double, ticks: Int, time: Double) {
            elapsedMs = (elapsedMs + deltaTime).truncatingRemainder(dividingBy: Self.periodMs)
            requestRender()
        }

        public override func destroySelf() {
            _logoAnchor = nil
            super.destroySelf()
        }

        public override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
            let phase = (elapsedMs.truncatingRemainder(dividingBy: Self.periodMs)) / Self.periodMs
            let glow = TUIThemeBridge.tint(_background, overlay: _primary, alpha: 0.2 + 0.35 * sin(phase * Double.pi))
            let lines = ["    █▀▀▀ █▀▀█", "    █_^█ █__█", "    ▀▀▀▀ ▀▀▀▀"]
            let key = "\(width)x\(height):\(Int(elapsedMs))"
            if !_animate && key == drawnKey { return }
            drawnKey = key
            for (dy, line) in lines.enumerated() where dy < height {
                buffer.drawText(line, x: screenX, y: screenY + dy, fg: _logoBase, bg: glow)
            }
        }
    }

    // MARK: - Highlights, Image Preview, Integrations, MCP, Models

    public struct HighlightEntry: Equatable, Hashable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    // parity: tui/src/component/dialog-highlights.tsx#DialogHighlights [status=adapted hash=701a886ff5de]
    public static func DialogHighlights(
        ctx: any RenderContext,
        version: String,
        items: [HighlightEntry],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setCentered(true)
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        for item in items {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(item.title), fg: .rgba(surface.text.base), attributes: TextAttributes.bold)))
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(item.body), fg: .rgba(surface.text.muted), wrapMode: .word)))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-highlights",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "What's new in \(version)", theme: theme, onClose: { dialog.clear() }),
            body: body,
            footer: TUIPrimitive.DialogFooter(
                ctx: ctx,
                props: TUIPrimitive.DialogFooterProps(actions: TUIPrimitive.DialogFooterActions(primary: [TUIPrimitive.DialogFooterAction(title: "ok", key: "enter", onTrigger: { dialog.clear() })])),
                theme: theme
            )
        )
    }

    public struct ImagePreviewItem: Equatable, Hashable, Sendable {
        public let uri: String
        public let mentionText: String?

        public init(uri: String, mentionText: String? = nil) {
            self.uri = uri
            self.mentionText = mentionText
        }
    }

    // parity: tui/src/component/dialog-image-preview.tsx#DialogImagePreview [status=adapted hash=6052e30c9e9d]
    public static func DialogImagePreview(
        ctx: any RenderContext,
        images: [ImagePreviewItem],
        initial: Int = 0,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setSize(.xlarge)
        dialog.setCentered(true)
        let index = images.isEmpty ? 0 : max(0, min(images.count - 1, initial))
        let surface = theme.surface(.dialog)
        let caption = images.indices.contains(index) ? (images[index].mentionText ?? "Image \(index + 1)") : "No preview"
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "prompt-image-viewer",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Image \(index + 1) of \(images.count)", theme: theme, onClose: { dialog.clear() }),
            body: TextRenderable(ctx: ctx, options: TextOptions(content: .string(caption), fg: .rgba(surface.text.muted), wrapMode: TextWrapMode.none, truncate: true))
        )
    }

    public struct IntegrationMethodSummary: Equatable, Hashable, Sendable {
        public let type: String
        public let label: String

        public init(type: String, label: String) {
            self.type = type
            self.label = label
        }
    }

    public struct IntegrationConnectionSummary: Equatable, Hashable, Sendable {
        public let type: String
        public let label: String
        public let name: String?

        public init(type: String, label: String, name: String? = nil) {
            self.type = type
            self.label = label
            self.name = name
        }
    }

    public struct IntegrationItem: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let methods: [IntegrationMethodSummary]
        public let connections: [IntegrationConnectionSummary]

        public init(id: String, name: String, methods: [IntegrationMethodSummary] = [], connections: [IntegrationConnectionSummary] = []) {
            self.id = id
            self.name = name
            self.methods = methods
            self.connections = connections
        }
    }

    private static let integrationPriority: [String: Int] = [
        "opencode": 0, "opencode-go": 1, "openai": 2, "github-copilot": 3, "anthropic": 4, "google": 5,
    ]

    // parity: tui/src/component/dialog-integration.tsx#integrationOptions [status=implemented hash=0cd4f5843c6c]
    public static func integrationOptions(_ list: [IntegrationItem]) -> [IntegrationItem] {
        list.sorted { a, b in
            let pa = integrationPriority[a.id] ?? 99
            let pb = integrationPriority[b.id] ?? 99
            if pa != pb { return pa < pb }
            let nameCmp = a.name.localizedStandardCompare(b.name)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return a.id < b.id
        }
    }

    // parity: tui/src/component/dialog-integration.tsx#connectMethods [status=implemented hash=19822749443d]
    public static func connectMethods(_ integration: IntegrationItem) -> [IntegrationMethodSummary] {
        integration.methods
            .filter { $0.type != "env" }
            .sorted { ($0.type == "key" ? 1 : 0) < ($1.type == "key" ? 1 : 0) }
    }

    // parity: tui/src/component/dialog-integration.tsx#credentialConnections [status=implemented hash=3f4bbd58937f]
    public static func credentialConnections(_ integration: IntegrationItem) -> [IntegrationConnectionSummary] {
        integration.connections.filter { $0.type == "credential" }
    }

    // parity: tui/src/component/dialog-integration.tsx#connectionSummary [status=implemented hash=26975525c493]
    public static func connectionSummary(_ integration: IntegrationItem) -> String {
        if integration.connections.count > 1 { return "\(integration.connections.count) connections" }
        guard let first = integration.connections.first else { return "" }
        return first.type == "credential" ? first.label : "$\(first.name ?? first.label)"
    }

    // parity: tui/src/component/dialog-integration.tsx#DialogIntegration [status=adapted hash=0554fea01e62]
    public static func DialogIntegration(
        ctx: any RenderContext,
        integrations: [IntegrationItem],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (IntegrationItem) -> Void)? = nil
    ) -> BoxRenderable {
        let sorted = integrationOptions(integrations)
        let options = sorted.map { item in
            TUIPrimitive.DialogSelectOption(
                title: item.name,
                value: item.id,
                footer: connectionSummary(item),
                onSelect: { _ in onSelect?(item) }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Connect a provider", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    public struct McpServerEntry: Equatable, Hashable, Sendable {
        public let name: String
        public let status: String
        public let error: String?

        public init(name: String, status: String, error: String? = nil) {
            self.name = name
            self.status = status
            self.error = error
        }
    }

    // parity: tui/src/component/dialog-mcp.tsx#DialogMcp [status=adapted hash=65965f4f10fe]
    public static func DialogMcp(
        ctx: any RenderContext,
        servers: [McpServerEntry],
        initialServer: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let sorted = servers.sorted { $0.name < $1.name }
        let options = sorted.map { server -> TUIPrimitive.DialogSelectOption<String> in
            let footer: String
            let color: RGBA
            switch server.status {
            case "connected":
                footer = "Connected ✓"
                color = surface.text.feedback.success.base
            case "failed":
                footer = "Failed !"
                color = surface.text.feedback.error.base
            case "needs_auth":
                footer = "Sign in required →"
                color = surface.text.feedback.warning.base
            case "pending":
                footer = "Connecting …"
                color = surface.text.muted
            default:
                footer = "Disabled ○"
                color = surface.text.muted
            }
            return TUIPrimitive.DialogSelectOption(title: server.name, value: server.name, footer: footer, footerColor: color)
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "MCP Servers", options: options, current: initialServer),
            dialog: dialog,
            theme: theme
        )
    }

    public struct ModelChoiceItem: Equatable, Hashable, Sendable {
        public let providerID: String
        public let modelID: String
        public let name: String
        public let category: String?
        public let isFree: Bool
        public let isFavorite: Bool

        public init(providerID: String, modelID: String, name: String, category: String? = nil, isFree: Bool = false, isFavorite: Bool = false) {
            self.providerID = providerID
            self.modelID = modelID
            self.name = name
            self.category = category
            self.isFree = isFree
            self.isFavorite = isFavorite
        }
    }

    // parity: tui/src/component/dialog-model-free.tsx#DialogFreeModels [status=adapted hash=161593edc857]
    public static func DialogFreeModels(
        ctx: any RenderContext,
        models: [ModelChoiceItem],
        currentKey: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (ModelChoiceItem) -> Void)? = nil
    ) -> BoxRenderable {
        let options = models.filter(\.isFree).map { model in
            TUIPrimitive.DialogSelectOption(
                title: model.name,
                value: "\(model.providerID)/\(model.modelID)",
                footer: model.isFavorite ? "★" : nil,
                onSelect: { dlg in onSelect?(model); dlg.clear() }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Free models", description: "Connect a provider for access to more models", options: options, current: currentKey, flat: true),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-model.tsx#DialogModel [status=adapted hash=6610f39766c4]
    public static func DialogModel(
        ctx: any RenderContext,
        models: [ModelChoiceItem],
        providerID: String? = nil,
        currentKey: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (ModelChoiceItem) -> Void)? = nil
    ) -> BoxRenderable {
        let scoped = providerID.map { pid in models.filter { $0.providerID == pid } } ?? models
        let options = scoped.map { model in
            TUIPrimitive.DialogSelectOption(
                title: model.name,
                value: "\(model.providerID)/\(model.modelID)",
                footer: model.isFree ? "Free" : (model.isFavorite ? "★" : nil),
                category: model.category,
                onSelect: { dlg in onSelect?(model); dlg.clear() }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Select model", options: options, current: currentKey),
            dialog: dialog,
            theme: theme
        )
    }

    // MARK: - Open, Pair, Session List, Rename, Shell Output, Skill, Stash, Status, Theme List, Update, Variant, Workspaces

    // parity: tui/src/component/dialog-open.tsx#DialogOpenKey [status=implemented hash=9d39233f2070]
    public static let DialogOpenKey = "DialogOpen"

    public struct OpenSessionItem: Equatable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let directory: String
        public let projectID: String?
        public let subpath: String?
        public let updatedMs: Int64

        public init(id: String, title: String, directory: String, projectID: String? = nil, subpath: String? = nil, updatedMs: Int64 = 0) {
            self.id = id
            self.title = title
            self.directory = directory
            self.projectID = projectID
            self.subpath = subpath
            self.updatedMs = updatedMs
        }
    }

    // parity: tui/src/component/dialog-open.tsx#moveOpenSession [status=implemented hash=9a0de4bfcb63]
    public static func moveOpenSession(
        _ session: OpenSessionItem,
        newDirectory: String,
        newProjectID: String? = nil,
        newSubpath: String? = nil,
        eventCreatedMs: Int64
    ) -> OpenSessionItem {
        OpenSessionItem(
            id: session.id,
            title: session.title,
            directory: newDirectory,
            projectID: newProjectID ?? session.projectID,
            subpath: newSubpath,
            updatedMs: max(session.updatedMs, eventCreatedMs)
        )
    }

    // parity: tui/src/component/dialog-open.tsx#DialogOpen [status=adapted hash=87d3058096c2]
    public static func DialogOpen(
        ctx: any RenderContext,
        sessions: [OpenSessionItem],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onOpenSession: (@Sendable (String) -> Void)? = nil
    ) -> BoxRenderable {
        let options = sessions.map { s in
            TUIPrimitive.DialogSelectOption(
                title: s.title,
                value: s.id,
                description: TUIUtil.projectName(canonical: s.directory),
                category: "Recent",
                onSelect: { dlg in onOpenSession?(s.id); dlg.clear() }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Open", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-pair.tsx#DialogPair [status=adapted hash=89002e27716c]
    public static func DialogPair(
        ctx: any RenderContext,
        links: [String],
        minutes: Int = 5,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setSize(.large)
        dialog.setCentered(true)
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Open a link to connect. Links work once and expire in \(minutes) minutes."), fg: .rgba(surface.text.muted), wrapMode: .word)))
        for url in links {
            body.add(TUIPrimitive.Link(ctx: ctx, props: TUIPrimitive.LinkProps(href: url, fg: surface.text.base)))
        }
        if let first = links.first, let qr = try? QR.renderUnicodeCompact(first, border: 1) {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(qr), fg: .rgba(surface.text.base))))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-pair",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Pair", theme: theme, onClose: { dialog.clear() }),
            body: body
        )
    }

    public enum SessionAttentionKind: String, Equatable, Hashable, Sendable {
        case permission
        case question
    }

    // parity: tui/src/component/dialog-session-list.tsx#sessionStatusGutter [status=adapted hash=d4db7899fdcb]
    public static func sessionStatusGutter(
        ctx: any RenderContext,
        theme: ResolvedTheme,
        attention: SessionAttentionKind?,
        running: Bool,
        rowColor: RGBA
    ) -> Renderable? {
        let surface = theme.surface(.dialog)
        if let attention {
            let fg = (rowColor == surface.text.action.primary.focused) ? rowColor : surface.text.feedback.warning.base
            return TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string(attention == .permission ? "!" : "?"),
                    fg: .rgba(fg),
                    attributes: TextAttributes.bold
                )
            )
        }
        if running {
            return Spinner(ctx: ctx, color: rowColor, theme: theme)
        }
        return nil
    }

    // parity: tui/src/component/dialog-session-list.tsx#DialogSessionList [status=adapted hash=ae82fc9f0fb4]
    public static func DialogSessionList(
        ctx: any RenderContext,
        sessions: [OpenSessionItem],
        currentSessionID: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (String) -> Void)? = nil
    ) -> BoxRenderable {
        let options = sessions.map { s in
            TUIPrimitive.DialogSelectOption(
                title: s.title,
                value: s.id,
                description: TUIUtil.projectName(canonical: s.directory),
                onSelect: { dlg in onSelect?(s.id); dlg.clear() }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Sessions", options: options, current: currentSessionID),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-session-rename.tsx#DialogSessionRename [status=adapted hash=f1aa91aa0b8a]
    public static func DialogSessionRename(
        ctx: any RenderContext,
        sessionID: String,
        currentTitle: String = "",
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onRename: (@Sendable (String, String) -> Void)? = nil
    ) -> BoxRenderable {
        TUIPrimitive.DialogPrompt(
            ctx: ctx,
            props: TUIPrimitive.DialogPromptProps(
                title: "Rename session",
                placeholder: "Session title",
                value: currentTitle,
                onConfirm: { next in
                    let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onRename?(sessionID, trimmed)
                    dialog.clear()
                },
                onCancel: { dialog.clear() }
            ),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-shell-output.tsx#DialogShellOutput [status=adapted hash=30c7325f39e8]
    public static func DialogShellOutput(
        ctx: any RenderContext,
        command: String,
        output: String,
        status: String = "running",
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setSize(.xlarge)
        dialog.setCentered(true)
        let surface = theme.surface(.dialog)
        let clean = stripAnsiSequences(output).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("$ \(command) (\(status))"), fg: .rgba(surface.text.muted))))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(clean), fg: .rgba(surface.text.base), wrapMode: .word)))
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-shell-output",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Shell output", theme: theme, onClose: { dialog.clear() }),
            body: body
        )
    }

    public struct SkillItem: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let description: String?

        public init(id: String, name: String, description: String? = nil) {
            self.id = id
            self.name = name
            self.description = description
        }
    }

    // parity: tui/src/component/dialog-skill.tsx#DialogSkillProps [status=implemented hash=5a6af204ebef]
    public struct DialogSkillProps: Sendable {
        public let skills: [SkillItem]
        public let onSelect: @Sendable (String) -> Void

        public init(skills: [SkillItem], onSelect: @escaping @Sendable (String) -> Void) {
            self.skills = skills
            self.onSelect = onSelect
        }
    }

    // parity: tui/src/component/dialog-skill.tsx#DialogSkill [status=adapted hash=9b7a1430f98d]
    public static func DialogSkill(
        ctx: any RenderContext,
        props: DialogSkillProps,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        dialog.setSize(.large)
        let maxWidth = props.skills.map(\.name.count).max() ?? 0
        let options = props.skills.map { skill in
            let padded = skill.name + String(repeating: " ", count: max(0, maxWidth - skill.name.count))
            return TUIPrimitive.DialogSelectOption(
                title: padded,
                value: skill.id,
                description: skill.description?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                onSelect: { dlg in
                    props.onSelect(skill.id)
                    dlg.clear()
                }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Skills", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    public struct StashItem: Equatable, Hashable, Sendable {
        public let text: String
        public let timestampMs: Double

        public init(text: String, timestampMs: Double) {
            self.text = text
            self.timestampMs = timestampMs
        }
    }

    // parity: tui/src/component/dialog-stash.tsx#DialogStash [status=adapted hash=789a6a386093]
    public static func DialogStash(
        ctx: any RenderContext,
        entries: [StashItem],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (Int) -> Void)? = nil
    ) -> BoxRenderable {
        let options = entries.enumerated().reversed().map { idx, entry -> TUIPrimitive.DialogSelectOption<Int> in
            let firstLine = entry.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let preview = TUIUtil.truncate(firstLine.trimmingCharacters(in: .whitespaces), 50)
            let lineCount = entry.text.split(separator: "\n", omittingEmptySubsequences: false).count
            return TUIPrimitive.DialogSelectOption(
                title: preview,
                value: idx,
                footer: lineCount > 1 ? "~\(lineCount) lines" : nil,
                onSelect: { dlg in onSelect?(idx); dlg.clear() }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Stash", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-status.tsx#DialogStatus [status=adapted hash=95a778e7241d]
    public static func DialogStatus(
        ctx: any RenderContext,
        mcpServers: [McpServerEntry],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
        if mcpServers.isEmpty {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("No MCP servers"), fg: .rgba(surface.text.base))))
        } else {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(mcpServers.count) MCP server\(mcpServers.count == 1 ? "" : "s")"), fg: .rgba(surface.text.base))))
            for srv in mcpServers {
                body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("• \(srv.name) \(srv.error ?? srv.status)"), fg: .rgba(surface.text.muted))))
            }
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-status",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Status", theme: theme, onClose: { dialog.clear() }),
            body: body
        )
    }

    // parity: tui/src/component/dialog-theme-list.tsx#DialogThemeList [status=adapted hash=21dd79f330aa]
    public static func DialogThemeList(
        ctx: any RenderContext,
        selectedTheme: String = "opencode",
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (String) -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let names = TUIThemeBridge.allThemes().keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let options = names.map { name in
            TUIPrimitive.DialogSelectOption(
                title: name,
                value: name,
                onSelect: { dlg in
                    onSelect?(name)
                    if let onClose { onClose() } else { dlg.clear() }
                }
            )
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Themes", placeholder: "Search themes", options: options, current: selectedTheme, onCancel: onClose),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-update.tsx#DialogUpdate [status=adapted hash=f8523742c2db]
    public static func DialogUpdate(
        ctx: any RenderContext,
        state: String,
        version: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSkip: (@Sendable () -> Void)? = nil,
        onInstall: (@Sendable () -> Void)? = nil,
        onRestart: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        dialog.setCentered(true)
        let surface = theme.surface(.dialog)
        let title = state == "installing" ? "Updating OpenCode" : ((state == "available" || state == "failed") ? "Update available" : "Update")
        var buttons: [TUIPrimitive.DialogButton] = []
        if state != "installing" {
            buttons.append(TUIPrimitive.DialogButton(label: "Skip") { onSkip?(); dialog.clear() })
            if state == "available" { buttons.append(TUIPrimitive.DialogButton(label: "Update") { onInstall?() }) }
            if state == "installed" { buttons.append(TUIPrimitive.DialogButton(label: "Restart") { onRestart?() }) }
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-update",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: title, theme: theme, onClose: { dialog.clear() }),
            body: TextRenderable(ctx: ctx, options: TextOptions(content: .string(version.map { "Version \($0)" } ?? "Status: \(state)"), fg: .rgba(surface.text.muted))),
            buttons: buttons.isEmpty ? nil : TUIPrimitive.DialogButtons(ctx: ctx, buttons: buttons, active: max(0, buttons.count - 1), theme: theme)
        )
    }

    // parity: tui/src/component/dialog-variant.tsx#DialogVariant [status=adapted hash=9ab04251b091]
    public static func DialogVariant(
        ctx: any RenderContext,
        variants: [String],
        currentVariant: String? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (String?) -> Void)? = nil
    ) -> BoxRenderable {
        var options = [
            TUIPrimitive.DialogSelectOption(title: "Default", value: "default", onSelect: { dlg in onSelect?(nil); dlg.clear() }),
        ]
        for v in variants where v != "default" {
            options.append(TUIPrimitive.DialogSelectOption(title: v, value: v, onSelect: { dlg in onSelect?(v); dlg.clear() }))
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Select variant", options: options, current: currentVariant ?? "default", flat: true),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-workspace-file-changes.tsx#WorkspaceFileChangesChoice [status=implemented hash=719f2646fdff]
    public enum WorkspaceFileChangesChoice: String, Equatable, Hashable, Sendable {
        case no
        case yes
    }

    // parity: tui/src/component/dialog-workspace-file-changes.tsx#statusLabel [status=implemented hash=d6896bf91d8a]
    public static func statusLabel(_ status: String) -> String {
        if status == "added" { return "A" }
        if status == "deleted" { return "D" }
        return "M"
    }

    public struct WorkspaceFileChange: Equatable, Hashable, Sendable {
        public let path: String
        public let status: String
        public let additions: Int
        public let deletions: Int

        public init(path: String, status: String = "modified", additions: Int = 0, deletions: Int = 0) {
            self.path = path
            self.status = status
            self.additions = additions
            self.deletions = deletions
        }
    }

    // parity: tui/src/component/dialog-workspace-file-changes.tsx#DialogWorkspaceFileChanges [status=adapted hash=9804eaec8135]
    public static func DialogWorkspaceFileChanges(
        ctx: any RenderContext,
        files: [WorkspaceFileChange],
        title: String = "File Changes Found",
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (WorkspaceFileChangesChoice) -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
        for file in files.prefix(8) {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(statusLabel(file.status)) \(file.path) +\(file.additions) -\(file.deletions)"), fg: .rgba(surface.text.base))))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-workspace-file-changes",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: title, theme: theme, onClose: { onSelect?(.no); dialog.clear() }),
            body: body,
            footer: TUIPrimitive.DialogFooter(
                ctx: ctx,
                props: TUIPrimitive.DialogFooterProps(
                    actions: TUIPrimitive.DialogFooterActions(
                        primary: [
                            TUIPrimitive.DialogFooterAction(title: "cancel", key: "esc", onTrigger: { onSelect?(.no); dialog.clear() }),
                            TUIPrimitive.DialogFooterAction(title: "confirm", key: "enter", onTrigger: { onSelect?(.yes); dialog.clear() }),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // parity: tui/src/component/dialog-workspaces.tsx#WorkspaceSelection [status=implemented hash=c7e54e3e2ca7]
    public enum WorkspaceSelection: Equatable, Hashable, Sendable {
        case directory(path: String, subdirectory: Bool)
        case new(name: String)
    }

    // parity: tui/src/component/dialog-workspaces.tsx#DialogWorkspaces [status=adapted hash=37488019ef3c]
    public static func DialogWorkspaces(
        ctx: any RenderContext,
        directories: [String],
        current: WorkspaceSelection? = nil,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onSelect: (@Sendable (WorkspaceSelection) -> Void)? = nil
    ) -> BoxRenderable {
        dialog.setSize(.xlarge)
        let options: [TUIPrimitive.DialogSelectOption<WorkspaceSelection>] = directories.map { dir in
            let sel = WorkspaceSelection.directory(path: dir, subdirectory: false)
            return TUIPrimitive.DialogSelectOption(title: dir, value: sel, onSelect: { dlg in onSelect?(sel); dlg.clear() })
        }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Workspaces", options: options, current: current, grow: true),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/dialog-worktree-name.tsx#DialogWorktreeName [status=adapted hash=bdd4c70bb5fe]
    public static func DialogWorktreeName(
        ctx: any RenderContext,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme,
        onConfirm: @escaping @Sendable (String) -> Void
    ) -> BoxRenderable {
        TUIPrimitive.DialogPrompt(
            ctx: ctx,
            props: TUIPrimitive.DialogPromptProps(
                title: "Name worktree",
                placeholder: "Worktree name",
                onConfirm: { raw in
                    let slug = slugifyWorktreeName(raw)
                    onConfirm(slug.isEmpty ? "worktree-\(Int.random(in: 1000...9999))" : slug)
                }
            ),
            dialog: dialog,
            theme: theme
        )
    }

    private static func slugifyWorktreeName(_ input: String) -> String {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        var prevDash = true
        for scalar in lower.unicodeScalars {
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                out.append(Character(scalar))
                prevDash = false
            } else if !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Logo, Overlays, Startup Loading, Theme Error Toast, Connected & Usage

    // parity: tui/src/component/logo.tsx#Logo [status=adapted hash=829deb4209cf]
    public static func Logo(
        ctx: any RenderContext,
        terminalWidth: Int = 80,
        terminalHeight: Int = 24,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(id: "opencode-logo", flexDirection: .column))
        guard terminalHeight >= 12 else { return box }
        func renderLogoLine(_ line: String, fg: RGBA, bold: Bool) -> [TextChunk] {
            let shadow = TUIThemeBridge.tint(theme.background.base, overlay: fg, alpha: 0.25)
            let attrs = bold ? TextAttributes.bold : TextAttributes.none
            return line.map { ch in
                switch ch {
                case "_": return TextChunk(text: " ", fg: fg, bg: shadow, attributes: attrs)
                case "^": return TextChunk(text: "▀", fg: fg, bg: shadow, attributes: attrs)
                case "~": return TextChunk(text: "▀", fg: shadow, attributes: attrs)
                case ",": return TextChunk(text: "▄", fg: shadow, attributes: attrs)
                default: return TextChunk(text: String(ch), fg: fg, attributes: attrs)
                }
            }
        }
        if terminalWidth < 22 {
            for line in ["█▀▀█", "█__█", "▀▀▀▀"] {
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .styled(StyledText(chunks: renderLogoLine(line, fg: theme.text.base, bold: true))))))
            }
        } else if terminalWidth < 44 {
            for line in TUIUtil.logoLeft.dropFirst() {
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .styled(StyledText(chunks: renderLogoLine(line, fg: theme.text.muted, bold: false))))))
            }
            for line in TUIUtil.logoRight {
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .styled(StyledText(chunks: renderLogoLine(line, fg: theme.text.base, bold: true))))))
            }
        } else {
            for (idx, leftLine) in TUIUtil.logoLeft.enumerated() {
                let rightLine = idx < TUIUtil.logoRight.count ? TUIUtil.logoRight[idx] : ""
                let chunks = renderLogoLine(leftLine, fg: theme.text.muted, bold: false)
                    + [TextChunk(text: " ")]
                    + renderLogoLine(rightLine, fg: theme.text.base, bold: true)
                box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .styled(StyledText(chunks: chunks)))))
            }
        }
        return box
    }

    // parity: tui/src/component/migration-overlay.tsx#MigrationOverlay [status=adapted hash=e84a63a5908c]
    public static func MigrationOverlay(
        ctx: any RenderContext,
        label: String,
        numerator: Int? = nil,
        denominator: Int? = nil,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let countText: String
        if let n = numerator, let d = denominator { countText = " \(n)/\(d)" }
        else if let n = numerator { countText = " \(n)" }
        else { countText = "" }
        let overlay = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "migration-overlay",
                flexDirection: .row,
                position: .absolute,
                top: .point(1),
                right: .point(2),
                paddingTop: .point(1),
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                zIndex: 10_000,
                backgroundColor: .rgba(theme.background.raised.high),
                border: .sides([.left]),
                borderColor: .rgba(theme.text.feedback.info.base),
                customBorderChars: TUIPrimitive.SplitBorder.customBorderChars
            )
        )
        overlay.add(Spinner(ctx: ctx, label: "\(label)\(countText)", color: theme.text.feedback.info.base, theme: theme))
        return overlay
    }

    // parity: tui/src/component/reconnecting.tsx#Reconnecting [status=adapted hash=682ee21df691]
    public static func Reconnecting(
        ctx: any RenderContext,
        managed: Bool = false,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let overlay = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "reconnecting-overlay",
                alignItems: .center,
                justifyContent: .center,
                position: .absolute,
                top: .point(0),
                right: .point(0),
                bottom: .point(0),
                left: .point(0),
                zIndex: 10_000,
                backgroundColor: .rgba(RGBA.fromInts(0, 0, 0, 150))
            )
        )
        let card = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .point(48),
                flexDirection: .column,
                paddingTop: .point(1),
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                gap: .point(1),
                backgroundColor: .rgba(theme.background.raised.base)
            )
        )
        card.add(Spinner(ctx: ctx, label: managed ? "Restarting service…" : "Connection lost…", color: theme.text.base, theme: theme))
        card.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(managed ? "Your session will resume automatically." : "Reconnecting to the server automatically."), fg: .rgba(theme.text.muted))))
        overlay.add(card)
        return overlay
    }

    // parity: tui/src/component/startup-loading.tsx#StartupLoading [status=adapted hash=181297948c59]
    public static func StartupLoading(
        ctx: any RenderContext,
        ready: Bool,
        visible: Bool = true,
        theme: ResolvedTheme
    ) -> BoxRenderable? {
        guard visible else { return nil }
        let pill = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "startup-loading",
                paddingRight: .point(1),
                paddingLeft: .point(1),
                backgroundColor: .rgba(theme.background.raised.base)
            )
        )
        pill.add(Spinner(ctx: ctx, label: ready ? "Finishing startup…" : "Loading plugins…", color: theme.text.muted, theme: theme))
        return pill
    }

    // parity: tui/src/component/theme-error-toast.tsx#ThemeErrorToast [status=adapted hash=6ac957f0e6c6]
    public static func ThemeErrorToast(
        themeName: String,
        error: any Error,
        toast: TUIPrimitive.ToastContext
    ) {
        toast.show(
            TUIPrimitive.ToastOptions(
                title: "Failed to load theme: \(themeName)",
                message: TUIUtil.errorMessage(error),
                variant: .error
            )
        )
    }

    // parity: tui/src/component/use-connected.tsx#useConnected [status=implemented hash=8c3352620195]
    public static func useConnected(_ integrations: [TUIUtil.IntegrationConnectionsSummary]) -> Bool {
        TUIUtil.hasConnectedProvider(integrations)
    }

    // MARK: - Usage Limits Dialogs & Notices (`src/component/usage.tsx`)

    public struct UsageLimitsViewModel: Sendable {
        public let budgets: [UsageLimitsSchema.Budget]
        public let workspaceName: String?
        public let providers: [String: TUIUtil.LimitedProvider]

        public init(
            budgets: [UsageLimitsSchema.Budget],
            workspaceName: String? = nil,
            providers: [String: TUIUtil.LimitedProvider] = [:]
        ) {
            self.budgets = budgets
            self.workspaceName = workspaceName
            self.providers = providers
        }

        public func usage(for model: TUIUtil.LimitedModel) -> TUIUtil.ModelUsage? {
            TUIUtil.modelUsage(budgets: budgets, model: model, provider: providers[model.providerID])
        }

        public func served(_ providerID: String) -> Bool {
            TUIUtil.servedByConsole(providers[providerID])
        }
    }

    // parity: tui/src/component/usage.tsx#useUsageLimits [status=adapted hash=ec9814806238]
    public static func useUsageLimits(
        budgets: [UsageLimitsSchema.Budget] = [],
        workspaceName: String? = nil,
        providers: [TUIUtil.LimitedProvider] = []
    ) -> UsageLimitsViewModel {
        UsageLimitsViewModel(
            budgets: budgets,
            workspaceName: workspaceName,
            providers: Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        )
    }

    public struct LimitLabelResult: Equatable, Hashable, Sendable {
        public let text: String
        public let danger: Bool

        public init(text: String, danger: Bool) {
            self.text = text
            self.danger = danger
        }
    }

    // parity: tui/src/component/usage.tsx#limitLabel [status=implemented hash=6c8c31d3f183]
    public static func limitLabel(_ usage: TUIUtil.ModelUsage?, model: TUIUtil.LimitedModel) -> LimitLabelResult? {
        guard let usage else { return nil }
        let level = TUIUtil.usageLevel(usage, model: model)
        if level == .plenty { return nil }
        if level == .reached { return LimitLabelResult(text: "Limit reached", danger: true) }
        return LimitLabelResult(text: "\(TUIUtil.formatDollars(usage.left)) left", danger: level == .out)
    }

    // parity: tui/src/component/usage.tsx#DialogUsage [status=adapted hash=d2fac3b6652e]
    public static func DialogUsage(
        ctx: any RenderContext,
        limits: UsageLimitsViewModel,
        models: [(model: TUIUtil.LimitedModel, name: String)],
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let options: [TUIPrimitive.DialogSelectOption<String>] = models
            .sorted { $0.name < $1.name }
            .compactMap { entry in
                guard let usage = limits.usage(for: entry.model) else { return nil }
                let level = TUIUtil.usageLevel(usage, model: entry.model)
                let footer = level == .reached ? "Limit reached" : "\(TUIUtil.formatDollars(usage.left)) left"
                let color = (level == .reached || level == .out) ? surface.text.feedback.error.base : surface.text.muted
                return TUIPrimitive.DialogSelectOption(title: entry.name, value: "\(entry.model.providerID)/\(entry.model.id)", footer: footer, footerColor: color)
            }
        return TUIPrimitive.DialogSelect(
            ctx: ctx,
            props: TUIPrimitive.DialogSelectProps(title: "Usage", options: options),
            dialog: dialog,
            theme: theme
        )
    }

    // parity: tui/src/component/usage.tsx#DialogUsageModel [status=adapted hash=2fff3f8cbf46]
    public static func DialogUsageModel(
        ctx: any RenderContext,
        modelName: String,
        model: TUIUtil.LimitedModel,
        limits: UsageLimitsViewModel,
        dialog: TUIPrimitive.DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        if let usage = limits.usage(for: model) {
            let level = TUIUtil.usageLevel(usage, model: model)
            let isShort = level == .out || level == .reached
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(TUIUtil.formatDollars(usage.left)) remaining"), fg: .rgba(isShort ? surface.text.feedback.error.base : surface.text.base), attributes: TextAttributes.bold)))
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Resets \(TUIUtil.formatReset(usage.resetsAt))"), fg: .rgba(surface.text.muted))))
            for item in usage.limits {
                body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("• \(TUIUtil.formatDollars(item.spent)) used of \(TUIUtil.formatDollars(item.budget.limit.rawValue))"), fg: .rgba(surface.text.base))))
                body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("  \(TUIUtil.limitScope(item.budget, workspace: limits.workspaceName))"), fg: .rgba(surface.text.muted))))
            }
        } else {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("No limits apply to \(modelName)."), fg: .rgba(surface.text.muted))))
        }
        return TUIPrimitive.DialogLayout(
            ctx: ctx,
            id: "dialog-usage-model",
            header: TUIPrimitive.DialogHeader(ctx: ctx, title: "Usage › \(modelName)", theme: theme, onClose: { dialog.clear() }),
            body: body
        )
    }

    private static let warnedUsageKeys = Mutex<Set<String>>([])

    // parity: tui/src/component/usage.tsx#useUsageAlerts [status=adapted hash=ad0ddd94c7d8]
    public static func useUsageAlerts(
        model: TUIUtil.LimitedModel,
        modelName: String,
        usage: TUIUtil.ModelUsage?,
        toast: TUIPrimitive.ToastContext
    ) {
        guard let usage else { return }
        let level = TUIUtil.usageLevel(usage, model: model)
        if level == .plenty { return }
        let key = "\(model.providerID)/\(model.id):\(level == .reached ? "reached" : "low")"
        let inserted = warnedUsageKeys.withLock { $0.insert(key).inserted }
        guard inserted else { return }
        if level == .reached {
            toast.show(TUIPrimitive.ToastOptions(title: "\(modelName) limit reached", message: "Resets \(TUIUtil.formatReset(usage.resetsAt))", variant: .error))
        } else {
            toast.show(TUIPrimitive.ToastOptions(title: "Running low on \(modelName)", message: "\(TUIUtil.formatDollars(usage.left)) left · resets \(TUIUtil.formatReset(usage.resetsAt))", variant: .warning))
        }
    }

    public struct LimitNoticeData: Equatable, Hashable, Sendable {
        public let title: String
        public let body: String
        public let key: String?
        public let linkLabel: String?
        public let linkHref: String?

        public init(title: String, body: String, key: String? = nil, linkLabel: String? = nil, linkHref: String? = nil) {
            self.title = title
            self.body = body
            self.key = key
            self.linkLabel = linkLabel
            self.linkHref = linkHref
        }
    }

    // parity: tui/src/component/usage.tsx#useLimitNotice [status=implemented hash=5f8a8389b413]
    public static func useLimitNotice(
        errorType: String?,
        statusCode: Int? = nil,
        responseBody: String? = nil,
        retryAfterMs: Double? = nil,
        completedAtMs: Double = 0,
        modelName: String,
        servedByConsole: Bool = false,
        workspaceName: String? = nil,
        modelShortcut: String? = nil
    ) -> LimitNoticeData? {
        let reset = TUIUtil.refusalReset(responseBody: responseBody)
            ?? TUIUtil.retryReset(retryAfterMs: retryAfterMs, baseMs: completedAtMs)
        let resets = reset.map { "Resets \(TUIUtil.formatReset($0)). " } ?? ""
        let key = modelShortcut ?? "/models"

        if errorType == "provider.go-limit" {
            let namePart = TUIUtil.goLimitName(responseBody: responseBody)
            let suffix = [namePart, "usage limit reached"].compactMap { $0 }.joined(separator: " ")
            return LimitNoticeData(
                title: "OpenCode Go \(suffix)",
                body: "\(resets)Switch to a free model with",
                key: key,
                linkLabel: "Or turn on Extra Usage on your Go page to keep going now:",
                linkHref: TUIUtil.goLimitLink(responseBody: responseBody)
            )
        }
        if errorType == "provider.model-budget-limit" {
            return LimitNoticeData(title: "\(modelName) usage limit reached", body: "\(resets)Switch model with", key: key)
        }
        if errorType == "provider.budget-limit" {
            return LimitNoticeData(title: "Usage limit reached", body: "\(resets)Paid models are paused. Switch to a free model with", key: key)
        }
        if statusCode == 402 && servedByConsole {
            return LimitNoticeData(
                title: "\(workspaceName ?? "Your workspace") is out of credits",
                body: "Paid models are paused until an admin adds credits in OpenCode Console."
            )
        }
        return nil
    }

    // parity: tui/src/component/usage.tsx#UsageLimitNotice [status=adapted hash=292dd2e6455a]
    public static func UsageLimitNotice(
        ctx: any RenderContext,
        notice: LimitNoticeData,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "usage-limit-notice",
                flexDirection: .column,
                marginLeft: .point(2),
                paddingTop: .point(1),
                paddingBottom: .point(1),
                paddingLeft: .point(1),
                border: .sides([.left]),
                borderColor: .rgba(theme.border.base),
                customBorderChars: TUIPrimitive.SplitBorder.customBorderChars
            )
        )
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(notice.title), fg: .rgba(theme.text.base))))
        let bodyLine = notice.key.map { "\(notice.body) \($0) to continue." } ?? notice.body
        box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(bodyLine), fg: .rgba(theme.text.muted), wrapMode: .word)))
        if let label = notice.linkLabel, let href = notice.linkHref {
            box.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(label), fg: .rgba(theme.text.muted), wrapMode: .word)))
            box.add(TUIPrimitive.Link(ctx: ctx, props: TUIPrimitive.LinkProps(href: href, fg: theme.text.base)))
        }
        return box
    }
}
