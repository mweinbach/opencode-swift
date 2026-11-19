// Pure-Swift Context methods and domain helpers matching `native/src/context.zig`.
// Provides direct ergonomic Swift methods on `NativeContextEngine.Context` and its
// resource descriptors (`Edit`, `Editor`, `SharedText`, `TextView`, `MarkdownOptions`,
// `MarkdownDoc`, `Text`, `RawAccess`, `StdoutCreate`), backed by `NativeContextABI` and `SwiftRenderLib`.
// Pure Swift 6 — zero OS or Foundation imports.

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Domain Resource Methods (native/src/context.zig)

public extension NativeContextEngine.Edit {
    // parity: native/src/context.zig#Edit.checkMutable [status=implemented hash=60bdcb4c8eb6]
    func checkMutable(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) {
        do {
            _ = try context.table.lookup(handle, expectedKind: .editBuffer)
        } catch {
            throw .table(error)
        }
    }

    // parity: native/src/context.zig#Edit.invalidate [status=implemented hash=513ac15edde8]
    func invalidate(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "edit.invalidate:\(handle.slot)"))
    }

    // parity: native/src/context.zig#Edit.invalidatePreparation [status=implemented hash=d08673d27c7c]
    func invalidatePreparation(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "edit.invalidatePreparation:\(handle.slot)"))
    }
}

public extension NativeContextEngine.Editor {
    // parity: native/src/context.zig#Editor.checkMutable [status=implemented hash=ede8221a58aa]
    func checkMutable(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) {
        do {
            _ = try context.table.lookup(handle, expectedKind: .editorView)
        } catch {
            throw .table(error)
        }
    }

    // parity: native/src/context.zig#Editor.invalidate [status=implemented hash=722f82a36b41]
    func invalidate(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "editor.invalidate:\(handle.slot)"))
    }

    // parity: native/src/context.zig#Editor.invalidatePreparation [status=implemented hash=e15dd18d6ef7]
    func invalidatePreparation(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "editor.invalidatePreparation:\(handle.slot)"))
    }

    // parity: native/src/context.zig#Editor.prepareView [status=implemented hash=0188ecb12833]
    func prepareView(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) -> NativeEditorViewInfo {
        var info = NativeEditorViewInfo()
        let status = NativeContextABI.ot_editor_view_get_info(context.abiHandle, view: handle, followCursor: false, outInfo: &info)
        try context.checkStatus(status)
        return info
    }
}

public extension NativeContextEngine.SharedText {
    // parity: native/src/context.zig#SharedText.checkMutable [status=implemented hash=bf29201b03c5]
    func checkMutable(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) {
        do {
            _ = try context.table.lookup(handle, expectedKind: .textBuffer)
        } catch {
            throw .table(error)
        }
    }

    // parity: native/src/context.zig#SharedText.invalidate [status=implemented hash=3e6974a74078]
    func invalidate(in context: NativeContextEngine.Context, measure: Bool = true) {
        let tag = measure ? "measure" : "prep"
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "text.invalidate(\(tag)):\(handle.slot)"))
    }

    // parity: native/src/context.zig#SharedText.setWidthMethod [status=implemented hash=2761157d1e74]
    func setWidthMethod(_ method: WidthMethod, in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) {
        try checkMutable(in: context)
        let raw: UInt32 = method == .wcwidth
            ? UInt32(NativeABI.OT_WIDTH_METHOD_WCWIDTH)
            : UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE)
        let status = NativeContextABI.ot_text_buffer_set_width_method(context.abiHandle, textBuffer: handle, widthMethod: raw)
        try context.checkStatus(status)
    }
}

public extension NativeContextEngine.TextView {
    // parity: native/src/context.zig#TextView.checkMutable [status=implemented hash=29ec4e02d7cb]
    func checkMutable(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) {
        do {
            _ = try context.table.lookup(handle, expectedKind: .textBufferView)
        } catch {
            throw .table(error)
        }
    }

    // parity: native/src/context.zig#TextView.invalidate [status=implemented hash=29247c18f369]
    func invalidate(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "textView.invalidate:\(handle.slot)"))
    }

    // parity: native/src/context.zig#TextView.invalidatePreparation [status=implemented hash=7fd1c328fcd7]
    func invalidatePreparation(in context: NativeContextEngine.Context) {
        context.pushDiagnostic(NativeContextEngine.Diagnostic(level: .debug, message: "textView.invalidatePreparation:\(handle.slot)"))
    }

    // parity: native/src/context.zig#TextView.prepareView [status=implemented hash=8310543bf676]
    func prepareView(in context: NativeContextEngine.Context) throws(NativeContextEngine.ContextError) -> NativeEditorViewInfo {
        var info = NativeEditorViewInfo()
        let status = NativeContextABI.ot_text_buffer_view_get_info(context.abiHandle, view: handle, outInfo: &info)
        try context.checkStatus(status)
        return info
    }
}

public extension NativeMarkdownOptions {
    // parity: native/src/context.zig#MarkdownOptions.engine [status=implemented hash=dae68e0c98a3]
    func engine() throws(NativeContextEngine.ContextError) -> NativeZigMarkdown.Options {
        let allFlags = UInt32(
            NativeABI.OT_MD_CONCEAL |
            NativeABI.OT_MD_HYPERLINKS |
            NativeABI.OT_MD_MATH |
            NativeABI.OT_MD_HOOK
        )
        guard (flags & ~allFlags) == 0 else {
            throw .invalidOptions("unsupported markdown flags: \(flags)")
        }
        let limit = UInt32(sourceByteLimit ?? Int(NativeZigMarkdown.sourceByteCountMax))
        guard limit <= NativeZigMarkdown.sourceByteCountMax else {
            throw .invalidOptions("markdown sourceByteLimit exceeds max")
        }
        var packedFilter: [UInt8] = []
        for (idx, item) in hookFilter.enumerated() {
            if idx > 0 { packedFilter.append(0) }
            packedFilter.append(contentsOf: item.utf8)
        }
        return NativeZigMarkdown.Options(
            math: (flags & UInt32(NativeABI.OT_MD_MATH)) != 0,
            limits: NativeZigMarkdown.Limits(
                sourceByteCount: limit == 0 ? NativeZigMarkdown.sourceByteCountMax : limit
            ),
            hookFilter: packedFilter,
            hook: (flags & UInt32(NativeABI.OT_MD_HOOK)) != 0,
            conceal: (flags & UInt32(NativeABI.OT_MD_CONCEAL)) != 0,
            hyperlinks: (flags & UInt32(NativeABI.OT_MD_HYPERLINKS)) != 0
        )
    }
}

public extension NativeContextEngine.MarkdownDoc {
    // parity: native/src/context.zig#MarkdownDoc.resolve [status=implemented hash=d0b0c02a1661]
    func resolve(
        scope: NativeZigMarkdown.Scope,
        styleHandle: NativeContextEngine.Handle?,
        in context: NativeContextEngine.Context
    ) -> NativeEditorStyle {
        guard let styleHandle else { return NativeEditorStyle() }
        var resolvedId: UInt32? = nil
        let scopeName: String
        if scope.headingLevel > 0 {
            scopeName = "markup.heading.\(scope.headingLevel)"
        } else if scope.raw {
            scopeName = "markup.raw"
        } else if scope.link {
            scopeName = "markup.link"
        } else if scope.strong {
            scopeName = "markup.strong"
        } else if scope.italic {
            scopeName = "markup.italic"
        } else if scope.strikethrough {
            scopeName = "markup.strikethrough"
        } else {
            scopeName = "default"
        }
        _ = NativeContextABI.ot_syntax_style_resolve(context.abiHandle, style: styleHandle, name: scopeName, outStyleId: &resolvedId)
        var attrs: UInt32 = TextAttributes.none
        if scope.strong { attrs |= TextAttributes.bold }
        if scope.italic { attrs |= TextAttributes.italic }
        if scope.strikethrough { attrs |= TextAttributes.strikethrough }
        return NativeEditorStyle(fg: nil, bg: nil, attributes: attrs)
    }
}

public extension NativeContextEngine.Text {
    struct Mapping: Equatable, Hashable, Sendable {
        public var contentEpoch: UInt64
        public var wrapWidth: UInt32?
        public var wrapMode: TextWrapMode
        public var textAlign: TextAlign
        public var truncate: Bool
        public var firstLineOffset: UInt32

        public init(
            contentEpoch: UInt64 = 0,
            wrapWidth: UInt32? = nil,
            wrapMode: TextWrapMode = .word,
            textAlign: TextAlign = .left,
            truncate: Bool = false,
            firstLineOffset: UInt32 = 0
        ) {
            self.contentEpoch = contentEpoch
            self.wrapWidth = wrapWidth
            self.wrapMode = wrapMode
            self.textAlign = textAlign
            self.truncate = truncate
            self.firstLineOffset = firstLineOffset
        }
    }

    // parity: native/src/context.zig#Text.mapping [status=implemented hash=24ba09d9bf21]
    func mapping(
        contentEpoch: UInt64 = 0,
        wrapWidth: UInt32? = nil,
        wrapMode: TextWrapMode = .word,
        textAlign: TextAlign = .left,
        truncate: Bool = false,
        firstLineOffset: UInt32 = 0
    ) -> Mapping {
        Mapping(
            contentEpoch: contentEpoch,
            wrapWidth: wrapWidth,
            wrapMode: wrapMode,
            textAlign: textAlign,
            truncate: truncate,
            firstLineOffset: firstLineOffset
        )
    }

    // parity: native/src/context.zig#Text.prepareView [status=implemented hash=86254972701e]
    func prepareView(widthMethod: WidthMethod = .unicode) -> Int {
        Int(segmentGraphemeClusters(bytes, widthMethod: widthMethod).reduce(UInt32(0)) { $0 + $1.width })
    }
}

// MARK: - Context RawAccess, StdoutCreate & Checked Operations (native/src/context.zig)

public extension NativeContextEngine.Context {
    struct RawAccess: @unchecked Sendable {
        public let owner: NativeContextEngine.Context

        public init(owner: NativeContextEngine.Context) {
            self.owner = owner
        }

        // parity: native/src/context.zig#Context.RawAccess.getSession [status=implemented hash=a3e6e530b12f]
        public func getSession(_ handle: NativeContextEngine.Handle) throws -> SessionHandle {
            try owner.resolveSession(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getSessionRenderer [status=implemented hash=ad22690e958e]
        public func getSessionRenderer(_ handle: NativeContextEngine.Handle) throws -> NativeSessionRendererState {
            var state = NativeSessionRendererState()
            let status = NativeContextABI.ot_session_get_renderer_state(owner.abiHandle, session: handle, outState: &state)
            try owner.checkStatus(status)
            return state
        }

        // parity: native/src/context.zig#Context.RawAccess.getUnicode [status=implemented hash=adfd35242bc1]
        public func getUnicode(_ handle: NativeContextEngine.Handle) throws -> NativeContextEngine.EncodedUnicode {
            try owner.resolveUnicode(handle).encoded
        }

        // parity: native/src/context.zig#Context.RawAccess.getEmbeddedTerminal [status=implemented hash=81f1fda9f347]
        public func getEmbeddedTerminal(_ handle: NativeContextEngine.Handle) throws -> ContextEmbeddedTerminalHandle {
            try owner.resolveEmbeddedTerminal(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getImage [status=implemented hash=0280745e0ce0]
        public func getImage(_ handle: NativeContextEngine.Handle) throws -> ContextImageHandle {
            try owner.resolveImage(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getAudioEngine [status=implemented hash=afc34fc384c8]
        public func getAudioEngine(_ handle: NativeContextEngine.Handle) throws -> AudioEngineHandle {
            try owner.resolveAudio(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getBuffer [status=implemented hash=8252b117ea1c]
        public func getBuffer(_ handle: NativeContextEngine.Handle) throws -> ContextBufferHandle {
            try owner.resolveBuffer(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getRenderable [status=implemented hash=602b35c2fd60]
        public func getRenderable(_ handle: NativeContextEngine.Handle) throws -> SceneNodeHandle {
            try owner.resolveSceneNode(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getTextBuffer [status=implemented hash=7bd88fff4da9]
        public func getTextBuffer(_ handle: NativeContextEngine.Handle) throws -> NativeContextEngine.SharedText {
            try owner.resolveTextBuffer(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getTextBufferView [status=implemented hash=bb052a00f26f]
        public func getTextBufferView(_ handle: NativeContextEngine.Handle) throws -> NativeContextEngine.TextView {
            try owner.resolveTextBufferView(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getEditBuffer [status=implemented hash=a138c288b541]
        public func getEditBuffer(_ handle: NativeContextEngine.Handle) throws -> NativeContextEngine.Edit {
            try owner.resolveEditBuffer(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getEditorView [status=implemented hash=f84b37e3102c]
        public func getEditorView(_ handle: NativeContextEngine.Handle) throws -> NativeContextEngine.Editor {
            try owner.resolveEditorView(handle)
        }

        // parity: native/src/context.zig#Context.RawAccess.getSyntaxStyle [status=implemented hash=73c4071f67ff]
        public func getSyntaxStyle(_ handle: NativeContextEngine.Handle) throws -> ContextSyntaxStyleHandle {
            try owner.resolveSyntaxStyle(handle)
        }
    }

    struct StdoutCreate: Sendable {
        public let fd: Int32

        public init(fd: Int32 = 1) {
            self.fd = fd
        }

        // parity: native/src/context.zig#Context.StdoutCreate.create [status=implemented hash=6034c6583a23]
        public func create() throws(NativeStdoutWriter.WriterCreateError) -> NativeStdoutWriter.Writer<NativeStdoutWriter.FdSink, NativeStdoutWriter.ThreadRunner> {
            try NativeStdoutWriter.Writer.create(
                sink: NativeStdoutWriter.FdSink(fd: fd),
                runner: NativeStdoutWriter.ThreadRunner()
            )
        }
    }

    internal var abiHandle: NativeContextABI.ContextHandle {
        NativeContextABI.ContextHandle(context: self)
    }

    internal func checkStatus(_ status: Int32) throws(NativeContextEngine.ContextError) {
        if status == Int32(NativeABI.OT_OK) { return }
        throw .status(status, getLastError())
    }

    // parity: native/src/context.zig#Context.raw [status=implemented hash=9e56a6cb7fd2]
    func raw() -> RawAccess {
        RawAccess(owner: self)
    }

    // parity: native/src/context.zig#Context.getLinkUrl [status=implemented hash=74d54f7d1d94]
    func getLinkUrl(linkId: UInt32) throws(NativeContextEngine.ContextError) -> String? {
        var url: String? = nil
        try checkStatus(NativeContextABI.ot_context_get_link_url(abiHandle, linkId: linkId, outUrl: &url))
        return url
    }

    // parity: native/src/context.zig#Context.createClipboardService [status=implemented hash=55b2eea3c6f5]
    func createClipboardService() throws -> any HostClipboardService {
        try createHostClipboardWithBackend { _ in InMemoryHostClipboardBackend() }
    }

    // parity: native/src/context.zig#Context.createAudioEngine [status=implemented hash=273f9439f77c]
    func createAudioEngine(options: AudioCreateOptions = AudioCreateOptions()) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_audio_create(abiHandle, options: options, outAudio: &handle))
        return handle
    }

    // MARK: Session Lifecycle & Rendering

    // parity: native/src/context.zig#Context.createSession [status=implemented hash=d827830084df]
    func createSession(options: NativeSessionOptions = NativeSessionOptions()) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_session_create(abiHandle, options: options, outSession: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.attachSessionRenderer [status=implemented hash=fbd79ddaf71c]
    func attachSessionRenderer(
        session: NativeContextEngine.Handle,
        options: NativeSessionRendererOptions,
        environment: [String: String]? = nil
    ) throws(NativeContextEngine.ContextError) {
        let status: Int32
        if let environment {
            status = NativeContextABI.ot_session_attach_renderer_with_env(abiHandle, session: session, options: options, environment: environment)
        } else {
            status = NativeContextABI.ot_session_attach_renderer(abiHandle, session: session, options: options)
        }
        try checkStatus(status)
    }

    // parity: native/src/context.zig#Context.sessionGetLinkId [status=implemented hash=6fca1b6e019c]
    func sessionGetLinkId(session: NativeContextEngine.Handle, url: String) throws(NativeContextEngine.ContextError) -> UInt32 {
        var linkId: UInt32 = 0
        try checkStatus(NativeContextABI.ot_session_get_link_id(abiHandle, session: session, url: url, outLinkId: &linkId))
        return linkId
    }

    // parity: native/src/context.zig#Context.acquireSessionBufferLease [status=implemented hash=2cefab96543a]
    func acquireSessionBufferLease(
        session: NativeContextEngine.Handle,
        slot: NativeContextEngine.RendererBuffer = .next
    ) throws(NativeContextEngine.ContextError) -> (handle: NativeContextEngine.Handle, lease: NativeSessionBufferLease) {
        var leaseHandle = NativeContextEngine.Handle.zero
        var lease = NativeSessionBufferLease(handle: ContextObjectHandle(contextId: 0, slot: 0, generation: 0), width: 0, height: 0, generation: 0)
        try checkStatus(NativeContextABI.ot_session_acquire_buffer_lease(abiHandle, session: session, slot: slot, outLeaseHandle: &leaseHandle, outLease: &lease))
        return (leaseHandle, lease)
    }

    // parity: native/src/context.zig#Context.drawSessionBuffer [status=implemented hash=32ee7e1f271f]
    func drawSessionBuffer(
        session: NativeContextEngine.Handle,
        source: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        crop: NativeContextEngine.BufferCrop? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_draw_buffer(abiHandle, session: session, source: source, x: x, y: y, crop: crop))
    }

    // parity: native/src/context.zig#Context.drawContextBuffer [status=implemented hash=ee6b351d0484]
    static func drawContextBuffer(
        destination: OptimizedBuffer,
        source: OptimizedBuffer,
        x: Int = 0,
        y: Int = 0,
        crop: NativeContextEngine.BufferCrop? = nil
    ) {
        destination.drawFrameBuffer(
            destX: x,
            destY: y,
            frameBuffer: source,
            sourceX: crop.map { Int($0.x) },
            sourceY: crop.map { Int($0.y) },
            sourceWidth: crop?.width.map { Int($0) },
            sourceHeight: crop?.height.map { Int($0) }
        )
    }

    // parity: native/src/context.zig#Context.sessionSetDebugOverlay [status=implemented hash=6b520c67c2b5]
    func sessionSetDebugOverlay(
        session: NativeContextEngine.Handle,
        enabled: Bool,
        corner: DebugOverlayCorner = .bottomRight
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_set_debug_overlay(abiHandle, session: session, enabled: enabled, corner: corner))
    }

    // parity: native/src/context.zig#Context.sessionUpdateStats [status=implemented hash=c919539d05a4]
    func sessionUpdateStats(
        session: NativeContextEngine.Handle,
        overallMs: Double,
        fps: UInt32,
        callbackMs: Double
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_update_stats(abiHandle, session: session, overallMs: overallMs, fps: fps, callbackMs: callbackMs))
    }

    // parity: native/src/context.zig#Context.sessionUpdateMemoryStats [status=implemented hash=833f23e73e19]
    func sessionUpdateMemoryStats(
        session: NativeContextEngine.Handle,
        heapUsed: UInt32,
        heapTotal: UInt32,
        arrayBuffers: UInt32
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_update_memory_stats(abiHandle, session: session, heapUsed: heapUsed, heapTotal: heapTotal, arrayBuffers: arrayBuffers))
    }

    // parity: native/src/context.zig#Context.sessionDumpHitGrid [status=implemented hash=58c4ee1d697a]
    func sessionDumpHitGrid(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var dump = ""
        try checkStatus(NativeContextABI.ot_session_dump_hit_grid(abiHandle, session: session, outDump: &dump))
        return dump
    }

    // parity: native/src/context.zig#Context.renderSession [status=implemented hash=aebf2ded3486]
    func renderSession(session: NativeContextEngine.Handle, force: Bool = false) throws(NativeContextEngine.ContextError) -> UInt32 {
        var status: UInt32 = 0
        try checkStatus(NativeContextABI.ot_session_render(abiHandle, session: session, force: force, outRenderStatus: &status))
        return status
    }

    // parity: native/src/context.zig#Context.setupSessionTerminal [status=implemented hash=cb6e728a080c]
    func setupSessionTerminal(
        session: NativeContextEngine.Handle,
        options: NativeSessionTerminalOptions = NativeSessionTerminalOptions()
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_setup_terminal(abiHandle, session: session, options: options))
    }

    // parity: native/src/context.zig#Context.suspendSession [status=implemented hash=9236123b9e37]
    func suspendSession(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_suspend(abiHandle, session: session))
    }

    // parity: native/src/context.zig#Context.resumeSession [status=implemented hash=1c22a29de06f]
    func resumeSession(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_resume(abiHandle, session: session))
    }

    // parity: native/src/context.zig#Context.pumpSession [status=implemented hash=548e64c528f3]
    func pumpSession(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSessionPumpResult {
        var result = NativeSessionPumpResult(status: .idle)
        try checkStatus(NativeContextABI.ot_session_pump(abiHandle, session: session, outResult: &result))
        return result
    }

    // parity: native/src/context.zig#Context.sessionInputFeed [status=implemented hash=d64666b059e5]
    func sessionInputFeed(session: NativeContextEngine.Handle, bytes: [UInt8]) throws(NativeContextEngine.ContextError) -> NativeInputDrain {
        var drain = NativeInputDrain()
        try checkStatus(NativeContextABI.ot_session_input_feed(abiHandle, session: session, bytes: bytes, outDrain: &drain))
        return drain
    }

    // parity: native/src/context.zig#Context.sessionInputExpect [status=implemented hash=f11cdc468d45]
    func sessionInputExpect(session: NativeContextEngine.Handle, flags: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_input_expect(abiHandle, session: session, flags: flags))
    }

    // parity: native/src/context.zig#Context.sessionInputReset [status=implemented hash=8765f58b5468]
    func sessionInputReset(session: NativeContextEngine.Handle, flags: UInt32 = 0) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_input_reset(abiHandle, session: session, flags: flags))
    }

    // parity: native/src/context.zig#Context.getSessionTerminalState [status=implemented hash=61811e7ab428]
    func getSessionTerminalState(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSessionTerminalPhase {
        var phase: NativeSessionTerminalPhase = .uninitialized
        try checkStatus(NativeContextABI.ot_session_get_terminal_state(abiHandle, session: session, outPhase: &phase))
        return phase
    }

    // parity: native/src/context.zig#Context.controlSession [status=implemented hash=29a6079b49fa]
    func controlSession(session: NativeContextEngine.Handle, command: NativeSessionControl) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_control(abiHandle, session: session, command: command))
    }

    // parity: native/src/context.zig#Context.writeSessionClipboard [status=implemented hash=b6c8d63305af]
    func writeSessionClipboard(
        session: NativeContextEngine.Handle,
        target: ClipboardTarget = .clipboard,
        bytes: [UInt8]
    ) throws(NativeContextEngine.ContextError) -> Bool {
        var sent = false
        try checkStatus(NativeContextABI.ot_session_clipboard(abiHandle, session: session, target: target, bytes: bytes, outSent: &sent))
        return sent
    }

    // parity: native/src/context.zig#Context.resizeSessionRenderer [status=implemented hash=f498fe62b32b]
    func resizeSessionRenderer(session: NativeContextEngine.Handle, width: UInt32, height: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_resize_renderer(abiHandle, session: session, width: width, height: height))
    }

    // parity: native/src/context.zig#Context.writeSession [status=implemented hash=1fc77526d7ec]
    func writeSession(session: NativeContextEngine.Handle, bytes: [UInt8]) throws(NativeContextEngine.ContextError) -> Bool {
        var accepted = false
        try checkStatus(NativeContextABI.ot_session_write(abiHandle, session: session, bytes: bytes, outAccepted: &accepted))
        return accepted
    }

    // parity: native/src/context.zig#Context.readOutput [status=implemented hash=2ed328cb51f8]
    func readOutput(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> (ticket: NativeOutputTicket?, bytes: [UInt8]) {
        var ticket: NativeOutputTicket? = nil
        var bytes: [UInt8] = []
        try checkStatus(NativeContextABI.ot_session_read_output(abiHandle, session: session, outTicket: &ticket, outBytes: &bytes))
        return (ticket, bytes)
    }

    // parity: native/src/context.zig#Context.drainOutput [status=implemented hash=83461135d0c5]
    func drainOutput(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var bytes: [UInt8] = []
        try checkStatus(NativeContextABI.ot_session_drain_output(abiHandle, session: session, outBytes: &bytes))
        return bytes
    }

    // parity: native/src/context.zig#Context.drainStdout [status=implemented hash=fad5f8de7a76]
    func drainStdout(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var bytes: [UInt8] = []
        try checkStatus(NativeContextABI.ot_session_drain_stdout(abiHandle, session: session, outBytes: &bytes))
        return bytes
    }

    // parity: native/src/context.zig#Context.postStdout [status=implemented hash=26f5fa07c3b5]
    func postStdout(session: NativeContextEngine.Handle, bytes: [UInt8]) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_post_stdout(abiHandle, session: session, bytes: bytes))
    }

    // parity: native/src/context.zig#Context.completeOutput [status=implemented hash=71eb8c0ec74f]
    func completeOutput(ticket: NativeOutputTicket, succeeded: Bool = true) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_complete_output(abiHandle, ticket: ticket, succeeded: succeeded))
    }

    // parity: native/src/context.zig#Context.beginSessionClose [status=implemented hash=4f0e1157fcc4]
    func beginSessionClose(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_close(abiHandle, session: session))
    }

    // parity: native/src/context.zig#Context.dropSessionOutput [status=implemented hash=7193b142c0b9]
    func dropSessionOutput(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_drop_output(abiHandle, session: session))
    }

    // parity: native/src/context.zig#Context.cancelSession [status=implemented hash=331e2ece4987]
    func cancelSession(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_cancel(abiHandle, session: session))
    }

    // MARK: Buffers, Images & Unicode

    // parity: native/src/context.zig#Context.createBuffer [status=implemented hash=8b5919aeb0b0]
    func createBuffer(options: NativeContextBufferOptions) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_buffer_create(abiHandle, options: options, outHandle: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.importImage [status=implemented hash=b323a354a485]
    func importImage(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions = PixelImportOptions()
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        try createImagePixels(pixels: pixels, width: width, height: height, options: options)
    }

    // parity: native/src/context.zig#Context.inspectImage [status=implemented hash=1ad72cd42464]
    func inspectImage(bytes: [UInt8]) throws(NativeContextEngine.ContextError) -> NativeImageInfo {
        var info = NativeImageInfo()
        try checkStatus(NativeContextABI.ot_image_inspect(abiHandle, bytes: bytes, outInfo: &info))
        return info
    }

    // parity: native/src/context.zig#Context.decodeImage [status=implemented hash=499a565c9b35]
    func decodeImage(bytes: [UInt8]) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_decode(abiHandle, bytes: bytes, outImage: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.createImagePixels [status=implemented hash=a2888bf646cb]
    func createImagePixels(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions = PixelImportOptions()
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_create_pixels(abiHandle, pixels: pixels, width: width, height: height, options: options, outImage: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.cloneImageFrom [status=implemented hash=574a29a52d2b]
    func cloneImageFrom(
        source: NativeContextEngine.Context? = nil,
        image: NativeContextEngine.Handle
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_clone(abiHandle, source: source?.abiHandle, image: image, outImage: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.retainImage [status=implemented hash=81b81341e377]
    func retainImage(_ image: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var handle = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_retain(abiHandle, image: image, outImage: &handle))
        return handle
    }

    // parity: native/src/context.zig#Context.imageInfo [status=implemented hash=2d25924355ef]
    func imageInfo(_ image: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeImageInfo {
        var info = NativeImageInfo()
        try checkStatus(NativeContextABI.ot_image_get_info(abiHandle, image: image, outInfo: &info))
        return info
    }

    // parity: native/src/context.zig#Context.updateImagePixels [status=implemented hash=884929756b4a]
    func updateImagePixels(
        _ image: NativeContextEngine.Handle,
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions = PixelImportOptions()
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_image_update_pixels(abiHandle, image: image, pixels: pixels, width: width, height: height, options: options))
    }

    // parity: native/src/context.zig#Context.resizeImage [status=implemented hash=f4e27ac2c3ae]
    func resizeImage(
        _ image: NativeContextEngine.Handle,
        width: UInt32,
        height: UInt32,
        filter: UInt32 = UInt32(NativeABI.OT_IMAGE_FILTER_DEFAULT)
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_resize(abiHandle, image: image, width: width, height: height, filter: filter, outImage: &out))
        return out
    }

    // parity: native/src/context.zig#Context.extractImage [status=implemented hash=9994e2d1a83b]
    func extractImage(
        _ image: NativeContextEngine.Handle,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_extract(abiHandle, image: image, left: left, top: top, width: width, height: height, outImage: &out))
        return out
    }

    // parity: native/src/context.zig#Context.extendImage [status=implemented hash=ca2dee7eb058]
    func extendImage(
        _ image: NativeContextEngine.Handle,
        top: UInt32,
        right: UInt32,
        bottom: UInt32,
        left: UInt32,
        background: RGBA = RGBA.fromInts(0, 0, 0, 0)
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_extend(abiHandle, image: image, top: top, right: right, bottom: bottom, left: left, background: background, outImage: &out))
        return out
    }

    // parity: native/src/context.zig#Context.transformImage [status=implemented hash=9edaf2b0964e]
    func transformImage(
        _ image: NativeContextEngine.Handle,
        operation: UInt32
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_transform(abiHandle, image: image, operation: operation, outImage: &out))
        return out
    }

    // parity: native/src/context.zig#Context.compositeImage [status=implemented hash=6ae75a0202c3]
    func compositeImage(
        base: NativeContextEngine.Handle,
        overlay: NativeContextEngine.Handle,
        left: Int32 = 0,
        top: Int32 = 0,
        blend: UInt32 = UInt32(NativeABI.OT_IMAGE_BLEND_SOURCE_OVER)
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_image_composite(abiHandle, base: base, overlay: overlay, left: left, top: top, blend: blend, outImage: &out))
        return out
    }

    // parity: native/src/context.zig#Context.copyImagePixels [status=implemented hash=695bf6b28dcd]
    func copyImagePixels(
        _ image: NativeContextEngine.Handle,
        format: PixelFormat = .rgba8
    ) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_image_copy_pixels(abiHandle, image: image, format: format, outPixels: &out))
        return out
    }

    // parity: native/src/context.zig#Context.copyImagePng [status=implemented hash=1d164d6272fd]
    func copyImagePng(_ image: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_image_copy_png(abiHandle, image: image, outPng: &out))
        return out
    }

    // parity: native/src/context.zig#Context.takeImagePixels [status=implemented hash=4525ed69ef0f]
    func takeImagePixels(_ image: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> (lease: NativeContextEngine.Handle, raw: RawImage) {
        var lease = NativeContextEngine.Handle.zero
        var raw = RawImage(data: [], width: 0, height: 0, stride: 0)
        try checkStatus(NativeContextABI.ot_image_take_pixels(abiHandle, image: image, outLeaseHandle: &lease, outRaw: &raw))
        return (lease, raw)
    }

    // parity: native/src/context.zig#Context.imagePixelsSnapshot [status=implemented hash=1cb4145f96a1]
    func imagePixelsSnapshot(_ lease: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> RawImage {
        do {
            return try resolveImagePixels(lease).raw
        } catch let err as NativeContextHandleTable.TableError {
            throw .table(err)
        } catch {
            throw .status(Int32(NativeABI.OT_STALE_HANDLE), "\(error)")
        }
    }

    // parity: native/src/context.zig#Context.releaseImagePixels [status=implemented hash=7f4d07498888]
    func releaseImagePixels(_ lease: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_image_pixels_release(abiHandle, lease: lease))
    }

    // parity: native/src/context.zig#Context.createUnicode [status=implemented hash=db23fab7372d]
    func createUnicode(
        text: String,
        widthMethod: UInt32 = UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE)
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_unicode_create(abiHandle, text: text, widthMethod: widthMethod, outUnicode: &out))
        return out
    }

    // parity: native/src/context.zig#Context.drawBufferUnicode [status=implemented hash=3d362e45c07a]
    func drawBufferUnicode(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        unicode: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) throws(NativeContextEngine.ContextError) {
        try drawUnicodeOn(target: target, frame: frame, unicode: unicode, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
    }

    // parity: native/src/context.zig#Context.drawUnicodeOn [status=implemented hash=fb66bb62bc79]
    func drawUnicodeOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        unicode: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_buffer_draw_unicode(
                abiHandle, target: target, frame: frame, unicode: unicode, x: x, y: y, fg: fg, bg: bg, attributes: attributes
            )
        )
    }

    // MARK: Embedded Terminal

    // parity: native/src/context.zig#Context.createEmbeddedTerminal [status=implemented hash=1bbfe6c8be0f]
    func createEmbeddedTerminal(
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        maxScrollback: UInt32 = 1_000,
        transparentBackground: Bool = false
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(
            NativeContextABI.ot_embedded_terminal_create(
                abiHandle, cols: cols, rows: rows, maxScrollback: maxScrollback, transparentBackground: transparentBackground, outTerminal: &out
            )
        )
        return out
    }

    // parity: native/src/context.zig#Context.embeddedTerminalWrite [status=implemented hash=1004d0b96879]
    func embeddedTerminalWrite(terminal: NativeContextEngine.Handle, bytes: [UInt8]) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_embedded_terminal_write(abiHandle, terminal: terminal, bytes: bytes))
    }

    // parity: native/src/context.zig#Context.embeddedTerminalResize [status=implemented hash=b0306b5f4e92]
    func embeddedTerminalResize(terminal: NativeContextEngine.Handle, cols: UInt32, rows: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_embedded_terminal_resize(abiHandle, terminal: terminal, cols: cols, rows: rows))
    }

    // parity: native/src/context.zig#Context.embeddedTerminalCommand [status=implemented hash=4a5fb7defce8]
    func embeddedTerminalCommand(
        terminal: NativeContextEngine.Handle,
        command: UInt32,
        argument: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_embedded_terminal_command(abiHandle, terminal: terminal, command: command, argument: argument))
    }

    // parity: native/src/context.zig#Context.embeddedTerminalSetSelection [status=implemented hash=c29896847ec1]
    func embeddedTerminalSetSelection(
        terminal: NativeContextEngine.Handle,
        startX: UInt32,
        startY: UInt32,
        endX: UInt32,
        endY: UInt32
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_embedded_terminal_set_selection(
                abiHandle, terminal: terminal, startX: startX, startY: startY, endX: endX, endY: endY
            )
        )
    }

    // parity: native/src/context.zig#Context.embeddedTerminalGetSelectedText [status=implemented hash=5e9ba68b8794]
    func embeddedTerminalGetSelectedText(terminal: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_embedded_terminal_get_selected_text(abiHandle, terminal: terminal, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.embeddedTerminalCompose [status=implemented hash=c2f01900d663]
    func embeddedTerminalCompose(
        terminal: NativeContextEngine.Handle,
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_embedded_terminal_compose(abiHandle, terminal: terminal, target: target, frame: frame, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.embeddedTerminalCursor [status=implemented hash=7215b328b4a2]
    func embeddedTerminalCursor(terminal: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> EmbeddedTerminalCursor {
        var cursor = EmbeddedTerminalCursor()
        try checkStatus(NativeContextABI.ot_embedded_terminal_cursor_get(abiHandle, terminal: terminal, outCursor: &cursor))
        return cursor
    }

    // parity: native/src/context.zig#Context.embeddedTerminalScrollbar [status=implemented hash=e695a7cf4031]
    func embeddedTerminalScrollbar(terminal: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> EmbeddedTerminalScrollState {
        var scroll = EmbeddedTerminalScrollState(offset: 0, total: 0, visible: 0)
        try checkStatus(NativeContextABI.ot_embedded_terminal_scrollbar_get(abiHandle, terminal: terminal, outScroll: &scroll))
        return scroll
    }

    // parity: native/src/context.zig#Context.embeddedTerminalEncodeKey [status=implemented hash=d02e082f7c36]
    func embeddedTerminalEncodeKey(
        terminal: NativeContextEngine.Handle,
        key: EmbeddedTerminalKey
    ) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_embedded_terminal_encode_key(abiHandle, terminal: terminal, key: key, outBytes: &out))
        return out
    }

    // parity: native/src/context.zig#Context.embeddedTerminalEncodeMouse [status=implemented hash=a762f2d61149]
    func embeddedTerminalEncodeMouse(
        terminal: NativeContextEngine.Handle,
        mouse: EmbeddedTerminalMouse
    ) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_embedded_terminal_encode_mouse(abiHandle, terminal: terminal, mouse: mouse, outBytes: &out))
        return out
    }

    // parity: native/src/context.zig#Context.embeddedTerminalEncodePaste [status=implemented hash=bc8cd5871b48]
    func embeddedTerminalEncodePaste(
        terminal: NativeContextEngine.Handle,
        input: [UInt8]
    ) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_embedded_terminal_encode_paste(abiHandle, terminal: terminal, input: input, outBytes: &out))
        return out
    }

    // parity: native/src/context.zig#Context.embeddedTerminalEncodeFocus [status=implemented hash=e21ae1d34d4d]
    func embeddedTerminalEncodeFocus(
        terminal: NativeContextEngine.Handle,
        focused: Bool
    ) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_embedded_terminal_encode_focus(abiHandle, terminal: terminal, focused: focused, outBytes: &out))
        return out
    }

    // parity: native/src/context.zig#Context.embeddedTerminalDrainResponses [status=implemented hash=201595ee99af]
    func embeddedTerminalDrainResponses(terminal: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> [UInt8] {
        var out: [UInt8] = []
        try checkStatus(NativeContextABI.ot_embedded_terminal_drain_responses(abiHandle, terminal: terminal, outBytes: &out))
        return out
    }

    // MARK: Buffer Drawing & Kitty Image Transport

    // parity: native/src/context.zig#Context.drawBufferImage [status=implemented hash=7dd01be0aea5]
    func drawBufferImage(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        image: NativeContextEngine.Handle,
        options: NativeContextImageDraw
    ) throws(NativeContextEngine.ContextError) {
        try drawImageOn(target: target, frame: frame, image: image, options: options)
    }

    // parity: native/src/context.zig#Context.drawImageOn [status=implemented hash=2729a198b3ac]
    func drawImageOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        image: NativeContextEngine.Handle,
        options: NativeContextImageDraw
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_image(abiHandle, target: target, frame: frame, image: image, options: options))
    }

    // parity: native/src/context.zig#Context.sessionSetImageResolution [status=implemented hash=9dc8b7f844bf]
    func sessionSetImageResolution(
        session: NativeContextEngine.Handle,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_set_image_resolution(abiHandle, session: session, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    // parity: native/src/context.zig#Context.sessionSetKittyImageTransport [status=implemented hash=c459a9329cc3]
    func sessionSetKittyImageTransport(session: NativeContextEngine.Handle, mode: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_set_kitty_image_transport(abiHandle, session: session, mode: mode))
    }

    // parity: native/src/context.zig#Context.sessionKittyImageTransportStatus [status=implemented hash=9f10f609fbe5]
    func sessionKittyImageTransportStatus(
        session: NativeContextEngine.Handle
    ) throws(NativeContextEngine.ContextError) -> NativeSessionKittyImageTransportStatus {
        var status = NativeSessionKittyImageTransportStatus()
        try checkStatus(NativeContextABI.ot_session_get_kitty_image_transport(abiHandle, session: session, outStatus: &status))
        return status
    }

    // parity: native/src/context.zig#Context.sessionPollKittyImageTransport [status=implemented hash=5570716df177]
    func sessionPollKittyImageTransport(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> Bool {
        var pending = false
        try checkStatus(NativeContextABI.ot_session_poll_kitty_image_transport(abiHandle, session: session, outPending: &pending))
        return pending
    }

    // parity: native/src/context.zig#Context.sessionCancelKittyImageTransport [status=implemented hash=035b18f37849]
    func sessionCancelKittyImageTransport(session: NativeContextEngine.Handle, failed: Bool = false) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_cancel_kitty_image_transport(abiHandle, session: session, failed: failed))
    }

    // parity: native/src/context.zig#Context.sessionProcessKittyImageReply [status=implemented hash=10a076e3a89f]
    func sessionProcessKittyImageReply(session: NativeContextEngine.Handle, bytes: [UInt8]) throws(NativeContextEngine.ContextError) -> Int {
        var processed = 0
        try checkStatus(NativeContextABI.ot_session_process_kitty_image_reply(abiHandle, session: session, bytes: bytes, outProcessed: &processed))
        return processed
    }

    // parity: native/src/context.zig#Context.sessionStartKittyFileProbe [status=implemented hash=668c8cac1c83]
    func sessionStartKittyFileProbe(session: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_session_start_kitty_file_probe(abiHandle, session: session))
    }

    // parity: native/src/context.zig#Context.resizeBuffer [status=implemented hash=21c1593917f7]
    func resizeBuffer(_ buffer: NativeContextEngine.Handle, width: UInt32, height: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_resize(abiHandle, buffer: buffer, width: width, height: height))
    }

    // parity: native/src/context.zig#Context.clearBuffer [status=implemented hash=5789d1b8a28c]
    func clearBuffer(_ buffer: NativeContextEngine.Handle, background: RGBA? = nil) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw(abiHandle, target: buffer, draw: .clear(background: background)))
    }

    // parity: native/src/context.zig#Context.drawBufferText [status=implemented hash=d39ca47b481b]
    func drawBufferText(
        _ buffer: NativeContextEngine.Handle,
        text: String,
        x: Int,
        y: Int,
        foreground: RGBA,
        background: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none,
        maxWidth: Int? = nil,
        ellipsis: Bool = false
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_buffer_draw(
                abiHandle,
                target: buffer,
                draw: .text(
                    x: x,
                    y: y,
                    text: text,
                    foreground: foreground,
                    background: background,
                    attributes: attributes,
                    maxWidth: maxWidth,
                    ellipsis: ellipsis
                )
            )
        )
    }

    // parity: native/src/context.zig#Context.fillBufferRect [status=implemented hash=26e6c87efd84]
    func fillBufferRect(
        _ buffer: NativeContextEngine.Handle,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        background: RGBA
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_buffer_draw(
                abiHandle,
                target: buffer,
                draw: .fill(x: x, y: y, width: width, height: height, background: background)
            )
        )
    }

    // parity: native/src/context.zig#Context.drawBuffer [status=implemented hash=e27003fb48c3]
    func drawBuffer(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        draw: NativeBufferDraw
    ) throws(NativeContextEngine.ContextError) {
        try drawBufferOn(target: target, frame: frame, draw: draw)
    }

    // parity: native/src/context.zig#Context.drawBufferOn [status=implemented hash=9558308f78bf]
    func drawBufferOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        draw: NativeBufferDraw
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw(abiHandle, target: target, frame: frame, draw: draw))
    }

    // parity: native/src/context.zig#Context.bufferStack [status=implemented hash=eb4477fc061c]
    func bufferStack(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        operation: NativeBufferStack
    ) throws(NativeContextEngine.ContextError) -> Double {
        try bufferStackOn(target: target, frame: frame, operation: operation)
    }

    // parity: native/src/context.zig#Context.bufferStackOn [status=implemented hash=60c4223e1c18]
    func bufferStackOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        operation: NativeBufferStack
    ) throws(NativeContextEngine.ContextError) -> Double {
        var opacity: Double = 1.0
        try checkStatus(NativeContextABI.ot_buffer_stack(abiHandle, target: target, frame: frame, operation: operation, outOpacity: &opacity))
        return opacity
    }

    // parity: native/src/context.zig#Context.drawGrid [status=implemented hash=08f60646f3e7]
    func drawGrid(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        grid: NativeBufferGrid
    ) throws(NativeContextEngine.ContextError) {
        try drawGridOn(target: target, frame: frame, grid: grid)
    }

    // parity: native/src/context.zig#Context.drawGridOn [status=implemented hash=b80cb657430a]
    func drawGridOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        grid: NativeBufferGrid
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_grid(abiHandle, target: target, frame: frame, grid: grid))
    }

    // parity: native/src/context.zig#Context.drawPackedBuffer [status=implemented hash=df6fd9554383]
    func drawPackedBuffer(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        bytes: [UInt8],
        width: UInt32,
        height: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_packed(abiHandle, target: target, frame: frame, bytes: bytes, width: width, height: height, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.drawSuperSampleBuffer [status=implemented hash=cec7e38f8b0f]
    func drawSuperSampleBuffer(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        bytes: [UInt8],
        width: UInt32,
        height: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try drawSuperSampleOn(target: target, frame: frame, bytes: bytes, width: width, height: height, x: x, y: y)
    }

    // parity: native/src/context.zig#Context.drawSuperSampleOn [status=implemented hash=856cf22e0d7e]
    func drawSuperSampleOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        bytes: [UInt8],
        width: UInt32,
        height: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_supersample(abiHandle, target: target, frame: frame, bytes: bytes, width: width, height: height, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.drawGrayscaleBuffer [status=implemented hash=7bcf6b0096f5]
    func drawGrayscaleBuffer(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        x: Int32,
        y: Int32,
        width: UInt32,
        height: UInt32,
        intensity: Double = 1.0,
        flags: UInt32 = 3
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_buffer_draw_grayscale(
                abiHandle, target: target, frame: frame, x: x, y: y, width: width, height: height, intensity: intensity, flags: flags
            )
        )
    }

    // parity: native/src/context.zig#Context.colorMatrixBuffer [status=implemented hash=04015e4c7980]
    func colorMatrixBuffer(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        matrix: [Float],
        x: Int32 = 0,
        y: Int32 = 0,
        width: UInt32? = nil,
        height: UInt32? = nil,
        strength: Double = 1.0,
        targetMask: UInt32 = 3
    ) throws(NativeContextEngine.ContextError) {
        try colorMatrixOn(target: target, frame: frame, matrix: matrix, x: x, y: y, width: width, height: height, strength: strength, targetMask: targetMask)
    }

    // parity: native/src/context.zig#Context.colorMatrixOn [status=implemented hash=904a0a31b354]
    func colorMatrixOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        matrix: [Float],
        x: Int32 = 0,
        y: Int32 = 0,
        width: UInt32? = nil,
        height: UInt32? = nil,
        strength: Double = 1.0,
        targetMask: UInt32 = 3
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_buffer_color_matrix(
                abiHandle, target: target, frame: frame, matrix: matrix, x: x, y: y, width: width, height: height, strength: strength, targetMask: targetMask
            )
        )
    }

    // parity: native/src/context.zig#Context.checkBufferDimensions [status=implemented hash=b37cfccc6803]
    func checkBufferDimensions(width: UInt32, height: UInt32) throws(NativeContextEngine.ContextError) {
        guard width > 0 && height > 0 else {
            throw .invalidOptions("buffer dimensions must be positive")
        }
        let cells = UInt64(width) * UInt64(height)
        guard cells <= UInt64(options.renderCellsMax), width <= UInt32(Int32.max), height <= UInt32(Int32.max) else {
            throw .invalidOptions("buffer dimensions exceed renderCellsMax")
        }
    }

    // parity: native/src/context.zig#Context.drawTextBufferView [status=implemented hash=74fd164d3cdb]
    func drawTextBufferView(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try drawTextViewOn(target: target, frame: frame, view: view, x: x, y: y)
    }

    // parity: native/src/context.zig#Context.drawTextViewOn [status=implemented hash=5b2454baa81c]
    func drawTextViewOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_text_view(abiHandle, target: target, frame: frame, view: view, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.drawEditorView [status=implemented hash=10803fc704e6]
    func drawEditorView(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try drawEditorViewOn(target: target, frame: frame, view: view, x: x, y: y)
    }

    // parity: native/src/context.zig#Context.drawEditorViewOn [status=implemented hash=879e0e79f8ee]
    func drawEditorViewOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_editor_view(abiHandle, target: target, frame: frame, view: view, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.drawSceneBody [status=implemented hash=a93cf6a5cbd4]
    func drawSceneBody(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        node: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try drawSceneBodyOn(target: target, frame: frame, node: node, x: x, y: y)
    }

    // parity: native/src/context.zig#Context.drawSceneBodyOn [status=implemented hash=05871baf8afc]
    func drawSceneBodyOn(
        target: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest? = nil,
        node: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_draw_scene_body(abiHandle, target: target, frame: frame, node: node, x: x, y: y))
    }

    // parity: native/src/context.zig#Context.acquireOwnedBufferLease [status=implemented hash=1e2d86c5637f]
    func acquireOwnedBufferLease(
        buffer: NativeContextEngine.Handle
    ) throws(NativeContextEngine.ContextError) -> (handle: NativeContextEngine.Handle, lease: NativeSessionBufferLease) {
        var leaseHandle = NativeContextEngine.Handle.zero
        var lease = NativeSessionBufferLease(handle: ContextObjectHandle(contextId: 0, slot: 0, generation: 0), width: 0, height: 0, generation: 0)
        try checkStatus(NativeContextABI.ot_buffer_acquire_lease(abiHandle, buffer: buffer, outLeaseHandle: &leaseHandle, outLease: &lease))
        return (leaseHandle, lease)
    }

    // parity: native/src/context.zig#Context.bufferLeaseSnapshot [status=implemented hash=b5a68db45e92]
    func bufferLeaseSnapshot(_ lease: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSessionBufferLease {
        try checkStatus(NativeContextABI.ot_buffer_lease_validate(abiHandle, lease))
        do {
            return try resolveBufferLease(lease)
        } catch let err as NativeContextHandleTable.TableError {
            throw .table(err)
        } catch {
            throw .status(Int32(NativeABI.OT_STALE_HANDLE), "\(error)")
        }
    }

    // parity: native/src/context.zig#Context.releaseBufferLease [status=implemented hash=3e19091503c6]
    func releaseBufferLease(_ lease: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_buffer_lease_release(abiHandle, lease))
    }

    // MARK: Scene Operations

    // parity: native/src/context.zig#Context.sceneCreateNode [status=implemented hash=36a42abdb84f]
    func sceneCreateNode(
        session: NativeContextEngine.Handle? = nil,
        kind: UInt32 = UInt32(NativeABI.OT_SCENE_BOX),
        num: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_scene_create_node(abiHandle, session: session, kind: kind, num: num, outNode: &out))
        return out
    }

    // parity: native/src/context.zig#Context.sceneDestroyNode [status=implemented hash=fa201e8fc9ee]
    func sceneDestroyNode(_ node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_destroy_node(abiHandle, node: node))
    }

    // parity: native/src/context.zig#Context.sceneSetMeasure [status=implemented hash=f326124d35a0]
    func sceneSetMeasure(node: NativeContextEngine.Handle, measure: FlexMeasureFunc?) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_measure(abiHandle, node: node, measure: measure))
    }

    // parity: native/src/context.zig#Context.sceneSetBoxDetails [status=implemented hash=ebb9307a9850]
    func sceneSetBoxDetails(node: NativeContextEngine.Handle, details: NativeSceneBoxDetails) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_box_details(abiHandle, node: node, details: details))
    }

    // parity: native/src/context.zig#Context.sceneSetImage [status=implemented hash=dd20ba2b4abf]
    func sceneSetImage(
        node: NativeContextEngine.Handle,
        image: NativeContextEngine.Handle?,
        fit: ImageFit = .fit,
        imageProtocol: ImageRenderProtocol = .auto,
        buffer: NativeContextEngine.Handle? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_image(abiHandle, node: node, image: image, fit: fit, imageProtocol: imageProtocol, buffer: buffer))
    }

    // parity: native/src/context.zig#Context.sceneSetCrop [status=implemented hash=fbc065ce98d1]
    func sceneSetCrop(
        node: NativeContextEngine.Handle,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_crop(abiHandle, node: node, left: left, top: top, width: width, height: height))
    }

    // parity: native/src/context.zig#Context.sceneSetVideo [status=implemented hash=ef7e264db4f8]
    func sceneSetVideo(
        node: NativeContextEngine.Handle,
        fit: ImageFit = .fit,
        buffer: NativeContextEngine.Handle? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_video(abiHandle, node: node, fit: fit, buffer: buffer))
    }

    // parity: native/src/context.zig#Context.videoOpen [status=implemented hash=25743c8d9651]
    func videoOpen(
        node: NativeContextEngine.Handle,
        path: String,
        flags: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) -> NativeVideoInfo {
        var info = NativeVideoInfo()
        try checkStatus(NativeContextABI.ot_video_open(abiHandle, node: node, path: path, flags: flags, outInfo: &info))
        return info
    }

    // parity: native/src/context.zig#Context.videoControl [status=implemented hash=ef5806053995]
    func videoControl(
        node: NativeContextEngine.Handle,
        command: String,
        intValue: Int64 = 0,
        floatValue: Float = 0,
        boolValue: Bool = false
    ) throws(NativeContextEngine.ContextError) {
        let status: Int32
        switch command {
        case "play": status = NativeContextABI.ot_video_play(abiHandle, node: node)
        case "pause": status = NativeContextABI.ot_video_pause(abiHandle, node: node)
        case "seek": status = NativeContextABI.ot_video_seek(abiHandle, node: node, timeUs: intValue)
        case "loop": status = NativeContextABI.ot_video_set_loop(abiHandle, node: node, loop: boolValue)
        case "muted": status = NativeContextABI.ot_video_set_muted(abiHandle, node: node, muted: boolValue)
        case "volume": status = NativeContextABI.ot_video_set_volume(abiHandle, node: node, volume: floatValue)
        case "avSyncOffset": status = NativeContextABI.ot_video_set_av_sync_offset(abiHandle, node: node, offsetUs: intValue)
        case "maxFps": status = NativeContextABI.ot_video_set_max_fps(abiHandle, node: node, fps: UInt32(max(0, intValue)))
        default: throw .invalidOptions("unknown video control: \(command)")
        }
        try checkStatus(status)
    }

    // parity: native/src/context.zig#Context.videoGetState [status=implemented hash=abea3b857037]
    func videoGetState(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeVideoState {
        var state = NativeVideoState()
        try checkStatus(NativeContextABI.ot_video_get_state(abiHandle, node: node, outState: &state))
        return state
    }

    // parity: native/src/context.zig#Context.videoGetError [status=implemented hash=0d2a8bb02d9a]
    func videoGetError(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var message = ""
        try checkStatus(NativeContextABI.ot_video_get_error(abiHandle, node: node, outError: &message))
        return message
    }

    // parity: native/src/context.zig#Context.sceneSetSurface [status=implemented hash=710daeec4b06]
    func sceneSetSurface(node: NativeContextEngine.Handle, buffer: NativeContextEngine.Handle?) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_surface(abiHandle, node: node, buffer: buffer))
    }

    // parity: native/src/context.zig#Context.sceneSetEditorView [status=implemented hash=8875d2bd4a7f]
    func sceneSetEditorView(node: NativeContextEngine.Handle, view: NativeContextEngine.Handle?) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_editor_view(abiHandle, node: node, view: view))
    }

    // parity: native/src/context.zig#Context.sceneSetEditorOptions [status=implemented hash=9e1a06962efc]
    func sceneSetEditorOptions(node: NativeContextEngine.Handle, options: NativeSceneEditorOptions) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_editor_options(abiHandle, node: node, options: options))
    }

    // parity: native/src/context.zig#Context.sceneSetTextView [status=implemented hash=314fcf7b526b]
    func sceneSetTextView(node: NativeContextEngine.Handle, view: NativeContextEngine.Handle?) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_text_view(abiHandle, node: node, view: view))
    }

    // parity: native/src/context.zig#Context.sceneSetTextViewPaint [status=implemented hash=a95cbd6d6eca]
    func sceneSetTextViewPaint(node: NativeContextEngine.Handle, enabled: Bool) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_text_view_paint(abiHandle, node: node, enabled: enabled))
    }

    // parity: native/src/context.zig#Context.sceneHasMeasure [status=implemented hash=147d4adf7022]
    func sceneHasMeasure(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> Bool {
        var has = false
        try checkStatus(NativeContextABI.ot_scene_has_measure(abiHandle, node: node, outHasMeasure: &has))
        return has
    }

    // parity: native/src/context.zig#Context.sceneReachesHooks [status=implemented hash=e53e90280ff6]
    func sceneReachesHooks(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> Bool {
        var reaches = false
        try checkStatus(NativeContextABI.ot_scene_reaches_hooks(abiHandle, node: node, outReaches: &reaches))
        return reaches
    }

    // parity: native/src/context.zig#Context.scenePainted [status=implemented hash=dba9c2bef5d5]
    func scenePainted(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> Bool {
        var painted = false
        try checkStatus(NativeContextABI.ot_scene_painted(abiHandle, node: node, outPainted: &painted))
        return painted
    }

    // parity: native/src/context.zig#Context.sceneMarkDirty [status=implemented hash=bd678dc9ae6f]
    func sceneMarkDirty(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_mark_dirty(abiHandle, node: node))
    }

    // parity: native/src/context.zig#Context.checkSceneRead [status=implemented hash=36e60b22556d]
    func checkSceneRead() throws(NativeContextEngine.ContextError) {
        guard !isDestroyed else { throw .table(.staleHandle) }
    }

    // parity: native/src/context.zig#Context.sceneMoveNode [status=implemented hash=f637cd48ceae]
    func sceneMoveNode(
        node: NativeContextEngine.Handle,
        parent: NativeContextEngine.Handle?,
        index: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_move_node(abiHandle, node: node, parent: parent, index: index))
    }

    // parity: native/src/context.zig#Context.sceneClearChildren [status=implemented hash=477ea31e931a]
    func sceneClearChildren(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_clear_children(abiHandle, node: node))
    }

    // parity: native/src/context.zig#Context.sceneSetStyle [status=implemented hash=d0360770ca75]
    func sceneSetStyle(
        node: NativeContextEngine.Handle,
        group: UInt32,
        kind: UInt32,
        edge: UInt32,
        unit: UInt32,
        value: Float,
        flags: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try sceneSetStyleLocked(node: node, group: group, kind: kind, edge: edge, unit: unit, value: value, flags: flags)
    }

    // parity: native/src/context.zig#Context.sceneSetStyleLocked [status=implemented hash=98729b7ed116]
    func sceneSetStyleLocked(
        node: NativeContextEngine.Handle,
        group: UInt32,
        kind: UInt32,
        edge: UInt32,
        unit: UInt32,
        value: Float,
        flags: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_style(abiHandle, node: node, group: group, kind: kind, edge: edge, unit: unit, value: value, flags: flags))
    }

    // parity: native/src/context.zig#Context.sceneGetStyle [status=implemented hash=2c0bfca2cdb9]
    func sceneGetStyle(
        node: NativeContextEngine.Handle,
        group: NativeStyleGroup,
        kind: Int32,
        edge: Int32 = 0
    ) throws(NativeContextEngine.ContextError) -> YogaValue {
        var out = YogaValue(unit: .undefined, value: 0)
        try checkStatus(NativeContextABI.ot_scene_get_style(abiHandle, node: node, group: group, kind: kind, edge: edge, outValue: &out))
        return out
    }

    // parity: native/src/context.zig#Context.sceneSetPositions [status=implemented hash=5a53acff5a08]
    func sceneSetPositions(
        node: NativeContextEngine.Handle,
        left: Float? = nil,
        top: Float? = nil,
        right: Float? = nil,
        bottom: Float? = nil
    ) throws(NativeContextEngine.ContextError) {
        let edges: [(UInt32, Float?)] = [
            (UInt32(NativeABI.OT_EDGE_LEFT), left),
            (UInt32(NativeABI.OT_EDGE_TOP), top),
            (UInt32(NativeABI.OT_EDGE_RIGHT), right),
            (UInt32(NativeABI.OT_EDGE_BOTTOM), bottom),
        ]
        for (edge, value) in edges {
            if let value {
                try sceneSetStyle(
                    node: node,
                    group: UInt32(NativeStyleGroup.value.rawValue),
                    kind: UInt32(NativeABI.OT_STYLE_VALUE_POSITION),
                    edge: edge,
                    unit: UInt32(NativeABI.OT_UNIT_POINT),
                    value: value
                )
            }
        }
    }

    // parity: native/src/context.zig#Context.sceneSetPaint [status=implemented hash=b6f17b1e0cc8]
    func sceneSetPaint(node: NativeContextEngine.Handle, update: NativeScenePaintUpdate) throws(NativeContextEngine.ContextError) {
        try scenePatchPaintLocked(node: node, update: update)
    }

    // parity: native/src/context.zig#Context.scenePatchPaint [status=implemented hash=dad77522e7f1]
    func scenePatchPaint(node: NativeContextEngine.Handle, update: NativeScenePaintUpdate) throws(NativeContextEngine.ContextError) {
        try scenePatchPaintLocked(node: node, update: update)
    }

    // parity: native/src/context.zig#Context.scenePatchPaintLocked [status=implemented hash=a20a116fe793]
    func scenePatchPaintLocked(node: NativeContextEngine.Handle, update: NativeScenePaintUpdate) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_paint(abiHandle, node: node, update: update))
    }

    // parity: native/src/context.zig#Context.sceneSetViewport [status=implemented hash=d9b8d8f69ec4]
    func sceneSetViewport(content: NativeContextEngine.Handle, viewport: NativeContextEngine.Handle?) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_viewport(abiHandle, content: content, viewport: viewport))
    }

    // parity: native/src/context.zig#Context.sceneSetScroll [status=implemented hash=27a55be99927]
    func sceneSetScroll(node: NativeContextEngine.Handle, options: NativeSceneScrollOptions) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_scroll(abiHandle, node: node, options: options))
    }

    // parity: native/src/context.zig#Context.sceneSetScrollArrow [status=implemented hash=2a401b4b8285]
    func sceneSetScrollArrow(
        node: NativeContextEngine.Handle,
        axis: UInt32,
        end: UInt32,
        options: NativeSceneArrowOptions
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_scroll_arrow(abiHandle, node: node, axis: axis, end: end, options: options))
    }

    // parity: native/src/context.zig#Context.sceneScrollTo [status=implemented hash=fb19054803db]
    func sceneScrollTo(
        node: NativeContextEngine.Handle,
        x: Double,
        y: Double,
        flags: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) -> NativeSceneScrollState {
        var state = NativeSceneScrollState()
        try checkStatus(NativeContextABI.ot_scene_scroll_to(abiHandle, node: node, x: x, y: y, flags: flags, outState: &state))
        return state
    }

    // parity: native/src/context.zig#Context.sceneScrollRequest [status=implemented hash=de5e541b00d1]
    func sceneScrollRequest(
        node: NativeContextEngine.Handle,
        kind: NativeSceneScrollRequestKind,
        target: NativeContextEngine.Handle? = nil,
        align: NativeSceneScrollAlign = .nearest,
        inset: Double = 0
    ) throws(NativeContextEngine.ContextError) -> NativeSceneScrollState {
        var state = NativeSceneScrollState()
        try checkStatus(NativeContextABI.ot_scene_scroll_request(abiHandle, node: node, kind: kind, target: target, align: align, inset: inset, outState: &state))
        return state
    }

    // parity: native/src/context.zig#Context.sceneGetScroll [status=implemented hash=31053b4bf5f8]
    func sceneGetScroll(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSceneScrollState {
        var state = NativeSceneScrollState()
        try checkStatus(NativeContextABI.ot_scene_get_scroll(abiHandle, node: node, outState: &state))
        return state
    }

    // parity: native/src/context.zig#Context.sceneSetFocus [status=implemented hash=2b692720001f]
    func sceneSetFocus(node: NativeContextEngine.Handle, focused: Bool) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_focus(abiHandle, node: node, focused: focused))
    }

    // parity: native/src/context.zig#Context.sceneSetHooks [status=implemented hash=531badf2998e]
    func sceneSetHooks(
        node: NativeContextEngine.Handle,
        flags: UInt32,
        generation: UInt64 = 1,
        initialWidth: UInt32 = 0,
        initialHeight: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_hooks(abiHandle, node: node, flags: flags, generation: generation, initialWidth: initialWidth, initialHeight: initialHeight))
    }

    // parity: native/src/context.zig#Context.sceneSetSlider [status=implemented hash=aed5d566b624]
    func sceneSetSlider(node: NativeContextEngine.Handle, options: NativeSceneSliderOptions) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_slider(abiHandle, node: node, options: options))
    }

    // parity: native/src/context.zig#Context.sceneGetSliderThumb [status=implemented hash=2041434a1eaf]
    func sceneGetSliderThumb(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> SliderThumb {
        var thumb = SliderThumb(size: 0, start: 0)
        try checkStatus(NativeContextABI.ot_scene_get_slider_thumb(abiHandle, node: node, outThumb: &thumb))
        return thumb
    }

    // parity: native/src/context.zig#Context.sceneSetArrow [status=implemented hash=3f4751d40829]
    func sceneSetArrow(node: NativeContextEngine.Handle, options: NativeSceneArrowOptions) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_arrow(abiHandle, node: node, options: options))
    }

    // parity: native/src/context.zig#Context.sceneSetText [status=implemented hash=f642c4a20c08]
    func sceneSetText(node: NativeContextEngine.Handle, text: String) throws(NativeContextEngine.ContextError) {
        try Self.validateTextBytes(Array(text.utf8))
        try checkStatus(NativeContextABI.ot_scene_set_text(abiHandle, node: node, text: text))
    }

    // parity: native/src/context.zig#Context.validateTextBytes [status=implemented hash=112efe6a31dc]
    static func validateTextBytes(_ bytes: [UInt8]) throws(NativeContextEngine.ContextError) {
        guard bytes.count <= 64 * 1024 * 1024 else {
            throw .invalidOptions("text exceeds maximum byte length")
        }
        guard String(validating: bytes, as: UTF8.self) != nil else {
            throw .invalidOptions("text contains invalid UTF-8")
        }
    }

    // parity: native/src/context.zig#Context.sceneSetStyledText [status=implemented hash=e0dda02a77f1]
    func sceneSetStyledText(
        node: NativeContextEngine.Handle,
        chunks: [NativeContextEngine.StyledTextChunk]
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_styled_text(abiHandle, node: node, chunks: chunks))
    }

    // parity: native/src/context.zig#Context.sceneSetTextOptions [status=implemented hash=4af5053e6407]
    func sceneSetTextOptions(node: NativeContextEngine.Handle, options: NativeSceneTextOptions) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_text_options(abiHandle, node: node, options: options))
    }

    // parity: native/src/context.zig#Context.sceneSetTextSelection [status=implemented hash=bc11e48f3b7a]
    func sceneSetTextSelection(
        node: NativeContextEngine.Handle,
        options: NativeSceneTextSelectionOptions
    ) throws(NativeContextEngine.ContextError) -> Bool {
        var changed = false
        try checkStatus(NativeContextABI.ot_scene_set_text_selection(abiHandle, node: node, options: options, outChanged: &changed))
        return changed
    }

    // parity: native/src/context.zig#Context.sceneGetTextSelection [status=implemented hash=288c0faa8048]
    func sceneGetTextSelection(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> UInt64 {
        var packed: UInt64 = 0
        try checkStatus(NativeContextABI.ot_scene_get_text_selection(abiHandle, node: node, outPacked: &packed))
        return packed
    }

    // parity: native/src/context.zig#Context.sceneGetSelectedText [status=implemented hash=b638d21e660d]
    func sceneGetSelectedText(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_scene_get_selected_text(abiHandle, node: node, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.textBufferGetRange [status=implemented hash=62d042b7a84b]
    func textBufferGetRange(
        textBuffer: NativeContextEngine.Handle,
        start: UInt32,
        end: UInt32
    ) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_text_buffer_get_range(abiHandle, textBuffer: textBuffer, start: start, end: end, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.editBufferGetRange [status=implemented hash=96bb3034379e]
    func editBufferGetRange(
        editBuffer: NativeContextEngine.Handle,
        byCoords: Bool = false,
        startA: UInt32,
        startB: UInt32 = 0,
        endA: UInt32,
        endB: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(
            NativeContextABI.ot_edit_buffer_get_range(
                abiHandle, editBuffer: editBuffer, byCoords: byCoords, startA: startA, startB: startB, endA: endA, endB: endB, outText: &text
            )
        )
        return text
    }

    // parity: native/src/context.zig#Context.editMeasureText [status=implemented hash=d4d5b1394a79]
    func editMeasureText(editBuffer: NativeContextEngine.Handle, text: String) throws(NativeContextEngine.ContextError) -> UInt32 {
        var width: UInt32 = 0
        try checkStatus(NativeContextABI.ot_edit_buffer_measure_text(abiHandle, editBuffer: editBuffer, text: text, outWidth: &width))
        return width
    }

    // parity: native/src/context.zig#Context.measureEditText [status=implemented hash=f73f79871de5]
    func measureEditText(
        text: String,
        widthMethod: UInt32 = UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE),
        tabWidth: UInt32 = 2
    ) throws(NativeContextEngine.ContextError) -> UInt32 {
        var width: UInt32 = 0
        try checkStatus(NativeContextABI.ot_edit_measure_text(abiHandle, text: text, widthMethod: widthMethod, tabWidth: tabWidth, outWidth: &width))
        return width
    }

    // parity: native/src/context.zig#Context.textViewGetSelectedText [status=implemented hash=e15f59888a6f]
    func textViewGetSelectedText(view: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_text_buffer_view_get_selected_text(abiHandle, view: view, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.editorGetSelectedText [status=implemented hash=2850cb3d8a21]
    func editorGetSelectedText(view: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_editor_view_get_selected_text(abiHandle, view: view, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.sceneGetText [status=implemented hash=aae659235d24]
    func sceneGetText(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var text = ""
        try checkStatus(NativeContextABI.ot_scene_get_text(abiHandle, node: node, outText: &text))
        return text
    }

    // parity: native/src/context.zig#Context.sceneGetTextInfo [status=implemented hash=f52d6accd702]
    func sceneGetTextInfo(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSceneTextMetrics {
        var metrics = NativeSceneTextMetrics()
        try checkStatus(NativeContextABI.ot_scene_get_text_info(abiHandle, node: node, outMetrics: &metrics))
        return metrics
    }

    // parity: native/src/context.zig#Context.sceneGetTextLines [status=implemented hash=9e630d6a117c]
    func sceneGetTextLines(
        node: NativeContextEngine.Handle,
        firstLine: UInt32 = 0,
        lineCount: UInt32? = nil
    ) throws(NativeContextEngine.ContextError) -> LineInfo {
        var info = LineInfo(lineStartCols: [], lineWidthCols: [], lineWidthColsMax: 0, lineSources: [], lineWraps: [])
        try checkStatus(NativeContextABI.ot_scene_get_text_lines(abiHandle, node: node, firstLine: firstLine, lineCount: lineCount, outInfo: &info))
        return info
    }

    // parity: native/src/context.zig#Context.sceneGetTextByteAt [status=implemented hash=9801598f02f4]
    func sceneGetTextByteAt(node: NativeContextEngine.Handle, x: Int32, y: Int32) throws(NativeContextEngine.ContextError) -> UInt32 {
        var offset: UInt32 = 0
        try checkStatus(NativeContextABI.ot_scene_get_text_byte_at(abiHandle, node: node, x: x, y: y, outByteOffset: &offset))
        return offset
    }

    // parity: native/src/context.zig#Context.sceneGetLayout [status=implemented hash=eb485abd47c1]
    func sceneGetLayout(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSceneLayout {
        var layout = NativeSceneLayout()
        try checkStatus(NativeContextABI.ot_scene_get_layout(abiHandle, node: node, kind: .computed, outLayout: &layout))
        return layout
    }

    // parity: native/src/context.zig#Context.sceneGetPaintLayout [status=implemented hash=5ed66b2b9103]
    func sceneGetPaintLayout(node: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeSceneLayout {
        var layout = NativeSceneLayout()
        try checkStatus(NativeContextABI.ot_scene_get_layout(abiHandle, node: node, kind: .paint, outLayout: &layout))
        return layout
    }

    // parity: native/src/context.zig#Context.sceneMeasureLayout [status=implemented hash=f1e728dd0ff7]
    func sceneMeasureLayout(
        session: NativeContextEngine.Handle? = nil,
        root: NativeContextEngine.Handle,
        availableWidth: Float? = nil
    ) throws(NativeContextEngine.ContextError) -> Int {
        var rounds = 0
        try checkStatus(NativeContextABI.ot_scene_measure_layout(abiHandle, session: session, root: root, availableWidth: availableWidth, outRounds: &rounds))
        return rounds
    }

    // parity: native/src/context.zig#Context.scenePaint [status=implemented hash=0eb4d8c95154]
    func scenePaint(
        session: NativeContextEngine.Handle,
        root: NativeContextEngine.Handle,
        background: RGBA = RGBA.fromInts(0, 0, 0, 255),
        useMouse: Bool = false,
        excludedHitNum: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_paint(abiHandle, session: session, root: root, background: background, useMouse: useMouse, excludedHitNum: excludedHitNum))
    }

    // parity: native/src/context.zig#Context.sceneFrameStep [status=implemented hash=6fabe7278f3b]
    func sceneFrameStep(
        session: NativeContextEngine.Handle,
        root: NativeContextEngine.Handle,
        options: NativeSceneFrameOptions = NativeSceneFrameOptions(),
        previous: NativeSceneFrameRequest? = nil
    ) throws(NativeContextEngine.ContextError) -> NativeSceneFrameRequest {
        try sceneFrameStepWithRecording(session: session, root: root, options: options, previous: previous, recording: nil)
    }

    // parity: native/src/context.zig#Context.sceneFrameStepWithRecording [status=implemented hash=7b99bba287e1]
    func sceneFrameStepWithRecording(
        session: NativeContextEngine.Handle,
        root: NativeContextEngine.Handle,
        options: NativeSceneFrameOptions = NativeSceneFrameOptions(),
        previous: NativeSceneFrameRequest? = nil,
        recording: [UInt8]? = nil
    ) throws(NativeContextEngine.ContextError) -> NativeSceneFrameRequest {
        _ = recording
        var req = NativeSceneFrameRequest(
            session: SessionHandle(contextId: session.contextId, slot: session.slot, generation: session.generation),
            root: SceneNodeHandle(contextId: root.contextId, slot: root.slot, generation: root.generation),
            node: SceneNodeHandle(contextId: root.contextId, slot: root.slot, generation: root.generation),
            frameId: 0,
            requestId: 0,
            layoutEpoch: 0,
            kind: .done
        )
        try checkStatus(
            NativeContextABI.ot_scene_frame_step_with_geometry(
                abiHandle, session: session, root: root, options: options, previous: previous, outRequest: &req
            )
        )
        return req
    }

    // parity: native/src/context.zig#Context.sceneFramePaintSlots [status=implemented hash=235cd6e6e988]
    func sceneFramePaintSlots(
        session: NativeContextEngine.Handle,
        request: NativeSceneFrameRequest
    ) throws(NativeContextEngine.ContextError) -> [NativeScenePaintSlot] {
        var slots: [NativeScenePaintSlot] = []
        try checkStatus(NativeContextABI.ot_scene_frame_get_paint_slots(abiHandle, session: session, request: request, outSlots: &slots))
        return slots
    }

    // parity: native/src/context.zig#Context.sceneFrameAcquireBufferLease [status=implemented hash=aa0ffce0af8c]
    func sceneFrameAcquireBufferLease(
        session: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest
    ) throws(NativeContextEngine.ContextError) -> (handle: NativeContextEngine.Handle, lease: NativeSessionBufferLease) {
        var handle = NativeContextEngine.Handle.zero
        var lease = NativeSessionBufferLease(handle: ContextObjectHandle(contextId: 0, slot: 0, generation: 0), width: 0, height: 0, generation: 0)
        try checkStatus(NativeContextABI.ot_scene_frame_acquire_buffer_lease(abiHandle, session: session, frame: frame, outLeaseHandle: &handle, outLease: &lease))
        return (handle, lease)
    }

    // parity: native/src/context.zig#Context.sceneFrameDrawBuffer [status=implemented hash=2725d85ff65e]
    func sceneFrameDrawBuffer(
        session: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest,
        source: NativeContextEngine.Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        crop: NativeContextEngine.BufferCrop? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_frame_draw_buffer(abiHandle, session: session, frame: frame, source: source, x: x, y: y, crop: crop))
    }

    // parity: native/src/context.zig#Context.sceneFrameCommit [status=implemented hash=3c1d1413ccf9]
    func sceneFrameCommit(
        session: NativeContextEngine.Handle,
        frame: NativeSceneFrameRequest,
        force: Bool = false
    ) throws(NativeContextEngine.ContextError) -> UInt32 {
        var status: UInt32 = 0
        try checkStatus(NativeContextABI.ot_scene_frame_commit(abiHandle, session: session, frame: frame, force: force, outRenderStatus: &status))
        return status
    }

    // parity: native/src/context.zig#Context.sceneFrameCancel [status=implemented hash=ed02b4414a2f]
    func sceneFrameCancel(session: NativeContextEngine.Handle, frame: NativeSceneFrameRequest) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_frame_cancel(abiHandle, session: session, frame: frame))
    }

    // parity: native/src/context.zig#Context.sceneHitTest [status=implemented hash=cf1124754107]
    func sceneHitTest(root: NativeContextEngine.Handle, x: Int32, y: Int32) throws(NativeContextEngine.ContextError) -> UInt32 {
        var hit: UInt32 = 0
        try checkStatus(NativeContextABI.ot_scene_hit_test(abiHandle, root: root, x: x, y: y, outHitNum: &hit))
        return hit
    }

    // parity: native/src/context.zig#Context.sceneHitTestExcluding [status=implemented hash=3732a1d53efa]
    func sceneHitTestExcluding(
        root: NativeContextEngine.Handle,
        x: Int32,
        y: Int32,
        excludedNum: UInt32
    ) throws(NativeContextEngine.ContextError) -> UInt32 {
        var hit: UInt32 = 0
        try checkStatus(NativeContextABI.ot_scene_hit_test_excluding(abiHandle, root: root, x: x, y: y, excludedNum: excludedNum, outHitNum: &hit))
        return hit
    }

    // parity: native/src/context.zig#Context.sceneSetDebugFlags [status=implemented hash=314705d72b1c]
    func sceneSetDebugFlags(session: NativeContextEngine.Handle? = nil, flags: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_scene_set_debug_flags(abiHandle, session: session, flags: flags))
    }

    // parity: native/src/context.zig#Context.sceneGetStats [status=implemented hash=53e0f6330569]
    func sceneGetStats(session: NativeContextEngine.Handle? = nil) throws(NativeContextEngine.ContextError) -> OpenTUICore.NativeRenderStats {
        var stats = OpenTUICore.NativeRenderStats()
        try checkStatus(NativeContextABI.ot_scene_get_stats(abiHandle, session: session, outStats: &stats))
        return stats
    }

    // parity: native/src/context.zig#Context.sceneGetCursorState [status=implemented hash=72ee469e7695]
    func sceneGetCursorState(session: NativeContextEngine.Handle? = nil) throws(NativeContextEngine.ContextError) -> CursorState {
        var cursor = CursorState(x: 0, y: 0, visible: false)
        try checkStatus(NativeContextABI.ot_scene_get_cursor_state(abiHandle, session: session, outCursor: &cursor))
        return cursor
    }

    // MARK: TextBuffer, TextBufferView, SyntaxStyle & Markdown

    // parity: native/src/context.zig#Context.createTextBuffer [status=implemented hash=ced977db7b82]
    func createTextBuffer(
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions()
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_text_buffer_create(abiHandle, options: options, outTextBuffer: &out))
        return out
    }

    // parity: native/src/context.zig#Context.createTextBufferView [status=implemented hash=7895ba7145fd]
    func createTextBufferView(textBuffer: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_text_buffer_view_create(abiHandle, textBuffer: textBuffer, outView: &out))
        return out
    }

    // parity: native/src/context.zig#Context.textBufferSetText [status=implemented hash=36de1065811d]
    func textBufferSetText(textBuffer: NativeContextEngine.Handle, text: String) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_text(abiHandle, textBuffer: textBuffer, text: text))
    }

    // parity: native/src/context.zig#Context.textBufferSetStyledText [status=implemented hash=4916d7ca1bcc]
    func textBufferSetStyledText(textBuffer: NativeContextEngine.Handle, chunks: [TextChunk]) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_styled_text(abiHandle, textBuffer: textBuffer, chunks: chunks))
    }

    // parity: native/src/context.zig#Context.textBufferReplaceStyledBatch [status=implemented hash=98aecc1653a9]
    func textBufferReplaceStyledBatch(
        updates: [(textBuffer: NativeContextEngine.Handle, chunks: [TextChunk])]
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_replace_styled_batch(abiHandle, updates: updates))
    }

    // parity: native/src/context.zig#Context.textBufferAppend [status=implemented hash=ab5e27a023ca]
    func textBufferAppend(textBuffer: NativeContextEngine.Handle, text: String) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_append(abiHandle, textBuffer: textBuffer, text: text))
    }

    // parity: native/src/context.zig#Context.textBufferClear [status=implemented hash=d58b5943977d]
    func textBufferClear(textBuffer: NativeContextEngine.Handle, reset: Bool = false) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_clear(abiHandle, textBuffer: textBuffer, reset: reset))
    }

    // parity: native/src/context.zig#Context.textBufferSetSyntaxStyle [status=implemented hash=c4ce305d5e7f]
    func textBufferSetSyntaxStyle(
        textBuffer: NativeContextEngine.Handle,
        style: NativeContextEngine.Handle?
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_syntax_style(abiHandle, textBuffer: textBuffer, style: style))
    }

    // parity: native/src/context.zig#Context.textBufferSetDefaults [status=implemented hash=337023a890ff]
    func textBufferSetDefaults(
        textBuffer: NativeContextEngine.Handle,
        mask: UInt32,
        options: NativeEditorStyle?
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_defaults(abiHandle, textBuffer: textBuffer, mask: mask, options: options))
    }

    // parity: native/src/context.zig#Context.editBufferSetTabWidth [status=implemented hash=e6d3304426ba]
    func editBufferSetTabWidth(editBuffer: NativeContextEngine.Handle, width: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_tab_width(abiHandle, editBuffer: editBuffer, width: width))
    }

    // parity: native/src/context.zig#Context.textBufferSetTabWidth [status=implemented hash=8ab1d3d4a1f1]
    func textBufferSetTabWidth(textBuffer: NativeContextEngine.Handle, width: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_tab_width(abiHandle, textBuffer: textBuffer, width: width))
    }

    // parity: native/src/context.zig#Context.textBufferSetWidthMethod [status=implemented hash=b0adf6f7ad1c]
    func textBufferSetWidthMethod(textBuffer: NativeContextEngine.Handle, widthMethod: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_width_method(abiHandle, textBuffer: textBuffer, widthMethod: widthMethod))
    }

    // parity: native/src/context.zig#Context.textBufferHighlight [status=implemented hash=23ebb39a81f7]
    func textBufferHighlight(
        textBuffer: NativeContextEngine.Handle,
        operation: UInt32,
        argument: UInt32 = 0,
        highlight: Highlight? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_highlight(abiHandle, textBuffer: textBuffer, operation: operation, argument: argument, highlight: highlight))
    }

    // parity: native/src/context.zig#Context.textBufferSetLayer [status=implemented hash=ff379c8779d9]
    func textBufferSetLayer(
        textBuffer: NativeContextEngine.Handle,
        layerId: UInt32,
        startByte: UInt32,
        endByte: UInt32,
        runs: [Highlight]
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_set_layer(abiHandle, textBuffer: textBuffer, layerId: layerId, startByte: startByte, endByte: endByte, runs: runs))
    }

    // parity: native/src/context.zig#Context.groupSet [status=implemented hash=01d7b4c308f8]
    func groupSet(target: NativeContextEngine.Handle, groupIds: [UInt32]) throws(NativeContextEngine.ContextError) -> UInt32 {
        var count: UInt32 = 0
        try checkStatus(NativeContextABI.ot_context_group_set(abiHandle, target: target, groupIds: groupIds, outCount: &count))
        return count
    }

    // parity: native/src/context.zig#Context.textViewSetViewport [status=implemented hash=ca41a0c85306]
    func textViewSetViewport(
        view: NativeContextEngine.Handle,
        viewport: NativeEditorViewport,
        sizeOnly: Bool = false
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_view_set_viewport(abiHandle, view: view, viewport: viewport, sizeOnly: sizeOnly))
    }

    // parity: native/src/context.zig#Context.textViewCommand [status=implemented hash=8d2643377726]
    func textViewCommand(
        view: NativeContextEngine.Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_view_command(abiHandle, view: view, command: command, argument: argument))
    }

    // parity: native/src/context.zig#Context.textViewSetTabColor [status=implemented hash=f8a3271e3a20]
    func textViewSetTabColor(view: NativeContextEngine.Handle, color: RGBA) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_text_buffer_view_set_tab_color(abiHandle, view: view, color: color))
    }

    // parity: native/src/context.zig#Context.textViewSelect [status=implemented hash=929d9d6e9a81]
    func textViewSelect(
        view: NativeContextEngine.Handle,
        options: NativeEditorSelection
    ) throws(NativeContextEngine.ContextError) -> Bool {
        var changed = false
        try checkStatus(NativeContextABI.ot_text_buffer_view_select(abiHandle, view: view, options: options, outChanged: &changed))
        return changed
    }

    // parity: native/src/context.zig#Context.createEditBuffer [status=implemented hash=e7ff4d9e3621]
    func createEditBuffer(
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions()
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_edit_buffer_create(abiHandle, options: options, outHandle: &out))
        return out
    }

    // parity: native/src/context.zig#Context.createEditorView [status=implemented hash=37984258680a]
    func createEditorView(
        editBuffer: NativeContextEngine.Handle,
        width: UInt32,
        height: UInt32
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_editor_view_create(abiHandle, editBuffer: editBuffer, width: width, height: height, outHandle: &out))
        return out
    }

    // parity: native/src/context.zig#Context.createSyntaxStyle [status=implemented hash=b30a1922416e]
    func createSyntaxStyle() throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_syntax_style_create(abiHandle, outHandle: &out))
        return out
    }

    // parity: native/src/context.zig#Context.syntaxStyleRegister [status=implemented hash=87b40aac90a3]
    func syntaxStyleRegister(
        style: NativeContextEngine.Handle,
        name: String,
        definition: NativeEditorStyle
    ) throws(NativeContextEngine.ContextError) -> UInt32 {
        var styleId: UInt32 = 0
        try checkStatus(NativeContextABI.ot_syntax_style_register(abiHandle, style: style, name: name, definition: definition, outStyleId: &styleId))
        return styleId
    }

    // parity: native/src/context.zig#Context.createMarkdown [status=implemented hash=9b8eccebd056]
    func createMarkdown(
        options: NativeMarkdownOptions = NativeMarkdownOptions()
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.Handle {
        var out = NativeContextEngine.Handle.zero
        try checkStatus(NativeContextABI.ot_markdown_create(abiHandle, options: options, outDoc: &out))
        return out
    }

    // parity: native/src/context.zig#Context.markdownCall [status=implemented hash=268d0917a435]
    func markdownCall(
        doc: NativeContextEngine.Handle,
        action: String,
        text: String = "",
        options: NativeMarkdownOptions? = nil
    ) throws(NativeContextEngine.ContextError) -> NativeMarkdownResult {
        var result = NativeMarkdownResult()
        let status: Int32
        switch action {
        case "append": status = NativeContextABI.ot_markdown_append(abiHandle, doc: doc, text: text, outResult: &result)
        case "set": status = NativeContextABI.ot_markdown_set(abiHandle, doc: doc, text: text, outResult: &result)
        case "finish": status = NativeContextABI.ot_markdown_finish(abiHandle, doc: doc, outResult: &result)
        case "setOptions":
            status = NativeContextABI.ot_markdown_set_options(abiHandle, doc: doc, options: options ?? NativeMarkdownOptions(), outResult: &result)
        default:
            throw .invalidOptions("unknown markdown action: \(action)")
        }
        try checkStatus(status)
        return result
    }

    // parity: native/src/context.zig#Context.markdownSource [status=implemented hash=78206baefd4b]
    func markdownSource(doc: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> String {
        var source = ""
        try checkStatus(NativeContextABI.ot_markdown_get_source(abiHandle, doc: doc, outSource: &source))
        return source
    }

    // parity: native/src/context.zig#Context.markdownReadChanges [status=implemented hash=db7899510410]
    func markdownReadChanges(doc: NativeContextEngine.Handle) throws(NativeContextEngine.ContextError) -> [NativeMarkdownBlock] {
        var blocks: [NativeMarkdownBlock] = []
        try checkStatus(NativeContextABI.ot_markdown_read_changes(abiHandle, doc: doc, outBlocks: &blocks))
        return blocks
    }

    // parity: native/src/context.zig#Context.markdownReadLeaf [status=implemented hash=a0299bc218a9]
    func markdownReadLeaf(
        doc: NativeContextEngine.Handle,
        blockIndex: UInt32
    ) throws(NativeContextEngine.ContextError) -> NativeMarkdownLeaf {
        var leaf = NativeMarkdownLeaf()
        try checkStatus(NativeContextABI.ot_markdown_read_leaf(abiHandle, doc: doc, blockIndex: blockIndex, outLeaf: &leaf))
        return leaf
    }

    // parity: native/src/context.zig#Context.markdownReadSource [status=implemented hash=cb9ef4ceea85]
    func markdownReadSource(
        doc: NativeContextEngine.Handle,
        blockIndex: UInt32
    ) throws(NativeContextEngine.ContextError) -> String {
        var source = ""
        try checkStatus(NativeContextABI.ot_markdown_read_source(abiHandle, doc: doc, blockIndex: blockIndex, outSource: &source))
        return source
    }

    // parity: native/src/context.zig#Context.markdownBind [status=implemented hash=08c2dc33f9bf]
    func markdownBind(
        doc: NativeContextEngine.Handle,
        blockIndex: UInt32,
        node: NativeContextEngine.Handle
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_markdown_bind(abiHandle, doc: doc, blockIndex: blockIndex, node: node))
    }

    // MARK: EditBuffer & EditorView Operations

    // parity: native/src/context.zig#Context.editSetSyntaxStyle [status=implemented hash=942d703ba028]
    func editSetSyntaxStyle(
        editBuffer: NativeContextEngine.Handle,
        style: NativeContextEngine.Handle?
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_syntax_style(abiHandle, editBuffer: editBuffer, style: style))
    }

    // parity: native/src/context.zig#Context.editSetText [status=implemented hash=690510a2baf9]
    func editSetText(
        editBuffer: NativeContextEngine.Handle,
        text: String,
        preserveHistory: Bool = false
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_text(abiHandle, editBuffer: editBuffer, text: text, preserveHistory: preserveHistory))
    }

    // parity: native/src/context.zig#Context.editInsertText [status=implemented hash=bc78aa3f1ae4]
    func editInsertText(editBuffer: NativeContextEngine.Handle, text: String) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_insert_text(abiHandle, editBuffer: editBuffer, text: text))
    }

    // parity: native/src/context.zig#Context.editDeleteRange [status=implemented hash=18f5afb66457]
    func editDeleteRange(
        editBuffer: NativeContextEngine.Handle,
        startRow: UInt32,
        startCol: UInt32,
        endRow: UInt32,
        endCol: UInt32
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(
            NativeContextABI.ot_edit_buffer_delete_range(
                abiHandle, editBuffer: editBuffer, startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol
            )
        )
    }

    // parity: native/src/context.zig#Context.editSetCursor [status=implemented hash=1f1a558123c6]
    func editSetCursor(editBuffer: NativeContextEngine.Handle, row: UInt32, col: UInt32) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_cursor(abiHandle, editBuffer: editBuffer, row: row, col: col))
    }

    // parity: native/src/context.zig#Context.editHistory [status=implemented hash=9f1f319114a0]
    func editHistory(editBuffer: NativeContextEngine.Handle, redo: Bool) throws(NativeContextEngine.ContextError) -> String? {
        var meta: String? = nil
        try checkStatus(NativeContextABI.ot_edit_buffer_history(abiHandle, editBuffer: editBuffer, redo: redo, outMeta: &meta))
        return meta
    }

    // parity: native/src/context.zig#Context.editCommand [status=implemented hash=12bfe400802a]
    func editCommand(
        editBuffer: NativeContextEngine.Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_command(abiHandle, editBuffer: editBuffer, command: command, argument: argument))
    }

    // parity: native/src/context.zig#Context.editSetDefaults [status=implemented hash=a6e1df847c42]
    func editSetDefaults(
        editBuffer: NativeContextEngine.Handle,
        mask: UInt32,
        options: NativeEditorStyle?
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_defaults(abiHandle, editBuffer: editBuffer, mask: mask, options: options))
    }

    // parity: native/src/context.zig#Context.editHighlight [status=implemented hash=f24a4c0e22c8]
    func editHighlight(
        editBuffer: NativeContextEngine.Handle,
        operation: UInt32,
        argument: UInt32 = 0,
        highlight: Highlight? = nil
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_highlight(abiHandle, editBuffer: editBuffer, operation: operation, argument: argument, highlight: highlight))
    }

    // parity: native/src/context.zig#Context.editSetLayer [status=implemented hash=aae0ad3e99fe]
    func editSetLayer(
        editBuffer: NativeContextEngine.Handle,
        layerId: UInt32,
        startByte: UInt32,
        endByte: UInt32,
        runs: [Highlight]
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_edit_buffer_set_layer(abiHandle, editBuffer: editBuffer, layerId: layerId, startByte: startByte, endByte: endByte, runs: runs))
    }

    // parity: native/src/context.zig#Context.editMark [status=implemented hash=da031360331c]
    func editMark(
        editBuffer: NativeContextEngine.Handle,
        operation: UInt32,
        mark: NativeEditMark? = nil,
        markId: UInt32? = nil
    ) throws(NativeContextEngine.ContextError) -> UInt32 {
        var outId: UInt32 = 0
        try checkStatus(NativeContextABI.ot_edit_buffer_mark(abiHandle, editBuffer: editBuffer, operation: operation, mark: mark, markId: markId, outId: &outId))
        return outId
    }

    // parity: native/src/context.zig#Context.editorSetViewport [status=implemented hash=66935296996f]
    func editorSetViewport(
        view: NativeContextEngine.Handle,
        viewport: NativeEditorViewport,
        sizeOnly: Bool = false,
        moveCursor: Bool = true
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_editor_view_set_viewport(abiHandle, view: view, viewport: viewport, sizeOnly: sizeOnly, moveCursor: moveCursor))
    }

    // parity: native/src/context.zig#Context.editorSetScrollMargin [status=implemented hash=cfdfe2a8d75d]
    func editorSetScrollMargin(view: NativeContextEngine.Handle, margin: Float) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_editor_view_set_scroll_margin(abiHandle, view: view, margin: margin))
    }

    // parity: native/src/context.zig#Context.editorCommand [status=implemented hash=ebae727057a6]
    func editorCommand(
        view: NativeContextEngine.Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_editor_view_command(abiHandle, view: view, command: command, argument: argument))
    }

    // parity: native/src/context.zig#Context.editorSetTabColor [status=implemented hash=230543de04d1]
    func editorSetTabColor(view: NativeContextEngine.Handle, color: RGBA) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_editor_view_set_tab_color(abiHandle, view: view, color: color))
    }

    // parity: native/src/context.zig#Context.editorSelect [status=implemented hash=a3ab0796633f]
    func editorSelect(
        view: NativeContextEngine.Handle,
        options: NativeEditorSelection
    ) throws(NativeContextEngine.ContextError) -> Bool {
        var changed = false
        try checkStatus(NativeContextABI.ot_editor_view_select(abiHandle, view: view, options: options, outChanged: &changed))
        return changed
    }

    // parity: native/src/context.zig#Context.editorPrepareView [status=implemented hash=8d277f9552c2]
    func editorPrepareView(
        view: NativeContextEngine.Handle,
        followCursor: Bool = false
    ) throws(NativeContextEngine.ContextError) -> NativeEditorViewInfo {
        var info = NativeEditorViewInfo()
        try checkStatus(NativeContextABI.ot_editor_view_get_info(abiHandle, view: view, followCursor: followCursor, outInfo: &info))
        return info
    }

    // parity: native/src/context.zig#Context.editorReplaceSelection [status=implemented hash=9c697b9b830d]
    func editorReplaceSelection(
        view: NativeContextEngine.Handle,
        text: String
    ) throws(NativeContextEngine.ContextError) -> NativeEditorReplacement {
        var replacement = NativeEditorReplacement()
        try checkStatus(NativeContextABI.ot_editor_view_replace_selection(abiHandle, view: view, text: text, outReplacement: &replacement))
        return replacement
    }

    // parity: native/src/context.zig#Context.editorSetPlaceholder [status=implemented hash=e31356a10844]
    func editorSetPlaceholder(view: NativeContextEngine.Handle, chunks: [TextChunk]) throws(NativeContextEngine.ContextError) {
        try checkStatus(NativeContextABI.ot_editor_view_set_placeholder(abiHandle, view: view, chunks: chunks))
    }

    // parity: native/src/context.zig#Context.followWidthMethod [status=implemented hash=d76fbd733d3c]
    static func followWidthMethod(scene: NativeZigScene.Scene, method: WidthMethod) {
        let textMethod: TextWidthMethod = method == .wcwidth ? .wcwidth : .unicode
        for renderable in scene.nodes.values {
            if case .textBufferView(let view) = renderable.measureTarget {
                view.buffer.core.setWidthMethod(textMethod)
                NativeZigYoga.yogaNodeInvalidateMeasure(renderable.yogaNode)
                NativeZigScene.Scene.markObservationStale(renderable)
            } else if case .editorView(let editor) = renderable.measureTarget {
                editor.editBuffer.textBuffer.core.setWidthMethod(textMethod)
                NativeZigYoga.yogaNodeInvalidateMeasure(renderable.yogaNode)
                NativeZigScene.Scene.markObservationStale(renderable)
            }
        }
        scene.clearPreparation()
    }
}
