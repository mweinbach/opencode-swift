import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

@Suite("Renderables Method Parity (Wave 3 O2)")
struct RenderablesMethodParityTests {
    // MARK: - 1. TS Renderables & Runtime Plugin Support Overrides

    @Test("BaseRenderable polymorphic methods, ScrollBox primaryAxis/overflow/bar sizing, and renderable overrides")
    func tsRenderableOverridesAndPolymorphism() throws {
        let test = createTestRenderer(options: TestRendererOptions(width: 40, height: 12))
        defer { test.renderer.destroy() }

        // Polymorphic BaseRenderable operations on Renderable
        let parentBox = BoxRenderable(ctx: test.renderer, options: BoxOptions(id: "parent-box", width: .point(30), height: .point(8)))
        let childA = BoxRenderable(ctx: test.renderer, options: BoxOptions(id: "child-a", width: .point(5), height: .point(2)))
        let childB = BoxRenderable(ctx: test.renderer, options: BoxOptions(id: "child-b", width: .point(5), height: .point(2)))
        let baseParent: BaseRenderable = parentBox
        #expect(baseParent.add(childA) == 0)
        baseParent.insertBefore(childB, anchor: childA)
        #expect(baseParent.getChildrenCount() == 2)
        #expect(baseParent.getBaseChildren().map(\.id) == ["child-b", "child-a"])
        #expect(baseParent.getBaseRenderable("child-a") === childA)
        #expect(baseParent.findBaseDescendantById("child-b") === childB)
        baseParent.requestRender()
        #expect(baseParent.isDirty)
        baseParent.remove(childB)
        #expect(baseParent.getChildrenCount() == 1)

        // Polymorphic BaseRenderable operations on TextNodeRenderable
        let rootText = TextNodeRenderable(options: TextNodeOptions(id: "tn-root"))
        let leafNode = TextNodeRenderable(options: TextNodeOptions(id: "tn-leaf"))
        let baseText: BaseRenderable = rootText
        #expect(baseText.add(leafNode) == 0)
        #expect(baseText.getBaseChildren().count == 1)
        #expect(baseText.getBaseRenderable("tn-leaf") === leafNode)
        #expect(baseText.findBaseDescendantById("tn-leaf") === leafNode)
        baseText.remove(leafNode)
        #expect(baseText.getChildrenCount() == 0)

        // ScrollBoxRenderable.primaryAxis, overflow, and ScrollBoxBar.width / height
        let scroll = ScrollBoxRenderable(ctx: test.renderer, options: ScrollBoxOptions(id: "sb", width: .point(20), height: .point(6)))
        #expect(scroll.primaryAxis == .column)
        scroll.content.flexDirection = .row
        #expect(scroll.primaryAxis == .row)
        #expect(scroll.overflow == .hidden)
        scroll.overflow = .visible
        #expect(scroll.overflow == .hidden)
        scroll.verticalScrollBar.width = 2
        scroll.horizontalScrollBar.height = 2
        #expect(scroll.verticalScrollBar.width >= 0)
        #expect(scroll.horizontalScrollBar.height >= 0)

        // InputRenderable single-line overrides
        let input = InputRenderable(ctx: test.renderer, options: InputRenderableOptions(id: "inp", value: "hello world", maxLength: 32))
        #expect(input.newLine() == false)
        input.focus()
        input.placeholderText = "type here"
        #expect(input.placeholderText == "type here")
        input.initialValue = "ignored"
        #expect(input.value == "hello world")
        #expect(input.deleteWordBackward())
        input.insertText("swift\n")
        #expect(input.value == "hello swift")
        #expect(input.undo())
        #expect(input.redo())
        #expect(input.submit())
        input.blur()

        // TextareaRenderable color overrides
        let area = TextareaRenderable(ctx: test.renderer, options: TextareaOptions(initialValue: "abc"))
        let bg = RGBA.fromInts(10, 20, 30, 255)
        let fg = RGBA.fromInts(200, 210, 220, 255)
        area.backgroundColor = bg
        area.textColor = fg
        #expect(area.backgroundColor == bg)
        #expect(area.textColor == fg)

        // CodeRenderable wrapMode / lineInfo / getLineSources
        let code = CodeRenderable(
            ctx: test.renderer,
            options: CodeOptions(content: "let a = 1\nlet b = 2", filetype: "swift", syntaxStyle: SyntaxStyle.create())
        )
        code.wrapMode = .char
        #expect(code.wrapMode == .char)
        #expect(code.getLineSources(startLine: 0, lineCount: 2).count >= 1)
        #expect(code.lineInfo.lineSources.count >= 1)

        // TextRenderable add / insertBefore / requestRender
        let txt = TextRenderable(ctx: test.renderer)
        let spanA = TextNodeRenderable(options: TextNodeOptions(id: "a"))
        let spanB = TextNodeRenderable(options: TextNodeOptions(id: "b"))
        txt.add(spanA)
        #expect(txt.insertBefore(spanB, anchor: spanA) == 0)
        txt.requestRender()

        // LineNumberRenderable & DiffRenderable teardown
        let lineNum = LineNumberRenderable(ctx: test.renderer)
        #expect(lineNum.add(code) >= 0)
        lineNum.destroyRecursively()
        #expect(lineNum.isDestroyed)

        let diff = DiffRenderable(ctx: test.renderer, options: DiffOptions(diff: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"))
        diff.destroyRecursively()
        #expect(diff.isDestroyed)

        // Runtime plugin descriptor helper (avoid mutating shared RuntimePluginSupport singleton across parallel suites)
        let runtimePlugin = createRuntimePlugin(CreateRuntimePluginOptions())
        #expect(runtimePlugin.name == "swift-plugin-opentui-runtime-modules")
    }

    // MARK: - 2. NativeZigRenderable

    @Test("NativeZigRenderable initWithConfig, setMeasureTarget, detachMeasure, resetForReuse, and NodeStorage.retainedBytes")
    func nativeZigRenderableLifecycle() throws {
        let cfg = NativeZigYoga.Config()
        let renderable = NativeZigRenderable.NativeRenderable.initWithConfig(cfg)
        renderable.contextOwned = true
        #expect(renderable.getYogaNode() === renderable.yogaNode)

        let tb = NativeZigTextBuffer.UnifiedTextBuffer()
        tb.core.setText("hello\nworld")
        let tbv = NativeZigTextBufferView.UnifiedTextBufferView(buffer: tb)
        try renderable.setMeasureTarget(.textBufferView(tbv))
        renderable.yogaNode.calculateLayout(40, 10, .ltr)
        #expect(renderable.yogaNode.getComputedWidth() >= 5)
        #expect(renderable.yogaNode.getComputedHeight() >= 2)

        try renderable.setMeasureTargetPreservingProvider(.none, preserveProvider: true)
        renderable.detachMeasure()
        #expect(renderable.resetForReuse() == true)

        let storage = NativeZigRenderable.NodeStorage(node: renderable)
        #expect(storage.retainedBytes() > 0)
        renderable.deinitRenderable()
        #expect(!renderable.contextOwned)
    }

    // MARK: - 3. NativeZigMarkdownInline & NativeZigMarkdown

    @Test("NativeZigMarkdownInline Parser incremental lifecycle, PendingSpans.add, and constants")
    func nativeZigMarkdownInlineMethods() {
        #expect(NativeZigMarkdownInline.tokenCountMax == 4096)
        #expect(NativeZigMarkdownInline.delimiterCountMax == 32)
        #expect(NativeZigMarkdownInline.bracketCountMax == 64)
        #expect(NativeZigMarkdownInline.labelCodepointCountMax == 999)

        let refs = NativeZigMarkdownInline.References(definitions: [
            "docs": NativeZigMarkdownInline.Link(destination: "https://example.com", title: "Docs"),
        ])
        #expect(refs.lookup("  DOCS  ")?.destination == "https://example.com")

        var parser = NativeZigMarkdownInline.Parser(references: refs)
        let r1 = parser.feed(Array("hi *em* `code`".utf8), final: true)
        #expect(r1.tokens.first?.endOffset() == 3)
        #expect(parser.result() == r1)
        #expect(parser.settled())
        #expect(parser.firstUnresolvedToken() == UInt32(r1.tokens.count))
        let changed = parser.takeChanged()
        #expect(changed.token == 0)
        #expect(parser.takeChanged().token == UInt32.max)

        parser.rebase(drop: 3)
        #expect(parser.tokens.isEmpty)

        _ = parser.restart(Array("hello **bold**".utf8), at: 6)
        #expect(!parser.tokens.isEmpty)

        parser.reset()
        #expect(parser.tokens.isEmpty)
        parser.releaseCapacity()
        parser.deinitParser()
        #expect(parser.subject.isEmpty)

        var spans = NativeZigMarkdownInline.PendingSpans()
        var marked: UInt64 = 0
        let firstChanged = spans.add(
            runs: [
                NativeZigMarkdownInline.PendingRun(at: 0, end: 2, char: UInt8(ascii: "*"), count: 2, open: true, close: false),
                NativeZigMarkdownInline.PendingRun(at: 4, end: 6, char: UInt8(ascii: "*"), count: 2, open: false, close: true),
            ],
            marked: &marked
        )
        #expect(firstChanged == 0)
        #expect(marked == 4)
        #expect(spans.kinds.count == 4)
        #expect(spans.kinds[0] == NativeZigMarkdownInline.kindBit(.strong))
        spans.clear()
        #expect(spans.fresh)
        spans.deinitSpans()
        #expect(spans.kinds.isEmpty)
    }

    @Test("NativeZigMarkdown Doc append/set/finish/readChanges/setOptions/wholeWrite/TailSink parity")
    func nativeZigMarkdownDocMethods() throws {
        #expect(NativeZigMarkdown.tableColumnCountMax == 128)
        #expect(NativeZigMarkdown.heldLineByteCountMax == 4096)
        #expect(NativeZigMarkdown.hookFilterByteCountMax == 256)
        #expect(NativeZigMarkdown.hookFilterItemByteCountMax == 64)
        #expect(NativeZigMarkdown.hookFilterItemCountMax == 16)
        #expect(NativeZigMarkdown.scratchRetainedByteCountMax == 1 << 20)

        let opts = NativeZigMarkdown.Options(math: true, hookFilter: Array("foo\0bar".utf8), conceal: true, hyperlinks: true)
        #expect(opts.liveShown)

        var c1 = NativeZigMarkdown.Counters()
        c1.lineByteVisits = 10
        c1.restyledKinds = 0b01
        c1.waitingRunsMax = 4
        var c2 = NativeZigMarkdown.Counters()
        c2.lineByteVisits = 5
        c2.restyledKinds = 0b10
        c2.waitingRunsMax = 9
        let sum = NativeZigMarkdown.Counters.plus(c1, c2)
        #expect(sum.lineByteVisits == 15)
        #expect(sum.restyledKinds == 0b11)
        #expect(sum.waitingRunsMax == 9)

        let doc = NativeZigMarkdown.Doc(options: opts)
        #expect(doc.filter() == Array("foo\0bar".utf8))

        try doc.append(Array("# Title\n\nHello *world*".utf8))
        #expect(doc.changeCount() >= 2)
        // Zero capacity reports count without acknowledging
        let peek = doc.readChanges(capacity: 0)
        #expect(peek.count >= 2)
        #expect(peek.changes.isEmpty)
        #expect(doc.changeCount() == peek.count)

        let drained = doc.readChanges(capacity: Int(peek.count))
        #expect(drained.changes.count == Int(peek.count))
        #expect(doc.changeCount() == 0)

        try doc.finish()
        #expect(doc.finished)
        #expect(doc.subtreeEnd(0) >= 1)
        #expect(NativeZigMarkdown.Doc.isBound(doc.blocks[0]))
        #expect(NativeZigMarkdown.Doc.isInlineLeaf(doc.blocks[0]))

        let leaf = try #require(doc.readLeaf(0))
        #expect(doc.leafDisplay(0) == leaf.bytes)
        #expect(!doc.leafSubject(0).isEmpty)
        #expect(!doc.parseLeaf(0).tokens.isEmpty)
        let content = doc.leafContent(0)
        #expect(content.sourceOffset(0) == 0)

        let sink = NativeZigMarkdown.TailSink()
        let write = doc.wholeWrite(0)
        sink.apply(write)
        #expect(sink.shown(block: 0) == leaf.bytes)
        #expect(NativeZigMarkdown.Doc.sameStyles(leaf: leaf, styles: sink.shownStyles(block: 0)))
        _ = sink.mirror(block: 1)
        sink.deinitSink()
        #expect(sink.shown(block: 0).isEmpty)

        // setOptions validates hookFilter and preserves finished state
        #expect(throws: NativeZigMarkdown.Error.invalidOptions) {
            try doc.setOptions(NativeZigMarkdown.Options(hookFilter: [0]))
        }
        try doc.setOptions(NativeZigMarkdown.Options(math: false, conceal: false, hyperlinks: true))
        #expect(doc.finished)
        doc.relistHostWritten()
        #expect(doc.changeCount() >= 1)

        try doc.set(Array("Replacement paragraph".utf8))
        #expect(!doc.finished)
        doc.deinitDoc()
        #expect(doc.blocks.isEmpty)
    }

    // MARK: - 4. Embedded Terminal (ghostty, main, unavailable)

    @Test("NativeZigEmbeddedTerminal StreamHandler.vt, composeChecked, encodeKey/Mouse, and unavailable parity")
    func nativeZigEmbeddedTerminalMethods() throws {
        let key = NativeZigGhostty.Key(action: .press, keyName: "enter", utf8: "\r")
        #expect(key.event() == key)
        let mouse = NativeZigGhostty.Mouse(action: .press, button: 0, x: 2, y: 3)
        #expect(mouse.event() == mouse)

        let term = try NativeZigEmbeddedTerminal.EmbeddedTerminal(
            options: NativeZigEmbeddedTerminal.Options(cols: 10, rows: 4)
        )
        // DECCOLM (mode 3) and kittyDnd are filtered by StreamHandler.vt
        _ = term.streamHandler.vt(action: .setMode(3))
        _ = term.streamHandler.vt(action: .kittyDnd)
        #expect(term.streamHandler.ignoredActionCount == 2)
        _ = term.streamHandler.vt(action: .print("Z"))
        try term.write("abc")

        term.setTransparentBackground(true)
        #expect(term.transparentBackground)

        let buf = try OptimizedBuffer.create(width: 10, height: 4)
        // Exceeding cell budget fails composeChecked
        #expect(throws: NativeZigEmbeddedTerminal.Error.compositor(.invalidOptions)) {
            try term.composeChecked(into: buf, cellsMax: 10)
        }
        try term.composeChecked(into: buf, cellsMax: 100)
        #expect(term.cursor().hasValue)
        #expect(term.scrollbar().visible == 4)

        var encodedKey = term.encodeKey(key)
        #expect(encodedKey == [0x0D])
        term.freeEncoded(&encodedKey)
        #expect(encodedKey.isEmpty)

        let encodedMouse = try term.encodeMouse(mouse)
        #expect(!encodedMouse.isEmpty)
        #expect(throws: NativeZigEmbeddedTerminal.Error.compositor(.invalidOptions)) {
            _ = try term.encodeMouse(NativeZigGhostty.Mouse(action: .press, button: 0, x: .nan, y: 0))
        }

        term.setSelection(start: NativeZigGhostty.Coordinate(x: 0, y: 0), end: NativeZigGhostty.Coordinate(x: 3, y: 0))
        var sel = term.selectedText()
        #expect(sel.hasPrefix("Zabc"))
        term.freeSelectedText(&sel)
        #expect(sel.isEmpty)
        term.clearSelection()
        term.deinitTerminal()

        // Unavailable stub parity
        let unavailable = NativeZigEmbeddedUnavailable.EmbeddedTerminal()
        unavailable.scroll(delta: 1)
        unavailable.clearSelection()
        unavailable.freeSelectedText("")
        unavailable.invalidate()
        unavailable.setTransparentBackground(true)
        unavailable.freeEncoded([])
        unavailable.deinitUnavailable()
        #expect(unavailable.cursor().hasValue == false)
        #expect(unavailable.scrollbar().total == 0)
        #expect(throws: NativeZigEmbeddedUnavailable.Error.unsupported) {
            try unavailable.composeChecked(into: buf, originX: 0, originY: 0, cellsMax: 40)
        }
    }

    // MARK: - 5. NativeZigScene & NativeZigSession

    @Test("NativeZigScene node lifecycle, scroll, paintBody, frameStep, hitToken, and paintedArea")
    func nativeZigSceneMethods() throws {
        let coreSession = try NativeSession(sink: MemorySessionOutputSink())
        let coreScene = NativeScene(driver: coreSession)
        let sessionHandle = SessionHandle(contextId: 7, slot: 1, generation: 1)
        let scene = NativeZigScene.Scene(core: coreScene, session: sessionHandle)
        #expect(NativeZigScene.paintFieldsAll == (1 << 11) - 1)

        var arrow = NativeZigScene.ArrowOptions(text: "▲")
        arrow.deinitOptions()
        #expect(arrow.text == nil)

        var imgState = NativeZigScene.ImageState()
        imgState.deinitState()
        var vidState = NativeZigScene.VideoState(openError: "err")
        vidState.deinitState()
        #expect(vidState.openError.isEmpty)

        // Insert root + box child
        let rootRenderable = NativeZigRenderable.NativeRenderable()
        rootRenderable.yogaNode.setWidth(20)
        rootRenderable.yogaNode.setHeight(10)
        let rootHandle = SceneNodeHandle(contextId: 7, slot: 1, generation: 1)
        try scene.prepareInsert(kind: UInt32(NativeABI.OT_SCENE_ROOT), num: 1)
        scene.insert(storage: NativeZigRenderable.NodeStorage(node: rootRenderable), handle: rootHandle, kind: UInt32(NativeABI.OT_SCENE_ROOT), num: 1)

        // Duplicate root rejected
        #expect(throws: NativeZigScene.SceneError.sceneAlreadyAttached) {
            try scene.prepareInsert(kind: UInt32(NativeABI.OT_SCENE_ROOT), num: 2)
        }

        let boxRenderable = NativeZigRenderable.NativeRenderable()
        boxRenderable.yogaNode.setWidth(10)
        boxRenderable.yogaNode.setHeight(5)
        let boxHandle = SceneNodeHandle(contextId: 7, slot: 2, generation: 1)
        try scene.prepareInsert(kind: UInt32(NativeABI.OT_SCENE_BOX), num: 2)
        scene.insert(storage: NativeZigRenderable.NodeStorage(node: boxRenderable), handle: boxHandle, kind: UInt32(NativeABI.OT_SCENE_BOX), num: 2)
        try scene.move(boxRenderable, destination: rootRenderable, index: 0)
        #expect(try scene.reaches(boxRenderable) == true)

        try scene.setPaintPartial(
            boxRenderable,
            fields: UInt32(NativeABI.OT_SCENE_PROPERTY_BORDER | NativeABI.OT_SCENE_PROPERTY_BACKGROUND),
            patch: NativeZigScene.Paint(borderSides: UInt32(NativeABI.OT_BORDER_ALL), background: RGBA.fromInts(10, 20, 30, 255))
        )
        try scene.setBoxDetails(boxRenderable, options: NativeZigScene.BoxDetails(title: "Box"))
        try scene.setScroll(boxRenderable, options: NativeZigScene.ScrollOptions(follow: UInt32(NativeABI.OT_SCENE_SCROLL_FOLLOW_BOTTOM), culling: true))
        let boxNode = try #require(boxRenderable.sceneNode)
        #expect(boxNode.filtersChildren())
        #expect(boxNode.childYoga(for: boxRenderable) !== boxRenderable.yogaNode)

        // ScrollState helpers
        var scrollState = try #require(boxNode.scroll)
        scrollState.maxY = 20
        scrollState.viewport = NativeZigScene.Layout(width: 10, height: 5)
        scrollState.visibleY = true
        scrollState.offsetY = 20
        scrollState.restick()
        #expect(scrollState.stuck)
        #expect(scrollState.observed().count == 6)
        _ = scrollState.applyGutters(to: boxRenderable.yogaNode)
        let rects = scrollState.barRects(axis: 1, box: NativeZigScene.Layout(width: 10, height: 5), sides: 0)
        #expect(rects.bar.width == 1)
        #expect(scrollState.slider(axis: 1).max == 20)
        boxNode.scroll = scrollState

        try scene.setScrollArrow(boxRenderable, axis: 1, end: 0, options: NativeZigScene.ArrowOptions(text: "^"))
        try scene.scrollTo(boxRenderable, target: (0, 5), relative: (false, false), reapply: true)
        try scene.requestScroll(boxRenderable, kind: UInt32(NativeABI.OT_SCENE_SCROLL_REQUEST_LAYOUT), target: nil as NativeZigRenderable.NativeRenderable?)
        try scene.setHooks(boxRenderable, flags: UInt32(NativeABI.OT_SCENE_HOOK_SCROLL), generation: 1, initialWidth: 10, initialHeight: 5)

        let target = try OptimizedBuffer.create(width: 20, height: 10)
        let id = NativeZigScene.BufferIdentity(target: target)
        #expect(id.matches(target))

        let ticket = try scene.frameStep(target: target, options: NativeZigScene.FrameOptions(useMouse: true))
        let painted = try scene.checkPainted(ticket)
        #expect(painted.ticket == ticket)
        scene.requalifyPainted(target: target)
        #expect(scene.paintedLatest(boxRenderable))
        #expect(scene.paintedArea(for: boxNode) != nil)
        #expect(scene.hitToken(screenWidth: 20, screenHeight: 10, x: 1, y: 1) != 0)
        try scene.paintBody(into: target, value: boxRenderable, x: 0, y: 0)

        scene.setViewport(boxRenderable, viewport: rootHandle)
        scene.cancelFrame()
        scene.clearChildren(rootRenderable)
        _ = scene.remove(boxRenderable)
        scene.detachAll()
        scene.deinitScene()
        #expect(scene.nodes.isEmpty)
    }

    @Test("NativeZigSession lifecycle, controls, kitty transport, output draining, and teardown")
    func nativeZigSessionMethods() throws {
        #expect(NativeZigSession.controlPacketBytesMax == 4096)
        #expect(NativeZigSession.cursorSettleNs == 10_000_000)
        #expect(NativeZigSession.splitSnapshotsMax == UInt32(NativeABI.OT_SPLIT_SNAPSHOTS_MAX))

        let session = try NativeZigSession.Session()
        try session.checkOpen()
        try session.checkRendering()
        try session.checkResizing()
        try session.checkFrameIdle()
        try session.checkLayoutIdle()

        try session.setupTerminal(NativeZigSession.TerminalOptions(useAlternateScreen: false))
        #expect(session.getTerminalState().phase == .active)

        try session.control(.title("OpenTUI"))
        #expect(session.lastTitle == "OpenTUI")
        try session.control(.mouse(.motion))
        #expect(session.lastMouseMode == .motion)
        try session.control(.cursor(NativeZigSession.CursorOptions(x: 2, y: 3, visible: true)))
        #expect(session.lastCursor.x == 2)
        try session.setPaletteState(palette: [RGBA.fromInts(1, 2, 3, 255)], defaultFg: .defaultForeground(), defaultBg: .defaultBackground(), epoch: 1)
        #expect(try session.triggerNotification(message: "Ready", title: "App") == true)
        #expect(try session.writeClipboard(target: 0, bytes: Array("clip".utf8)) == true)

        try session.setKittyImageTransport(mode: 1)
        #expect(try session.kittyImageTransportStatus()[0] == 1)
        #expect(try session.pollKittyImageTransport(nowNs: 100) == true)
        #expect(try session.processKittyImageReply(Array("OK".utf8)) == 1)
        try session.cancelKittyImageTransport(failed: false)
        try session.startKittyFileProbe()

        try session.setInputExpectations(NativeZigSession.Session.InputExpectations(replies: true))
        let feed = session.feedInput(Array("abc".utf8), nowNs: 50)
        #expect(feed.consumed == 3)
        try session.resetInput(keepReply: false)

        // Drain queued output via readOutput + completeOutput and drainOutput
        let read = try #require(try session.readOutput(maxBytes: 16))
        try session.completeOutput(ticket: read.ticket, result: .written)
        var drainedBytes: [UInt8] = []
        let drainedCount = try session.drainOutput(maxBytes: 4096) { chunk in
            drainedBytes.append(contentsOf: chunk)
            return chunk.count
        }
        #expect(drainedCount > 0)
        #expect(try session.drainStdout(maxBytes: 16, writer: { $0.count }) == 0)

        try session.write(Array("hello".utf8))
        let postRes = try session.postStdout(maxBytes: 16, wait: false, writer: { $0.count })
        #expect(postRes.inFlight)
        let collectRes = try session.postStdout(maxBytes: 0, wait: true)
        #expect(collectRes.written == 5)

        // Split control, screen switch, suspend/resume, detached sync
        #expect(try session.splitControl(.reset(seedRows: 0, pinnedRenderOffset: 4)) == 4)
        #expect(try session.splitControl(.sync(6)) == 6)
        #expect(try session.splitControl(.renderOffset(2)) == 2)
        try session.setScreen(alternate: true, width: 80, height: 24)
        #expect(try session.render(force: true) == .presented)
        #expect(try session.renderSplit(pinnedRenderOffset: 1) == .presented)

        let detached = try NativeZigSession.Session(handle: SessionHandle(contextId: 1, slot: 2, generation: 1))
        try detached.syncDetached(from: session)
        #expect(detached.paletteEpoch == 1)

        try session.suspendTerminal()
        #expect(session.getTerminalState().phase == .suspended)
        try session.resumeTerminal()
        #expect(session.getTerminalState().phase == .active)

        _ = session.getStats()
        try session.dropOutput()
        #expect(try session.pumpExit() == .closed)
        session.cancel()
        #expect(session.canDestroy())
        try session.deinitSession()
    }

    // MARK: - 6. NativeContextHandleTable, OutputWriter, and NativeContextMethods

    @Test("NativeContextHandleTable.Table, OutputWriter.write, and NativeContextEngine.Context methods")
    func nativeContextMethodsParity() throws {
        // Handle table checkCapacity / getKind / next
        let table = NativeContextHandleTable.Table(contextId: 9, capacity: 2)
        try table.checkCapacity()
        let h1 = try table.allocate(kind: .buffer)
        let h2 = try table.allocate(kind: .session)
        #expect(try table.getKind(h1) == .buffer)
        #expect(throws: NativeContextHandleTable.TableError.objectLimit) {
            try table.checkCapacity()
        }
        var cursor = 0
        #expect(table.next(kind: .session, cursor: &cursor) == h2)
        #expect(table.next(kind: .session, cursor: &cursor) == nil)
        let tok = try table.beginDestroy(h1)
        table.finishDestroy(tok)
        try table.checkCapacity()
        table.resetAll()

        // OutputWriter & stdOptions
        #expect(NativeContextABI.stdOptions.logLevel == .debug)
        let writer = NativeContextABI.OutputWriter { bytes in Int64(bytes.count) }
        #expect(try writer.write(Array("ok".utf8)) == 2)
        let badWriter = NativeContextABI.OutputWriter { _ in -1 }
        #expect(throws: NativeContextABI.OutputWriter.WriteError.writeFailed) {
            _ = try badWriter.write([1, 2])
        }

        // NativeContextEngine helper structs & Context methods
        #expect(NativeContextEngine.terminalInputBytesMax > 0)
        let mdOpts = try NativeMarkdownOptions(flags: UInt32(NativeABI.OT_MD_CONCEAL | NativeABI.OT_MD_HYPERLINKS)).engine()
        #expect(mdOpts.liveShown)
        let txtHelper = NativeContextEngine.Text("hello")
        #expect(txtHelper.mapping(contentEpoch: 2).contentEpoch == 2)
        #expect(txtHelper.prepareView() == 5)
        try NativeContextEngine.Context.validateTextBytes(Array("valid utf8".utf8))

        let ctx = try NativeContextEngine.Context()
        defer { ctx.destroy() }
        try ctx.checkBufferDimensions(width: 20, height: 10)
        try ctx.checkSceneRead()

        let buf = try ctx.createBuffer(options: NativeContextBufferOptions(width: 20, height: 10))
        try ctx.resizeBuffer(buf, width: 24, height: 12)
        try ctx.clearBuffer(buf, background: RGBA.fromInts(0, 0, 0, 255))
        try ctx.fillBufferRect(buf, x: 0, y: 0, width: 4, height: 2, background: RGBA.fromInts(10, 20, 30, 255))
        try ctx.drawBufferText(buf, text: "hi", x: 0, y: 0, foreground: RGBA.fromInts(255, 255, 255, 255))
        let (leaseHandle, _) = try ctx.acquireOwnedBufferLease(buffer: buf)
        #expect(try ctx.bufferLeaseSnapshot(leaseHandle).width == 24)
        try ctx.releaseBufferLease(leaseHandle)

        // RawAccess lookups
        let raw = ctx.raw()
        _ = try raw.getBuffer(buf)

        let tb = try ctx.createTextBuffer()
        try ctx.textBufferSetText(textBuffer: tb, text: "hello")
        try ctx.textBufferAppend(textBuffer: tb, text: " world")
        #expect(try ctx.textBufferGetRange(textBuffer: tb, start: 0, end: 5) == "hello")
        let sharedText = try raw.getTextBuffer(tb)
        try sharedText.checkMutable(in: ctx)
        sharedText.invalidate(in: ctx)
        try sharedText.setWidthMethod(.unicode, in: ctx)

        let tbv = try ctx.createTextBufferView(textBuffer: tb)
        let textViewDesc = try raw.getTextBufferView(tbv)
        try textViewDesc.checkMutable(in: ctx)
        textViewDesc.invalidate(in: ctx)
        textViewDesc.invalidatePreparation(in: ctx)
        _ = try textViewDesc.prepareView(in: ctx)

        let eb = try ctx.createEditBuffer()
        try ctx.editSetText(editBuffer: eb, text: "abc")
        try ctx.editInsertText(editBuffer: eb, text: "!")
        #expect(try ctx.editMeasureText(editBuffer: eb, text: "abcd") == 4)
        #expect(try ctx.measureEditText(text: "abcd") == 4)
        let editDesc = try raw.getEditBuffer(eb)
        try editDesc.checkMutable(in: ctx)
        editDesc.invalidate(in: ctx)
        editDesc.invalidatePreparation(in: ctx)

        let ev = try ctx.createEditorView(editBuffer: eb, width: 20, height: 4)
        let editorDesc = try raw.getEditorView(ev)
        try editorDesc.checkMutable(in: ctx)
        editorDesc.invalidate(in: ctx)
        editorDesc.invalidatePreparation(in: ctx)
        _ = try editorDesc.prepareView(in: ctx)
        _ = try ctx.editorPrepareView(view: ev)

        let style = try ctx.createSyntaxStyle()
        let styleId = try ctx.syntaxStyleRegister(style: style, name: "keyword", definition: NativeEditorStyle(attributes: TextAttributes.bold))
        #expect(styleId > 0)
        _ = try raw.getSyntaxStyle(style)

        let md = try ctx.createMarkdown()
        _ = try ctx.markdownCall(doc: md, action: "set", text: "# Heading")
        #expect(try ctx.markdownSource(doc: md) == "# Heading")
        _ = try ctx.markdownReadChanges(doc: md)

        let uni = try ctx.createUnicode(text: "OK")
        #expect(try raw.getUnicode(uni).text == "OK")
        try ctx.drawBufferUnicode(target: buf, unicode: uni, x: 0, y: 1)

        let emb = try ctx.createEmbeddedTerminal(cols: 12, rows: 4)
        try ctx.embeddedTerminalWrite(terminal: emb, bytes: Array("hi".utf8))
        #expect(try ctx.embeddedTerminalScrollbar(terminal: emb).visible == 4)
        #expect(try ctx.embeddedTerminalCursor(terminal: emb).x >= 0)
        _ = try ctx.embeddedTerminalEncodeKey(terminal: emb, key: EmbeddedTerminalKey(key: "enter", text: "\r"))

        let session = try ctx.createSession()
        _ = try raw.getSession(session)
        let node = try ctx.sceneCreateNode(session: session, kind: UInt32(NativeABI.OT_SCENE_TEXT), num: 1)
        try ctx.sceneSetText(node: node, text: "scene-text")
        #expect(try ctx.sceneGetText(node: node) == "scene-text")
        try ctx.sceneDestroyNode(node)

        _ = try ctx.createClipboardService()
        let stdoutWriter = try NativeContextEngine.Context.StdoutCreate(fd: 1).create()
        defer { stdoutWriter.abandon() }
        #expect(stdoutWriter.totalBytesWritten == 0)
    }
}
