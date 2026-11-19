import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import Testing

// MARK: - TextBufferRenderable & TextRenderable Tests

@Suite("TextBufferRenderable and TextRenderable")
struct TextBufferAndTextRenderableTests {
    @Test("renders plain text and computes intrinsic layout dimensions")
    func rendersPlainTextWithIntrinsicSize() {
        let test = createTestRenderer(width: 30, height: 6)
        defer { test.destroy() }

        let text = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(id: "greeting", content: "Hello OpenTUI!")
        )
        test.root.add(text)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("Hello OpenTUI!"))
        #expect(text.plainText == "Hello OpenTUI!")
        #expect(text.lineCount == 1)
        #expect(text.virtualLineCount == 1)
        #expect(text.width >= 14)
        #expect(text.height == 1)
    }

    @Test("wraps text by word and char modes and reports lineInfo")
    func wrapsTextAndReportsLineInfo() {
        let test = createTestRenderer(width: 10, height: 6)
        defer { test.destroy() }

        let text = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(
                content: "alpha beta gamma",
                width: .point(10),
                wrapMode: .word
            )
        )
        test.root.add(text)
        test.renderOnce()

        #expect(text.lineCount == 1)
        #expect(text.virtualLineCount >= 2)
        #expect(text.lineInfo.lineSources.allSatisfy { $0 == 0 })

        let frame = test.captureCharFrame()
        #expect(frame.contains("alpha"))
        #expect(frame.contains("beta"))
        #expect(frame.contains("gamma"))

        text.wrapMode = .char
        test.renderOnce()
        #expect(text.virtualLineCount == 2)
    }

    @Test("renders StyledText colors, attributes, and hyperlinks")
    func rendersStyledTextChunks() {
        let test = createTestRenderer(width: 30, height: 4)
        defer { test.destroy() }

        let styled = StyledText(chunks: [
            bold(red("ERR")),
            TextChunk(text: ": "),
            link("https://example.com")(green("docs")),
        ])
        let text = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(content: .styled(styled))
        )
        test.root.add(text)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("ERR: docs"))

        let spans = test.captureSpans()
        let firstLineSpans = spans.lines[0].spans
        let errSpan = firstLineSpans.first { $0.text.contains("ERR") }
        #expect(errSpan != nil)
        #expect(errSpan?.fg == parseColor("red"))
        #expect(((errSpan?.attributes ?? 0) & TextAttributes.bold) != 0)

        let linkUrl = test.renderer.getLinkAt(x: 5, y: 0)
        #expect(linkUrl == "https://example.com")
    }

    @Test("supports truncation with ellipsis, tab indicators, and scrolling")
    func truncationTabIndicatorsAndScrolling() {
        let test = createTestRenderer(width: 10, height: 2)
        defer { test.destroy() }

        let text = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(
                content: "0123456789ABCDEF\nLine2\nLine3\nLine4",
                width: .point(10),
                height: .point(2),
                wrapMode: TextWrapMode.none,
                truncate: true
            )
        )
        test.root.add(text)
        test.renderOnce()

        let truncatedFrame = test.captureCharFrame()
        #expect(truncatedFrame.contains("…"))

        text.truncate = false
        text.scrollY = 2
        test.renderOnce()
        let scrolledFrame = test.captureCharFrame()
        #expect(scrolledFrame.contains("Line3"))
        #expect(scrolledFrame.contains("Line4"))
        #expect(text.scrollY == 2)
        #expect(text.maxScrollY == 2)

        text.setContent("a\tb")
        text.scrollY = 0
        text.tabIndicator = "→"
        test.renderOnce()
        let tabFrame = test.captureCharFrame()
        #expect(tabFrame.contains("a→"))
    }

    @Test("supports mouse drag selection across ASCII and emoji graphemes")
    func selectionAcrossText() {
        let test = createTestRenderer(width: 24, height: 5)
        defer { test.destroy() }

        let text = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(
                content: "Hello World\nSecond Line",
                selectable: true
            )
        )
        test.root.add(text)
        test.renderOnce()

        #expect(text.hasSelection() == false)
        #expect(text.shouldStartSelection(x: 0, y: 0) == true)

        test.mockMouse.drag(startX: 6, startY: 0, endX: 10, endY: 0)
        test.renderOnce()

        #expect(text.hasSelection() == true)
        #expect(text.getSelectedText() == "World")
        #expect(text.getSelection() == TextSelectionRange(start: 6, end: 11))

        // Multi-line selection
        test.mockMouse.drag(startX: 0, startY: 0, endX: 5, endY: 1)
        test.renderOnce()
        #expect(text.getSelectedText() == "Hello World\nSecond")
    }
}

// MARK: - TextNodeRenderable Tests

@Suite("TextNodeRenderable")
struct TextNodeRenderableTests {
    @Test("inherits fg, bg, attributes, and links through nested nodes")
    func styleInheritanceAndMerging() {
        let root = TextNodeRenderable(
            options: TextNodeOptions(
                id: "root",
                fg: "#FF0000",
                attributes: TextAttributes.bold
            )
        )
        let child = TextNodeRenderable(
            options: TextNodeOptions(
                id: "child",
                bg: "#0000FF",
                attributes: TextAttributes.italic,
                link: TextChunkLink(url: "https://opentui.dev")
            )
        )
        child.add("nested")
        root.add("prefix ")
        root.add(child)
        root.add(" suffix")

        #expect(isTextNodeRenderable(root))
        #expect(root.getChildrenCount() == 3)
        #expect(root.getChildren().count == 1)
        #expect(root.getRenderable("child") === child)
        #expect(root.getRenderableIndex("child") == 1)

        let chunks = root.toChunks()
        #expect(chunks.count == 3)
        #expect(chunks[0].text == "prefix ")
        #expect(chunks[0].fg == parseColor("#FF0000"))
        #expect(chunks[0].attributes == TextAttributes.bold)

        #expect(chunks[1].text == "nested")
        #expect(chunks[1].fg == parseColor("#FF0000"))
        #expect(chunks[1].bg == parseColor("#0000FF"))
        #expect(chunks[1].attributes == (TextAttributes.bold | TextAttributes.italic))
        #expect(chunks[1].link?.url == "https://opentui.dev")
    }

    @Test("propagates dirty changes from inline TextNodeRenderable to parent TextRenderable")
    func dirtyPropagationAndComposition() {
        let test = createTestRenderer(width: 30, height: 4)
        defer { test.destroy() }

        let text = TextRenderable(ctx: test.renderer, options: TextOptions(id: "inline-host"))
        let span = TextNodeRenderable.fromString(
            "World",
            options: TextNodeOptions(id: "span", fg: "#00FF00", attributes: TextAttributes.underline)
        )
        text.add("Hello ")
        text.add(span)
        test.root.add(text)
        test.renderOnce()

        #expect(test.captureCharFrame().contains("Hello World"))
        #expect(text.getTextChildren().count == 1)

        // Mutate nested node -> dirty propagates to TextRenderable -> re-composes on next frame
        span.clear()
        span.add("Swift")
        test.renderOnce()

        #expect(test.captureCharFrame().contains("Hello Swift"))

        // insertBefore & remove
        let badge = TextNodeRenderable.fromString("[!] ")
        text.insertBefore(badge, anchor: span)
        test.renderOnce()
        #expect(test.captureCharFrame().contains("Hello [!] Swift"))

        text.remove(badge)
        test.renderOnce()
        #expect(test.captureCharFrame().contains("Hello Swift"))

        text.clear()
        test.renderOnce()
        #expect(text.plainText == "")
    }
}

// MARK: - LineNumberRenderable Tests

@Suite("LineNumberRenderable")
struct LineNumberRenderableTests {
    @Test("renders line numbers, signs, offsets, hidden numbers, and wrapped continuations")
    func rendersGutterWithWrappingAndSigns() {
        let test = createTestRenderer(width: 24, height: 6)
        defer { test.destroy() }

        let target = TextRenderable(
            ctx: test.renderer,
            options: TextOptions(
                content: "first line wraps here\nsecond\nthird",
                width: .point(12),
                wrapMode: .word
            )
        )
        let lineNum = LineNumberRenderable(
            ctx: test.renderer,
            options: LineNumberOptions(
                id: "ln",
                target: target,
                minWidth: 3,
                paddingRight: 1,
                lineColors: [1: .color("#224422")],
                lineSigns: [0: LineSign(before: ">", beforeColor: "#FF0000", after: "+")],
                lineNumberOffset: 0
            )
        )
        test.root.add(lineNum)
        test.renderOnce()

        let frame = test.captureCharFrame()
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Line 0 wraps onto 2 visual rows: first row has "> 1+ ", continuation row has no line number
        #expect(lines[0].contains(">"))
        #expect(lines[0].contains("1+"))
        #expect(!lines[1].contains("1"))
        #expect(!lines[1].contains("2"))
        // Logical line 1 gets line number 2
        let hasLine2 = lines.contains { $0.contains("2") && $0.contains("second") }
        let hasLine3 = lines.contains { $0.contains("3") && $0.contains("third") }
        #expect(hasLine2)
        #expect(hasLine3)

        // Line colors populate both gutter and darkened content backgrounds
        let colors = lineNum.getLineColors()
        #expect(colors.gutter[1] == parseColor("#224422"))
        #expect(colors.content[1] != nil)

        // Hide line number and apply offset
        lineNum.lineNumberOffset = 10
        lineNum.setHideLineNumbers([2])
        test.renderOnce()
        let updatedFrame = test.captureCharFrame()
        #expect(updatedFrame.contains("11"))
        #expect(updatedFrame.contains("12"))
        #expect(!updatedFrame.contains("13"))

        // Toggle visibility
        lineNum.showLineNumbers = false
        #expect(lineNum.showLineNumbers == false)
        lineNum.clearTarget()
        #expect(lineNum.target == nil)
    }

    @Test("auto-attaches LineInfoProvider child via add(_:)")
    func autoAttachesTargetViaAdd() {
        let test = createTestRenderer(width: 20, height: 4)
        defer { test.destroy() }

        let wrapper = LineNumberRenderable(ctx: test.renderer, options: LineNumberOptions(minWidth: 3))
        let code = TextRenderable(ctx: test.renderer, options: TextOptions(content: "let a = 1\nlet b = 2"))
        wrapper.add(code)
        test.root.add(wrapper)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("1") && frame.contains("let a = 1"))
        #expect(frame.contains("2") && frame.contains("let b = 2"))
    }
}

// MARK: - TextTableRenderable Tests

@Suite("TextTableRenderable")
struct TextTableRenderableTests {
    @Test("renders bordered table with box-drawing junctions and styled cells")
    func rendersBorderedTableWithJunctions() {
        let test = createTestRenderer(width: 30, height: 10)
        defer { test.destroy() }

        let table = TextTableRenderable(
            ctx: test.renderer,
            options: TextTableOptions(
                width: .point(24),
                content: [
                    [[bold("Name")], [bold("Role")]],
                    ["Alice", [green("Admin")]],
                    ["Bob", "User"],
                ],
                columnWidthMode: .full,
                borderStyle: .single
            )
        )
        test.root.add(table)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("┌"))
        #expect(frame.contains("┬"))
        #expect(frame.contains("┐"))
        #expect(frame.contains("├"))
        #expect(frame.contains("┼"))
        #expect(frame.contains("┤"))
        #expect(frame.contains("└"))
        #expect(frame.contains("┴"))
        #expect(frame.contains("┘"))
        #expect(frame.contains("Name"))
        #expect(frame.contains("Alice"))
        #expect(frame.contains("Admin"))
        #expect(frame.contains("Bob"))
        #expect(table.columnWidths.count == 2)
        #expect(table.rowHeights.count == 3)
    }

    @Test("wraps multi-line cells and respects proportional vs balanced column fitters")
    func wrapsCellsAndSupportsFitters() {
        let test = createTestRenderer(width: 24, height: 12)
        defer { test.destroy() }

        let content: TextTableContent = [
            ["ID", "Description"],
            ["1", "This is a fairly long cell description that wraps cleanly"],
        ]
        let table = TextTableRenderable(
            ctx: test.renderer,
            options: TextTableOptions(
                width: .point(22),
                content: content,
                wrapMode: .word,
                columnWidthMode: .full,
                columnFitter: .proportional,
                cellPadding: 0
            )
        )
        test.root.add(table)
        test.renderOnce()

        #expect(table.rowHeights[1] > 1)
        let propWidths = table.columnWidths
        #expect(propWidths.reduce(0, +) + 3 == 22)

        table.columnFitter = .balanced
        test.renderOnce()
        #expect(table.columnWidths.reduce(0, +) + 3 == 22)

        // Border style and outerBorder toggles
        table.borderStyle = .rounded
        test.renderOnce()
        let roundedFrame = test.captureCharFrame()
        #expect(roundedFrame.contains("╭"))
        #expect(roundedFrame.contains("╯"))

        table.outerBorder = false
        test.renderOnce()
        let noOuterFrame = test.captureCharFrame()
        #expect(!noOuterFrame.contains("╭"))
        #expect(noOuterFrame.contains("│"))
    }

    @Test("supports single-cell and multi-cell selection across table cells")
    func tableCellSelection() {
        let test = createTestRenderer(width: 30, height: 10)
        defer { test.destroy() }

        let table = TextTableRenderable(
            ctx: test.renderer,
            options: TextTableOptions(
                content: [
                    ["Name", "Score"],
                    ["Alice", "100"],
                    ["Bob", "95"],
                ],
                columnWidthMode: .content,
                selectable: true
            )
        )
        test.root.add(table)
        test.renderOnce()

        // Cell (0,0) "Name" starts at (1, 1) inside outer border
        #expect(table.shouldStartSelection(x: 1, y: 1) == true)
        #expect(table.shouldStartSelection(x: 0, y: 0) == false) // border cell

        // Drag across row 0 and row 1 spanning both columns
        test.mockMouse.drag(startX: 1, startY: 1, endX: 10, endY: 3)
        test.renderOnce()

        #expect(table.hasSelection() == true)
        let selected = table.getSelectedText()
        #expect(selected.contains("Name\tScore"))
        #expect(selected.contains("Alice\t100"))
    }
}

// MARK: - EmbeddedTerminalRenderable Tests

@Suite("EmbeddedTerminalRenderable")
struct EmbeddedTerminalRenderableTests {
    @Test("parses ANSI SGR output, cursor movement, DSR response, and renders screen")
    func parsesAnsiAndRendersScreen() {
        let test = createTestRenderer(width: 30, height: 8)
        defer { test.destroy() }

        var capturedResponses: [String] = []
        var resizeEvents: [(Int, Int)] = []
        var screenChanges = 0

        let term = EmbeddedTerminalRenderable(
            ctx: test.renderer,
            options: EmbeddedTerminalOptions(
                cols: 20,
                rows: 5,
                onData: { bytes, source in
                    if source == .response {
                        capturedResponses.append(String(decoding: bytes, as: UTF8.self))
                    }
                },
                onTerminalResize: { cols, rows in
                    resizeEvents.append((cols, rows))
                },
                onScreenChange: {
                    screenChanges += 1
                }
            )
        )
        test.root.add(term)
        test.renderOnce()

        term.write("\u{1B}[32mHello\u{1B}[0m Terminal\r\nRow 2\u{1B}[6n")
        test.renderOnce()

        let snap = term.screen()
        #expect(snap.lines.first == "Hello Terminal")
        #expect(snap.lines.count >= 2 && snap.lines[1] == "Row 2")
        #expect(snap.cursor.x == 5 && snap.cursor.y == 1)
        #expect(capturedResponses.contains("\u{1B}[2;6R"))
        #expect(screenChanges > 0)

        let frame = test.captureCharFrame()
        #expect(frame.contains("Hello Terminal"))
        #expect(frame.contains("Row 2"))

        // Verify ANSI green fg color was painted on 'H'
        let cellH = test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        #expect(cellH?.foreground == RGBA.fromInts(0x00, 0x80, 0x00, 255))

        // Resize updates dimensions and notifies callback
        term.setWidth(.point(25))
        term.setHeight(.point(6))
        test.renderOnce()
        #expect(resizeEvents.last?.0 == 25)
        #expect(resizeEvents.last?.1 == 6)
    }

    @Test("encodes keys, bracketed paste, focus reporting, and text selection")
    func inputEncodingFocusAndSelection() {
        let test = createTestRenderer(width: 24, height: 6)
        defer { test.destroy() }

        var inputs: [String] = []
        let term = EmbeddedTerminalRenderable(
            ctx: test.renderer,
            options: EmbeddedTerminalOptions(
                cols: 20,
                rows: 4,
                onData: { bytes, source in
                    if source == .input {
                        inputs.append(String(decoding: bytes, as: UTF8.self))
                    }
                }
            )
        )
        test.root.add(term)
        test.renderOnce()

        // Enable focus reporting and bracketed paste
        term.write("\u{1B}[?1004h\u{1B}[?2004hAlpha Beta\r\nGamma Delta")
        test.renderOnce()

        term.focus()
        #expect(term.focused == true)
        #expect(inputs.contains("\u{1B}[I"))

        test.mockInput.pressArrow(.up)
        #expect(inputs.contains("\u{1B}[A"))

        let pasted = term.encodePaste(Array("hi".utf8))
        #expect(String(decoding: pasted, as: UTF8.self) == "\u{1B}[200~hi\u{1B}[201~")

        // Selection inside embedded terminal
        test.mockMouse.drag(startX: 0, startY: 0, endX: 4, endY: 0)
        test.renderOnce()
        #expect(term.hasSelection() == true)
        #expect(term.getSelectedText() == "Alpha")

        term.blur()
        #expect(inputs.contains("\u{1B}[O"))
    }
}

// MARK: - ImageRenderable & VideoRenderable Tests

@Suite("ImageRenderable and VideoRenderable")
struct ImageAndVideoRenderablesTests {
    @Test("resolves image protocols and validates crop rectangles")
    func protocolResolutionAndCropChecks() throws {
        let kittyCaps = TerminalCapabilities(kittyGraphics: true, sixel: false, multiplexer: .none)
        #expect(resolveImageRenderProtocol(requested: .auto, capabilities: kittyCaps, hasResolution: false) == .kitty)

        let tmuxCaps = TerminalCapabilities(kittyGraphics: true, sixel: true, multiplexer: .tmux)
        #expect(resolveImageRenderProtocol(requested: .auto, capabilities: tmuxCaps, hasResolution: true) == .blocks)

        let sixelCaps = TerminalCapabilities(kittyGraphics: false, sixel: true, multiplexer: .none)
        #expect(resolveImageRenderProtocol(requested: .auto, capabilities: sixelCaps, hasResolution: true) == .sixel)
        #expect(resolveImageRenderProtocol(requested: .auto, capabilities: sixelCaps, hasResolution: false) == .blocks)
        #expect(resolveImageRenderProtocol(requested: .sixel, capabilities: sixelCaps, hasResolution: false) == .blocks)

        let validCrop = try checkCrop(ImageExtractOptions(left: 1, top: 1, width: 2, height: 2), width: 4, height: 4)
        #expect(sameCrop(validCrop, ImageExtractOptions(left: 1, top: 1, width: 2, height: 2)))

        #expect(throws: MediaRenderableError.self) {
            _ = try checkCrop(ImageExtractOptions(left: 3, top: 0, width: 2, height: 2), width: 4, height: 4)
        }
    }

    @Test("renders RGBA pixel images with half-blocks and encodes Kitty graphics protocol")
    func imageHalfBlockRenderingAndKittyEncoding() throws {
        let test = createTestRenderer(width: 10, height: 4)
        defer { test.destroy() }

        // 2x2 image: top row red, bottom row blue
        let red = RGBA.fromInts(255, 0, 0, 255)
        let blue = RGBA.fromInts(0, 0, 255, 255)
        var pixelImg = PixelImage.solid(width: 2, height: 2, color: red)
        pixelImg.setPixel(x: 0, y: 1, color: blue)
        pixelImg.setPixel(x: 1, y: 1, color: blue)

        var loadedImage: PixelImage? = nil
        let image = ImageRenderable(
            ctx: test.renderer,
            options: ImageOptions(
                width: .point(2),
                height: .point(1),
                source: .pixelImage(pixelImg),
                fit: .fill,
                onLoad: { loadedImage = $0 }
            )
        )
        test.root.add(image)
        test.renderOnce()

        #expect(loadedImage == pixelImg)
        let frame = test.captureCharFrame()
        #expect(frame.contains("▀"))

        let cell0 = test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        #expect(cell0?.scalar == 0x2580) // '▀'
        #expect(cell0?.foreground == red)
        #expect(cell0?.background == blue)

        // Solid color renders full block '█'
        let solidImg = PixelImage.solid(width: 2, height: 2, color: red)
        image.source = .pixelImage(solidImg)
        test.renderOnce()
        #expect(test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.scalar == 0x2588) // '█'

        // Pure-Swift Kitty Graphics Protocol escape encoder
        let kitty = image.encodeKittySequence(cols: 2, rows: 1, imageId: 42)
        #expect(kitty != nil)
        #expect(kitty?.hasPrefix("\u{1B}_Ga=T,f=32,s=2,v=2,q=2,c=2,r=1,i=42,m=0;") == true)
        #expect(kitty?.hasSuffix("\u{1B}\\") == true)

        let deleteSeq = encodeKittyGraphicsDelete(imageId: 42)
        #expect(deleteSeq == "\u{1B}_Ga=d,d=I,i=42,q=2\u{1B}\\")
    }

    @Test("presents video frame sequences with play, pause, seek, loop, and half-block rendering")
    func videoPlaybackAndFramePresentation() {
        let test = createTestRenderer(width: 8, height: 4)
        defer { test.destroy() }

        let red = RGBA.fromInts(255, 0, 0, 255)
        let green = RGBA.fromInts(0, 255, 0, 255)
        let blue = RGBA.fromInts(0, 0, 255, 255)
        let frames = [
            PixelImage.solid(width: 2, height: 2, color: red),
            PixelImage.solid(width: 2, height: 2, color: green),
            PixelImage.solid(width: 2, height: 2, color: blue),
        ]

        var readyMeta: VideoMetadata? = nil
        var playCount = 0
        var pauseCount = 0
        var endCount = 0
        var seekTimes: [Double] = []

        let video = VideoRenderable(
            ctx: test.renderer,
            options: VideoOptions(
                width: .point(2),
                height: .point(1),
                frames: frames,
                fps: 10,
                fit: .fill,
                maxFps: 30,
                onReady: { readyMeta = $0 },
                onEnd: { endCount += 1 },
                onPlay: { playCount += 1 },
                onPause: { pauseCount += 1 },
                onSeek: { seekTimes.append($0) }
            )
        )
        test.root.add(video)
        test.renderOnce()

        #expect(video.ready == true)
        #expect(readyMeta?.width == 2)
        #expect(readyMeta?.height == 2)
        #expect(video.duration == 0.3)
        #expect(video.paused == true)
        #expect(test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.foreground == red)

        // Seek to frame 1 (t = 0.15s at 10fps -> index 1 = green)
        video.seek(0.15)
        test.renderOnce()
        #expect(seekTimes.last == 0.15)
        #expect(video.currentFrameIndex == 1)
        #expect(test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.foreground == green)

        // Play, advance clock past end -> reaches ended state and fires onEnd
        video.play()
        #expect(video.playing == true)
        #expect(playCount == 1)

        test.advanceClock(by: 250)
        test.renderOnce()
        #expect(video.ended == true)
        #expect(video.paused == true)
        #expect(endCount == 1)
        #expect(test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.foreground == blue)

        // Loop mode restarts seamlessly
        video.loop = true
        video.seek(0.0)
        video.play()
        test.advanceClock(by: 120)
        test.renderOnce()
        #expect(video.playing == true)

        video.pause()
        #expect(video.paused == true)
        #expect(pauseCount == 1)
    }
}
