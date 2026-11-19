import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import Synchronization
import Testing

// MARK: - Helpers

private struct SessionRoleKey: SSHContextKey {
    typealias Value = String
}

private func waitUntil(
    timeoutMs: Int = 2_000,
    pollMs: Int = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
    while !condition() {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return true
}

private func assertValidUTF16Highlights(_ content: String, _ highlights: [SimpleHighlight]) {
    let units = Array(content.utf16)
    var prevEnd = 0
    for h in highlights {
        #expect(h.start >= 0)
        #expect(h.start < h.end)
        #expect(h.end <= units.count)
        #expect(h.start >= prevEnd)
        // Must never split a UTF-16 surrogate pair
        if h.start < units.count {
            let u = units[h.start]
            #expect(!(u >= 0xDC00 && u <= 0xDFFF), "Highlight start split surrogate pair at \(h.start)")
        }
        if h.end < units.count {
            let u = units[h.end]
            #expect(!(u >= 0xDC00 && u <= 0xDFFF), "Highlight end split surrogate pair at \(h.end)")
        }
        prevEnd = h.end
    }
}

private func substringOffset(of needle: String, in haystack: String) -> Int? {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty, n.count <= h.count else { return nil }
    for i in 0...(h.count - n.count) {
        var matched = true
        for j in 0..<n.count {
            if h[i + j] != n[j] {
                matched = false
                break
            }
        }
        if matched { return i }
    }
    return nil
}

private func highlightSlice(_ content: String, _ h: SimpleHighlight) -> String {
    let units = Array(content.utf16)
    return String(decoding: units[h.start..<h.end], as: UTF16.self)
}

private func makeDefaultSyntaxStyle() -> SyntaxStyle {
    SyntaxStyle.fromStyles([
        "default": StyleDefinition(fg: RGBA.fromInts(220, 220, 220, 255)),
        "keyword": StyleDefinition(fg: RGBA.fromInts(198, 120, 221, 255), bold: true),
        "string": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "comment": StyleDefinition(fg: RGBA.fromInts(92, 99, 112, 255), italic: true),
        "number": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255)),
        "type": StyleDefinition(fg: RGBA.fromInts(229, 192, 123, 255)),
        "function": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255)),
        "operator": StyleDefinition(fg: RGBA.fromInts(86, 182, 194, 255)),
        "punctuation": StyleDefinition(fg: RGBA.fromInts(171, 178, 191, 255)),
        "property": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
        "boolean": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255), bold: true),
        "constant": StyleDefinition(fg: RGBA.fromInts(209, 154, 102, 255)),
        "markup.heading": StyleDefinition(fg: RGBA.fromInts(97, 175, 239, 255), bold: true),
        "markup.raw": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "diff.plus": StyleDefinition(fg: RGBA.fromInts(152, 195, 121, 255)),
        "diff.minus": StyleDefinition(fg: RGBA.fromInts(224, 108, 117, 255)),
    ])
}

/// Interactive test renderable painting a dynamic status line and responding to clicks.
private final class InteractiveBannerRenderable: Renderable, @unchecked Sendable {
    var text: String {
        didSet { requestRender() }
    }
    var clickCount: Int = 0
    var onClicked: ((Int) -> Void)?

    init(
        ctx: any RenderContext,
        text: String,
        options: RenderableOptions = RenderableOptions(width: .percent(100), height: .point(3))
    ) {
        self.text = text
        super.init(ctx: ctx, options: options)
    }

    override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        guard width > 0 && height > 0 else { return }
        buffer.drawText(
            text,
            x: origin.x,
            y: origin.y,
            fg: RGBA.fromInts(240, 240, 240, 255),
            bg: RGBA.fromInts(20, 30, 50, 255)
        )
    }

    override func onMouseEvent(_ event: MouseEvent) {
        if event.type == .down {
            clickCount += 1
            onClicked?(clickCount)
        }
    }
}

// MARK: - ResolveFiletype Tests

@Suite("ResolveFiletype")
struct ResolveFiletypeTests {
    @Test("extToFiletype resolves extensions with normalization and leading dots")
    func extToFiletypeNormalization() {
        #expect(extToFiletype("swift") == "swift")
        #expect(extToFiletype(".SWIFT") == "swift")
        #expect(extToFiletype("  .tsx  ") == "typescriptreact")
        #expect(extToFiletype("mjs") == "javascript")
        #expect(extToFiletype("cts") == "typescript")
        #expect(extToFiletype("mtsx") == "typescriptreact")
        #expect(extToFiletype("cc") == "cpp")
        #expect(extToFiletype("hxx") == "cpp")
        #expect(extToFiletype("c++") == "cpp")
        #expect(extToFiletype("h++") == "cpp")
        #expect(extToFiletype("hrl") == "erlang")
        #expect(extToFiletype("hs") == "haskell")
        #expect(extToFiletype("ml") == "ocaml")
        #expect(extToFiletype("scala") == "scala")
        #expect(extToFiletype("zon") == "zig")
        #expect(extToFiletype("sh") == "bash")
        #expect(extToFiletype("zsh") == "bash")
        #expect(extToFiletype("patch") == "diff")
        #expect(extToFiletype("pyi") == "python")
        #expect(extToFiletype("fsx") == "fsharp")
        #expect(extToFiletype("") == nil)
        #expect(extToFiletype("   ") == nil)
        #expect(extToFiletype(".") == nil)
        #expect(extToFiletype("nonexistent") == nil)
    }

    @Test("pathToFiletype matches upstream resolve-ft.ts behavior for paths, aliases, and basenames")
    func pathToFiletypeParity() {
        // Bare tokens without dots or basename entries return nil
        #expect(pathToFiletype("tsx") == nil)
        #expect(pathToFiletype("components/Button.tsx") == "typescriptreact")

        // Common extension aliases
        #expect(pathToFiletype("src/index.mjs") == "javascript")
        #expect(pathToFiletype("src/index.cts") == "typescript")
        #expect(pathToFiletype("src/index.mtsx") == "typescriptreact")
        #expect(pathToFiletype("src/module.cc") == "cpp")
        #expect(pathToFiletype("src/module.hxx") == "cpp")
        #expect(pathToFiletype("src/config.hrl") == "erlang")
        #expect(pathToFiletype("src/main.hs") == "haskell")
        #expect(pathToFiletype("src/main.ml") == "ocaml")
        #expect(pathToFiletype("src/main.scala") == "scala")
        #expect(pathToFiletype("src/config.zon") == "zig")
        #expect(pathToFiletype("src/script.sh") == "bash")

        // Windows backslashes & trailing slashes
        #expect(pathToFiletype("C:\\Users\\dev\\App.swift") == "swift")
        #expect(pathToFiletype("/repo/docker/Dockerfile/") == "dockerfile")
        #expect(pathToFiletype("///") == nil)
        #expect(pathToFiletype("file.") == nil)

        // Common basenames & dotfiles
        #expect(pathToFiletype("Dockerfile") == "dockerfile")
        #expect(pathToFiletype("Containerfile") == "dockerfile")
        #expect(pathToFiletype("Makefile") == "make")
        #expect(pathToFiletype("GNUmakefile") == "make")
        #expect(pathToFiletype("Rakefile") == "ruby")
        #expect(pathToFiletype("Gemfile") == "ruby")
        #expect(pathToFiletype(".bashrc") == "bash")
        #expect(pathToFiletype(".vimrc") == "vim")
        #expect(pathToFiletype("/home/user/.zshrc") == "bash")
    }

    @Test("infoStringToFiletype normalizes markdown fence info strings")
    func infoStringToFiletypeParity() {
        #expect(infoStringToFiletype("tsx") == "typescriptreact")
        #expect(infoStringToFiletype("TSX title=Button.tsx") == "typescriptreact")
        #expect(infoStringToFiletype(".jsx") == "javascriptreact")
        #expect(infoStringToFiletype("Button.tsx") == "typescriptreact")
        #expect(infoStringToFiletype("Dockerfile") == "dockerfile")
        #expect(infoStringToFiletype("bash") == "bash")
        #expect(infoStringToFiletype(".bashrc") == "bash")
        #expect(infoStringToFiletype("customlang meta=1") == "customlang")
        #expect(infoStringToFiletype("") == nil)
        #expect(infoStringToFiletype("   ") == nil)
        #expect(infoStringToFiletype(".") == nil)
    }

    @Test("resolveFiletype disambiguates paths, extensions, basenames, and fence info strings")
    func resolveFiletypeConvenience() {
        #expect(resolveFiletype("src/Button.tsx") == "typescriptreact")
        #expect(resolveFiletype("C:\\src\\main.rs") == "rust")
        #expect(resolveFiletype("My Project/app.swift") == "swift")
        #expect(resolveFiletype("python title=script.js") == "python")
        #expect(resolveFiletype("TSX title=App.tsx") == "typescriptreact")
        #expect(resolveFiletype("Dockerfile") == "dockerfile")
        #expect(resolveFiletype(".ts") == "typescript")
        #expect(resolveFiletype("rs") == "rust")
        #expect(resolveFiletype("   ") == nil)
    }
}

// MARK: - SyntaxHighlighter Tests

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    @Test("BuiltInSyntaxHighlighter tokenizes Swift including nested comments, strings, types, and functions")
    func highlightSwift() {
        let code = """
        // Greeting helper 🚀
        /* outer /* inner */ comment */
        public struct Greeter {
            let count: Int = 42
            func greet(name: String) -> Bool {
                return name.isEmpty == false
            }
        }
        """
        let highlighter = BuiltInSyntaxHighlighter.shared
        let result = highlighter.highlight(content: code, filetype: "swift")
        #expect(result.warning == nil)
        assertValidUTF16Highlights(code, result.highlights)

        let byTextAndGroup = result.highlights.map { (highlightSlice(code, $0), $0.group) }
        #expect(byTextAndGroup.contains { $0.0 == "// Greeting helper 🚀" && $0.1 == "comment" })
        #expect(byTextAndGroup.contains { $0.0 == "/* outer /* inner */ comment */" && $0.1 == "comment" })
        #expect(byTextAndGroup.contains { $0.0 == "public" && $0.1 == "keyword" })
        #expect(byTextAndGroup.contains { $0.0 == "struct" && $0.1 == "keyword" })
        #expect(byTextAndGroup.contains { $0.0 == "Greeter" && $0.1 == "type" })
        #expect(byTextAndGroup.contains { $0.0 == "Int" && $0.1 == "type" })
        #expect(byTextAndGroup.contains { $0.0 == "42" && $0.1 == "number" })
        #expect(byTextAndGroup.contains { $0.0 == "greet" && $0.1 == "function" })
        #expect(byTextAndGroup.contains { $0.0 == "isEmpty" && $0.1 == "property" })
        #expect(byTextAndGroup.contains { $0.0 == "false" && $0.1 == "boolean" })
    }

    @Test("BuiltInSyntaxHighlighter tokenizes TypeScript, JSON, Rust, Python, Go, Shell, C++, Markdown, and Diff")
    func highlightMultipleLanguages() {
        let highlighter = BuiltInSyntaxHighlighter.shared

        // TypeScript
        let ts = "export const msg: string = `hi ${name}` // 日本語\nconst ok = true && null"
        let tsRes = highlighter.highlight(content: ts, filetype: "ts")
        assertValidUTF16Highlights(ts, tsRes.highlights)
        #expect(tsRes.highlights.contains { highlightSlice(ts, $0) == "export" && $0.group == "keyword" })
        #expect(tsRes.highlights.contains { highlightSlice(ts, $0) == "string" && $0.group == "type" })
        #expect(tsRes.highlights.contains { highlightSlice(ts, $0) == "`hi ${name}`" && $0.group == "string" })
        #expect(tsRes.highlights.contains { highlightSlice(ts, $0) == "true" && $0.group == "boolean" })
        #expect(tsRes.highlights.contains { highlightSlice(ts, $0) == "null" && $0.group == "constant" })

        // JSON
        let json = """
        {"name": "OpenTUI 🚀", "count": -12.5, "active": true, "extra": null}
        """
        let jsonRes = highlighter.highlight(content: json, filetype: "json")
        assertValidUTF16Highlights(json, jsonRes.highlights)
        #expect(jsonRes.highlights.contains { highlightSlice(json, $0) == "\"name\"" && $0.group == "property" })
        #expect(jsonRes.highlights.contains { highlightSlice(json, $0) == "\"OpenTUI 🚀\"" && $0.group == "string" })
        #expect(jsonRes.highlights.contains { highlightSlice(json, $0) == "-12.5" && $0.group == "number" })
        #expect(jsonRes.highlights.contains { highlightSlice(json, $0) == "true" && $0.group == "boolean" })
        #expect(jsonRes.highlights.contains { highlightSlice(json, $0) == "null" && $0.group == "constant" })

        // Rust (including lifetimes & raw strings)
        let rust = """
        pub fn parse<'a>(input: &'a str) -> Option<usize> {
            let raw = r#"hello 'a' world"#;
            let ch = 'x';
            println!("{}", raw);
            Some(input.len())
        }
        """
        let rustRes = highlighter.highlight(content: rust, filetype: "rs")
        assertValidUTF16Highlights(rust, rustRes.highlights)
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "pub" && $0.group == "keyword" })
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "parse" && $0.group == "function" })
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "'a" && $0.group == "type" })
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "r#\"hello 'a' world\"#" && $0.group == "string" })
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "'x'" && $0.group == "string" })
        #expect(rustRes.highlights.contains { highlightSlice(rust, $0) == "Some" && $0.group == "constant" })

        // Python
        let py = """
        # Compute sum
        @cache
        def add(a: int, b: int) -> int:
            msg = f"sum={a + b}"
            return a + b if True else None
        """
        let pyRes = highlighter.highlight(content: py, filetype: "py")
        assertValidUTF16Highlights(py, pyRes.highlights)
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "# Compute sum" && $0.group == "comment" })
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "def" && $0.group == "keyword" })
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "add" && $0.group == "function" })
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "True" && $0.group == "boolean" })
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "None" && $0.group == "constant" })
        #expect(pyRes.highlights.contains { highlightSlice(py, $0) == "f\"sum={a + b}\"" && $0.group == "string" })

        // Go
        let goCode = "package main\nfunc main() { s := `raw`; _ = iota }"
        let goRes = highlighter.highlight(content: goCode, filetype: "go")
        assertValidUTF16Highlights(goCode, goRes.highlights)
        #expect(goRes.highlights.contains { highlightSlice(goCode, $0) == "package" && $0.group == "keyword" })
        #expect(goRes.highlights.contains { highlightSlice(goCode, $0) == "`raw`" && $0.group == "string" })
        #expect(goRes.highlights.contains { highlightSlice(goCode, $0) == "iota" && $0.group == "constant" })

        // Shell
        let sh = "# comment\nexport FOO=\"bar\"\nif true; then echo $FOO; fi"
        let shRes = highlighter.highlight(content: sh, filetype: "sh")
        assertValidUTF16Highlights(sh, shRes.highlights)
        #expect(shRes.highlights.contains { highlightSlice(sh, $0) == "# comment" && $0.group == "comment" })
        #expect(shRes.highlights.contains { highlightSlice(sh, $0) == "export" && $0.group == "keyword" })
        #expect(shRes.highlights.contains { highlightSlice(sh, $0) == "$FOO" && $0.group == "constant" })

        // C++
        let cpp = "#include <vector>\nint main() { return nullptr == 0 ? 1 : 0; }"
        let cppRes = highlighter.highlight(content: cpp, filetype: "cpp")
        assertValidUTF16Highlights(cpp, cppRes.highlights)
        #expect(cppRes.highlights.contains { highlightSlice(cpp, $0) == "#include" && $0.group == "keyword" })
        #expect(cppRes.highlights.contains { highlightSlice(cpp, $0) == "nullptr" && $0.group == "constant" })

        // Markdown
        let md = "# Heading 🚀\nUse `swift test` here.\n```swift\nlet x = 1\n```"
        let mdRes = highlighter.highlight(content: md, filetype: "md")
        assertValidUTF16Highlights(md, mdRes.highlights)
        #expect(mdRes.highlights.contains { highlightSlice(md, $0) == "# Heading 🚀" && $0.group == "markup.heading" })
        #expect(mdRes.highlights.contains { highlightSlice(md, $0) == "`swift test`" && $0.group == "markup.raw" })
        #expect(mdRes.highlights.contains { highlightSlice(md, $0) == "let x = 1" && $0.group == "markup.raw" })

        // Unified Diff
        let diff = """
        diff --git a/app.swift b/app.swift
        --- a/app.swift
        +++ b/app.swift
        @@ -1,3 +1,3 @@
         let unchanged = 1
        -let oldVal = "日本語"
        +let newVal = "🚀🇺🇸"
        """
        let diffRes = highlighter.highlight(content: diff, filetype: "diff")
        assertValidUTF16Highlights(diff, diffRes.highlights)
        #expect(diffRes.highlights.contains { highlightSlice(diff, $0) == "--- a/app.swift" && $0.group == "comment" })
        #expect(diffRes.highlights.contains { highlightSlice(diff, $0) == "+++ b/app.swift" && $0.group == "comment" })
        #expect(diffRes.highlights.contains { highlightSlice(diff, $0) == "@@ -1,3 +1,3 @@" && $0.group == "markup.heading" })
        #expect(diffRes.highlights.contains { highlightSlice(diff, $0) == "-let oldVal = \"日本語\"" && $0.group == "diff.minus" })
        #expect(diffRes.highlights.contains { highlightSlice(diff, $0) == "+let newVal = \"🚀🇺🇸\"" && $0.group == "diff.plus" })
    }

    @Test("BuiltInSyntaxHighlighter integrates with treeSitterToTextChunks & SyntaxStyle preserving emoji/CJK UTF-16 fidelity")
    func syntaxStyleAndTextChunksRoundTrip() {
        let samples: [(String, String)] = [
            ("swift", "let 🚀label = \"こんにちは 🇺🇸👨‍👩‍👧‍👦\"\n// コメント\nreturn 123"),
            ("typescript", "const title: string = \"日本語 🚀\"; /* ok */ return true;"),
            ("json", "{\"emoji\": \"🚀🇺🇸\", \"日本語\": 42, \"ok\": false}"),
            ("python", "# 日本語 🚀\ndef run(x: str) -> bool:\n    return x == \"中文\""),
            ("diff", "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-旧 🚀\n+新 🇺🇸"),
        ]

        let style = makeDefaultSyntaxStyle()
        let highlighter = BuiltInSyntaxHighlighter.shared

        for (ft, source) in samples {
            let result = highlighter.highlight(content: source, filetype: ft)
            assertValidUTF16Highlights(source, result.highlights)
            #expect(!result.highlights.isEmpty)

            let chunks = treeSitterToTextChunks(
                content: source,
                highlights: result.highlights,
                syntaxStyle: style
            )
            let reconstructed = chunks.map(\.text).joined()
            #expect(reconstructed == source, "Round-trip text mismatch for \(ft)")
            #expect(chunks.contains { $0.fg != nil })
        }
    }

    @Test("highlightOnce async API, unsupported filetype warning, and Static/Mock highlighters")
    func asyncAndDeterministicHighlighters() async {
        let builtIn = BuiltInSyntaxHighlighter.shared
        let asyncRes = await builtIn.highlightOnce(content: "let x = 1", filetype: "swift")
        #expect(asyncRes.warning == nil)
        #expect(!asyncRes.highlights.isEmpty)

        let unsupported = builtIn.highlight(content: "hello", filetype: "brainfuck")
        #expect(unsupported.highlights.isEmpty)
        #expect(unsupported.warning != nil)

        let staticHL = StaticSyntaxHighlighter(
            highlights: [SimpleHighlight(0, 3, "keyword")],
            resultsByFiletype: [
                "json": SyntaxHighlightResult(highlights: [SimpleHighlight(0, 4, "constant")])
            ]
        )
        #expect(staticHL.highlight(content: "let", filetype: "swift").highlights == [SimpleHighlight(0, 3, "keyword")])
        #expect(staticHL.highlight(content: "null", filetype: ".json").highlights == [SimpleHighlight(0, 4, "constant")])

        let mock = MockSyntaxHighlighter(
            defaultResult: SyntaxHighlightResult(highlights: [SimpleHighlight(0, 2, "operator")], warning: "mock-warn")
        )
        let r1 = mock.highlight(content: "==", filetype: "swift")
        let r2 = await mock.highlightOnce(content: "!=", filetype: "rust")
        #expect(r1.warning == "mock-warn")
        #expect(r2.highlights == [SimpleHighlight(0, 2, "operator")])
        #expect(mock.recordedCalls == [
            MockSyntaxHighlighter.Call(content: "==", filetype: "swift", isAsync: false),
            MockSyntaxHighlighter.Call(content: "!=", filetype: "rust", isAsync: true),
        ])
        mock.reset()
        #expect(mock.recordedCalls.isEmpty)
    }
}

// MARK: - SSHCliRenderer & TerminalBackend Tests

@Suite("SSHCliRenderer")
struct SSHCliRendererTests {
    @Test("End-to-end SSH open session: middleware -> live CliRenderer -> keystrokes & mouse -> window-change -> disconnect")
    func endToEndOpenSSHSession() async throws {
        let hostKey = generateEd25519KeyPair()
        let driver = InMemorySSHTransportDriver()

        let capturedRenderer = Mutex<CliRenderer?>(nil)
        let capturedAdapter = Mutex<SSHCliRendererAdapter?>(nil)
        let observedRole = Mutex<String?>(nil)
        let resizeEvents = Mutex<[(Int, Int)]>([])
        let initialReady = Mutex(false)

        let server = try createCliSSHServer(
            config: SSHServerConfig(
                auth: .open,
                hostKey: .pem(hostKey.privatePem),
                startupBanner: false
            ),
            rendererConfig: SSHCliRendererConfig(
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: true
            ),
            driver: driver
        )
        .use { session, next in
            try await next(SessionRoleKey.self, value: "operator:\(session.identity.username)")
        }
        .serve { session in
            observedRole.withLock { $0 = session.context[SessionRoleKey.self] }
            guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else {
                Issue.record("Expected live CliRenderer attached via SSHCliRendererAdapter")
                return
            }
            capturedRenderer.withLock { $0 = cli }
            capturedAdapter.withLock { $0 = adapter }

            let banner = InteractiveBannerRenderable(ctx: cli, text: "READY:60x20")
            banner.text = "BOOT:\(cli.width)x\(cli.height)"
            cli.root.add(banner)

            _ = cli.keyInput.onKeypress { key in
                banner.text = "KEY=\(key.name)"
                cli.renderOnce()
            }
            banner.onClicked = { clicks in
                banner.text = "CLICKED-\(clicks)"
                cli.renderOnce()
            }
            _ = session.onResize { cols, rows in
                resizeEvents.withLock { $0.append((cols, rows)) }
                banner.text = "DIM=\(cols)x\(rows)"
                cli.renderOnce()
            }

            cli.renderOnce(force: true)
            await adapter.flushOutput()
            initialReady.withLock { $0 = true }
        }

        let listenInfo = try await server.listen(port: 0, host: "127.0.0.1")
        #expect(listenInfo.port > 0)

        let client = driver.connect()
        let authResult = await client.authenticate(method: "none", username: "alice")
        #expect(authResult == .accepted)
        client.emitReady()

        let sessionChannel = client.openSession()
        #expect(sessionChannel.requestPty(term: "xterm-256color", cols: 60, rows: 20))
        let channel = try #require(sessionChannel.requestShell())

        #expect(await waitUntil { initialReady.withLock { $0 } })
        let cli = try #require(capturedRenderer.withLock { $0 })
        let adapter = try #require(capturedAdapter.withLock { $0 })

        #expect(observedRole.withLock { $0 } == "operator:alice")
        #expect(cli.width == 60)
        #expect(cli.height == 20)
        #expect(server.activeSessions == 1)

        // Verify alternate screen setup and rendered initial ANSI frame on SSH channel
        #expect(await waitUntil { channel.writtenText.contains("BOOT:60x20") })
        #expect(channel.writtenText.contains(ANSI.switchToAlternateScreen))

        // 1. Send keystroke over SSH stdin -> CliRenderer updates banner & diffs ANSI frame
        channel.receiveText("z")
        await adapter.flushOutput()
        #expect(cli.captureCharFrame().contains("KEY=z"))
        #expect(await waitUntil { channel.writtenText.contains("KEY=z") })

        // 2. Send SGR left-mouse down+up at (col=2, row=1) over SSH stdin -> hits banner & diffs frame
        channel.receiveText("\u{1B}[<0;2;1M\u{1B}[<0;2;1m")
        await adapter.flushOutput()
        #expect(cli.captureCharFrame().contains("CLICKED-1"))
        #expect(await waitUntil { channel.writtenText.contains("CLICKED-1") })

        // 3. Send SSH window-change resize -> CliRenderer resizes & re-renders
        sessionChannel.sendWindowChange(cols: 100, rows: 35)
        await adapter.flushOutput()
        #expect(cli.captureCharFrame().contains("DIM=100x35"))
        #expect(await waitUntil { channel.writtenText.contains("DIM=100x35") })
        #expect(cli.width == 100)
        #expect(cli.height == 35)
        let lastResize = resizeEvents.withLock { $0 }.last
        #expect(lastResize?.0 == 100 && lastResize?.1 == 35)
        let backendSize = await adapter.backend.size
        #expect(backendSize == TerminalSize(width: 100, height: 35))

        // 4. Client disconnects -> CliRenderer destroys cleanly & active session releases
        channel.emitClose()
        #expect(await waitUntil { cli.isDestroyed && server.activeSessions == 0 })
        #expect(adapter.isDestroyed)

        await server.close()
    }

    @Test("End-to-end SSH password auth + app-initiated CliRenderer.destroy() emits alt-screen cleanup before channel close")
    func passwordAuthAndCleanRendererTeardown() async throws {
        let hostKey = generateEd25519KeyPair()
        let driver = InMemorySSHTransportDriver()
        let attachedRenderer = Mutex<CliRenderer?>(nil)
        let attachedAdapter = Mutex<SSHCliRendererAdapter?>(nil)

        let server = try createCliSSHServer(
            config: SSHServerConfig(
                auth: .methods(SSHAuthMethods(
                    password: { ctx in
                        ctx.username == "bob" && timingSafeEqual(ctx.password, "s3cr3t")
                    }
                )),
                hostKey: .pem(hostKey.privatePem),
                startupBanner: false
            ),
            rendererConfig: SSHCliRendererConfig(
                screenMode: .alternateScreen,
                exitOnCtrlC: true,
                useMouse: true
            ),
            driver: driver
        )
        .serve { session in
            guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else { return }
            let banner = InteractiveBannerRenderable(ctx: cli, text: "AUTH:\(session.identity.username)")
            cli.root.add(banner)
            cli.renderOnce(force: true)
            await adapter.flushOutput()
            attachedRenderer.withLock { $0 = cli }
            attachedAdapter.withLock { $0 = adapter }
        }

        _ = try await server.listen(port: 0, host: "127.0.0.1")

        let client = driver.connect()
        // Wrong password rejected
        let badAuth = await client.authenticate(method: "password", username: "bob", password: "wrong")
        #expect(badAuth == .rejected([.password]))

        // Valid password accepted
        let goodAuth = await client.authenticate(method: "password", username: "bob", password: "s3cr3t")
        #expect(goodAuth == .accepted)
        client.emitReady()

        let sessionChannel = client.openSession()
        sessionChannel.requestPty(term: "xterm-256color", cols: 72, rows: 22)
        let channel = try #require(sessionChannel.requestShell())

        #expect(await waitUntil { attachedRenderer.withLock { $0 } != nil })
        let cli = try #require(attachedRenderer.withLock { $0 })
        #expect(await waitUntil { channel.writtenText.contains("AUTH:bob") })

        // Trigger Ctrl+C over SSH stdin -> CliRenderer.destroy() runs -> emits alt-screen exit before channel close
        channel.receiveData([0x03])

        #expect(await waitUntil { cli.isDestroyed && channel.isClosed && server.activeSessions == 0 })
        let output = channel.writtenText
        #expect(output.contains(ANSI.switchToAlternateScreen))
        #expect(output.contains(ANSI.switchToMainScreen))
        #expect(output.contains("\u{1B}[?25h"))
        #expect(channel.exits == [0])

        await server.close()
    }

    @Test("End-to-end SSH publickey auth attaches live CliRenderer with authenticated identity")
    func publicKeyAuthEndToEnd() async throws {
        let hostKey = generateEd25519KeyPair()
        let userKey = generateEd25519KeyPair().parsed
        let blob = Array("session-verify-blob".utf8)

        let useRealCrypto = userKey.sign(blob: blob) != nil
        let verifier: any SSHSignatureVerifier = useRealCrypto
            ? DefaultSSHSignatureVerifier()
            : ClosureSSHSignatureVerifier { key, msg, sig, _ in
                timingSafeEqual(sig, SSHSHA256.hash(key.blob + msg))
            }
        let signature = userKey.sign(blob: blob) ?? SSHSHA256.hash(userKey.publicSSH + blob)

        let driver = InMemorySSHTransportDriver()
        let renderedIdentity = Mutex<SSHIdentity?>(nil)

        let server = try createCliSSHServer(
            config: SSHServerConfig(
                auth: .methods(SSHAuthMethods(
                    publicKey: .policy(SSHPublicKeyPolicy(
                        authorizedKeys: .keys(["\(userKey.type) \(userKey.publicSSHBase64) carol@host"])
                    ))
                )),
                hostKey: .pem(hostKey.privatePem),
                startupBanner: false,
                signatureVerifier: verifier
            ),
            driver: driver
        )
        .serve { session in
            renderedIdentity.withLock { $0 = session.identity }
            guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else { return }
            let fp = session.identity.fingerprint ?? "none"
            let banner = InteractiveBannerRenderable(ctx: cli, text: "PK:\(session.identity.username):\(fp.prefix(12))")
            cli.root.add(banner)
            cli.renderOnce(force: true)
            await adapter.flushOutput()
        }

        _ = try await server.listen(port: 0, host: "127.0.0.1")

        let client = driver.connect()
        let authResult = await client.authenticate(
            method: "publickey",
            username: "carol",
            keyAlgorithm: userKey.type,
            keyData: userKey.publicSSH,
            signature: signature,
            blob: blob
        )
        #expect(authResult == .accepted)
        client.emitReady()

        let sessionChannel = client.openSession()
        sessionChannel.requestPty(term: "xterm-256color", cols: 84, rows: 26)
        let channel = try #require(sessionChannel.requestShell())

        #expect(await waitUntil { channel.writtenText.contains("PK:carol:SHA256:") })
        let identity = try #require(renderedIdentity.withLock { $0 })
        #expect(identity.method == .publicKey)
        #expect(identity.username == "carol")
        #expect(identity.fingerprint == userKey.fingerprint)

        await server.close()
        #expect(await waitUntil { server.activeSessions == 0 })
    }

    @Test("SSHCliRendererAdapter preserves FIFO output under channel backpressure and closes cleanly")
    func backpressureAndShutdownDrain() async throws {
        let channel = InMemorySSHChannel()
        let pressureErrors = Mutex(0)

        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                pty: SSHPtyInfo(term: "xterm-256color", cols: 50, rows: 10, hasPty: true),
                identity: .none(username: "bp"),
                createRenderer: createCliRendererSSHFactory(
                    config: SSHCliRendererConfig(
                        screenMode: .alternateScreen,
                        useMouse: false,
                        onOutputError: { err in
                            if err is OutputPressureError {
                                pressureErrors.withLock { $0 += 1 }
                            }
                        }
                    )
                )
            )
        )

        let handlerReady = Mutex(false)
        let sessionTask = Task {
            try await bridge.enterApp { session in
                guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else { return }
                let banner = InteractiveBannerRenderable(ctx: cli, text: "FRAME-1")
                cli.root.add(banner)

                // Hold channel to simulate peer TCP window backpressure
                channel.hold()
                cli.renderOnce(force: true)
                banner.text = "SECOND-2"
                cli.renderOnce()
                await adapter.flushOutput()
                handlerReady.withLock { $0 = true }
            }
        }

        #expect(await waitUntil { handlerReady.withLock { $0 } })
        // Release backpressure -> queued chunks flush in strict FIFO order
        channel.release()

        let text = channel.writtenText
        let idx1 = try #require(substringOffset(of: "FRAME-1", in: text))
        let idx2 = try #require(substringOffset(of: "SECOND-2", in: text))
        #expect(idx1 < idx2)
        #expect(pressureErrors.withLock { $0 } == 0)

        await bridge.destroy()
        _ = try await sessionTask.value
        #expect(channel.isClosed)
    }

    @Test("runWithTerminalBackend wires MemoryTerminalBackend raw mode, size sync, input, rendering, and cleanup")
    func runWithMemoryTerminalBackend() async throws {
        let backend = MemoryTerminalBackend(size: TerminalSize(width: 90, height: 30))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: 40,
                height: 12,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: true,
                clock: ManualClock()
            )
        )
        let banner = InteractiveBannerRenderable(ctx: renderer, text: "BOOT")
        renderer.root.add(banner)
        _ = renderer.keyInput.onKeypress { key in
            banner.text = "PRESSED:\(key.name)"
        }

        let observedRawMode = try await runWithTerminalBackend(
            renderer: renderer,
            backend: backend
        ) { liveRenderer, session in
            let rawDuringRun = await backend.isRawMode
            #expect(rawDuringRun)
            #expect(liveRenderer.width == 90)
            #expect(liveRenderer.height == 30)

            // Resize backend and sync into live CliRenderer
            await backend.resize(to: TerminalSize(width: 110, height: 40))
            _ = await session.syncSize()
            #expect(liveRenderer.width == 110)
            #expect(liveRenderer.height == 40)

            // Feed input and render updated frame
            session.feedInput("k")
            await session.renderNow()
            return rawDuringRun
        }

        #expect(observedRawMode == true)
        #expect(await backend.isRawMode == false)
        #expect(renderer.isDestroyed == true)

        let rendered = await backend.renderedOutput
        #expect(rendered.contains(ANSI.switchToAlternateScreen))
        #expect(rendered.contains("BOOT"))
        #expect(rendered.contains("PRESSED:k"))
        #expect(rendered.contains(ANSI.switchToMainScreen))
        #expect(rendered.contains("\u{1B}[?25h"))
    }

    @Test("runWithTerminalBackend wait-until-destroy overload exits cleanly when renderer.destroy() is invoked")
    func runWithTerminalBackendUntilDestroy() async throws {
        let backend = MemoryTerminalBackend(size: TerminalSize(width: 64, height: 18))
        let renderer = CliRenderer(
            config: CliRendererConfig(
                width: 64,
                height: 18,
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                useMouse: false,
                clock: ManualClock()
            )
        )
        let banner = InteractiveBannerRenderable(ctx: renderer, text: "LIVE-LOOP")
        renderer.root.add(banner)

        let runnerTask = Task {
            try await runWithTerminalBackend(renderer: renderer, backend: backend)
        }

        var reachedLive = false
        for _ in 0..<200 {
            if await backend.isRawMode, (await backend.renderedOutput).contains("LIVE-LOOP") {
                reachedLive = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reachedLive)
        #expect(await backend.isRawMode == true)

        // Destroy renderer to end runWithTerminalBackend cleanly
        renderer.destroy()
        try await runnerTask.value

        #expect(renderer.isDestroyed == true)
        #expect(await backend.isRawMode == false)
        let out = await backend.renderedOutput
        #expect(out.contains("LIVE-LOOP"))
        #expect(out.contains(ANSI.switchToMainScreen))
    }
}
