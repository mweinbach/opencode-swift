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
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView

/// Recorded HTTP request captured by `P4MockServer` for asserting wire payloads in Swift Testing.
struct P4RecordedRequest: Equatable, Sendable {
    let method: String
    let url: String
    let body: String
}

/// Configurable mock OpenCode server transport recording every outgoing HTTP request.
final class P4MockServer: Sendable {
    private let requestsStore = Mutex<[P4RecordedRequest]>([])
    private let inboxItemsStore = Mutex<[P4InboxMockItem]>([])
    private let nextIDCounter = Mutex<Int>(1)

    struct P4InboxMockItem: Equatable, Sendable {
        var id: String
        var sessionID: String
        var text: String
        var delivery: String
    }

    init(initialInbox: [P4InboxMockItem] = []) {
        inboxItemsStore.withLock { $0 = initialInbox }
    }

    func recordedRequests() -> [P4RecordedRequest] {
        requestsStore.withLock { $0 }
    }

    func clearRequests() {
        requestsStore.withLock { $0 = [] }
    }

    func setInboxItems(_ items: [P4InboxMockItem]) {
        inboxItemsStore.withLock { $0 = items }
    }

    func makeTransport() -> MockHTTPTransport {
        MockHTTPTransport { [weak self] req in
            guard let self else {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 500, headers: [:]), body: [])
            }
            let bodyStr = String(decoding: req.body ?? [], as: UTF8.self)
            self.requestsStore.withLock {
                $0.append(P4RecordedRequest(method: req.method, url: req.url, body: bodyStr))
            }

            // POST /api/session/:id/prompt
            if req.method == "POST", req.url.contains("/api/session/"), req.url.hasSuffix("/prompt") {
                let seq = self.nextIDCounter.withLock { c -> Int in
                    let v = c
                    c += 1
                    return v
                }
                let msgID = "msg_p4_\(seq)"
                let sid = Self.extractSessionID(from: req.url) ?? "ses_demo01"
                let delivery = bodyStr.contains("\"queue\"") ? "queue" : "steer"
                let decodedText = Self.extractJSONStringField(bodyStr, key: "text") ?? ""
                if delivery == "queue" {
                    self.inboxItemsStore.withLock {
                        $0.append(P4InboxMockItem(id: msgID, sessionID: sid, text: decodedText, delivery: delivery))
                    }
                }
                let json = """
                {"data":{"id":"\(msgID)","sessionID":"\(sid)","time":{"created":1700000000000},"type":"user","payload":{"text":\(Self.jsonEscape(decodedText))},"delivery":"\(delivery)"}}
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            // GET /api/session/:id/inbox
            if req.method == "GET", req.url.contains("/api/session/"), req.url.hasSuffix("/inbox") {
                let sid = Self.extractSessionID(from: req.url) ?? "ses_demo01"
                let items = self.inboxItemsStore.withLock { list in
                    list.filter { $0.sessionID == sid }
                }
                let serialized = items.map { item in
                    """
                    {"id":"\(item.id)","sessionID":"\(item.sessionID)","time":{"created":1700000000000},"type":"user","payload":{"text":\(Self.jsonEscape(item.text))},"delivery":"\(item.delivery)"}
                    """
                }.joined(separator: ",")
                let json = "{\"data\":[\(serialized)]}"
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            // DELETE /api/session/:id/inbox/:inboxID
            if req.method == "DELETE", req.url.contains("/inbox/") {
                if let last = req.url.split(separator: "/").last.map(String.init) {
                    self.inboxItemsStore.withLock { list in
                        list.removeAll { $0.id == last }
                    }
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }

            // PATCH /api/session/:id/inbox/:inboxID
            if req.method == "PATCH", req.url.contains("/inbox/") {
                if let last = req.url.split(separator: "/").last.map(String.init) {
                    let nextDelivery = bodyStr.contains("\"steer\"") ? "steer" : "queue"
                    self.inboxItemsStore.withLock { list in
                        if let idx = list.firstIndex(where: { $0.id == last }) {
                            list[idx].delivery = nextDelivery
                        }
                    }
                }
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }

            // POST /api/pty
            if req.method == "POST", req.url.contains("/api/pty") {
                let seq = self.nextIDCounter.withLock { c -> Int in
                    let v = c
                    c += 1
                    return v
                }
                let ptyID = "pty_test_\(seq)"
                let json = """
                {"location":{"directory":"/workspace"},"data":{"id":"\(ptyID)","title":"zsh","command":"/bin/zsh","args":[],"cwd":"/workspace","status":"running","pid":4242}}
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            // DELETE /api/pty/:id
            if req.method == "DELETE", req.url.contains("/api/pty/") {
                return HTTPResponse(head: HTTPResponseHead(statusCode: 204, headers: [:]), body: [])
            }

            // POST /api/shell
            if req.method == "POST", req.url.contains("/api/shell") {
                let seq = self.nextIDCounter.withLock { c -> Int in
                    let v = c
                    c += 1
                    return v
                }
                let shID = "sh_test_\(seq)"
                let cmd = Self.extractJSONStringField(bodyStr, key: "command") ?? "echo ok"
                let json = """
                {"location":{"directory":"/workspace"},"data":{"id":"\(shID)","status":"exited","command":\(Self.jsonEscape(cmd)),"cwd":"/workspace","shell":"/bin/zsh","file":"/tmp/out.log","pid":9001,"exit":0,"metadata":{},"time":{"started":1700000000000,"completed":1700000000100}}}
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            // GET /api/shell/:id/output
            if req.method == "GET", req.url.contains("/api/shell/"), req.url.contains("/output") {
                let json = """
                {"location":{"directory":"/workspace"},"data":{"output":"hello from embedded terminal\\nline two","cursor":38,"size":38,"truncated":false}}
                """
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            // GET /api/session/:id/message or /api/session/:id
            if req.method == "GET", req.url.contains("/message") {
                let json = "{\"data\":[],\"hasMore\":false}"
                return HTTPResponse(
                    head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "application/json"]),
                    body: Array(json.utf8)
                )
            }

            return HTTPResponse(head: HTTPResponseHead(statusCode: 404, headers: [:]), body: [])
        }
    }

    private static func extractSessionID(from url: String) -> String? {
        guard let range = url.range(of: "/api/session/") else { return nil }
        let tail = url[range.upperBound...]
        return tail.split(separator: "/").first.map(String.init)
    }

    private static func extractJSONStringField(_ body: String, key: String) -> String? {
        guard let data = body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .string(let val) = decoded[key]
        else {
            return nil
        }
        return val
    }

    private static func jsonEscape(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Interactive test harness for P4 tests (kept free of `import Testing` to respect macOS CLT cross-import rules).
final class P4InteractiveHarness: @unchecked Sendable {
    let testRenderer: TestRenderer
    let store: TUIInteractiveStore
    let mockServer: P4MockServer
    let client: OpenCodeClient
    let controller: TUIInteractiveClient
    let viewRoot: TUIViewRoot

    init(
        width: Int = 100,
        height: Int = 34,
        state: TUIInteractiveState,
        kittyKeyboard: Bool = false,
        mockServer: P4MockServer = P4MockServer()
    ) {
        let resolvedTheme = state.resolveTheme()
        self.testRenderer = createTestRenderer(
            width: width,
            height: height,
            kittyKeyboard: kittyKeyboard,
            backgroundColor: resolvedTheme.background.base
        )
        self.store = TUIInteractiveStore(state)
        self.mockServer = mockServer
        self.client = OpenCodeClient(options: ClientOptions(
            baseUrl: state.serverURL,
            transport: mockServer.makeTransport()
        ))
        let rootBox = RootBox()
        self.controller = TUIInteractiveClient(
            client: client,
            store: store,
            directory: state.directory,
            markDirty: {
                rootBox.invalidate()
            }
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

    func lines() -> [String] {
        frame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func cellBackground(x: Int, y: Int) -> RGBA? {
        render()
        return testRenderer.renderer.currentRenderBuffer.cell(atX: x, y: y)?.background
    }

    func pressLeader(_ key: String) {
        testRenderer.mockInput.pressKey("x", modifiers: MockKeyModifiers(ctrl: true))
        testRenderer.mockInput.pressKey(key)
        render()
    }

    func pressLeaderReturn() {
        testRenderer.mockInput.pressKey("x", modifiers: MockKeyModifiers(ctrl: true))
        testRenderer.mockInput.pressReturn()
        render()
    }

    func pressLeaderArrow(_ direction: ScrollDirection) {
        testRenderer.mockInput.pressKey("x", modifiers: MockKeyModifiers(ctrl: true))
        testRenderer.mockInput.pressArrow(direction)
        render()
    }

    func pressEscapeAndFlush() {
        testRenderer.mockInput.pressEscape()
        testRenderer.mockInput.flushTimeouts()
        render()
    }

    @discardableResult
    func clickRenderable(id: String) -> Bool {
        render()
        guard let node = testRenderer.root.findDescendantById(id) else { return false }
        let cx = node.x + max(0, node.width / 2)
        let cy = node.y + max(0, node.height / 2)
        testRenderer.mockMouse.click(x: cx, y: cy)
        render()
        return true
    }

    @discardableResult
    func clickText(_ needle: String) -> Bool {
        let rows = lines()
        for (y, row) in rows.enumerated() {
            if let range = row.range(of: needle) {
                let prefix = String(row[..<range.lowerBound])
                let x = prefix.count + max(0, needle.count / 2)
                testRenderer.mockMouse.click(x: x, y: y)
                render()
                return true
            }
        }
        return false
    }

    func waitUntil(timeoutMs: Int = 1_500, condition: @Sendable () -> Bool) async -> Bool {
        let stepMs = 15
        let attempts = max(1, timeoutMs / stepMs)
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return condition()
    }

    func destroy() {
        viewRoot.unmount()
        testRenderer.destroy()
    }
}

enum P4Fixtures {
    static func makeHomeState(
        width: Int = 100,
        height: Int = 34,
        mode: ThemeMode = .light,
        pasteSummary: Bool = false
    ) -> TUIInteractiveState {
        var state = TUIInteractiveLoop.makeDefaultPreviewState(
            width: width,
            height: height,
            route: .home(TUIContext.HomeRoute()),
            mode: mode
        )
        state.preferences.pasteSummary = pasteSummary
        return state
    }

    static func makeSessionState(
        width: Int = 110,
        height: Int = 34,
        mode: ThemeMode = .light,
        running: Bool = false,
        openTabs: [String]? = nil,
        extraSessions: [TUISessionItem] = []
    ) -> TUIInteractiveState {
        var state = TUIInteractiveLoop.makeDefaultPreviewState(
            width: width,
            height: height,
            route: .session(TUIContext.SessionRoute(sessionID: "ses_demo01")),
            mode: mode
        )
        state.sessionStatus = running ? .running : .idle
        if !extraSessions.isEmpty {
            state.sessions.append(contentsOf: extraSessions)
        }
        if let openTabs {
            state.openSessionTabs = openTabs
        }
        return state
    }

    static func makeEvent(type: String, data: [String: JSONValue]) -> OpenCodeEvent {
        OpenCodeEvent(id: "evt_p4", type: type, data: .object(data))
    }
}
