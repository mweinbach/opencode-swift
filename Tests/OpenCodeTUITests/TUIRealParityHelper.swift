import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView

/// Test harness helper (kept free of `import Testing` to respect macOS CLT cross-import rules).
final class TUIRealParityHarness {
    let testRenderer: TestRenderer
    let store: TUIInteractiveStore
    let transport: MockHTTPTransport
    let client: OpenCodeClient
    let controller: TUIInteractiveClient
    let viewRoot: TUIViewRoot

    init(
        width: Int = 100,
        height: Int = 34,
        state: TUIInteractiveState,
        kittyKeyboard: Bool = false,
        transport: MockHTTPTransport = MockHTTPTransport()
    ) {
        let resolvedTheme = state.resolveTheme()
        self.testRenderer = createTestRenderer(
            width: width,
            height: height,
            kittyKeyboard: kittyKeyboard,
            backgroundColor: resolvedTheme.background.base
        )
        self.store = TUIInteractiveStore(state)
        self.transport = transport
        self.client = OpenCodeClient(options: ClientOptions(
            baseUrl: state.serverURL,
            transport: transport
        ))
        let rootBox = RootBox()
        self.controller = TUIInteractiveClient(
            client: client,
            store: store,
            directory: state.directory,
            markDirty: {}
        )
        self.viewRoot = TUIInteractiveLoop.mountInteractiveView(
            on: testRenderer.renderer,
            store: store,
            clientController: controller,
            markDirty: {
                rootBox.invalidate()
            }
        )
        rootBox.set(viewRoot)
        render()
    }

    private final class RootBox: @unchecked Sendable {
        private var root: TUIViewRoot?
        func set(_ r: TUIViewRoot) { root = r }
        func invalidate() { root?.invalidate() }
    }

    func render(force: Bool = true) {
        viewRoot.invalidate()
        testRenderer.renderOnce(force: force)
    }

    func frame() -> String {
        render()
        return testRenderer.captureCharFrame()
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

    func pressEscapeAndFlush() {
        testRenderer.mockInput.pressEscape()
        testRenderer.mockInput.flushTimeouts()
        render()
    }

    func destroy() {
        viewRoot.unmount()
        testRenderer.destroy()
    }
}

enum TUIRealParityFixtures {
    static func makeHomeState(
        width: Int = 100,
        height: Int = 34,
        mode: ThemeMode = .light,
        mcpServers: [TUIMCPServerItem]? = nil
    ) -> TUIInteractiveState {
        var state = TUIInteractiveLoop.makeDefaultPreviewState(
            width: width,
            height: height,
            route: .home(TUIContext.HomeRoute()),
            mode: mode
        )
        if let mcpServers {
            state.mcpServers = mcpServers
        }
        return state
    }

    static func makeSessionState(
        width: Int = 124,
        height: Int = 34,
        mode: ThemeMode = .light,
        running: Bool = false
    ) -> TUIInteractiveState {
        var state = TUIInteractiveLoop.makeDefaultPreviewState(
            width: width,
            height: height,
            route: .session(TUIContext.SessionRoute(sessionID: "ses_demo01")),
            mode: mode
        )
        state.sessionStatus = running ? .running : .idle
        return state
    }

    static func makeEvent(type: String, data: [String: JSONValue]) -> OpenCodeEvent {
        OpenCodeEvent(id: "evt_test", type: type, data: .object(data))
    }
}
