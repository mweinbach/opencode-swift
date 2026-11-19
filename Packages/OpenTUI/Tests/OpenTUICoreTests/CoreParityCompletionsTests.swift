import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Testing

// MARK: - Helper for Packed Buffer Encoding

private func appendLEFloat32(_ value: Float, to bytes: inout [UInt8]) {
    let bits = value.bitPattern
    bytes.append(UInt8(bits & 0xFF))
    bytes.append(UInt8((bits >> 8) & 0xFF))
    bytes.append(UInt8((bits >> 16) & 0xFF))
    bytes.append(UInt8((bits >> 24) & 0xFF))
}

private func appendLEUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
    bytes.append(UInt8((value >> 16) & 0xFF))
    bytes.append(UInt8((value >> 24) & 0xFF))
}

private func makePackedCellRecord(
    bg: (Float, Float, Float, Float),
    fg: (Float, Float, Float, Float),
    char: UInt32
) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(48)
    appendLEFloat32(bg.0, to: &out)
    appendLEFloat32(bg.1, to: &out)
    appendLEFloat32(bg.2, to: &out)
    appendLEFloat32(bg.3, to: &out)
    appendLEFloat32(fg.0, to: &out)
    appendLEFloat32(fg.1, to: &out)
    appendLEFloat32(fg.2, to: &out)
    appendLEFloat32(fg.3, to: &out)
    appendLEUInt32(char, to: &out)
    appendLEUInt32(0, to: &out)
    appendLEUInt32(0, to: &out)
    appendLEUInt32(0, to: &out)
    return out
}

// MARK: - Suite 1: Core Buffer, RGBA, Border, TextBuffer & EditBuffer Completions

@Suite("CoreParityCompletions — Core Types, Buffer, RGBA, Border & Text/Edit")
struct CoreParityCompletionsCoreTests {
    @Test("ATTRIBUTE_BASE constants, DebugOverlayCorner, WidthMethod, Timeout, ViewportBounds")
    func coreTypesAndConstants() {
        #expect(ATTRIBUTE_BASE_BITS == 8)
        #expect(ATTRIBUTE_BASE_MASK == 0xFF)
        #expect(DebugOverlayCorner.allCorners.count == 4)
        #expect(WidthMethod.unicode.textWidthMethod == .unicode)
        #expect(WidthMethod.wcwidth.textWidthMethod == .wcwidth)
        #expect(WidthMethod.unicodeWide.textWidthMethod == .unicodeWide)

        let timeout: Timeout = TimerHandle(rawValue: 42)
        #expect(timeout?.rawValue == 42)

        let vp = ViewportBounds(x: 2, y: 3, width: 10, height: 5)
        #expect(!vp.isEmpty)
        #expect(vp.contains(x: 2, y: 3))
        #expect(!vp.contains(x: 12, y: 3))
        #expect(vp.intersects(ViewportBounds(x: 10, y: 7, width: 4, height: 4)))
        #expect(!vp.intersects(ViewportBounds(x: 12, y: 3, width: 4, height: 4)))
    }

    @Test("RGBA.map, ColorInput, NormalizedColorValue, and normalizeColorValue")
    func rgbaCompletions() {
        let color = RGBA.fromInts(255, 0, 128, 255)
        let mapped = color.map { Int(($0 * 100.0).rounded()) }
        #expect(mapped.0 == 100)
        #expect(mapped.1 == 0)
        #expect(mapped.2 == 50)
        #expect(mapped.3 == 100)

        let input: ColorInput = "#336699"
        let normalized = normalizeColorValue(input)
        #expect(normalized == NormalizedColorValue(rgba: RGBA.fromHex("#336699")))
        #expect(normalizeColorValue(nil as ColorInput?) == nil)
        #expect(normalizeColorValue("red")?.rgba == RGBA.fromHex("#FF0000"))
        #expect(normalizeColorValue(color)?.rgba == color)
    }

    @Test("BorderConfig and BoxDrawOptions BorderSpec/ColorInput convenience init")
    func borderCompletions() {
        let config = BorderConfig(
            borderStyle: .rounded,
            border: .sides([.top, .bottom]),
            borderColor: "#00ff00"
        )
        #expect(config.borderStyle == .rounded)
        #expect(config.border == .sides([.top, .bottom]))

        let buf = OptimizedBuffer(width: 10, height: 5)
        let opts = BoxDrawOptions(
            x: 0,
            y: 0,
            width: 8,
            height: 4,
            borderStyle: .rounded,
            border: .enabled(true),
            borderColor: "#ffffff",
            backgroundColor: "#000000",
            shouldFill: true,
            title: "Box"
        )
        buf.drawBox(opts)
        #expect(buf.getCell(x: 0, y: 0)?.scalar == UInt32("╭".unicodeScalars.first!.value))
        #expect(buf.getFgColor(x: 0, y: 0) == RGBA.fromHex("#ffffff"))
        #expect(buf.getBgColor(x: 1, y: 1) == RGBA.fromHex("#000000"))
    }

    @Test("ResourceContext, NativeResourceOwner, NativeInputSession lifecycle")
    func resourceContextAndInputSession() throws {
        let ctx = ResourceContext(objectCapacity: 128, renderCellsMax: 4096)
        #expect(!ctx.disposed)
        #expect(ctx.resourceContext === ctx)
        try ctx.assertAlive()

        let inputSession = NativeInputSession(resourceContext: ctx, sessionId: 7)
        #expect(inputSession.sessionId == 7)
        #expect(inputSession.resourceContext === ctx)

        ctx.destroy()
        #expect(ctx.disposed)
        #expect(throws: ResourceContextError.disposed) {
            try ctx.assertAlive()
        }
    }

    @Test("OptimizedBuffer buffers, withBuffers, fromRecorder, and fromSession")
    func bufferPlanesAndFactories() throws {
        let recorder = OptimizedBuffer.fromRecorder(width: 4, height: 2)
        recorder.drawText("Hi", x: 0, y: 0, fg: RGBA.fromInts(10, 20, 30, 255), bg: RGBA.fromInts(40, 50, 60, 255))

        let rawPlanes = recorder.buffers
        #expect(rawPlanes.width == 4)
        #expect(rawPlanes.height == 2)
        #expect(rawPlanes.char[0] == UInt32(UInt8(ascii: "H")))
        #expect(rawPlanes.char[1] == UInt32(UInt8(ascii: "i")))
        #expect(rawPlanes.fg.count == 4 * 2 * 4)
        #expect(rawPlanes.bg.count == 4 * 2 * 4)

        let firstChar: UInt32 = try recorder.withBuffers { access in
            access.char[0]
        }
        #expect(firstChar == UInt32(UInt8(ascii: "H")))

        let session = SessionBuffer(width: 6, height: 3)
        let currentBuf = OptimizedBuffer.fromSession(session, which: .current)
        let nextBuf = OptimizedBuffer.fromSession(session, which: .next)
        #expect(currentBuf === session.current)
        #expect(nextBuf === session.next)

        recorder.destroy()
        #expect(throws: BufferAccessError.bufferDestroyed) {
            _ = try recorder.withBuffers { $0.width }
        }
    }

    @Test("OptimizedBuffer drawTextBuffer (with SyntaxStyle highlights) and drawEditorView")
    func drawTextBufferAndEditorView() {
        let style = SyntaxStyle.create()
        let kwId = style.registerStyle("keyword", StyleDefinitionInput(fg: Color.string("#ff0000"), bold: true))

        let tb = TextBuffer.create()
        tb.setText("let x = 1")
        tb.setSyntaxStyle(style)
        #expect(tb.getSyntaxStyle() === style)
        tb.addHighlight(lineIdx: 0, highlight: Highlight(start: 0, end: 3, styleId: kwId))

        let tbView = TextBufferView.create(tb)
        tbView.setViewport(x: 0, y: 0, width: 12, height: 2)

        let canvas = OptimizedBuffer(width: 12, height: 4)
        canvas.drawTextBuffer(tbView, x: 1, y: 1)

        #expect(canvas.getCell(x: 1, y: 1)?.scalar == UInt32(UInt8(ascii: "l")))
        #expect(canvas.getFgColor(x: 1, y: 1) == RGBA.fromHex("#ff0000"))
        #expect((canvas.getCell(x: 1, y: 1)?.attributes ?? 0) & TextAttributes.bold != 0)
        #expect(canvas.getCell(x: 5, y: 1)?.scalar == UInt32(UInt8(ascii: "x")))

        // EditorView placeholder and text rendering
        let eb = EditBuffer.create()
        eb.setSyntaxStyle(style)
        #expect(eb.getSyntaxStyle() === style)
        let editorView = EditorView.create(editBuffer: eb, viewportWidth: 12, viewportHeight: 2)
        editorView.setPlaceholderStyledText([TextChunk(text: "Type...", fg: RGBA.fromInts(100, 100, 100, 255))])

        let editorCanvas = OptimizedBuffer(width: 12, height: 2)
        editorCanvas.drawEditorView(editorView, x: 0, y: 0)
        #expect(editorCanvas.getPlainText(trimTrailingSpaces: true).hasPrefix("Type..."))

        eb.setText("Hello")
        editorCanvas.clear()
        editorCanvas.drawEditorView(editorView, x: 0, y: 0)
        #expect(editorCanvas.getPlainText(trimTrailingSpaces: true).hasPrefix("Hello"))
    }

    @Test("OptimizedBuffer drawSuperSampleBuffer, drawPackedBuffer, drawGrayscaleBuffer, drawImage")
    func pixelAndImageDrawing() throws {
        // 1. drawSuperSampleBuffer (2x2 pixels -> 1 cell upper-half block)
        let ssBuf = OptimizedBuffer(width: 4, height: 2)
        // Row 0: two dark pixels (0,0,0,255); Row 1: two white pixels (255,255,255,255)
        let rgbaPixels: [UInt8] = [
            0, 0, 0, 255,       0, 0, 0, 255,
            255, 255, 255, 255, 255, 255, 255, 255,
        ]
        ssBuf.drawSuperSampleBuffer(x: 0, y: 0, pixelData: rgbaPixels, format: .rgba8unorm, alignedBytesPerRow: 8)
        let ssCell = try #require(ssBuf.getCell(x: 0, y: 0))
        #expect(ssCell.scalar == 0x2580) // Upper half block ▀
        #expect(ssCell.foreground == RGBA.fromInts(0, 0, 0, 255))
        #expect(ssCell.background == RGBA.fromInts(255, 255, 255, 255))

        // 2. drawPackedBuffer (48-byte CellResult)
        let packedBuf = OptimizedBuffer(width: 4, height: 2)
        let recA = makePackedCellRecord(bg: (0, 0, 1, 1), fg: (1, 1, 0, 1), char: UInt32(UInt8(ascii: "A")))
        let recB = makePackedCellRecord(bg: (0, 1, 0, 1), fg: (1, 0, 0, 1), char: UInt32(UInt8(ascii: "B")))
        packedBuf.drawPackedBuffer(recA + recB, posX: 1, posY: 0, terminalWidthCells: 2, terminalHeightCells: 1)
        #expect(packedBuf.getCell(x: 1, y: 0)?.scalar == UInt32(UInt8(ascii: "A")))
        #expect(packedBuf.getCell(x: 2, y: 0)?.scalar == UInt32(UInt8(ascii: "B")))
        #expect(packedBuf.getBgColor(x: 1, y: 0) == RGBA.fromInts(0, 0, 255, 255))

        // 3. drawGrayscaleBuffer & drawGrayscaleBufferSupersampled
        let grayBuf = OptimizedBuffer(width: 4, height: 2)
        grayBuf.drawGrayscaleBuffer(
            posX: 0,
            posY: 0,
            intensities: [0.0, 1.0],
            srcWidth: 2,
            srcHeight: 1,
            fg: RGBA.fromInts(255, 255, 255, 255),
            bg: RGBA.fromInts(0, 0, 0, 255)
        )
        #expect(grayBuf.getCell(x: 0, y: 0)?.scalar == defaultSpaceChar)
        #expect(grayBuf.getCell(x: 1, y: 0)?.scalar == UInt32(UInt8(ascii: "$")))

        let graySSBuf = OptimizedBuffer(width: 4, height: 2)
        graySSBuf.drawGrayscaleBufferSupersampled(
            posX: 0,
            posY: 0,
            intensities: [1.0, 1.0, 1.0, 1.0],
            srcWidth: 2,
            srcHeight: 2
        )
        #expect(graySSBuf.getCell(x: 0, y: 0)?.scalar == UInt32(UInt8(ascii: "$")))

        // 4. drawImage
        let img = try NativeImage.fromPixels(
            [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255],
            width: 2,
            height: 2
        )
        defer { img.dispose() }
        let imgBuf = OptimizedBuffer(width: 4, height: 2)
        let drawn = imgBuf.drawImage(img, x: 0, y: 0, width: 2, height: 1)
        #expect(drawn)
        #expect(imgBuf.getCell(x: 0, y: 0)?.scalar != defaultSpaceChar)
    }

    @Test("OptimizedBuffer encodeUnicode, drawChar(UInt64), freeUnicode, and drawGrid")
    func encodeUnicodeAndDrawGrid() {
        let buf = OptimizedBuffer(width: 10, height: 5)
        let encoded = buf.encodeUnicode("A😀")
        #expect(encoded.data.count == 2)
        #expect(encoded.data[0].width == 1)
        #expect(encoded.data[0].char == UInt64(UInt32(UInt8(ascii: "A"))))
        #expect(encoded.data[1].width == 2)
        #expect(encoded.data[1].char > UInt64(UInt32.max))

        buf.drawChar(encoded.data[0].char, x: 0, y: 0, fg: .defaultForeground(), bg: RGBA.fromInts(0, 0, 0, 255))
        buf.drawChar(encoded.data[1].char, x: 1, y: 0, fg: .defaultForeground(), bg: RGBA.fromInts(0, 0, 0, 255))
        #expect(buf.getPlainText(trimTrailingSpaces: true).hasPrefix("A😀"))
        buf.freeUnicode(encoded)

        // drawGrid: 2x2 grid (columns at 0, 3, 6; rows at 0, 2, 4)
        let gridBuf = OptimizedBuffer(width: 8, height: 5)
        gridBuf.drawGrid(
            NativeBufferGrid(
                borderChars: BorderCharArrays.single,
                borderFg: RGBA.fromInts(255, 255, 255, 255),
                borderBg: RGBA.fromInts(0, 0, 0, 255),
                columnOffsets: [0, 3, 6],
                rowOffsets: [0, 2, 4],
                drawInner: true,
                drawOuter: true
            )
        )
        let lines = gridBuf.getPlainText(trimTrailingSpaces: true).split(separator: "\n").map(String.init)
        #expect(lines[0] == "┌──┬──┐")
        #expect(lines[1] == "│  │  │")
        #expect(lines[2] == "├──┼──┤")
        #expect(lines[3] == "│  │  │")
        #expect(lines[4] == "└──┴──┘")
    }

    @Test("TextBuffer.loadFile with injectable RuntimeFileReader")
    func textBufferLoadFile() throws {
        let tb = TextBuffer.create()
        try tb.loadFile("/virtual/hello.txt") { path in
            #expect(path == "/virtual/hello.txt")
            return Array("hello\r\nworld".utf8)
        }
        #expect(tb.getPlainText() == "hello\nworld")

        #expect(throws: TextBufferLoadError.self) {
            try tb.loadFile("/missing.txt")
        }
    }
}

// MARK: - Suite 2: Renderable, CliRenderer & QRCodeRegistration Completions

@Suite("CoreParityCompletions — Renderable, CliRenderer & QRCodeRegistration")
struct CoreParityCompletionsRendererTests {
    @Test("Renderable Yoga getters, mutation guards, refreshHooks, listeners, and visualizeRenderableTree")
    func renderableCompletions() throws {
        let renderer = CliRenderer(config: CliRendererConfig(width: 40, height: 12))
        defer { renderer.destroy() }

        let parentBox = BoxRenderable(
            ctx: renderer,
            options: BoxOptions(
                id: "parent",
                width: .point(20),
                height: .point(10),
                minWidth: .point(5),
                maxWidth: .point(30),
                minHeight: .point(3),
                maxHeight: .point(12),
                flexGrow: 2,
                flexShrink: 0.5,
                flexBasis: .point(8),
                flexDirection: .row,
                flexWrap: .wrap,
                alignItems: .center,
                alignSelf: .flexEnd,
                alignContent: .spaceBetween,
                justifyContent: .spaceAround,
                position: .absolute,
                marginTop: .point(1),
                paddingLeft: .point(2),
                rowGap: .point(3),
                aspectRatio: 1.5
            )
        )
        let childA = BoxRenderable(ctx: renderer, options: BoxOptions(id: "child-a"))
        let childB = BoxRenderable(ctx: renderer, options: BoxOptions(id: "child-b"))
        parentBox.add(childA)
        parentBox.add(childB)
        renderer.root.add(parentBox)

        #expect(parentBox.getRenderContext() === renderer)
        #expect(!parentBox.isFreed())
        try parentBox.assertMutable()
        #expect(parentBox.runMutation { 42 } == 42)

        #expect(parentBox.getFlexDirection() == .row)
        #expect(parentBox.getMargin(.top) == .point(1))
        #expect(parentBox.getWidth() == .point(20))
        #expect(parentBox.getHeight() == .point(10))
        #expect(parentBox.getFlexWrap() == .wrap)
        #expect(parentBox.getAlignItems() == .center)
        #expect(parentBox.getAlignContent() == .spaceBetween)
        #expect(parentBox.getAspectRatio() == 1.5)
        #expect(parentBox.getJustifyContent() == .spaceAround)
        #expect(parentBox.getAlignSelf() == .flexEnd)
        #expect(parentBox.getPositionType() == .absolute)
        #expect(parentBox.getFlexGrow() == 2)
        #expect(parentBox.getFlexShrink() == 0.5)
        #expect(parentBox.getFlexBasis() == .point(8))
        #expect(parentBox.getMinWidth() == .point(5))
        #expect(parentBox.getMinHeight() == .point(3))
        #expect(parentBox.getMaxWidth() == .point(30))
        #expect(parentBox.getMaxHeight() == .point(12))
        #expect(parentBox.getPadding(.left) == .point(2))
        #expect(parentBox.getGap(.row) == .point(3))

        // NativeRenderableIntegration metadata
        let integration = NativeRenderableIntegration(kind: "box", body: .host, beforeAfter: true)
        #expect(integration.kind == "box")
        #expect(integration.beforeAfter)

        // refreshHooks registers lifecycle pass
        var passCount = 0
        parentBox.onLifecyclePass = { passCount += 1 }
        parentBox.refreshHooks()
        #expect(renderer.getLifecyclePasses().contains(where: { $0 === parentBox }))
        parentBox.runLifecyclePass()
        #expect(passCount == 1)

        // Scene event listeners (prepend ordering, off, removeAllListeners)
        var order: [String] = []
        let t1 = parentBox.addListener(.focused) { order.append("second") }
        let t2 = parentBox.prependListener(.focused) { order.append("first") }
        let t3 = parentBox.on(sceneEvent: "custom") { order.append("custom") }
        parentBox.emit(.focused)
        parentBox.emit("custom")
        #expect(order == ["first", "second", "custom"])

        parentBox.off(listener: t1)
        parentBox.removeListener(token: t3)
        order.removeAll()
        parentBox.emit(.focused)
        parentBox.emit("custom")
        #expect(order == ["first"])

        parentBox.removeAllListeners(.focused)
        _ = t2
        order.removeAll()
        parentBox.emit(.focused)
        #expect(order.isEmpty)

        // visualizeRenderableTree
        var logged = ""
        let tree = visualizeRenderableTree(parentBox, maxDepth: 5) { logged = $0 }
        #expect(tree == logged)
        #expect(tree.contains("Renderable Tree:"))
        #expect(tree.contains("parent"))
        #expect(tree.contains("├── child-a"))
        #expect(tree.contains("└── child-b"))

        let truncated = visualizeRenderableTree(parentBox, maxDepth: 1)
        #expect(truncated.contains("(max depth reached)"))

        // Destroyed renderable guards
        childA.destroy()
        #expect(childA.isFreed())
        #expect(childA.runMutation { 99 } == nil)
        #expect(throws: RenderableMutationError.destroyed(id: "child-a")) {
            try childA.assertMutable()
        }
    }

    @Test("CliRenderer async setup, console, debug overlay, OSC controls, stats, frame callbacks & scrollback")
    func cliRendererCompletions() async throws {
        var emitted: [String] = []
        let clock = ManualClock()
        let renderer = await createCliRenderer(
            config: CliRendererConfig(
                width: 30,
                height: 10,
                screenMode: .splitFooter,
                footerHeight: 4,
                clock: clock,
                outputWriter: { emitted.append($0) }
            )
        )

        #expect(renderer.currentControlState == "idle")
        #expect(renderer.externalOutputMode == .captureStdout)
        #expect(renderer.paletteDetectionStatus == .idle)
        renderer.setPaletteDetectionStatus(.cached)
        #expect(renderer.paletteDetectionStatus == .cached)

        // Focused editor tracking
        let textarea = TextareaRenderable(ctx: renderer, options: TextareaOptions(id: "editor"))
        renderer.root.add(textarea)
        textarea.focus()
        #expect(renderer.currentFocusedEditor === textarea)

        // Console mode & console overlay
        renderer.consoleMode = .consoleOverlay
        #expect(renderer.consoleMode == .consoleOverlay)
        #expect(renderer.console.isActive)
        renderer.consoleMode = .disabled
        #expect(!renderer.console.isActive)

        // Kitty image transport lifecycle
        #expect(renderer.kittyImageTransport == .raw)
        renderer.kittyImageTransport = .file
        #expect(renderer.kittyImageTransportStatus.requested == .file)
        #expect(renderer.kittyImageTransportStatus.fileState == .probing)
        renderer.cancelKittyImageTransport()
        #expect(renderer.kittyImageTransportStatus.fileState == .cancelled)

        // Notifications, ProgramStatus, Title, Reset BG, OSC 52 Clipboard
        #expect(renderer.triggerNotification("Build complete", title: "OpenTUI"))
        #expect(emitted.last == "\u{1B}]777;notify;OpenTUI;Build complete\u{07}")

        let status = ProgramStatus.working(id: "build", app: "swift", title: "Test", progress: 0.5)
        #expect(renderer.setProgramStatus(status))
        #expect(emitted.last?.contains("\u{1B}]7501;state=working;id=build;app=swift") == true)
        #expect(ProgramStatusKind.permission.oscFieldValue == "permission")

        renderer.setTerminalTitle("Swift OpenTUI")
        #expect(emitted.last == "\u{1B}]2;Swift OpenTUI\u{07}")

        renderer.resetTerminalBgColor()
        #expect(emitted.last == "\u{1B}]111;\u{07}")

        #expect(renderer.isOsc52Supported())
        #expect(renderer.copyToClipboardOSC52("hello"))
        #expect(emitted.last?.contains("\u{1B}]52;c;aGVsbG8=") == true)
        #expect(renderer.clearClipboardOSC52())
        #expect(emitted.last?.contains("\u{1B}]52;c;") == true)

        // Debug inputs, debug overlay & memory snapshot interval
        renderer.recordDebugInput("a", timestamp: "10ms")
        #expect(renderer.getDebugInputs() == [DebugInputEntry(timestamp: "10ms", sequence: "a")])

        renderer.configureDebugOverlay(enabled: false, corner: .topLeft)
        #expect(renderer.debugOverlayConfig.corner == .topLeft)
        renderer.toggleDebugOverlay()
        #expect(renderer.debugOverlayConfig.enabled)
        renderer.setMemorySnapshotInterval(500)
        renderer.toggleDebugOverlay()
        #expect(!renderer.debugOverlayConfig.enabled)

        // Tracked frame callbacks + native stats + dumpHitGrid
        var callbackHits = 0
        let cbHandle = FrameCallbackHandle { _ in callbackHits += 1 }
        renderer.setFrameCallback(cbHandle)
        #expect(renderer.hasFrameCallback(cbHandle))
        renderer.setGatherStats(true)
        #expect(renderer.isGatheringStats)

        renderer.renderOnce(force: true)
        #expect(callbackHits == 1)
        #expect(renderer.lastSceneTimeMs >= 0)
        #expect(renderer.getNativeStats().frameCount >= 1)

        let hitDump = renderer.dumpHitGrid()
        #expect(!hitDump.isEmpty)

        renderer.removeFrameCallback(cbHandle)
        #expect(!renderer.hasFrameCallback(cbHandle))
        renderer.clearAllFrameCallbacks()
        renderer.setGatherStats(false)
        #expect(!renderer.isGatheringStats)

        // ScrollbackSurface & writeToScrollback & resetSplitFooterForReplay
        let surface = try renderer.createScrollbackSurface(options: ScrollbackSurfaceOptions(startOnNewLine: true))
        let surfaceText = TextRenderable(
            ctx: surface.renderContext,
            options: TextOptions(content: "Scrollback line", width: .point(20), height: .point(1))
        )
        surface.root.add(surfaceText)
        await surface.settle()
        surface.commitRows(startRow: 0, endRowExclusive: 1)
        #expect(emitted.contains(where: { $0.contains("Scrollback line") }))
        surface.destroy()
        #expect(surface.isDestroyed)

        var toreDown = false
        try renderer.writeToScrollback { ctx in
            let line = TextRenderable(
                ctx: ctx.renderContext,
                options: TextOptions(content: "Direct commit", width: .point(20), height: .point(1))
            )
            return ScrollbackSnapshot(root: line, width: 20, height: 1, teardown: { toreDown = true })
        }
        #expect(toreDown)
        #expect(emitted.contains(where: { $0.contains("Direct commit") }))

        try renderer.resetSplitFooterForReplay(options: SplitFooterReplayResetOptions(clearSavedLines: true))
        #expect(emitted.last?.contains(ANSI.clearSavedLines) == true)

        // PixelResolution helper + idle + closed
        let res = PixelResolution(width: 800, height: 480)
        #expect(res.cellPixelSize(cols: 80, rows: 24)?.width == 10.0)
        await renderer.idle()

        let closedTask = renderer.closed
        renderer.destroy()
        await closedTask.value
        #expect(renderer.isDestroyed)

        // Event payload types smoke check
        let errEvt = CliRendererErrorEvent(error: CliRendererOperationError.rendererDestroyed)
        let dropEvt = CliRendererFrameDroppedEvent(bytes: 2000, limit: 1000)
        let events = RendererEvents(resize: { _, _ in })
        #expect(dropEvt.bytes == 2000)
        #expect(errEvt.renderable == nil)
        #expect(events.resize != nil)
    }

    @Test("QRCodeRegistration registers React & Solid tags and TUIQRCode mounts & patches")
    func qrCodeRegistrationAndDeclarativeView() throws {
        let registry = QRCodeComponentRegistry()
        #expect(!registry.isRegistered(QRCodeComponentRegistry.reactTag))
        #expect(!registry.isRegistered(QRCodeComponentRegistry.solidTag))

        registerQRCode(in: registry)
        #expect(registry.isRegistered("qr-code"))
        #expect(registry.isRegistered("qr_code"))
        #expect(registry.registeredTags == ["qr-code", "qr_code"])

        let renderer = CliRenderer(config: CliRendererConfig(width: 60, height: 30))
        defer { renderer.destroy() }

        let reactQR = try #require(
            registry.createRenderable(tag: "qr-code", ctx: renderer, options: QRCodeOptions(content: "https://opentui.dev"))
        )
        let solidQR = try #require(
            registry.createRenderable(tag: "qr_code", ctx: renderer, options: QRCodeOptions(content: "SOLID"))
        )
        #expect(reactQR.content == "https://opentui.dev")
        #expect(reactQR.moduleCount > 0)
        #expect(solidQR.content == "SOLID")
        #expect(solidQR.moduleCount > 0)

        // Declarative node mount & patch via registry.makeViewNode + TUIQRCode.register
        let node1 = try #require(
            registry.makeViewNode(
                tag: "qr-code",
                options: QRCodeOptions(content: "HELLO", errorCorrectionLevel: .M, scale: 1)
            )
        )
        let mounted = try #require(node1.mount(in: renderer) as? QRCodeRenderable)
        #expect(mounted.content == "HELLO")

        let node2 = try #require(
            registry.makeViewNode(
                tag: "qr_code",
                options: QRCodeOptions(content: "WORLD", errorCorrectionLevel: .H, scale: 2, invert: true)
            )
        )
        #expect(node2.patch(mounted))
        #expect(mounted.content == "WORLD")
        #expect(mounted.errorCorrectionLevel == .H)
        #expect(mounted.scale == 2)
        #expect(mounted.invert)

        let v1 = TUIQRCode("HELLO", ecl: .M, scale: 1)
        let viewNode = try #require(v1.resolveNodes().first)
        let viewMounted = try #require(viewNode.mount(in: renderer) as? QRCodeRenderable)
        #expect(viewMounted.content == "HELLO")

        registry.unregister(tag: "qr-code")
        #expect(!registry.isRegistered("qr-code"))
        registry.reset()
        #expect(registry.registeredTags.isEmpty)
    }
}
