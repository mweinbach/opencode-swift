import Foundation
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUIRenderables
import OpenTUIView

/// Test harness and fixture helpers for live OAuth & Models catalog TUI tests.
/// Kept free of `import Testing` to respect macOS Command Line Tools cross-import rules.
final class TUILiveOAuthHarness {
    final class URLBox: Sendable {
        let storage = Mutex<[String]>([])
        func append(_ url: String) { storage.withLock { $0.append(url) } }
        var values: [String] { storage.withLock { $0 } }
    }

    let testRenderer: TestRenderer
    let store: TUIInteractiveStore
    let transport: MockHTTPTransport
    let client: OpenCodeClient
    let controller: TUIInteractiveClient
    let viewRoot: TUIViewRoot
    let openedURLs = URLBox()

    init(
        width: Int = 110,
        height: Int = 34,
        state: TUIInteractiveState,
        transport: MockHTTPTransport,
        oauthPollInterval: Duration = .milliseconds(15),
        browserOpenerError: String? = nil
    ) {
        let resolvedTheme = state.resolveTheme()
        self.testRenderer = createTestRenderer(
            width: width,
            height: height,
            kittyKeyboard: true,
            backgroundColor: resolvedTheme.background.base
        )
        self.store = TUIInteractiveStore(state)
        self.transport = transport
        self.client = OpenCodeClient(options: ClientOptions(
            baseUrl: state.serverURL,
            transport: transport
        ))
        let urlsBox = self.openedURLs
        let rootBox = RootBox()
        self.controller = TUIInteractiveClient(
            client: client,
            store: store,
            directory: state.directory,
            openBrowserURL: { url in
                urlsBox.append(url)
                if let err = browserOpenerError {
                    throw BrowserLaunchFailure(message: err)
                }
            },
            oauthPollInterval: oauthPollInterval,
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

    private struct BrowserLaunchFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class RootBox: @unchecked Sendable {
        private var root: TUIViewRoot?
        func set(_ r: TUIViewRoot) { root = r }
        func invalidate() { root?.invalidate() }
    }

    var launchedURLs: [String] {
        openedURLs.values
    }

    func render(force: Bool = true) {
        viewRoot.invalidate()
        testRenderer.renderOnce(force: force)
    }

    func frame() -> String {
        render()
        return testRenderer.captureCharFrame()
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

enum TUILiveOAuthFixtures {
    static let defaultDirectory = "/Users/dev/workspace"

    static func makeBaseState(
        integrations: [TUIIntegrationItem] = [],
        providers: [String: String] = [:],
        models: [TUIModelItem] = []
    ) -> TUIInteractiveState {
        TUIInteractiveState(
            route: .home(TUIContext.HomeRoute()),
            themeName: "opencode",
            themePreference: .light,
            detectedMode: .light,
            cols: 110,
            rows: 34,
            serverVersion: "2.3.2",
            serverURL: "http://127.0.0.1:49374",
            directory: defaultDirectory,
            homeDirectory: "/Users/dev",
            providers: providers,
            models: models,
            selectedModel: models.first,
            integrations: integrations
        )
    }

    static func githubCopilotForm() -> FormSchema.Fields {
        FormSchema.Fields([
            .string(FormSchema.StringField(
                key: "deploymentType",
                title: "Select GitHub deployment type",
                required: true,
                options: [
                    FormSchema.Option(value: "github.com", label: "GitHub.com", description: "Public"),
                    FormSchema.Option(value: "enterprise", label: "GitHub Enterprise", description: "Data residency or self-hosted"),
                ]
            )),
            .string(FormSchema.StringField(
                key: "enterpriseUrl",
                title: "Enter your GitHub Enterprise URL or domain",
                required: true,
                when: [FormSchema.When(key: "deploymentType", op: .eq, value: .string("enterprise"))],
                placeholder: "company.ghe.com or https://company.ghe.com"
            )),
        ])!
    }

    static func githubCopilotIntegration(connected: Bool = false) -> TUIIntegrationItem {
        TUIIntegrationItem(
            id: "github-copilot",
            name: "GitHub Copilot",
            methods: [
                .oauth(
                    id: "device",
                    label: "Login with GitHub Copilot",
                    form: githubCopilotForm()
                ),
            ],
            connections: connected
                ? [.credential(id: "cred_gh1", label: "GitHub Copilot", method: "device", statusMessage: nil)]
                : []
        )
    }

    static func openAIOAuthAndKeyIntegration() -> TUIIntegrationItem {
        TUIIntegrationItem(
            id: "openai",
            name: "OpenAI",
            methods: [
                // Deliberately put `.key` before `.oauth` in raw input to verify OAuth sorts first!
                .key(label: "API key"),
                .oauth(id: "chatgpt", label: "ChatGPT Plus/Pro (Codex)"),
                .env(names: ["OPENAI_API_KEY"]),
            ],
            connections: []
        )
    }

    static func codeModeOAuthIntegration() -> TUIIntegrationItem {
        TUIIntegrationItem(
            id: "gitlab",
            name: "GitLab Duo",
            methods: [
                .key(label: "Personal Access Token"),
                .oauth(id: "pkce", label: "Sign in with GitLab OAuth"),
            ],
            connections: []
        )
    }

    static func jsonResponse(_ statusCode: Int, json: String) -> HTTPResponse {
        HTTPResponse(
            head: HTTPResponseHead(statusCode: statusCode, headers: ["content-type": "application/json"]),
            body: Array(json.utf8)
        )
    }

    static func attemptStatusJSON(status: String, message: String? = nil) -> String {
        let msgPart = message.map { ",\"message\":\"\($0)\"" } ?? ""
        return #"{"location":{"directory":"\#(defaultDirectory)"},"data":{"status":"\#(status)"\#(msgPart),"time":{"created":1750000000000,"expires":1750000900000}}}"#
    }

    static func sseResponse(events: [(id: String, type: String, dataJSON: String)]) -> HTTPResponse {
        var stream = ""
        for ev in events {
            stream += "data: {\"id\":\"\(ev.id)\",\"type\":\"\(ev.type)\",\"data\":\(ev.dataJSON)}\n\n"
        }
        return HTTPResponse(
            head: HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            body: Array(stream.utf8)
        )
    }

    static func decodeJSONObject(_ bytes: [UInt8]?) -> [String: JSONValue]? {
        guard let bytes, !bytes.isEmpty else { return nil }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)),
              case .object(let dict) = decoded
        else {
            return nil
        }
        return dict
    }

    static func modelJSON(
        id: String,
        providerID: String,
        name: String,
        context: Int = 200_000,
        output: Int = 32_000
    ) -> String {
        """
        {"id":"\(id)","modelID":"\(id)","providerID":"\(providerID)","type":"chat","name":"\(name)","capabilities":{"tools":true,"input":["text"],"output":["text"],"temperature":true},"variants":[],"time":{"released":1750118400000},"cost":[],"status":"active","enabled":true,"limit":{"context":\(context),"output":\(output)}}
        """
    }

    static func providerJSON(id: String, name: String) -> String {
        #"{"id":"\#(id)","name":"\#(name)","activation":"auto","package":"@opencode/ai/providers/\#(id)"}"#
    }

    /// Generates a large live catalog matching ModelsDev scale (320+ providers, 1,200+ models).
    static func largeCatalogJSON(providerCount: Int = 320, modelsPerProvider: Int = 4) -> (providersJSON: String, modelsJSON: String, defaultJSON: String) {
        var providerItems: [String] = [
            providerJSON(id: "opencode", name: "OpenCode Console"),
            providerJSON(id: "openai", name: "OpenAI"),
            providerJSON(id: "anthropic", name: "Anthropic"),
            providerJSON(id: "github-copilot", name: "GitHub Copilot"),
            providerJSON(id: "xai", name: "xAI"),
            providerJSON(id: "poe", name: "Poe"),
            providerJSON(id: "digitalocean", name: "DigitalOcean"),
            providerJSON(id: "gitlab", name: "GitLab"),
        ]
        var modelItems: [String] = [
            modelJSON(id: "claude-sonnet-4-6", providerID: "anthropic", name: "Claude Sonnet 4.6"),
            modelJSON(id: "gpt-5.3-codex", providerID: "openai", name: "GPT-5.3 Codex"),
            modelJSON(id: "claude-opus-4-6", providerID: "github-copilot", name: "Claude Opus 4.6 (Copilot)"),
            modelJSON(id: "grok-4", providerID: "xai", name: "Grok 4"),
            modelJSON(id: "console-zen-pro", providerID: "opencode", name: "OpenCode Zen Pro"),
        ]
        let extraProviders = max(0, providerCount - providerItems.count)
        for pIdx in 0..<extraProviders {
            let pid = "catalog-provider-\(pIdx)"
            let pname = "Catalog Provider \(pIdx)"
            providerItems.append(providerJSON(id: pid, name: pname))
            for mIdx in 0..<modelsPerProvider {
                modelItems.append(modelJSON(
                    id: "model-\(pIdx)-\(mIdx)",
                    providerID: pid,
                    name: "Model \(pIdx).\(mIdx) Turbo"
                ))
            }
        }
        let loc = #"{"directory":"\#(defaultDirectory)"}"#
        let providersJSON = #"{"location":\#(loc),"data":[\#(providerItems.joined(separator: ","))]}"#
        let modelsJSON = #"{"location":\#(loc),"data":[\#(modelItems.joined(separator: ","))]}"#
        let defaultJSON = #"{"location":\#(loc),"data":\#(modelItems[0])}"#
        return (providersJSON, modelsJSON, defaultJSON)
    }

    static func waitUntil(
        timeoutMs: Int = 2_000,
        pollMs: Int = 15,
        _ condition: () -> Bool
    ) async -> Bool {
        let iterations = max(1, timeoutMs / max(1, pollMs))
        for _ in 0..<iterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(pollMs))
        }
        return condition()
    }
}
