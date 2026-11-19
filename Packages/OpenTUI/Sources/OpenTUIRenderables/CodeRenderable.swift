import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - Highlight & Chunk Callback Types

/// Context passed to `OnHighlightCallback` when transforming syntax highlight ranges.
// parity: core/src/renderables/Code.ts#HighlightContext [status=implemented hash=a7c2c2dbb536]
public struct HighlightContext: Sendable {
    public var content: String
    public var filetype: String
    public var syntaxStyle: SyntaxStyle

    public init(content: String, filetype: String, syntaxStyle: SyntaxStyle) {
        self.content = content
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
    }
}

/// Optional transformation callback invoked after syntax highlighting produces `SimpleHighlight` ranges.
/// Returning `nil` keeps the original highlights unchanged.
// parity: core/src/renderables/Code.ts#OnHighlightCallback [status=implemented hash=a1ea57138eae]
public typealias OnHighlightCallback = (
    _ highlights: [SimpleHighlight],
    _ context: HighlightContext
) -> [SimpleHighlight]?

/// Context passed to `OnChunksCallback` when post-processing styled text chunks.
// parity: core/src/renderables/Code.ts#ChunkRenderContext [status=implemented hash=c4cbfb2203ca]
public struct ChunkRenderContext: Sendable {
    public var content: String
    public var filetype: String
    public var syntaxStyle: SyntaxStyle
    public var highlights: [SimpleHighlight]
    public var sourceRanges: [Range<Int>]?

    public init(
        content: String,
        filetype: String,
        syntaxStyle: SyntaxStyle,
        highlights: [SimpleHighlight],
        sourceRanges: [Range<Int>]? = nil
    ) {
        self.content = content
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.highlights = highlights
        self.sourceRanges = sourceRanges
    }
}

/// Optional transformation callback invoked after highlight ranges are converted into `TextChunk`s.
/// Returning `nil` keeps the generated chunks unchanged.
// parity: core/src/renderables/Code.ts#OnChunksCallback [status=implemented hash=a091329a981f]
public typealias OnChunksCallback = (
    _ chunks: [TextChunk],
    _ context: ChunkRenderContext
) -> [TextChunk]?

// MARK: - CodeOptions

/// Configuration options for initializing a `CodeRenderable`.
// parity: core/src/renderables/Code.ts#CodeOptions [status=implemented hash=cf4cb8acb49a]
public struct CodeOptions {
    public var bufferOptions: TextBufferOptions
    public var content: String?
    public var filetype: String?
    public var syntaxStyle: SyntaxStyle
    public var highlighter: (any SyntaxHighlighter)?
    public var conceal: Bool?
    public var drawUnstyledText: Bool?
    public var streaming: Bool?
    public var initialStyledText: StyledText?
    public var baseHighlight: String?
    public var onHighlight: OnHighlightCallback?
    public var onChunks: OnChunksCallback?
    /// When `true` (default), highlights run synchronously during layout/update passes.
    /// Set to `false` when driving asynchronous highlighting explicitly via `highlightAsync()`.
    public var autoHighlight: Bool?

    public init(
        id: String? = nil,
        content: String? = nil,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        highlighter: (any SyntaxHighlighter)? = nil,
        conceal: Bool? = nil,
        drawUnstyledText: Bool? = nil,
        streaming: Bool? = nil,
        initialStyledText: StyledText? = nil,
        baseHighlight: String? = nil,
        onHighlight: OnHighlightCallback? = nil,
        onChunks: OnChunksCallback? = nil,
        autoHighlight: Bool? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        flexBasis: FlexValue? = nil,
        alignSelf: Align? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        overflow: Overflow? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        buffered: Bool? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        selectable: Bool? = nil,
        attributes: UInt32? = nil,
        wrapMode: TextWrapMode? = nil,
        textAlign: TextAlign? = nil,
        tabIndicator: String? = nil,
        tabIndicatorColor: Color? = nil,
        truncate: Bool? = nil
    ) {
        self.bufferOptions = TextBufferOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            flexBasis: flexBasis,
            alignSelf: alignSelf,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            overflow: overflow,
            zIndex: zIndex,
            visible: visible,
            opacity: opacity,
            buffered: buffered,
            fg: fg,
            bg: bg,
            selectionBg: selectionBg,
            selectionFg: selectionFg,
            selectable: selectable,
            attributes: attributes,
            wrapMode: wrapMode,
            textAlign: textAlign,
            tabIndicator: tabIndicator,
            tabIndicatorColor: tabIndicatorColor,
            truncate: truncate
        )
        self.content = content
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.highlighter = highlighter
        self.conceal = conceal
        self.drawUnstyledText = drawUnstyledText
        self.streaming = streaming
        self.initialStyledText = initialStyledText
        self.baseHighlight = baseHighlight
        self.onHighlight = onHighlight
        self.onChunks = onChunks
        self.autoHighlight = autoHighlight
    }

    public init(
        bufferOptions: TextBufferOptions,
        content: String? = nil,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle = SyntaxStyle.create(),
        highlighter: (any SyntaxHighlighter)? = nil,
        conceal: Bool? = nil,
        drawUnstyledText: Bool? = nil,
        streaming: Bool? = nil,
        initialStyledText: StyledText? = nil,
        baseHighlight: String? = nil,
        onHighlight: OnHighlightCallback? = nil,
        onChunks: OnChunksCallback? = nil,
        autoHighlight: Bool? = nil
    ) {
        self.bufferOptions = bufferOptions
        self.content = content
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.highlighter = highlighter
        self.conceal = conceal
        self.drawUnstyledText = drawUnstyledText
        self.streaming = streaming
        self.initialStyledText = initialStyledText
        self.baseHighlight = baseHighlight
        self.onHighlight = onHighlight
        self.onChunks = onChunks
        self.autoHighlight = autoHighlight
    }
}

// MARK: - CodeRenderable

/// Syntax-highlighted code block renderable extending `TextBufferRenderable`.
/// Integrates `SyntaxStyle`, pluggable `SyntaxHighlighter` (defaulting to `BuiltInSyntaxHighlighter`),
/// `treeSitterToTextChunks`, conceal line-source remapping, streaming preview retention,
/// and both synchronous and asynchronous highlighting paths.
// parity: core/src/renderables/Code.ts#CodeRenderable [status=implemented hash=b99372d616ce]
open class CodeRenderable: TextBufferRenderable, @unchecked Sendable {
    private static let previewVersion: Int = -2

    private var _content: String
    private var _filetype: String?
    private var _syntaxStyle: SyntaxStyle
    private var _highlighter: any SyntaxHighlighter
    private var _conceal: Bool
    private var _drawUnstyledText: Bool
    private var _streaming: Bool
    private var _initialStyledText: StyledText?
    private var _baseHighlight: String?
    private var _onHighlight: OnHighlightCallback?
    private var _onChunks: OnChunksCallback?
    private var _autoHighlight: Bool

    private var _highlightsDirty: Bool = false
    private var _isHighlighting: Bool = false
    private var _highlightRerun: Bool = false
    private var _version: Int = 0
    private var _shownVersion: Int = -1
    private var _shouldRenderTextBuffer: Bool = true
    private var _streamsDeltas: Bool = false

    private var _renderedLineSources: [Int]? = nil
    private var _mappedLineInfo: LineInfo? = nil
    private var _highlightingTask: Task<Void, Never> = Task {}

    public init(ctx: any RenderContext, options: CodeOptions = CodeOptions()) {
        self._content = options.content ?? ""
        self._filetype = options.filetype
        self._syntaxStyle = options.syntaxStyle
        self._highlighter = options.highlighter ?? BuiltInSyntaxHighlighter.shared
        self._conceal = options.conceal ?? true
        self._drawUnstyledText = options.drawUnstyledText ?? true
        self._streaming = options.streaming ?? false
        self._initialStyledText = options.initialStyledText
        self._baseHighlight = options.baseHighlight
        self._onHighlight = options.onHighlight
        self._onChunks = options.onChunks
        self._autoHighlight = options.autoHighlight ?? true

        super.init(ctx: ctx, options: options.bufferOptions)

        if !self._content.isEmpty {
            if let initial = self._initialStyledText, self._drawUnstyledText {
                self.textBuffer.setStyledText(initial)
                self._shownVersion = Self.previewVersion
            } else {
                self.textBuffer.setText(self._content)
                self._shownVersion = -1
            }
            self._shouldRenderTextBuffer = self._drawUnstyledText || self._filetype == nil
            self._highlightsDirty = true
            self.updateTextInfo()
        } else {
            self._shouldRenderTextBuffer = false
            self._highlightsDirty = false
        }
    }

    // MARK: - Public Properties

    // parity: core/src/renderables/Code.ts#CodeRenderable.content [status=implemented hash=ebe008abea36]
    public var content: String {
        get { _content }
        set {
            guard _content != newValue else { return }
            writeContent(newValue)
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.filetype [status=implemented hash=cfbaa5c81d52]
    public var filetype: String? {
        get { _filetype }
        set {
            guard _filetype != newValue else { return }
            _filetype = newValue
            invalidateHighlights()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.syntaxStyle [status=implemented hash=8bbbc920cf40]
    public var syntaxStyle: SyntaxStyle {
        get { _syntaxStyle }
        set {
            guard _syntaxStyle !== newValue else { return }
            _syntaxStyle = newValue
            changeStyle()
        }
    }

    /// Pluggable syntax highlighter (defaults to `BuiltInSyntaxHighlighter.shared`),
    /// corresponding to `CodeRenderable.treeSitterClient` in upstream TypeScript.
    // parity: core/src/renderables/Code.ts#CodeRenderable.treeSitterClient [status=adapted hash=1488120890ad]
    public var highlighter: any SyntaxHighlighter {
        get { _highlighter }
        set {
            _highlighter = newValue
            invalidateHighlights()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.conceal [status=implemented hash=2bc204954212]
    public var conceal: Bool {
        get { _conceal }
        set {
            guard _conceal != newValue else { return }
            _conceal = newValue
            changeStyle()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.drawUnstyledText [status=implemented hash=82031b0a971f]
    public var drawUnstyledText: Bool {
        get { _drawUnstyledText }
        set {
            guard _drawUnstyledText != newValue else { return }
            _drawUnstyledText = newValue
            invalidateHighlights(bumpVersion: false)
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.streaming [status=implemented hash=a6ce28dc913c]
    public var streaming: Bool {
        get { _streaming }
        set {
            guard _streaming != newValue else { return }
            _streaming = newValue
            if !newValue {
                _streamsDeltas = false
            }
            invalidateHighlights(bumpVersion: false)
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.initialStyledText [status=implemented hash=f50bff178e46]
    public var initialStyledText: StyledText? {
        get { _initialStyledText }
        set {
            guard _initialStyledText != newValue else { return }
            _initialStyledText = newValue
            let shows = newValue != nil && _drawUnstyledText
            let replaces = shows && _streaming && _isHighlighting
            let previewed = _shownVersion == Self.previewVersion
            guard !_content.isEmpty, (_shownVersion < 0 || replaces), !(newValue == nil && previewed) else {
                return
            }
            if let styled = newValue, shows {
                textBuffer.setStyledText(styled)
                _shownVersion = Self.previewVersion
            } else {
                textBuffer.setText(_content)
                if !shows && previewed && !_drawUnstyledText && _filetype != nil {
                    _shouldRenderTextBuffer = false
                }
                _shownVersion = -1
            }
            setRenderedLineSources(nil)
            updateTextInfo()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.onHighlight [status=implemented hash=868a329482e2]
    public var onHighlight: OnHighlightCallback? {
        get { _onHighlight }
        set {
            _onHighlight = newValue
            changeStyle()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.baseHighlight [status=implemented hash=9383ecac3c10]
    public var baseHighlight: String? {
        get { _baseHighlight }
        set {
            guard _baseHighlight != newValue else { return }
            _baseHighlight = newValue
            changeStyle()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.onChunks [status=implemented hash=600570448bbe]
    public var onChunks: OnChunksCallback? {
        get { _onChunks }
        set {
            _onChunks = newValue
            changeStyle()
        }
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.isHighlighting [status=implemented hash=40dc7f2f0f7e]
    public var isHighlighting: Bool {
        _isHighlighting || _highlightRerun
    }

    /// Task tracking the latest asynchronous highlighting pass (completed immediately when idle).
    // parity: core/src/renderables/Code.ts#CodeRenderable.highlightingDone [status=adapted hash=cfc5e53caf3d]
    public var highlightingDone: Task<Void, Never> {
        _highlightingTask
    }

    public var autoHighlight: Bool {
        get { _autoHighlight }
        set { _autoHighlight = newValue }
    }

    /// Internal hook used by `MarkdownRenderable` to signal whether a streamed fence is still open.
    internal func setStreamsDeltas(_ open: Bool) {
        _streamsDeltas = open
    }

    // MARK: - Streaming Preview & Highlights API

    // parity: core/src/renderables/Code.ts#CodeRenderable.updateStreamingPreview [status=implemented hash=f51130477f32]
    public func updateStreamingPreview(content: String, initialStyledText: StyledText) {
        _content = content
        _initialStyledText = initialStyledText
        _shownVersion = Self.previewVersion
        invalidateHighlights()
        textBuffer.setStyledText(initialStyledText)
        setRenderedLineSources(nil)
        updateTextInfo()
    }

    // parity: core/src/renderables/Code.ts#CodeRenderable.getLineHighlights [status=implemented hash=b897d18d8d45]
    public func getLineHighlights(_ lineIdx: Int) -> [Highlight] {
        guard !isDestroyed && !textBuffer.isDestroyed else { return [] }
        return textBuffer.getLineHighlights(lineIdx)
    }

    /// Synchronously executes syntax highlighting if dirty (or when `force == true`).
    public func highlightNow(force: Bool = false) {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }
        guard force || _highlightsDirty else { return }
        runSynchronousHighlight()
    }

    /// Runs an asynchronous highlight pass using `highlighter.highlightOnce(content:filetype:)`.
    /// Drops stale replies if `content`, `filetype`, or style options change while suspended.
    public func highlightAsync() async {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }

        let contentSnapshot = _content
        let filetypeSnapshot = _filetype
        let versionSnapshot = _version

        if contentSnapshot.isEmpty {
            applyPlainOrEmpty(hasContent: false)
            return
        }

        if filetypeSnapshot == nil && _onChunks == nil && _baseHighlight == nil {
            applyPlainOrEmpty(hasContent: true)
            return
        }

        ensureVisibleTextBeforeHighlight()
        _highlightsDirty = false
        _isHighlighting = true

        let task = Task<Void, Never> { @Sendable in }
        _highlightingTask = task

        let result: SyntaxHighlightResult
        if let ft = filetypeSnapshot {
            result = await _highlighter.highlightOnce(content: contentSnapshot, filetype: ft)
        } else {
            result = SyntaxHighlightResult()
        }

        guard !isDestroyed && !textBuffer.isDestroyed else {
            _isHighlighting = false
            return
        }
        guard versionSnapshot == _version else {
            _isHighlighting = false
            _highlightsDirty = true
            requestRender()
            return
        }

        finishHighlight(
            content: contentSnapshot,
            filetype: filetypeSnapshot ?? "",
            version: versionSnapshot,
            rawHighlights: result.highlights
        )
    }

    // MARK: - LineInfo & Conceal Remapping

    open override var lineInfo: LineInfo {
        guard let renderedLineSources = _renderedLineSources else {
            return super.lineInfo
        }
        if let cached = _mappedLineInfo {
            return cached
        }
        let base = super.lineInfo
        let mappedSources = base.lineSources.map { line in
            (line >= 0 && line < renderedLineSources.count) ? renderedLineSources[line] : line
        }
        let mapped = LineInfo(
            lineStartCols: base.lineStartCols,
            lineWidthCols: base.lineWidthCols,
            lineWidthColsMax: base.lineWidthColsMax,
            lineSources: mappedSources,
            lineWraps: base.lineWraps
        )
        _mappedLineInfo = mapped
        return mapped
    }

    open override func getLineSources(startLine: Int, lineCount: Int) -> [Int] {
        let sources = super.getLineSources(startLine: startLine, lineCount: lineCount)
        guard let renderedLineSources = _renderedLineSources else {
            return sources
        }
        return sources.map { line in
            (line >= 0 && line < renderedLineSources.count) ? renderedLineSources[line] : line
        }
    }

    open override var wrapMode: TextWrapMode {
        get { super.wrapMode }
        set {
            if super.wrapMode != newValue {
                _mappedLineInfo = nil
                super.wrapMode = newValue
            }
        }
    }

    open override func onResize(width: Int, height: Int) {
        _mappedLineInfo = nil
        super.onResize(width: width, height: height)
    }

    open override func updateTextInfo() {
        _mappedLineInfo = nil
        super.updateTextInfo()
    }

    // MARK: - Lifecycle & Rendering

    open override func prepareBeforeMeasure() {
        if _autoHighlight && _highlightsDirty {
            scheduleHighlights()
        }
    }

    open override func onUpdate(deltaTime: Double) {
        super.onUpdate(deltaTime: deltaTime)
        if _autoHighlight && _highlightsDirty {
            scheduleHighlights()
        }
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard _shouldRenderTextBuffer else { return }
        super.renderSelf(buffer: buffer, deltaTime: deltaTime)
    }

    open override func destroySelf() {
        _isHighlighting = false
        _highlightRerun = false
        _streamsDeltas = false
        _highlightingTask.cancel()
        super.destroySelf()
    }

    // MARK: - Internal Highlighting State Machine

    private func writeContent(_ value: String) {
        let isDeltaAppend = _streaming
            && _streamsDeltas
            && !_content.isEmpty
            && value.hasPrefix(_content)
            && !_conceal
            && _onHighlight == nil
            && _onChunks == nil
            && _baseHighlight == nil
            && _initialStyledText == nil

        let previousContent = _content
        _content = value

        if isDeltaAppend {
            let delta = String(value.dropFirst(previousContent.count))
            if !delta.isEmpty {
                textBuffer.append(delta)
            }
            _version &+= 1
            _highlightsDirty = true
            updateTextInfo()
            return
        }

        // Streaming with drawUnstyledText == false retains the last painted highlight until the new one lands.
        if _streaming && _shouldRenderTextBuffer && _shownVersion >= 0 && !_drawUnstyledText {
            invalidateHighlights()
            requestRender()
            return
        }

        if !value.isEmpty, let initial = _initialStyledText, _drawUnstyledText {
            textBuffer.setStyledText(initial)
            _shownVersion = Self.previewVersion
        } else {
            textBuffer.setText(value)
            _shownVersion = -1
        }
        invalidateHighlights()
        setRenderedLineSources(nil)
        updateTextInfo()
    }

    private func invalidateHighlights(bumpVersion: Bool = true) {
        _highlightsDirty = true
        if bumpVersion {
            _version &+= 1
        }
        guard !isDestroyed else { return }
        if !_drawUnstyledText && _filetype != nil {
            paintHighlightsOnly()
        }
        if _shownVersion >= 0 && _shownVersion != _version && !_streaming {
            showPlainText()
        }
        requestRender()
    }

    private func showPlainText() {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }
        _shouldRenderTextBuffer = _drawUnstyledText || _filetype == nil
        textBuffer.setText(_content)
        textBuffer.clearAllHighlights()
        _shownVersion = -1
        setRenderedLineSources(nil)
        updateTextInfo()
    }

    private func changeStyle() {
        if _shownVersion < 0 || _shownVersion != _version || isDestroyed {
            invalidateHighlights()
            return
        }
        _version &+= 1
        _shownVersion = _version
        _highlightsDirty = true
        requestRender()
    }

    private func paintHighlightsOnly() {
        if !_streaming || !_shouldRenderTextBuffer || _shownVersion == -1 {
            _shouldRenderTextBuffer = (_shownVersion == _version)
        }
    }

    private func ensureVisibleTextBeforeHighlight() {
        let keeps = _streaming && _shouldRenderTextBuffer
        if _drawUnstyledText {
            if !keeps && _shownVersion != _version {
                if let initial = _initialStyledText {
                    textBuffer.setStyledText(initial)
                    _shownVersion = Self.previewVersion
                } else {
                    textBuffer.setText(_content)
                    _shownVersion = -1
                }
                setRenderedLineSources(nil)
            } else if keeps && _shownVersion == -1 && _initialStyledText != nil {
                _shownVersion = Self.previewVersion
            }
            _shouldRenderTextBuffer = true
        } else {
            paintHighlightsOnly()
        }
    }

    private func scheduleHighlights() {
        guard _highlightsDirty && !isDestroyed && !textBuffer.isDestroyed else { return }
        runSynchronousHighlight()
    }

    private func applyPlainOrEmpty(hasContent: Bool) {
        _shouldRenderTextBuffer = hasContent
        _highlightsDirty = false
        _isHighlighting = false
        _highlightRerun = false
        textBuffer.setText(_content)
        textBuffer.clearAllHighlights()
        _shownVersion = -1
        setRenderedLineSources(nil)
        updateTextInfo()
    }

    private func runSynchronousHighlight() {
        let hasContent = !_content.isEmpty
        if !hasContent {
            applyPlainOrEmpty(hasContent: false)
            return
        }

        if _filetype == nil && _onChunks == nil && _baseHighlight == nil {
            applyPlainOrEmpty(hasContent: true)
            return
        }

        ensureVisibleTextBeforeHighlight()
        _highlightsDirty = false

        let contentSnapshot = _content
        let filetypeSnapshot = _filetype
        let versionSnapshot = _version

        _isHighlighting = true
        let rawHighlights: [SimpleHighlight]
        if let ft = filetypeSnapshot {
            rawHighlights = _highlighter.highlight(content: contentSnapshot, filetype: ft).highlights
        } else {
            rawHighlights = []
        }

        finishHighlight(
            content: contentSnapshot,
            filetype: filetypeSnapshot ?? "",
            version: versionSnapshot,
            rawHighlights: rawHighlights
        )
    }

    private func finishHighlight(
        content: String,
        filetype: String,
        version: Int,
        rawHighlights: [SimpleHighlight]
    ) {
        var highlights = rawHighlights
        if let callback = _onHighlight {
            let context = HighlightContext(content: content, filetype: filetype, syntaxStyle: _syntaxStyle)
            if let modified = callback(highlights, context) {
                highlights = modified
            }
        }

        if !highlights.isEmpty || _onChunks != nil || _baseHighlight != nil {
            let chunkResult = treeSitterToTextChunksWithMetadata(
                content: content,
                highlights: highlights,
                syntaxStyle: _syntaxStyle,
                conceal: ConcealOptions(enabled: _conceal),
                baseHighlight: _baseHighlight
            )
            var chunks = chunkResult.chunks
            let renderedLineSources: [Int]? = _onChunks != nil
                ? nil
                : getConcealLinesSourceMap(content: content, highlights: highlights)

            if let onChunksCallback = _onChunks {
                let chunkContext = ChunkRenderContext(
                    content: content,
                    filetype: filetype,
                    syntaxStyle: _syntaxStyle,
                    highlights: highlights,
                    sourceRanges: chunkResult.ranges
                )
                if let modified = onChunksCallback(chunks, chunkContext) {
                    chunks = modified
                }
            }

            settle(
                version: version,
                styledText: StyledText(chunks: chunks),
                highlights: highlights,
                content: content,
                lineSources: renderedLineSources
            )
        } else {
            settle(
                version: version,
                styledText: nil,
                highlights: [],
                content: content,
                lineSources: nil
            )
        }
    }

    private func settle(
        version: Int,
        styledText: StyledText?,
        highlights: [SimpleHighlight],
        content: String,
        lineSources: [Int]?
    ) {
        guard !isDestroyed && !textBuffer.isDestroyed else { return }

        if let styledText {
            textBuffer.setStyledText(styledText)
        } else {
            textBuffer.setText(_content)
        }
        syncTextBufferLineHighlights(content: content, highlights: highlights)
        setRenderedLineSources(lineSources)
        _shownVersion = version
        _shouldRenderTextBuffer = !_content.isEmpty
        _isHighlighting = false
        _highlightsDirty = false
        updateTextInfo()
    }

    private func syncTextBufferLineHighlights(content: String, highlights: [SimpleHighlight]) {
        textBuffer.clearAllHighlights()
        guard !highlights.isEmpty && !content.isEmpty && !_syntaxStyle.isDestroyed else { return }

        let units = Array(content.utf16)
        var lineStarts: [Int] = [0]
        for i in units.indices where units[i] == 0x0A {
            lineStarts.append(i + 1)
        }

        func lineAndCol(for utf16Offset: Int) -> (line: Int, col: Int) {
            let clamped = max(0, min(utf16Offset, units.count))
            var lo = 0
            var hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= clamped {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return (lo, clamped - lineStarts[lo])
        }

        for h in highlights {
            guard h.start < h.end else { continue }
            let styleId = _syntaxStyle.getStyleId(h.group) ?? 0
            let startPos = lineAndCol(for: h.start)
            let endPos = lineAndCol(for: h.end)

            if startPos.line == endPos.line {
                if startPos.col < endPos.col {
                    textBuffer.addHighlight(
                        lineIdx: startPos.line,
                        highlight: Highlight(start: startPos.col, end: endPos.col, styleId: styleId)
                    )
                }
            } else {
                for lineIdx in startPos.line...endPos.line {
                    let lineStartOffset = lineStarts[lineIdx]
                    let lineEndOffset: Int
                    if lineIdx + 1 < lineStarts.count {
                        lineEndOffset = max(lineStartOffset, lineStarts[lineIdx + 1] - 1)
                    } else {
                        lineEndOffset = units.count
                    }
                    let segStart = (lineIdx == startPos.line) ? startPos.col : 0
                    let segEnd = (lineIdx == endPos.line) ? endPos.col : (lineEndOffset - lineStartOffset)
                    if segStart < segEnd {
                        textBuffer.addHighlight(
                            lineIdx: lineIdx,
                            highlight: Highlight(start: segStart, end: segEnd, styleId: styleId)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Conceal Line Source Mapping

    private func setRenderedLineSources(_ lineSources: [Int]?) {
        _renderedLineSources = lineSources
        _mappedLineInfo = nil
    }

    private static func isIdentityLineSources(_ lineSources: [Int]) -> Bool {
        for i in lineSources.indices where lineSources[i] != i {
            return false
        }
        return true
    }

    private static func getMergedConcealLineRanges(_ highlights: [SimpleHighlight]) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        for highlight in highlights {
            guard let meta = highlight.meta, meta.concealLines != nil else { continue }
            let group = highlight.group
            let isEmptyConceal = meta.conceal == ""
                || (meta.conceal == nil && (group == "conceal" || group.hasPrefix("conceal.")))
            if isEmptyConceal {
                ranges.append((start: highlight.start, end: highlight.end))
            }
        }

        if ranges.count <= 1 { return ranges }

        ranges.sort { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = [ranges[0]]
        for i in 1..<ranges.count {
            let next = ranges[i]
            if next.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, next.end)
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    private func getConcealLinesSourceMap(content: String, highlights: [SimpleHighlight]) -> [Int]? {
        guard _conceal && !content.isEmpty else { return nil }

        let concealLineRanges = Self.getMergedConcealLineRanges(highlights)
        guard !concealLineRanges.isEmpty else { return nil }

        let units = Array(content.utf16)
        let utf16Len = units.count

        var lineSources: [Int] = []
        var sourceLine = 0
        var lineStart = 0
        var rangeIndex = 0
        var currentRenderedLineHasText = false

        func setCurrentRenderedLineSource(_ line: Int, hasText: Bool) {
            if lineSources.isEmpty {
                lineSources.append(line)
            } else if !currentRenderedLineHasText {
                lineSources[lineSources.count - 1] = line
            }
            if hasText {
                currentRenderedLineHasText = true
            }
        }

        while lineStart <= utf16Len {
            var newlineOffset = -1
            var scan = lineStart
            while scan < utf16Len {
                if units[scan] == 0x0A {
                    newlineOffset = scan
                    break
                }
                scan += 1
            }
            let lineEnd = newlineOffset == -1 ? utf16Len : newlineOffset

            while rangeIndex < concealLineRanges.count && concealLineRanges[rangeIndex].end <= lineStart {
                rangeIndex += 1
            }

            let range = rangeIndex < concealLineRanges.count ? concealLineRanges[rangeIndex] : nil
            let fullyConcealed = range != nil
                && lineEnd > lineStart
                && range!.start <= lineStart
                && range!.end >= lineEnd
            let lineBreakConcealed = newlineOffset != -1
                && range != nil
                && range!.start <= newlineOffset
                && range!.end >= newlineOffset

            if !fullyConcealed || !lineBreakConcealed {
                let hasText = lineEnd > lineStart && !fullyConcealed
                if hasText || newlineOffset != -1 || !fullyConcealed {
                    setCurrentRenderedLineSource(sourceLine, hasText: hasText)
                }
                if newlineOffset != -1 && !lineBreakConcealed {
                    lineSources.append(sourceLine + 1)
                    currentRenderedLineHasText = false
                }
            }

            sourceLine += 1
            if newlineOffset == -1 { break }
            lineStart = newlineOffset + 1
        }

        if lineSources.isEmpty || Self.isIdentityLineSources(lineSources) {
            return nil
        }
        return lineSources
    }
}
