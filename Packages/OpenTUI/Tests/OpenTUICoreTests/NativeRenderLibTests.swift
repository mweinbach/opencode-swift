import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// MARK: - NativeABI Tests

@Suite("NativeABI")
struct NativeABITests {
    @Test("ABI constants and collection sizes match upstream native-abi.generated.ts")
    func abiConstantsAndTables() {
        #expect(NativeABI.OT_CONTEXT_ABI_VERSION == 2)
        #expect(NativeABI.OT_OK == 0)
        #expect(NativeABI.OT_INVALID_ARGUMENT == -1)
        #expect(NativeABI.OT_STALE_HANDLE == -9)
        #expect(NativeABI.OT_IMAGE_UNSUPPORTED_FORMAT == -40)
        #expect(NativeABI.OT_VIDEO_FAILED == -60)
        #expect(NativeABI.OT_SCENE_ROOT == 0)
        #expect(NativeABI.OT_SCENE_BOX == 1)
        #expect(NativeABI.OT_BORDER_ALL == 15)

        // Verify 32-bit unsigned high-bit constants preserved losslessly in Int64
        #expect(NativeABI.OT_MOUSE_POINTER_UNCHANGED == 4_294_967_295)
        #expect(NativeABI.OT_EDIT_MARK_ANY_KIND == 4_294_967_295)
        #expect(NativeABI.OT_CELL_CHAR_GRAPHEME == 2_147_483_648)
        #expect(NativeABI.OT_CELL_CHAR_CONTINUATION == 3_221_225_472)

        // Verify full generated tables
        #expect(NativeABI.nativeConstants.count == 855)
        #expect(NativeABI.nativeSymbols.count == 292)
        #expect(NativeABI.nativeCallbacks.count == 3)
        #expect(NativeABI.nativeLayouts.count == 101)
        #expect(NativeABI.nativeConstants["OT_CONTEXT_ABI_VERSION"] == 2)
        #expect(NativeABI.nativeSymbols["ot_scene_create_node"]?.returns == "i32")
        #expect(NativeABI.nativeCallbacks["ot_edit_event_callback"]?.args == ["u64", "u32", "u32", "u32"])
    }

    @Test("Struct layout sizes and field offsets match opentui.h ABI")
    func abiLayoutMetadata() {
        #expect(NativeABI.nativeLayouts["ot_handle"]?.size == ZigHandle.byteSize)
        #expect(NativeABI.nativeLayouts["ot_handle"]?.fields["slot"]?.offset == 8)
        #expect(NativeABI.nativeLayouts["ot_styled_text_chunk"]?.size == ZigTextChunk.byteSize)
        #expect(NativeABI.nativeLayouts["ot_scene_text_line"]?.size == ZigLineInfo.byteSize)
        #expect(NativeABI.nativeLayouts["ot_scene_cursor_state"]?.size == ZigCursorState.byteSize)
        #expect(NativeABI.nativeLayouts["ot_scene_scroll_bar_state"]?.size == ZigScrollBarState.byteSize)
        #expect(NativeABI.nativeLayouts["ot_scene_scroll_state"]?.size == ZigScrollState.byteSize)
        #expect(NativeABI.nativeLayouts["ot_edit_highlight"]?.size == ZigHighlight.byteSize)
        #expect(NativeABI.nativeLayouts["ot_edit_position"]?.size == ZigLogicalCursor.byteSize)
        #expect(NativeABI.nativeLayouts["ot_editor_position"]?.size == ZigVisualCursor.byteSize)
        #expect(NativeABI.nativeLayouts["ot_editor_measure"]?.size == ZigMeasuredSize.byteSize)
    }
}

// MARK: - ZigStructs & FFI Tests

@Suite("ZigStructs")
struct ZigStructsTests {
    @Test("All core/src/zig-structs.ts codecs round-trip little-endian binary buffers")
    func zigStructsRoundTrip() throws {
        let buildOpts = BuildOptions(gpaSafeStats: true, gpaMemoryLimitTracking: false)
        let buildBytes = BuildOptionsStruct.pack(buildOpts)
        #expect(buildBytes == [1, 0])
        #expect(try BuildOptionsStruct.unpack(buildBytes) == buildOpts)

        let allocStats = AllocatorStats(
            totalRequestedBytes: 1_048_576,
            activeAllocations: 42,
            smallAllocations: 40,
            largeAllocations: 2,
            requestedBytesValid: true
        )
        let allocBytes = AllocatorStatsStruct.pack(allocStats)
        #expect(allocBytes.count == 40)
        #expect(try AllocatorStatsStruct.unpack(allocBytes) == allocStats)

        let feedOpts = ZigNativeSpanFeedOptions(
            chunkSize: 32_768,
            initialChunks: 4,
            maxBytes: 2_097_152,
            growthPolicy: .block,
            autoCommitOnFull: false,
            spanQueueCapacity: 128
        )
        let feedOptBytes = NativeSpanFeedOptionsStruct.pack(feedOpts)
        #expect(feedOptBytes.count == 24)
        #expect(try NativeSpanFeedOptionsStruct.unpack(feedOptBytes) == feedOpts)

        let feedStats = ZigNativeSpanFeedStats(
            bytesWritten: 9_000,
            spansCommitted: 15,
            chunks: 3,
            pendingSpans: 2,
            outstandingSpans: 1,
            outstandingBytes: 512
        )
        #expect(try NativeSpanFeedStatsStruct.unpack(NativeSpanFeedStatsStruct.pack(feedStats)) == feedStats)

        let spanInfo = ZigSpanInfo(
            chunkPtr: FFIPointer(address: 0x1000_2000),
            offset: 64,
            len: 256,
            chunkIndex: 1,
            slotIndex: 7,
            releaseId: 99
        )
        #expect(try SpanInfoStruct.unpack(SpanInfoStruct.pack(spanInfo)) == spanInfo)

        let reserve = ReserveInfo(ptr: FFIPointer(address: 0x2000_0000), len: 4096)
        #expect(try ReserveInfoStruct.unpack(ReserveInfoStruct.pack(reserve)) == reserve)

        let audioCreate = AudioCreateOptions(sampleRate: 44_100, playbackChannels: 2)
        #expect(try AudioCreateOptionsStruct.unpack(AudioCreateOptionsStruct.pack(audioCreate)) == audioCreate)

        let audioStart = ZigAudioStartOptions(periodSizeInFrames: 256, periods: 3, noClip: true, alsaNoMMap: true)
        #expect(try AudioStartOptionsStruct.unpack(AudioStartOptionsStruct.pack(audioStart)) == audioStart)

        let voice = AudioVoiceOptions(volume: 0.75, pan: -0.25, loop: true, groupId: 5)
        #expect(try AudioVoiceOptionsStruct.unpack(AudioVoiceOptionsStruct.pack(voice)) == voice)

        let streamOpts = AudioStreamCreateOptions(
            capacityMs: 4000,
            startupMs: 500,
            resumeMs: 250,
            volume: 0.9,
            pan: 0.1,
            groupId: 2,
            maxProbeBytes: 8192,
            format: .flac,
            sampleRate: 48_000,
            channels: 2
        )
        #expect(try AudioStreamCreateOptionsStruct.unpack(AudioStreamCreateOptionsStruct.pack(streamOpts)) == streamOpts)

        let streamStats = NativeAudioStreamStats(
            bytesReceived: 120_000,
            framesDecoded: 30_000,
            framesPlayed: 28_000,
            state: NativeAudioStreamState.playing.rawValue,
            sampleRate: 48_000,
            channels: 2,
            bufferedFrames: 2000,
            capacityFrames: 96_000,
            underruns: 1,
            errorCode: -2,
            readyGeneration: 3
        )
        #expect(try AudioStreamStatsStruct.unpack(AudioStreamStatsStruct.pack(streamStats)) == streamStats)

        let captureStats = NativeAudioCaptureStats(
            framesReceived: 5000,
            framesRead: 4500,
            framesDropped: 12,
            sampleRate: 16_000,
            channels: 1,
            bufferedFrames: 500,
            capacityFrames: 8192
        )
        #expect(try AudioCaptureStatsStruct.unpack(AudioCaptureStatsStruct.pack(captureStats)) == captureStats)

        let audioStats = ZigAudioStats(
            soundsLoaded: 4,
            voicesActive: 2,
            framesMixed: 102_400,
            lockMisses: 0,
            lastPeak: 0.5,
            lastRms: 0.25
        )
        #expect(try AudioStatsStruct.unpack(AudioStatsStruct.pack(audioStats)) == audioStats)

        let imgInfo = NativeImageInfo(
            width: 320,
            height: 240,
            sourceWidth: 640,
            sourceHeight: 480,
            format: 1,
            colorStatus: 0,
            orientation: 1,
            hasAlpha: 1
        )
        #expect(try NativeImageInfo.unpack(imgInfo.pack()) == imgInfo)
    }

    @Test("C-ABI scene/editor/text Zig* structs round-trip exact layout byte sizes")
    func zigLayoutStructsRoundTrip() throws {
        let handle = ZigHandle(contextId: 42, slot: 7, generation: 3)
        #expect(try ZigHandle.unpack(handle.pack()) == handle)

        let scroll = ZigScrollState(
            stuck: 1,
            changes: 3,
            generation: 11,
            offsetX: 12.5,
            offsetY: 44.0,
            maxX: 100.0,
            maxY: 200.0,
            content: ZigSceneRect(x: 0, y: 0, width: 120, height: 240),
            viewport: ZigSceneRect(x: 1, y: 2, width: 80, height: 24),
            horizontalBar: ZigScrollBarState(visible: true, thumbStart: 4, thumbSize: 20),
            verticalBar: ZigScrollBarState(visible: true, thumbStart: 8, thumbSize: 10)
        )
        let scrollBytes = scroll.pack()
        #expect(scrollBytes.count == 360)
        #expect(try ZigScrollState.unpack(scrollBytes) == scroll)

        let cursor = ZigCursorState(x: 10, y: 5, visible: true, style: 2, blinking: true, r: 0.5, g: 0.25, b: 1.0, a: 1.0)
        #expect(try ZigCursorState.unpack(cursor.pack()) == cursor)

        let lineInfo = ZigLineInfo(startCols: 0, widthCols: 42, sourceLine: 3, wrapIndex: 1)
        #expect(try ZigLineInfo.unpack(lineInfo.pack()) == lineInfo)

        let visual = ZigVisualCursor(visualRow: 2, visualCol: 5, logicalRow: 10, logicalCol: 5, offset: 120)
        #expect(try ZigVisualCursor.unpack(visual.pack()) == visual)

        let logical = ZigLogicalCursor(valid: true, row: 10, col: 5, offset: 120)
        #expect(try ZigLogicalCursor.unpack(logical.pack()) == logical)

        let hl = ZigHighlight(start: 4, end: 12, styleId: 7, priority: 2, ref: 1)
        #expect(try ZigHighlight.unpack(hl.pack()) == hl)

        let measured = ZigMeasuredSize(lineCount: 12, widthColsMax: 78)
        #expect(try ZigMeasuredSize.unpack(measured.pack()) == measured)

        let chunk = ZigTextChunk(
            byteCount: 11,
            flags: 7,
            foreground: RGBA.fromInts(255, 128, 64, 255),
            background: RGBA.fromInts(10, 20, 30, 255),
            attributes: TextAttributes.bold,
            linkOffset: 0,
            linkByteCount: 18
        )
        #expect(try ZigTextChunk.unpack(chunk.pack()) == chunk)

        #expect(throws: ZigStructError.bufferTooSmall(expected: 16, actual: 4)) {
            _ = try ZigHandle.unpack([0, 1, 2, 3])
        }
    }

    @Test("Pure-Swift FFI adapter pointer, buffer, and library/callback lifecycle")
    func portableFFIAdapter() throws {
        #expect(ffiBool(true) == 1)
        #expect(ffiBool(false) == 0)
        #expect(trimNodeFFIOutputBytes([1, 2, 3, 4, 5], length: 3) == [1, 2, 3])
        #expect(try toPointer(.int(4096)).address == 4096)

        #expect(throws: FFIError.invalidPointer(POINTER_NEGATIVE)) {
            _ = try toPointer(.int(-1))
        }

        let runtime = SwiftFFIRuntime()
        let p = runtime.pinBuffer([10, 20, 30, 40])
        #expect(try runtime.readBytes(pointer: p, offset: 1, length: 2) == [20, 30])
        runtime.releaseBuffer(at: p)

        let bun = createBunBackend(runtime: runtime)
        #expect(throws: FFIError.unsupported(BUN_DLOPEN_NULL)) {
            _ = try bun.dlopen(nil, symbols: [:])
        }

        let node = createNodeBackend(runtime: runtime)
        let lib = try node.dlopen("libopentui.\(node.suffix)", symbols: [:])
        #expect(throws: FFIError.unsupported(NODE_CALLBACK_THREADSAFE)) {
            _ = try lib.createCallback({ _ in 0 }, definition: FFIFunction(threadsafe: true))
        }
        let cb = try lib.createCallback({ _ in 42 }, definition: FFIFunction(args: [.i32], returns: .i32))
        #expect(cb.ptr != nil)
        lib.close()
        #expect(cb.isClosed)
        #expect(cb.ptr == nil)
        #expect(throws: FFIError.libraryClosed(LIBRARY_CLOSED)) {
            _ = try lib.createCallback({ _ in 0 })
        }
    }
}

// MARK: - SwiftRenderLib / NativeRenderLib Tests

@Suite("SwiftRenderLib")
struct NativeRenderLibTests {
    @Test("Buffer creation, drawing, box, stack, leases, and unicode rendering")
    func bufferDrawingAndLeases() throws {
        let lib = createRenderLib()
        defer { lib.dispose() }

        let ctx = try lib.createContext()
        let buf = try lib.createOptimizedBuffer(ctx, width: 20, height: 5)
        let target: NativeDrawingTarget = .buffer(context: ctx, target: buf)

        try lib.bufferClear(ctx, buffer: buf, background: RGBA.fromInts(0, 0, 0, 255))
        try lib.bufferDrawBox(ctx, buffer: buf, x: 0, y: 0, width: 20, height: 5, title: "Demo")
        try lib.bufferDrawText(ctx, buffer: buf, text: "Hello Swift", x: 2, y: 2)

        let text = try lib.bufferPlainText(ctx, buffer: buf)
        #expect(text.contains("Demo"))
        #expect(text.contains("Hello Swift"))

        let uni = try lib.createContextUnicode(ctx, text: "OK")
        #expect(try lib.getContextUnicode(ctx, handle: uni) == "OK")
        try lib.contextBufferDrawUnicode(target, unicode: uni, x: 2, y: 3)
        #expect(try lib.bufferPlainText(ctx, buffer: buf).contains("OK"))
        lib.destroyContextUnicode(ctx, handle: uni)

        let op = try lib.contextBufferStack(target, op: .pushOpacity(0.5))
        #expect(op == 0.5)
        #expect(try lib.contextBufferStack(target, op: .popOpacity) == 1.0)

        let lease = try lib.contextAcquireBufferLease(ctx, buffer: buf)
        #expect(try lib.contextValidateBufferLease(ctx, lease: lease))
        let byteSize = try lib.contextBufferLeaseGetRealCharSize(ctx, lease: lease, addLineBreaks: true)
        let resolved = try lib.contextBufferLeaseWriteResolvedChars(ctx, lease: lease, addLineBreaks: true)
        #expect(byteSize == resolved.count)
        #expect(byteSize > 0)
        lib.contextReleaseBufferLease(ctx, lease: lease)
        #expect(try lib.contextValidateBufferLease(ctx, lease: lease) == false)

        lib.destroyContextBuffer(ctx, buffer: buf)
        lib.destroyContext(ctx)
    }

    @Test("TextBuffer, EditBuffer, EditorView, and SyntaxStyle execute on real Swift engine")
    func textEditAndSyntaxStyle() throws {
        let lib = createRenderLib()
        defer { lib.dispose() }

        let ctx = try lib.createContext()

        // SyntaxStyle registration & lookup
        let style = try lib.createSyntaxStyle(ctx)
        let kwId = try lib.registerSyntaxStyle(
            ctx,
            style: style,
            name: "keyword",
            definition: NativeEditorStyle(fg: RGBA.fromInts(255, 100, 50, 255), attributes: TextAttributes.bold)
        )
        #expect(kwId > 0)
        #expect(try lib.contextSyntaxStyleResolveByName(ctx, style: style, name: "keyword") == kwId)
        #expect(try lib.contextSyntaxStyleGetStyleCount(ctx, style: style) == 1)

        // TextBuffer + TextBufferView
        let tb = try lib.createTextBuffer(ctx)
        try lib.textBufferSetText(ctx, textBuffer: tb, text: "Alpha\nBeta")
        try lib.contextTextBufferAppend(ctx, textBuffer: tb, text: "\nGamma")
        try lib.contextTextBufferSetSyntaxStyle(ctx, textBuffer: tb, style: style)
        #expect(try lib.contextTextBufferGetText(ctx, textBuffer: tb) == "Alpha\nBeta\nGamma")
        let tbInfo = try lib.contextTextBufferGetInfo(ctx, textBuffer: tb)
        #expect(tbInfo.lineCount == 3)

        let tbView = try lib.createContextTextBufferView(ctx, textBuffer: tb)
        try lib.contextTextBufferViewSetViewport(ctx, view: tbView, x: 0, y: 0, width: 40, height: 10)
        let measured = try lib.contextTextBufferViewMeasure(ctx, view: tbView, width: 40, height: 10)
        #expect(measured.lineCount == 3)

        // EditBuffer + EditorView + Extmarks + Undo/Redo
        let eb = try lib.createEditBuffer(ctx)
        try lib.editBufferInsertText(ctx, editBuffer: eb, text: "let x = 1\nlet y = 2")
        #expect(try lib.contextEditBufferGetText(ctx, editBuffer: eb) == "let x = 1\nlet y = 2")

        let markId = try lib.contextEditBufferMark(
            ctx,
            editBuffer: eb,
            operation: .add,
            mark: NativeEditMark(id: 0, kind: 1, atomic: true, style: kwId, priority: 1, start: 0, end: 3)
        )
        #expect(markId > 0)
        #expect(try lib.contextEditBufferGetMarks(ctx, editBuffer: eb).count == 1)

        let ev = try lib.createEditorView(ctx, editBuffer: eb, width: 40, height: 10)
        _ = try lib.contextEditorViewSelect(
            ctx,
            view: ev,
            selection: NativeEditorSelection(operation: .set, start: 0, end: 3)
        )
        #expect(try lib.contextEditorViewGetSelectedText(ctx, view: ev) == "let")
        let repl = try lib.contextEditorViewReplaceSelection(ctx, view: ev, text: "var")
        #expect(repl.deleted && repl.inserted)
        #expect(try lib.contextEditBufferGetText(ctx, editBuffer: eb).hasPrefix("var x = 1"))

        let buf = try lib.createOptimizedBuffer(ctx, width: 30, height: 5)
        try lib.contextDrawEditorView(.buffer(context: ctx, target: buf), view: ev, x: 0, y: 0)
        #expect(try lib.bufferPlainText(ctx, buffer: buf).contains("var x = 1"))

        lib.destroyContextEditorView(ctx, view: ev)
        lib.destroyContextEditBuffer(ctx, editBuffer: eb)
        lib.destroyContextTextBufferView(ctx, view: tbView)
        lib.destroyContextTextBuffer(ctx, textBuffer: tb)
        lib.destroyContextSyntaxStyle(ctx, style: style)
        lib.destroyContext(ctx)
    }

    @Test("Scene, SceneStaging, NativePaintRecorder, Session, and subsystems lifecycle")
    func sceneSessionAndSubsystems() throws {
        let lib = createRenderLib()
        defer { lib.dispose() }

        let (ctx, session) = try lib.createRenderer(width: 40, height: 12)
        let root = try lib.sceneCreate(ctx)
        let child = try lib.sceneCreateNode(ctx, kind: UInt32(NativeABI.OT_SCENE_TEXT), num: 2)
        try lib.sceneMoveNode(ctx, child: child, parent: root, index: 0)
        try lib.sceneSetText(ctx, node: child, text: "Scene Hello")
        #expect(try lib.sceneGetText(ctx, node: child) == "Scene Hello")

        // SceneStaging + flush
        let staging = try SceneStaging()
        try staging.stageBackground(context: ctx, node: root, color: RGBA.fromInts(10, 20, 30, 255))
        try staging.stageStyle(
            context: ctx,
            node: root,
            group: UInt32(NativeABI.OT_STYLE_VALUE),
            kind: UInt32(NativeABI.OT_STYLE_VALUE_WIDTH),
            edge: 0,
            unit: UInt32(NativeABI.OT_UNIT_POINT),
            value: 40,
            flags: 0
        )
        #expect(staging.pending && staging.count == 2)
        let applied = try lib.sceneFlush(ctx, staging: staging)
        #expect(applied == 2)
        #expect(!staging.pending)

        // NativePaintRecorder
        let recorder = NativePaintRecorder()
        recorder.begin()
        recorder.slot(node: root, phase: .self, opacity: 0.8)
        recorder.draw(.clear(background: RGBA.fromInts(0, 0, 0, 255)))
        #expect(recorder.stack(.pushOpacity(0.5)) == 0.4)
        let recorded = recorder.end()
        #expect(recorded.count == 3)

        // Scene frame step & commit
        let frame = try lib.sceneFrameStep(ctx, session: session, root: root)
        let status = try lib.sceneFrameCommit(ctx, frame: frame, force: true)
        #expect(status == .presented || status == .skipped)

        // Session links & output
        let linkId = try lib.sessionGetLinkId(ctx, session: session, url: "https://opencode.ai")
        #expect(try lib.contextGetLinkUrl(ctx, linkId: linkId) == "https://opencode.ai")

        // Markdown
        let md = try lib.markdownCreate(ctx)
        let mdRes = try lib.markdownWrite(ctx, markdown: md, text: "# Heading\n\nParagraph")
        #expect(mdRes.changed > 0)
        #expect(try lib.markdownGetSource(ctx, markdown: md) == "# Heading\n\nParagraph")
        lib.markdownDestroy(ctx, markdown: md)

        // Embedded terminal
        let term = try lib.createContextEmbeddedTerminal(ctx, cols: 20, rows: 5)
        try lib.contextEmbeddedTerminalWrite(ctx, terminal: term, bytes: Array("prompt> hi".utf8))
        try lib.contextEmbeddedTerminalSetSelection(ctx, terminal: term, startX: 0, startY: 0, endX: 6, endY: 0)
        #expect(try lib.contextEmbeddedTerminalGetSelectedText(ctx, terminal: term) == "prompt")
        lib.destroyContextEmbeddedTerminal(ctx, terminal: term)

        // Clipboard
        let clipSvc = lib.clipboardServiceCreate()
        let writeOp = lib.clipboardWriteOperationStart(clipSvc, mime: "text/plain", data: Array("copied".utf8))
        #expect(writeOp.status == .ok)
        let readOp = lib.clipboardReadOperationStart(clipSvc)
        #expect(readOp.status == .ok)
        if let opHandle = readOp.operation {
            let len = lib.clipboardOperationResultDataLength(opHandle)
            var out = Array(repeating: UInt8(0), count: len)
            #expect(lib.clipboardOperationResultDataCopy(opHandle, into: &out) == .ok)
            #expect(String(decoding: out, as: UTF8.self) == "copied")
            #expect(lib.clipboardOperationDestroy(opHandle) == .destroyed)
        }
        #expect(lib.clipboardServiceDestroy(clipSvc) == .destroyed)

        // Yoga
        let yNode = lib.yogaNodeCreateForOpenTUI()
        lib.yogaNodeStyleSetValue(yNode, kind: 0, edge: 0, unit: .point, value: 50)
        lib.yogaNodeStyleSetValue(yNode, kind: 1, edge: 0, unit: .point, value: 10)
        lib.yogaNodeCalculateLayout(yNode, width: 80, height: 24)
        let yLayout = lib.yogaNodeGetComputedLayout(yNode)
        #expect(yLayout.width == 50 && yLayout.height == 10)
        lib.yogaNodeFree(yNode)

        // Audio
        let audio = lib.createAudioEngine(AudioCreateOptions(sampleRate: 48_000, playbackChannels: 2))
        #expect(lib.audioStart(audio))
        let groupId = lib.audioCreateGroup(audio, name: "sfx")
        #expect(groupId > 0)
        let streamId = lib.audioCreateStream(audio, options: AudioStreamCreateOptions(format: .pcm))
        #expect(lib.audioWriteStream(audio, streamId: streamId, data: [0, 0, 1, 0, 2, 0, 3, 0]) == 8)
        #expect(lib.audioGetStreamStats(audio, streamId: streamId)?.bytesReceived == 8)
        #expect(lib.audioCloseStream(audio, streamId: streamId))
        lib.destroyAudioEngine(audio)

        // SpanFeed
        let feed = lib.createNativeSpanFeed(ZigNativeSpanFeedOptions(chunkSize: 1024, initialChunks: 1))
        _ = try lib.streamWrite(feed, bytes: Array("span-payload".utf8))
        let spans = lib.streamDrainSpans(feed)
        #expect(spans.count == 1)
        #expect(spans[0].len == 12)
        lib.destroyNativeSpanFeed(feed)

        // Image
        let rgbaPixels: [UInt8] = [
            255, 0, 0, 255,  0, 255, 0, 255,
            0, 0, 255, 255,  255, 255, 255, 255,
        ]
        let img = try lib.imageCreateFromRgba(ctx, pixels: rgbaPixels, width: 2, height: 2)
        let imgInfo = try lib.imageGetInfo(ctx, image: img)
        #expect(imgInfo.width == 2 && imgInfo.height == 2)
        let png = try lib.imageCopyPng(ctx, image: img)
        #expect(png.count > 8)
        lib.imageDestroy(ctx, image: img)

        // Cleanup & singleton resolution
        lib.destroyRenderer(context: ctx, session: session)
        setRenderLib(lib)
        #expect(resolveRenderLib() === lib)
        setRenderLib(nil)
    }
}
