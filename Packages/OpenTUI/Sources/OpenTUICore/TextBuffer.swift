/// A styled highlight range in a `TextBuffer` or `EditBuffer`.
// parity: core/src/types.ts#Highlight [status=implemented hash=08280aa0e40b]
public struct Highlight: Equatable, Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var styleId: UInt32
    public var priority: Int?
    public var hlRef: Int?

    public init(
        start: Int,
        end: Int,
        styleId: UInt32,
        priority: Int? = nil,
        hlRef: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.styleId = styleId
        self.priority = priority
        self.hlRef = hlRef
    }
}

/// Visual or logical line layout metrics exposed by `TextBufferView` and `EditorView`.
// parity: core/src/types.ts#LineInfo [status=implemented hash=df0a6f0e79a1]
public struct LineInfo: Equatable, Hashable, Sendable, Codable {
    /// Display-column offset for each visual line start.
    public var lineStartCols: [Int]
    /// Display-column width for each visual line.
    public var lineWidthCols: [Int]
    /// Maximum display-column width across the reported lines.
    public var lineWidthColsMax: Int
    /// Source logical line index for each visual line.
    public var lineSources: [Int]
    /// Wrap index within each source logical line.
    public var lineWraps: [Int]

    public init(
        lineStartCols: [Int] = [],
        lineWidthCols: [Int] = [],
        lineWidthColsMax: Int = 0,
        lineSources: [Int] = [],
        lineWraps: [Int] = []
    ) {
        self.lineStartCols = lineStartCols
        self.lineWidthCols = lineWidthCols
        self.lineWidthColsMax = lineWidthColsMax
        self.lineSources = lineSources
        self.lineWraps = lineWraps
    }
}

/// Protocol for views providing visual/logical line info and scroll offsets.
// parity: core/src/types.ts#LineInfoProvider [status=implemented hash=31c950668d37]
public protocol LineInfoProvider: AnyObject {
    var lineInfo: LineInfo { get }
    func getLineSources(startLine: Int, lineCount: Int) -> [Int]
    var lineCount: Int { get }
    var virtualLineCount: Int { get }
    var scrollY: Int { get }
}

/// Result of measuring wrapped text dimensions for a target width/height constraint.
// parity: core/src/zig.ts#MeasureResult [status=implemented hash=33fef844b529]
public struct MeasureResult: Equatable, Hashable, Sendable, Codable {
    public var lineCount: Int
    public var widthColsMax: Int

    public init(lineCount: Int, widthColsMax: Int) {
        self.lineCount = lineCount
        self.widthColsMax = widthColsMax
    }
}

/// Wrapping mode for `TextBufferView` and `EditorView`.
public enum TextWrapMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case none
    case char
    case word
}

/// Horizontal text alignment within the viewport width.
public enum TextAlign: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case left
    case center
    case right
}

/// Half-open selection range in document display-cell offsets (counting 1 cell per newline).
public struct TextSelectionRange: Equatable, Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// A laid-out visual line produced by `TextBufferView` after wrapping or unwrapping.
public struct TextVirtualLine: Equatable, Hashable, Sendable {
    /// Text content of this virtual line (without trailing `\n`).
    public var text: String
    /// Zero-based logical line index in the backing `TextBuffer`.
    public var sourceLine: Int
    /// Zero-based wrap index within `sourceLine`.
    public var wrapIndex: Int
    /// Document display-cell offset at the start of this virtual line (counting 1 per `\n`).
    public var documentCellOffset: Int
    /// Display-column offset from the start of `sourceLine`.
    public var sourceColStart: Int
    /// Display-cell width of this virtual line.
    public var widthCols: Int
    /// UTF-8 byte range of this virtual line within the backing `Rope`.
    public var utf8Range: Range<Int>

    public init(
        text: String,
        sourceLine: Int,
        wrapIndex: Int,
        documentCellOffset: Int,
        sourceColStart: Int,
        widthCols: Int,
        utf8Range: Range<Int>
    ) {
        self.text = text
        self.sourceLine = sourceLine
        self.wrapIndex = wrapIndex
        self.documentCellOffset = documentCellOffset
        self.sourceColStart = sourceColStart
        self.widthCols = widthCols
        self.utf8Range = utf8Range
    }
}

/// Computes left padding in display columns needed to align a rendered line within `viewportWidth`.
public func alignmentPadCols(alignment: TextAlign, viewportWidth: Int, lineWidthCols: Int) -> Int {
    guard lineWidthCols < viewportWidth else { return 0 }
    switch alignment {
    case .left:
        return 0
    case .center:
        return (viewportWidth - lineWidthCols) / 2
    case .right:
        return viewportWidth - lineWidthCols
    }
}

// MARK: - TextBuffer

/// Pure-Swift text storage with balanced `Rope` backing, styled `TextChunk` metadata,
/// per-line highlights, and display-cell offset coordinate mapping.
// parity: core/src/text-buffer.ts#TextBuffer [status=implemented hash=c50d503e2c9a]
public final class TextBuffer {
    internal var _rope: Rope
    private var _chunks: [TextChunk]
    private var _highlightsByLine: [Int: [Highlight]]
    private var _defaultFg: RGBA?
    private var _defaultBg: RGBA?
    private var _defaultAttributes: UInt32?
    private var _tabWidth: Int
    private var _widthMethod: TextWidthMethod
    private var _destroyed: Bool = false
    internal var _generation: UInt64 = 0

    /// Optional opaque syntax style identifier/tag for consumers without depending on `SyntaxStyle`.
    public var syntaxStyleToken: UInt32?

    public init(widthMethod: TextWidthMethod = .unicode, tabWidth: Int = 2) {
        self._rope = Rope()
        self._chunks = []
        self._highlightsByLine = [:]
        self._tabWidth = max(1, tabWidth)
        self._widthMethod = widthMethod
    }

    // parity: core/src/text-buffer.ts#TextBuffer.create [status=implemented hash=0d594a7c3827]
    public static func create(widthMethod: TextWidthMethod = .unicode) -> TextBuffer {
        TextBuffer(widthMethod: widthMethod)
    }

    public var isDestroyed: Bool {
        _destroyed
    }

    private func assertAlive() {
        precondition(!_destroyed, "TextBuffer is destroyed")
    }

    /// Current persistent `Rope` backing this buffer (O(1) snapshot).
    public var rope: Rope {
        assertAlive()
        return _rope
    }

    /// Current styled chunks stored in this buffer.
    public var styledChunks: [TextChunk] {
        assertAlive()
        return _chunks
    }

    public var defaultFg: RGBA? { _defaultFg }
    public var defaultBg: RGBA? { _defaultBg }
    public var defaultAttributes: UInt32? { _defaultAttributes }
    public var widthMethod: TextWidthMethod { _widthMethod }

    internal func replaceRope(_ newRope: Rope, preserveHighlights: Bool = true) {
        _rope = newRope
        let text = newRope.text
        _chunks = text.isEmpty ? [] : [TextChunk(text: text)]
        if !preserveHighlights {
            _highlightsByLine.removeAll()
        }
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setText [status=implemented hash=9c8e09374701]
    public func setText(_ text: String) {
        assertAlive()
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        _rope = Rope(normalized)
        _chunks = normalized.isEmpty ? [] : [TextChunk(text: normalized)]
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.append [status=implemented hash=b0a28e4681e2]
    public func append(_ text: String) {
        assertAlive()
        guard !text.isEmpty else { return }
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        _rope.insert(normalized, atUTF8: _rope.utf8Count)
        _chunks.append(TextChunk(text: normalized))
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setStyledText [status=implemented hash=57252972b038]
    public func setStyledText(_ text: StyledText) {
        assertAlive()
        if text.chunks.isEmpty {
            clear()
            return
        }
        var normalizedChunks: [TextChunk] = []
        normalizedChunks.reserveCapacity(text.chunks.count)
        var combined = ""
        for var chunk in text.chunks {
            let norm = _TextEngineMetrics.normalizeLineEndings(chunk.text)
            chunk.text = norm
            normalizedChunks.append(chunk)
            combined.append(norm)
        }
        _rope = Rope(combined)
        _chunks = normalizedChunks
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setDefaultFg [status=implemented hash=7aa4d6292eb4]
    public func setDefaultFg(_ fg: RGBA?) {
        assertAlive()
        _defaultFg = fg
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setDefaultBg [status=implemented hash=7480da1a6ee0]
    public func setDefaultBg(_ bg: RGBA?) {
        assertAlive()
        _defaultBg = bg
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setDefaultAttributes [status=implemented hash=74d76150dbee]
    public func setDefaultAttributes(_ attributes: UInt32?) {
        assertAlive()
        _defaultAttributes = attributes
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.resetDefaults [status=implemented hash=0c56e124127d]
    public func resetDefaults() {
        assertAlive()
        _defaultFg = nil
        _defaultBg = nil
        _defaultAttributes = nil
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.getLineCount [status=implemented hash=1e49a804768f]
    public func getLineCount() -> Int {
        assertAlive()
        return _rope.lineCount
    }

    /// Total display-cell width of all characters excluding newlines.
    // parity: core/src/text-buffer.ts#TextBuffer.length [status=implemented hash=e2d3a055ea2c]
    public var length: Int {
        assertAlive()
        return _TextEngineMetrics.totalContentWidth(_rope.text, tabWidth: _tabWidth, widthMethod: _widthMethod)
    }

    /// Total UTF-8 byte count including LF line breaks.
    // parity: core/src/text-buffer.ts#TextBuffer.byteSize [status=implemented hash=47fa02503a8b]
    public var byteSize: Int {
        assertAlive()
        return _rope.utf8Count
    }

    /// Total document display-cell length counting 1 cell per newline.
    public var documentCellLength: Int {
        assertAlive()
        return _TextEngineMetrics.documentDisplayWidth(_rope.text, tabWidth: _tabWidth, widthMethod: _widthMethod)
    }

    // parity: core/src/text-buffer.ts#TextBuffer.getPlainText [status=implemented hash=7694db93b404]
    public func getPlainText() -> String {
        assertAlive()
        return _rope.text
    }

    /// Returns the text of 0-based logical line `lineIdx` without its trailing newline.
    public func getLine(_ lineIdx: Int) -> String {
        assertAlive()
        return _rope.line(at: lineIdx) ?? ""
    }

    /// Reads `[startOffset, endOffset)` in document display cells (counting 1 cell per newline),
    /// snapping cleanly to grapheme boundaries.
    // parity: core/src/text-buffer.ts#TextBuffer.getTextRange [status=implemented hash=0b78ff5206e0]
    public func getTextRange(startOffset: Int, endOffset: Int) -> String {
        assertAlive()
        guard startOffset < endOffset else { return "" }
        let clampedStart = max(0, startOffset)
        let clampedEnd = max(clampedStart, endOffset)
        let startByte = utf8Offset(forDocumentCellOffset: clampedStart, roundDown: false)
        let endByte = utf8Offset(forDocumentCellOffset: clampedEnd, roundDown: false)
        guard startByte < endByte else { return "" }
        return _rope.slice(utf8Range: startByte..<endByte)
    }

    /// Reads a half-open range between `(startRow, startCol)` and `(endRow, endCol)` in logical line & display-cell coordinates.
    public func getTextRangeByCoords(startRow: Int, startCol: Int, endRow: Int, endCol: Int) -> String {
        assertAlive()
        let startOffset = positionToOffset(row: startRow, col: startCol)
        let endOffset = positionToOffset(row: endRow, col: endCol)
        return getTextRange(startOffset: startOffset, endOffset: endOffset)
    }

    // MARK: - Coordinate Conversions

    /// Maps a 0-based logical `(row, col)` (display-cell column) to a document display-cell offset (1 per `\n`).
    public func positionToOffset(row: Int, col: Int) -> Int {
        assertAlive()
        let linesCount = _rope.lineCount
        let clampedRow = max(0, min(row, linesCount - 1))
        var offset = 0
        for r in 0..<clampedRow {
            let line = _rope.line(at: r) ?? ""
            offset += _TextEngineMetrics.lineDisplayWidth(line, tabWidth: _tabWidth, widthMethod: _widthMethod) + 1
        }
        let targetLine = _rope.line(at: clampedRow) ?? ""
        let lineWidth = _TextEngineMetrics.lineDisplayWidth(targetLine, tabWidth: _tabWidth, widthMethod: _widthMethod)
        let clampedCol = max(0, min(col, lineWidth))
        offset += _TextEngineMetrics.snapColDown(clampedCol, in: targetLine, tabWidth: _tabWidth, widthMethod: _widthMethod)
        return offset
    }

    /// Maps a document display-cell offset (1 per `\n`) to a 0-based logical `(row, col)`.
    public func offsetToPosition(_ offset: Int) -> (row: Int, col: Int)? {
        assertAlive()
        guard offset >= 0 else { return nil }
        var remaining = offset
        let linesCount = _rope.lineCount
        for r in 0..<linesCount {
            let line = _rope.line(at: r) ?? ""
            let lineWidth = _TextEngineMetrics.lineDisplayWidth(line, tabWidth: _tabWidth, widthMethod: _widthMethod)
            if remaining <= lineWidth {
                let snapped = _TextEngineMetrics.snapColDown(remaining, in: line, tabWidth: _tabWidth, widthMethod: _widthMethod)
                return (r, snapped)
            }
            if r + 1 < linesCount {
                remaining -= (lineWidth + 1)
            } else {
                return (r, lineWidth)
            }
        }
        return (0, 0)
    }

    /// Returns the document display-cell offset at column 0 of 0-based logical line `row`.
    public func getLineStartOffset(_ row: Int) -> Int {
        positionToOffset(row: row, col: 0)
    }

    /// Converts a document display-cell offset (1 per `\n`) to a UTF-8 byte offset in `_rope`.
    /// When `roundDown` is `true`, an offset inside a wide grapheme rounds to that grapheme's start byte;
    /// when `false`, it includes any grapheme starting strictly before `offset`.
    internal func utf8Offset(forDocumentCellOffset targetOffset: Int, roundDown: Bool = true) -> Int {
        if targetOffset <= 0 { return 0 }
        var cell = 0
        var byteOffset = 0
        let text = _rope.text
        for ch in text {
            let w: Int
            if ch == "\n" {
                w = 1
            } else {
                w = _TextEngineMetrics.graphemeWidth(ch, tabWidth: _tabWidth, widthMethod: _widthMethod)
            }
            if cell == targetOffset {
                return byteOffset
            }
            if cell + w > targetOffset {
                return roundDown ? byteOffset : (byteOffset + ch.utf8.count)
            }
            cell += w
            byteOffset += ch.utf8.count
        }
        return byteOffset
    }

    /// Converts a UTF-8 byte offset in `_rope` to a document display-cell offset (1 per `\n`).
    internal func documentCellOffset(forUTF8Offset targetByte: Int, roundDown: Bool = true) -> Int {
        if targetByte <= 0 { return 0 }
        var cell = 0
        var byteOffset = 0
        let text = _rope.text
        for ch in text {
            let b = ch.utf8.count
            let w = (ch == "\n") ? 1 : _TextEngineMetrics.graphemeWidth(ch, tabWidth: _tabWidth, widthMethod: _widthMethod)
            if byteOffset == targetByte {
                return cell
            }
            if byteOffset + b > targetByte {
                return roundDown ? cell : (cell + w)
            }
            byteOffset += b
            cell += w
        }
        return cell
    }

    /// Converts a UTF-16 code unit index in `getPlainText()` to a document display-cell offset (1 per `\n`).
    /// Rounds down within a grapheme; clamps at EOF.
    internal func stringIndexToCellOffset(_ index: Int) -> Int {
        if index <= 0 { return 0 }
        var cell = 0
        var utf16Seen = 0
        let text = _rope.text
        for ch in text {
            let u16 = ch.utf16.count
            if utf16Seen + u16 > index {
                return cell
            }
            let w = (ch == "\n") ? 1 : _TextEngineMetrics.graphemeWidth(ch, tabWidth: _tabWidth, widthMethod: _widthMethod)
            utf16Seen += u16
            cell += w
            if utf16Seen == index {
                return cell
            }
        }
        return cell
    }

    /// Converts a document display-cell offset (1 per `\n`) to a UTF-16 code unit index in `getPlainText()`.
    /// Rounds down within a grapheme, past zero-width text at a tie, and clamps at EOF.
    internal func cellOffsetToStringIndex(_ offset: Int) -> Int {
        if offset <= 0 { return 0 }
        var cell = 0
        var utf16Seen = 0
        let text = _rope.text
        for ch in text {
            let w = (ch == "\n") ? 1 : _TextEngineMetrics.graphemeWidth(ch, tabWidth: _tabWidth, widthMethod: _widthMethod)
            let u16 = ch.utf16.count
            if cell + w > offset {
                return utf16Seen
            }
            cell += w
            utf16Seen += u16
        }
        return utf16Seen
    }

    // MARK: - Highlights

    /// Adds a highlight spanning absolute display-cell positions excluding newlines across logical lines.
    // parity: core/src/text-buffer.ts#TextBuffer.addHighlightByCharRange [status=implemented hash=98e4d276f24c]
    public func addHighlightByCharRange(_ highlight: Highlight) {
        assertAlive()
        guard highlight.start < highlight.end else { return }
        let lineCount = _rope.lineCount
        var running = 0
        for row in 0..<lineCount {
            let line = _rope.line(at: row) ?? ""
            let lineWidth = _TextEngineMetrics.lineDisplayWidth(line, tabWidth: _tabWidth, widthMethod: _widthMethod)
            let lineStart = running
            let lineEnd = running + lineWidth
            let overlapStart = max(highlight.start, lineStart)
            let overlapEnd = min(highlight.end, lineEnd)
            if overlapStart < overlapEnd {
                let localHighlight = Highlight(
                    start: overlapStart - lineStart,
                    end: overlapEnd - lineStart,
                    styleId: highlight.styleId,
                    priority: highlight.priority,
                    hlRef: highlight.hlRef
                )
                addHighlight(lineIdx: row, highlight: localHighlight)
            }
            running = lineEnd
            if running >= highlight.end { break }
        }
    }

    /// Adds a highlight to a specific 0-based logical line using display-column coordinates.
    // parity: core/src/text-buffer.ts#TextBuffer.addHighlight [status=implemented hash=a0da54ba434d]
    public func addHighlight(lineIdx: Int, highlight: Highlight) {
        assertAlive()
        guard lineIdx >= 0 && highlight.start < highlight.end else { return }
        _highlightsByLine[lineIdx, default: []].append(highlight)
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.removeHighlightsByRef [status=implemented hash=1c3b0adc0247]
    public func removeHighlightsByRef(_ hlRef: Int) {
        assertAlive()
        var emptyLines: [Int] = []
        for (lineIdx, var list) in _highlightsByLine {
            list.removeAll { $0.hlRef == hlRef }
            if list.isEmpty {
                emptyLines.append(lineIdx)
            } else {
                _highlightsByLine[lineIdx] = list
            }
        }
        for lineIdx in emptyLines {
            _highlightsByLine.removeValue(forKey: lineIdx)
        }
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.clearLineHighlights [status=implemented hash=2398396746ea]
    public func clearLineHighlights(_ lineIdx: Int) {
        assertAlive()
        _highlightsByLine.removeValue(forKey: lineIdx)
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.clearAllHighlights [status=implemented hash=7130e621c8b7]
    public func clearAllHighlights() {
        assertAlive()
        _highlightsByLine.removeAll()
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.getLineHighlights [status=implemented hash=f896207920e3]
    public func getLineHighlights(_ lineIdx: Int) -> [Highlight] {
        assertAlive()
        return _highlightsByLine[lineIdx] ?? []
    }

    // parity: core/src/text-buffer.ts#TextBuffer.getHighlightCount [status=implemented hash=b26a9ee5b2c7]
    public func getHighlightCount() -> Int {
        assertAlive()
        return _highlightsByLine.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Width & Tab Settings

    // parity: core/src/text-buffer.ts#TextBuffer.setTabWidth [status=implemented hash=1f5631c1660c]
    public func setTabWidth(_ width: Int) {
        assertAlive()
        let effective = max(1, width)
        if _tabWidth != effective {
            _tabWidth = effective
            _generation &+= 1
        }
    }

    // parity: core/src/text-buffer.ts#TextBuffer.getTabWidth [status=implemented hash=b720632479e3]
    public func getTabWidth() -> Int {
        assertAlive()
        return _tabWidth
    }

    // parity: core/src/text-buffer.ts#TextBuffer.setWidthMethod [status=implemented hash=9af952bdb557]
    public func setWidthMethod(_ widthMethod: TextWidthMethod) {
        assertAlive()
        if _widthMethod != widthMethod {
            _widthMethod = widthMethod
            _generation &+= 1
        }
    }

    /// Clears text while preserving highlights and defaults.
    // parity: core/src/text-buffer.ts#TextBuffer.clear [status=implemented hash=5e664ad56774]
    public func clear() {
        assertAlive()
        _rope = Rope()
        _chunks = []
        _generation &+= 1
    }

    /// Resets text, highlights, and defaults completely.
    // parity: core/src/text-buffer.ts#TextBuffer.reset [status=implemented hash=6dfccb55b649]
    public func reset() {
        assertAlive()
        _rope = Rope()
        _chunks = []
        _highlightsByLine.removeAll()
        _defaultFg = nil
        _defaultBg = nil
        _defaultAttributes = nil
        _generation &+= 1
    }

    // parity: core/src/text-buffer.ts#TextBuffer.destroy [status=implemented hash=a94b780e2071]
    public func destroy() {
        guard !_destroyed else { return }
        _rope = Rope()
        _chunks = []
        _highlightsByLine.removeAll()
        _destroyed = true
    }
}

// MARK: - TextBufferView

/// Pure-Swift layout, wrapping, viewport windowing, and local/global selection engine for `TextBuffer`.
// parity: core/src/text-buffer-view.ts#TextBufferView [status=implemented hash=bbf6e0f36648]
public final class TextBufferView: LineInfoProvider {
    public let textBuffer: TextBuffer

    private var _destroyed: Bool = false
    private var _wrapWidth: Int? = nil
    private var _wrapMode: TextWrapMode = .none
    private var _textAlign: TextAlign = .left
    private var _firstLineOffset: Int = 0
    private var _viewport: ViewportBounds? = nil
    private var _truncate: Bool = false
    private var _tabIndicator: Unicode.Scalar? = nil
    private var _tabIndicatorColor: RGBA? = nil

    private var _selection: TextSelectionRange? = nil
    private var _selectionAnchor: Int? = nil
    private var _selectionFocus: Int? = nil
    private var _selectionBg: RGBA? = nil
    private var _selectionFg: RGBA? = nil
    private var _selectionOccupancy: SelectionOccupancy = .cell
    private var _selectionBehavior: SelectionBehavior = .cell

    private var _cachedVirtualLines: [TextVirtualLine] = []
    private var _cachedGeneration: UInt64 = .max
    private var _layoutDirty: Bool = true

    public init(textBuffer: TextBuffer) {
        self.textBuffer = textBuffer
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.create [status=implemented hash=e29d44e3ab1f]
    public static func create(_ textBuffer: TextBuffer) -> TextBufferView {
        TextBufferView(textBuffer: textBuffer)
    }

    public var isDestroyed: Bool {
        _destroyed
    }

    private func assertAlive() {
        precondition(!_destroyed, "TextBufferView is destroyed")
        precondition(!textBuffer.isDestroyed, "Backing TextBuffer is destroyed")
    }

    private func markDirty() {
        _layoutDirty = true
    }

    public var wrapMode: TextWrapMode { _wrapMode }
    public var wrapWidth: Int? { _wrapWidth }
    public var textAlign: TextAlign { _textAlign }
    public var firstLineOffset: Int { _firstLineOffset }
    public var truncate: Bool { _truncate }
    public var tabIndicator: Unicode.Scalar? { _tabIndicator }
    public var tabIndicatorColor: RGBA? { _tabIndicatorColor }
    public var selectionBgColor: RGBA? { _selectionBg }
    public var selectionFgColor: RGBA? { _selectionFg }

    public var viewport: ViewportBounds? {
        assertAlive()
        return _viewport
    }

    // MARK: - LineInfoProvider

    public var lineCount: Int {
        assertAlive()
        return textBuffer.getLineCount()
    }

    public var virtualLineCount: Int {
        getVirtualLineCount()
    }

    public var scrollY: Int {
        assertAlive()
        return _viewport?.y ?? 0
    }

    // MARK: - Wrapping & Layout Engine

    private func effectiveWrapWidth(overrideWidth: Int? = nil) -> Int? {
        guard _wrapMode != .none else { return nil }
        if let overrideWidth {
            return overrideWidth > 0 ? overrideWidth : nil
        }
        if let w = _wrapWidth, w > 0 {
            return w
        }
        if let vp = _viewport, vp.width > 0 {
            return vp.width
        }
        return nil
    }

    private func ensureVirtualLines() {
        if !_layoutDirty && _cachedGeneration == textBuffer._generation {
            return
        }
        _cachedVirtualLines = computeVirtualLines(
            wrapWidthOverride: nil,
            wrapMode: _wrapMode,
            firstLineOffset: _firstLineOffset
        )
        _cachedGeneration = textBuffer._generation
        _layoutDirty = false
    }

    /// Returns all computed virtual lines (wrapped according to `wrapMode` and `wrapWidth`).
    public func virtualLines() -> [TextVirtualLine] {
        assertAlive()
        ensureVirtualLines()
        return _cachedVirtualLines
    }

    /// Returns the slice of virtual lines currently visible in the configured viewport.
    public func visibleVirtualLines() -> [TextVirtualLine] {
        assertAlive()
        ensureVirtualLines()
        guard let vp = _viewport else {
            return _cachedVirtualLines
        }
        guard vp.height > 0 && vp.width > 0 else { return [] }
        let startIdx = max(0, min(vp.y, _cachedVirtualLines.count))
        let endIdx = max(startIdx, min(startIdx + vp.height, _cachedVirtualLines.count))
        var result = Array(_cachedVirtualLines[startIdx..<endIdx])
        if _truncate && _wrapMode == .none {
            for i in result.indices {
                if result[i].widthCols > vp.width {
                    result[i] = truncateVirtualLine(result[i], maxCols: vp.width)
                }
            }
        }
        return result
    }

    private func truncateVirtualLine(_ vline: TextVirtualLine, maxCols: Int) -> TextVirtualLine {
        guard maxCols > 0 else {
            var empty = vline
            empty.text = ""
            empty.widthCols = 0
            return empty
        }
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        let target = max(0, maxCols - 1)
        var out = ""
        var width = 0
        for ch in vline.text {
            let w = _TextEngineMetrics.graphemeWidth(ch, tabWidth: tabWidth, widthMethod: method)
            if width + w > target {
                break
            }
            out.append(ch)
            width += w
        }
        out.append("…")
        width += 1
        var copy = vline
        copy.text = out
        copy.widthCols = width
        return copy
    }

    internal func computeVirtualLines(
        wrapWidthOverride: Int?,
        wrapMode: TextWrapMode,
        firstLineOffset: Int
    ) -> [TextVirtualLine] {
        let rope = textBuffer._rope
        let lineCount = rope.lineCount
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        let activeWrapWidth: Int? = (wrapMode == .none) ? nil : effectiveWrapWidth(overrideWidth: wrapWidthOverride)

        var output: [TextVirtualLine] = []
        output.reserveCapacity(lineCount)
        var docCellOffset = 0

        for row in 0..<lineCount {
            let lineUTF8Range = rope.lineRange(at: row) ?? 0..<0
            let lineText = rope.slice(utf8Range: lineUTF8Range)
            let lineWidth = _TextEngineMetrics.lineDisplayWidth(lineText, tabWidth: tabWidth, widthMethod: method)

            guard let maxCols = activeWrapWidth, maxCols > 0 else {
                output.append(TextVirtualLine(
                    text: lineText,
                    sourceLine: row,
                    wrapIndex: 0,
                    documentCellOffset: docCellOffset,
                    sourceColStart: 0,
                    widthCols: lineWidth,
                    utf8Range: lineUTF8Range
                ))
                docCellOffset += lineWidth + 1
                continue
            }

            let clusters = _TextEngineMetrics.lineClusters(lineText, tabWidth: tabWidth, widthMethod: method)
            if clusters.isEmpty {
                output.append(TextVirtualLine(
                    text: "",
                    sourceLine: row,
                    wrapIndex: 0,
                    documentCellOffset: docCellOffset,
                    sourceColStart: 0,
                    widthCols: 0,
                    utf8Range: lineUTF8Range
                ))
                docCellOffset += 1
                continue
            }

            let wrapped = wrapLineClusters(
                clusters: clusters,
                lineText: lineText,
                lineUTF8Base: lineUTF8Range.lowerBound,
                sourceLine: row,
                docCellBase: docCellOffset,
                wrapWidth: maxCols,
                firstLineIndent: (row == 0) ? max(0, firstLineOffset) : 0,
                wrapMode: wrapMode
            )
            output.append(contentsOf: wrapped)
            docCellOffset += lineWidth + 1
        }

        return output
    }

    private func wrapLineClusters(
        clusters: [_TextEngineMetrics.LineCluster],
        lineText: String,
        lineUTF8Base: Int,
        sourceLine: Int,
        docCellBase: Int,
        wrapWidth: Int,
        firstLineIndent: Int,
        wrapMode: TextWrapMode
    ) -> [TextVirtualLine] {
        var result: [TextVirtualLine] = []
        var idx = 0
        var wrapIdx = 0
        let total = clusters.count

        while idx < total {
            let limit = (wrapIdx == 0 && firstLineIndent > 0)
                ? max(1, wrapWidth - firstLineIndent)
                : wrapWidth

            let startIdx = idx
            var currentWidth = 0
            var lastBreakEndIdx: Int? = nil

            while idx < total {
                let c = clusters[idx]
                if currentWidth + c.width > limit && idx > startIdx {
                    break
                }
                currentWidth += c.width
                idx += 1
                if wrapMode == .word && _TextEngineMetrics.isWordWrapBreak(c.character) {
                    lastBreakEndIdx = idx
                }
                // If a single wide grapheme exceeded limit on its own, emit it alone.
                if currentWidth >= limit && idx == startIdx + 1 {
                    break
                }
            }

            var endIdx = idx
            if wrapMode == .word && endIdx < total, let breakEnd = lastBreakEndIdx, breakEnd > startIdx {
                // Only rewind to break opportunity if we didn't stop right after a break already.
                if !_TextEngineMetrics.isWordWrapBreak(clusters[endIdx - 1].character) {
                    endIdx = breakEnd
                }
            }

            // Recompute exact slice metrics for [startIdx..<endIdx]
            let firstCluster = clusters[startIdx]
            let lastCluster = clusters[endIdx - 1]
            let segWidth = lastCluster.colEnd - firstCluster.colStart
            let segUTF8Start = lineUTF8Base + firstCluster.utf8Start
            let segUTF8End = lineUTF8Base + lastCluster.utf8End

            let utf8View = lineText.utf8
            let sIdx = utf8View.index(utf8View.startIndex, offsetBy: firstCluster.utf8Start)
            let eIdx = utf8View.index(utf8View.startIndex, offsetBy: lastCluster.utf8End)
            let segText = String(lineText[sIdx..<eIdx])

            result.append(TextVirtualLine(
                text: segText,
                sourceLine: sourceLine,
                wrapIndex: wrapIdx,
                documentCellOffset: docCellBase + firstCluster.colStart,
                sourceColStart: firstCluster.colStart,
                widthCols: segWidth,
                utf8Range: segUTF8Start..<segUTF8End
            ))

            idx = endIdx
            wrapIdx += 1
        }

        return result
    }

    // MARK: - Selection Operations

    // parity: core/src/text-buffer-view.ts#TextBufferView.setSelection [status=implemented hash=1bbdb1f890f1]
    public func setSelection(start: Int, end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        let docLen = textBuffer.documentCellLength
        let s = max(0, min(start, docLen))
        let e = max(0, min(end, docLen))
        _selectionBg = bgColor ?? _selectionBg
        _selectionFg = fgColor ?? _selectionFg
        if s == e {
            _selection = nil
            _selectionAnchor = nil
            _selectionFocus = nil
            return
        }
        _selectionAnchor = s
        _selectionFocus = e
        _selection = TextSelectionRange(start: min(s, e), end: max(s, e))
    }

    /// Selects the single grapheme starting at `offset` (inclusive cell selection).
    internal func selectCharacter(at offset: Int) {
        setSelectionInclusive(start: offset, end: offset)
    }

    /// Selects offsets `[start, end]` inclusively when occupancy is `.cell`, or `[min, max)` when `.boundary`.
    public func setSelectionInclusive(start: Int, end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        let docLen = textBuffer.documentCellLength
        let a = max(0, min(start, docLen))
        let f = max(0, min(end, docLen))
        _selectionBg = bgColor ?? _selectionBg
        _selectionFg = fgColor ?? _selectionFg
        _selectionAnchor = a
        _selectionFocus = f
        let lo = min(a, f)
        var hi = max(a, f)
        if _selectionOccupancy == .cell && hi < docLen {
            hi = nextGraphemeDocumentCellEnd(at: hi)
        }
        if lo == hi {
            _selection = nil
        } else {
            _selection = TextSelectionRange(start: lo, end: hi)
        }
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.updateSelection [status=implemented hash=bd5b8bf5b15b]
    public func updateSelection(end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        guard let anchor = _selectionAnchor else { return }
        setSelection(start: anchor, end: end, bgColor: bgColor, fgColor: fgColor)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.resetSelection [status=implemented hash=38138f8e3522]
    public func resetSelection() {
        assertAlive()
        _selection = nil
        _selectionAnchor = nil
        _selectionFocus = nil
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getSelection [status=implemented hash=f0518e9fd89f]
    public func getSelection() -> TextSelectionRange? {
        assertAlive()
        return _selection
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.hasSelection [status=implemented hash=997ec38633e4]
    public func hasSelection() -> Bool {
        assertAlive()
        return _selection != nil
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setLocalSelection [status=implemented hash=97215236454d]
    @discardableResult
    public func setLocalSelection(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        bgColor: RGBA? = nil,
        fgColor: RGBA? = nil,
        behavior: SelectionBehavior = .cell
    ) -> Bool {
        assertAlive()
        _selectionBehavior = behavior
        _selectionBg = bgColor ?? _selectionBg
        _selectionFg = fgColor ?? _selectionFg
        return applyLocalSelection(anchorX: anchorX, anchorY: anchorY, focusX: focusX, focusY: focusY, behavior: behavior)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.updateLocalSelection [status=implemented hash=e01fde848e20]
    @discardableResult
    public func updateLocalSelection(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        bgColor: RGBA? = nil,
        fgColor: RGBA? = nil,
        behavior: SelectionBehavior = .cell
    ) -> Bool {
        assertAlive()
        _selectionBehavior = behavior
        _selectionBg = bgColor ?? _selectionBg
        _selectionFg = fgColor ?? _selectionFg
        return applyLocalSelection(anchorX: anchorX, anchorY: anchorY, focusX: focusX, focusY: focusY, behavior: behavior)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.resetLocalSelection [status=implemented hash=4011e68dcedd]
    public func resetLocalSelection() {
        resetSelection()
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setSelectionColors [status=implemented hash=be9059e9e325]
    public func setSelectionColors(bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        _selectionBg = bgColor
        _selectionFg = fgColor
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setSelectionOccupancy [status=implemented hash=588bf48b5289]
    public func setSelectionOccupancy(_ occupancy: SelectionOccupancy) {
        assertAlive()
        _selectionOccupancy = occupancy
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getSelectionOccupancy [status=implemented hash=ed667d771157]
    public func getSelectionOccupancy() -> SelectionOccupancy {
        assertAlive()
        return _selectionOccupancy
    }

    @discardableResult
    internal func convertSelectionToCell() -> Bool {
        assertAlive()
        guard let anchor = _selectionAnchor, let focus = _selectionFocus else { return false }
        _selectionBehavior = .cell
        setSelectionInclusive(start: anchor, end: focus)
        return _selection != nil
    }

    private func applyLocalSelection(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        behavior: SelectionBehavior
    ) -> Bool {
        ensureVirtualLines()
        guard !_cachedVirtualLines.isEmpty else {
            _selection = nil
            return false
        }
        let vpX = _viewport?.x ?? 0
        let vpY = _viewport?.y ?? 0
        let vpWidth = _viewport?.width ?? 0

        let aRow = anchorY + vpY
        let fRow = focusY + vpY

        // Both endpoints completely above or completely below all virtual lines -> no selection
        if (aRow < 0 && fRow < 0) || (aRow >= _cachedVirtualLines.count && fRow >= _cachedVirtualLines.count) {
            _selection = nil
            return false
        }

        let aOffset = localCoordsToDocumentOffset(localX: anchorX + vpX, vlineIndex: aRow, viewportWidth: vpWidth)
        let fOffset = localCoordsToDocumentOffset(localX: focusX + vpX, vlineIndex: fRow, viewportWidth: vpWidth)

        _selectionAnchor = aOffset
        _selectionFocus = fOffset

        let start: Int
        let end: Int
        switch behavior {
        case .cell:
            let lo = min(aOffset, fOffset)
            var hi = max(aOffset, fOffset)
            let docLen = textBuffer.documentCellLength
            if _selectionOccupancy == .cell && hi < docLen {
                hi = nextGraphemeDocumentCellEnd(at: hi)
            }
            start = lo
            end = hi

        case .word:
            let aRange = wordRange(around: aOffset)
            let fRange = wordRange(around: fOffset)
            start = min(aRange.start, fRange.start)
            end = max(aRange.end, fRange.end)

        case .line:
            let aRange = lineRangeInDocCells(around: aOffset)
            let fRange = lineRangeInDocCells(around: fOffset)
            start = min(aRange.start, fRange.start)
            end = max(aRange.end, fRange.end)
        }

        guard start < end else {
            _selection = nil
            return false
        }
        _selection = TextSelectionRange(start: start, end: end)
        return true
    }

    internal func localCoordsToDocumentOffset(localX: Int, vlineIndex: Int, viewportWidth: Int) -> Int {
        ensureVirtualLines()
        guard !_cachedVirtualLines.isEmpty else { return 0 }
        if vlineIndex < 0 {
            return 0
        }
        if vlineIndex >= _cachedVirtualLines.count {
            return textBuffer.documentCellLength
        }
        let vline = _cachedVirtualLines[vlineIndex]
        let pad = viewportWidth > 0
            ? alignmentPadCols(alignment: _textAlign, viewportWidth: viewportWidth, lineWidthCols: vline.widthCols)
            : 0
        let adjustedX = max(0, localX - pad)
        let clampedCol = min(adjustedX, vline.widthCols)
        let snapped = _TextEngineMetrics.snapColDown(
            clampedCol,
            in: vline.text,
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
        return vline.documentCellOffset + snapped
    }

    private func nextGraphemeDocumentCellEnd(at offset: Int) -> Int {
        let text = textBuffer.getPlainText()
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        var cell = 0
        for ch in text {
            let w = (ch == "\n") ? 1 : _TextEngineMetrics.graphemeWidth(ch, tabWidth: tabWidth, widthMethod: method)
            if cell <= offset && offset < cell + w {
                return cell + w
            }
            cell += w
        }
        return cell
    }

    private func wordRange(around offset: Int) -> TextSelectionRange {
        guard let pos = textBuffer.offsetToPosition(offset) else {
            return TextSelectionRange(start: offset, end: offset)
        }
        let line = textBuffer.getLine(pos.row)
        let lineStart = textBuffer.getLineStartOffset(pos.row)
        let clusters = _TextEngineMetrics.lineClusters(line, tabWidth: textBuffer.getTabWidth(), widthMethod: textBuffer.widthMethod)
        guard !clusters.isEmpty else {
            return TextSelectionRange(start: lineStart, end: lineStart)
        }
        var targetIdx = clusters.count - 1
        for (idx, c) in clusters.enumerated() {
            if pos.col < c.colEnd {
                targetIdx = idx
                break
            }
        }
        let targetIsBoundary = _TextEngineMetrics.isSelectionWordBoundary(clusters[targetIdx].character)
        let targetIsSpace = clusters[targetIdx].character == " " || clusters[targetIdx].character == "\t"

        var left = targetIdx
        while left > 0 {
            let prev = clusters[left - 1].character
            if targetIsSpace {
                if prev != " " && prev != "\t" { break }
            } else if targetIsBoundary {
                break
            } else {
                if _TextEngineMetrics.isSelectionWordBoundary(prev) { break }
            }
            left -= 1
        }
        var right = targetIdx + 1
        while right < clusters.count {
            let next = clusters[right].character
            if targetIsSpace {
                if next != " " && next != "\t" { break }
            } else if targetIsBoundary {
                break
            } else {
                if _TextEngineMetrics.isSelectionWordBoundary(next) { break }
            }
            right += 1
        }
        return TextSelectionRange(
            start: lineStart + clusters[left].colStart,
            end: lineStart + clusters[right - 1].colEnd
        )
    }

    private func lineRangeInDocCells(around offset: Int) -> TextSelectionRange {
        guard let pos = textBuffer.offsetToPosition(offset) else {
            return TextSelectionRange(start: 0, end: 0)
        }
        let lineStart = textBuffer.getLineStartOffset(pos.row)
        let line = textBuffer.getLine(pos.row)
        let lineWidth = _TextEngineMetrics.lineDisplayWidth(
            line,
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
        return TextSelectionRange(start: lineStart, end: lineStart + lineWidth)
    }

    // MARK: - Configuration Commands

    // parity: core/src/text-buffer-view.ts#TextBufferView.setWrapWidth [status=implemented hash=4c9f9b06a601]
    public func setWrapWidth(_ width: Int?) {
        assertAlive()
        let normalized = (width ?? 0) > 0 ? width : nil
        if _wrapWidth != normalized {
            _wrapWidth = normalized
            markDirty()
        }
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setWrapMode [status=implemented hash=91a9ea738c53]
    public func setWrapMode(_ mode: TextWrapMode) {
        assertAlive()
        if _wrapMode != mode {
            _wrapMode = mode
            markDirty()
        }
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setTextAlign [status=implemented hash=ef933a7c6ece]
    public func setTextAlign(_ alignment: TextAlign) {
        assertAlive()
        _textAlign = alignment
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setFirstLineOffset [status=implemented hash=9193a6b52ab8]
    public func setFirstLineOffset(_ offset: Int) {
        assertAlive()
        let clamped = max(0, offset)
        if _firstLineOffset != clamped {
            _firstLineOffset = clamped
            markDirty()
        }
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setViewportSize [status=implemented hash=0f72fe9f1755]
    public func setViewportSize(width: Int, height: Int) {
        assertAlive()
        let currentX = _viewport?.x ?? 0
        let currentY = _viewport?.y ?? 0
        let newViewport = ViewportBounds(x: currentX, y: currentY, width: max(0, width), height: max(0, height))
        let widthChanged = _viewport?.width != newViewport.width
        _viewport = newViewport
        if widthChanged && _wrapMode != .none && _wrapWidth == nil {
            markDirty()
        }
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setViewport [status=implemented hash=81dc36bd10b1]
    public func setViewport(x: Int, y: Int, width: Int, height: Int) {
        assertAlive()
        let newViewport = ViewportBounds(x: max(0, x), y: max(0, y), width: max(0, width), height: max(0, height))
        let widthChanged = _viewport?.width != newViewport.width
        _viewport = newViewport
        if widthChanged && _wrapMode != .none && _wrapWidth == nil {
            markDirty()
        }
    }

    // MARK: - Line Info & Measurement

    // parity: core/src/text-buffer-view.ts#TextBufferView.lineInfo [status=implemented hash=f43da3654140]
    public var lineInfo: LineInfo {
        assertAlive()
        let visible = visibleVirtualLines()
        return buildLineInfo(from: visible)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.logicalLineInfo [status=implemented hash=255acf2932ec]
    public var logicalLineInfo: LineInfo {
        assertAlive()
        ensureVirtualLines()
        return buildLineInfo(from: _cachedVirtualLines)
    }

    private func buildLineInfo(from lines: [TextVirtualLine]) -> LineInfo {
        var starts: [Int] = []
        var widths: [Int] = []
        var sources: [Int] = []
        var wraps: [Int] = []
        starts.reserveCapacity(lines.count)
        widths.reserveCapacity(lines.count)
        sources.reserveCapacity(lines.count)
        wraps.reserveCapacity(lines.count)
        var maxWidth = 0
        for line in lines {
            starts.append(line.documentCellOffset)
            widths.append(line.widthCols)
            sources.append(line.sourceLine)
            wraps.append(line.wrapIndex)
            if line.widthCols > maxWidth {
                maxWidth = line.widthCols
            }
        }
        return LineInfo(
            lineStartCols: starts,
            lineWidthCols: widths,
            lineWidthColsMax: maxWidth,
            lineSources: sources,
            lineWraps: wraps
        )
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getLineSources [status=implemented hash=9f83e7432b5f]
    public func getLineSources(startLine: Int, lineCount: Int) -> [Int] {
        assertAlive()
        ensureVirtualLines()
        guard lineCount > 0 else { return [] }
        let start = max(0, min(startLine, _cachedVirtualLines.count))
        let end = max(start, min(start + lineCount, _cachedVirtualLines.count))
        return _cachedVirtualLines[start..<end].map(\.sourceLine)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getSelectedText [status=implemented hash=db3e11c8f6e4]
    public func getSelectedText() -> String {
        assertAlive()
        guard let sel = _selection, sel.start < sel.end else { return "" }
        return textBuffer.getTextRange(startOffset: sel.start, endOffset: sel.end)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getPlainText [status=implemented hash=d7dfd3d3167a]
    public func getPlainText() -> String {
        assertAlive()
        return textBuffer.getPlainText()
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setTabIndicator [status=implemented hash=af5b108a41d8]
    public func setTabIndicator(_ indicator: String) {
        assertAlive()
        _tabIndicator = indicator.unicodeScalars.first
    }

    public func setTabIndicator(codePoint: UInt32) {
        assertAlive()
        _tabIndicator = codePoint == 0 ? nil : Unicode.Scalar(codePoint)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setTabIndicatorColor [status=implemented hash=4b8944d3e420]
    public func setTabIndicatorColor(_ color: RGBA) {
        assertAlive()
        _tabIndicatorColor = color
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.setTruncate [status=implemented hash=35a69176a146]
    public func setTruncate(_ truncate: Bool) {
        assertAlive()
        _truncate = truncate
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.measureForDimensions [status=implemented hash=12938affd600]
    public func measureForDimensions(width: Int, height: Int) -> MeasureResult? {
        assertAlive()
        let lines = computeVirtualLines(
            wrapWidthOverride: width > 0 ? width : nil,
            wrapMode: _wrapMode,
            firstLineOffset: _firstLineOffset
        )
        var maxCols = 0
        for line in lines {
            if line.widthCols > maxCols {
                maxCols = line.widthCols
            }
        }
        return MeasureResult(lineCount: lines.count, widthColsMax: maxCols)
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.getVirtualLineCount [status=implemented hash=6251542d4055]
    public func getVirtualLineCount() -> Int {
        assertAlive()
        ensureVirtualLines()
        return _cachedVirtualLines.count
    }

    // parity: core/src/text-buffer-view.ts#TextBufferView.destroy [status=implemented hash=35d0b974f3bb]
    public func destroy() {
        guard !_destroyed else { return }
        _cachedVirtualLines.removeAll()
        _selection = nil
        _destroyed = true
    }
}
