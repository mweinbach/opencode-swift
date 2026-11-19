import OpenTUICore
import Testing

// MARK: - KeyBindings Tests

@Suite("KeyBindingTests")
struct KeyBindingTests {
    @Test("Key serialization, event helper, and human-readable formatting")
    func serializationAndFormatting() {
        let binding = KeyBinding(name: "y", ctrl: true, shift: true, action: "redo")
        #expect(getKeyBindingKey(binding) == "y:1:1:0:0")
        #expect(keyBindingToString(binding) == "ctrl+shift+y")

        let superSave = KeyBinding(name: "s", super: true, action: "save")
        #expect(getKeyBindingKey(superSave) == "s:0:0:0:1")
        #expect(keyBindingToString(superSave) == "super+s")

        let plainEsc = KeyBinding(name: "escape", action: "cancel")
        #expect(keyBindingToString(plainEsc) == "escape")

        let parsed = ParsedKey(
            name: "c",
            ctrl: true,
            meta: false,
            shift: false,
            sequence: "\u{03}",
            raw: "\u{03}",
            super: false
        )
        let event = KeyEvent(parsed)
        #expect(getKeyBindingKeyFromEvent(event) == "c:1:0:0:0")
    }

    @Test("Merging key bindings preserves order and overrides matching chords")
    func mergeKeyBindingsOrderAndOverride() {
        let defaults = [
            KeyBinding(name: "up", action: "move-up"),
            KeyBinding(name: "down", action: "move-down"),
            KeyBinding(name: "return", action: "submit"),
        ]
        let custom = [
            KeyBinding(name: "down", action: "next-item"),
            KeyBinding(name: "j", ctrl: true, action: "move-down"),
        ]
        let merged = mergeKeyBindings(defaults, custom)
        #expect(merged.count == 4)
        #expect(merged[0].action == "move-up")
        #expect(merged[1].action == "next-item")
        #expect(merged[2].action == "submit")
        #expect(merged[3].action == "move-down")
    }

    @Test("Alias merging and compiled lookup map")
    func aliasesAndCompiledMap() {
        let aliases = mergeKeyAliases(defaultKeyAliases, ["spacebar": "space"])
        #expect(aliases["enter"] == "return")
        #expect(aliases["esc"] == "escape")
        #expect(aliases["spacebar"] == "space")

        let bindings = [
            KeyBinding(name: "enter", action: "confirm"),
            KeyBinding(name: "esc", action: "dismiss"),
            KeyBinding(name: "kpup", action: "prev"),
        ]
        let map = buildKeyBindingsMap(bindings, aliasMap: defaultKeyAliases)
        #expect(map["enter:0:0:0:0"] == "confirm")
        #expect(map["return:0:0:0:0"] == "confirm")
        #expect(map["escape:0:0:0:0"] == "dismiss")
        #expect(map["up:0:0:0:0"] == "prev")
    }

    @Test("Kitty base-layout fallback resolves non-Latin and AZERTY digit chords without hijacking Dvorak")
    func kittyBaseCodeFallback() {
        let map = buildKeyBindingsMap([
            KeyBinding(name: "c", ctrl: true, action: "copy"),
            KeyBinding(name: "1", ctrl: true, action: "tab-1"),
            KeyBinding(name: "j", ctrl: true, action: "newline"),
        ])

        // Hangul ㅊ with Kitty baseCode 99 ('c') -> resolves Ctrl+C
        let hangulKey = ParsedKey(name: "ㅊ", ctrl: true, sequence: "", raw: "", baseCode: 99)
        let hangulEvent = KeyEvent(hangulKey)
        #expect(getKeyBindingKeys(hangulEvent) == ["ㅊ:1:0:0:0", "c:1:0:0:0"])
        #expect(getKeyBindingAction(map, hangulEvent) == "copy")
        #expect(matchesKeyBinding(hangulEvent, KeyBindingLookup(name: "c", ctrl: true)))

        // Uppercase baseCode 67 ('C') normalizes to lowercase 'c'
        let upperBase = KeyBindingLookup(name: "с", ctrl: true, baseCode: 67)
        #expect(getKeyBindingAction(map, upperBase) == "copy")

        // AZERTY '&' on physical '1' key (baseCode 49) -> resolves Ctrl+1
        let azertyDigit = KeyBindingLookup(name: "&", ctrl: true, baseCode: 49)
        #expect(getKeyBindingAction(map, azertyDigit) == "tab-1")

        // Dvorak Ctrl+J with physical baseCode 'c' (99) must stay Ctrl+J (ASCII typed name, non-digit baseCode)
        let dvorak = KeyBindingLookup(name: "j", ctrl: true, baseCode: 99)
        #expect(getKeyBindingKeys(dvorak) == ["j:1:0:0:0"])
        #expect(getKeyBindingAction(map, dvorak) == "newline")
    }
}

// MARK: - Clipboard Tests

@Suite("ClipboardTests")
struct ClipboardTests {
    @Test("Pure-Swift Base64 encodes and decodes ASCII, padding variants, and UTF-8 emoji")
    func base64RoundTrip() {
        #expect(base64Encode("") == "")
        #expect(base64Encode("f") == "Zg==")
        #expect(base64Encode("fo") == "Zm8=")
        #expect(base64Encode("foo") == "Zm9v")
        #expect(base64Encode("foobar") == "Zm9vYmFy")
        #expect(base64Encode("Hello, OpenTUI!") == "SGVsbG8sIE9wZW5UVUkh")

        let unicode = "こんにちは 🚀 OpenTUI"
        let encoded = base64Encode(unicode)
        let decodedBytes = base64Decode(encoded)
        #expect(decodedBytes == Array(unicode.utf8))
        #expect(base64Decode("invalid!base64") == nil)
        #expect(base64Decode("abc") == nil)
    }

    @Test("OSC 52 encoding supports standard, tmux passthrough, and GNU screen chunked passthrough")
    func osc52EncodingModes() {
        // Standard ST terminator
        let standard = Osc52Clipboard.encodeCopy("hello", target: .clipboard, passthrough: .none)
        #expect(standard == "\u{1B}]52;c;aGVsbG8=\u{1B}\\")

        let primary = Osc52Clipboard.encodeCopy("hi", target: .primary, passthrough: .none)
        #expect(primary == "\u{1B}]52;p;aGk=\u{1B}\\")

        let secondary = Osc52Clipboard.encodeCopy("hi", target: .secondary, passthrough: .none)
        #expect(secondary == "\u{1B}]52;q;aGk=\u{1B}\\")

        let query = Osc52Clipboard.encodeQuery(target: .clipboard, passthrough: .none)
        #expect(query == "\u{1B}]52;c;?\u{1B}\\")

        let clear = Osc52Clipboard.encodeClear(target: .clipboard, passthrough: .none)
        #expect(clear == "\u{1B}]52;c;\u{1B}\\")

        // Tmux DCS passthrough doubles embedded ESC bytes
        let tmux = Osc52Clipboard.encodeCopy("hello", target: .clipboard, passthrough: .tmux)
        #expect(tmux == "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;aGVsbG8=\u{1B}\u{1B}\\\u{1B}\\")

        // GNU screen DCS passthrough uses BEL terminator and chunks to <= 252 bytes per DCS block
        let screenShort = Osc52Clipboard.encodeCopy("hello", target: .clipboard, passthrough: .screen)
        #expect(screenShort == "\u{1B}P\u{1B}]52;c;aGVsbG8=\u{07}\u{1B}\\")

        let longText = String(repeating: "A", count: 400)
        let screenLong = Osc52Clipboard.encodeCopy(longText, target: .clipboard, passthrough: .screen)
        #expect(screenLong.hasPrefix("\u{1B}P\u{1B}]52;c;"))
        #expect(screenLong.hasSuffix("\u{07}\u{1B}\\"))
        // Multiple DCS wrappers emitted for >252 byte payload
        let dcsCount = screenLong.componentsSeparated(by: "\u{1B}P").count - 1
        #expect(dcsCount >= 2)
    }

    @Test("OSC 52 capability detection, writer dispatch, and renderer adapter")
    func capabilityAndAdapter() {
        #expect(Osc52Clipboard.isOsc52Supported(environment: ["TERM_PROGRAM": "ghostty"]))
        #expect(Osc52Clipboard.isOsc52Supported(environment: ["TERM": "xterm-256color"]))
        #expect(Osc52Clipboard.isOsc52Supported(environment: ["WT_SESSION": "1"]))
        #expect(!Osc52Clipboard.isOsc52Supported(environment: ["TERM": "dumb"]))
        #expect(!Osc52Clipboard.isOsc52Supported(environment: ["TERM_PROGRAM": "ghostty"], osc52Support: .unsupported))

        #expect(Osc52Clipboard.detectPassthrough(environment: ["TMUX": "/tmp/tmux-1000/default,1,0"]) == .tmux)
        #expect(Osc52Clipboard.detectPassthrough(environment: ["STY": "1234.pts-0"]) == .screen)
        #expect(Osc52Clipboard.detectPassthrough(environment: ["TERM": "xterm-256color"]) == .none)

        final class Sink: @unchecked Sendable {
            var written: [String] = []
        }
        let sink = Sink()
        let clipboard = Clipboard(passthrough: .none, osc52Support: .supported, remote: false) { seq in
            sink.written.append(seq)
            return true
        }
        #expect(clipboard.isOsc52Supported())
        #expect(clipboard.copyToClipboardOSC52("abc", target: .clipboard))
        #expect(clipboard.clearClipboardOSC52(target: .primary))
        #expect(sink.written == [
            "\u{1B}]52;c;YWJj\u{1B}\\",
            "\u{1B}]52;p;\u{1B}\\",
        ])

        let adapter = createRendererClipboardAdapter(clipboard)
        #expect(!adapter.remote)
        let writeRes = adapter.writeText("ok", selection: .clipboard)
        #expect(writeRes == TerminalClipboardOperationResult(status: .attempted, capability: .supported))

        let unsupported = Clipboard(osc52Support: .unsupported) { _ in true }
        let unsupportedAdapter = createRendererClipboardAdapter(unsupported)
        #expect(unsupportedAdapter.writeText("x", selection: .clipboard).status == .notAttempted)
    }
}

private extension String {
    func componentsSeparated(by separator: String) -> [String] {
        guard !separator.isEmpty else { return [self] }
        let bytes = Array(self.utf8)
        let sep = Array(separator.utf8)
        var result: [String] = []
        var start = 0
        var i = 0
        while i + sep.count <= bytes.count {
            var match = true
            for j in 0..<sep.count where bytes[i + j] != sep[j] {
                match = false
                break
            }
            if match {
                result.append(String(decoding: bytes[start..<i], as: UTF8.self))
                i += sep.count
                start = i
            } else {
                i += 1
            }
        }
        result.append(String(decoding: bytes[start..<bytes.count], as: UTF8.self))
        return result
    }
}

// MARK: - TerminalPalette Tests

@Suite("TerminalPaletteTests")
struct TerminalPaletteTests {
    @Test("Parses OSC 4 and OSC 10-19 replies with 16-bit rgb: scaling and #rrggbb hex")
    func parseOscReplies() {
        let reply =
            "\u{1B}]4;0;rgb:0000/0000/0000\u{07}"
            + "\u{1B}]4;1;rgb:ffff/8080/0000\u{1B}\\"
            + "\u{1B}]4;15;#AABBCC\u{07}"
            + "\u{1B}]10;rgb:eeee/eeee/eeee\u{07}"
            + "\u{1B}]11;#101820\u{1B}\\"
            + "\u{1B}]12;rgb:f/0/f\u{07}"
            + "\u{1B}]17;rgb:1212/3434/5656\u{07}"
            + "\u{1B}]19;rgb:abab/cdcd/efef\u{1B}\\"

        let parsed = parseOscColorResponse(reply, size: 16)
        #expect(parsed.palette.count == 16)
        #expect(parsed.palette[0] == "#000000")
        #expect(parsed.palette[1] == "#ff8000")
        #expect(parsed.palette[15] == "#aabbcc")
        #expect(parsed.palette[2] == nil)
        #expect(parsed.defaultForeground == "#eeeeee")
        #expect(parsed.defaultBackground == "#101820")
        #expect(parsed.cursorColor == "#ff00ff")
        #expect(parsed.highlightBackground == "#123456")
        #expect(parsed.highlightForeground == "#abcdef")

        // Re-applying identical replies reports changed == false
        var mutable = parsed
        #expect(!applyPaletteReplies(&mutable, sequence: reply))
    }

    @Test("Builds standard, tmux, and legacy-tmux palette queries")
    func queryBuilders() {
        let plain = buildPaletteQueries(size: 2, includeSpecialColors: true, inTmux: false, inLegacyTmux: false)
        #expect(plain.contains("\u{1B}]4;0;?\u{07}\u{1B}]4;1;?\u{07}"))
        #expect(plain.contains("\u{1B}]10;?\u{07}"))
        #expect(plain.contains("\u{1B}]19;?\u{07}"))

        let tmux = buildPaletteQueries(size: 2, includeSpecialColors: true, inTmux: true, inLegacyTmux: false)
        #expect(tmux.contains("\u{1B}]10;?\u{07}\u{1B}]11;?\u{07}\u{1B}]12;?\u{07}"))
        #expect(!tmux.contains("\u{1B}]19;?\u{07}"))

        let legacyTmux = buildPaletteQueries(size: 1, includeSpecialColors: false, inLegacyTmux: true)
        #expect(legacyTmux == "\u{1B}Ptmux;\u{1B}\u{1B}]4;0;?\u{07}\u{1B}\\")
    }

    @Test("TerminalPalette detector, normalization fallbacks, and deterministic signature")
    func detectorAndNormalization() {
        final class MockOscSource: OscSubscriptionSource {
            var handlers: [(String) -> Void] = []
            func subscribeOsc(_ handler: @escaping (String) -> Void) -> () -> Void {
                handlers.append(handler)
                return { [weak self] in
                    self?.handlers.removeAll()
                }
            }
            func emit(_ seq: String) {
                for h in handlers { h(seq) }
            }
        }

        let source = MockOscSource()
        let detector = createTerminalPalette(options: TerminalPaletteOptions(
            isTTY: true,
            writeFn: { written in
                if written.contains("\u{1B}]4;0;?") {
                    source.emit("\u{1B}]4;0;rgb:1111/2222/3333\u{07}")
                }
                if written.contains("\u{1B}]10;?") {
                    source.emit("\u{1B}]10;#ffffff\u{07}\u{1B}]11;#000000\u{07}")
                }
                return true
            },
            oscSource: source
        ))

        let detected = detector.detect(options: GetPaletteOptions(timeout: 100, size: 4))
        #expect(detected.palette[0] == "#112233")
        #expect(detected.defaultForeground == "#ffffff")
        #expect(detected.defaultBackground == "#000000")

        let normalized = normalizeTerminalPalette(detected)
        #expect(normalized.palette.count == 256)
        #expect(normalized.palette[0] == RGBA.fromHex("#112233"))
        #expect(normalized.palette[1] == RGBA.fromInts(0x80, 0x00, 0x00))
        #expect(normalized.defaultForeground == RGBA.fromInts(255, 255, 255))
        #expect(normalized.defaultBackground == RGBA.fromInts(0, 0, 0))

        let sig1 = buildTerminalPaletteSignature(detected)
        let sig2 = buildTerminalPaletteSignature(detected)
        let sigDefault = buildTerminalPaletteSignature(nil)
        #expect(sig1 == sig2)
        #expect(sig1 != sigDefault)
        detector.cleanup()
    }
}

// MARK: - EnvRegistry Tests

@Suite("EnvRegistryTests")
struct EnvRegistryTests {
    @Test("Boolean parsing handles true/1/on/yes case-insensitively")
    func booleanParsing() {
        #expect(parseEnvBoolean("true"))
        #expect(parseEnvBoolean("TRUE"))
        #expect(parseEnvBoolean("1"))
        #expect(parseEnvBoolean("on"))
        #expect(parseEnvBoolean("YES"))
        #expect(!parseEnvBoolean("false"))
        #expect(!parseEnvBoolean("0"))
        #expect(!parseEnvBoolean("off"))
        #expect(!parseEnvBoolean("no"))
        #expect(!parseEnvBoolean(""))
    }

    @Test("Injectable EnvRegistry registration, typed parsing, caching, and errors")
    func registryParsingAndCaching() throws {
        let registry = EnvRegistry(environment: [
            "OTUI_DEBUG": "yes",
            "OTUI_PORT": "8080",
            "OTUI_HOST": "localhost",
            "OTUI_BAD_NUM": "not-a-number",
        ])

        try registerEnvVar(
            EnvVarConfig(name: "OTUI_DEBUG", description: "Enable debug", default: false, type: .boolean),
            in: registry
        )
        // Identical re-registration is idempotent
        try registerEnvVar(
            EnvVarConfig(name: "OTUI_DEBUG", description: "Enable debug", default: false, type: .boolean),
            in: registry
        )
        // Conflicting re-registration throws
        #expect(throws: EnvRegistryError.alreadyRegisteredWithDifferentConfig(name: "OTUI_DEBUG")) {
            try registerEnvVar(
                EnvVarConfig(name: "OTUI_DEBUG", description: "Different", default: true, type: .boolean),
                in: registry
            )
        }

        try registry.register(EnvVarConfig(name: "OTUI_PORT", description: "Port", default: 3000, type: .number))
        try registry.register(EnvVarConfig(name: "OTUI_HOST", description: "Host", type: .string))
        try registry.register(EnvVarConfig(name: "OTUI_OPT", description: "Optional", required: false, type: .string))
        try registry.register(EnvVarConfig(name: "OTUI_REQ", description: "Required key", type: .string))
        try registry.register(EnvVarConfig(name: "OTUI_BAD_NUM", description: "Bad num", type: .number))

        #expect(try registry.getBool("OTUI_DEBUG") == true)
        #expect(try registry.getNumber("OTUI_PORT") == 8080)
        #expect(try registry.getString("OTUI_HOST") == "localhost")
        #expect(try registry.getString("OTUI_OPT") == nil)

        #expect(throws: EnvRegistryError.requiredVariableNotSet(name: "OTUI_REQ", description: "Required key")) {
            _ = try registry.get("OTUI_REQ")
        }
        #expect(throws: EnvRegistryError.invalidNumber(name: "OTUI_BAD_NUM", rawValue: "not-a-number")) {
            _ = try registry.get("OTUI_BAD_NUM")
        }
        #expect(throws: EnvRegistryError.notRegistered(name: "UNKNOWN_VAR")) {
            _ = try registry.get("UNKNOWN_VAR")
        }

        // Cache behavior: changing env with setRawValue invalidates key, clearEnvCache clears all
        registry.setRawValue("false", forKey: "OTUI_DEBUG")
        #expect(try registry.getBool("OTUI_DEBUG") == false)
        clearEnvCache(in: registry)
        #expect(try registry.getNumber("OTUI_PORT") == 8080)
    }

    @Test("Generates Markdown and ANSI-colored environment docs")
    func envDocsGeneration() throws {
        let empty = EnvRegistry()
        #expect(generateEnvDocs(from: empty) == "# Environment Variables\n\nNo environment variables registered.\n")
        #expect(generateEnvDocs(from: empty, colored: true).contains("No environment variables registered."))

        let registry = EnvRegistry()
        try registry.register(EnvVarConfig(name: "DEBUG", description: "Debug mode", default: false, type: .boolean))
        try registry.register(EnvVarConfig(name: "OPTIONAL", description: "Optional flag", required: false, type: .string))
        try registry.register(EnvVarConfig(name: "API_KEY", description: "Secret key", type: .string))

        let md = generateEnvMarkdown(from: registry)
        #expect(md.contains("## DEBUG"))
        #expect(md.contains("**Type:** `boolean`"))
        #expect(md.contains("**Default:** `false`"))
        #expect(md.contains("**Default:** *unset*"))
        #expect(md.contains("**Default:** *Required*"))

        let colored = generateEnvColored(from: registry)
        #expect(colored.contains("\u{1B}[1;33mDEBUG\u{1B}[0m"))
        #expect(colored.contains("\u{1B}[35munset\u{1B}[0m"))
        #expect(colored.contains("\u{1B}[31mRequired\u{1B}[0m"))
    }
}

// MARK: - OutputCapture Tests

@Suite("OutputCaptureTests")
struct OutputCaptureTests {
    @Test("Captures stdout/stderr, evicts oldest past maxEntries, emits write events, and claims output")
    func captureBufferAndEvents() {
        let capture = OutputCapture(maxEntries: 3)
        var observed: [(CaptureStream, String)] = []
        let token = capture.onWrite { stream, data in
            observed.append((stream, data))
        }

        capture.write(.stdout, "a")
        capture.write(.stderr, "b")
        capture.write(.stdout, "c")
        capture.write(.stderr, "d")

        #expect(capture.size == 3)
        #expect(capture.entries == [
            CapturedOutput(stream: .stderr, output: "b"),
            CapturedOutput(stream: .stdout, output: "c"),
            CapturedOutput(stream: .stderr, output: "d"),
        ])
        #expect(observed.count == 4)

        let claimed = capture.claimOutput()
        #expect(claimed == "bcd")
        #expect(capture.size == 0)

        capture.off(token)
        let stream = CapturedWritableStream(stream: .stdout, capture: capture, columns: 120, rows: 40, colorDepth: 24)
        stream.write("hello")
        #expect(stream.getColorDepth() == 24)
        #expect(capture.size == 1)
        #expect(observed.count == 4)

        capture.clear()
        #expect(capture.size == 0)
    }
}

// MARK: - HighlightChunks Tests

@Suite("HighlightChunksTests")
struct HighlightChunksTests {
    @Test("Converts overlapping tree-sitter highlights with specificity cascade, UTF-16 slicing, and concealment")
    func treeSitterHighlightsAndConceal() {
        let style = SyntaxStyle.fromStyles([
            "default": StyleDefinitionInput(fg: "#cccccc"),
            "keyword": StyleDefinitionInput(fg: "#ff0000", bold: true),
            "keyword.control": StyleDefinitionInput(italic: true),
            "string": StyleDefinitionInput(fg: "#00ff00"),
            "markup.raw.block": StyleDefinitionInput(bg: "#111111"),
        ])

        // Nested specificity: keyword (1) then keyword.control (2) merges bold + italic + fg=#ff0000
        let content = "if \"hi\" 😀"
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(start: 0, end: 2, group: "keyword"),
            SimpleHighlight(start: 0, end: 2, group: "keyword.control"),
            SimpleHighlight(start: 3, end: 7, group: "string"),
        ]

        let chunks = treeSitterToTextChunks(content: content, highlights: highlights, syntaxStyle: style)
        #expect(chunks.map(\.text) == ["if", " ", "\"hi\"", " 😀"])
        #expect(chunks[0].fg == RGBA.fromHex("#ff0000"))
        #expect(chunks[0].attributes == (TextAttributes.bold | TextAttributes.italic))
        #expect(chunks[1].fg == RGBA.fromHex("#cccccc"))
        #expect(chunks[2].fg == RGBA.fromHex("#00ff00"))

        // Concealment: heading "# Title" conceals "#" and skips trailing space; inline conceal replaces with custom glyph
        let md = "# Title\n**bold**"
        let mdHighlights: [SimpleHighlight] = [
            SimpleHighlight(start: 0, end: 1, group: "conceal", meta: HighlightMeta(conceal: "")),
            SimpleHighlight(start: 8, end: 10, group: "conceal", meta: HighlightMeta(conceal: "•")),
            SimpleHighlight(start: 14, end: 16, group: "conceal", meta: HighlightMeta(conceal: "")),
        ]
        let concealed = treeSitterToTextChunks(
            content: md,
            highlights: mdHighlights,
            syntaxStyle: style,
            conceal: ConcealOptions(enabled: true)
        )
        #expect(concealed.map(\.text).joined() == "Title\n•bold")

        let unconcealed = treeSitterToTextChunks(
            content: md,
            highlights: mdHighlights,
            syntaxStyle: style,
            conceal: ConcealOptions(enabled: false)
        )
        #expect(unconcealed.map(\.text).joined() == md)

        // Injection container suppresses markup.raw.block inside it
        let code = "let x = 1"
        let injected: [SimpleHighlight] = [
            SimpleHighlight(start: 0, end: 9, group: "markup.raw.block", meta: HighlightMeta(containsInjection: true)),
            SimpleHighlight(start: 0, end: 3, group: "keyword", meta: HighlightMeta(isInjection: true)),
        ]
        let injectedChunks = treeSitterToTextChunks(content: code, highlights: injected, syntaxStyle: style)
        #expect(injectedChunks[0].text == "let")
        #expect(injectedChunks[0].bg == nil)
        #expect(injectedChunks[0].fg == RGBA.fromHex("#ff0000"))
    }

    @Test("Converts HAST element, text, and root trees to styled TextChunks")
    func hastConversion() {
        let style = SyntaxStyle.fromStyles([
            "default": StyleDefinitionInput(fg: "#ffffff"),
            "hljs-keyword": StyleDefinitionInput(fg: "#cc99cd", bold: true),
            "hljs-emphasis": StyleDefinitionInput(italic: true),
        ])

        let tree = HASTNode.root([
            .element(tagName: "span", className: "hljs-keyword", children: [
                .text("func"),
                .element(tagName: "em", className: "hljs-emphasis", children: [
                    .text(" main")
                ]),
            ]),
            .text("()"),
        ])

        let chunks = hastToTextChunks(node: tree, syntaxStyle: style)
        #expect(chunks.count == 3)
        #expect(chunks[0].text == "func")
        #expect(chunks[0].fg == RGBA.fromHex("#cc99cd"))
        #expect(chunks[0].attributes == TextAttributes.bold)

        #expect(chunks[1].text == " main")
        #expect(chunks[1].fg == RGBA.fromHex("#cc99cd"))
        #expect(chunks[1].attributes == (TextAttributes.bold | TextAttributes.italic))

        #expect(chunks[2].text == "()")
        #expect(chunks[2].fg == RGBA.fromHex("#ffffff"))

        let styled = hastToStyledText(tree, syntaxStyle: style)
        #expect(styled.plainText == "func main()")
    }
}

// MARK: - PostEffects Tests

@Suite("PostEffectsTests")
struct PostEffectsTests {
    private func makeSolidBuffer(width: Int, height: Int, fg: RGBA, bg: RGBA) -> OptimizedBuffer {
        let buffer = OptimizedBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                buffer.setCellRaw(
                    x: x,
                    y: y,
                    cell: TerminalCell(scalar: UInt32(UInt8(ascii: "X")), foreground: fg, background: bg)
                )
            }
        }
        return buffer
    }

    @Test("Color matrices: grayscale, sepia, invert, brightness, contrast, saturation, hue rotation, colorblind")
    func colorMatricesAndTransform() {
        // Grayscale on pure red (255, 0, 0) -> (76, 76, 76) since round(0.299 * 255) = 76
        let buf = makeSolidBuffer(width: 2, height: 2, fg: RGBA.fromInts(255, 0, 0), bg: RGBA.fromInts(0, 255, 0))
        applyColorMatrix(buffer: buf, matrix: ColorMatrices.grayscale, strength: 1.0, target: .fg)
        #expect(buf.cell(atX: 0, y: 0)?.foreground == RGBA.fromInts(76, 76, 76))
        // BG untouched because target == .fg
        #expect(buf.cell(atX: 0, y: 0)?.background == RGBA.fromInts(0, 255, 0))

        // Invert twice returns original
        let invBuf = makeSolidBuffer(width: 2, height: 2, fg: RGBA.fromInts(40, 100, 200), bg: RGBA.fromInts(10, 20, 30))
        applyInvert(buffer: invBuf)
        #expect(invBuf.cell(atX: 0, y: 0)?.foreground == RGBA.fromInts(215, 155, 55))
        #expect(invBuf.cell(atX: 0, y: 0)?.background == RGBA.fromInts(245, 235, 225))
        applyInvert(buffer: invBuf)
        #expect(invBuf.cell(atX: 0, y: 0)?.foreground == RGBA.fromInts(40, 100, 200))

        // Hue rotation by 0 and 360 is identity
        let h0 = ColorMatrices.hueRotation(degrees: 0)
        let h360 = ColorMatrices.hueRotation(degrees: 360)
        for i in 0..<16 {
            #expect(abs(h0[i] - ColorMatrices.identity[i]) < 1e-4)
            #expect(abs(h360[i] - ColorMatrices.identity[i]) < 1e-4)
        }

        // Sepia, brightness, contrast, saturation, protanopia/deuteranopia/tritanopia dimensions & application
        #expect(ColorMatrices.sepia.count == 16)
        #expect(ColorMatrices.protanopiaSim.count == 16)
        #expect(ColorMatrices.deuteranopiaSim.count == 16)
        #expect(ColorMatrices.tritanopiaSim.count == 16)

        let brightBuf = makeSolidBuffer(width: 1, height: 1, fg: RGBA.fromInts(100, 100, 100), bg: RGBA.fromInts(50, 50, 50))
        applyBrightness(buffer: brightBuf, brightness: 0.2)
        #expect((brightBuf.cell(atX: 0, y: 0)?.foreground.toInts().0 ?? 0) > 140)

        let contrastBuf = makeSolidBuffer(width: 1, height: 1, fg: RGBA.fromInts(200, 50, 128), bg: RGBA.fromInts(0, 0, 0))
        applyColorMatrix(buffer: contrastBuf, matrix: ColorMatrices.contrast(1.5), target: .fg)
        let cInts = contrastBuf.cell(atX: 0, y: 0)!.foreground.toInts()
        #expect(cInts.0 > 200)
        #expect(cInts.1 < 50)
    }

    @Test("Scanlines, vignette, noise, blur, bloom, chromatic aberration, ASCII art, and animated effects")
    func filtersAndEffectsPipeline() {
        // Scanlines darken every step-th row background only
        let scanBuf = makeSolidBuffer(width: 4, height: 4, fg: RGBA.fromInts(200, 200, 200), bg: RGBA.fromInts(100, 100, 100))
        applyScanlines(buffer: scanBuf, strength: 0.5, step: 2)
        #expect(scanBuf.cell(atX: 0, y: 0)?.background == RGBA.fromInts(50, 50, 50))
        #expect(scanBuf.cell(atX: 0, y: 1)?.background == RGBA.fromInts(100, 100, 100))
        #expect(scanBuf.cell(atX: 0, y: 0)?.foreground == RGBA.fromInts(200, 200, 200))

        // Vignette darkens corners more than center
        let vigBuf = makeSolidBuffer(width: 9, height: 9, fg: RGBA.fromInts(200, 200, 200), bg: RGBA.fromInts(200, 200, 200))
        applyVignette(buffer: vigBuf, strength: 0.8)
        let corner = vigBuf.cell(atX: 0, y: 0)!.background.toInts().0
        let center = vigBuf.cell(atX: 4, y: 4)!.background.toInts().0
        #expect(corner < center)

        // Blur spreads color from a single bright cell to neighbors
        let blurBuf = makeSolidBuffer(width: 5, height: 5, fg: RGBA.fromInts(0, 0, 0), bg: RGBA.fromInts(0, 0, 0))
        blurBuf.setCellRaw(x: 2, y: 2, cell: TerminalCell(scalar: 0x20, foreground: RGBA.fromInts(0, 0, 0), background: RGBA.fromInts(255, 255, 255)))
        applyBlur(buffer: blurBuf, radius: 1, target: .bg)
        #expect(blurBuf.cell(atX: 2, y: 1)!.background.toInts().0 > 0)
        #expect(blurBuf.cell(atX: 2, y: 2)!.background.toInts().0 < 255)

        // Bloom illuminates neighbors around bright pixels above threshold
        let bloomBuf = makeSolidBuffer(width: 5, height: 5, fg: RGBA.fromInts(0, 0, 0), bg: RGBA.fromInts(0, 0, 0))
        bloomBuf.setCellRaw(x: 2, y: 2, cell: TerminalCell(scalar: 0x20, foreground: RGBA.fromInts(255, 255, 255), background: RGBA.fromInts(0, 0, 0)))
        applyBloom(buffer: bloomBuf, threshold: 0.8, strength: 0.5, radius: 2)
        #expect(bloomBuf.cell(atX: 2, y: 1)!.foreground.toInts().0 > 0)

        // Chromatic aberration shifts red and blue channels horizontally at edges
        let chromaBuf = makeSolidBuffer(width: 7, height: 3, fg: RGBA.fromInts(0, 0, 0), bg: RGBA.fromInts(0, 0, 0))
        chromaBuf.setCellRaw(x: 3, y: 1, cell: TerminalCell(scalar: 0x20, foreground: RGBA.fromInts(255, 255, 255), background: RGBA.fromInts(0, 0, 0)))
        applyChromaticAberration(buffer: chromaBuf, strength: 2.0)
        #expect(chromaBuf.cell(atX: 3, y: 1)!.foreground.toInts().1 == 255)

        // ASCII art maps dark vs bright background to lowest vs highest ramp glyphs
        let asciiBuf = makeSolidBuffer(width: 2, height: 1, fg: RGBA.fromInts(0, 0, 0), bg: RGBA.fromInts(0, 0, 0))
        asciiBuf.setCellRaw(x: 1, y: 0, cell: TerminalCell(scalar: 0x20, foreground: RGBA.fromInts(0, 0, 0), background: RGBA.fromInts(255, 255, 255)))
        applyAsciiArt(buffer: asciiBuf, ramp: " .#@")
        #expect(asciiBuf.cell(atX: 0, y: 0)?.scalar == UInt32(UInt8(ascii: " ")))
        #expect(asciiBuf.cell(atX: 1, y: 0)?.scalar == UInt32(UInt8(ascii: "@")))

        // Noise & PostProcessEffect protocol polymorphism
        let noiseBuf = makeSolidBuffer(width: 4, height: 4, fg: RGBA.fromInts(128, 128, 128), bg: RGBA.fromInts(128, 128, 128))
        var effects: [any PostProcessEffect] = [
            NoiseEffect(strength: 0.3, seed: 42),
            ColorMatrixEffect(matrix: ColorMatrices.sepia, strength: 0.5, target: .fg),
            CloudsEffect(scale: 0.1, speed: 1.0, density: 0.9, darkness: 0.5, seed: 7),
            FlamesEffect(scale: 0.1, speed: 1.0, intensity: 0.8, seed: 9),
            CRTRollingBarEffect(speed: 1.0, height: 0.25, intensity: 0.4, fadeDistance: 0.3),
            RainbowTextEffect(speed: 1.0, saturation: 1.0, value: 1.0, repeats: 2.0),
            DistortionEffect(glitchChancePerSecond: 100.0, seed: 123),
        ]
        for i in effects.indices {
            effects[i].apply(to: noiseBuf, deltaTime: 0.1)
        }
        #expect(noiseBuf.width == 4 && noiseBuf.height == 4)

        // RainbowTextEffect specifically recolors white foreground cells
        let rainbowBuf = makeSolidBuffer(width: 6, height: 2, fg: RGBA.fromInts(255, 255, 255), bg: RGBA.fromInts(0, 0, 0))
        let rainbow = RainbowTextEffect(speed: 0.5, saturation: 1.0, value: 1.0, repeats: 1.0)
        rainbow.apply(rainbowBuf, deltaTime: 0.2)
        let firstFg = rainbowBuf.cell(atX: 0, y: 0)!.foreground
        let lastFg = rainbowBuf.cell(atX: 5, y: 0)!.foreground
        #expect(firstFg != RGBA.fromInts(255, 255, 255) || lastFg != RGBA.fromInts(255, 255, 255))
        #expect(firstFg != lastFg)
    }
}
