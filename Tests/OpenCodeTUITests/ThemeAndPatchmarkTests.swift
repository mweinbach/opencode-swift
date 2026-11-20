import Testing
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore

// MARK: - Theme Tests (`packages/theme`)

@Suite("TUI Theme Tokens, Defaults, Resolution & V1 Migration")
struct ThemeSuite {
    // The previous default theme is now "opencode-classic" (upstream test/theme/v2/* switched to getOpenCodeClassicTheme).
    @Test("Built-in opencode-classic theme resolves all semantic roles in light and dark modes")
    func builtInOpencodeLightAndDark() throws {
        let doc = ThemeDefaults.opencodeClassic
        #expect(themeModes(doc) == [.light, .dark])
        #expect(supportsThemeMode(doc, mode: .light))
        #expect(supportsThemeMode(doc, mode: .dark))

        let light = try resolveThemeDocument(doc, mode: .light)
        let dark = try resolveThemeDocument(doc, mode: .dark)

        // Core text & background tokens
        #expect(light.text.base == RGBA.fromHex("#1a1a1a"))
        #expect(light.text.muted == RGBA.fromHex("#8a8a8a"))
        #expect(light.text.faint == RGBA.fromHex("#8a8a8a")) // auto-expanded to $text.muted
        #expect(light.background.base == RGBA.fromHex("#ffffff"))
        #expect(light.background.raised.base == RGBA.fromHex("#fafafa"))
        #expect(light.background.raised.high == RGBA.fromHex("#f5f5f5"))
        #expect(light.background.raised.max == RGBA.fromHex("#bebebe"))

        #expect(dark.text.base == RGBA.fromHex("#eeeeee"))
        #expect(dark.text.muted == RGBA.fromHex("#808080"))
        #expect(dark.text.faint == RGBA.fromHex("#808080"))
        #expect(dark.background.base == RGBA.fromHex("#0a0a0a"))
        #expect(dark.background.raised.base == RGBA.fromHex("#141414"))
        #expect(dark.background.raised.high == RGBA.fromHex("#1e1e1e"))
        #expect(dark.background.raised.max == RGBA.fromHex("#4c4c4c"))

        // Action & formfield tokens + state priority
        #expect(dark.text.action.primary.base == RGBA.fromHex("#eeeeee"))
        #expect(dark.text.action.primary.disabled == RGBA.fromHex("#808080"))
        #expect(dark.text.action.primary.focused == RGBA.fromHex("#0a0a0a"))
        #expect(dark.text.action.primary.selected == RGBA.fromHex("#fab283"))
        #expect(dark.text.action.primary.hovered == RGBA.fromHex("#eeeeee")) // inherited from base
        #expect(dark.background.action.primary.base == RGBA.fromInts(0, 0, 0, 0))
        #expect(dark.background.action.primary.focused == RGBA.fromHex("#fab283"))
        #expect(dark.background.action.destructive.base == RGBA.fromHex("#e06c75"))

        #expect(dark.text.formfield.base == RGBA.fromHex("#eeeeee"))
        #expect(dark.text.formfield.focused == RGBA.fromHex("#fab283"))
        #expect(dark.text.formfield.disabled == RGBA.fromHex("#808080"))
        #expect(dark.background.formfield.base == dark.background.base)
        #expect(dark.background.formfield.hovered == dark.background.base)

        // Feedback tokens (with muted expanded from base)
        #expect(dark.text.feedback.error.base == RGBA.fromHex("#e06c75"))
        #expect(dark.text.feedback.error.muted == RGBA.fromHex("#e06c75"))
        #expect(dark.text.feedback.warning.base == RGBA.fromHex("#f5a742"))
        #expect(dark.text.feedback.success.base == RGBA.fromHex("#7fd88f"))
        #expect(dark.text.feedback.info.base == RGBA.fromHex("#56b6c2"))
        #expect(light.text.feedback.warning.base == RGBA.fromHex("#d68c27"))
        for kind in FeedbackKind.allCases {
            #expect(dark.background.feedback[kind].base == dark.background.base)
        }

        // Border, scrollbar, diff, syntax, markdown
        #expect(light.border.base == RGBA.fromHex("#b8b8b8"))
        #expect(light.scrollbar.base == RGBA.fromHex("#a0a0a0"))
        #expect(dark.border.base == RGBA.fromHex("#484848"))
        #expect(dark.scrollbar.base == RGBA.fromHex("#606060"))
        #expect(dark.diff.text.added == RGBA.fromHex("#4fd6be"))
        #expect(dark.diff.background.context == RGBA.fromHex("#141414"))
        #expect(dark.diff.highlight.added == RGBA.fromHex("#b8db87"))
        #expect(dark.diff.lineNumber.text == RGBA.fromHex("#8f8f8f"))
        #expect(dark.syntax.keyword == RGBA.fromHex("#9d7cd8"))
        #expect(dark.syntax.function == RGBA.fromHex("#fab283"))
        #expect(dark.markdown.heading == RGBA.fromHex("#9d7cd8"))
        #expect(dark.markdown.code == RGBA.fromHex("#7fd88f"))
        #expect(dark.categorical.count == 5)
        #expect(light.categorical.count == 5)
    }

    @Test("StatefulColor.state(_:) enforces strict priority order: disabled > pressed > focused > selected > hovered > base")
    func statefulColorPriority() {
        let color = StatefulColor(
            base: RGBA.fromHex("#111111"),
            disabled: RGBA.fromHex("#222222"),
            pressed: RGBA.fromHex("#333333"),
            focused: RGBA.fromHex("#444444"),
            selected: RGBA.fromHex("#555555"),
            hovered: RGBA.fromHex("#666666")
        )
        #expect(color.state(ActionStates()) == color.base)
        #expect(color.state(ActionStates(hovered: true)) == color.hovered)
        #expect(color.state(ActionStates(selected: true, hovered: true)) == color.selected)
        #expect(color.state(ActionStates(focused: true, selected: true, hovered: true)) == color.focused)
        #expect(color.state(ActionStates(pressed: true, focused: true, selected: true, hovered: true)) == color.pressed)
        #expect(color.state(ActionStates(disabled: true, pressed: true, focused: true, selected: true, hovered: true)) == color.disabled)
    }

    @Test("opencode2 surface views (@dialog and @dialog.@footer) are contextualized and absolute")
    func opencode2SurfacesAndAbsoluteViews() throws {
        let dark = try resolveThemeDocument(ThemeDefaults.opencode2, mode: .dark)
        let light = try resolveThemeDocument(ThemeDefaults.opencode2, mode: .light)

        // Base vs dialog vs dialog.footer in dark mode
        #expect(dark.background.base == RGBA.fromHex("#080808"))
        let darkDialog = dark.surface(.dialog)
        #expect(darkDialog.background.base == RGBA.fromHex("#141414")) // $background.raised.base
        #expect(darkDialog.background.action.primary.hovered == RGBA.fromHex("#303030")) // $background.raised.max
        #expect(darkDialog.background.action.primary.base == RGBA.fromInts(0, 0, 0, 0)) // inherited from base
        #expect(darkDialog.text.muted == RGBA.fromHex("#808080"))

        let darkFooter = dark.surface(.dialogFooter)
        #expect(darkFooter.background.base == darkDialog.background.base) // inherits from dialog
        #expect(darkFooter.text.muted == RGBA.fromHex("#b0b0b0")) // overridden to $hue.neutral.200
        #expect(darkDialog.surface(.dialogFooter) == darkFooter) // absolute surface lookup
        #expect(darkFooter.surface(.dialog) == darkDialog)

        // Light dialog overrides from opencode2.light.@dialog
        let lightDialog = light.surface(.dialog)
        #expect(lightDialog.background.base == RGBA.fromHex("#fafafa")) // $hue.neutral.800
        #expect(lightDialog.background.raised.high == RGBA.fromHex("#f2f2f2")) // $hue.neutral.700
        // Upstream lightened the new theme's light grays (500 #cfcfcf -> #e6e6e6, 600 #dddddd -> #eeeeee).
        #expect(lightDialog.background.action.primary.hovered == RGBA.fromHex("#eeeeee")) // $hue.neutral.600
    }

    @Test("Hue step helpers (source, increase, decrease) navigate and clamp hue scales")
    func hueStepHelpers() throws {
        let dark = try resolveThemeDocument(ThemeDefaults.opencodeClassic, mode: .dark)
        let textColor = dark.text.base // #eeeeee -> neutral.200
        let src = try #require(dark.source(textColor))
        #expect(src.hue == "neutral")
        #expect(src.step == .s200)

        #expect(dark.increase(textColor) == dark.hue.neutral[.s300])
        #expect(dark.increase(textColor, 2) == dark.hue.neutral[.s400])
        #expect(dark.decrease(textColor) == dark.hue.neutral[.s100])
        #expect(dark.decrease(textColor, 10) == dark.hue.neutral[.s100]) // clamped at 100
        #expect(dark.increase(textColor, 100) == dark.hue.neutral[.s900]) // clamped at 900
        #expect(dark.increase(textColor, Double.nan) == textColor) // non-finite -> 0

        let unlisted = RGBA.fromHex("#123456")
        #expect(dark.source(unlisted) == nil)
        #expect(dark.increase(unlisted) == unlisted)
        #expect(dark.decrease(unlisted) == unlisted)
    }

    @Test("ThemeDocument JSON round-trip and parseThemeDocument")
    func themeDocumentJsonRoundTrip() throws {
        let json = try ThemePatchmarkTestHelper.encodeThemeDocumentJSON(ThemeDefaults.opencode2)
        let parsed = try parseThemeDocument(json: json, name: "opencode2")
        #expect(parsed == ThemeDefaults.opencode2)

        let jsonVal = try ThemePatchmarkTestHelper.decodeJSONValue(json)
        let parsedFromVal = try parseThemeDocument(jsonVal, name: "opencode2-val")
        #expect(parsedFromVal == ThemeDefaults.opencode2)
    }

    @Test("Single-mode custom theme falls back to available mode")
    func singleModeFallback() throws {
        let darkOnly = ThemeDocument(base: ThemeDefaults.opencodeClassic.base, light: nil, dark: ThemeDefaults.opencodeClassic.dark)
        #expect(themeModes(darkOnly) == [.dark])
        #expect(!supportsThemeMode(darkOnly, mode: .light))
        let selected = try selectThemeMode(darkOnly, mode: .light)
        #expect(selected.mode == .dark)
        let resolvedFallback = try resolveThemeDocument(darkOnly, mode: .light)
        #expect(resolvedFallback.background.base == RGBA.fromHex("#0a0a0a"))
    }

    @Test("ThemeDefaults.resolveOrDefault falls back to built-in default")
    func resolveOrDefaultFallback() throws {
        let emptyModes = ThemeDocument(base: ThemeDefaults.opencode.base, light: nil, dark: nil)
        let fallbackDark = ThemeDefaults.resolveOrDefault(emptyModes, mode: .dark)
        let expectedDark = try ThemeDefaults.resolveDefault(mode: .dark)
        #expect(fallbackDark == expectedDark)
        let fallbackLight = ThemeDefaults.resolveOrDefault(nil, mode: .light)
        let expectedLight = try ThemeDefaults.resolveDefault(mode: .light)
        #expect(fallbackLight == expectedLight)
    }

    @Test("mergeTheme recursively deep-merges nested JSON objects")
    func mergeThemeDeepMerge() {
        let merged = mergeTheme(
            .object(["a": .object(["x": .string("#111"), "y": .string("#222")]), "b": .string("old")]),
            .object(["a": .object(["y": .string("#333"), "z": .string("#444")]), "b": .string("new")])
        )
        #expect(merged["b"] == .string("new"))
        if case .object(let aObj) = merged["a"] {
            #expect(aObj["x"] == .string("#111"))
            #expect(aObj["y"] == .string("#333"))
            #expect(aObj["z"] == .string("#444"))
        } else {
            Issue.record("Expected merged nested object for key 'a'")
        }
    }

    @Test("Cycle detection, missing refs, and themeDecodeError formatting")
    func themeCycleAndDecodeErrors() throws {
        var cyclicDef = try selectTheme(ThemeDefaults.opencode, mode: .dark)
        cyclicDef.text.base = "$text.muted"
        cyclicDef.text.muted = "$text.base"
        #expect(throws: ThemeError.self) {
            _ = try resolveTheme(cyclicDef)
        }

        var cyclicHueDef = try selectTheme(ThemeDefaults.opencode, mode: .dark)
        cyclicHueDef.hue["accent"] = .alias("$hue.interactive")
        cyclicHueDef.hue["interactive"] = .alias("$hue.accent")
        #expect(throws: ThemeError.self) {
            _ = try resolveTheme(cyclicHueDef)
        }

        let err = themeDecodeError(ThemeError("bad hex, got \"not-a-hex\""), name: "custom")
        #expect(err.message == "Invalid theme: custom \"not-a-hex\" is an invalid value")
        #expect(throws: ThemeError.self) {
            _ = try parseThemeDocument(json: "{\"base\":{}}", name: "broken")
        }
    }

    @Test("OKLCH color math matches upstream reference outputs")
    func oklchMathParity() {
        let red = rgbToOklch(1, 0, 0)
        #expect(abs(red.l - 0.6279553606145516) < 1e-9)
        #expect(abs(red.c - 0.2576833077361567) < 1e-9)
        #expect(abs(red.h - 29.233885192342633) < 1e-9)

        let blue = rgbToOklch(0.2, 0.5, 0.8)
        #expect(abs(blue.l - 0.5883450172994283) < 1e-9)
        #expect(abs(blue.c - 0.1391473333540185) < 1e-9)
        #expect(abs(blue.h - 251.44320831455514) < 1e-9)

        #expect(oklchToHex(OklchColor(l: 0.65, c: 0.15, h: 240)) == "#2998d8")
        #expect(oklchToHex(OklchColor(l: 0.9, c: 0.4, h: 140)) == "#89ff6e")
        #expect(byte(0) == "00")
        #expect(byte(15) == "0f")
        #expect(byte(255) == "ff")
        #expect(hex(RGBA.fromInts(10, 20, 30, 255)) == "#0a141e")
        #expect(hex(RGBA.fromInts(10, 20, 30, 128)) == "#0a141e80")
    }

    @Test("V1 theme resolution, migrateV1, and migrateV1NewDesigns produce valid light & dark themes")
    func v1MigrationAndNewDesigns() throws {
        // Round-trip ThemeV1Json through Codable
        let v1JsonStr = try ThemePatchmarkTestHelper.encodeThemeV1JSON(ThemeDefaults.opencodeV1)
        let decodedV1 = try ThemePatchmarkTestHelper.decodeThemeV1JSON(v1JsonStr)
        #expect(decodedV1 == ThemeDefaults.opencodeV1)

        // Resolve V1 directly
        let v1Dark = try resolveV1(ThemeDefaults.opencodeV1, mode: .dark)
        let v1Light = try resolveV1(ThemeDefaults.opencodeV1, mode: .light)
        #expect(detectMode(v1Dark) == .dark)
        #expect(detectMode(v1Light) == .light)
        #expect(v1Dark.thinkingOpacity == 0.6)
        #expect(!v1Dark._hasSelectedListItemText)
        #expect(v1Dark.backgroundMenu == v1Dark.backgroundElement)
        #expect(selectedForeground(v1Dark, background: v1Dark.primary) == v1Dark.background)
        #expect(dialogBackground(v1Dark) == "$background.raised.base")

        let inferred = inferHues(v1Dark)
        #expect(inferred.byToken[.accent] == .purple)
        #expect(inferred.byToken[.primary] == .orange)
        #expect(inferred.byToken[.error] == .red)
        #expect(inferred.byToken[.success] == .green)

        // Classic migrateV1 (matching upstream theme.test.ts)
        let migrated = try migrateV1(ThemeDefaults.opencodeV1)
        #expect(themeModes(migrated) == [.light, .dark])
        for mode in [Mode.light, Mode.dark] {
            let resolved = try resolveThemeDocument(migrated, mode: mode)
            #expect(resolved.hue.accent[.s800].a == 1.0)
            #expect(resolved.hue.interactive[.s800].a == 1.0)
            #expect(!resolved.categorical.isEmpty)
        }

        // New-designs migration (opencode2 layout)
        let migratedV2 = try migrateV1NewDesigns(ThemeDefaults.opencodeV1)
        #expect(themeModes(migratedV2) == [.light, .dark])
        let v2Dark = try resolveThemeDocument(migratedV2, mode: .dark)
        let v2Light = try resolveThemeDocument(migratedV2, mode: .light)
        #expect(v2Dark.text.base == v1Dark.text)
        #expect(v2Dark.background.base == v1Dark.background)
        #expect(v2Light.text.base == v1Light.text)
        #expect(v2Light.background.base == v1Light.background)
        #expect(v2Light.surface(.dialog).background.base == v2Light.hue.neutral[.s800])

        // Single-mode V1 theme collapses to single mode
        var darkOnlyV1 = ThemeDefaults.opencodeV1
        darkOnlyV1.theme[.background] = .string("#0a0a0a")
        darkOnlyV1.theme[.text] = .string("#eeeeee")
        let singleMigrated = try migrateV1(darkOnlyV1)
        #expect(themeModes(singleMigrated) == [.dark])
    }

    @Test("generateSyntax maps resolved theme tokens to OpenTUICore SyntaxStyle scopes")
    func generateSyntaxScopes() throws {
        let dark = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        let style = generateSyntax(dark)

        #expect(style.getStyle("default")?.fg == dark.text.base)
        #expect(style.getStyle("prompt")?.fg == dark.hue.accent[.s200])
        #expect(style.getStyle("comment")?.fg == dark.syntax.comment)
        #expect(style.getStyle("comment")?.italic == true)
        #expect(style.getStyle("keyword.type")?.fg == dark.syntax.type)
        #expect(style.getStyle("keyword.type")?.bold == true)
        #expect(style.getStyle("keyword.type")?.italic == true)
        #expect(style.getStyle("markup.heading.1")?.underline == true)
        #expect(style.getStyle("markup.heading.1")?.bold == true)
        #expect(style.getStyle("markup.raw.inline")?.bg == dark.background.base)
        #expect(style.getStyle("diff.plus")?.fg == dark.diff.text.added)
        #expect(style.getStyle("diff.plus")?.bg == dark.diff.background.added)
        #expect(style.getStyle("extmark.paste")?.fg == dark.background.base)
        #expect(style.getStyle("extmark.paste")?.bg == dark.text.feedback.warning.base)

        // Transparent page background falls back to text.action.primary.focused for extmark.paste
        var transparentDef = try selectTheme(ThemeDefaults.opencode, mode: .dark)
        transparentDef.background.base = "transparent"
        let transparentTheme = try resolveTheme(transparentDef)
        let transparentStyle = generateSyntax(transparentTheme)
        #expect(transparentStyle.getStyle("extmark.paste")?.fg == transparentTheme.text.action.primary.focused)
    }

    @Test("Contextual dialog action override inherits surface base instead of leaking outer state")
    func contextualDialogActionPrecedence() throws {
        var def = try selectTheme(ThemeDefaults.opencode, mode: .dark)
        // Outer theme has primary hovered = #141414 ($hue.neutral.700), base = transparent.
        // Dialog overrides ONLY primary.base = #334455 (leaving $hovered nil).
        def.dialog = DialogTokensDefinition(
            background: BackgroundDefinition(
                base: "$background.raised.base",
                action: ActionColorDefinition(
                    primary: StatefulColorDefinition(base: "#334455")
                )
            )
        )
        let resolved = try resolveTheme(def)
        let dlg = resolved.surface(.dialog)
        #expect(dlg.background.action.primary.base == RGBA.fromHex("#334455"))
        // Must inherit dialog's own base (#334455), not leak outer surface's hovered (#141414)!
        #expect(dlg.background.action.primary.hovered == RGBA.fromHex("#334455"))
    }

    @Test("V1 ANSI color resolution, transparent foreground contrast, and dialogBackground fallback")
    func v1AnsiAndTransparentFallbacks() throws {
        var v1 = ThemeDefaults.opencodeV1
        v1.theme[.background] = .string("transparent")
        v1.theme[.backgroundPanel] = .string("none")
        v1.theme[.backgroundElement] = .string("transparent")
        v1.theme[.primary] = .ansi(196) // red in 6x6x6 cube: 196-16=180 -> r=5(255), g=0, b=0
        v1.theme[.secondary] = .ansi(244) // grayscale: (244-232)*10+8 = 128
        v1.theme[.accent] = .ansi(9) // bright red #ff0000

        let resolved = try resolveV1(v1, mode: .dark)
        #expect(resolved.background == RGBA.fromInts(0, 0, 0, 0))
        #expect(resolved.primary == RGBA.fromInts(255, 0, 0))
        #expect(resolved.secondary == RGBA.fromInts(128, 128, 128))
        #expect(resolved.accent == RGBA.fromHex("#ff0000"))

        // Transparent background -> contrast-based selectedForeground
        #expect(selectedForeground(resolved, background: RGBA.fromHex("#ffffff")) == RGBA.fromInts(0, 0, 0))
        #expect(selectedForeground(resolved, background: RGBA.fromHex("#000000")) == RGBA.fromInts(255, 255, 255))
        // All surfaces transparent + light text (#eeeeee) -> "#000000"
        #expect(dialogBackground(resolved) == "#000000")

        // expandTokens standalone
        let expanded = expandTokens(ThemeTokensDefinition(
            text: TextDefinition(
                base: "#ffffff",
                feedback: TextFeedbackDefinition(error: TextFeedbackItemDefinition(base: "#ff0000"))
            )
        ))
        #expect(expanded.text?.muted == "$text.base")
        #expect(expanded.text?.faint == "$text.muted")
        #expect(expanded.text?.feedback?.error?.muted == "$text.feedback.error.base")
    }
}

// MARK: - Patchmark Tests (`packages/patchmark`)

@Suite("Patchmark Entities, Healing, Inline, Blocks, HTML & Streaming Parser")
struct PatchmarkSuite {
    @Test("HTML5 entities table, numeric decoding, unescapeString, and normalizeURI")
    func entitiesAndUriNormalization() {
        #expect(HTML_ENTITIES.count == 2125)
        #expect(decodeEntity("&amp;") == "&")
        #expect(decodeEntity("&copy;") == "©")
        #expect(decodeEntity("&Tab;") == "\t")
        #expect(decodeEntity("&NewLine;") == "\n")
        #expect(decodeEntity("&acE;") == "\u{223E}\u{0333}")
        #expect(decodeEntity("&#0;") == "\u{FFFD}")
        #expect(decodeEntity("&#128;") == "€")
        #expect(decodeEntity("&#x1F600;") == "😀")
        #expect(decodeEntity("&#xD800;") == "\u{FFFD}")
        #expect(decodeEntity("&unknown;") == "&unknown;")
        #expect(decodeCodePoint(153) == "™")
        #expect(decodeCodePoint(-1) == "\u{FFFD}")
        #expect(decodeCodePoint(0x110000) == "\u{FFFD}")

        #expect(unescapeString("a\\*b &amp; &#x41; \\z") == "a*b & A \\z")
        #expect(normalizeURI("https://example.com/a b?q=1%20&x=é🚀") == "https://example.com/a%20b?q=1%20&x=%C3%A9%F0%9F%9A%80")
        #expect(normalizeURI("https://example.com/path?a=1&b=2#top") == "https://example.com/path?a=1&b=2#top")
    }

    @Test("Streaming tail healing closes open emphasis, code spans, links, and hides dangling markers")
    func streamingTailHealing() {
        #expect(healStreamingInline("Hello **world") == "Hello **world**")
        #expect(healStreamingInline("Hello **") == "Hello **")
        #expect(healStreamingInline("Hello ***bold italic") == "Hello ***bold italic***")
        #expect(healStreamingInline("Code `foo") == "Code `foo`")
        #expect(healStreamingInline("Code ```") == "Code ")
        #expect(healStreamingInline("Strike ~~del") == "Strike ~~del~~")
        #expect(healStreamingInline("See [docs](https://example.com/gu") == "See docs")
        #expect(healStreamingInline("See ![img](https://example.com/a.png") == "See ")
        #expect(healStreamingInline("Math $a * b$ and **open") == "Math $a * b$ and **open**")
        #expect(healStreamingInline("Paren \\(x * y\\) and _ital") == "Paren \\(x * y\\) and _ital_")
        #expect(healStreamingInline("Snake foo_bar and _open") == "Snake foo_bar and _open_")
        #expect(healStreamingInline("Trailing **bold   ") == "Trailing **bold**")

        let h = computeTailHeal("See [docs](https://example.com/gu")
        #expect(h == TailHeal(strip: 29, append: "docs"))
        #expect(applyTailHeal("See [docs](https://example.com/gu", h) == "See docs")
    }

    @Test("Inline parser handles emphasis, code, links, references, GFM autolinks, strikethrough, and math")
    func inlineParserCoverage() {
        #expect(normalizeReference("[  Foo\n\tBar  ]") == "FOO BAR")
        #expect(normalizeReference("[Straße]") == "STRASSE")

        var refmap: RefMap = [:]
        let consumed = parseReference("[spec]: https://spec.commonmark.org/ \"CommonMark\"\n", into: &refmap)
        #expect(consumed > 0)
        #expect(refmap["SPEC"]?.href == "https://spec.commonmark.org/")
        #expect(refmap["SPEC"]?.title == "CommonMark")

        let nodes = parseInlines("Read **bold**, *em*, ~~old~~, `code`, [spec], $E = mc^2$, and $5.", options: InlineParseOptions(gfm: true, math: true, defs: refmap))
        let html = renderInlinesToHtml(nodes, options: HtmlRenderOptions(gfm: true, math: true))
        #expect(html == "Read <strong>bold</strong>, <em>em</em>, <del>old</del>, <code>code</code>, <a href=\"https://spec.commonmark.org/\" title=\"CommonMark\">spec</a>, <span class=\"math-inline\" data-math-delimiter=\"dollar\">E = mc^2</span>, and $5.")
    }

    @Test("Preserves settled blocks across streaming deltas and emits minimal patches")
    func settledBlocksAndMinimalPatches() {
        let stream = createMarkdownStream(StreamOptions(renderHtml: true))
        let f1 = stream.append("# Heading\n\nFirst paragraph.\n\nSecond ")
        #expect(f1.blocks.count == 3)
        #expect(f1.blocks[0].status == .settled)
        #expect(f1.blocks[1].status == .settled)
        #expect(f1.blocks[2].status == .streaming)

        let b0 = f1.blocks[0]
        let b1 = f1.blocks[1]

        let f2 = stream.append("paragraph continues with **bold")
        #expect(f2.blocks[0] == b0)
        #expect(f2.blocks[1] == b1)
        #expect(f2.patches.count == 1)
        #expect(f2.patches[0].op == "replace")

        let f3 = stream.finalize()
        #expect(f3.blocks[0] == b0)
        #expect(f3.blocks[1] == b1)
        #expect(f3.blocks[2].status == .settled)
        #expect(f3.patches.count == 1)
        #expect(f3.patches[0].op == "finalize")
    }

    @Test("Holds pending block markers until first word arrives (zero kind-pop)")
    func pendingMarkersAndZeroKindPop() {
        let s1 = splitPendingMarker("Done.\n\n-")
        #expect(s1.visible == "Done.\n\n" && s1.held == "-")
        let s2 = splitPendingMarker("Done.\n\n##")
        #expect(s2.visible == "Done.\n\n" && s2.held == "##")
        let s3 = splitPendingMarker("Steps:\n\n12.")
        #expect(s3.visible == "Steps:\n\n" && s3.held == "12.")
        let s4 = splitPendingMarker("Done.\n\n---")
        #expect(s4.visible == "Done.\n\n---" && s4.held == "")

        let source = "## What changed\n\nThe transcript grows in place.\n\n- One item.\n- Two items.\n\n1. First\n2. Second\n\n> Quoted\n\nThe end."
        let stream = createMarkdownStream()
        var kindsById: [Int: String] = [:]
        let chars = Array(source)
        for i in 1...chars.count {
            let prefix = String(chars[0..<i])
            let frame = stream.update(prefix, streaming: i < chars.count)
            for b in frame.blocks {
                if let prev = kindsById[b.id] {
                    #expect(b.kind.typeName == prev)
                }
                kindsById[b.id] = b.kind.typeName
            }
        }
    }

    @Test("Heals incomplete emphasis, code spans, and links on streaming tail without <hr> flashes")
    func tailHealStreamingAndNoHrFlash() {
        let stream = createMarkdownStream(StreamOptions(renderHtml: true))
        let f1 = stream.update("Hello **world", streaming: true)
        #expect(renderBlocksToHtml(f1.blocks) == "<p>Hello <strong>world</strong></p>\n")

        let f2 = stream.update("See [docs](https://example.com/gu", streaming: true)
        #expect(renderBlocksToHtml(f2.blocks) == "<p>See docs</p>\n")

        let f3 = stream.update("See [docs](https://example.com/guide)", streaming: true)
        #expect(renderBlocksToHtml(f3.blocks).contains("href=\"https://example.com/guide\""))

        // Partial ** never heals into **** or flashes <hr>
        let md = "Paragraph one.\n\n**Bold heading:** details here.\n"
        let s2 = createMarkdownStream(StreamOptions(holdPendingMarkers: false, renderHtml: true))
        let chars = Array(md)
        for i in 1...chars.count {
            let f = s2.update(String(chars[0..<i]), streaming: i < chars.count)
            for b in f.blocks {
                #expect(b.kind.typeName != "hr")
                #expect(!(b.liveRaw ?? b.raw).contains("****"))
            }
            #expect(!renderBlocksToHtml(f.blocks).contains("<hr"))
        }
    }

    @Test("Streams open code fences and settles when closing fence arrives split across deltas")
    func openCodeFencesAndSplitClosing() {
        let stream = createMarkdownStream()
        stream.append("Intro\n\n```ts\nconst a = 1;\n")
        #expect(stream.getBlocks()[0].status == .settled)

        let f1 = stream.append("const b = 2;\n")
        #expect(f1.patches.count == 1)
        #expect(f1.patches[0].op == "replace")
        #expect(f1.blocks[1].kind == .code(
            language: "ts",
            meta: nil,
            source: "const a = 1;\nconst b = 2;\n",
            htmlLiteral: nil,
            fence: "```",
            indented: false,
            complete: false
        ))

        stream.append("`")
        stream.append("`")
        let closed = stream.append("`\n\nAfter")
        #expect(closed.blocks[1].status == .settled)
        if case .code(_, _, let src, _, _, _, let complete) = closed.blocks[1].kind {
            #expect(complete == true)
            #expect(src == "const a = 1;\nconst b = 2;")
        } else {
            Issue.record("Expected code block at index 1")
        }
    }

    @Test("Keeps nested fenced code inside list items and preserves follow-up prose as paragraph")
    func nestedCodeInsideLists() {
        let stream = createMarkdownStream(StreamOptions(renderHtml: true))
        let frame = stream.update(
            "1. First item\n   ```ts\n   const x = 1\n   ```\n2. Second item\n   ```ts\n   const y = 2",
            streaming: true
        )
        #expect(frame.blocks.count == 1)
        #expect(frame.blocks[0].kind.typeName == "list")
        #expect(frame.blocks[0].status == .streaming)
        let done = stream.finalize()
        #expect(done.blocks[0].html == "<ol>\n<li>First item\n<pre><code class=\"language-ts\">const x = 1\n</code></pre>\n</li>\n<li>Second item\n<pre><code class=\"language-ts\">const y = 2\n</code></pre>\n</li>\n</ol>\n")

        let md2 = "1. Step one:\n\n   ```sh\n   bun test\n   ```\n\n   Follow-up prose in item one.\n"
        let s2 = createMarkdownStream(StreamOptions(renderHtml: true))
        let done2 = s2.update(md2, streaming: false)
        #expect(done2.blocks.count == 1)
        #expect(done2.blocks[0].html == "<ol>\n<li>\n<p>Step one:</p>\n<pre><code class=\"language-sh\">bun test\n</code></pre>\n<p>Follow-up prose in item one.</p>\n</li>\n</ol>\n")
    }

    @Test("Resolves late reference definitions via targeted patches and handles rebuild ref edits")
    func lateReferencesAndRebuildPatches() {
        let stream = createMarkdownStream(StreamOptions(renderHtml: true))
        let f1 = stream.append("Read the [specification][spec].\n\nSecond paragraph.\n\n")
        #expect(f1.blocks[0].status == .settled)
        #expect(f1.blocks[1].status == .settled)

        let f2 = stream.append("[spec]: https://spec.commonmark.org/\n\n")
        let patchedFirst = f2.patches.contains { patch in
            if case .replace(let id, _, _) = patch { return id == f1.blocks[0].id }
            return false
        }
        #expect(patchedFirst)
        #expect(renderBlocksToHtml(f2.blocks).contains("href=\"https://spec.commonmark.org/\""))

        // Ref-only paragraph before thematic break & rebuild patch replay
        let s2 = createMarkdownStream(StreamOptions(renderHtml: true))
        let first = s2.update("[x][r]\n\nOther\n\n[r]: /one\n---\n", streaming: true)
        #expect(renderBlocksToHtml(first.blocks) == "<p><a href=\"/one\">x</a></p>\n<p>Other</p>\n<hr />\n")

        let next = s2.update("[x][r]\n\nOther\n\n[r]: /two\n---\n", streaming: true)
        var replica = first.blocks
        applyPatches(&replica, next.patches)
        #expect(replica == next.blocks)
        #expect(renderBlocksToHtml(replica) == "<p><a href=\"/two\">x</a></p>\n<p>Other</p>\n<hr />\n")
    }

    @Test("Parses inline and display math, currency rules, setext headings, tables, and groupHtmlBlocks")
    func mathTablesSetextAndHtmlGroups() {
        // Math & currency
        let mathStream = createMarkdownStream()
        let mf = mathStream.update(
            "Lunch costs $5 and $10, while $A = \\pi r^2$ and \\(e^{i\\pi} + 1 = 0\\).\n\n$$\n\\int_0^1 x^2\\,dx = \\frac{1}{3}\n$$\n",
            streaming: false
        )
        #expect(mf.blocks.count == 2)
        if case .paragraph(let inlines) = mf.blocks[0].kind {
            let mathNodes = inlines.filter { $0.typeName == "math" }
            #expect(mathNodes == [
                .math(source: "A = \\pi r^2", delimiter: .dollar, display: false),
                .math(source: "e^{i\\pi} + 1 = 0", delimiter: .paren, display: false),
            ])
        } else {
            Issue.record("Expected paragraph at index 0")
        }
        #expect(mf.blocks[1].kind == .math(source: "\\int_0^1 x^2\\,dx = \\frac{1}{3}", delimiter: .doubleDollar, complete: true))

        // Streaming tables row-by-row
        let tableStream = createMarkdownStream()
        let tf1 = tableStream.append("| Col A | Col B |\n")
        #expect(tf1.blocks[0].kind.typeName == "paragraph")
        let tf2 = tableStream.append("|---|---|\n| 1 | 2 |\n")
        if case .table(_, _, let rows) = tf2.blocks[0].kind {
            #expect(rows.count == 1)
        } else {
            Issue.record("Expected table")
        }
        let tf3 = tableStream.append("| 3 | **four** |\n")
        if case .table(_, _, let rows) = tf3.blocks[0].kind {
            #expect(rows.count == 2)
        } else {
            Issue.record("Expected table")
        }

        // Setext headings & lazy blockquote continuations during 1-char streaming
        let setextMd = "Title\n===\n\nSection\n---\n\n> quoted first line\nlazy continuation line\n"
        let setextStream = createMarkdownStream(StreamOptions(renderHtml: true))
        let setextChars = Array(setextMd)
        for i in 1...setextChars.count {
            let f = setextStream.update(String(setextChars[0..<i]), streaming: i < setextChars.count)
            for b in f.blocks { #expect(b.kind.typeName != "list") }
        }
        let setextDone = setextStream.finalize()
        #expect(renderBlocksToHtml(setextDone.blocks) == "<h1>Title</h1>\n<h2>Section</h2>\n<blockquote>\n<p>quoted first line\nlazy continuation line</p>\n</blockquote>\n")

        // groupHtmlBlocks for <details>
        let detailsMd = "<details>\n<summary>Summary</summary>\n\nHidden paragraph.\n\n```ts\nconst x = 1\n```\n</details>\n\nAfter.\n"
        let detailsStream = createMarkdownStream(StreamOptions(groupHtmlBlocks: true, renderHtml: true))
        let detailsDone = detailsStream.update(detailsMd, streaming: false)
        #expect(detailsDone.blocks.count == 2)
        #expect(detailsDone.blocks[0].kind.typeName == "group")
        #expect(detailsDone.blocks[0].raw.contains("<details>"))
        #expect(detailsDone.blocks[0].raw.contains("</details>"))
        #expect(detailsDone.blocks[1].raw == "After.\n")
    }

    @Test("Passes all 24 official GFM spec examples in one-shot and 1-char streaming with patch invariance")
    func gfmSpecComplianceAndStreamingInvariance() {
        let gfmExamples: [(id: Int, md: String, html: String)] = [
            (198, "| foo | bar |\n| --- | --- |\n| baz | bim |\n",
             "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n"),
            (199, "| abc | defghi |\n:-: | -----------:\nbar | baz\n",
             "<table>\n<thead>\n<tr>\n<th align=\"center\">abc</th>\n<th align=\"right\">defghi</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"center\">bar</td>\n<td align=\"right\">baz</td>\n</tr>\n</tbody>\n</table>\n"),
            (200, "| f\\|oo  |\n| ------ |\n| b `\\|` az |\n| b **\\|** im |\n",
             "<table>\n<thead>\n<tr>\n<th>f|oo</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>b <code>|</code> az</td>\n</tr>\n<tr>\n<td>b <strong>|</strong> im</td>\n</tr>\n</tbody>\n</table>\n"),
            (201, "| abc | def |\n| --- | --- |\n| bar | baz |\n> bar\n",
             "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n<blockquote>\n<p>bar</p>\n</blockquote>\n"),
            (202, "| abc | def |\n| --- | --- |\n| bar | baz |\nbar\n\nbar\n",
             "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n</tbody>\n</table>\n<p>bar</p>\n"),
            (203, "| abc | def |\n| --- |\n| bar |\n",
             "<p>| abc | def |\n| --- |\n| bar |</p>\n"),
            (204, "| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |\n",
             "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n"),
            (205, "| abc | def |\n| --- | --- |\n",
             "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n</table>\n"),
            (279, "- [ ] foo\n- [x] bar\n",
             "<ul>\n<li><input disabled=\"\" type=\"checkbox\"> foo</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> bar</li>\n</ul>\n"),
            (280, "- [x] foo\n  - [ ] bar\n  - [x] baz\n- [ ] bim\n",
             "<ul>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> foo\n<ul>\n<li><input disabled=\"\" type=\"checkbox\"> bar</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> baz</li>\n</ul>\n</li>\n<li><input disabled=\"\" type=\"checkbox\"> bim</li>\n</ul>\n"),
            (491, "~~Hi~~ Hello, world!\n",
             "<p><del>Hi</del> Hello, world!</p>\n"),
            (492, "This ~~has a\n\nnew paragraph~~.\n",
             "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n"),
            (621, "www.commonmark.org\n",
             "<p><a href=\"http://www.commonmark.org\">www.commonmark.org</a></p>\n"),
            (622, "Visit www.commonmark.org/help for more information.\n",
             "<p>Visit <a href=\"http://www.commonmark.org/help\">www.commonmark.org/help</a> for more information.</p>\n"),
            (623, "Visit www.commonmark.org.\n\nVisit www.commonmark.org/a.b.\n",
             "<p>Visit <a href=\"http://www.commonmark.org\">www.commonmark.org</a>.</p>\n<p>Visit <a href=\"http://www.commonmark.org/a.b\">www.commonmark.org/a.b</a>.</p>\n"),
            (624, "www.google.com/search?q=Markup+(business)\n\nwww.google.com/search?q=Markup+(business)))\n\n(www.google.com/search?q=Markup+(business))\n\n(www.google.com/search?q=Markup+(business)\n",
             "<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>))</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>)</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n"),
            (625, "www.google.com/search?q=(business))+ok\n",
             "<p><a href=\"http://www.google.com/search?q=(business))+ok\">www.google.com/search?q=(business))+ok</a></p>\n"),
            (626, "www.google.com/search?q=commonmark&hl=en\n\nwww.google.com/search?q=commonmark&hl;\n",
             "<p><a href=\"http://www.google.com/search?q=commonmark&amp;hl=en\">www.google.com/search?q=commonmark&amp;hl=en</a></p>\n<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&amp;hl;</p>\n"),
            (627, "www.commonmark.org/he<lp\n",
             "<p><a href=\"http://www.commonmark.org/he\">www.commonmark.org/he</a>&lt;lp</p>\n"),
            (628, "http://commonmark.org\n\n(Visit https://encrypted.google.com/search?q=Markup+(business))\n\nAnonymous FTP is available at ftp://foo.bar.baz.\n",
             "<p><a href=\"http://commonmark.org\">http://commonmark.org</a></p>\n<p>(Visit <a href=\"https://encrypted.google.com/search?q=Markup+(business)\">https://encrypted.google.com/search?q=Markup+(business)</a>)</p>\n<p>Anonymous FTP is available at <a href=\"ftp://foo.bar.baz\">ftp://foo.bar.baz</a>.</p>\n"),
            (629, "foo@bar.baz\n",
             "<p><a href=\"mailto:foo@bar.baz\">foo@bar.baz</a></p>\n"),
            (630, "hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is.\n",
             "<p>hello@mail+xyz.example isn't valid, but <a href=\"mailto:hello+xyz@mail.example\">hello+xyz@mail.example</a> is.</p>\n"),
            (631, "a.b-c_d@a.b\n\na.b-c_d@a.b.\n\na.b-c_d@a.b-\n\na.b-c_d@a.b_\n",
             "<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a></p>\n<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a>.</p>\n<p>a.b-c_d@a.b-</p>\n<p>a.b-c_d@a.b_</p>\n"),
            (652, "<strong> <title> <style> <em>\n\n<blockquote>\n  <xmp> is disallowed.  <XMP> is also disallowed.\n</blockquote>\n",
             "<p><strong> &lt;title> &lt;style> <em></p>\n<blockquote>\n  &lt;xmp> is disallowed.  &lt;XMP> is also disallowed.\n</blockquote>\n"),
        ]

        for ex in gfmExamples {
            // One-shot
            let oneShot = createMarkdownStream(StreamOptions(gfm: true, math: false, heal: false, holdPendingMarkers: false, renderHtml: true))
            let frame = oneShot.update(ex.md, streaming: false)
            let got = renderBlocksToHtml(frame.blocks, options: HtmlRenderOptions(gfm: true, math: false))
            #expect(got == ex.html, "GFM example \(ex.id) one-shot mismatch")

            // 1-char streaming with patch-replay replica check
            let stream = createMarkdownStream(StreamOptions(gfm: true, math: false, heal: true, holdPendingMarkers: true, renderHtml: true))
            var replica: [MarkdownBlock] = []
            for ch in ex.md {
                let f = stream.append(String(ch))
                applyPatches(&replica, f.patches)
                #expect(replica == f.blocks, "GFM example \(ex.id) patch replica diverged")
            }
            let fin = stream.finalize()
            applyPatches(&replica, fin.patches)
            #expect(replica == fin.blocks)
            #expect(renderBlocksToHtml(fin.blocks, options: HtmlRenderOptions(gfm: true, math: false)) == ex.html, "GFM example \(ex.id) streaming mismatch")
        }
    }

    @Test("Full corpus transcripts match upstream HTML byte-for-byte under 1-char streaming and UTF-16 offsets")
    func corpusTranscriptsAndUtf16Offsets() {
        let transcript1 = "# Architecture Review\n\nHere is the summary with **bold**, *italic*, `src/stream.ts`, and [CommonMark][cm].\n\n1. First item:\n\n   ```ts\n   export const answer = 42\n   ```\n\n   Follow-up paragraph inside item 1.\n\n2. Second item with a nested blockquote:\n   > Quoted line one\n   lazy continuation line two\n\n| Phase | Cost | Share |\n| :--- | ---: | :---: |\n| Split | 6 us | 5% |\n| Render | 185 us | 10% |\n\n$$\n\\int_0^1 x^2\\,dx = \\frac{1}{3}\n$$\n\n[cm]: https://spec.commonmark.org/\n"
        let expectedHtml1 = "<h1>Architecture Review</h1>\n<p>Here is the summary with <strong>bold</strong>, <em>italic</em>, <code>src/stream.ts</code>, and <a href=\"https://spec.commonmark.org/\">CommonMark</a>.</p>\n<ol>\n<li>\n<p>First item:</p>\n<pre><code class=\"language-ts\">export const answer = 42\n</code></pre>\n<p>Follow-up paragraph inside item 1.</p>\n</li>\n<li>\n<p>Second item with a nested blockquote:</p>\n<blockquote>\n<p>Quoted line one\nlazy continuation line two</p>\n</blockquote>\n</li>\n</ol>\n<table>\n<thead>\n<tr>\n<th align=\"left\">Phase</th>\n<th align=\"right\">Cost</th>\n<th align=\"center\">Share</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"left\">Split</td>\n<td align=\"right\">6 us</td>\n<td align=\"center\">5%</td>\n</tr>\n<tr>\n<td align=\"left\">Render</td>\n<td align=\"right\">185 us</td>\n<td align=\"center\">10%</td>\n</tr>\n</tbody>\n</table>\n<div class=\"math-block\" data-math-delimiter=\"double-dollar\">\\int_0^1 x^2\\,dx = \\frac{1}{3}</div>\n"

        let stream = createMarkdownStream(StreamOptions(renderHtml: true))
        var replica: [MarkdownBlock] = []
        for ch in transcript1 {
            let f = stream.append(String(ch))
            applyPatches(&replica, f.patches)
            #expect(replica == f.blocks)
        }
        let fin = stream.finalize()
        applyPatches(&replica, fin.patches)
        #expect(replica == fin.blocks)
        #expect(renderBlocksToHtml(fin.blocks, options: HtmlRenderOptions(gfm: true, math: true)) == expectedHtml1)

        // Mermaid + UTF-16 emoji offsets
        let emojiMd = "🚀 Hello\n\n```mermaid\ngraph TD\n  A --> B\n```\n"
        let s2 = createMarkdownStream(StreamOptions(renderHtml: true))
        let f2 = s2.update(emojiMd, streaming: false)
        #expect(f2.blocks.count == 2)
        // "🚀" is 2 UTF-16 code units + " Hello\n" (7) + "\n" (1) = start offset 10 for block 1
        #expect(f2.blocks[0].start == 0)
        #expect(f2.blocks[0].end == 9)
        #expect(f2.blocks[1].start == 10)
        #expect(f2.blocks[1].kind == .mermaid(source: "graph TD\n  A --> B", htmlLiteral: nil, complete: true))
        #expect(f2.blocks[1].html == "<pre><code class=\"language-mermaid\">graph TD\n  A --&gt; B\n</code></pre>\n")

        // Unclosed display math reparse fallback
        let unclosedMath = "$$\nnot really closed math\n"
        let s3 = createMarkdownStream(StreamOptions(renderHtml: true))
        let f3 = s3.update(unclosedMath, streaming: false)
        #expect(f3.blocks.count == 1)
        #expect(f3.blocks[0].kind.typeName == "paragraph")
    }

    @Test("CRLF split across chunks, null-byte replacement, HTML block types, reset, and tagfilter")
    func crlfNullBytesHtmlBlocksAndOptions() {
        // Split \r and \n across separate append() calls
        let s = createMarkdownStream(StreamOptions(renderHtml: true))
        let f1 = s.append("# Title\r")
        #expect(f1.blocks.count == 1)
        _ = s.append("\n\r\nBody\u{0000}text")
        let fin = s.finalize()
        #expect(fin.blocks.count == 2)
        #expect(renderBlocksToHtml(fin.blocks) == "<h1>Title</h1>\n<p>Body\u{FFFD}text</p>\n")
        #expect(s.getText() == "# Title\r\n\r\nBody\u{0000}text")

        // reset clears stream state and restarts block IDs at 0
        s.reset()
        #expect(s.getBlocks().isEmpty)
        #expect(s.getText().isEmpty)
        let afterReset = s.append("Fresh\n")
        #expect(afterReset.blocks.count == 1)
        #expect(afterReset.blocks[0].id == 0)

        // Direct BlockParser & splitTableRow with escaped pipes
        #expect(splitTableRow("| a \\| b | c \\\\| d |") == ["a \\| b", "c \\\\", "d"])
        let bp = BlockParser(options: ParserOptions(gfm: true, math: true))
        bp.incorporateLine("<!-- comment -->")
        bp.incorporateLine("<?xml version=\"1.0\"?>")
        bp.incorporateLine("<!DOCTYPE html>")
        bp.incorporateLine("<![CDATA[raw]]>")
        bp.incorporateLine("    indented code")
        bp.finish()
        #expect(bp.doc.children.count == 5)
        #expect(bp.doc.children[0].type == .htmlBlock && bp.doc.children[0].htmlBlockType == 2)
        #expect(bp.doc.children[1].type == .htmlBlock && bp.doc.children[1].htmlBlockType == 3)
        #expect(bp.doc.children[2].type == .htmlBlock && bp.doc.children[2].htmlBlockType == 4)
        #expect(bp.doc.children[3].type == .htmlBlock && bp.doc.children[3].htmlBlockType == 5)
        #expect(bp.doc.children[4].type == .codeBlock && !bp.doc.children[4].isFenced)

        // filterDisallowedRawHtml & escapeHtml
        #expect(filterDisallowedRawHtml("<ScRiPt>alert(1)</script><iframe src=x><b>ok</b>") == "&lt;ScRiPt>alert(1)&lt;/script>&lt;iframe src=x><b>ok</b>")
        #expect(escapeHtml("a & b < c > \"d\"") == "a &amp; b &lt; c &gt; &quot;d&quot;")

        // settleOnComplete: false holds top-level block until next visible block arrives
        let delayed = createMarkdownStream(StreamOptions(settleOnComplete: false, renderHtml: true))
        let d1 = delayed.append("# Heading\n")
        #expect(d1.blocks.count == 1)
        #expect(d1.blocks[0].status == .streaming)
        let d2 = delayed.append("\nNext paragraph")
        #expect(d2.blocks.count == 2)
        #expect(d2.blocks[0].status == .settled)
        #expect(d2.blocks[1].status == .streaming)
    }

    private func applyPatches(_ replica: inout [MarkdownBlock], _ patches: [BlockPatch]) {
        for patch in patches {
            switch patch {
            case .append(let block):
                replica.append(block)
            case .replace(_, let index, let block), .finalize(_, let index, let block):
                replica[index] = block
            case .truncate(let keepCount):
                replica.removeSubrange(keepCount..<replica.count)
            }
        }
    }
}
