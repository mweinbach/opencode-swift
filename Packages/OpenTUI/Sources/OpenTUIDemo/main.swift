import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView
import Synchronization

// MARK: - Demo State & Themes

private struct AccentPalette: Sendable {
    let name: String
    let primary: String
    let secondary: String
    let muted: String
}

private let palettes: [AccentPalette] = [
    AccentPalette(name: "Electric Cyan", primary: "#38bdf8", secondary: "#a78bfa", muted: "#94a3b8"),
    AccentPalette(name: "Emerald", primary: "#34d399", secondary: "#60a5fa", muted: "#94a3b8"),
    AccentPalette(name: "Amber Glow", primary: "#fbbf24", secondary: "#fb7185", muted: "#a8a29e"),
    AccentPalette(name: "Rose Pulse", primary: "#f472b6", secondary: "#38bdf8", muted: "#cbd5e1"),
]

private let demoTabs: [TabSelectOption] = [
    TabSelectOption(name: "1 Controls", description: "ASCIIFont, Input, Select & Slider"),
    TabSelectOption(name: "2 Code & Diff", description: "Syntax Highlighting & Unified/Split Diff"),
    TabSelectOption(name: "3 Markdown", description: "CommonMark + GFM Tables"),
    TabSelectOption(name: "4 QR Code", description: "Live ISO/IEC 18004 Terminal QR"),
]

private let sampleSwiftCode = """
import OpenTUIView

struct Dashboard: TUIView {
    let title: String
    var body: some TUIView {
        TUIBox(border: true, borderStyle: .rounded, title: title) {
            VStack(spacing: 1) {
                TUIText("Pure Swift 6.2 • Zero C/Zig FFI", fg: "#34d399")
                TUIQRCode("https://github.com/anomalyco/opentui")
            }
        }
    }
}
"""

private let sampleUnifiedDiff = """
--- a/Sources/OpenTUIRenderables/Renderer.swift
+++ b/Sources/OpenTUIRenderables/Renderer.swift
@@ -12,5 +12,6 @@
 public final class CliRenderer {
-    public let backend = "ffi-zig"
+    public let backend = "pure-swift-6.2"
+    public let parityCoverage = "100.0% (5,679/5,679)"
     public func renderOnce() {
         flushDiffToTerminal()
     }
"""

private let sampleMarkdown = """
# Swift OpenTUI Showcase

Built with **pure Swift 6.2** strict concurrency and **100.0% parity** across all 5 upstream packages.

- [x] Pure-Swift Flexbox layout, Rope/EditBuffer, ANSI diff renderer
- [x] Full `OpenTUIKeymap` runtime & all 16 universal addons
- [x] Complete `packages/ssh` bridge & declarative `@resultBuilder` DSL

```swift
let qr = try QRCode.encodeText("Hello OpenTUI", ecl: .M)
```
"""

private struct DemoState: Sendable {
    var activeTab: Int = 0
    var paletteIndex: Int = 0
    var sliderValue: Double = 72
    var qrInputText: String = "https://github.com/anomalyco/opentui"
    var qrInverted: Bool = false
    var diffView: DiffViewMode = .unified
    var focusZone: Int = 0 // 0 = select/nav, 1 = text input
    var lastEvent: String = "Ready — 1-4/Tab switch views, arrows/mouse interact"
    var cols: Int = 100
    var rows: Int = 30
    var shouldQuit: Bool = false
}

private final class DemoStore: Sendable {
    private let state: Mutex<DemoState>

    init(_ initial: DemoState) {
        self.state = Mutex(initial)
    }

    func withLock<R>(_ body: (inout DemoState) -> sending R) -> sending R {
        state.withLock(body)
    }
}

// MARK: - Syntax Theme

private func makeDemoSyntaxStyle() -> SyntaxStyle {
    SyntaxStyle.fromStyles([
        "keyword": StyleDefinitionInput(fg: Color.string("#c084fc"), bold: true),
        "string": StyleDefinitionInput(fg: Color.string("#34d399")),
        "comment": StyleDefinitionInput(fg: Color.string("#64748b"), italic: true),
        "number": StyleDefinitionInput(fg: Color.string("#fbbf24")),
        "type": StyleDefinitionInput(fg: Color.string("#38bdf8"), bold: true),
        "function": StyleDefinitionInput(fg: Color.string("#60a5fa")),
        "property": StyleDefinitionInput(fg: Color.string("#f472b6")),
        "markup.heading": StyleDefinitionInput(fg: Color.string("#38bdf8"), bold: true),
        "markup.strong": StyleDefinitionInput(fg: Color.string("#f8fafc"), bold: true),
        "markup.raw": StyleDefinitionInput(fg: Color.string("#fbbf24")),
        "diff.plus": StyleDefinitionInput(fg: Color.string("#34d399")),
        "diff.minus": StyleDefinitionInput(fg: Color.string("#fb7185")),
    ])
}

// MARK: - Declarative View Builder

private func mountDemoApp(
    on renderer: CliRenderer,
    state: DemoStore,
    syntaxStyle: SyntaxStyle,
    onRequestQuit: @escaping @Sendable () -> Void
) -> TUIViewRoot {
    let viewRoot = TUIViewRoot(renderer: renderer)
    viewRoot.autoRenderOnInvalidate = false

    let themeOptions = palettes.map { p in
        SelectOption(name: p.name, description: "Primary \(p.primary) / Secondary \(p.secondary)")
    }

    let parityRows: [[String]] = [
        ["Package", "Swift Target", "Fns", "Syms", "Parity"],
        ["core", "Core/Render", "2098", "3777", "100%"],
        ["keymap", "Keymap", "203", "410", "100%"],
        ["native", "Core/Term", "799", "1372", "100%"],
        ["qrcode", "Renderables", "42", "57", "100%"],
        ["ssh", "Terminal", "17", "63", "100%"],
    ]

    let rebuild: @Sendable () -> Void = {
        viewRoot.invalidate()
    }

    // Global keyboard shortcuts (active when text input is not capturing typing)
    _ = renderer.keyInput.onKeypress { key in
        if key.ctrl && key.name.lowercased() == "c" {
            state.withLock { $0.shouldQuit = true }
            onRequestQuit()
            return
        }

        let snap = state.withLock { $0 }
        let editingInput = (snap.activeTab == 0 && snap.focusZone == 1)

        if key.name == "escape" {
            if editingInput {
                state.withLock {
                    $0.focusZone = 0
                    $0.lastEvent = "Exited input focus (Esc)"
                }
                rebuild()
            } else {
                state.withLock { $0.shouldQuit = true }
                onRequestQuit()
            }
            return
        }

        if key.name == "tab" {
            state.withLock {
                let delta = key.shift ? (demoTabs.count - 1) : 1
                $0.activeTab = ($0.activeTab + delta) % demoTabs.count
                $0.focusZone = 0
                $0.lastEvent = "Switched to \(demoTabs[$0.activeTab].name)"
            }
            rebuild()
            return
        }

        if editingInput {
            return
        }

        switch key.name.lowercased() {
        case "q":
            state.withLock { $0.shouldQuit = true }
            onRequestQuit()
        case "1", "2", "3", "4":
            if let num = Int(key.name), num >= 1, num <= demoTabs.count {
                state.withLock {
                    $0.activeTab = num - 1
                    $0.focusZone = 0
                    $0.lastEvent = "Tab \(num): \(demoTabs[num - 1].name)"
                }
                rebuild()
            }
        case "i":
            state.withLock {
                if $0.activeTab == 0 {
                    $0.focusZone = 1
                    $0.lastEvent = "Editing URL / QR input (press Enter or Esc when done)"
                } else if $0.activeTab == 3 {
                    $0.qrInverted.toggle()
                    $0.lastEvent = "QR inverted = \($0.qrInverted)"
                }
            }
            rebuild()
        case "/":
            state.withLock {
                $0.activeTab = 0
                $0.focusZone = 1
                $0.lastEvent = "Focused URL / QR input (Esc to leave)"
            }
            rebuild()
        case "v":
            if snap.activeTab == 1 {
                state.withLock {
                    $0.diffView = ($0.diffView == .unified) ? .split : .unified
                    $0.lastEvent = "Diff mode: \($0.diffView.rawValue)"
                }
                rebuild()
            }
        case "left", "-":
            if snap.activeTab == 0 {
                state.withLock {
                    $0.sliderValue = max(0, $0.sliderValue - 5)
                    $0.lastEvent = "Intensity: \(Int($0.sliderValue))%"
                }
                rebuild()
            }
        case "right", "=", "+":
            if snap.activeTab == 0 {
                state.withLock {
                    $0.sliderValue = min(100, $0.sliderValue + 5)
                    $0.lastEvent = "Intensity: \(Int($0.sliderValue))%"
                }
                rebuild()
            }
        default:
            state.withLock { $0.lastEvent = "Key: \(key.name)" }
            rebuild()
        }
    }

    viewRoot.render {
        let snap = state.withLock { $0 }
        let palette = palettes[snap.paletteIndex]
        let meterPct = Int(snap.sliderValue.rounded())
        let barFilled = max(0, min(20, meterPct / 5))
        let meterBar = String(repeating: "█", count: barFilled) + String(repeating: "░", count: 20 - barFilled)

        VStack(spacing: 0) {
            // Header + Tab Bar
            TUIBox(
                border: true,
                borderStyle: .rounded,
                borderColor: Color.string(palette.primary),
                title: " swift-opentui • 100.0% Parity Interactive Demo ",
                titleColor: Color.string(palette.primary),
                bottomTitle: " \(snap.cols)×\(snap.rows) • Tab/1-4: Views • q/Ctrl+C: Quit "
            ) {
                TUITabSelect(
                    options: demoTabs,
                    selectedIndex: snap.activeTab,
                    tabWidth: max(14, (snap.cols - 6) / 4),
                    showDescription: true,
                    showUnderline: true,
                    selectedTextColor: Color.string("#0f172a"),
                    selectedBackgroundColor: Color.string(palette.primary),
                    onChange: { idx, opt in
                        state.withLock {
                            $0.activeTab = idx
                            $0.focusZone = 0
                            $0.lastEvent = "Tab: \(opt?.name ?? "\(idx + 1)")"
                        }
                        rebuild()
                    },
                    onSelect: { idx, opt in
                        state.withLock {
                            $0.activeTab = idx
                            $0.lastEvent = "Selected tab: \(opt.name)"
                        }
                        rebuild()
                    }
                )
                .key("demo-tabs")
                .width(.percent(100))
            }
            .width(.percent(100))
            .height(5)

            // Main Body by Tab
            if snap.activeTab == 0 {
                VStack(spacing: 1) {
                    TUIBox(
                        border: true,
                        borderStyle: .single,
                        borderColor: Color.string(palette.secondary),
                        title: " Pure Swift 6.2 Terminal UI Engine "
                    ) {
                        HStack(spacing: 2) {
                            TUIASCIIFont("OPENTUI", font: .tiny, color: Color.string(palette.primary))
                            VStack(spacing: 0) {
                                TUIText("3,159/3,159 Functions (100.0%)", fg: Color.string("#34d399"), attributes: createTextAttributes(bold: true))
                                TUIText("5,679/5,679 Symbols (100.0%) • 506 Swift Tests", fg: Color.string(palette.muted))
                                TUIText("91/91 Live Differential Oracle Functions PASS", fg: Color.string(palette.secondary))
                            }
                        }
                    }
                    .width(.percent(100))
                    .height(5)

                    HStack(spacing: 1) {
                        TUIBox(
                            border: true,
                            borderStyle: .rounded,
                            borderColor: Color.string(snap.focusZone == 0 ? palette.primary : palette.muted),
                            title: " Accent Theme (↑/↓ or click) "
                        ) {
                            TUISelect(
                                options: themeOptions,
                                selectedIndex: snap.paletteIndex,
                                wrapSelection: true,
                                showDescription: true,
                                selectedTextColor: Color.string("#0f172a"),
                                selectedBackgroundColor: Color.string(palette.primary),
                                onChange: { idx, opt in
                                    state.withLock {
                                        $0.paletteIndex = idx
                                        $0.lastEvent = "Theme: \(opt?.name ?? palettes[idx].name)"
                                    }
                                    rebuild()
                                },
                                onSelect: { idx, opt in
                                    state.withLock {
                                        $0.paletteIndex = idx
                                        $0.lastEvent = "Locked theme: \(opt.name)"
                                    }
                                    rebuild()
                                }
                            )
                            .key("theme-select")
                            .width(.percent(100))
                            .height(8)
                            .focused(snap.focusZone == 0)
                        }
                        .width(.percent(48))
                        .height(10)

                        VStack(spacing: 1) {
                            TUIBox(
                                border: true,
                                borderStyle: .rounded,
                                borderColor: Color.string(snap.focusZone == 1 ? palette.primary : palette.muted),
                                title: " QR / Text Input (press 'i' or '/') "
                            ) {
                                VStack(spacing: 1) {
                                    TUIInput(
                                        value: snap.qrInputText,
                                        placeholder: "Type text for Tab 4 QR Code...",
                                        maxLength: 80,
                                        onInput: { val in
                                            state.withLock {
                                                $0.qrInputText = val
                                                $0.lastEvent = "Input (\(val.count) chars)"
                                            }
                                            rebuild()
                                        },
                                        onSubmit: { val in
                                            state.withLock {
                                                $0.qrInputText = val
                                                $0.focusZone = 0
                                                $0.lastEvent = "Saved QR payload: \(val)"
                                            }
                                            rebuild()
                                        }
                                    )
                                    .key("qr-input")
                                    .width(.percent(100))
                                    .focused(snap.focusZone == 1)

                                    TUIText("Payload: \(snap.qrInputText)", fg: Color.string(palette.muted))
                                }
                            }
                            .width(.percent(100))
                            .height(5)

                            TUIBox(
                                border: true,
                                borderStyle: .rounded,
                                borderColor: Color.string(palette.secondary),
                                title: " Slider (click/drag or ←/→) "
                            ) {
                                VStack(spacing: 1) {
                                    TUISlider(
                                        min: 0,
                                        max: 100,
                                        value: snap.sliderValue,
                                        orientation: .horizontal,
                                        onChange: { val in
                                            state.withLock {
                                                $0.sliderValue = val
                                                $0.lastEvent = "Slider: \(Int(val.rounded()))%"
                                            }
                                            rebuild()
                                        }
                                    )
                                    .key("demo-slider")
                                    .width(.percent(100))
                                    .height(1)

                                    TUIText("Level: \(meterBar) \(meterPct)%", fg: Color.string(palette.primary))
                                }
                            }
                            .width(.percent(100))
                            .height(5)
                        }
                        .width(.percent(50))
                    }
                    .width(.percent(100))
                    .flexGrow(1)
                }
                .flexGrow(1)
                .padding(top: 1, right: 0, bottom: 0, left: 0)
            } else if snap.activeTab == 1 {
                VStack(spacing: 1) {
                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.primary),
                        title: " Syntax-Highlighted Swift Code (BuiltInSyntaxHighlighter) "
                    ) {
                        TUICode(sampleSwiftCode, filetype: "swift", syntaxStyle: syntaxStyle)
                            .key("demo-code")
                            .width(.percent(100))
                    }
                    .width(.percent(100))
                    .flexGrow(1)

                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.secondary),
                        title: " DiffRenderable [\(snap.diffView.rawValue.uppercased())] — press 'v' to toggle Unified / Split "
                    ) {
                        TUIDiff(
                            sampleUnifiedDiff,
                            view: snap.diffView,
                            filetype: "swift",
                            syntaxStyle: syntaxStyle,
                            showLineNumbers: true,
                            showWordDiff: true
                        )
                        .key("demo-diff")
                        .width(.percent(100))
                        .flexGrow(1)
                    }
                    .width(.percent(100))
                    .flexGrow(1)
                }
                .flexGrow(1)
                .padding(top: 1, right: 0, bottom: 0, left: 0)
            } else if snap.activeTab == 2 {
                HStack(spacing: 1) {
                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.primary),
                        title: " MarkdownRenderable (CommonMark + GFM) "
                    ) {
                        TUIMarkdown(sampleMarkdown, syntaxStyle: syntaxStyle)
                            .key("demo-markdown")
                            .width(.percent(100))
                    }
                    .flexGrow(1)

                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.secondary),
                        title: " TextTableRenderable (100% Parity Matrix) "
                    ) {
                        TUITable(
                            rows: parityRows,
                            showBorders: true,
                            borderStyle: .rounded,
                            borderColor: Color.string(palette.muted),
                            columnWidthMode: .content
                        )
                        .key("demo-table")
                        .width(.percent(100))
                    }
                    .flexGrow(1)
                }
                .flexGrow(1)
                .padding(top: 1, right: 0, bottom: 0, left: 0)
            } else {
                HStack(spacing: 2) {
                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.primary),
                        title: " Live QRCodeRenderable ('i' invert) "
                    ) {
                        TUIQRCode(
                            snap.qrInputText.isEmpty ? "https://github.com/anomalyco/opentui" : snap.qrInputText,
                            ecl: .M,
                            fg: Color.string(palette.primary),
                            bg: Color.string("#0f172a"),
                            quietZone: 4,
                            fit: QRCodeFitMode.none,
                            invert: snap.qrInverted
                        )
                        .key("demo-qr")
                    }
                    .width(42)

                    TUIBox(
                        border: true,
                        borderStyle: .rounded,
                        borderColor: Color.string(palette.secondary),
                        title: " QR Details "
                    ) {
                        VStack(spacing: 1) {
                            TUIText("Payload:", fg: Color.string(palette.muted))
                            TUIText(snap.qrInputText, fg: Color.string(palette.primary), attributes: createTextAttributes(bold: true))
                            TUIText("Inverted: \(snap.qrInverted ? "Yes" : "No") (press 'i' to toggle)", fg: Color.string(palette.muted))
                            TUIText("Press '/' to jump back to Tab 1 and edit the encoded text live!", fg: Color.string("#34d399"))
                            TUIText("Supports Numeric, Alphanumeric, UTF-8 Byte, and full Shift JIS Kanji (6,944-entry table).", fg: Color.string(palette.muted))
                        }
                    }
                    .flexGrow(1)
                }
                .width(.percent(100))
                .flexGrow(1)
                .padding(top: 1, right: 0, bottom: 0, left: 0)
            }

            // Footer Status Bar
            TUIBox(
                border: false,
                backgroundColor: Color.string("#1e293b"),
                shouldFill: true
            ) {
                HStack(spacing: 2) {
                    TUIText(" ● \(snap.lastEvent)", fg: Color.string(palette.primary))
                    TUISpacer()
                    TUIText("1-4 Tabs • Tab Next • q Quit ", fg: Color.string(palette.muted))
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

// MARK: - Entrypoint

@main
struct OpenTUIDemoMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if let snapIdx = args.firstIndex(of: "--snapshot") {
            let tabArg = (snapIdx + 1 < args.count) ? Int(args[snapIdx + 1]) : nil
            let initialTab = max(0, min(demoTabs.count - 1, (tabArg ?? 1) - 1))
            runSnapshot(tab: initialTab)
            return
        }

        let backend = PlatformTerminalBackend(defaultSize: TerminalSize(width: 100, height: 30))
        guard backend.isInteractiveTerminal else {
            // Friendly non-TTY fallback so running from pipes/scripts still previews cleanly!
            print("opentui-demo: stdin/stdout is not an interactive TTY — rendering Tab 1 preview (--snapshot):\n")
            runSnapshot(tab: 0)
            return
        }

        let initialSize = await backend.size
        let state = DemoStore(DemoState(cols: initialSize.width, rows: initialSize.height))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: initialSize.width,
                height: initialSize.height,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: true,
                clock: ManualClock()
            )
        )
        let syntaxStyle = makeDemoSyntaxStyle()

        do {
            try await runWithTerminalBackend(
                renderer: renderer,
                backend: backend,
                options: TerminalBackendRunOptions(
                    enterRawMode: true,
                    manageTerminalModes: true,
                    initialRender: false,
                    destroyOnExit: true,
                    enableMouseMovement: true
                )
            ) { liveRenderer, session in
                let viewRoot = mountDemoApp(
                    on: liveRenderer,
                    state: state,
                    syntaxStyle: syntaxStyle,
                    onRequestQuit: {
                        state.withLock { $0.shouldQuit = true }
                    }
                )
                defer { viewRoot.unmount() }

                await session.renderNow(force: true)

                var lastSize = initialSize
                while !state.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
                    // Check for terminal window resize
                    let currentSize = await backend.size
                    if currentSize != lastSize {
                        lastSize = currentSize
                        state.withLock {
                            $0.cols = currentSize.width
                            $0.rows = currentSize.height
                            $0.lastEvent = "Resized to \(currentSize.width)×\(currentSize.height)"
                        }
                        _ = await session.syncSize()
                        viewRoot.invalidate()
                        await session.renderNow(force: true)
                    }

                    // Poll raw terminal input (non-blocking 16ms tick -> ~60 FPS responsive)
                    let bytes = (try? backend.pollRead(maxBytes: 4096, timeoutMs: 16)) ?? []
                    if !bytes.isEmpty {
                        session.feedInput(bytes)
                        if !state.withLock({ $0.shouldQuit }) && !liveRenderer.isDestroyed {
                            await session.renderNow(force: false)
                        }
                    } else {
                        await Task.yield()
                    }
                }
            }
        } catch {
            print("opentui-demo error: \(error)")
        }
    }

    private static func runSnapshot(tab: Int) {
        let test = createTestRenderer(width: 100, height: 28)
        defer { test.destroy() }
        let state = DemoStore(DemoState(activeTab: tab, cols: 100, rows: 28))
        let syntaxStyle = makeDemoSyntaxStyle()
        let root = mountDemoApp(on: test.renderer, state: state, syntaxStyle: syntaxStyle, onRequestQuit: {})
        test.renderOnce(force: true)
        print(test.captureCharFrame())
        root.unmount()
    }
}
