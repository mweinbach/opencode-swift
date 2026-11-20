import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Coverage for the upstream "signed-in browser pane" sync of `packages/plugin-browser/src/*` and the plugin host
/// contract changes in `packages/plugin/src/*`.
@Suite("Browser Plugin Parity Sync (wildcard, preview paths, workspace, tools, contract)")
struct BrowserPluginParitySyncTests {
    // MARK: - Test doubles

    /// An in-memory filesystem with directory symlinks: `links` maps a link path to its target.
    final class LinkedFS: OpenCodeFileSystem, Sendable {
        private struct State: Sendable {
            var files: [String: [UInt8]]
            var dirs: Set<String>
            var links: [String: String]
            var modes: [String: UInt16] = [:]
        }

        private let state: Mutex<State>

        init(files: [String: [UInt8]] = [:], dirs: Set<String> = ["/"], links: [String: String] = [:]) {
            state = Mutex(State(files: files, dirs: dirs, links: links))
        }

        func storedFiles() -> [String: [UInt8]] { state.withLock { $0.files } }
        func mode(_ path: String) -> UInt16? { state.withLock { $0.modes[path] } }

        private func resolve(_ path: String) -> String {
            state.withLock { s in
                var current = path
                var changed = true
                var hops = 0
                while changed, hops < 16 {
                    changed = false
                    hops += 1
                    for (link, target) in s.links where current == link || current.hasPrefix(link + "/") {
                        current = target + current.dropFirst(link.count)
                        changed = true
                        break
                    }
                }
                return current
            }
        }

        func readFile(at path: String) async throws -> [UInt8] {
            let real = resolve(path)
            guard let bytes = state.withLock({ $0.files[real] }) else { throw PlatformError.notFound(path) }
            return bytes
        }

        func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
            _ = createDirectories
            state.withLock { $0.files[path] = bytes }
        }

        func writeFileExclusive(_ bytes: [UInt8], to path: String) async throws {
            try state.withLock { s in
                if s.files[path] != nil { throw PlatformError.alreadyExists(path) }
                s.files[path] = bytes
            }
        }

        func exists(at path: String) async -> Bool {
            let real = resolve(path)
            return state.withLock { $0.files[real] != nil || $0.dirs.contains(real) }
        }

        func stat(at path: String) async throws -> FileStat {
            let real = resolve(path)
            return try state.withLock { s in
                if let data = s.files[real] { return FileStat(type: .file, size: Int64(data.count)) }
                if s.dirs.contains(real) { return FileStat(type: .directory) }
                throw PlatformError.notFound(path)
            }
        }

        func makeDirectory(at path: String, recursive: Bool) async throws {
            try state.withLock { s in
                if !recursive, s.dirs.contains(path) { throw PlatformError.alreadyExists(path) }
                s.dirs.insert(path)
            }
        }

        func readDirectory(at path: String) async throws -> [String] { _ = path; return [] }

        func remove(at path: String) async throws {
            state.withLock { s in
                s.files = s.files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
                s.dirs = s.dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }
            }
        }

        func rename(from source: String, to destination: String) async throws { _ = (source, destination) }

        func realPath(at path: String) async throws -> String {
            let real = resolve(path)
            let found = state.withLock { $0.files[real] != nil || $0.dirs.contains(real) }
            guard found else { throw PlatformError.notFound(path) }
            return real
        }

        func setModificationTime(at path: String, epochMs: Int64) async throws { _ = (path, epochMs) }

        func chmod(at path: String, mode: UInt16) async throws {
            state.withLock { $0.modes[path] = mode }
        }
    }

    private static let tabID = "tab_01234567-89ab-cdef-0123-456789abcdef"

    private static func toolContext(_ sessionID: SessionID = SessionID.create()) -> ToolSchema.Context {
        ToolSchema.Context(
            sessionID: sessionID,
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: "msg-1",
            id: ToolSchema.CallID(rawValue: "call-1"),
            progress: { _ in }
        )
    }

    private static func location(_ directory: String, project: String? = nil) -> LocationSchema.Info {
        LocationSchema.Info(
            directory: SchemaPrimitive.AbsolutePath(rawValue: directory),
            workspaceID: nil,
            project: LocationSchema.ProjectRef(
                id: ProjectID.global,
                directory: SchemaPrimitive.AbsolutePath(rawValue: project ?? directory),
                canonical: SchemaPrimitive.AbsolutePath(rawValue: project ?? directory)
            )
        )
    }

    private static func normalize(_ type: BrowserPlugin.Browser.Method, _ fields: [String: JSONValue]) throws -> BrowserPlugin.Browser.Action {
        try BrowserPlugin.BrowserTools.normalizeAction(BrowserPlugin.Browser.Input(type: type, fields: fields))
    }

    private static func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as ToolSchema.ToolError {
            return error.message
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - wildcard.ts

    @Test("Wildcard.match follows core's permission matcher case table")
    func wildcardMatch() {
        let rows: [(String, String, Bool, Bool)] = [
            ("tabs.list", "*", false, true),
            ("", "*", false, true),
            ("tabs.list", "tabs.*", false, true),
            ("tabs.", "tabs.*", false, true),
            ("files.upload", "tabs.*", false, false),
            ("a/b/c.env", "*.env", false, true),
            ("first\nsecond", "first*", false, true),
            ("tabs.open", "tabs.ope?", false, true),
            ("tabs.ope", "tabs.ope?", false, false),
            ("tabs.opens", "tabs.ope?", false, false),
            ("git push", "git push *", false, true),
            ("git push origin dev", "git push *", false, true),
            ("git pushx", "git push *", false, false),
            ("git push", "git push*", false, true),
            ("git pushx", "git push*", false, true),
            (#"C:\Users\x\project\a.ts"#, "C:/Users/x/project/*", false, true),
            ("C:/Users/x/project/a.ts", #"C:\Users\x\*"#, false, true),
            (#"C:\Users\y\a.ts"#, "C:/Users/x/*", false, false),
            ("browser", "b.owser", false, false),
            ("b.owser", "b.owser", false, true),
            ("a+b(c)[d]{e}|f^g$h", "a+b(c)[d]{e}|f^g$h", false, true),
            ("browsers", "browser", false, false),
            ("a browser", "browser", false, false),
            (".OPENCODE/x", ".opencode/*", false, false),
            (".OPENCODE/x", ".opencode/*", true, true),
            ("Tabs.List", "tabs.list", false, false),
            ("Tabs.List", "tabs.list", true, true),
            // `?` is one UTF-16 code unit: an emoji is two.
            ("😀", "?", false, false),
            ("😀", "??", false, true),
        ]
        for (input, pattern, ignoreCase, expected) in rows {
            #expect(BrowserPlugin.Wildcard.match(input, pattern, ignoreCase: ignoreCase) == expected, "\(pattern) on \(input)")
        }
    }

    // MARK: - preview-path.ts

    @Test("previewPath, windowsPreviewSegment, workspacePrefix and remotePath")
    func previewPaths() {
        let preview = BrowserPlugin.PreviewPath.self
        for path in ["src/aux.html", "icons/CON.svg", "12:00.png", "trailing."] {
            #expect(preview.previewPath(path, windows: false), "\(path)")
            #expect(!preview.previewPath(path, windows: true), "\(path)")
        }
        for path in ["a/../x", "C:/foo", "/a", "a//b", #"a\b"#, "a\u{0}b", "./a", ""] {
            #expect(!preview.previewPath(path, windows: false), "\(path)")
            #expect(!preview.previewPath(path, windows: true), "\(path)")
        }
        #expect(preview.windowsPreviewSegment("console.log"))
        #expect(!preview.windowsPreviewSegment("conin$.txt"))
        #expect(!preview.windowsPreviewSegment("COM9"))
        #expect(preview.windowsPreviewSegment("com0"))

        let prefix = preview.workspacePrefix("ses_AbC123")
        #expect(prefix == "workspace://ses_abc123/")
        for address in ["workspace://ses_abc123/site/page.html", "workspace://ses_AbC123/site/page.html", "WORKSPACE://SES_ABC123/site/page.html"] {
            #expect(preview.remotePath(address, prefix: prefix) == "site/page.html")
        }
        #expect(preview.remotePath("workspace://ses_other/site/page.html", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/Site/Page.html", prefix: prefix) == "Site/Page.html")
        #expect(preview.remotePath("workspace://ses_abc123/a%20b.html?x=1#top", prefix: prefix) == "a b.html")
        #expect(preview.remotePath("workspace://ses_abc123/a%2Fb.html", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/a%5cb.html", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/%E0%A4%A", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/../x", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/", prefix: prefix) == nil)
        #expect(preview.remotePath("workspace://ses_abc123/con.txt", prefix: prefix, windows: true) == nil)
    }

    // MARK: - workspace.ts

    @Test("workspaceTarget requires both the name and its resolved target inside one root")
    func workspaceTarget() async throws {
        let fs = LinkedFS(
            files: ["/work/site/index.html": [1], "/outside/secret.txt": [2]],
            dirs: ["/", "/work", "/work/site", "/outside", "/real"],
            links: ["/work/escape": "/outside", "/linked": "/work"]
        )
        let workspace = BrowserPlugin.Workspace.self
        #expect(try await workspace.workspaceTarget("/work/site/index.html", roots: ["/work"], fileSystem: fs) == "/work/site/index.html")
        // The name is inside, but the link leads out.
        #expect(try await workspace.workspaceTarget("/work/escape/secret.txt", roots: ["/work"], fileSystem: fs) == nil)
        // The name is outside every root: no disk access at all.
        #expect(try await workspace.workspaceTarget("/elsewhere/missing", roots: ["/work"], fileSystem: fs) == nil)
        // A root reached through a link compares physical names.
        #expect(try await workspace.workspaceTarget("/linked/site/index.html", roots: ["/linked"], fileSystem: fs) == "/work/site/index.html")
        // A root itself is inside.
        #expect(try await workspace.workspaceTarget("/work", roots: ["/work"], fileSystem: fs) == "/work")
        // A missing file inside a root reports the filesystem error.
        await #expect(throws: PlatformError.self) {
            _ = try await workspace.workspaceTarget("/work/missing.html", roots: ["/work"], fileSystem: fs)
        }
    }

    // MARK: - files.ts

    @Test("BrowserFiles.entry, address and locate resolve the exact workspace entry")
    func filesLocate() async throws {
        let files = BrowserPlugin.BrowserFiles.self
        #expect(files.address("https://example.com"))
        #expect(files.address(" skill://browser/SKILL.md"))
        #expect(!files.address("C:/repo/a.html"))
        #expect(!files.address("site/index.html"))

        #expect(files.entry("https://example.com/report.html", directory: "/work", isWindows: false) == nil)
        #expect(files.entry("site/index.html:3", directory: "/work", isWindows: false) == .entry(absolute: "/work/site/index.html", name: "site/index.html"))
        #expect(files.entry(" site/index.html#L2C1-L4 ", directory: "/work", isWindows: false) == .entry(absolute: "/work/site/index.html", name: "site/index.html"))
        #expect(files.entry(#"site\index.html"#, directory: "/work", isWindows: false) == .entry(absolute: "/work/site/index.html", name: "site/index.html"))
        #expect(files.entry("file:///work/site/a%20b.html", directory: "/work", isWindows: false) == .entry(absolute: "/work/site/a b.html", name: "site/a b.html"))
        #expect(files.entry("file://localhost/work/x.html", directory: "/work", isWindows: false) == .entry(absolute: "/work/x.html", name: "x.html"))
        #expect(files.entry("file://server/share/x.html", directory: "/work", isWindows: false) == .outside(absolute: "file://server/share/x.html"))
        #expect(files.entry("file:///work/a%2Fb.html", directory: "/work", isWindows: false) == .unresolved)
        #expect(files.entry("../outside.html", directory: "/work", isWindows: false) == .outside(absolute: "/outside.html"))
        #expect(files.entry("site/con.txt", directory: "/work", isWindows: true) == .invalid(absolute: "/work/site/con.txt"))

        let fs = LinkedFS(
            files: ["/work/site/index.html": Array("<h1>hi</h1>".utf8), "/outside/x.html": [1]],
            dirs: ["/", "/work", "/work/site", "/work/site/docs", "/outside"],
            links: ["/work/site/docs/other": "/outside", "/link": "/work"]
        )
        let approved = Mutex<[String]>([])
        let approve: @Sendable (String) async throws(ToolSchema.ToolError) -> Void = { path in approved.withLock { $0.append(path) } }
        for path in ["site/index.html", "./site/index.html", #"site\index.html"#, "site/index.html:3", "site/index.html#L2", "/work/site/index.html", "file:///work/site/index.html"] {
            let located = try await files.locate(path, directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
            #expect(located == .init(absolute: "/work/site/index.html", found: true, directory: false), "\(path)")
        }
        #expect(try await files.locate("missing.html", directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
            == .init(absolute: "/work/missing.html", found: false, directory: false))
        #expect(try await files.locate("site/docs", directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
            == .init(absolute: "/work/site/docs", found: false, directory: true))
        #expect(try await files.locate("https://example.com/x.html", directory: "/work", approve: approve, fileSystem: fs, isWindows: false) == nil)
        let escaped = try await files.locate("site/docs/other/x.html", directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
        #expect(escaped?.outside == true)
        let lexical = try await files.locate("../x.html", directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
        #expect(lexical?.outside == true)
        await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await files.locate("file:///a%2Fb", directory: "/work", approve: approve, fileSystem: fs, isWindows: false)
        }

        // A workspace reached through a link keeps its own spelling and asks once.
        approved.withLock { $0.removeAll() }
        let through = try await files.locate("site/index.html", directory: "/link", approve: approve, fileSystem: fs, isWindows: false)
        #expect(through == .init(absolute: "/link/site/index.html", found: true, directory: false))
        #expect(approved.withLock { $0 } == ["/link/site/index.html"])
    }

    @Test("BrowserFiles.authorize asserts external_directory, then read/edit with lexical resources")
    func filesAuthorize() async throws {
        let asserted = Mutex<[PluginContract.AssertInput]>([])
        let assert: @Sendable (PluginContract.AssertInput) async throws(ToolSchema.ToolError) -> Void = { input in
            asserted.withLock { $0.append(input) }
        }
        let tool = Self.toolContext()
        try await BrowserPlugin.BrowserFiles.authorize(
            location: Self.location("/work/app", project: "/work"),
            assert: assert,
            tool: tool,
            action: "read",
            paths: ["/work/app/a.txt", "/work/shared/b.txt", "/tmp/x/c.txt", "/tmp/x/d.txt", "/work/app"]
        )
        let calls = asserted.withLock { $0 }
        #expect(calls.count == 2)
        #expect(calls[0].action == "external_directory")
        #expect(calls[0].resources == ["/tmp/x/*"])
        #expect(calls[0].save == [])
        #expect(calls[1].action == "read")
        #expect(calls[1].resources == ["a.txt", "../shared/b.txt", "/tmp/x/c.txt", "/tmp/x/d.txt", "."])
        #expect(calls[1].save == [])
        #expect(calls[1].source == .tool(messageID: "msg-1", id: "call-1"))

        asserted.withLock { $0.removeAll() }
        try await BrowserPlugin.BrowserFiles.authorize(
            location: Self.location("/work"),
            assert: assert,
            tool: tool,
            action: "edit",
            paths: ["/work/a.txt"]
        )
        let inside = asserted.withLock { $0 }
        #expect(inside.count == 1)
        #expect(inside[0].save == ["a.txt"])

        // A project at the filesystem root does not count as inside.
        asserted.withLock { $0.removeAll() }
        try await BrowserPlugin.BrowserFiles.authorize(location: Self.location("/work", project: "/"), assert: assert, tool: tool, action: "read", paths: ["/etc/hosts"])
        #expect(asserted.withLock { $0 }.first?.action == "external_directory")

        let remote = LocationSchema.Info(
            directory: SchemaPrimitive.AbsolutePath(rawValue: "/work"),
            workspaceID: WorkspaceID.create(),
            project: Self.location("/work").project
        )
        await #expect(throws: ToolSchema.ToolError.self) {
            try await BrowserPlugin.BrowserFiles.authorize(location: remote, assert: assert, tool: tool, action: "read", paths: ["/work/a"])
        }
    }

    @Test("BrowserFiles uploadPath, read, exportRoot, exportPaths and save")
    func filesTransfer() async throws {
        let files = BrowserPlugin.BrowserFiles.self
        #expect(files.uploadPath("/work", "~", home: "/home/me", isWindows: false) == "/home/me")
        #expect(files.uploadPath("/work", "~/a.png", home: "/home/me", isWindows: false) == "/home/me/a.png")
        #expect(files.uploadPath("/work", "img/../a.png", home: "/home/me", isWindows: false) == "/work/a.png")
        #expect(files.uploadPath("/work", "/abs/a.png", home: "/home/me", isWindows: false) == "/abs/a.png")

        let fs = LinkedFS(
            files: ["/work/shot.png": [0x89, 0x50], "/work/big.bin": Array(repeating: 0, count: 5 * 1024 * 1024)],
            dirs: ["/", "/work", "/work/dir", "/cache"],
            links: ["/work/alias.png": "/work/shot.png"]
        )
        let physical = try await files.physical(["/work/alias.png"], fileSystem: fs)
        #expect(physical == ["/work/shot.png"])
        let read = try await files.read(paths: physical, names: ["/work/alias.png"], fileSystem: fs)
        #expect(read.count == 1)
        #expect(read[0].name == "alias.png")
        #expect(read[0].mime == "image/png")
        #expect(read[0].data == [0x89, 0x50])
        await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await files.read(paths: ["/work/dir"], names: ["dir"], fileSystem: fs)
        }
        await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await files.read(paths: ["/work/shot.png", "/work/big.bin"], names: [], fileSystem: fs)
        }
        do {
            _ = try await files.read(paths: ["/work/missing"], names: [], fileSystem: fs)
            Issue.record("expected a failure")
        } catch {
            #expect(error.message.contains("Details: ENOENT: Not found: /work/missing"))
        }

        let root = files.exportRoot("ses_123", cache: "/cache")
        #expect(root == "/cache/browser-exports/" + Hash.sha256("ses_123"))
        let captures = try ["..", ".", "CON.txt", "lpt1", "report.html"].map { name in
            BrowserPlugin.Browser.File(id: try BrowserPlugin.Browser.FileID.make(), name: name, mime: "text/plain", data: Array(name.utf8))
        }
        let plan = files.exportPaths(captures, root: root)
        #expect(plan.directory.hasPrefix(root + "/"))
        #expect(plan.paths.map { $0.split(separator: "/").last.map(String.init) } == ["capture", "capture", "capture", "capture", "report.html"])
        #expect(plan.paths.enumerated().allSatisfy { index, path in path.hasPrefix("\(plan.directory)/\(index)/") })
        let saved = try await files.save(files: captures, plan: plan, fileSystem: fs)
        #expect(saved.map(\.name) == ["..", ".", "CON.txt", "lpt1", "report.html"])
        #expect(fs.storedFiles()[saved[0].path] == Array("..".utf8))
        #expect(fs.mode(plan.directory) == 0o700)
        #expect(fs.mode(saved[4].path) == 0o600)
        // The planned directory must be fresh.
        await #expect(throws: ToolSchema.ToolError.self) {
            _ = try await files.save(files: captures, plan: plan, fileSystem: fs)
        }
        #expect(try await files.save(files: [], plan: plan, fileSystem: fs).isEmpty)
    }

    // MARK: - rpc.ts

    @Test("rpc: operations, file actions, extension origins, loopback and URL matching")
    func rpcHelpers() throws {
        let browser = BrowserPlugin.Browser.self
        #expect(browser.Operations.count == 44)
        #expect(!browser.Operations.contains { $0.name == .preview })
        #expect(browser.Method.allCases.count == 46)
        #expect(browser.Method.preview.isFileAction && browser.Method.navigatePath.isFileAction)
        #expect(browser.Method(rawValue: "navigate.path") == .navigatePath)
        #expect(browser.MAX_WAIT_MS == 30_000)
        #expect(browser.FailureCode.unmet == "condition_unmet")
        #expect(browser.FailureCode.signInRequired == "sign_in_required")
        #expect(browser.operation(named: .wait)?.parameterNames == ["tabID", "frameID", "condition", "text", "textGone", "selector", "ref", "state", "url", "delayMs", "time", "ms", "timeoutMs", "timeout"])
        #expect(browser.operation(named: .tabsOpen)?.parameterNames == ["url", "path", "focus"])
        #expect(browser.operation(named: .networkGet)?.parameterNames == ["tabID", "id", "requestID", "includeBody", "includeResponseBody", "maxBodyChars"])
        #expect(browser.operation(named: .tabsList)?.parameterNames == [])

        #expect(browser.extensionOrigin("chrome-extension://abc/options.html"))
        #expect(browser.extensionOrigin("MOZ-EXTENSION://x/popup.html"))
        #expect(browser.extensionOrigin("blob:chrome-extension://abc/0b6f7c2e"))
        #expect(browser.extensionOrigin("extension:"))
        #expect(!browser.extensionOrigin("blob:https://example.com/uuid"))
        #expect(!browser.extensionOrigin("https://chrome-extension.example.com"))
        #expect(!browser.extensionOrigin("not a url"))
        #expect(browser.extensionPageRefusal("moz-extension://x").hasPrefix("Agent browser tools cannot open extension pages such as moz-extension://x:"))

        for value in ["localhost", "localhost:3000/app", "app.localhost:3000", "127.0.0.1:8080", "[::1]:5173", "LOCALHOST?x"] {
            #expect(browser.loopbackAddress(value), "\(value)")
        }
        for value in ["localhost.example.com", "128.0.0.1", "example.com", "localhostx"] {
            #expect(!browser.loopbackAddress(value), "\(value)")
        }

        #expect(browser.matchesURL("https://app.test/dashboard?tab=1", "/dashboard"))
        #expect(browser.matchesURL("https://app.test/dashboard", "**/dashboard"))
        #expect(!browser.matchesURL("https://app.test/dashboard/settings", "**/dashboard"))
        #expect(browser.matchesURL("https://app.test/a.b", "*/a.b"))
        #expect(!browser.matchesURL("https://app.test/axb", "*/a.b"))
        #expect(!browser.matchesURL("abc", "ab*bc"))
        #expect(browser.matchesURL("https://app.test/some/path", "https://*/*/path"))

        let shown = try BrowserPlugin.Browser.Shown(path: "site/a.html", tabID: BrowserPlugin.Browser.TabID.make(Self.tabID), url: "file:///w/site/a.html")
        #expect(shown.tab == nil)
        let waited = BrowserPlugin.Browser.Waited(
            tab: BrowserPlugin.Browser.Tab(id: try .make(Self.tabID), url: "about:blank", title: "", loading: false, canGoBack: false, canGoForward: false, generation: 1),
            met: false,
            waited: .url,
            elapsedMs: 12,
            observed: "The address was about:blank after 12 ms."
        )
        #expect(waited.waited.rawValue == "url")

        let skill = BrowserPlugin.BrowserSkill.info.content
        #expect(skill.contains("`[browser.not_attached]`"))
        #expect(skill.contains("Its tabs show beside the conversation"))
        #expect(skill.contains("- `tools.browser.tabs.open`: Open a tab on a web address (url)"))
        #expect(!skill.contains("tools.browser.preview`"))
    }

    // MARK: - tools.ts normalizeAction

    @Test("normalizeAction folds aliases and fails conflicting or missing parameters")
    func normalizeAliases() throws {
        let ref = JSONValue.string("e4")
        let tab = JSONValue.string(Self.tabID)
        #expect(try Self.normalize(.find, ["tabID": tab, "query": .string("Save")]).fields == ["tabID": tab, "text": .string("Save")])
        #expect(try Self.normalize(.fill, ["tabID": tab, "ref": ref, "value": .string("")]).fields == ["tabID": tab, "ref": ref, "text": .string("")])
        #expect(try Self.normalize(.filesGet, ["tabID": tab, "id": .string("file_x")]).fields == ["tabID": tab, "fileID": .string("file_x")])
        #expect(try Self.normalize(.networkGet, ["tabID": tab, "requestID": .string("r1"), "includeResponseBody": .bool(true)]).fields
            == ["tabID": tab, "id": .string("r1"), "includeResponseBody": .bool(true)])
        #expect(Self.message { _ = try Self.normalize(.fill, ["tabID": tab, "ref": ref, "text": .string("keep"), "value": .string("replace")]) }?.contains("Conflicting") == true)
        #expect(Self.message { _ = try Self.normalize(.find, ["tabID": tab]) }?.contains("Missing text") == true)
        #expect(Self.message { _ = try Self.normalize(.evaluate, ["tabID": tab, "expression": .string("1"), "code": .string("2")]) }?.contains("Conflicting") == true)
        #expect(try Self.normalize(.evaluate, ["tabID": tab, "expression": .string("1"), "script": .string("1")]).fields == ["tabID": tab, "script": .string("1")])
        for key in ["script", "expression", "code"] {
            #expect(try Self.normalize(.evaluate, ["tabID": tab, key: .string("document.title")]).fields == ["tabID": tab, "script": .string("document.title")])
        }
        #expect(try Self.normalize(.evaluate, ["tabID": tab, "frameID": .string("frame"), "expression": .string("location.href")]).fields
            == ["tabID": tab, "frameID": .string("frame"), "script": .string("location.href")])
        #expect(Self.message { _ = try Self.normalize(.evaluate, ["tabID": tab]) }
            == "browser.evaluate needs the JavaScript to run in script, for example browser.evaluate({ tabID, script: \"document.title\" }).")
        // A ref's script is a function that receives the element; it is never wrapped.
        #expect(try Self.normalize(.evaluate, ["tabID": tab, "ref": .string("e1"), "script": .string("return 1")]).fields["script"] == .string("return 1"))
    }

    @Test("normalizeAction routes workspace files to preview/navigate.path and normalizes web addresses")
    func normalizeAddresses() throws {
        let tab = JSONValue.string(Self.tabID)
        let addresses = ["file:///D:/site/index.html", "workspace://ses_1/site/index.html"]
        for file in ["site/index.html", " site/index.html#L2 ", #"C:\repo\site\index.html"#, "../outside.html"] + addresses {
            let trimmed = String(file.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
            let open = try Self.normalize(.tabsOpen, ["path": .string(file)])
            #expect(open.type == .preview && open.fields == ["path": .string(trimmed)])
            let move = try Self.normalize(.navigate, ["tabID": tab, "path": .string(file)])
            #expect(move.type == .navigatePath && move.fields == ["tabID": tab, "path": .string(trimmed)])
        }
        for url in addresses {
            #expect(try Self.normalize(.tabsOpen, ["url": .string(url)]).type == .preview)
            #expect(try Self.normalize(.navigate, ["tabID": tab, "url": .string(url)]).type == .navigatePath)
        }
        #expect(try Self.normalize(.tabsOpen, ["path": .string("site/index.html"), "focus": .bool(false)]).fields == ["path": .string("site/index.html")])
        #expect(Self.message { _ = try Self.normalize(.tabsOpen, ["url": .string("https://example.com"), "path": .string("a.html")]) }
            == "browser.tabs.open takes url or path, not both. Pass url for a web address, or path for a workspace file.")
        #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab]) }?.hasPrefix("browser.navigate needs url or path") == true)
        for fields: [String: JSONValue] in [["url": .string("oc-preview://abc/site/index.html")], ["path": .string("oc-preview://abc/x")]] {
            #expect(Self.message { _ = try Self.normalize(.tabsOpen, fields) }?.contains("Pass the file's own path to browser.tabs.open({ path })") == true)
        }
        for path in ["https://example.com/report.html", "skill://browser/SKILL.md", " "] {
            #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab, "path": .string(path)]) }?.hasPrefix("browser.navigate needs path to name a workspace file") == true)
        }
        for path in ["/tmp/page.html", "./page.html", "../page.html", #"C:\Users\me\page.html"#, "D:/page.html", "~/report.html"] {
            #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab, "url": .string(path)]) }
                == "\(BrowserPlugin.BrowserTools.jsonStringLiteral(path)) is a local file, not a web address. Pass it as path: browser.navigate({ tabID, path }).")
        }
        for url in ["chrome-extension://abc/options.html", "blob:chrome-extension://abc/0b6f7c2e"] {
            #expect(Self.message { _ = try Self.normalize(.tabsOpen, ["url": .string(url)]) } == BrowserPlugin.Browser.extensionPageRefusal(url))
        }
        #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab, "url": .string("ftp://example.com/file")]) }?
            .hasPrefix("\"ftp://example.com/file\" is not a browser URL. Use an http:// or https:// address") == true)
        #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab, "url": .string("https://user:secret@example.com")]) }?.contains("is not a browser URL") == true)
        #expect(try Self.normalize(.navigate, ["tabID": tab, "url": .string("example.com/docs")]).url == "https://example.com/docs")
        #expect(try Self.normalize(.navigate, ["tabID": tab, "url": .string("localhost:8000")]).url == "http://localhost:8000/")
        #expect(try Self.normalize(.navigate, ["tabID": tab, "url": .string("app.localhost:3000")]).url == "http://app.localhost:3000/")
        #expect(try Self.normalize(.tabsOpen, [:]).fields.isEmpty)
        #expect(try Self.normalize(.tabsOpen, ["url": .string(" ")]).url == "about:blank")
        let long = "https://example.com/" + String(repeating: "é", count: 400)
        #expect(Self.message { _ = try Self.normalize(.navigate, ["tabID": tab, "url": .string(long)]) }
            == "The URL is longer than 2048 characters once encoded. Open a shorter address.")
    }

    // MARK: - tools.ts waitPlan / asyncBody

    @Test("waitPlan reads the condition from the keys models write")
    func waitPlans() throws {
        let tab = JSONValue.string(Self.tabID)
        func plan(_ fields: [String: JSONValue]) throws -> BrowserPlugin.BrowserTools.WaitPlan {
            var all = fields
            all["tabID"] = tab
            return try BrowserPlugin.BrowserTools.waitPlan(BrowserPlugin.Browser.Input(type: .wait, fields: all))
        }
        func desktop(_ condition: BrowserPlugin.Browser.Waited.Condition, _ timeoutMs: Int, _ text: String? = nil) -> BrowserPlugin.BrowserTools.WaitPlan {
            var fields: [String: JSONValue] = ["tabID": tab, "condition": .string(condition.rawValue), "timeoutMs": .int(Int64(timeoutMs))]
            if let text { fields["text"] = .string(text) }
            return .init(timeoutMs: timeoutMs, waited: condition, kind: .desktop(BrowserPlugin.Browser.Action(type: .wait, fields: fields)))
        }
        let rows: [([String: JSONValue], BrowserPlugin.BrowserTools.WaitPlan)] = [
            (["text": .string("Done"), "timeout": .int(1_000)], desktop(.text, 1_000, "Done")),
            (["text": .string("Done"), "timeout": .int(120_000)], desktop(.text, 30_000, "Done")),
            (["text": .string("Done"), "state": .string("visible")], desktop(.text, 10_000, "Done")),
            (["text": .string("Spinner"), "state": .string("hidden")], desktop(.textGone, 10_000, "Spinner")),
            (["text": .string("Spinner"), "state": .string("detached"), "timeout": .int(30_000)], desktop(.textGone, 30_000, "Spinner")),
            (["text": .string("Done"), "timeoutMs": .int(250)], desktop(.text, 250, "Done")),
            (["text": .string("Done")], desktop(.text, 10_000, "Done")),
            (["state": .string("load")], desktop(.load, 10_000)),
            (["state": .string("networkidle")], desktop(.load, 10_000)),
            (["state": .string("load"), "timeout": .int(5_000)], desktop(.load, 5_000)),
            ([:], desktop(.load, 10_000)),
            (["textGone": .string("Loading")], desktop(.textGone, 10_000, "Loading")),
            (["condition": .string("text"), "text": .string("Done"), "timeoutMs": .int(30_000)], desktop(.text, 30_000, "Done")),
            (["condition": .string("load"), "timeout": .int(30_000)], desktop(.load, 30_000)),
            (["selector": .string("#app .ready"), "timeout": .int(8_000)], .init(timeoutMs: 8_000, waited: .element, kind: .element(.selector("#app .ready"), gone: false, frameID: nil))),
            (["selector": .string(".spinner"), "state": .string("hidden"), "frameID": .string("frame")], .init(timeoutMs: 10_000, waited: .elementGone, kind: .element(.selector(".spinner"), gone: true, frameID: "frame"))),
            (["ref": .string("e4")], .init(timeoutMs: 10_000, waited: .element, kind: .element(.ref(try .make("e4")), gone: false, frameID: nil))),
            (["url": .string("**/dashboard")], .init(timeoutMs: 10_000, waited: .url, kind: .url("**/dashboard"))),
            (["time": .int(3_000)], .init(timeoutMs: 3_000, waited: .delay, kind: .delay)),
            (["time": .int(6)], .init(timeoutMs: 6_000, waited: .delay, kind: .delay)),
            (["ms": .int(1_200)], .init(timeoutMs: 1_200, waited: .delay, kind: .delay)),
            (["delayMs": .double(90_000)], .init(timeoutMs: 30_000, waited: .delay, kind: .delay)),
            (["condition": .string("delay"), "timeout": .int(2_000)], .init(timeoutMs: 2_000, waited: .delay, kind: .delay)),
            (["timeout": .int(5_000)], .init(timeoutMs: 5_000, waited: .delay, kind: .delay)),
            (["timeoutMs": .double(1_500.4)], .init(timeoutMs: 1_500, waited: .delay, kind: .delay)),
        ]
        for (fields, expected) in rows {
            #expect(try plan(fields) == expected, "\(fields)")
        }
        #expect(Self.message { _ = try plan(["text": .string("Done"), "selector": .string("#done")]) }
            == "browser.wait takes one condition, but got text and selector. Wait for each in its own call, for example browser.wait({ tabID, text: \"Saved\" }).")
        #expect(Self.message { _ = try plan(["condition": .string("text")]) }
            == "browser.wait needs the text to look for, for example browser.wait({ tabID, text: \"Saved\" }).")
        #expect(Self.message { _ = try plan(["condition": .string("element")]) }
            == "browser.wait needs selector or ref, for example browser.wait({ tabID, selector: \"#save\" }).")
        #expect(Self.message { _ = try plan(["condition": .string("delay")]) }
            == "browser.wait needs a duration to pause, for example browser.wait({ tabID, delayMs: 500 }).")
    }

    @Test("asyncBody wraps scripts with a top-level return or await, and leaves compiling scripts alone")
    func asyncBodies() {
        let tools = BrowserPlugin.BrowserTools.self
        func body(_ script: String) -> String { "(async () => {\n\(script)\n})()" }
        func expression(_ script: String) -> String { "(async () => (\n\(script)\n))()" }
        #expect(tools.asyncBody("return document.title") == body("return document.title"))
        #expect(tools.asyncBody("const r = await fetch(\"/x\"); return r.status") == body("const r = await fetch(\"/x\"); return r.status"))
        #expect(tools.asyncBody("await new Promise((resolve) => resolve(1))") == expression("await new Promise((resolve) => resolve(1))"))
        #expect(tools.asyncBody("await Promise.resolve(2).then((value) => value + 1);") == expression("await Promise.resolve(2).then((value) => value + 1)"))
        #expect(tools.asyncBody("const a = await Promise.resolve(4); return a + 1") == body("const a = await Promise.resolve(4); return a + 1"))
        #expect(tools.asyncBody("await a()\nawait b()") == body("await a()\nawait b()"))
        for script in [
            "document.title",
            "const a = 1; a + 1",
            "[...document.querySelectorAll('a')].map((a) => { return a.href })",
            "(async () => { return await fetch('/x').then((r) => r.status) })()",
            "({ returnValue: 1, awaited: 2 })",
            "async function f() { return await g() }; f()",
            "'return' + `await ${x}`",
            "items.map(async (x) => await x)",
        ] {
            #expect(tools.asyncBody(script) == script, "\(script)")
        }
        #expect(tools.asyncBody("return (") == "return (")
        #expect(tools.asyncBody("return \"unterminated") == "return \"unterminated")
    }

    // MARK: - machine.ts

    @Test("machine: grants, rule selection, sessions, connection and tab errors")
    func machineSelectors() throws {
        let machine = BrowserPlugin.BrowserMachine.self
        #expect(machine.isGrant(PermissionSchema.Rule(action: "browser", resource: "*", effect: .allow)))
        #expect(machine.isGrant(PermissionSchema.Rule(action: "skill", resource: "browser", effect: .allow)))
        #expect(!machine.isGrant(PermissionSchema.Rule(action: "browser", resource: "*", effect: .deny)))
        #expect(!machine.isGrant(PermissionSchema.Rule(action: "browser", resource: "click", effect: .allow)))

        let rules = [
            PermissionSchema.Rule(action: "*", resource: "*", effect: .allow),
            PermissionSchema.Rule(action: "browser", resource: "tabs.*", effect: .deny),
            PermissionSchema.Rule(action: "browse?", resource: "tabs.list", effect: .allow),
            PermissionSchema.Rule(action: "read", resource: "*", effect: .deny),
        ]
        #expect(machine.selectBrowserRule(rules, "tabs.list", ignoreCase: false)?.effect == .allow)
        #expect(machine.selectBrowserRule(rules, "tabs.open", ignoreCase: false)?.effect == .deny)
        #expect(machine.selectBrowserRule(rules, "click", ignoreCase: false)?.resource == "*")
        #expect(machine.selectBrowserRule([], "click", ignoreCase: false) == nil)
        #expect(machine.selectBrowserRule([PermissionSchema.Rule(action: "BROWSER", resource: "*", effect: .deny)], "click", ignoreCase: true) != nil)
        #expect(machine.selectBrowserRule([PermissionSchema.Rule(action: "BROWSER", resource: "*", effect: .deny)], "click", ignoreCase: false) == nil)

        let connection = BrowserPlugin.BrowserConnection.self
        #expect(connection.denial(rules, ["click"]) == nil)
        #expect(connection.denial(rules, ["click", "tabs.open"]) == "[browser.denied] browser.tabs.open is denied for this agent by configuration; no action ran. Do not retry it.")
        #expect(connection.denial([PermissionSchema.Rule(action: "browser", resource: "*", effect: .deny)], ["click"])?.contains("Browser tools are denied for this agent") == true)
        #expect(connection.denial([PermissionSchema.Rule(action: "browser", resource: "preview", effect: .deny)], ["tabs.open", "preview"])?.contains("permission browser.preview") == true)

        let sessionID = SessionID.create()
        var state = machine.createConnectionState()
        #expect(!machine.hasSession(state, sessionID: sessionID))
        guard case .error(let none) = machine.selectConnection(state, sessionID: sessionID) else {
            Issue.record("expected no attachment")
            return
        }
        #expect(none.message.hasPrefix("No browser is attached to this session."))
        state = machine.transitionConnection(state, .attachStarted(sessionID: sessionID, attempt: 1, connectionID: "c1")).state
        #expect(machine.hasSession(state, sessionID: sessionID))
        guard case .error(let connecting) = machine.selectConnection(state, sessionID: sessionID) else {
            Issue.record("expected attaching")
            return
        }
        #expect(connecting.message == "The desktop browser is still connecting to this session. No action ran. Retry only after it attaches.")
        state = machine.transitionConnection(state, .permissionsSynced(sessionID: sessionID, attempt: 2)).state
        let tabs = try (0..<12).map { index in
            BrowserPlugin.Browser.Tab(
                id: try .make("tab_00000000-0000-0000-0000-0000000000" + (index < 10 ? "0\(index)" : "\(index)")),
                url: index == 0 ? "https://example.com/" + String(repeating: "a", count: 120) : "about:blank",
                title: "",
                loading: false,
                canGoBack: false,
                canGoForward: false,
                generation: index
            )
        }
        state = machine.transitionConnection(state, .stateUpdated(sessionID: sessionID, connectionID: "c1", browserState: .init(tabs: tabs))).state
        guard case .ok(let connectionID, let listed) = machine.selectConnection(state, sessionID: sessionID) else {
            Issue.record("expected attached")
            return
        }
        #expect(connectionID == "c1" && listed.count == 12)
        let missing = BrowserPlugin.Browser.Action(type: .click, fields: ["tabID": .string(Self.tabID), "ref": .string("e1")])
        guard case .error(let unavailable) = machine.selectTarget(state, sessionID: sessionID, action: missing) else {
            Issue.record("expected tab_unavailable")
            return
        }
        #expect(unavailable.message.hasPrefix("[browser.tab_unavailable] No open tab in this session has the ID \(Self.tabID)"))
        #expect(unavailable.message.contains("…)"))
        #expect(unavailable.message.contains(", and 2 more from browser.tabs.list({})"))

        // A desktop failure keeps its code readable apart from the message.
        let command = BrowserPlugin.Browser.Command(action: missing)
        state = machine.transitionConnection(state, .requestStarted(sessionID: sessionID, connectionID: "c1", requestID: "r1", command: command)).state
        let settled = machine.transitionConnection(state, .requestSettled(
            sessionID: sessionID,
            connectionID: "c1",
            requestID: "r1",
            outcome: .failure(code: "stale_ref", message: "gone")
        ))
        #expect(settled.effects.contains(.settleRequest(requestID: "r1", settlement: .error(ToolSchema.ToolError(
            message: "[browser.stale_ref] gone",
            metadata: ["code": .string("stale_ref")]
        )))))
    }

    // MARK: - plugin/src contract

    @Test("plugin contract: tool hook info/codemode, OAuth revoke, TUI jobs, GUI browser and built-ins")
    func pluginContract() async throws {
        let before = PluginEffect.ToolHooks.ExecuteBefore(
            tool: "read",
            info: PluginEffect.DynamicToolInfo(name: "read", input: .jsonSchema([:]), description: "", execute: { _, _ in ToolSchema.Result(output: .null) }),
            codemode: true,
            sessionID: SessionID.create(),
            agent: AgentSchema.ID(rawValue: "build"),
            messageID: try #require(SessionMessageSchema.ID(rawValue: "msg_01")),
            id: ToolSchema.CallID(rawValue: "c"),
            input: .object([:])
        )
        #expect(before.codemode && before.info?.name == "read")
        let copy = PluginEffect.ToolHooks.ExecuteBefore(
            tool: before.tool, codemode: true, sessionID: before.sessionID, agent: before.agent,
            messageID: before.messageID, id: before.id, input: before.input
        )
        #expect(before == copy)

        let revoked = Mutex(false)
        let registration = PluginEffect.IntegrationOAuthMethodRegistration(
            integrationID: "x",
            method: PluginEffect.IntegrationOAuthMethod(id: "m", label: "M"),
            authorize: { _ in throw ToolSchema.ToolError(message: "unused") },
            revoke: { _ in revoked.withLock { $0 = true } }
        )
        #expect(registration.revoke != nil)

        #expect(PluginGui.System.isExternalURL("https://example.com"))
        #expect(PluginGui.System.isExternalURL("mailto:a@b.c"))
        #expect(!PluginGui.System.isExternalURL("file:///etc/passwd"))
        let opened = Mutex<[String]>([])
        let system = PluginGui.System(openExternal: { url in opened.withLock { $0.append(url) } })
        system.openExternal("file:///etc/passwd")
        system.openExternal("https://opencode.ai")
        #expect(opened.withLock { $0 } == ["https://opencode.ai"])

        let browser = PluginGui.Browser()
        #expect(await browser.experimental.close(PluginGui.ExperimentalBrowserTab(rawValue: "t")) == false)
        #expect(PluginGui.BuiltinAppLink.registry.id == "app-link")
        #expect(PluginGui.BuiltinPromptGate.registry.id == "prompt-gate")

        let session = PluginGui.SessionRef(
            key: "k", id: "ses_1", tab: "t",
            server: PluginGui.ServerRef(id: "local", name: "Local", url: "http://localhost"), pending: false, location: nil
        )
        let ran = Mutex(0)
        await PluginGui.BuiltinPromptGate.waitAll([
            PluginGui.BuiltinPromptGate(ready: { _ in ran.withLock { $0 += 1 } }),
            PluginGui.BuiltinPromptGate(ready: { _ in throw ToolSchema.ToolError(message: "ignored") }),
        ], session: session)
        #expect(ran.withLock { $0 } == 1)

        let placed = Mutex<[PluginGui.OpenOptions?]>([])
        let layout = PluginGui.BuiltinLayout(base: PluginGui.Layout(open: { _, _, options in placed.withLock { $0.append(options) } }))
        layout.open("browser:tab", session, PluginGui.BuiltinOpenOptions(tab: .append, after: "browser:other"))
        #expect(placed.withLock { $0 } == [PluginGui.OpenOptions(tab: .append)])
        #expect(layout.fitsSide())

        let provided = Mutex<[String]>([])
        let context = PluginGui.BuiltinContext(base: PluginGui.Context(id: "opencode.browser", provideContract: { id, _ in
            provided.withLock { $0.append(id) }
            return {}
        }))
        _ = context.provideFor(PluginGui.Browser.contract) { _, _ in PluginGui.Browser() }
        #expect(provided.withLock { $0 } == ["browser"])
    }
}
