import Testing
import OpenTUICore

// MARK: - StyledText Tests

@Suite("StyledText Tests")
struct StyledTextTests {
    @Test("reverse applies the inverse text attribute")
    func reverseAppliesInverseAttribute() {
        #expect(reverse("status").attributes == TextAttributes.inverse)
        #expect(inverse("status").attributes == TextAttributes.inverse)
        #expect(hidden("secret").attributes == TextAttributes.hidden)
    }

    @Test("foreground, bright, and background color helpers resolve CSS colors")
    func colorHelpers() {
        let fgPairs: [(TextChunk, String)] = [
            (black("a"), "black"),
            (red("a"), "red"),
            (green("a"), "green"),
            (yellow("a"), "yellow"),
            (blue("a"), "blue"),
            (magenta("a"), "magenta"),
            (cyan("a"), "cyan"),
            (white("a"), "white"),
            (brightBlack("a"), "brightBlack"),
            (brightRed("a"), "brightRed"),
            (brightGreen("a"), "brightGreen"),
            (brightYellow("a"), "brightYellow"),
            (brightBlue("a"), "brightBlue"),
            (brightMagenta("a"), "brightMagenta"),
            (brightCyan("a"), "brightCyan"),
            (brightWhite("a"), "brightWhite"),
        ]
        for (chunk, name) in fgPairs {
            #expect(chunk.text == "a")
            #expect(chunk.fg == parseColor(name))
            #expect(chunk.bg == nil)
            #expect(chunk.attributes == 0)
            #expect(chunk.link == nil)
        }

        let bgPairs: [(TextChunk, String)] = [
            (bgBlack("b"), "black"),
            (bgRed("b"), "red"),
            (bgGreen("b"), "green"),
            (bgYellow("b"), "yellow"),
            (bgBlue("b"), "blue"),
            (bgMagenta("b"), "magenta"),
            (bgCyan("b"), "cyan"),
            (bgWhite("b"), "white"),
        ]
        for (chunk, name) in bgPairs {
            #expect(chunk.text == "b")
            #expect(chunk.fg == nil)
            #expect(chunk.bg == parseColor(name))
            #expect(chunk.attributes == 0)
        }
    }

    @Test("attribute helpers set individual flags and merge across nested calls")
    func attributeHelpersAndNesting() {
        #expect(bold("x").attributes == TextAttributes.bold)
        #expect(italic("x").attributes == TextAttributes.italic)
        #expect(underline("x").attributes == TextAttributes.underline)
        #expect(strikethrough("x").attributes == TextAttributes.strikethrough)
        #expect(dim("x").attributes == TextAttributes.dim)
        #expect(blink("x").attributes == TextAttributes.blink)

        let combined = bgBlue(bold(italic(underline(red("hello")))))
        #expect(combined.text == "hello")
        #expect(combined.fg == parseColor("red"))
        #expect(combined.bg == parseColor("blue"))
        #expect(
            combined.attributes
                == (TextAttributes.bold | TextAttributes.italic | TextAttributes.underline)
        )

        // Newer fg overrides older fg while keeping bg and attributes
        let overridden = green(combined)
        #expect(overridden.fg == parseColor("green"))
        #expect(overridden.bg == parseColor("blue"))
        #expect(overridden.attributes == combined.attributes)
    }

    @Test("custom fg, bg, and link transforms accept strings, RGBA, and chunks")
    func customColorAndLinkTransforms() {
        let customFg = RGBA.fromInts(10, 20, 30, 255)
        let customBg = RGBA.fromInts(40, 50, 60, 255)

        let styled = bg(customBg)(fg(customFg)(bold("custom")))
        #expect(styled.fg == customFg)
        #expect(styled.bg == customBg)
        #expect(styled.attributes == TextAttributes.bold)

        let hexStyled = fg("#112233")(bg("#445566")("hex"))
        #expect(hexStyled.fg == parseColor("#112233"))
        #expect(hexStyled.bg == parseColor("#445566"))

        // Empty color string acts as unset (matching JS truthiness)
        let kept = fg("")(red("keep"))
        #expect(kept.fg == parseColor("red"))

        // Link on plain input leaves fg/bg/attributes nil
        let plainLink = link("https://example.com")("click")
        #expect(plainLink.text == "click")
        #expect(plainLink.fg == nil)
        #expect(plainLink.bg == nil)
        #expect(plainLink.attributes == nil)
        #expect(plainLink.link == TextChunkLink(url: "https://example.com"))

        // Link preserves existing chunk styling and subsequent styling preserves link
        let styledLink = bold(link("https://example.com")(blue("docs")))
        #expect(styledLink.text == "docs")
        #expect(styledLink.fg == parseColor("blue"))
        #expect(styledLink.attributes == TextAttributes.bold)
        #expect(styledLink.link == TextChunkLink(url: "https://example.com"))
    }

    @Test("StylableInput handles strings, numbers, booleans, and chunks")
    func stylableInputTypes() {
        #expect(red(42).text == "42")
        #expect(red(3.5).text == "3.5")
        #expect(red(42.0).text == "42")
        #expect(red(true).text == "true")
        #expect(red(false).text == "false")
    }

    @Test("StyledText, isStyledText, stringToStyledText, and template builder t")
    func styledTextContainersAndTemplateBuilder() {
        let fromString = stringToStyledText("plain")
        #expect(isStyledText(fromString))
        #expect(!isStyledText("plain"))
        #expect(!isStyledText(nil))
        #expect(!isStyledText(TextChunk(text: "plain")))
        #expect(fromString.chunks == [TextChunk(text: "plain")])
        #expect(fromString.plainText == "plain")

        let built = t(["Hello ", "! Count: ", ""], [.chunk(bold(red("world"))), .int(7)])
        #expect(built.chunks == [
            TextChunk(text: "Hello ", attributes: 0),
            bold(red("world")),
            TextChunk(text: "! Count: ", attributes: 0),
            TextChunk(text: "7", attributes: 0),
        ])
        #expect(built.plainText == "Hello world! Count: 7")

        let interpolated = t("Hello \(bold(red("world")))! Count: \(7)")
        #expect(interpolated == built)
    }
}

// MARK: - DetectLinks Tests

@Suite("DetectLinks Tests")
struct DetectLinksTests {
    private func whiteChunk(_ text: String) -> TextChunk {
        TextChunk(text: text, fg: RGBA.fromInts(255, 255, 255, 255), attributes: 0)
    }

    private func utf16Offset(of needle: String, in haystack: String, from startOffset: Int = 0) -> Int {
        let h = Array(haystack.utf16)
        let n = Array(needle.utf16)
        for i in startOffset...(h.count - n.count) {
            if Array(h[i..<(i + n.count)]) == n {
                return i
            }
        }
        fatalError("Needle '\(needle)' not found in '\(haystack)'")
    }

    private func utf16Slice(_ text: String, _ start: Int, _ end: Int) -> String {
        let units = Array(text.utf16)
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    @Test("normalizeMarkdownLinkTarget unescapes ASCII punctuation and preserves other backslashes")
    func normalizeMarkdownLinkTargetBehavior() {
        #expect(
            normalizeMarkdownLinkTarget(#"custom://example.test/a\(b\)/c\\d\*e"#)
                == #"custom://example.test/a(b)/c\d*e"#
        )
        #expect(normalizeMarkdownLinkTarget(#"https://example.test/\a\z\"#) == #"https://example.test/\a\z\"#)
        #expect(normalizeMarkdownLinkTarget("") == "")
    }

    @Test("sets link on markup.link.url and markup.link.label chunks")
    func markupLinkUrlAndLabel() {
        let destination = "custom+v1://example.test/path"
        let content = "[Click here](\(destination))"
        let start = utf16Offset(of: destination, in: content)
        let destLen = destination.utf16.count
        let contentLen = content.utf16.count
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(0, 1, "markup.link"),
            SimpleHighlight(1, 11, "markup.link.label"),
            SimpleHighlight(11, start, "markup.link"),
            SimpleHighlight(start, start + destLen, "markup.link.url"),
            SimpleHighlight(start + destLen, contentLen, "markup.link"),
        ]
        let chunks = [
            whiteChunk("["),
            whiteChunk("Click here"),
            whiteChunk("]("),
            whiteChunk(destination),
            whiteChunk(")"),
        ]

        let result = detectLinks(chunks, context: DetectLinksContext(content: content, highlights: highlights))

        #expect(result.first(where: { $0.text == destination })?.link == TextChunkLink(url: destination))
        #expect(result.first(where: { $0.text == "Click here" })?.link == TextChunkLink(url: destination))
    }

    @Test("sets link on string.special.url chunks")
    func stringSpecialUrl() {
        let content = "// see https://example.com for details"
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(0, 38, "comment"),
            SimpleHighlight(7, 26, "string.special.url"),
        ]
        let chunks = [whiteChunk("// see "), whiteChunk("https://example.com"), whiteChunk(" for details")]

        let result = detectLinks(chunks, context: DetectLinksContext(content: content, highlights: highlights))

        #expect(
            result.first(where: { $0.text == "https://example.com" })?.link
                == TextChunkLink(url: "https://example.com")
        )
    }

    @Test("does not set link on non-URL chunks or when no URL scopes exist")
    func nonUrlChunksUnchanged() {
        let content = "const x = 42"
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(0, 5, "keyword"),
            SimpleHighlight(6, 7, "variable"),
            SimpleHighlight(10, 12, "number"),
        ]
        let chunks = [whiteChunk("const"), whiteChunk(" "), whiteChunk("x"), whiteChunk(" = "), whiteChunk("42")]
        let result = detectLinks(chunks, context: DetectLinksContext(content: content, highlights: highlights))
        for item in result {
            #expect(item.link == nil)
        }

        let mdContent = "**label** and `code`"
        let mdHighlights: [SimpleHighlight] = [
            SimpleHighlight(0, 9, "markup.strong"),
            SimpleHighlight(0, 2, "conceal", HighlightMeta(conceal: "")),
            SimpleHighlight(2, 7, "markup.link.label"),
            SimpleHighlight(7, 9, "conceal", HighlightMeta(conceal: "")),
            SimpleHighlight(14, 20, "markup.raw"),
        ]
        let mdChunks = [whiteChunk("label"), whiteChunk(" and "), whiteChunk("code")]
        let mdResult = detectLinks(mdChunks, context: DetectLinksContext(content: mdContent, highlights: mdHighlights))
        #expect(mdResult == mdChunks)
    }

    @Test("detects links when chunks have concealed text")
    func concealedTextChunks() {
        let content = "[Click here](https://example.com)"
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(0, 1, "markup.link"),
            SimpleHighlight(1, 11, "markup.link.label"),
            SimpleHighlight(11, 13, "markup.link"),
            SimpleHighlight(13, 32, "markup.link.url"),
            SimpleHighlight(32, 33, "markup.link"),
        ]
        let chunks = [
            whiteChunk(""),
            whiteChunk("Click here"),
            whiteChunk(" "),
            whiteChunk("https://example.com"),
            whiteChunk(""),
        ]

        let result = detectLinks(chunks, context: DetectLinksContext(content: content, highlights: highlights))

        #expect(
            result.first(where: { $0.text == "https://example.com" })?.link
                == TextChunkLink(url: "https://example.com")
        )
        #expect(
            result.first(where: { $0.text == "Click here" })?.link
                == TextChunkLink(url: "https://example.com")
        )
    }

    @Test("links formatted and source-replaced label chunks across intervening conceal captures")
    func formattedAndSourceReplacedLabelChunks() {
        let content = "[a **A&amp;B** z](https://example.com)"
        let labelEnd = utf16Offset(of: "]", in: content)
        let entityStart = utf16Offset(of: "&amp;", in: content)
        let urlStart = utf16Offset(of: "https://", in: content)
        let contentLen = content.utf16.count
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(1, labelEnd, "markup.link.label"),
            SimpleHighlight(3, labelEnd - 2, "markup.strong"),
            SimpleHighlight(3, 5, "conceal", HighlightMeta(conceal: "")),
            SimpleHighlight(entityStart, entityStart + 5, "character.special", HighlightMeta(conceal: "&")),
            SimpleHighlight(labelEnd - 4, labelEnd - 2, "conceal", HighlightMeta(conceal: "")),
            SimpleHighlight(labelEnd, labelEnd + 1, "conceal", HighlightMeta(conceal: " ")),
            SimpleHighlight(urlStart, contentLen - 1, "markup.link.url"),
        ]
        let chunks = ["a ", "A", "&", "B", " z", " ", "(", "https://example.com"].map(whiteChunk)
        let sourceRanges = [
            LinkSourceRange(start: 1, end: 3),
            LinkSourceRange(start: 5, end: entityStart),
            LinkSourceRange(start: entityStart, end: entityStart + 5),
            LinkSourceRange(start: entityStart + 5, end: entityStart + 6),
            LinkSourceRange(start: labelEnd - 2, end: labelEnd),
            LinkSourceRange(start: labelEnd, end: labelEnd + 1),
            LinkSourceRange(start: labelEnd + 1, end: labelEnd + 2),
            LinkSourceRange(start: urlStart, end: contentLen - 1),
        ]

        let result = detectLinks(
            chunks,
            context: DetectLinksContext(content: content, highlights: highlights, sourceRanges: sourceRanges)
        )

        for label in result.prefix(5) {
            #expect(label.link == TextChunkLink(url: "https://example.com"))
        }
        #expect(result[5].link == nil)
        #expect(result[7].link == TextChunkLink(url: "https://example.com"))
    }

    @Test("normalizes escaped named destinations while preserving literal autolink backslashes")
    func escapedNamedDestinationsVsAutolink() {
        let destination = #"custom://example.test/a\(b\)/c\\d\*e"#
        let autolink = #"https://example.test/a\*b"#
        let content = "[label](\(destination)) <\(autolink)>"
        let start = utf16Offset(of: destination, in: content)
        let autoStart = utf16Offset(of: autolink, in: content)
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(1, 6, "markup.link.label"),
            SimpleHighlight(start, start + destination.utf16.count, "markup.link.url"),
            SimpleHighlight(autoStart, autoStart + autolink.utf16.count, "markup.link.url"),
        ]

        let result = detectLinks(
            [whiteChunk("label"), whiteChunk(destination), whiteChunk(autolink)],
            context: DetectLinksContext(
                content: content,
                highlights: highlights,
                sourceRanges: [
                    LinkSourceRange(start: 1, end: 6),
                    LinkSourceRange(start: start, end: start + destination.utf16.count),
                    LinkSourceRange(start: autoStart, end: autoStart + autolink.utf16.count),
                ]
            )
        )

        #expect(result.map { $0.link?.url } == [
            #"custom://example.test/a(b)/c\d*e"#,
            #"custom://example.test/a(b)/c\d*e"#,
            autolink,
        ])
    }

    @Test("associates each named label with its destination, never an unrelated autolink or bare URL")
    func associatesEachNamedLabelWithItsDestination() {
        let content =
            "[orphan] [other] <https://auto.test> https://bare.test [a](custom+v1://target.test) [b](https://second.test)"
        let orphanStart = utf16Offset(of: "orphan", in: content)
        let otherStart = utf16Offset(of: "other", in: content)
        let autoStart = utf16Offset(of: "https://auto.test", in: content)
        let bareStart = utf16Offset(of: "https://bare.test", in: content)
        let labelStart = utf16Offset(of: "a](", in: content)
        let targetStart = utf16Offset(of: "custom+v1://target.test", in: content)
        let secondLabel = utf16Offset(of: "b](", in: content)
        let secondTarget = utf16Offset(of: "https://second.test", in: content)

        let highlights: [SimpleHighlight] = [
            SimpleHighlight(orphanStart, orphanStart + 6, "markup.link.label"),
            SimpleHighlight(otherStart, otherStart + 5, "markup.link.label"),
            SimpleHighlight(autoStart, autoStart + "https://auto.test".utf16.count, "markup.link.url"),
            SimpleHighlight(labelStart, labelStart + 1, "markup.link.label"),
            SimpleHighlight(targetStart, targetStart + "custom+v1://target.test".utf16.count, "markup.link.url"),
            SimpleHighlight(secondLabel, secondLabel + 1, "markup.link.label"),
            SimpleHighlight(secondTarget, secondTarget + "https://second.test".utf16.count, "markup.link.url"),
        ]
        let sourceRanges = [
            LinkSourceRange(start: orphanStart, end: orphanStart + 6),
            LinkSourceRange(start: otherStart, end: otherStart + 5),
            LinkSourceRange(start: autoStart, end: autoStart + "https://auto.test".utf16.count),
            LinkSourceRange(start: bareStart, end: bareStart + "https://bare.test".utf16.count),
            LinkSourceRange(start: labelStart, end: labelStart + 1),
            LinkSourceRange(start: targetStart, end: targetStart + "custom+v1://target.test".utf16.count),
            LinkSourceRange(start: secondLabel, end: secondLabel + 1),
            LinkSourceRange(start: secondTarget, end: secondTarget + "https://second.test".utf16.count),
        ]
        let chunks = sourceRanges.map { whiteChunk(utf16Slice(content, $0.start, $0.end)) }

        let result = detectLinks(
            chunks,
            context: DetectLinksContext(content: content, highlights: highlights, sourceRanges: sourceRanges)
        )

        #expect(result.map { $0.link?.url } == [
            nil,
            nil,
            "https://auto.test",
            "https://bare.test",
            "custom+v1://target.test",
            "custom+v1://target.test",
            "https://second.test",
            "https://second.test",
        ])
    }

    @Test("prioritizes outer formatted label and explicit destinations over visible URL text")
    func prioritizesExplicitDestinationsOverVisibleUrlText() {
        do {
            let content = "[**before https://visible.test after**](custom+v1://target.test)"
            let labelStart = 1
            let labelEnd = utf16Offset(of: "]", in: content)
            let visibleStart = utf16Offset(of: "https://visible.test", in: content)
            let visibleLen = "https://visible.test".utf16.count
            let targetStart = utf16Offset(of: "custom+v1://target.test", in: content)
            let targetLen = "custom+v1://target.test".utf16.count
            let highlights: [SimpleHighlight] = [
                SimpleHighlight(labelStart, labelEnd, "markup.link.label"),
                SimpleHighlight(labelStart + 2, labelEnd, "markup.link.label"),
                SimpleHighlight(visibleStart, visibleStart + visibleLen, "string.special.url"),
                SimpleHighlight(targetStart, targetStart + targetLen, "markup.link.url"),
            ]
            let chunks = [
                whiteChunk("before "),
                whiteChunk("https://visible.test"),
                whiteChunk(" after"),
                whiteChunk("custom+v1://target.test"),
            ]
            let sourceRanges = [
                LinkSourceRange(start: labelStart + 2, end: visibleStart),
                LinkSourceRange(start: visibleStart, end: visibleStart + visibleLen),
                LinkSourceRange(start: visibleStart + visibleLen, end: labelEnd - 2),
                LinkSourceRange(start: targetStart, end: targetStart + targetLen),
            ]

            let result = detectLinks(
                chunks,
                context: DetectLinksContext(content: content, highlights: highlights, sourceRanges: sourceRanges)
            )
            #expect(result.map { $0.link?.url } == Array(repeating: "custom+v1://target.test", count: 4))
        }

        do {
            let content = "[https://visible.test](custom://target.test)"
            let visibleStart = 1
            let visibleEnd = utf16Offset(of: "]", in: content)
            let targetStart = utf16Offset(of: "custom://target.test", in: content)
            let highlights: [SimpleHighlight] = [
                SimpleHighlight(visibleStart, visibleEnd, "markup.link.label"),
                SimpleHighlight(visibleStart, visibleEnd, "string.special.url"),
                SimpleHighlight(targetStart, content.utf16.count - 1, "markup.link.url"),
            ]

            let result = detectLinks(
                [whiteChunk("https://visible.test"), whiteChunk("custom://target.test")],
                context: DetectLinksContext(
                    content: content,
                    highlights: highlights,
                    sourceRanges: [
                        LinkSourceRange(start: visibleStart, end: visibleEnd),
                        LinkSourceRange(start: targetStart, end: content.utf16.count - 1),
                    ]
                )
            )
            #expect(result.map { $0.link?.url } == ["custom://target.test", "custom://target.test"])
        }
    }

    @Test("splits bare HTTP(S) URLs with balanced parens and strips trailing punctuation")
    func splitsBareHttpUrlsWithBalancedParens() {
        let content =
            "ftp://ignored.test mailto:user@test See HtTpS://one.test/path, then (http://two.test/a_(b))."
        let result = detectLinks([whiteChunk(content)], context: DetectLinksContext(content: content))

        #expect(result.map(\.text) == [
            "ftp://ignored.test mailto:user@test See ",
            "HtTpS://one.test/path",
            ", then (",
            "http://two.test/a_(b)",
            ").",
        ])
        #expect(result.map { $0.link?.url } == [
            nil,
            "HtTpS://one.test/path",
            nil,
            "http://two.test/a_(b)",
            nil,
        ])
    }

    @Test("styles only bare URLs like link labels and keeps their existing attributes")
    func stylesOnlyBareUrlsLikeLinkLabels() {
        let content = "<https://auto.test> https://bare.test"
        let highlights: [SimpleHighlight] = [SimpleHighlight(1, 18, "markup.link.url")]
        let boldAttr = createTextAttributes(bold: true)
        let blueColor = RGBA.fromInts(100, 150, 255, 255)
        let whiteColor = RGBA.fromInts(255, 255, 255, 255)
        let syntaxStyle = LinkStyleTable([
            "markup.link.label": StyleAttrs(fg: .rgba(blueColor), underline: true),
        ])

        var input = whiteChunk(content)
        input.attributes = boldAttr

        let result = detectLinks(
            [input],
            context: DetectLinksContext(content: content, highlights: highlights, syntaxStyle: syntaxStyle)
        )

        #expect(result.map(\.text) == ["<", "https://auto.test", "> ", "https://bare.test"])
        #expect(result.map(\.fg) == [whiteColor, whiteColor, whiteColor, blueColor])
        #expect(
            result.map(\.attributes) == [
                boldAttr,
                boldAttr,
                boldAttr,
                createTextAttributes(bold: true, underline: true),
            ]
        )
    }

    @Test("preserves interior URL apostrophes while excluding surrounding quotes")
    func preservesInteriorApostrophes() {
        let content = "Visit https://example.test/it's-valid or 'https://example.test/quoted'."
        let result = detectLinks([whiteChunk(content)], context: DetectLinksContext(content: content))

        let urls = result.compactMap { $0.link?.url }
        #expect(urls == [
            "https://example.test/it's-valid",
            "https://example.test/quoted",
        ])
    }

    @Test("excludes concealed formatting markers without stripping literal URL characters")
    func excludesConcealedFormattingMarkers() {
        for marker in ["*", "**", "_", "__", "~~"] {
            let url = "https://example.test/path_*~"
            let content = "\(marker)\(url)\(marker),"
            let markerLen = marker.utf16.count
            let end = markerLen + url.utf16.count
            var highlights: [SimpleHighlight] = []
            for idx in 0..<markerLen {
                highlights.append(SimpleHighlight(end + idx, end + idx + 1, "conceal", HighlightMeta(conceal: "")))
            }

            let result = detectLinks(
                [whiteChunk(url)],
                context: DetectLinksContext(
                    content: content,
                    highlights: highlights,
                    sourceRanges: [LinkSourceRange(start: markerLen, end: end)]
                )
            )
            #expect(result[0].link?.url == url)
        }
    }

    @Test("does not link bare URLs inside inline or block raw markup")
    func excludesRawMarkup() {
        let content = "`https://inline.test` https://visible.test ```https://block.test```"
        let inlineStart = utf16Offset(of: "https://inline.test", in: content)
        let blockStart = utf16Offset(of: "https://block.test", in: content)
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(inlineStart - 1, inlineStart + "https://inline.test".utf16.count + 1, "markup.raw"),
            SimpleHighlight(blockStart - 3, blockStart + "https://block.test".utf16.count + 3, "markup.raw.block"),
        ]

        let result = detectLinks([whiteChunk(content)], context: DetectLinksContext(content: content, highlights: highlights))

        #expect(result.map(\.text) == [
            "`https://inline.test` ",
            "https://visible.test",
            " ```https://block.test```",
        ])
        #expect(result.map { $0.link?.url } == [nil, "https://visible.test", nil])
    }

    @Test("preserves styles and existing links when splitting URL chunks")
    func preservesStylesAndExistingLinks() {
        let content = "prefix https://new.test suffix"
        let fgColor = RGBA.fromInts(10, 20, 30, 255)
        let bgColor = RGBA.fromInts(40, 50, 60, 255)
        let styled = TextChunk(text: content, fg: fgColor, bg: bgColor, attributes: 7)
        let existing = TextChunk(
            text: "existing",
            fg: RGBA.fromInts(255, 255, 255, 255),
            attributes: 0,
            link: TextChunkLink(url: "https://existing.test")
        )

        let result = detectLinks(
            [styled, existing],
            context: DetectLinksContext(
                content: "\(content)existing",
                sourceRanges: [
                    LinkSourceRange(start: 0, end: content.utf16.count),
                    LinkSourceRange(start: content.utf16.count, end: content.utf16.count + existing.text.utf16.count),
                ]
            )
        )

        #expect(result.map(\.text) == ["prefix ", "https://new.test", " suffix", "existing"])
        #expect(result[1].link == TextChunkLink(url: "https://new.test"))
        #expect(result[3].link == TextChunkLink(url: "https://existing.test"))
        for item in result.prefix(3) {
            #expect(item.fg == fgColor)
            #expect(item.bg == bgColor)
            #expect(item.attributes == 7)
        }
    }

    @Test("uses exact source ranges for conceal replacements and repeated visible text")
    func exactSourceRangesForConcealAndRepeatedText() {
        let content = "xx [xx](https://example.com) xx"
        let labelStart = utf16Offset(of: "xx", in: content, from: 3)
        let urlStart = utf16Offset(of: "https://", in: content)
        let urlLen = "https://example.com".utf16.count
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(labelStart, labelStart + 2, "markup.link.label"),
            SimpleHighlight(labelStart + 2, labelStart + 3, "conceal", HighlightMeta(conceal: "xx")),
            SimpleHighlight(urlStart, urlStart + urlLen, "markup.link.url"),
        ]
        let chunks = [
            whiteChunk("xx "),
            whiteChunk("xx"),
            whiteChunk("xx"),
            whiteChunk("("),
            whiteChunk("https://example.com"),
            whiteChunk(" xx"),
        ]
        let sourceRanges = [
            LinkSourceRange(start: 0, end: 3),
            LinkSourceRange(start: labelStart, end: labelStart + 2),
            LinkSourceRange(start: labelStart + 2, end: labelStart + 3),
            LinkSourceRange(start: labelStart + 3, end: labelStart + 4),
            LinkSourceRange(start: urlStart, end: urlStart + urlLen),
            LinkSourceRange(start: content.utf16.count - 3, end: content.utf16.count),
        ]

        let result = detectLinks(
            chunks,
            context: DetectLinksContext(content: content, highlights: highlights, sourceRanges: sourceRanges)
        )

        #expect(result[0].link == nil)
        #expect(result[1].link == TextChunkLink(url: "https://example.com"))
        #expect(result[2].link == nil)
        #expect(result[4].link == TextChunkLink(url: "https://example.com"))
        #expect(result[5].link == nil)
    }

    @Test("does not split replacement text using unrelated source URL offsets")
    func doesNotSplitReplacementTextUsingUnrelatedOffsets() {
        let content = "https://hidden.test https://visible.test"
        let firstEnd = utf16Offset(of: " ", in: content)
        let chunks = [whiteChunk("replacement"), whiteChunk(" "), whiteChunk("https://visible.test")]
        let sourceRanges = [
            LinkSourceRange(start: 0, end: firstEnd),
            LinkSourceRange(start: firstEnd, end: firstEnd + 1),
            LinkSourceRange(start: firstEnd + 1, end: content.utf16.count),
        ]

        let result = detectLinks(
            chunks,
            context: DetectLinksContext(content: content, sourceRanges: sourceRanges)
        )

        #expect(result.map(\.text) == ["replacement", " ", "https://visible.test"])
        #expect(result.map { $0.link?.url } == [nil, nil, "https://visible.test"])
    }

    @Test("preserves exact UTF-16 code unit offsets across CJK and emoji surrogate pairs")
    func utf16OffsetsWithCJKAndEmoji() {
        let emojiUrl = "https://example.test/🎉"
        let bareUrl = "https://bare.test/日本語"
        let content = "🚀 中文 [ラベル🎉](\(emojiUrl)) ✨ \(bareUrl)."
        let labelStart = utf16Offset(of: "ラベル🎉", in: content)
        let labelEnd = labelStart + "ラベル🎉".utf16.count
        let urlStart = utf16Offset(of: emojiUrl, in: content)
        let urlEnd = urlStart + emojiUrl.utf16.count
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(labelStart, labelEnd, "markup.link.label"),
            SimpleHighlight(urlStart, urlEnd, "markup.link.url"),
        ]

        let result = detectLinks([whiteChunk(content)], context: DetectLinksContext(content: content, highlights: highlights))

        #expect(result.map(\.text) == [
            "🚀 中文 [",
            "ラベル🎉",
            "](",
            emojiUrl,
            ") ✨ ",
            bareUrl,
            ".",
        ])
        #expect(result.map { $0.link?.url } == [
            nil,
            emojiUrl,
            nil,
            emojiUrl,
            nil,
            bareUrl,
            nil,
        ])
    }

    @Test("processes dense raw markup, named links, bare URLs, and chunks efficiently")
    func denseWorkloadScaling() {
        let count = 1_500
        var parts: [String] = []
        parts.reserveCapacity(count)
        var highlights: [SimpleHighlight] = []
        highlights.reserveCapacity(count * 3)
        var chunks: [TextChunk] = []
        chunks.reserveCapacity(count * 3)
        var sourceRanges: [LinkSourceRange] = []
        sourceRanges.reserveCapacity(count * 3)
        var offset = 0

        for index in 0..<count {
            let raw = "`https://hidden\(index).test`"
            let label = "label\(index)"
            let target = "custom://target\(index).test"
            let visible = "https://visible\(index).test"
            let part = "\(raw) [\(label)](\(target)) \(visible) "
            let labelStart = offset + raw.utf16.count + 2
            let targetStart = labelStart + label.utf16.count + 2
            let visibleStart = targetStart + target.utf16.count + 2

            parts.append(part)
            highlights.append(SimpleHighlight(offset, offset + raw.utf16.count, "markup.raw"))
            highlights.append(SimpleHighlight(labelStart, labelStart + label.utf16.count, "markup.link.label"))
            highlights.append(SimpleHighlight(targetStart, targetStart + target.utf16.count, "markup.link.url"))
            chunks.append(whiteChunk(label))
            chunks.append(whiteChunk(target))
            chunks.append(whiteChunk(visible))
            sourceRanges.append(LinkSourceRange(start: labelStart, end: labelStart + label.utf16.count))
            sourceRanges.append(LinkSourceRange(start: targetStart, end: targetStart + target.utf16.count))
            sourceRanges.append(LinkSourceRange(start: visibleStart, end: visibleStart + visible.utf16.count))
            offset += part.utf16.count
        }

        let result = detectLinks(
            chunks,
            context: DetectLinksContext(
                content: parts.joined(),
                highlights: highlights,
                sourceRanges: sourceRanges
            )
        )

        #expect(result.count == count * 3)
        #expect(result[0].link?.url == "custom://target0.test")
        #expect(result[1].link?.url == "custom://target0.test")
        #expect(result[2].link?.url == "https://visible0.test")
        #expect(result[result.count - 3].link?.url == "custom://target\(count - 1).test")
        #expect(result[result.count - 2].link?.url == "custom://target\(count - 1).test")
        #expect(result[result.count - 1].link?.url == "https://visible\(count - 1).test")
    }
}

// MARK: - TerminalCapabilityDetection Tests

@Suite("TerminalCapabilityDetection Tests")
struct TerminalCapabilityDetectionTests {
    @Test("classifies every upstream capability response sequence")
    func capabilityResponseClassification() {
        let cases: [(String, Bool)] = [
            ("\u{1B}[?1016;2$y", true),
            ("\u{1B}[?2027;0$y", true),
            ("\u{1B}[?2031;2$y", true),
            ("\u{1B}[?1004;1$y", true),
            ("\u{1B}[?2026;2$y", true),
            ("\u{1B}[?2004;2$y", true),
            ("\u{1B}[1;2R", false),
            ("\u{1B}[20;30R", false),
            ("\u{1B}P>|kitty(0.40.1)\u{1B}\\", true),
            ("\u{1B}P>|ghostty 1.1.3\u{1B}\\", true),
            ("\u{1B}P>|tmux 3.5a\u{1B}\\", true),
            ("\u{1B}P1+r4d73=2570312573\u{1B}\\", true),
            ("\u{1B}P1+r4d73\u{1B}\\", true),
            ("\u{1B}P1+r4d73=\u{1B}\\", true),
            ("\u{1B}P0+r\u{1B}\\", true),
            ("\u{1B}P0+r4D73\u{1B}\\", true),
            ("\u{1B}P1+r544e=787465726d\u{1B}\\", false),
            ("\u{1B}P1+r4d73=abc\u{1B}\\", true),
            ("\u{1B}P1+r4d73=zz\u{1B}\\", true),
            ("\u{1B}P1+r524742=382F382F38\u{1B}\\", true),
            ("\u{1B}P1+r5463\u{1B}\\", true),
            ("\u{1B}P0+r524742\u{1B}\\", true),
            ("\u{1B}P0+r5463\u{1B}\\", true),
            ("\u{1B}_Gi=1;OK\u{1B}\\", true),
            ("\u{1B}_Gi=1;EINVAL:Zero width/height not allowed\u{1B}\\", true),
            ("\u{1B}[?62;c", true),
            ("\u{1B}[?62;22c", true),
            ("\u{1B}[?1;2;4c", true),
            ("\u{1B}[?6c", true),
            ("\u{1B}[?0u", true),
            ("\u{1B}[?1u", true),
            ("\u{1B}[?31u", true),
            ("\u{1B}]99;i=opentui-notifications:p=?;p=title,body\u{1B}\\", true),
            ("\u{1B}]99;i=opentui-notifications:p=?;p=title,body\u{07}", true),
            ("\u{1B}]1337;Capabilities=T2NoH\u{1B}\\", true),
            ("\u{1B}]7501;?\u{1B}\\", true),
            ("\u{1B}]7501;?:states=idle,working:kinds=auth\u{07}", true),
            ("\u{1B}]7501; ? : states=idle\u{1B}\\", true),
            ("\u{1B}]7501;state=idle\u{1B}\\", false),
            ("\u{1B}]75010;?\u{1B}\\", false),
            ("a", false),
            ("A", false),
            ("\u{1B}", false),
            ("\u{1B}a", false),
            ("\u{1B}[A", false),
            ("\u{1B}[B", false),
            ("\u{1B}[C", false),
            ("\u{1B}[D", false),
            ("\u{1B}OP", false),
            ("\u{1B}[11~", false),
            ("\u{1B}[24~", false),
            ("\u{1B}[1;2A", false),
            ("\u{1B}[1;5C", false),
            ("\u{1B}[<35;20;5m", false),
            ("\u{1B}[<0;10;10M", false),
            ("\u{1B}]9;hello\u{1B}\\", false),
            ("\u{1B}]777;notify;title;body\u{1B}\\", false),
            ("\u{1B}]99;i=other:p=?;p=title\u{1B}\\", false),
            ("\u{1B}[?1016;0$y", true),
        ]

        for (sequence, expected) in cases {
            #expect(isCapabilityResponse(sequence) == expected)
        }

        // Additional edge cases: progressive enhancement keyboard reply, embedded substring, BEL-terminated iTerm2
        #expect(isCapabilityResponse("\u{1B}[?1;2u"))
        #expect(isCapabilityResponse("prefix\u{1B}[?62;22csuffix"))
        #expect(isCapabilityResponse("\u{1B}]1337;Capabilities=T2NoH\u{07}"))
        #expect(isCapabilityResponse("\u{1B}p1+R4D73=ab\u{1B}\\"))
        #expect(!isCapabilityResponse("\u{1B}P>|unterminated"))
        #expect(!isCapabilityResponse("\u{1B}_Gunterminated"))
    }

    @Test("classifies explicit width reports")
    func explicitWidthClassification() {
        let cases: [(String, Bool)] = [
            ("\u{1B}[2;2R", true),
            ("\u{1B}[2;3R", true),
            ("\u{1B}[2;1R", false),
            ("\u{1B}[1;2R", false),
            ("\u{1B}[1;3R", false),
            ("\u{1B}[10;5R", false),
            ("noise\u{1B}[2;3Rtail", true),
        ]
        for (sequence, expected) in cases {
            #expect(isExplicitWidthReport(sequence) == expected)
        }
    }

    @Test("classifies and parses pixel resolution responses with Int32 bounds checking")
    func pixelResolutionDetectionAndParsing() {
        let detectionCases: [(String, Bool)] = [
            ("\u{1B}[4;720;1280t", true),
            ("\u{1B}[4;1080;1920t", true),
            ("\u{1B}[4;0;0t", true),
            ("a", false),
            ("\u{1B}[A", false),
            ("\u{1B}[?1016;2$y", false),
        ]
        for (sequence, expected) in detectionCases {
            #expect(isPixelResolutionResponse(sequence) == expected)
        }

        let parseCases: [(String, PixelResolution?)] = [
            ("\u{1B}[4;720;1280t", PixelResolution(width: 1280, height: 720)),
            ("\u{1B}[4;1080;1920t", PixelResolution(width: 1920, height: 1080)),
            ("\u{1B}[4;0;0t", PixelResolution(width: 0, height: 0)),
            ("a", nil),
            ("\u{1B}[A", nil),
            ("\u{1B}[?1016;2$y", nil),
            ("\u{1B}[4;4294967295;4294967295t", nil),
            ("\u{1B}[4;\(String(repeating: "9", count: 400));80t", nil),
            ("\u{1B}[4;2147483647;2147483647t", PixelResolution(width: 2_147_483_647, height: 2_147_483_647)),
            ("\u{1B}[4;2147483648;100t", nil),
            ("\u{1B}[4;0000000000000720;001280t", PixelResolution(width: 1280, height: 720)),
            ("prefix\u{1B}[4;600;800tsuffix", PixelResolution(width: 800, height: 600)),
        ]
        for (sequence, expected) in parseCases {
            #expect(parsePixelResolution(sequence) == expected)
        }
    }
}
