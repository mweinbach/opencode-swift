import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

@Suite("NativeSubsystemsCoreB")
struct NativeSubsystemsCoreBTests {
    // MARK: - TextBuffer, TextBufferView, EditBuffer, EditorView, Rope, SyntaxStyle

    @Test("SyntaxStyle borrower notifications and style resolution")
    func syntaxStyleAndBorrower() {
        let style = NativeZigSyntaxStyle.SyntaxStyle()
        let borrower = NativeZigSyntaxStyle.Borrower(dependent: .text(42))
        borrower.bind(style)
        #expect(borrower.changes == 1)

        let fg = RGBA.fromInts(120, 200, 255, 255)
        let id = style.registerStyle(name: "keyword", fg: fg, bg: nil, attributes: TextAttributes.bold)
        #expect(borrower.changes == 2)
        #expect(style.resolveByName("keyword") == id)
        #expect(style.resolveById(id)?.fg == fg)
        #expect(style.getStyleByName("keyword")?.attributes == TextAttributes.bold)
        #expect(style.getStyleCount() >= 1)

        borrower.bind(nil)
        #expect(borrower.changes == 3)
    }

    @Test("Generic NativeZigRope insert, split, concat, undo, and redo")
    func nativeZigRopeOperations() {
        var rope = NativeZigRope.Rope<String>(items: ["alpha", "beta"])
        rope.storeUndo(meta: [1, 2])
        rope.append("gamma")
        rope.prepend("zero")
        #expect(rope.toArray() == ["zero", "alpha", "beta", "gamma"])

        let right = rope.split(at: 2)
        #expect(rope.toArray() == ["zero", "alpha"])
        #expect(right.toArray() == ["beta", "gamma"])

        rope.concat(right)
        #expect(rope.slice(start: 1, end: 3) == ["alpha", "beta"])

        #expect(rope.canUndo)
        let restoredMeta = rope.undo(currentMeta: [3, 4])
        #expect(restoredMeta == [1, 2])
        #expect(rope.toArray() == ["alpha", "beta"])
        #expect(rope.canRedo)
        _ = rope.redo()
        #expect(rope.toArray() == ["zero", "alpha", "beta", "gamma"])

        let coreRope = NativeZigRope.makeStringRope("hello\nworld")
        #expect(coreRope.lineCount == 2)
    }

    @Test("UnifiedTextBuffer and UnifiedTextBufferView bridge")
    func textBufferAndViewBridge() throws {
        let tb = NativeZigTextBuffer.UnifiedTextBuffer()
        let viewId = tb.registerView()
        #expect(tb.isViewDirty(viewId))
        tb.clearViewDirty(viewId)
        #expect(!tb.isViewDirty(viewId))

        let memId = tb.memRegistry.register(Array("hello world\nsecond line".utf8))
        try tb.setTextFromMemId(memId)
        #expect(tb.isViewDirty(viewId))
        #expect(tb.getPlainText() == "hello world\nsecond line")
        #expect(tb.getLineCount() == 2)

        let view = NativeZigTextBufferView.UnifiedTextBufferView(buffer: tb)
        view.setWrapMode(.word)
        view.setViewport(NativeZigTextBufferView.Viewport(x: 0, y: 0, width: 20, height: 5))
        view.setSelection(start: 0, end: 5)
        #expect(view.getSelectedText() == "hello")
        #expect(view.getSelection() == NativeZigTextBufferView.SelectionRange(start: 0, end: 5))
        #expect(view.getVirtualLineCount() >= 2)
        #expect(view.virtualLineOutput().virtualLines.count >= 2)

        #expect(NativeZigTextBufferView.alignmentPadCols(alignment: .left, viewportWidth: 20, lineWidthCols: 6) == 0)
        #expect(NativeZigTextBufferView.alignmentPadCols(alignment: .center, viewportWidth: 20, lineWidthCols: 6) == 7)
        #expect(NativeZigTextBufferView.alignmentPadCols(alignment: .right, viewportWidth: 20, lineWidthCols: 6) == 14)
    }

    @Test("EditBuffer and EditorView bridge with notifications")
    func editBufferAndEditorViewBridge() {
        let events = Mutex<[NativeZigEditBuffer.NativeEvent]>([])
        let eb = NativeZigEditBuffer.EditBuffer()
        eb.notify = NativeZigEditBuffer.NativeEventNotify { ev in
            events.withLock { $0.append(ev) }
        }
        eb.setText("hello")
        eb.setCursor(row: 0, col: 5)
        eb.insertText(" swift")
        #expect(eb.getText() == "hello swift")
        #expect(eb.getCursor().col == 11)
        #expect(events.withLock { $0.contains(.contentChanged) && $0.contains(.cursorChanged) })

        let editorView = NativeZigEditorView.EditorView(editBuffer: eb, viewportWidth: 40, viewportHeight: 10)
        #expect(editorView.getText() == "hello swift")
        let vc = editorView.getVisualCursor()
        #expect(vc.logicalRow == 0)
        #expect(vc.logicalCol == 11)
    }

    // MARK: - Audio

    @Test("NativeZigAudio engine, capture buffer, playback, and stream lifecycle")
    func audioSubsystemBridge() throws {
        // CaptureBuffer ring overflow & snapshot
        let cap = NativeZigAudio.CaptureBuffer(sampleRate: 48_000, channels: 2, capacityFrames: 2)
        cap.write([0.1, 0.2, 0.3, 0.4, 0.5, 0.6], frameCount: 3)
        let snap1 = cap.snapshot()
        #expect(snap1.framesReceived == 3)
        #expect(snap1.framesDropped == 1)
        #expect(snap1.bufferedFrames == 2)
        let readSamples = cap.read(frameCount: 2)
        #expect(readSamples.count == 4)
        #expect(readSamples[0] == 0.3)

        // Engine lifecycle
        let engine = NativeZigAudio.create(options: NativeZigAudio.CreateOptions(sampleRate: 48_000, playbackChannels: 2))
        defer { NativeZigAudio.destroy(engine) }

        #expect(NativeZigAudio.start(engine) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.refreshPlaybackDevices(engine) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.refreshCaptureDevices(engine) == NativeZigAudio.Status.ok)
        _ = NativeZigAudio.getPlaybackDeviceCount(engine)
        _ = NativeZigAudio.getCaptureDeviceCount(engine)

        // Load synthesized WAV sound and mix
        let pcm = AudioSynthesizer.generate(waveform: .sine, frequency: 440, duration: 0.02, sampleRate: 48_000, channels: 2, amplitude: 0.5)
        let wav = try WAVCodec.encode(pcm)
        let loaded = NativeZigAudio.load(engine, data: wav)
        #expect(loaded.status == NativeZigAudio.Status.ok)

        let grp = NativeZigAudio.createGroup(engine, name: "sfx")
        #expect(grp.status == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.setGroupVolume(engine, groupId: grp.groupId, volume: 0.8) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.setMasterVolume(engine, volume: 0.9) == NativeZigAudio.Status.ok)

        let played = NativeZigAudio.play(
            engine,
            soundId: loaded.soundId,
            options: NativeZigAudio.VoiceOptions(volume: 1.0, pan: 0.0, loop: false, groupId: grp.groupId)
        )
        #expect(played.status == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.voiceSlotIndex(engine, voiceId: played.voiceId) != nil)

        #expect(NativeZigAudio.enableTap(engine, enabled: true, capacityFrames: 512) == NativeZigAudio.Status.ok)
        let mixed = NativeZigAudio.mixToBuffer(engine, frameCount: 64, channels: 2)
        #expect(mixed.status == NativeZigAudio.Status.ok)
        #expect(mixed.samples.count == 128)
        let tap = NativeZigAudio.readTap(engine, frameCount: 64, channels: 2)
        #expect(tap.status == NativeZigAudio.Status.ok)
        #expect(tap.framesRead > 0)

        // Stream lifecycle
        let streamRes = NativeZigAudio.createStream(engine, options: NativeZigAudio.StreamOptions(format: NativeZigAudio.StreamFormat.pcm))
        #expect(streamRes.status == NativeZigAudio.Status.ok)
        let pcmBytes = PCMConverter.float32ToBytesLE([0.25, -0.25, 0.5, -0.5])
        let wrote = NativeZigAudio.writeStream(engine, streamId: streamRes.streamId, data: pcmBytes)
        #expect(wrote.status == NativeZigAudio.Status.ok)
        #expect(wrote.written == pcmBytes.count)
        let stStats = NativeZigAudio.getStreamStats(engine, streamId: streamRes.streamId)
        #expect(stStats.stats?.framesDecoded == 2)
        #expect(NativeZigAudio.endStream(engine, streamId: streamRes.streamId) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.restartStream(engine, streamId: streamRes.streamId) == NativeZigAudio.Status.ok)
        let closed = NativeZigAudio.closeStream(engine, streamId: streamRes.streamId)
        #expect(closed.status == NativeZigAudio.Status.ok)

        let stats = NativeZigAudio.getStats(engine)
        #expect(stats.status == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.stopVoice(engine, voiceId: played.voiceId) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.unload(engine, soundId: loaded.soundId) == NativeZigAudio.Status.ok)
        #expect(NativeZigAudio.stop(engine) == NativeZigAudio.Status.ok)
    }

    // MARK: - Image & Terminal Image

    @Test("NativeZigImage pipeline and NativeZigTerminalImage Kitty/Sixel encoders")
    func imageAndTerminalImageBridge() throws {
        #expect(NativeZigImage.dimensionsWithinLimits(width: 4, height: 4))
        #expect(!NativeZigImage.dimensionsWithinLimits(width: 0, height: 4))
        #expect(NativeZigImage.Region.inside(NativeZigImage.Region(left: 1, top: 1, width: 2, height: 2), width: 4, height: 4) != nil)
        #expect(NativeZigImage.Region.inside(NativeZigImage.Region(left: 3, top: 1, width: 2, height: 2), width: 4, height: 4) == nil)

        // 2x2 RGBA image
        let pixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 0, 255,
        ]
        let img = try NativeZigImage.createFromRgba(pixels: pixels, width: 2, height: 2, stride: 8)
        #expect(img.width == 2 && img.height == 2)

        let png = try img.ensureEncodedPng()
        let probed = NativeZigImage.probe(png)
        #expect(probed.status == .ok)
        #expect(probed.info.width == 2 && probed.info.height == 2)
        #expect(probed.info.format == .png)

        let decoded = try NativeZigImage.decode(png)
        #expect(decoded.width == 2 && decoded.height == 2)

        let resized = try NativeZigImage.resize(img, width: 4, height: 4, filter: .nearest)
        #expect(resized.width == 4 && resized.height == 4)

        let extracted = try NativeZigImage.extract(resized, left: 1, top: 1, width: 2, height: 2)
        #expect(extracted.width == 2 && extracted.height == 2)

        let extended = try NativeZigImage.extend(extracted, top: 1, right: 1, bottom: 1, left: 1)
        #expect(extended.width == 4 && extended.height == 4)

        let rotated = try NativeZigImage.transform(img, operation: .rotate90)
        #expect(rotated.width == 2 && rotated.height == 2)

        let composited = try NativeZigImage.composite(base: resized, overlay: img, left: 0, top: 0, blend: .sourceOver)
        #expect(composited.width == 4)

        var bgraOut = Array(repeating: UInt8(0), count: 16)
        #expect(NativeZigImage.copyPixels(img, destination: &bgraOut, stride: 8, bgra: true) == .ok)
        #expect(bgraOut[0] == 0 && bgraOut[2] == 255) // red pixel swapped to BGRA

        // Kitty & Sixel encoding
        #expect(NativeZigTerminalImage.kittyPayloadSize(img) == 16)
        let z = NativeZigTerminalImage.kittyPlacementZ(placementId: 7)
        #expect(z < 0 && z >= Int32.min / 2)

        let transmit = NativeZigTerminalImage.writeKittyTransmit(img, id: 10, tmux: false)
        #expect(transmit.contains("\u{1B}_Ga=t"))
        #expect(transmit.contains("i=10"))

        let placement = NativeZigTerminalImage.writeKittyPlacement(id: 10, placementId: 1, x: 2, y: 3, width: 4, height: 2, z: z)
        #expect(placement.contains("\u{1B}[4;3H"))
        #expect(placement.contains("a=p,i=10,p=1"))

        let deletion = NativeZigTerminalImage.writeKittyDelete(id: 10, placementId: 1, freeImage: true)
        #expect(deletion.contains("a=d,d=I,i=10,p=1"))

        let quant = NativeZigTerminalImage.quantizeSixel(img, maxColors: 16)
        #expect(quant.palette.count == 4)
        let sixel = NativeZigTerminalImage.writeSixel(img, tmux: false)
        #expect(sixel.hasPrefix("\u{1B}P") && sixel.contains("q\"1;1;2;2"))
        let tmuxSixel = NativeZigTerminalImage.writeSixel(img, tmux: true)
        #expect(tmuxSixel.hasPrefix("\u{1B}Ptmux;"))
    }

    // MARK: - Video

    @Test("NativeZigVideo latency window, adaptive quality, and player")
    func videoSubsystemBridge() throws {
        var win = NativeZigVideo.LatencyWindow()
        win.add(1000)
        win.add(5000)
        win.add(2500)
        #expect(win.count == 3)
        #expect(win.maximum() == 5000)

        var q = NativeZigVideo.Quality()
        #expect(q.scale() == 1.0)
        for _ in 0..<10 {
            q.sample(costUs: 50_000, intervalUs: 33_333)
        }
        #expect(q.tier == 1)
        #expect(q.scale() == 0.75)

        let frame1 = try NativeZigImage.createFromRgba(pixels: [255, 0, 0, 255], width: 1, height: 1, stride: 4)
        let frame2 = try NativeZigImage.createFromRgba(pixels: [0, 255, 0, 255], width: 1, height: 1, stride: 4)
        let video = NativeZigVideo.Video(path: "clip.mp4", info: NativeZigVideo.Info(durationUs: 1_000_000, width: 1, height: 1))
        video.loadFrames([(0, frame1), (500_000, frame2)])
        let player = NativeZigVideo.Player(video: video)
        player.play()
        player.advance(byUs: 600_000)
        let snap = player.snapshot()
        #expect(snap.playing)
        #expect(snap.hasFrame)
        #expect(snap.framePtsUs == 500_000)
        #expect(player.frame(width: 1, height: 1)?.pixels == frame2.pixels)
    }

    // MARK: - NativeSpanFeed

    @Test("NativeZigSpanFeed write, commit, reserve, drain, and release")
    func spanFeedBridge() {
        let norm = NativeZigSpanFeed.normalizeOptions(NativeZigSpanFeed.Options(chunkSize: 0, initialChunks: 0, spanQueueCapacity: 0))
        #expect(norm.chunkSize == 64 * 1024)
        #expect(norm.initialChunks == 1)
        #expect(norm.spanQueueCapacity == 4096)

        let events = Mutex<[UInt32]>([])
        let stream = NativeZigSpanFeed.createNativeSpanFeedWithAllocator(options: NativeZigSpanFeed.defaultOptions())
        NativeZigSpanFeed.streamSetCallback(stream) { _, eventId, _, _ in
            events.withLock { $0.append(eventId) }
        }
        #expect(NativeZigSpanFeed.attachNativeSpanFeed(stream) == NativeZigSpanFeed.Status.ok)
        #expect(NativeZigSpanFeed.streamWrite(stream, bytes: Array("hello span".utf8)) == NativeZigSpanFeed.Status.ok)
        #expect(NativeZigSpanFeed.streamCommit(stream) == NativeZigSpanFeed.Status.ok)

        let res = NativeZigSpanFeed.streamReserve(stream, minLen: 8)
        #expect(res.status == NativeZigSpanFeed.Status.ok)
        #expect(NativeZigSpanFeed.streamCommitReserved(stream, bytes: Array("reserved".utf8)) == NativeZigSpanFeed.Status.ok)

        let drained = NativeZigSpanFeed.streamDrainSpans(stream, maxSpans: 4)
        #expect(drained.count == 2)
        #expect(stream.readSpan(drained[0]) == Array("hello span".utf8))
        #expect(stream.readSpan(drained[1]) == Array("reserved".utf8))
        for span in drained {
            #expect(NativeZigSpanFeed.streamReleaseSpan(stream, slotIndex: span.slotIndex, releaseId: span.releaseId) == NativeZigSpanFeed.Status.ok)
        }

        let stats = NativeZigSpanFeed.streamGetStats(stream)
        #expect(stats.status == NativeZigSpanFeed.Status.ok)
        #expect(stats.stats?.spansCommitted == 2)
        #expect(NativeZigSpanFeed.streamClose(stream) == NativeZigSpanFeed.Status.ok)
        #expect(NativeZigSpanFeed.destroyNativeSpanFeed(stream) == NativeZigSpanFeed.Status.ok)
        #expect(events.withLock { $0.contains(NativeZigSpanFeed.EventId.dataAvailable.rawValue) && $0.contains(NativeZigSpanFeed.EventId.closed.rawValue) })
    }

    // MARK: - Markdown, Inline, Tables

    @Test("NativeZigMarkdown and NativeZigMarkdownInline parsing and scanners")
    func markdownSubsystems() throws {
        let doc = NativeZigMarkdown.Doc()
        let changes = try doc.write("# Heading\n\nHello **world** `code`\n")
        #expect(!changes.changed.isEmpty)
        #expect(doc.blocks.count >= 2)
        #expect(doc.blocks[0].kind == .heading)
        #expect(doc.blocks[0].payload0 == 1)
        #expect(doc.readLeaf(0)?.bytes == Array("Heading".utf8))

        let defBytes = Array("[ref]: https://example.com\nProse line".utf8)
        let defScan = NativeZigMarkdown.definitionProse(defBytes, from: 0, closed: true)
        #expect(defScan.prose == 27)
        #expect(NativeZigMarkdown.lineContentEnd(Array("abc\ndef".utf8), at: 0) == 3)

        let inlineRes = NativeZigMarkdownInline.parse(content: Array("hi *em* and ` x `".utf8))
        #expect(inlineRes.matches.count == 1)
        #expect(inlineRes.matches[0].kind == .emphasis)
        #expect(NativeZigMarkdownInline.codeSpanBody(Array(" x ".utf8)) == Array("x".utf8))
        #expect(NativeZigMarkdownInline.runLength(Array("###abc".utf8), at: 0, char: UInt8(ascii: "#")) == 3)
        #expect(NativeZigMarkdownInline.isValidLabel(Array("foo".utf8)))
        #expect(!NativeZigMarkdownInline.isValidLabel(Array("   ".utf8)))
        #expect(NativeZigMarkdownInline.extendedLinkStart(Array("see https://example.com".utf8), at: 4))
        #expect(NativeZigMarkdownInline.titleFrom(Array("\"hello\"".utf8), at: 0, from: 0) == .closed(7))

        var htmlCursor = NativeZigMarkdownInline.HtmlResume()
        let htmlEnd = try NativeZigMarkdownInline.scanHtmlTagFrom(Array("<span>hi".utf8), at: 0, final: true, cursor: &htmlCursor)
        #expect(htmlEnd == 6)

        var pendingScan = NativeZigMarkdownInline.PendingScan()
        var pendingOut: [UInt8] = []
        var pendingRuns: [NativeZigMarkdownInline.PendingRun]? = []
        NativeZigMarkdownInline.renderPendingRuns(
            Array("a *b*".utf8),
            from: 0,
            codeOpener: nil,
            scan: &pendingScan,
            out: &pendingOut,
            runs: &pendingRuns
        )
        #expect(String(decoding: pendingOut, as: UTF8.self) == "a b")
        var spans = NativeZigMarkdownInline.PendingSpans()
        spans.resolve(runs: pendingRuns ?? [], displayLength: pendingOut.count)
        #expect(spans.kinds.contains(NativeZigMarkdownInline.kindBit(.emphasis)))

        let foldRun = NativeZigMarkdownTables.FoldRun(start: 0x41, end: 0x5A, step: 1, delta: 32)
        let foldMulti = NativeZigMarkdownTables.FoldMulti(codePoint: 0xDF, folded: [0x73, 0x73, 0])
        #expect(foldRun.delta == 32 && foldMulti.folded[0] == 0x73)
    }

    // MARK: - Yoga & NativeRenderable

    @Test("NativeZigYoga config, node tree, measure callback, and layout")
    func yogaBridge() throws {
        try NativeZigYoga.check(.ok)
        #expect(NativeZigYoga.fromError(.yogaDepthLimit) == .depthLimit)

        let config = YogaConfig.create()
        NativeZigYoga.yogaConfigSetUseWebDefaults(config, false)
        NativeZigYoga.yogaConfigSetPointScaleFactor(config, 1.0)
        NativeZigYoga.yogaConfigSetErrata(config, 0)
        #expect(NativeZigYoga.yogaConfigGetErrata(config) == 0)

        let root = YogaNode.createWithConfig(config)
        let child = YogaNode.createWithConfig(config)
        root.setWidth(Float(40))
        root.setHeight(Float(20))
        root.setAlignItems(.flexStart)
        NativeZigYoga.yogaNodeStyleSetBorder(root, edge: UInt32(Edge.all.rawValue), border: 1)
        #expect(NativeZigYoga.yogaNodeStyleGetBorder(root, edge: UInt32(Edge.all.rawValue)) == 1)

        let status = NativeZigYoga.yogaNodeSetNativeMeasureFunc(child, callback: { _, _, _, _ in
            NativeZigYoga.ExternalYogaSize(width: 12, height: 3)
        })
        #expect(status == .ok)
        #expect(NativeZigYoga.yogaNodeHasContext(child))

        root.insertChild(child, 0)
        #expect(NativeZigYoga.yogaNodeGetChildCount(root) == 1)
        #expect(NativeZigYoga.yogaNodeGetChild(root, index: 0) === child)

        root.calculateLayout(40, 20, .ltr)
        let checked = NativeZigYoga.yogaNodeGetLayoutChecked(child)
        #expect(checked.status == .ok)
        #expect(checked.layout?.width == 12)
        #expect(checked.layout?.height == 3)
        #expect(NativeZigYoga.yogaNodeLayoutGetEdge(root, kind: 2, edge: UInt32(Edge.left.rawValue)) == 1)

        #expect(NativeZigRenderable.normalizeYogaMeasureWidthInput(value: .nan, widthMode: 1) == 0)
        #expect(NativeZigRenderable.normalizeYogaMeasureHeightInput(value: .nan) == 1)
        #expect(NativeZigRenderable.measureCells(9.99995) == 10)
        #expect(NativeZigRenderable.measureCells(9.4) == 9)
    }

    // MARK: - Scene, SceneRecord, Session

    @Test("NativeZigScene hit testing, sliderThumb, layouts, and SceneRecord playback")
    func sceneAndSceneRecordBridge() throws {
        let hits = [
            NativeZigScene.Hit(x: 0, y: 0, width: 10, height: 10, token: 1, num: 1),
            NativeZigScene.Hit(x: 2, y: 2, width: 5, height: 5, token: 2, num: 2),
        ]
        #expect(NativeZigScene.topmostHit(hits, x: 3, y: 3) == 1)
        #expect(NativeZigScene.topmostHitExcept(hits, x: 3, y: 3, excluded: 2) == 0)

        let thumb = try NativeZigScene.sliderThumb(
            NativeZigScene.SliderOptions(min: 0, max: 100, value: 50, viewportSize: 20, orientation: 0),
            width: 20,
            height: 1
        )
        #expect(thumb.size > 0 && thumb.start > 0)

        let layout = NativeZigScene.Layout(width: 20, height: 10, screenX: 5, screenY: 4, content: [2, 1, 16, 8])
        let content = NativeZigScene.contentLayout(layout)
        #expect(content.screenX == 7 && content.screenY == 5 && content.width == 16 && content.height == 8)
        let offset = NativeZigScene.contentOffset(layout)
        #expect(offset == (2, 1))

        // SceneRecord encode -> index -> fingerprint -> play
        var payload: [UInt8] = []
        for v: UInt32 in [1, 1, 3, 2] {
            payload.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        payload.append(contentsOf: [10, 20, 30, 255])
        let packet = NativeZigSceneRecord.encodePacket(slot: 0, phase: 1, command: .draw, payload: payload)
        var segments: [NativeZigSceneRecord.Segments] = []
        try NativeZigSceneRecord.index(bytes: packet, slotCount: 1, segments: &segments)

        let renderable = NativeZigRenderable.NativeRenderable()
        let fp = NativeZigSceneRecord.fingerprint(member: renderable, bytes: packet, segments: segments[0], hooks: 0, frameId: 1)
        #expect(fp.digest != 0)

        let buf = OptimizedBuffer(width: 8, height: 6)
        try NativeZigSceneRecord.play(target: buf, bytes: packet, segment: segments[0].selfSegment)
        #expect(buf.bg[1 * 8 + 1] == RGBA.fromInts(10, 20, 30, 255))
    }

    @Test("NativeZigSession lifecycle, output tickets, and input feed")
    func sessionBridge() throws {
        let session = try NativeZigSession.Session()
        try session.setupTerminal(NativeZigSession.TerminalOptions(useAlternateScreen: false))
        #expect(session.terminalState.phase == .active)

        let feed = session.feedInput(Array("abc".utf8))
        #expect(feed.consumed == 3)

        let ticket = try session.postOutput(Array("frame".utf8))
        #expect(session.pump().status == .outputPending)
        let post = try session.completeOutput(ticket: ticket, result: .written)
        #expect(post.written == 5)
        #expect(session.completedBytes == 5)
        #expect(session.pump().status == .idle)

        session.close()
        #expect(session.state == .closed)
        #expect(session.pump().status == .closed)
    }

    // MARK: - Embedded Terminal, Ghostty VT, Compositor, Unavailable

    @Test("NativeZigEmbeddedTerminal VT stream, selection, compositor, and unavailable stub")
    func embeddedTerminalAndCompositor() throws {
        let term = try NativeZigEmbeddedTerminal.EmbeddedTerminal(
            options: NativeZigEmbeddedTerminal.Options(cols: 12, rows: 4)
        )
        try term.write("Hello\r\nWorld\u{1B}[c")
        #expect(term.cursor().x == 5 && term.cursor().y == 1)

        let replies = term.drainResponses()
        #expect(String(decoding: replies, as: UTF8.self).contains("\u{1B}[?62"))

        term.setSelection(
            start: NativeZigGhostty.Coordinate(x: 0, y: 0),
            end: NativeZigGhostty.Coordinate(x: 4, y: 0)
        )
        #expect(term.selectedText() == "Hello")

        let target = OptimizedBuffer(width: 12, height: 4)
        try term.compose(into: target, originX: 0, originY: 0)
        #expect(target.chars[0] == UInt32(UnicodeScalar("H").value))
        #expect(target.chars[12] == UInt32(UnicodeScalar("W").value))

        // Ghostty key/mouse/paste/focus encoders
        #expect(NativeZigGhostty.encodeKey(NativeZigGhostty.Key(keyName: "up")) == Array("\u{1B}[A".utf8))
        #expect(NativeZigGhostty.encodePaste(Array("hi".utf8), bracketed: true) == Array("\u{1B}[200~hi\u{1B}[201~".utf8))
        #expect(NativeZigGhostty.encodeFocus(true) == Array("\u{1B}[I".utf8))
        let mouseEnc = NativeZigGhostty.encodeMouse(NativeZigGhostty.Mouse(action: .press, button: 0, x: 2, y: 3))
        #expect(String(decoding: mouseEnc, as: UTF8.self) == "\u{1B}[<0;3;4M")

        // Unavailable stub always throws .unsupported
        #expect(throws: NativeZigEmbeddedUnavailable.Error.unsupported) {
            _ = try NativeZigEmbeddedUnavailable.EmbeddedTerminal.create()
        }
    }
}
