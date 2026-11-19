import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization

// MARK: - 1. NativeContextHandleTable Tests

@Suite("NativeContextABI.HandleTable")
struct NativeContextHandleTableTests {
    @Test("Slot allocation, lookup, generation reuse, and capacity enforcement")
    func handleLifecycleAndReuse() throws {
        let table = NativeContextHandleTable.Table(contextId: 42, capacity: 2)
        #expect(NativeContextHandleTable.slotCountMaxDefault == (1 << 22))
        #expect(table.capacity == 2)
        #expect(table.activeCount == 0)

        let h1 = try table.allocate(kind: .buffer)
        let h2 = try table.allocate(kind: .textBuffer)
        #expect(h1.contextId == 42)
        #expect(h1.slot == 1)
        #expect(h1.generation == 1)
        #expect(h2.slot == 2)
        #expect(table.activeCount == 2)

        // Capacity limit enforced
        #expect(throws: NativeContextHandleTable.TableError.objectLimit) {
            _ = try table.allocate(kind: .sceneNode)
        }
        #expect(NativeContextHandleTable.TableError.objectLimit.abiStatus == Int32(NativeABI.OT_OBJECT_LIMIT))

        // Lookup checks context and kind
        #expect(try table.lookup(h1, expectedKind: .buffer) == .buffer)
        #expect(throws: NativeContextHandleTable.TableError.wrongKind) {
            _ = try table.lookup(h1, expectedKind: .session)
        }
        let foreign = NativeContextHandleTable.Handle(contextId: 999, slot: h1.slot, generation: h1.generation)
        #expect(throws: NativeContextHandleTable.TableError.wrongContext) {
            _ = try table.lookup(foreign, expectedKind: .buffer)
        }

        // Two-phase destroy + cancel
        let cancelToken = try table.beginDestroy(h1, expectedKind: .buffer)
        #expect(throws: NativeContextHandleTable.TableError.staleHandle) {
            _ = try table.lookup(h1, expectedKind: .buffer)
        }
        table.cancelDestroy(cancelToken)
        #expect(try table.lookup(h1, expectedKind: .buffer) == .buffer)

        // Complete destroy bumps generation and pushes slot onto free list
        let token = try table.beginDestroy(h1, expectedKind: .buffer)
        table.finishDestroy(token)
        #expect(table.activeCount == 1)
        #expect(table.freeSlotCount == 1)
        #expect(table.generation(at: h1.slot) == 2)
        #expect(throws: NativeContextHandleTable.TableError.staleHandle) {
            _ = try table.lookup(h1, expectedKind: .buffer)
        }

        // Re-allocation reuses slot 1 with generation 2
        let h3 = try table.allocate(kind: .markdown)
        #expect(h3.slot == 1)
        #expect(h3.generation == 2)
        #expect(try table.lookup(h3, expectedKind: .markdown) == .markdown)

        // ZigHandle round-trip
        let zig = NativeContextABI.handleToC(h3)
        #expect(NativeContextABI.handleFromC(zig) == h3)
    }
}

// MARK: - 2. Context Lifecycle, Diagnostics, Buffer & Unicode ABI Tests

@Suite("NativeContextABI.ContextBufferUnicode")
struct NativeContextABIBufferTests {
    @Test("Context creation, version checks, diagnostics, and destroy")
    func contextLifecycleAndDiagnostics() throws {
        #expect(NativeContextABI.ot_context_abi_version() == UInt32(NativeABI.OT_CONTEXT_ABI_VERSION))

        var badCtx: NativeContextABI.ContextHandle?
        let badVer = NativeContextABI.ot_context_create(abiVersion: 999, outContext: &badCtx)
        #expect(badVer == Int32(NativeABI.OT_UNSUPPORTED_VERSION))
        #expect(badCtx == nil)

        var ctx: NativeContextABI.ContextHandle?
        let ok = NativeContextABI.ot_context_create(outContext: &ctx)
        #expect(ok == Int32(NativeABI.OT_OK))
        let handle = try #require(ctx)
        #expect(NativeContextABI.sessionContextStatus(handle) == Int32(NativeABI.OT_OK))

        // Trigger an error and verify last_error + diagnostics drain
        let staleStatus = NativeContextABI.ot_buffer_destroy(handle, .zero)
        #expect(staleStatus == Int32(NativeABI.OT_WRONG_CONTEXT))
        var errMsg = ""
        #expect(NativeContextABI.ot_context_get_last_error(handle, outMessage: &errMsg) == Int32(NativeABI.OT_OK))
        #expect(!errMsg.isEmpty)

        var diags: [NativeContextEngine.Diagnostic] = []
        #expect(NativeContextABI.ot_context_drain_diagnostics(handle, outDiagnostics: &diags) == Int32(NativeABI.OT_OK))
        #expect(!diags.isEmpty)

        #expect(NativeContextABI.ot_context_destroy(handle) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.sessionContextStatus(handle) == Int32(NativeABI.OT_STALE_HANDLE))
        #expect(NativeContextABI.ot_context_destroy(handle) == Int32(NativeABI.OT_STALE_HANDLE))
        #expect(!NativeContextABI.export_symbols().isEmpty)
    }

    @Test("Buffer create, draw, stack, lease, unicode, and destroy")
    func bufferLeaseAndUnicode() throws {
        let ctx = try NativeContextABI.createTestContext()
        defer { _ = NativeContextABI.ot_context_destroy(ctx) }

        var buf = NativeContextABI.Handle.zero
        #expect(
            NativeContextABI.ot_buffer_create(
                ctx,
                options: NativeContextBufferOptions(width: 20, height: 4, widthMethod: .unicode),
                outHandle: &buf
            ) == Int32(NativeABI.OT_OK)
        )

        #expect(NativeContextABI.ot_buffer_draw(ctx, target: buf, draw: .clear(background: RGBA.fromInts(0, 0, 0, 255))) == Int32(NativeABI.OT_OK))
        #expect(
            NativeContextABI.ot_buffer_draw(
                ctx,
                target: buf,
                draw: .text(
                    x: 0,
                    y: 0,
                    text: "Hello",
                    foreground: .defaultForeground(),
                    background: nil,
                    attributes: TextAttributes.none,
                    maxWidth: nil,
                    ellipsis: false
                )
            ) == Int32(NativeABI.OT_OK)
        )

        var opacity: Double = 0
        #expect(NativeContextABI.ot_buffer_stack(ctx, target: buf, operation: .pushOpacity(0.5), outOpacity: &opacity) == Int32(NativeABI.OT_OK))
        #expect(opacity == 0.5)
        #expect(NativeContextABI.ot_buffer_stack(ctx, target: buf, operation: .popOpacity, outOpacity: &opacity) == Int32(NativeABI.OT_OK))
        #expect(opacity == 1.0)

        // Unicode creation, character inspection, and drawing
        var uni = NativeContextABI.Handle.zero
        #expect(
            NativeContextABI.ot_unicode_create(
                ctx,
                text: "A界",
                widthMethod: UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE),
                outUnicode: &uni
            ) == Int32(NativeABI.OT_OK)
        )
        var chars: [NativeContextEngine.EncodedChar] = []
        #expect(NativeContextABI.ot_unicode_get(ctx, unicode: uni, outChars: &chars) == Int32(NativeABI.OT_OK))
        #expect(chars.count == 2)
        #expect(chars[0].width == 1)
        #expect(chars[1].width == 2)
        #expect(NativeContextABI.ot_buffer_draw_unicode(ctx, target: buf, unicode: uni, x: 0, y: 1) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_unicode_destroy(ctx, unicode: uni) == Int32(NativeABI.OT_OK))

        // Buffer lease acquire, validate, resolve chars, release
        var leaseHandle = NativeContextABI.Handle.zero
        var lease = NativeSessionBufferLease(handle: ContextObjectHandle(contextId: 0, slot: 0, generation: 0), width: 0, height: 0, generation: 0)
        #expect(NativeContextABI.ot_buffer_acquire_lease(ctx, buffer: buf, outLeaseHandle: &leaseHandle, outLease: &lease) == Int32(NativeABI.OT_OK))
        #expect(lease.width == 20 && lease.height == 4)
        #expect(NativeContextABI.ot_buffer_lease_validate(ctx, leaseHandle) == Int32(NativeABI.OT_OK))
        var charSize: UInt32 = 0
        #expect(NativeContextABI.ot_buffer_lease_get_real_char_size(ctx, lease: leaseHandle, addLineBreaks: true, outSize: &charSize) == Int32(NativeABI.OT_OK))
        #expect(charSize > 0)
        var resolved: [UInt8] = []
        #expect(NativeContextABI.ot_buffer_lease_write_resolved_chars(ctx, lease: leaseHandle, addLineBreaks: true, outBytes: &resolved) == Int32(NativeABI.OT_OK))
        let rendered = String(decoding: resolved, as: UTF8.self)
        #expect(rendered.contains("Hello"))
        #expect(NativeContextABI.ot_buffer_lease_release(ctx, leaseHandle) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_buffer_lease_validate(ctx, leaseHandle) == Int32(NativeABI.OT_STALE_HANDLE))

        #expect(NativeContextABI.ot_buffer_resize(ctx, buffer: buf, width: 10, height: 2) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_buffer_destroy(ctx, buf) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_buffer_resize(ctx, buffer: buf, width: 8, height: 2) == Int32(NativeABI.OT_STALE_HANDLE))
    }
}

// MARK: - 3. Text, Editor & SyntaxStyle ABI Tests

@Suite("NativeContextABI.TextAndEditor")
struct NativeContextABITextEditorTests {
    @Test("TextBuffer, TextBufferView, EditBuffer, EditorView, and SyntaxStyle ABI")
    func textAndEditorWorkflow() throws {
        let ctx = try NativeContextABI.createTestContext()
        defer { _ = NativeContextABI.ot_context_destroy(ctx) }

        // SyntaxStyle
        var style = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_syntax_style_create(ctx, outHandle: &style) == Int32(NativeABI.OT_OK))
        var kwId: UInt32 = 0
        #expect(
            NativeContextABI.ot_syntax_style_register(
                ctx,
                style: style,
                name: "keyword",
                definition: NativeEditorStyle(fg: RGBA.fromInts(255, 100, 50, 255), attributes: TextAttributes.bold),
                outStyleId: &kwId
            ) == Int32(NativeABI.OT_OK)
        )
        #expect(kwId > 0)
        var resolvedId: UInt32?
        #expect(NativeContextABI.ot_syntax_style_resolve(ctx, style: style, name: "keyword", outStyleId: &resolvedId) == Int32(NativeABI.OT_OK))
        #expect(resolvedId == kwId)
        var styleCount: UInt32 = 0
        #expect(NativeContextABI.ot_syntax_style_get_count(ctx, style: style, outCount: &styleCount) == Int32(NativeABI.OT_OK))
        #expect(styleCount == 1)

        // TextBuffer & TextBufferView
        var tb = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_text_buffer_create(ctx, outTextBuffer: &tb) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_set_syntax_style(ctx, textBuffer: tb, style: style) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_set_text(ctx, textBuffer: tb, text: "hello") == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_append(ctx, textBuffer: tb, text: " world") == Int32(NativeABI.OT_OK))
        var tbText = ""
        #expect(NativeContextABI.ot_text_buffer_get_text(ctx, textBuffer: tb, outText: &tbText) == Int32(NativeABI.OT_OK))
        #expect(tbText == "hello world")
        var tbRange = ""
        #expect(NativeContextABI.ot_text_buffer_get_range(ctx, textBuffer: tb, start: 0, end: 5, outText: &tbRange) == Int32(NativeABI.OT_OK))
        #expect(tbRange == "hello")

        var tbInfo = NativeTextBufferInfo()
        #expect(NativeContextABI.ot_text_buffer_get_info(ctx, textBuffer: tb, outInfo: &tbInfo) == Int32(NativeABI.OT_OK))
        #expect(tbInfo.byteLength == 11)

        var tv = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_text_buffer_view_create(ctx, textBuffer: tb, outView: &tv) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_view_set_viewport(ctx, view: tv, viewport: NativeEditorViewport(x: 0, y: 0, width: 20, height: 5)) == Int32(NativeABI.OT_OK))
        var measured = MeasureResult(lineCount: 0, widthColsMax: 0)
        #expect(NativeContextABI.ot_text_buffer_view_measure(ctx, view: tv, width: 20, height: 5, outResult: &measured) == Int32(NativeABI.OT_OK))
        #expect(measured.lineCount >= 1)

        // EditBuffer & EditorView
        var eb = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_edit_buffer_create(ctx, outHandle: &eb) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_set_syntax_style(ctx, editBuffer: eb, style: style) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_set_text(ctx, editBuffer: eb, text: "swift") == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_set_cursor(ctx, editBuffer: eb, row: 0, col: 5) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_insert_text(ctx, editBuffer: eb, text: " 6") == Int32(NativeABI.OT_OK))

        var ebText = ""
        #expect(NativeContextABI.ot_edit_buffer_get_text(ctx, editBuffer: eb, outText: &ebText) == Int32(NativeABI.OT_OK))
        #expect(ebText == "swift 6")

        var measuredWidth: UInt32 = 0
        #expect(NativeContextABI.ot_edit_measure_text(ctx, text: "abc", outWidth: &measuredWidth) == Int32(NativeABI.OT_OK))
        #expect(measuredWidth == 3)

        var ev = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_editor_view_create(ctx, editBuffer: eb, width: 40, height: 10, outHandle: &ev) == Int32(NativeABI.OT_OK))
        var vp = NativeEditorViewport()
        #expect(NativeContextABI.ot_editor_view_get_viewport(ctx, view: ev, outViewport: &vp) == Int32(NativeABI.OT_OK))
        #expect(vp.width == 40 && vp.height == 10)

        var selChanged = false
        #expect(
            NativeContextABI.ot_editor_view_select(
                ctx,
                view: ev,
                options: NativeEditorSelection(operation: .set, start: 0, end: 5),
                outChanged: &selChanged
            ) == Int32(NativeABI.OT_OK)
        )
        var selected = ""
        #expect(NativeContextABI.ot_editor_view_get_selected_text(ctx, view: ev, outText: &selected) == Int32(NativeABI.OT_OK))
        #expect(selected == "swift")

        var replacement = NativeEditorReplacement()
        #expect(NativeContextABI.ot_editor_view_replace_selection(ctx, view: ev, text: "Swift", outReplacement: &replacement) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_get_text(ctx, editBuffer: eb, outText: &ebText) == Int32(NativeABI.OT_OK))
        #expect(ebText == "Swift 6")

        // Cleanup
        #expect(NativeContextABI.ot_editor_view_destroy(ctx, ev) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_edit_buffer_destroy(ctx, eb) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_view_destroy(ctx, view: tv) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_text_buffer_destroy(ctx, textBuffer: tb) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_syntax_style_destroy(ctx, style) == Int32(NativeABI.OT_OK))
    }
}

// MARK: - 4. Session, Scene, Input, Output, Markdown, Terminal, Media, Audio & Runtime Tests

@Suite("NativeContextABI.Subsystems")
struct NativeContextABISubsystemsTests {
    @Test("Session, scene graph, frame lifecycle, input feed, and output ABI")
    func sessionSceneInputOutput() throws {
        let ctx = try NativeContextABI.createTestContext()
        defer { _ = NativeContextABI.ot_context_destroy(ctx) }

        var session = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_session_create(ctx, outSession: &session) == Int32(NativeABI.OT_OK))
        #expect(
            NativeContextABI.ot_session_attach_renderer(
                ctx,
                session: session,
                options: NativeSessionRendererOptions(width: 40, height: 12)
            ) == Int32(NativeABI.OT_OK)
        )

        var rState = NativeSessionRendererState()
        #expect(NativeContextABI.ot_session_get_renderer_state(ctx, session: session, outState: &rState) == Int32(NativeABI.OT_OK))
        #expect(rState.width == 40 && rState.height == 12)

        // Link pool round-trip
        var linkId: UInt32 = 0
        #expect(NativeContextABI.ot_session_get_link_id(ctx, session: session, url: "https://opentui.dev", outLinkId: &linkId) == Int32(NativeABI.OT_OK))
        #expect(linkId > 0)
        var resolvedUrl: String?
        #expect(NativeContextABI.ot_context_get_link_url(ctx, linkId: linkId, outUrl: &resolvedUrl) == Int32(NativeABI.OT_OK))
        #expect(resolvedUrl == "https://opentui.dev")

        // Input feed
        #expect(NativeContextABI.ot_session_input_expect(ctx, session: session, flags: 1) == Int32(NativeABI.OT_OK))
        var drain = NativeInputDrain()
        #expect(NativeContextABI.ot_session_input_feed(ctx, session: session, bytes: Array("a".utf8), outDrain: &drain) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_session_input_reset(ctx, session: session) == Int32(NativeABI.OT_OK))

        // Scene nodes, layout, frame step & commit
        var root = NativeContextABI.Handle.zero
        var child = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_scene_create_node(ctx, session: session, kind: UInt32(NativeABI.OT_SCENE_ROOT), num: 1, outNode: &root) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_create_node(ctx, session: session, kind: UInt32(NativeABI.OT_SCENE_TEXT), num: 2, outNode: &child) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_move_node(ctx, node: child, parent: root, index: 0) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_set_text(ctx, node: child, text: "Scene OK") == Int32(NativeABI.OT_OK))

        var rounds = 0
        #expect(NativeContextABI.ot_scene_measure_layout(ctx, session: session, root: root, availableWidth: 40, outRounds: &rounds) == Int32(NativeABI.OT_OK))

        var frameReq = NativeSceneFrameRequest(
            session: SessionHandle(contextId: 0, slot: 0, generation: 0),
            root: SceneNodeHandle(contextId: 0, slot: 0, generation: 0),
            node: SceneNodeHandle(contextId: 0, slot: 0, generation: 0),
            frameId: 0,
            requestId: 0,
            layoutEpoch: 0,
            kind: .done
        )
        #expect(NativeContextABI.ot_scene_frame_step_with_geometry(ctx, session: session, root: root, outRequest: &frameReq) == Int32(NativeABI.OT_OK))
        var renderStatus: UInt32 = 99
        #expect(NativeContextABI.ot_scene_frame_commit(ctx, session: session, frame: frameReq, outRenderStatus: &renderStatus) == Int32(NativeABI.OT_OK))

        // Post and drain stdout
        #expect(NativeContextABI.ot_session_post_stdout(ctx, session: session, bytes: Array("out".utf8)) == Int32(NativeABI.OT_OK))
        var stdoutBytes: [UInt8] = []
        #expect(NativeContextABI.ot_session_drain_stdout(ctx, session: session, outBytes: &stdoutBytes) == Int32(NativeABI.OT_OK))
        #expect(String(decoding: stdoutBytes, as: UTF8.self) == "out")

        #expect(NativeContextABI.ot_scene_clear_children(ctx, node: root) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_destroy_node(ctx, node: child) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_destroy_node(ctx, node: root) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_session_destroy(ctx, session: session) == Int32(NativeABI.OT_OK))
    }

    @Test("Markdown, EmbeddedTerminal, Image, Video, Audio, SpanFeed, and Runtime ABI")
    func markdownTerminalMediaAudioAndRuntime() throws {
        let ctx = try NativeContextABI.createTestContext()
        defer { _ = NativeContextABI.ot_context_destroy(ctx) }

        // Markdown
        var md = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_markdown_create(ctx, outDoc: &md) == Int32(NativeABI.OT_OK))
        var mdRes = NativeMarkdownResult()
        #expect(NativeContextABI.ot_markdown_set(ctx, doc: md, text: "# Title\n\nHello", outResult: &mdRes) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_markdown_append(ctx, doc: md, text: " world", outResult: &mdRes) == Int32(NativeABI.OT_OK))
        var mdBlocks: [NativeMarkdownBlock] = []
        #expect(NativeContextABI.ot_markdown_read_changes(ctx, doc: md, outBlocks: &mdBlocks) == Int32(NativeABI.OT_OK))
        #expect(!mdBlocks.isEmpty)
        #expect(NativeContextABI.ot_markdown_finish(ctx, doc: md, outResult: &mdRes) == Int32(NativeABI.OT_OK))
        var mdSrc = ""
        #expect(NativeContextABI.ot_markdown_get_source(ctx, doc: md, outSource: &mdSrc) == Int32(NativeABI.OT_OK))
        #expect(mdSrc == "# Title\n\nHello world")
        var block0Src = ""
        #expect(NativeContextABI.ot_markdown_read_source(ctx, doc: md, blockIndex: 0, outSource: &block0Src) == Int32(NativeABI.OT_OK))
        #expect(block0Src.contains("Title"))
        var leaf0 = NativeMarkdownLeaf()
        #expect(NativeContextABI.ot_markdown_read_leaf(ctx, doc: md, blockIndex: 0, outLeaf: &leaf0) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_markdown_destroy(ctx, doc: md) == Int32(NativeABI.OT_OK))

        // EmbeddedTerminal
        var term = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_embedded_terminal_create(ctx, cols: 20, rows: 5, outTerminal: &term) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_embedded_terminal_write(ctx, terminal: term, bytes: Array("Hi".utf8)) == Int32(NativeABI.OT_OK))
        var cursor = EmbeddedTerminalCursor()
        #expect(NativeContextABI.ot_embedded_terminal_cursor_get(ctx, terminal: term, outCursor: &cursor) == Int32(NativeABI.OT_OK))
        #expect(cursor.x == 2 && cursor.y == 0)
        var focusSeq: [UInt8] = []
        #expect(NativeContextABI.ot_embedded_terminal_encode_focus(ctx, terminal: term, focused: true, outBytes: &focusSeq) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_embedded_terminal_destroy(ctx, terminal: term) == Int32(NativeABI.OT_OK))

        // Image pipeline + ICC cache hooks
        let pixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        ]
        var img = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_image_create_pixels(ctx, pixels: pixels, width: 2, height: 2, outImage: &img) == Int32(NativeABI.OT_OK))
        var imgInfo = NativeImageInfo()
        #expect(NativeContextABI.ot_image_get_info(ctx, image: img, outInfo: &imgInfo) == Int32(NativeABI.OT_OK))
        #expect(imgInfo.width == 2 && imgInfo.height == 2)

        var resized = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_image_resize(ctx, image: img, width: 4, height: 4, outImage: &resized) == Int32(NativeABI.OT_OK))
        var pngBytes: [UInt8] = []
        #expect(NativeContextABI.ot_image_copy_png(ctx, image: resized, outPng: &pngBytes) == Int32(NativeABI.OT_OK))
        #expect(!pngBytes.isEmpty)
        var inspected = NativeImageInfo()
        #expect(NativeContextABI.ot_image_inspect(ctx, bytes: pngBytes, outInfo: &inspected) == Int32(NativeABI.OT_OK))
        #expect(inspected.width == 4 && inspected.height == 4)

        NativeContextABI.imageRetainIccCache()
        NativeContextABI.imageTestFailIccProfileCopyAllocationOnce()
        #expect(NativeContextABI.consumeIccCopyAllocationFailure() == true)
        #expect(NativeContextABI.consumeIccCopyAllocationFailure() == false)
        NativeContextABI.imageReleaseIccCache()

        #expect(NativeContextABI.ot_image_destroy(ctx, resized) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_image_destroy(ctx, img) == Int32(NativeABI.OT_OK))

        // Video
        var videoNode = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_scene_create_node(ctx, kind: UInt32(NativeABI.OT_SCENE_CUSTOM), num: 10, outNode: &videoNode) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_set_video(ctx, node: videoNode, fit: .fit) == Int32(NativeABI.OT_OK))
        var vidInfo = NativeVideoInfo()
        #expect(NativeContextABI.ot_video_open(ctx, node: videoNode, path: "sample.mp4", outInfo: &vidInfo) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_video_play(ctx, node: videoNode) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_video_set_loop(ctx, node: videoNode, loop: true) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_video_set_volume(ctx, node: videoNode, volume: 0.5) == Int32(NativeABI.OT_OK))
        var vidState = NativeVideoState()
        #expect(NativeContextABI.ot_video_get_state(ctx, node: videoNode, outState: &vidState) == Int32(NativeABI.OT_OK))
        #expect(vidState.playing == true)
        #expect(NativeContextABI.ot_video_pause(ctx, node: videoNode) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_scene_destroy_node(ctx, node: videoNode) == Int32(NativeABI.OT_OK))

        // Context Audio ABI (`context-audio-abi.zig`) + Standalone Audio ABI (`audio-abi.zig`)
        var ctxAudio = NativeContextABI.Handle.zero
        #expect(NativeContextABI.ot_audio_create(ctx, outAudio: &ctxAudio) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_audio_start(ctx, audio: ctxAudio, flags: UInt32(NativeABI.OT_AUDIO_START_NO_DEVICE)) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_audio_set_volume(ctx, audio: ctxAudio, volume: 0.75) == Int32(NativeABI.OT_OK))
        var mixed: [Float] = []
        #expect(NativeContextABI.ot_audio_mix(ctx, audio: ctxAudio, frameCount: 16, channels: 2, outSamples: &mixed) == Int32(NativeABI.OT_OK))
        #expect(mixed.count == 32)
        #expect(NativeContextABI.ot_audio_stop(ctx, audio: ctxAudio) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.ot_audio_destroy(ctx, ctxAudio) == Int32(NativeABI.OT_OK))

        #expect(NativeContextABI.createAudioEngine(ctx) == Int32(NativeABI.OT_OK))
        #expect(NativeContextABI.audioStartMixer(ctx) == Int32(NativeABI.OT_OK))
        var groupId: UInt32 = 0
        #expect(NativeContextABI.audioCreateGroup(ctx, name: "sfx", outGroupId: &groupId) == Int32(NativeABI.OT_OK))
        #expect(groupId > 0)
        #expect(NativeContextABI.audioSetGroupVolume(ctx, groupId: groupId, volume: 0.8) == Int32(NativeABI.OT_OK))
        var stats: ZigAudioStats?
        #expect(NativeContextABI.audioGetStats(ctx, outStats: &stats) == Int32(NativeABI.OT_OK))
        #expect(stats != nil)
        #expect(NativeContextABI.audioStop(ctx) == Int32(NativeABI.OT_OK))

        // NativeSpanFeed ABI
        let feedPtr = NativeContextABI.createNativeSpanFeed(renderLib: ctx.context.renderLib)
        #expect(!feedPtr.isNull)
        ctx.context.renderLib.destroyNativeSpanFeed(feedPtr)

        // Runtime, Lib, OpenTUI exports & CovRunner
        let logs = Mutex<[String]>([])
        NativeContextABI.setLogCallback { _, msg in
            logs.withLock { $0.append(msg) }
        }
        NativeContextABI.emitLog(level: 1, message: "abi-ok")
        NativeContextABI.setLogCallback(nil)
        #expect(logs.withLock { $0 } == ["abi-ok"])

        var buildOpts = NativeContextABI.ExternalBuildOptions()
        NativeContextABI.getBuildOptions(renderLib: ctx.context.renderLib, outOptions: &buildOpts)
        var allocStats = NativeContextABI.ExternalAllocatorStats()
        NativeContextABI.getAllocatorStats(renderLib: ctx.context.renderLib, outStats: &allocStats)
        _ = NativeContextABI.getArenaAllocatedBytes(renderLib: ctx.context.renderLib)
        #expect(!NativeContextABI.Runtime.allocator().name.isEmpty)
        #expect(NativeContextABI.Lib.io.nonBlocking == true)
        #expect(NativeContextABI.OpenTUI.rgbColor(10, 20, 30) == RGBA.fromInts(10, 20, 30, 255))
        #expect(try NativeContextABI.CovRunner.main() == 0)
    }
}
