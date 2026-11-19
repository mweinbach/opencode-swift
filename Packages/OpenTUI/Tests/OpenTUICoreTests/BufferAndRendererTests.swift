import Testing
import OpenTUICore

// MARK: - UnicodeWidth Tests

@Suite("UnicodeWidth")
struct UnicodeWidthTests {
    @Test("ASCII fast paths and printable prefix")
    func asciiFastPaths() {
        #expect(isAsciiOnly("hello world!"))
        #expect(!isAsciiOnly(""))
        #expect(!isAsciiOnly("hello\n"))
        #expect(!isAsciiOnly("hello\tworld"))
        #expect(!isAsciiOnly("héllo"))
        #expect(printableAsciiPrefixLen(Array("abc\tdef".utf8)) == 3)
        #expect(calculateTextWidth("Hello, OpenTUI!") == 15)
    }

    @Test("East Asian Wide, Fullwidth, Hangul, and combining marks")
    func wideAndCombiningCharacters() {
        #expect(eastAsianWidth(0x4E2D) == 2) // 中
        #expect(eastAsianWidth(0xFF21) == 2) // Ａ (fullwidth)
        #expect(eastAsianWidth(0xD55C) == 2) // 한 (Hangul)
        #expect(eastAsianWidth(0x0301) == 0) // combining acute accent
        #expect(calculateTextWidth("中文") == 4)
        #expect(calculateTextWidth("A中B") == 4)
        #expect(calculateTextWidth("e\u{0301}") == 1)
        #expect(calculateTextWidth("e\u{0301}", widthMethod: .wcwidth) == 1)
        #expect(isCombiningMark(Array("\u{0301}".utf8)))
        #expect(!isCombiningMark(Array("a".utf8)))
    }

    @Test("Emoji, ZWJ clusters, VS16, and regional indicator flags across WidthMethods")
    func emojiWidthMethods() {
        // Family ZWJ sequence: 4 emoji scalars joined by 3 ZWJs
        let family = "👨‍👩‍👧‍👦"
        #expect(calculateTextWidth(family, widthMethod: .unicode) == 2)
        #expect(calculateTextWidth(family, widthMethod: .wcwidth) == 8)
        #expect(calculateTextWidth(family, widthMethod: .noZWJ) == 8)

        // Heart + VS16 (U+2764 U+FE0F): text-default 1 cell widened to 2 by VS16 in unicode mode
        let redHeart = "\u{2764}\u{FE0F}"
        #expect(calculateTextWidth(redHeart, widthMethod: .unicode) == 2)
        #expect(calculateTextWidth(redHeart, widthMethod: .wcwidth) == 1)

        // Regional indicator flag pair: US flag
        let usFlag = "🇺🇸"
        #expect(calculateTextWidth(usFlag, widthMethod: .unicode) == 2)
        #expect(calculateTextWidth(usFlag, widthMethod: .wcwidth) == 2)
    }

    @Test("Tabs, line breaks, and control character display modes")
    func tabsLineBreaksAndControls() {
        #expect(calculateTextWidth("a\tb", tabWidth: 4) == 6)
        #expect(calculateTextWidth("a\tb", tabWidth: 2) == 4)
        #expect(findTabStops("a\tb\tc") == [1, 3])

        let breaks = findLineBreaks("a\nb\r\nc\rd")
        #expect(breaks == [
            LineBreak(pos: 1, kind: .lf),
            LineBreak(pos: 4, kind: .crlf),
            LineBreak(pos: 6, kind: .cr),
        ])

        #expect(isControl(0x01))
        #expect(isControl(0x7F))
        #expect(isControl(0x85))
        #expect(!isControl(0x20))
        #expect(containsControl(Array("ok\u{1B}bad".utf8)))
        #expect(containsControl([0xC2, 0x85])) // C1 U+0085
        #expect(!containsControl("clean UTF-8 中"))

        #expect(controlNotationWidth(0x01) == 2) // ^A
        #expect(controlNotationGlyph(0x01, index: 0) == UInt8(ascii: "^"))
        #expect(controlNotationGlyph(0x01, index: 1) == UInt8(ascii: "A"))
        #expect(controlNotationWidth(0x7F) == 2) // ^?
        #expect(controlNotationGlyph(0x7F, index: 1) == UInt8(ascii: "?"))
        #expect(controlNotationWidth(0x8A) == 4) // <8a>
        #expect(controlNotationGlyph(0x8A, index: 0) == UInt8(ascii: "<"))
        #expect(controlNotationGlyph(0x8A, index: 1) == UInt8(ascii: "8"))
        #expect(controlNotationGlyph(0x8A, index: 2) == UInt8(ascii: "a"))
        #expect(controlNotationGlyph(0x8A, index: 3) == UInt8(ascii: ">"))

        #expect(calculateTextWidth("\u{01}", controlDisplay: .hidden) == 0)
        #expect(calculateTextWidth("\u{01}", controlDisplay: .notation) == 2)
    }

    @Test("Wrap scanning, position snapping, previous grapheme, and TextWidthCursor")
    func wrapAndPositionScanning() {
        let bytes = Array("a中文b".utf8) // cols: a(0), 中(1..2), 文(3..4), b(5)
        let wrap3 = findWrapPosByWidth(bytes, maxColumns: 3)
        #expect(wrap3.columnsUsed == 3) // "a中"
        #expect(wrap3.byteOffset == 4)

        let wrap2 = findWrapPosByWidth(bytes, maxColumns: 2)
        #expect(wrap2.columnsUsed == 1) // "中" doesn't fit in 2nd col alone
        #expect(wrap2.byteOffset == 1)

        // Snap backward (selection start) vs forward (selection end) inside wide char at col 2
        let snapBack = findPosByWidth(bytes, maxColumns: 2, includeStartBefore: false)
        #expect(snapBack.byteOffset == 1)
        #expect(snapBack.columnsUsed == 1)

        let snapForward = findPosByWidth(bytes, maxColumns: 2, includeStartBefore: true)
        #expect(snapForward.byteOffset == 4)
        #expect(snapForward.columnsUsed == 3)

        let prev = getPrevGraphemeStart(bytes, byteOffset: 4)
        #expect(prev == PrevGraphemeResult(startOffset: 1, width: 2))

        var cursor = TextWidthCursor(text: "a中文b")
        #expect(cursor.advanceTo(1) == 1)
        #expect(cursor.advanceTo(2) == 3) // mid-character snaps past whole "中"
        #expect(cursor.byteOffset == 4)
        #expect(cursor.advanceTo(bytes.count) == 6)

        // Mixed ASCII/CJK layout wrap breaks
        let mixed = Array("hi中文!".utf8)
        let layout = findLineAndWordChunkLayoutInfo(mixed)
        #expect(layout.wordClasses.first == .asciiWord)
        #expect(layout.wordClasses.hasCjkBreaks)
        #expect(layout.wrapBreaks.contains(where: { $0.kind == .scriptTransition }))
        #expect(layout.cjkBreaks.contains(where: { $0.kind == .cjkIntercharacter }))
    }
}

// MARK: - GraphemePool Tests

@Suite("GraphemePool")
struct GraphemePoolTests {
    @Test("32-bit cell packing flags, extents, and widths")
    func packedCellBitLayout() {
        let gid: UInt32 = 0x0012_3456
        let start = packGraphemeStart(gid: gid, totalWidth: 2)
        #expect(isGraphemeChar(start))
        #expect(!isContinuationChar(start))
        #expect(isClusterChar(start))
        #expect(!isImageChar(start))
        #expect(graphemeIdFromChar(start) == gid)
        #expect(charRightExtent(start) == 1)
        #expect(charLeftExtent(start) == 0)
        #expect(encodedCharWidth(start) == 2)

        let cont = packContinuation(left: 1, gid: gid)
        #expect(!isGraphemeChar(cont))
        #expect(isContinuationChar(cont))
        #expect(isClusterChar(cont))
        #expect(graphemeIdFromChar(cont) == gid)
        #expect(charLeftExtent(cont) == 1)
        #expect(encodedCharWidth(cont) == 0)

        // Direct Unicode scalar
        #expect(!isClusterChar(0x41))
        #expect(encodedCharWidth(0x41) == 1)

        // Image cell
        let img = packImageCell(id: 42, fallback: 7)
        #expect(isImageChar(img))
        #expect(imageIdFromChar(img) == 42)
        #expect(imageFallbackFromChar(img) == 7)
    }

    @Test("Interning, refcounting, generation invalidation, and length bounds")
    func poolLifecycle() throws {
        let pool = GraphemePool()
        let emoji = "👨‍👩‍👧‍👦"

        let id1 = try pool.acquire(emoji)
        let id2 = try pool.acquire(emoji)
        #expect(id1 == id2)
        #expect(try pool.getRefcount(id1) == 2)
        #expect(try pool.getString(id1) == emoji)
        #expect(pool.liveCount == 1)

        try pool.decref(id1)
        #expect(try pool.getRefcount(id1) == 1)

        try pool.decref(id2)
        #expect(pool.liveCount == 0)

        // Re-acquiring recycles the slot with a bumped generation
        let id3 = try pool.acquire(emoji)
        #expect(id3 != id1)
        #expect((id3 & graphemeSlotMask) == (id1 & graphemeSlotMask))

        // Old ID must fail with wrongGeneration
        #expect(throws: GraphemePoolError.wrongGeneration) {
            _ = try pool.get(id1)
        }

        // Overlong grapheme (> 128 bytes) must fail
        let tooLong = Array(repeating: UInt8(ascii: "a"), count: graphemeBytesMax + 1)
        #expect(throws: GraphemePoolError.graphemeTooLong) {
            _ = try pool.acquire(tooLong)
        }
    }

    @Test("GraphemeTracker retains once per distinct ID and decrefs when last cell removed")
    func trackerRefcounting() throws {
        let pool = GraphemePool()
        let tracker = GraphemeTracker(pool: pool)

        let id = try pool.acquire("中")
        #expect(try pool.getRefcount(id) == 1)

        tracker.add(id)
        tracker.add(id)
        #expect(try pool.getRefcount(id) == 2) // pool refcount bumped only once
        #expect(tracker.graphemeCount == 1)
        #expect(tracker.graphemeCellCount == 2)
        #expect(tracker.totalGraphemeBytes == 6)

        tracker.remove(id)
        #expect(try pool.getRefcount(id) == 2)
        tracker.remove(id)
        #expect(try pool.getRefcount(id) == 1)
        #expect(!tracker.hasAny)
    }
}

// MARK: - LinkPool Tests

@Suite("LinkPool")
struct LinkPoolTests {
    @Test("24-bit link IDs round-trip through attributesWithLink and getLinkId")
    func linkPoolAndAttributes() throws {
        let pool = LinkPool()
        let url = "https://opencode.ai/docs"
        let id1 = try pool.acquire(url)
        #expect(id1 != 0)
        #expect(id1 <= TextAttributes.linkMask)

        let attrs = attributesWithLink(TextAttributes.bold | TextAttributes.underline, linkId: id1)
        #expect(getBaseAttributes(attrs) == (TextAttributes.bold | TextAttributes.underline))
        #expect(getLinkId(attrs) == id1)

        let id2 = try pool.acquire(url)
        #expect(id2 == id1)
        #expect(try pool.getRefcount(id1) == 2)
        #expect(try pool.get(id1) == url)

        try pool.decref(id1)
        try pool.decref(id2)
        #expect(pool.liveSlotCount == 0)

        let id3 = try pool.acquire(url)
        #expect(id3 != id1)
        #expect(throws: LinkPoolError.wrongGeneration) {
            _ = try pool.get(id1)
        }
    }

    @Test("URL validation rejects empty, oversized, and control characters")
    func urlValidation() {
        #expect(isWritableUrl("https://example.com/path?a=1&b=2"))
        #expect(!isWritableUrl(""))
        #expect(!isWritableUrl("https://example.com/\u{1B}]8;;"))
        #expect(!isWritableUrl("https://example.com/\u{07}"))
        #expect(!isWritableUrl("https://example.com/\nfoo"))
        #expect(!isWritableUrl(String(repeating: "a", count: linkMaxUrlLength + 1)))

        let pool = LinkPool()
        #expect(throws: LinkPoolError.invalidUrl) {
            _ = try pool.acquire("")
        }
        #expect(throws: LinkPoolError.invalidUrl) {
            _ = try pool.acquire("https://bad\u{1B}url")
        }
    }
}

// MARK: - SyntaxStyle Tests

@Suite("SyntaxStyle")
struct SyntaxStyleTests {
    @Test("Hierarchical dotted scope fallback, theme conversion, and cached merging")
    func hierarchicalFallbackAndMergeCache() {
        let theme: [ThemeTokenStyle] = [
            ThemeTokenStyle(
                scope: ["keyword"],
                style: .init(foreground: "#ff0000", bold: true)
            ),
            ThemeTokenStyle(
                scope: ["keyword.control"],
                style: .init(foreground: "#00ff00", italic: true)
            ),
            ThemeTokenStyle(
                scope: ["markup.emphasis"],
                style: .init(bold: false, underline: true)
            ),
        ]

        let flat = convertThemeToStyles(theme)
        #expect(flat["keyword"]?.fg == parseColor("#ff0000"))
        #expect(flat["keyword.control"]?.italic == true)

        let syntax = SyntaxStyle.fromTheme(theme)
        #expect(syntax.getStyleCount() == 3)

        // keyword.control.flow -> falls back to keyword.control (not just keyword!)
        let flowStyle = syntax.getStyle("keyword.control.flow")
        #expect(flowStyle?.fg == parseColor("#00ff00"))
        #expect(flowStyle?.italic == true)
        #expect(syntax.getStyleId("keyword.control.flow") == syntax.resolveStyleId("keyword.control"))

        // keyword.operator.assignment -> falls back through keyword.operator to keyword
        let opStyle = syntax.getStyle("keyword.operator.assignment")
        #expect(opStyle?.fg == parseColor("#ff0000"))
        #expect(opStyle?.bold == true)
        #expect(syntax.getStyleId("keyword.operator.assignment") == syntax.resolveStyleId("keyword"))

        // markup.strikethrough gets strikethrough: true automatically
        let strikeStyle = syntax.getStyle("markup.strikethrough")
        #expect(strikeStyle?.strikethrough == true)

        // mergeStyles caches results; later style overrides fg and explicitly clears bold: false
        let merged = syntax.mergeStyles("keyword", "markup.emphasis")
        #expect(merged.fg == parseColor("#ff0000"))
        #expect((merged.attributes & TextAttributes.bold) == 0)
        #expect((merged.attributes & TextAttributes.underline) != 0)
        #expect(syntax.getCacheSize() == 1)

        // Repeated call hits cache
        let merged2 = syntax.mergeStyles("keyword", "markup.emphasis")
        #expect(merged2 == merged)
        #expect(syntax.getCacheSize() == 1)

        // Updating a style preserves ID and invalidates merge cache
        let oldId = syntax.resolveStyleId("keyword")
        let updatedId = syntax.registerStyle("keyword", StyleDefinitionInput(fg: "#0000ff", bold: true))
        #expect(updatedId == oldId)
        #expect(syntax.getCacheSize() == 0)
    }

    @Test("SyntaxStyle conforms to LinkStyleResolving and integrates with detectLinks")
    func detectLinksIntegration() {
        let syntax = SyntaxStyle.fromStyles([
            "markup.link": StyleDefinitionInput(fg: "#3399ff", underline: true),
        ])

        let text = "Visit https://opencode.ai now"
        let chunks = [TextChunk(text: text)]
        let linked = detectLinks(chunks, context: DetectLinksContext(content: text, syntaxStyle: syntax))

        #expect(linked.count == 3)
        #expect(linked[1].text == "https://opencode.ai")
        #expect(linked[1].link?.url == "https://opencode.ai")
        #expect(linked[1].fg == parseColor("#3399ff"))
        #expect(((linked[1].attributes ?? 0) & TextAttributes.underline) != 0)
    }
}

// MARK: - OptimizedBuffer Tests

@Suite("OptimizedBuffer")
struct OptimizedBufferTests {
    @Test("Porter-Duff alpha blending of fg/bg, backdrop, and opacity stack")
    func alphaBlendingAndOpacity() {
        let buf = OptimizedBuffer(width: 6, height: 3)
        let red = RGBA.fromInts(200, 0, 0, 255)
        let blueHalf = RGBA.fromInts(0, 0, 200, 128)
        let white = RGBA.fromInts(255, 255, 255, 255)

        buf.clear(bg: red)
        buf.setCell(x: 1, y: 1, char: "X", fg: white, bg: red)

        // Blending a semi-transparent space over "X" preserves "X" and blends both fg and bg
        buf.setCellWithAlphaBlending(x: 1, y: 1, char: " ", fg: white, bg: blueHalf)
        let cell = buf.cell(atX: 1, y: 1)!
        #expect(cell.scalar == UInt32(UInt8(ascii: "X")))
        let (br, bg, bb, ba) = cell.background.toInts()
        #expect(br == 100 && bg == 0 && bb == 100 && ba == 255)

        // Nested opacity stack multiplies opacities
        buf.pushOpacity(0.5)
        #expect(buf.currentOpacity == 0.5)
        buf.pushOpacity(0.5)
        #expect(buf.currentOpacity == 0.25)
        buf.popOpacity()
        #expect(buf.currentOpacity == 0.5)
        buf.clearOpacity()
        #expect(buf.currentOpacity == 1.0)
    }

    @Test("Scissor clip rect stack clips nested draws and hit grid")
    func scissorStackAndHitGrid() {
        let buf = OptimizedBuffer(width: 10, height: 4)
        buf.clear(bg: RGBA.fromInts(0, 0, 0, 255))

        buf.pushScissorRect(x: 2, y: 1, width: 4, height: 2)
        buf.pushScissorRect(x: 3, y: 0, width: 5, height: 3)
        // Intersection is x: 3..<6, y: 1..<3
        #expect(buf.currentScissorRect == ClipRect(x: 3, y: 1, width: 3, height: 2))

        buf.drawText("0123456789", x: 0, y: 1, fg: RGBA.fromInts(255, 255, 255, 255))
        buf.fillHitRect(x: 0, y: 0, width: 10, height: 4, hitId: 99)

        #expect(buf.cell(atX: 2, y: 1)?.scalar == UInt32(UInt8(ascii: " ")))
        #expect(buf.cell(atX: 3, y: 1)?.scalar == UInt32(UInt8(ascii: "3")))
        #expect(buf.cell(atX: 5, y: 1)?.scalar == UInt32(UInt8(ascii: "5")))
        #expect(buf.cell(atX: 6, y: 1)?.scalar == UInt32(UInt8(ascii: " ")))

        #expect(buf.hitId(atX: 2, y: 1) == 0)
        #expect(buf.hitId(atX: 3, y: 1) == 99)
        #expect(buf.hitId(atX: 5, y: 2) == 99)
        #expect(buf.hitId(atX: 6, y: 1) == 0)

        buf.popScissorRect()
        #expect(buf.currentScissorRect == ClipRect(x: 2, y: 1, width: 4, height: 2))
        buf.popScissorRect()
        #expect(buf.currentScissorRect == nil)
    }

    @Test("Wide grapheme spans, continuation cleanup, styled text, and links")
    func graphemesStyledTextAndLinks() throws {
        let gPool = GraphemePool()
        let lPool = LinkPool()
        let buf = OptimizedBuffer(width: 12, height: 3, graphemePool: gPool, linkPool: lPool)
        buf.clear(bg: RGBA.fromInts(0, 0, 0, 255))

        buf.drawText("A中B", x: 0, y: 0, fg: RGBA.fromInts(255, 255, 255, 255))
        #expect(buf.getPlainText(trimTrailingSpaces: true).split(separator: "\n", omittingEmptySubsequences: false)[0] == "A中B")
        let startCell = buf.cell(atX: 1, y: 0)!
        let contCell = buf.cell(atX: 2, y: 0)!
        #expect(isGraphemeChar(startCell.scalar))
        #expect(isContinuationChar(contCell.scalar))
        #expect(gPool.liveCount == 1)

        // Overwriting the continuation cell clears the whole wide glyph and releases pool ref
        buf.setCell(x: 2, y: 0, char: "X", fg: RGBA.fromInts(255, 255, 255, 255), bg: RGBA.fromInts(0, 0, 0, 255))
        #expect(buf.cell(atX: 1, y: 0)?.scalar == defaultSpaceChar)
        #expect(buf.cell(atX: 2, y: 0)?.scalar == UInt32(UInt8(ascii: "X")))
        #expect(gPool.liveCount == 0)

        // drawStyledText with bold + OSC 8 link + newline
        let styled = StyledText(chunks: [
            bold(red("Hi ")),
            link("https://opencode.ai")(underline("Go")),
            TextChunk(text: "\nLine2"),
        ])
        buf.drawStyledText(styled, x: 0, y: 1)
        let lines = buf.getPlainText(trimTrailingSpaces: true).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[1] == "Hi Go")
        #expect(lines[2] == "Line2")

        let linkCell = buf.cell(atX: 3, y: 1)!
        let linkId = getLinkId(linkCell.attributes)
        #expect(linkId != 0)
        #expect(try lPool.get(linkId) == "https://opencode.ai")
        #expect((getBaseAttributes(linkCell.attributes) & TextAttributes.underline) != 0)
    }

    @Test("drawBox renders borders, fill, and aligned top/bottom titles")
    func drawBoxWithTitles() {
        let buf = OptimizedBuffer(width: 14, height: 5)
        buf.clear(bg: RGBA.fromInts(0, 0, 0, 255))

        buf.drawBox(
            x: 1,
            y: 0,
            width: 12,
            height: 4,
            borderStyle: .rounded,
            borderColor: RGBA.fromInts(255, 255, 255, 255),
            backgroundColor: RGBA.fromInts(20, 20, 40, 255),
            shouldFill: true,
            title: "Top",
            titleAlignment: .center,
            bottomTitle: "End",
            bottomTitleAlignment: .right
        )

        let rows = buf.getPlainText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(rows[0] == " ╭───Top────╮ ")
        #expect(rows[1] == " │          │ ")
        #expect(rows[2] == " │          │ ")
        #expect(rows[3] == " ╰──────End─╯ ")
    }

    @Test("drawFrameBuffer composites opaque and alpha-blended child buffers")
    func drawFrameBufferCompositing() {
        let gPool = GraphemePool()
        let lPool = LinkPool()
        let dest = OptimizedBuffer(width: 8, height: 3, graphemePool: gPool, linkPool: lPool)
        dest.clear(bg: RGBA.fromInts(100, 0, 0, 255))
        dest.drawText("ABCDEFGH", x: 0, y: 1, fg: RGBA.fromInts(255, 255, 255, 255))

        let child = OptimizedBuffer(width: 4, height: 1, respectAlpha: true, graphemePool: gPool, linkPool: lPool)
        child.clear(bg: RGBA.fromInts(0, 0, 0, 0))
        child.drawText("Z中", x: 0, y: 0, fg: RGBA.fromInts(255, 255, 0, 255), bg: RGBA.fromInts(0, 0, 100, 128))
        child.fillHitRect(x: 0, y: 0, width: 4, height: 1, hitId: 7)

        dest.drawFrameBuffer(destX: 2, destY: 1, frameBuffer: child)
        let row1 = dest.getPlainText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[1]
        #expect(row1 == "ABZ中FGH")
        #expect(dest.hitId(atX: 2, y: 1) == 7)
        // Background at (2,1) was blended between (0,0,100,128) and (100,0,0,255)
        let (r, _, b, _) = dest.cell(atX: 2, y: 1)!.background.toInts()
        #expect(r == 50 && b == 50)
    }
}

// MARK: - AnsiDiffRenderer Tests

@Suite("AnsiDiffRenderer")
struct AnsiDiffRendererTests {
    @Test("Synchronized output, no-op frame suppression, and minimal incremental diffs")
    func diffRenderingAndNoOpSuppression() {
        let renderer = AnsiDiffRenderer(width: 10, height: 2)
        let white = RGBA.fromInts(255, 255, 255, 255)
        let black = RGBA.fromInts(0, 0, 0, 255)

        // Frame 1: initial draw
        renderer.nextBuffer.clear(bg: black)
        renderer.nextBuffer.drawText("Hello", x: 0, y: 0, fg: white, bg: black)
        let frame1 = renderer.render(clearNextAfterRender: false)

        #expect(frame1.hasPrefix("\u{1B}[?2026h\u{1B}[?25l"))
        #expect(frame1.hasSuffix("\u{1B}[0m\u{1B}[?2026l"))
        #expect(frame1.contains("Hello"))
        #expect(renderer.stats.cellsUpdated == 20)

        // Frame 2: identical buffer -> true no-op (empty output!)
        let frame2 = renderer.render(clearNextAfterRender: false)
        #expect(frame2.isEmpty)
        #expect(renderer.stats.cellsUpdated == 0)

        // Frame 3: change a single cell at (4, 0) from 'o' to '!'
        renderer.nextBuffer.setCell(x: 4, y: 0, char: "!", fg: white, bg: black)
        let frame3 = renderer.render(clearNextAfterRender: false)
        #expect(renderer.stats.cellsUpdated == 1)
        #expect(renderer.stats.rowsDiffed == 1)
        #expect(frame3.contains("\u{1B}[1;5H")) // 1-based row 1, col 5
        #expect(frame3.contains("!"))
        #expect(!frame3.contains("Hell"))
    }

    @Test("ColorIntent emits truecolor, indexed 256, and default 39/49 sequences")
    func colorIntentsAndFallback() throws {
        let renderer = AnsiDiffRenderer(width: 6, height: 1)
        let rgbColor = RGBA.fromInts(12, 34, 56, 255)
        let indexedColor = try RGBA.fromIndex(196)
        let defFg = RGBA.defaultForeground()
        let defBg = RGBA.defaultBackground()

        renderer.nextBuffer.setCell(x: 0, y: 0, char: "R", fg: rgbColor, bg: defBg)
        renderer.nextBuffer.setCell(x: 1, y: 0, char: "I", fg: indexedColor, bg: defBg)
        renderer.nextBuffer.setCell(x: 2, y: 0, char: "D", fg: defFg, bg: defBg)

        let out = renderer.render()
        #expect(out.contains("\u{1B}[38;2;12;34;56m"))
        #expect(out.contains("\u{1B}[38;5;196m"))
        #expect(out.contains("\u{1B}[39m"))
        #expect(out.contains("\u{1B}[49m"))

        // When capabilities.rgb == false, truecolor falls back to nearest 256-color palette slot
        let indexedOnly = AnsiDiffRenderer(
            width: 2,
            height: 1,
            capabilities: RendererCapabilities(rgb: false, ansi256: true)
        )
        indexedOnly.nextBuffer.setCell(x: 0, y: 0, char: "F", fg: RGBA.fromInts(255, 0, 0, 255), bg: defBg)
        let fallbackOut = indexedOnly.render()
        #expect(!fallbackOut.contains("38;2;"))
        #expect(fallbackOut.contains("\u{1B}[38;5;"))
    }

    @Test("SGR attributes, OSC 8 hyperlinks, wide graphemes, and cursor state")
    func sgrHyperlinksGraphemesAndCursor() {
        let renderer = AnsiDiffRenderer(width: 12, height: 1)
        let styled = StyledText(chunks: [
            bold("B"),
            link("https://opencode.ai")(underline("中")),
            TextChunk(text: "X"),
        ])
        renderer.nextBuffer.drawStyledText(styled, x: 0, y: 0)
        renderer.cursorState = CursorRenderState(x: 5, y: 1, visible: true, style: .line, blinking: true)

        let out = renderer.render()
        #expect(out.contains("\u{1B}[1m")) // bold
        #expect(out.contains("\u{1B}[4m")) // underline
        #expect(out.contains("\u{1B}]8;id="))
        #expect(out.contains(";https://opencode.ai\u{1B}\\"))
        #expect(out.contains("\u{1B}]8;;\u{1B}\\")) // link closed before "X"
        #expect(out.contains("中"))
        #expect(out.contains("\u{1B}[5 q")) // blinking line cursor
        #expect(out.contains("\u{1B}[1;5H\u{1B}[?25h")) // cursor restored and shown
    }
}
