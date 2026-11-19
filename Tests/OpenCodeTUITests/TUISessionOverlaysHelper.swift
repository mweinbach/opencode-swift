import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView

/// Test harness & fixtures for `TUISessionOverlaysTests`
/// (kept free of `import Testing` to respect macOS CLT cross-import rules).
final class OverlayRenderHarness {
    let testRenderer: TestRenderer
    let viewRoot: TUIViewRoot
    let width: Int
    let height: Int
    let theme: ResolvedTheme

    init(
        width: Int = 100,
        height: Int = 34,
        mode: ThemeMode = .light,
        view: @escaping () -> AnyTUIView
    ) {
        let resolvedTheme = ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode, mode: mode)
        self.width = width
        self.height = height
        self.theme = resolvedTheme
        self.testRenderer = createTestRenderer(
            width: width,
            height: height,
            kittyKeyboard: false,
            backgroundColor: resolvedTheme.background.base
        )
        self.viewRoot = TUIViewRoot(testRenderer: testRenderer)
        self.viewRoot.render {
            ZStack(alignment: .stretch, justify: .flexStart) {
                TUIBox(
                    border: false,
                    backgroundColor: .rgba(resolvedTheme.background.base),
                    shouldFill: true
                ) {
                    view()
                }
                .width(.percent(100))
                .height(.percent(100))
            }
            .width(.percent(100))
            .height(.percent(100))
        }
        render()
    }

    func render(force: Bool = true) {
        viewRoot.invalidate()
        testRenderer.renderOnce(force: force)
    }

    func frame() -> String {
        render()
        return testRenderer.captureCharFrame()
    }

    func lines() -> [String] {
        frame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func collapsedText() -> String {
        frame()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    func cellBackground(x: Int, y: Int) -> RGBA? {
        render()
        return testRenderer.renderer.currentRenderBuffer.cell(atX: x, y: y)?.background
    }

    func cellForeground(x: Int, y: Int) -> RGBA? {
        render()
        return testRenderer.renderer.currentRenderBuffer.cell(atX: x, y: y)?.foreground
    }

    func cellScalar(x: Int, y: Int) -> UInt32? {
        render()
        return testRenderer.renderer.currentRenderBuffer.cell(atX: x, y: y)?.scalar
    }

    func findChar(_ ch: Character, onLineContaining needle: String) -> (x: Int, y: Int)? {
        let rows = lines()
        guard let y = rows.firstIndex(where: { $0.contains(needle) }),
              let colIdx = rows[y].firstIndex(of: ch)
        else { return nil }
        let x = rows[y].distance(from: rows[y].startIndex, to: colIdx)
        return (x, y)
    }

    func findSubstring(_ needle: String) -> (x: Int, y: Int)? {
        let rows = lines()
        for (y, row) in rows.enumerated() {
            if let range = row.range(of: needle) {
                let x = row.distance(from: row.startIndex, to: range.lowerBound)
                return (x, y)
            }
        }
        return nil
    }

    func destroy() {
        viewRoot.unmount()
        testRenderer.destroy()
    }
}

enum TUISessionOverlaysFixtures {
    static func theme(mode: ThemeMode) -> ResolvedTheme {
        ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode, mode: mode)
    }

    static func syntaxStyle(mode: ThemeMode) -> SyntaxStyle {
        generateSyntax(theme(mode: mode))
    }

    static let sampleSwiftPatch: String = """
    --- a/Sources/App/Greeter.swift
    +++ b/Sources/App/Greeter.swift
    @@ -1,3 +1,4 @@
     struct Greeter {
    -    func greet() -> String { "hello" }
    +    func greet(name: String) -> String { "hello, \\(name)" }
    +    let version = 2
     }
    """

    static let sampleSecondPatch: String = """
    --- a/README.md
    +++ b/README.md
    @@ -1,2 +1,3 @@
     # OpenCode
    -Draft documentation
    +Production Swift 6.2 port
    +Cross-platform TUI overlays
    """

    static func shellPermissionRequest() -> TUIPendingPermissionItem {
        TUIPendingPermissionItem(
            id: "perm_shell_01",
            sessionID: "ses_demo01",
            permission: "shell",
            patterns: ["git status", "swift test"],
            alwaysPatterns: ["swift test *", "git *"],
            toolName: "shell",
            commandPreview: "swift test --filter OpenCodeTUITests"
        )
    }

    static func editPermissionRequest() -> TUIPendingPermissionItem {
        TUIPendingPermissionItem(
            id: "perm_edit_02",
            sessionID: "ses_demo01",
            permission: "edit",
            patterns: ["Sources/App/Greeter.swift"],
            alwaysPatterns: ["Sources/App/*"],
            toolName: "edit",
            filePath: "Sources/App/Greeter.swift",
            diffPatch: sampleSwiftPatch
        )
    }

    static func singleSelectForm() -> TUIPendingFormItem {
        TUIPendingFormItem(
            id: "form_single_01",
            sessionID: "ses_demo01",
            title: "Deployment Target",
            message: "Choose where to publish this release.",
            fields: [
                TUIFormFieldItem(
                    key: "target",
                    label: "Environment",
                    description: "Select deployment environment",
                    kind: .singleSelect([
                        TUIFormOptionItem(label: "Staging", value: "staging", description: "Internal QA cluster"),
                        TUIFormOptionItem(label: "Production", value: "prod", description: "Live customer traffic"),
                    ]),
                    allowCustom: true,
                    required: true
                ),
            ]
        )
    }

    static func multiFieldForm() -> TUIPendingFormItem {
        TUIPendingFormItem(
            id: "form_multi_02",
            sessionID: "ses_demo01",
            title: "Project Setup",
            message: "Configure scaffolding options before generating files.",
            fields: [
                TUIFormFieldItem(
                    key: "framework",
                    label: "Framework",
                    description: "Pick primary framework",
                    kind: .singleSelect([
                        TUIFormOptionItem(label: "SwiftPM", value: "swiftpm"),
                        TUIFormOptionItem(label: "Vapor", value: "vapor"),
                    ]),
                    required: true
                ),
                TUIFormFieldItem(
                    key: "features",
                    label: "Features",
                    description: "Toggle optional capabilities",
                    kind: .multiSelect([
                        TUIFormOptionItem(label: "Swift Testing", value: "testing", description: "Modern test runner"),
                        TUIFormOptionItem(label: "Strict Concurrency", value: "concurrency"),
                        TUIFormOptionItem(label: "CLI Entrypoint", value: "cli"),
                    ]),
                    allowCustom: true,
                    required: true
                ),
                TUIFormFieldItem(
                    key: "notes",
                    label: "Notes",
                    description: "Additional instructions",
                    kind: .text(placeholder: "Enter release notes…"),
                    required: false
                ),
                TUIFormFieldItem(
                    key: "ci",
                    label: "Enable CI",
                    description: "Generate GitHub Actions workflow?",
                    kind: .boolean,
                    required: true
                ),
            ]
        )
    }

    static func sampleDiffViewerState(
        splitView: Bool = false,
        fullscreen: Bool = false,
        showFileTree: Bool = true
    ) -> TUIDiffViewerState {
        TUIDiffViewerState(
            title: "Diff Viewer",
            files: [
                TUIDiffFileEntry(
                    path: "Sources/App/Greeter.swift",
                    additions: 2,
                    deletions: 1,
                    status: "modified",
                    patch: sampleSwiftPatch
                ),
                TUIDiffFileEntry(
                    path: "README.md",
                    additions: 2,
                    deletions: 1,
                    status: "added",
                    patch: sampleSecondPatch
                ),
            ],
            selectedFileIndex: 0,
            splitView: splitView,
            fullscreen: fullscreen,
            showFileTree: showFileTree,
            wrapLines: true
        )
    }

    static func samplePairingInfo() -> TUIPairingInfo {
        TUIPairingInfo(
            links: ["http://192.168.1.42:4096/auth/connect/PAIR99"],
            localhostURL: "http://localhost:4096/auth/connect/PAIR99",
            expiresInMinutes: 10,
            isLoopbackOnly: true
        )
    }

    static func expectedQRLines(for url: String) -> [String] {
        guard let rendered = try? QR.renderUnicodeCompact(url, border: 1) else { return [] }
        return rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func sampleStatusSnapshot() -> TUIStatusSnapshot {
        TUIStatusSnapshot(
            serverURL: "http://127.0.0.1:4096",
            serverVersion: "2.3.2",
            directory: "/workspace/swift-opencode",
            gitBranch: "main",
            connectedProvidersCount: 3,
            totalModelsCount: 14,
            mcpServers: [
                TUIMCPServerItem(name: "github", status: .connected),
                TUIMCPServerItem(name: "postgres", status: .failed("connection refused")),
                TUIMCPServerItem(name: "linear", status: .needsAuth("OAuth token expired")),
                TUIMCPServerItem(name: "sentry", status: .disabled),
            ],
            skillsCount: 5,
            commandsCount: 18
        )
    }

    static func sampleUsageRows() -> [TUIUsageLimitRow] {
        [
            TUIUsageLimitRow(
                modelID: "anthropic/claude-sonnet-4-5",
                modelName: "Claude Sonnet 4.5",
                providerName: "Anthropic",
                scopeLabel: "Workspace monthly cap",
                spentDollars: 7.50,
                limitDollars: 20.00,
                resetsLabel: "5:00 PM today"
            ),
            TUIUsageLimitRow(
                modelID: "openai/gpt-5.3-codex",
                modelName: "GPT-5.3 Codex",
                providerName: "OpenAI",
                scopeLabel: "Daily limit",
                spentDollars: 10.00,
                limitDollars: 10.00,
                resetsLabel: "12:00 AM tomorrow",
                isReached: true
            ),
        ]
    }

    static func sampleDebugSnapshot(
        sseConnected: Bool = true,
        sseReconnecting: Bool = false
    ) -> TUIDebugSnapshot {
        TUIDebugSnapshot(
            serverURL: "http://127.0.0.1:4096",
            serverVersion: "2.3.2",
            sessionID: "ses_debug_99",
            sseConnected: sseConnected,
            sseReconnecting: sseReconnecting,
            terminalCols: 120,
            terminalRows: 40,
            themeName: "opencode",
            themeMode: .dark,
            kittyKeyboardFlags: 3,
            providersCount: 3,
            modelsCount: 14,
            agentsCount: 4,
            commandsCount: 18,
            skillsCount: 5,
            toolsCount: 22
        )
    }

    static func sampleTodoItems() -> [TUITodoItem] {
        [
            TUITodoItem(id: "t1", content: "Port permission prompt", status: .completed),
            TUITodoItem(id: "t2", content: "Verify diff viewer split mode", status: .inProgress),
            TUITodoItem(id: "t3", content: "Run full parity audit", status: .pending),
            TUITodoItem(id: "t4", content: "Deprecated legacy widget", status: .cancelled),
        ]
    }
}
