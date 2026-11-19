import Synchronization
import Testing
@testable import OpenTUICore

@Suite("Wave 3 O1 — OpenTUICore & Native Zig Method Parity")
struct NativeZigMethodParityTests {

    // MARK: - Tree-Sitter parsers-config & updateAssets

    @Test("defaultParsersConfig matches upstream parsers-config.ts definitions")
    func defaultParsersConfigParity() {
        let parsers = defaultParsersConfig.parsers
        #expect(parsers.count == 6)

        let byFiletype = Dictionary(uniqueKeysWithValues: parsers.map { ($0.filetype, $0) })
        let js = byFiletype["javascript"]
        #expect(js != nil)
        #expect(js?.aliases == ["javascriptreact"])
        #expect(js?.wasm.hasSuffix("tree-sitter-javascript.wasm") == true)
        #expect(js?.queries.highlights.count == 1)

        let tsx = byFiletype["typescriptreact"]
        #expect(tsx?.queries.highlights.count == 3)
        #expect(tsx?.wasm.hasSuffix("tree-sitter-tsx.wasm") == true)

        let md = byFiletype["markdown"]
        #expect(md?.queries.highlights == ["./assets/markdown/highlights.scm"])
        #expect(md?.queries.injections?.count == 1)
        #expect(md?.injectionMapping?.nodeTypes?["inline"] == "markdown_inline")
        #expect(md?.injectionMapping?.nodeTypes?["pipe_table_cell"] == "markdown_inline")
        #expect(md?.injectionMapping?.infoStringMap?["tsx"] == "typescriptreact")
        #expect(md?.injectionMapping?.infoStringMap?["md"] == "markdown")

        #expect(byFiletype["markdown_inline"]?.queries.highlights == ["./assets/markdown_inline/highlights.scm"])
        #expect(byFiletype["zig"]?.wasm.hasSuffix("tree-sitter-zig.wasm") == true)
    }

    @Test("updateAssets downloads wasm and combines local + remote highlight and injection queries")
    func updateAssetsCombinesQueries() async throws {
        let loader = InMemoryTreeSitterAssetLoader()
        loader.setRemoteResource([0x00, 0x61, 0x73, 0x6D], for: "https://example.com/lang.wasm")
        loader.setRemoteResource(Array("(identifier) @variable".utf8), for: "https://example.com/remote-highlights.scm")
        loader.setRemoteResource(Array("(code_fence) @injection.content".utf8), for: "https://example.com/injections.scm")
        loader.setLocalFile(Array("(comment) @comment".utf8), at: "/repo/lib/assets/custom/local.scm")

        let parser = FiletypeParserOptions(
            filetype: "custom",
            aliases: ["cst"],
            queries: FiletypeParserQueries(
                highlights: ["./assets/custom/local.scm", "https://example.com/remote-highlights.scm"],
                injections: ["https://example.com/injections.scm"]
            ),
            wasm: "https://example.com/lang.wasm"
        )
        let options = UpdateOptions(
            configPath: "/repo/lib/parsers-config.ts",
            assetsDir: "/repo/lib/assets",
            outputPath: "/repo/lib/default-parsers.ts"
        )

        let generated = try await updateAssets(options: options, parsers: [parser], loader: loader)
        #expect(generated.count == 1)
        #expect(generated[0].filetype == "custom")
        #expect(generated[0].aliases == ["cst"])
        #expect(generated[0].languagePath == "./assets/custom/lang.wasm")
        #expect(generated[0].highlightsPath == "./assets/custom/highlights.scm")
        #expect(generated[0].injectionsPath == "./assets/custom/injections.scm")

        let combinedHighlights = try await loader.readLocalFile(at: "/repo/lib/assets/custom/highlights.scm")
        let highlightsText = String(decoding: combinedHighlights, as: UTF8.self)
        #expect(highlightsText.contains("(comment) @comment"))
        #expect(highlightsText.contains("; Query from: https://example.com/remote-highlights.scm"))
        #expect(highlightsText.contains("(identifier) @variable"))

        let manifestBytes = try await loader.readLocalFile(at: "/repo/lib/default-parsers.ts")
        let manifestText = String(decoding: manifestBytes, as: UTF8.self)
        #expect(manifestText.contains("filetype=custom"))
        #expect(manifestText.contains("injections=./assets/custom/injections.scm"))
    }

    // MARK: - Portable platform/test.ts Harness

    @Test("platformDescribe, hooks, and platformExpect execute lifecycle order faithfully")
    func platformTestHarnessLifecycle() throws {
        let harness = PlatformTestHarness()
        let log = Mutex<[String]>([])

        let report = platformDescribe("math", harness: harness) {
            platformBefore(harness: harness) {
                log.withLock { $0.append("before") }
            }
            platformAfter(harness: harness) {
                log.withLock { $0.append("after") }
            }
            platformBeforeEach(harness: harness) {
                log.withLock { $0.append("beforeEach") }
            }
            platformAfterEach(harness: harness) {
                log.withLock { $0.append("afterEach") }
            }
            platformIt("adds", harness: harness) {
                log.withLock { $0.append("adds") }
                try platformExpect(2 + 2).toBe(4)
                let missing: Int? = nil
                try platformExpect(missing).toBeNull()
            }
            platformTest("throws", harness: harness) {
                log.withLock { $0.append("throws") }
                try platformExpect({ () throws -> Void in
                    throw PlatformAssertionError("boom")
                }).toThrow("boom")
            }
        }

        #expect(report.passed == ["math > adds", "math > throws"])
        #expect(report.failed.isEmpty)
        #expect(log.withLock { $0 } == [
            "before",
            "beforeEach", "adds", "afterEach",
            "beforeEach", "throws", "afterEach",
            "after",
        ])
    }

    // MARK: - NativeUtils, EventEmitter, StdoutWriter Sinks

    @Test("NativeUtils.fillU32 fills arrays and slices preserving surrounding bounds")
    func fillU32PreservesBounds() {
        var buffer = Array<UInt32>(repeating: 0xAABB_CCDD, count: 16)
        var mid = buffer[4..<12]
        NativeUtils.fillU32(&mid, value: 0x1234_5678)
        buffer[4..<12] = mid
        #expect(buffer[0..<4].allSatisfy { $0 == 0xAABB_CCDD })
        #expect(buffer[4..<12].allSatisfy { $0 == 0x1234_5678 })
        #expect(buffer[12..<16].allSatisfy { $0 == 0xAABB_CCDD })

        NativeUtils.fillU32(&buffer, value: 42)
        #expect(buffer.allSatisfy { $0 == 42 })
    }

    @Test("NativeStdoutWriter ScriptSink, MaskSink, and RoomSink honor retry and counting semantics")
    func stdoutWriterTestSinks() throws {
        let script = NativeStdoutWriter.ScriptSink(results: [
            .error(.interrupted),
            .wrote(1),
            .error(.wouldBlock),
            .wrote(3),
        ])
        let writer = try NativeStdoutWriter.Writer.create(
            sink: script,
            runner: NativeStdoutWriter.ThreadRunner()
        )
        writer.start(bytes: Array("abcd".utf8))
        let outcome = writer.waitCollect(graceNs: 1_000_000_000)
        #expect(outcome == .written)
        #expect(script.callsMade == 4)
        writer.abandon()

        let maskSink = NativeStdoutWriter.MaskSink(maskProvider: { 0xCAFE_BABE })
        let maskWriter = try NativeStdoutWriter.Writer.create(
            sink: maskSink,
            runner: NativeStdoutWriter.ThreadRunner()
        )
        maskWriter.start(bytes: [0x41])
        #expect(maskWriter.waitCollect(graceNs: 1_000_000_000) == .written)
        #expect(maskSink.lastObservedMask == 0xCAFE_BABE)
        maskWriter.abandon()

        let fds = try NativeStdoutWriter.testPipe(capacity: 2)
        defer { NativeStdoutWriter.closeAll(fds) }
        let roomSink = NativeStdoutWriter.RoomSink(fd: NativeStdoutWriter.FdSink(fd: fds.writeFd))
        let wrote = try roomSink.write(Array("xy".utf8)[...])
        #expect(wrote == 2)
        roomSink.waitWritable()
        #expect(roomSink.waitCount == 1)
    }

    // MARK: - GraphemePool, SyntaxStyle.resolveGroupSet, PassthroughWriter, BackendWriter

    @Test("GraphemePool.init(options:) and NativeZigSyntaxStyle.resolveGroupSet cache and invalidate")
    func graphemePoolOptionsAndSyntaxStyleGroupSet() throws {
        let pool = GraphemePool(options: GraphemePool.InitOptions(slotsPerPage: [32, 32, 16, 8, 4]))
        let id = try pool.acquire("👨‍👩‍👧‍👦")
        #expect(try pool.getString(id) == "👨‍👩‍👧‍👦")
        #expect(try pool.getRefcount(id) == 1)

        let style = NativeZigSyntaxStyle.SyntaxStyle()
        let borrower = NativeZigSyntaxStyle.Borrower()
        borrower.bind(style)
        let red = RGBA.fromInts(255, 0, 0, 255)
        let blue = RGBA.fromInts(0, 0, 255, 255)
        _ = style.registerStyle(name: "keyword", fg: red, bg: nil, attributes: TextAttributes.bold)

        var sets = NativeHighlightLayers.GroupSets()
        let groupId = try sets.intern(["keyword", "markup.strikethrough"])
        let resolved1 = style.resolveGroupSet(sets: sets, id: groupId)
        #expect(resolved1.fg == red)
        #expect((resolved1.attributes & TextAttributes.bold) != 0)
        #expect((resolved1.attributes & TextAttributes.strikethrough) != 0)

        // Re-registering invalidates the cached group set composition
        _ = style.registerStyle(name: "keyword", fg: blue, bg: nil, attributes: TextAttributes.italic)
        let resolved2 = style.resolveGroupSet(sets: sets, id: groupId)
        #expect(resolved2.fg == blue)
        #expect((resolved2.attributes & TextAttributes.italic) != 0)
        #expect(borrower.changes >= 3)
        sets.deinitGroupSets()
    }

    @Test("PassthroughWriter frames tmux ESC doubling and screen DCS chunks")
    func passthroughWriterTmuxAndScreen() throws {
        var tmuxSink = NativeTerminalByteBuffer()
        var tmuxWriter = try NativeTerminalState.PassthroughWriter(sink: tmuxSink, multiplexer: .tmux)
        try tmuxWriter.writeAll(Array("\u{1B}]0;hi\u{07}".utf8))
        try tmuxWriter.finish()
        tmuxSink = tmuxWriter.sink
        #expect(tmuxSink.string == "\u{1B}Ptmux;\u{1B}\u{1B}]0;hi\u{07}\u{1B}\\")

        var screenSink = NativeTerminalByteBuffer()
        var screenWriter = try NativeTerminalState.PassthroughWriter(sink: screenSink, multiplexer: .screen)
        try screenWriter.writeByte(UInt8(ascii: "A"))
        try screenWriter.writeByte(UInt8(ascii: "B"))
        try screenWriter.finish()
        screenSink = screenWriter.sink
        #expect(screenSink.string == "\u{1B}PAB\u{1B}\\")
    }

    @Test("FeedBackend.writer() stages frame output and commits via BackendWriter")
    func feedBackendWriter() throws {
        let feed = NativeSpanFeed.create(NativeSpanFeedOptions(chunkSize: 4096, initialChunks: 2))
        let backend = NativeRendererOutput.FeedBackend(feed: feed)
        #expect(backend.prepareFrame() == .ok)
        backend.beginFrame()
        var writer = backend.writer()
        _ = try writer.write(Array("hello ".utf8))
        try writer.print("world")
        try writer.writeByte(UInt8(ascii: "!"))
        try writer.flush()
        #expect(backend.endFrame() == .ok)
        let spans = feed.drain(maxSpans: 4)
        #expect(spans.count == 1)
        let bytes = feed.readSpan(spans[0]) ?? []
        #expect(String(decoding: bytes, as: UTF8.self) == "hello world!")
    }

    // MARK: - AnsiDiffRenderer (CliRenderer) & OptimizedBuffer Native Methods

    @Test("AnsiDiffRenderer CliRenderer parity methods manage split scrollback, deferred presentation, and Kitty transport")
    func cliRendererParityMethods() throws {
        let renderer = AnsiDiffRenderer(width: 20, height: 6)
        renderer.setDebugOverlay(enabled: true, corner: .topRight)
        #expect(renderer.debugOverlayEnabled)
        #expect(renderer.debugOverlayCorner == .topRight)

        #expect(renderer.resetSplitScrollback(seedRows: 10, pinnedRenderOffset: 4) == 4)
        #expect(renderer.getSplitOutputOffset(surfaceOffset: 6) == 6)
        // publishedRows (10) >= pinnedRenderOffset (8) => outputOffset == 8, clamping renderOffset (4) up to 8
        #expect(renderer.syncSplitScrollback(pinnedRenderOffset: 8) == 8)
        #expect(renderer.resetSplitScrollback(seedRows: 3, pinnedRenderOffset: 8) == 3)
        renderer.clearPendingSplitFooterTransition()

        renderer.updateStats(time: 16.0, fps: 60, frameCallbackTime: 1.5)
        renderer.updateMemoryStats(heapUsed: 100, heapTotal: 200, arrayBuffers: 50)
        let snap = renderer.getRenderStats()
        #expect(snap.lastFrameTime == 16.0)

        let feed = NativeSpanFeed.create(NativeSpanFeedOptions(chunkSize: 64 * 1024, initialChunks: 2))
        renderer.backend = NativeRendererOutput.FeedBackend(feed: feed)
        renderer.getNextBuffer().drawText("Hi", x: 0, y: 0, fg: RGBA.fromInts(255, 255, 255, 255))
        let status = try renderer.renderDeferred(force: true)
        #expect(status == .rendered)
        try renderer.completePresentation(outcome: .presented)

        #expect(renderer.setKittyImageTransport(mode: NativeKittyTransport.Mode.zlib.rawValue))
        let kittyStatus = renderer.kittyImageTransportStatus()
        #expect(kittyStatus[0] == NativeKittyTransport.Mode.zlib.rawValue)
        #expect(renderer.resolveImageProtocol(requested: .blocks) == .fallback)

        try renderer.resizeWithOutput(width: 24, height: 8, bytes: Array("\u{1B}[2J".utf8))
        #expect(renderer.width == 24)
        #expect(renderer.height == 8)
    }

    @Test("OptimizedBuffer PreparedResize, drawGraphemeChecked, and materializeImageFallbacks")
    func bufferNativeParityMethods() throws {
        let buf = try NativeBufferBridge.OptimizedBuffer(width: 8, height: 4)
        buf.ownerContextId = 7
        var lease = try buf.acquireLease()
        #expect(lease.isCurrent())

        var prepared = try buf.prepareResize(width: 10, height: 5)
        #expect(lease.isCurrent())
        prepared.commit()
        #expect(!lease.isCurrent())
        lease.release()
        #expect(buf.width == 10 && buf.height == 5)
        #expect(buf.getCharPtr().count == 50)

        try buf.core.drawGraphemeChecked(
            Array("A".utf8),
            cellWidth: 1,
            x: 0,
            y: 0,
            fg: RGBA.fromInts(255, 255, 255, 255),
            bg: RGBA.fromInts(0, 0, 0, 255)
        )
        try buf.core.drawTextChecked(
            Array("BC".utf8),
            x: 1,
            y: 0,
            fg: RGBA.fromInts(255, 255, 255, 255)
        )
        #expect(buf.core.getRealCharSize(addLineBreaks: false) >= 3)

        // Materialize an image placement fallback into quadrant cells
        let rgba: [UInt8] = Array(repeating: 255, count: 4 * 4 * 4)
        let coreImg = try NativeImage.fromRgba(rgba, width: 4, height: 4)
        let zigImg = NativeZigImage.Image(core: coreImg)
        zigImg.ownerContextId = 7
        buf.imagePlacements.append(
            NativeBufferBridge.OptimizedBuffer.ImagePlacement(
                placementId: 1,
                image: zigImg,
                x: 0,
                y: 1,
                width: 2,
                height: 2
            )
        )
        for py in 1..<3 {
            for px in 0..<2 {
                buf.core.setCellRaw(
                    x: px,
                    y: py,
                    cell: TerminalCell(
                        scalar: packImageCell(id: 1, fallback: 0),
                        foreground: RGBA.fromInts(255, 255, 255, 255),
                        background: RGBA.fromInts(0, 0, 0, 255),
                        attributes: TextAttributes.none
                    )
                )
            }
        }
        try buf.checkImageResources()
        try buf.materializeImageFallbacks()
        #expect(buf.imagePlacements.isEmpty)
        let materialized = buf.core.cell(atX: 0, y: 1)
        #expect(materialized != nil && !isImageChar(materialized!.scalar))
    }

    // MARK: - Video, SpanFeed, Rope, TextBuffer, TextBufferView, EditBuffer, EditorView

    @Test("NativeZigVideo open, prepare/schedule, offline audio mix, and Player lifecycle")
    func videoAndPlayerParity() throws {
        let info = NativeZigVideo.Info(
            durationUs: 2_000_000,
            width: 2,
            height: 2,
            fpsNum: 30,
            fpsDen: 1,
            hasAudio: 1,
            audioSampleRate: 48_000,
            audioChannels: 2
        )
        let player = NativeZigVideo.Player.open(path: "clip.mp4", audioEnabled: true, info: info)
        let frameImg = NativeZigImage.Image(core: try NativeImage.fromRgba(Array(repeating: 200, count: 16), width: 2, height: 2))
        player.video.loadFrames([(0, frameImg), (1_000_000, frameImg)])
        player.video.loadAudioSamples(Array(repeating: 0.5, count: 960 * 2))
        player.play()
        #expect(player.video.prepare(targetUs: 1_000_000))
        player.video.drainPreparation()
        #expect(player.video.decodedFrames() >= 1)

        var mixOut = Array<Float>(repeating: 0, count: 480 * 2)
        let mixed = player.video.mixOffline(output: &mixOut, frames: 480)
        #expect(mixed == 480)
        #expect(player.video.audioStats()?.framesPlayed == 480)
        #expect(player.video.audioTimeUs() == 10_000)
        #expect(player.lastError().isEmpty)
    }

    @Test("NativeZigSpanFeed SpanRing and Stream atomic writes + control reservation")
    func spanFeedRingAndStreamParity() throws {
        var ring = NativeZigSpanFeed.SpanRing(capacity: 4)
        var notified = false
        try ring.push(span: NativeZigSpanFeed.SpanInfo(len: 5, releaseId: 1), notify: &notified)
        #expect(notified)
        #expect(ring.count() == 1)
        let popped = ring.popMany(maxCount: 2)
        #expect(popped.count == 1 && popped[0].releaseId == 1)

        let stream = NativeZigSpanFeed.Stream.create(
            options: NativeZigSpanFeed.Options(chunkSize: 1024, initialChunks: 2, maxBytes: 2048, growthPolicy: 1)
        )
        try stream.attach()
        #expect(stream.bounded())
        #expect(stream.byteLimit() == 2048)
        try stream.reserveControlCapacity(bytes: 128)
        try stream.writeReservedControlAtomic(Array("\u{1B}[0m".utf8))
        #expect(stream.hasPendingSpans())
        let drained = stream.drainSpans(maxSpans: 4)
        #expect(drained.count == 1)
        #expect(drained[0].slice(in: stream) == Array("\u{1B}[0m".utf8))
        stream.markSpanConsumed(drained[0])
        stream.assertInvariants()
        try stream.close()
        try stream.tryDestroy()
    }

    @Test("NativeZigRope balanced Node tree, weight splitting, seeking, and undo")
    func ropeBalancedNodeAndWeightOps() throws {
        var rope = NativeZigRope.Rope<String>.fromSliceWithConfig(
            ["hello", " ", "world"],
            config: .init(maxUndoDepth: 8),
            weightOf: { UInt32($0.utf8.count) }
        )
        #expect(rope.totalWeight() == 11)
        let found = rope.findByWeight(7)
        #expect(found?.leaf == "world")
        #expect(found?.startWeight == 6)

        let splitter = NativeZigRope.Rope<String>.Node.LeafSplitFn { str, w in
            let bytes = Array(str.utf8)
            let splitAt = min(Int(w), bytes.count)
            return .init(
                left: String(decoding: bytes[0..<splitAt], as: UTF8.self),
                right: String(decoding: bytes[splitAt...], as: UTF8.self)
            )
        }
        rope.storeUndo(meta: [1])
        _ = try rope.replaceRangeByWeight(start: 6, end: 11, replacement: ["swift"], splitLeafFn: splitter)
        #expect(String(decoding: rope.toText { $0 }, as: UTF8.self) == "hello swift")

        let tree = try #require(rope.buildTree())
        #expect(tree.isBalanced())
        let empty = NativeZigRope.Rope<String>.Node.newLeaf("", weight: 0)
        let parts = NativeZigRope.Rope<String>.Node.splitAt(tree, index: 1, emptyLeaf: empty)
        #expect(parts.left.count() == 1)
        #expect(parts.right.count() == tree.count() - 1)
        let rejoined = NativeZigRope.Rope<String>.Node.joinBalanced(left: parts.left, right: parts.right)
        #expect(rejoined.count() == tree.count())

        #expect(rope.seekCount(counted: { $0 == " " ? 1 : 0 }, target: 0)?.leafIndex == 1)
        #expect(rope.countThrough(key: { UInt32($0.utf8.count) }, counted: { _ in 1 }, target: 6) == 2)
        #expect(rope.undo() == [1])
        #expect(String(decoding: rope.toText { $0 }, as: UTF8.self) == "hello world")
    }

    @Test("NativeZigTextBuffer, UnifiedTextBufferView, EditBuffer atomic marks, and EditorView")
    func textEngineNativeParity() throws {
        let eb = NativeZigEditBuffer.EditBuffer(options: .init(widthMethod: .unicode, tabWidth: 4, id: 1))
        eb.setText("hello @user world")
        let markId = try eb.addMark(.init(kind: 1, startByte: 6, endByte: 11, atomic: true))
        eb.setCursorByOffsetAtomic(8)
        let cur = eb.getPrimaryCursor()
        #expect(cur.offset == 6 || cur.offset == 11)
        eb.setCursorByOffset(11)
        eb.deleteAtomic(forwardDelete: false)
        #expect(eb.getText() == "hello  world")
        #expect(!eb.removeMark(id: markId))

        let view = NativeZigEditorView.EditorView(editBuffer: eb, viewportWidth: 20, viewportHeight: 5)
        view.setPlaceholderOwnedStyledText(
            text: Array("Type here".utf8),
            chunks: [.init(byteCount: 9)]
        )
        #expect(view.placeholderBuffer?.getPlainText() == "Type here")
        view.clearPlaceholder()
        #expect(view.placeholderBuffer == nil)

        let tbv = view.getTextBufferView()
        let word = tbv.selectWord(offset: 1)
        #expect(word == NativeZigTextBufferView.SelectionRange(start: 0, end: 5))
        tbv.setSelection(start: 0, end: 5)
        #expect(tbv.packSelectionInfo() == ((UInt64(0) << 32) | 5))
        var selBuf = Array<UInt8>(repeating: 0, count: 16)
        let copied = try tbv.copySelectedText(into: &selBuf)
        #expect(String(decoding: selBuf[0..<Int(copied)], as: UTF8.self) == "hello")

        let vc = view.logicalToVisualCursor(logicalRow: 0, logicalCol: 3)
        let back = view.visualToLogicalCursor(visualRow: vc.visualRow, visualCol: vc.visualCol)
        #expect(back?.logicalRow == 0 && back?.logicalCol == 3)

        let tb = eb.getTextBuffer()
        var prepared = tb.prepareOwnedStyledText(
            text: Array("abc".utf8),
            chunks: [.init(byteCount: 3, style: .init(fg: RGBA.fromInts(10, 20, 30, 255)))]
        )
        _ = prepared.commit()
        #expect(tb.getPlainText() == "abc")
        #expect(tb.convertUtf16(index: 2, toByte: true) == 2)
        #expect(NativeZigTextBuffer.UnifiedTextBuffer.effectiveTabWidth(0) == 2)
    }
}
