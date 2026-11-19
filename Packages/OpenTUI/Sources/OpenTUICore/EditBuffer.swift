/// Logical cursor coordinates within an `EditBuffer`.
// parity: core/src/zig.ts#LogicalCursor [status=implemented hash=d6b6933f45c9]
public struct LogicalCursor: Equatable, Hashable, Sendable, Codable {
    /// Zero-based logical line in the document.
    public var row: Int
    /// Display-cell column relative to the logical line start.
    public var col: Int
    /// Display-cell offset from the document start, counting each newline as one.
    public var offset: Int

    public init(row: Int = 0, col: Int = 0, offset: Int = 0) {
        self.row = row
        self.col = col
        self.offset = offset
    }
}

/// Visual cursor coordinates with both viewport-relative and document-absolute positions.
// parity: core/src/zig.ts#VisualCursor [status=implemented hash=d49a8ceb43d1]
public struct VisualCursor: Equatable, Hashable, Sendable, Codable {
    /// Wrapped row relative to the top of the viewport.
    public var visualRow: Int
    /// Display-cell column relative to the viewport.
    public var visualCol: Int
    /// Zero-based logical line in the document.
    public var logicalRow: Int
    /// Display-cell column relative to the logical line start.
    public var logicalCol: Int
    /// Display-cell offset from the document start, counting each newline as one.
    public var offset: Int

    public init(
        visualRow: Int = 0,
        visualCol: Int = 0,
        logicalRow: Int = 0,
        logicalCol: Int = 0,
        offset: Int = 0
    ) {
        self.visualRow = visualRow
        self.visualCol = visualCol
        self.logicalRow = logicalRow
        self.logicalCol = logicalCol
        self.offset = offset
    }
}

/// Viewport geometry returned by `EditorView.getViewport()`.
// parity: core/src/editor-view.ts#Viewport [status=implemented hash=5fd57f957e24]
public struct EditorViewport: Equatable, Hashable, Sendable, Codable {
    public var offsetY: Int
    public var offsetX: Int
    public var height: Int
    public var width: Int

    public init(offsetY: Int = 0, offsetX: Int = 0, height: Int = 0, width: Int = 0) {
        self.offsetY = offsetY
        self.offsetX = offsetX
        self.height = height
        self.width = width
    }
}

/// Native edit mark record in document display-cell offsets.
// parity: core/src/zig.ts#NativeEditMark [status=implemented hash=a84296d42611]
public struct NativeEditMark: Equatable, Hashable, Sendable, Codable {
    public var id: UInt32
    public var kind: UInt32
    public var atomic: Bool
    public var style: UInt32
    public var priority: UInt32
    public var start: Int
    public var end: Int

    public init(
        id: UInt32,
        kind: UInt32 = 0,
        atomic: Bool = false,
        style: UInt32 = 0,
        priority: UInt32 = 0,
        start: Int,
        end: Int
    ) {
        self.id = id
        self.kind = kind
        self.atomic = atomic
        self.style = style
        self.priority = priority
        self.start = start
        self.end = end
    }
}

/// Internal mark stored in UTF-8 byte coordinates (matching `edit-marks.zig`) so edits splice
/// and undo/redo restore marks cleanly with the rope snapshot.
internal struct StoredEditMark: Equatable, Sendable {
    var id: UInt32
    var kind: UInt32
    var atomic: Bool
    var style: UInt32
    var priority: UInt32
    var startByte: Int
    var endByte: Int

    /// Adjusts mark for deletion of `[start, end)` UTF-8 bytes. Returns `false` if the mark is dropped.
    mutating func applyDelete(start: Int, end: Int) -> Bool {
        if start == end || endByte <= start {
            return true
        }
        let count = end - start
        if startByte >= end {
            startByte -= count
            endByte -= count
            return true
        }
        if atomic || (startByte >= start && endByte <= end) {
            return false
        }
        endByte = endByte > end ? (endByte - count) : start
        startByte = min(startByte, start)
        return true
    }

    /// Adjusts mark for insertion of `count` UTF-8 bytes at `at`. Returns `false` if the mark is dropped.
    mutating func applyInsert(at: Int, count: Int) -> Bool {
        if count == 0 || endByte <= at {
            return true
        }
        if startByte >= at {
            startByte += count
            endByte += count
            return true
        }
        if atomic {
            return false
        }
        endByte += count
        return true
    }

    static func sortOrder(_ lhs: StoredEditMark, _ rhs: StoredEditMark) -> Bool {
        if lhs.startByte != rhs.startByte {
            return lhs.startByte < rhs.startByte
        }
        return lhs.id < rhs.id
    }
}

private struct EditHistorySnapshot: Sendable {
    let rope: Rope
    let cursor: LogicalCursor
    let marks: [StoredEditMark]
    let metadata: String?
}

/// Direction hint for moving a cursor out of an enclosing virtual extmark.
public enum KeepOutsideDirection: Int, Sendable {
    case nearer = 0
    case end = 1
    case start = -1
}

/// Returns the document display-cell offset at the end of `text` as an `EditBuffer` lays it out.
// parity: core/src/edit-buffer.ts#measureEditText [status=implemented hash=3e81d1c00f35]
public func measureEditText(
    _ text: String,
    widthMethod: TextWidthMethod = .unicode,
    tabWidth: Int? = nil
) -> Int {
    let normalized = _TextEngineMetrics.normalizeLineEndings(text)
    let effectiveTabWidth = (tabWidth ?? 0) > 0 ? tabWidth! : 2
    return _TextEngineMetrics.documentDisplayWidth(normalized, tabWidth: effectiveTabWidth, widthMethod: widthMethod)
}

// MARK: - EditBuffer

/// Pure-Swift editable text buffer with balanced `Rope` snapshots, grapheme/word/line cursor motion,
/// undo/redo history, highlights, and native extmark tracking.
// parity: core/src/edit-buffer.ts#EditBuffer [status=implemented hash=eab3f6a60ba5]
public final class EditBuffer {
    public let textBuffer: TextBuffer
    public let id: UInt32

    private var _cursor: LogicalCursor = LogicalCursor()
    private var _desiredCol: Int = 0
    private var _marks: [StoredEditMark] = []
    private var _nextMarkId: UInt32 = 1
    private var _undoStack: [EditHistorySnapshot] = []
    private var _redoStack: [EditHistorySnapshot] = []
    private var _destroyed: Bool = false

    /// Optional opaque syntax style token (decoupled from sibling `SyntaxStyle` target).
    public var syntaxStyleToken: UInt32? {
        get { textBuffer.syntaxStyleToken }
        set { textBuffer.syntaxStyleToken = newValue }
    }

    /// Invoked when text replacement drops marks with history, or on destroy.
    internal var _onHistoryReset: (() -> Void)?
    /// Set by `ExtmarksController`: whether atomic cursor rules around virtual extmarks apply now.
    internal var _atomic: (() -> Bool)?
    /// Shared per-buffer extmark payload & type registry (owned by this buffer, outlives individual controllers).
    internal var _extmarksState: ExtmarksBufferState?
    /// Internal listener list for views observing cursor changes.
    private var _cursorListeners: [(id: Int, handler: () -> Void)] = []
    private var _nextListenerId: Int = 1

    public init(widthMethod: TextWidthMethod = .unicode, tabWidth: Int = 2, id: UInt32 = 1) {
        self.textBuffer = TextBuffer(widthMethod: widthMethod, tabWidth: tabWidth)
        self.id = id
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.create [status=implemented hash=937d9ab23559]
    public static func create(widthMethod: TextWidthMethod = .unicode) -> EditBuffer {
        EditBuffer(widthMethod: widthMethod)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.isDestroyed [status=implemented hash=0ebb2d8ca234]
    public var isDestroyed: Bool {
        _destroyed
    }

    private func assertAlive() {
        precondition(!_destroyed, "EditBuffer is destroyed")
    }

    internal func addCursorListener(_ handler: @escaping () -> Void) -> Int {
        let listenerId = _nextListenerId
        _nextListenerId += 1
        _cursorListeners.append((id: listenerId, handler: handler))
        return listenerId
    }

    internal func removeCursorListener(_ listenerId: Int) {
        _cursorListeners.removeAll { $0.id == listenerId }
    }

    private func notifyCursorChanged() {
        for entry in _cursorListeners {
            entry.handler()
        }
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.runMutation [status=implemented hash=fcf2a96ee1c0]
    public func runMutation<T>(_ operation: () throws -> T) rethrows -> T {
        assertAlive()
        return try operation()
    }

    // MARK: - Text Replacement & History

    private func pushUndo(metadata: String? = nil) {
        _undoStack.append(EditHistorySnapshot(
            rope: textBuffer._rope.snapshot(),
            cursor: _cursor,
            marks: _marks,
            metadata: metadata
        ))
        _redoStack.removeAll(keepingCapacity: true)
    }

    private func spliceMarks(startByte: Int, deletedBytes: Int, insertedBytes: Int) {
        guard !_marks.isEmpty else { return }
        let deleteEnd = startByte + deletedBytes
        var updated: [StoredEditMark] = []
        updated.reserveCapacity(_marks.count)
        for var mark in _marks {
            if mark.applyDelete(start: startByte, end: deleteEnd),
               mark.applyInsert(at: startByte, count: insertedBytes)
            {
                updated.append(mark)
            }
        }
        updated.sort(by: StoredEditMark.sortOrder)
        _marks = updated
    }

    private func setBufferText(_ text: String, preserveHistory: Bool) {
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        if preserveHistory {
            pushUndo()
            let oldLen = textBuffer._rope.utf8Count
            textBuffer.replaceRope(Rope(normalized))
            spliceMarks(startByte: 0, deletedBytes: oldLen, insertedBytes: textBuffer._rope.utf8Count)
        } else {
            _undoStack.removeAll()
            _redoStack.removeAll()
            _marks.removeAll()
            textBuffer.replaceRope(Rope(normalized))
            _onHistoryReset?()
        }
        _cursor = LogicalCursor(row: 0, col: 0, offset: 0)
        _desiredCol = 0
        notifyCursorChanged()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setText [status=implemented hash=426a2a6a7c97]
    public func setText(_ text: String) {
        assertAlive()
        setBufferText(text, preserveHistory: false)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setTextOwned [status=implemented hash=bfe5051c8c34]
    public func setTextOwned(_ text: String) {
        setText(text)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.replaceText [status=implemented hash=a044b38d8062]
    public func replaceText(_ text: String) {
        assertAlive()
        setBufferText(text, preserveHistory: true)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.replaceTextOwned [status=implemented hash=0f9c2201ea54]
    public func replaceTextOwned(_ text: String) {
        replaceText(text)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getLineCount [status=implemented hash=902295187f8e]
    public func getLineCount() -> Int {
        assertAlive()
        return textBuffer.getLineCount()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setTabWidth [status=implemented hash=21fb1b35c1ff]
    public func setTabWidth(_ width: Int) {
        assertAlive()
        textBuffer.setTabWidth(width)
        refreshCursorFromRowCol(row: _cursor.row, col: _cursor.col, updateDesired: true)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getTabWidth [status=implemented hash=5934ea00b1cb]
    public func getTabWidth() -> Int {
        assertAlive()
        return textBuffer.getTabWidth()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getText [status=implemented hash=4ea880d49dd6]
    public func getText() -> String {
        assertAlive()
        return textBuffer.getPlainText()
    }

    // MARK: - Editing Operations

    // parity: core/src/edit-buffer.ts#EditBuffer.insertChar [status=implemented hash=bcc6e60cc4a1]
    public func insertChar(_ char: String) {
        insertText(char)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.insertText [status=implemented hash=38eb17f6f7d9]
    public func insertText(_ text: String) {
        assertAlive()
        guard !text.isEmpty else { return }
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        pushUndo()
        let insertByte = textBuffer.utf8Offset(forDocumentCellOffset: _cursor.offset, roundDown: true)
        let newRope = textBuffer._rope.inserting(normalized, atUTF8: insertByte)
        textBuffer.replaceRope(newRope)
        spliceMarks(startByte: insertByte, deletedBytes: 0, insertedBytes: normalized.utf8.count)
        let newByte = insertByte + normalized.utf8.count
        let newOffset = textBuffer.documentCellOffset(forUTF8Offset: newByte, roundDown: true)
        setCursorByOffsetRaw(newOffset)
    }

    private func atomicRulesActive() -> Bool {
        _atomic?() ?? false
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.deleteChar [status=implemented hash=9d3c8e3e717b]
    public func deleteChar() {
        assertAlive()
        if atomicRulesActive() {
            deleteAtomic(forward: true)
            return
        }
        deleteForwardRaw()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.deleteCharBackward [status=implemented hash=8a61ddddf14c]
    public func deleteCharBackward() {
        assertAlive()
        if atomicRulesActive() {
            deleteAtomic(forward: false)
            return
        }
        deleteBackwardRaw()
    }

    /// Convenience alias for `deleteCharBackward()`.
    public func deleteBackward() {
        deleteCharBackward()
    }

    /// Convenience alias for `deleteChar()`.
    public func deleteForward() {
        deleteChar()
    }

    private func deleteForwardRaw() {
        let docLen = textBuffer.documentCellLength
        guard _cursor.offset < docLen else { return }
        let startByte = textBuffer.utf8Offset(forDocumentCellOffset: _cursor.offset, roundDown: true)
        let nextOffset = nextCursorStop(from: _cursor.offset)
        let endByte = textBuffer.utf8Offset(forDocumentCellOffset: nextOffset, roundDown: true)
        guard startByte < endByte else { return }
        pushUndo()
        let newRope = textBuffer._rope.deleting(utf8Range: startByte..<endByte)
        textBuffer.replaceRope(newRope)
        spliceMarks(startByte: startByte, deletedBytes: endByte - startByte, insertedBytes: 0)
        setCursorByOffsetRaw(_cursor.offset)
    }

    private func deleteBackwardRaw() {
        guard _cursor.offset > 0 else { return }
        let endByte = textBuffer.utf8Offset(forDocumentCellOffset: _cursor.offset, roundDown: true)
        let prevOffset = prevCursorStop(from: _cursor.offset)
        let startByte = textBuffer.utf8Offset(forDocumentCellOffset: prevOffset, roundDown: true)
        guard startByte < endByte else { return }
        pushUndo()
        let newRope = textBuffer._rope.deleting(utf8Range: startByte..<endByte)
        textBuffer.replaceRope(newRope)
        spliceMarks(startByte: startByte, deletedBytes: endByte - startByte, insertedBytes: 0)
        setCursorByOffsetRaw(prevOffset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.deleteRange [status=implemented hash=25a48213fe14]
    public func deleteRange(startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        assertAlive()
        let startOffset = positionToOffset(row: startLine, col: startCol)
        let endOffset = positionToOffset(row: endLine, col: endCol)
        deleteOffsetRange(startOffset: startOffset, endOffset: endOffset)
    }

    internal func deleteOffsetRange(startOffset: Int, endOffset: Int) {
        let lo = max(0, min(startOffset, endOffset))
        let hi = max(startOffset, endOffset)
        guard lo < hi else { return }
        let startByte = textBuffer.utf8Offset(forDocumentCellOffset: lo, roundDown: true)
        let endByte = textBuffer.utf8Offset(forDocumentCellOffset: hi, roundDown: true)
        guard startByte < endByte else { return }
        pushUndo()
        let newRope = textBuffer._rope.deleting(utf8Range: startByte..<endByte)
        textBuffer.replaceRope(newRope)
        spliceMarks(startByte: startByte, deletedBytes: endByte - startByte, insertedBytes: 0)
        setCursorByOffsetRaw(lo)
    }

    /// Replaces `[startOffset, endOffset)` with `text` in a single atomic undo step.
    internal func replaceOffsetRange(startOffset: Int, endOffset: Int, with text: String) {
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        let lo = max(0, min(startOffset, endOffset))
        let hi = max(startOffset, endOffset)
        let startByte = textBuffer.utf8Offset(forDocumentCellOffset: lo, roundDown: true)
        let endByte = textBuffer.utf8Offset(forDocumentCellOffset: hi, roundDown: true)
        pushUndo()
        let newRope = textBuffer._rope.replacing(utf8Range: startByte..<endByte, with: normalized)
        textBuffer.replaceRope(newRope)
        spliceMarks(startByte: startByte, deletedBytes: endByte - startByte, insertedBytes: normalized.utf8.count)
        let newByte = startByte + normalized.utf8.count
        let newOffset = textBuffer.documentCellOffset(forUTF8Offset: newByte, roundDown: true)
        setCursorByOffsetRaw(newOffset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.newLine [status=implemented hash=3a2e5284f08c]
    public func newLine() {
        insertText("\n")
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.deleteLine [status=implemented hash=bcfeb4399117]
    public func deleteLine() {
        assertAlive()
        let row = _cursor.row
        let totalLines = textBuffer.getLineCount()
        guard let lineRange = textBuffer._rope.lineRange(at: row) else { return }
        let deleteRange: Range<Int>
        let targetRow: Int
        if totalLines == 1 {
            guard !lineRange.isEmpty else { return }
            deleteRange = lineRange
            targetRow = 0
        } else if row + 1 < totalLines {
            // Delete this line plus its trailing '\n'
            deleteRange = lineRange.lowerBound..<(lineRange.upperBound + 1)
            targetRow = row
        } else {
            // Last line: delete preceding '\n' and this line
            deleteRange = max(0, lineRange.lowerBound - 1)..<lineRange.upperBound
            targetRow = row - 1
        }
        guard deleteRange.lowerBound < deleteRange.upperBound else { return }
        pushUndo()
        let newRope = textBuffer._rope.deleting(utf8Range: deleteRange)
        textBuffer.replaceRope(newRope)
        spliceMarks(
            startByte: deleteRange.lowerBound,
            deletedBytes: deleteRange.upperBound - deleteRange.lowerBound,
            insertedBytes: 0
        )
        let clampedRow = max(0, min(targetRow, textBuffer.getLineCount() - 1))
        let newLineWidth = _TextEngineMetrics.lineDisplayWidth(
            textBuffer.getLine(clampedRow),
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
        refreshCursorFromRowCol(row: clampedRow, col: min(_desiredCol, newLineWidth), updateDesired: false)
    }

    /// Deletes from the previous word boundary to the cursor.
    public func deleteWordBackward() {
        assertAlive()
        let prev = getPrevWordBoundary()
        guard prev.offset < _cursor.offset else { return }
        deleteOffsetRange(startOffset: prev.offset, endOffset: _cursor.offset)
    }

    /// Deletes from the cursor to the next word boundary.
    public func deleteWordForward() {
        assertAlive()
        let next = getNextWordBoundary()
        guard next.offset > _cursor.offset else { return }
        deleteOffsetRange(startOffset: _cursor.offset, endOffset: next.offset)
    }

    /// Deletes from the start of the current logical line to the cursor.
    public func deleteToLineStart() {
        assertAlive()
        guard _cursor.col > 0 else { return }
        deleteRange(startLine: _cursor.row, startCol: 0, endLine: _cursor.row, endCol: _cursor.col)
    }

    /// Deletes from the cursor to the end of the current logical line.
    public func deleteToLineEnd() {
        assertAlive()
        let eol = getEOL()
        guard _cursor.col < eol.col else { return }
        deleteRange(startLine: _cursor.row, startCol: _cursor.col, endLine: eol.row, endCol: eol.col)
    }

    // MARK: - Cursor Movement

    private func prevCursorStop(from offset: Int) -> Int {
        guard offset > 0, let pos = textBuffer.offsetToPosition(offset) else { return 0 }
        if pos.col == 0 {
            return offset - 1
        }
        let line = textBuffer.getLine(pos.row)
        let clusters = _TextEngineMetrics.lineClusters(line, tabWidth: textBuffer.getTabWidth(), widthMethod: textBuffer.widthMethod)
        let lineStart = textBuffer.getLineStartOffset(pos.row)
        var prevCol = 0
        for c in clusters {
            if c.colStart >= pos.col { break }
            prevCol = c.colStart
        }
        return lineStart + prevCol
    }

    private func nextCursorStop(from offset: Int) -> Int {
        let docLen = textBuffer.documentCellLength
        guard offset < docLen, let pos = textBuffer.offsetToPosition(offset) else { return docLen }
        let line = textBuffer.getLine(pos.row)
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        let lineWidth = _TextEngineMetrics.lineDisplayWidth(line, tabWidth: tabWidth, widthMethod: method)
        if pos.col >= lineWidth {
            // Move across '\n' to next line start
            return min(docLen, offset + 1)
        }
        let clusters = _TextEngineMetrics.lineClusters(line, tabWidth: tabWidth, widthMethod: method)
        let lineStart = textBuffer.getLineStartOffset(pos.row)
        for c in clusters {
            if c.colEnd > pos.col {
                return lineStart + c.colEnd
            }
        }
        return lineStart + lineWidth
    }

    private func refreshCursorFromRowCol(row: Int, col: Int, updateDesired: Bool) {
        let lines = textBuffer.getLineCount()
        let clampedRow = max(0, min(row, lines - 1))
        let line = textBuffer.getLine(clampedRow)
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        let lineWidth = _TextEngineMetrics.lineDisplayWidth(line, tabWidth: tabWidth, widthMethod: method)
        let clampedCol = max(0, min(col, lineWidth))
        let snappedCol = _TextEngineMetrics.snapColDown(clampedCol, in: line, tabWidth: tabWidth, widthMethod: method)
        let offset = textBuffer.positionToOffset(row: clampedRow, col: snappedCol)
        _cursor = LogicalCursor(row: clampedRow, col: snappedCol, offset: offset)
        if updateDesired {
            _desiredCol = snappedCol
        }
        notifyCursorChanged()
    }

    private func setCursorByOffsetRaw(_ offset: Int) {
        let docLen = textBuffer.documentCellLength
        let clamped = max(0, min(offset, docLen))
        if let pos = textBuffer.offsetToPosition(clamped) {
            let exactOffset = textBuffer.positionToOffset(row: pos.row, col: pos.col)
            _cursor = LogicalCursor(row: pos.row, col: pos.col, offset: exactOffset)
            _desiredCol = pos.col
        } else {
            _cursor = LogicalCursor(row: 0, col: 0, offset: 0)
            _desiredCol = 0
        }
        notifyCursorChanged()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.moveCursorLeft [status=implemented hash=4c529fca1218]
    public func moveCursorLeft() {
        assertAlive()
        if atomicRulesActive() {
            moveAtomic(right: false)
            return
        }
        setCursorByOffsetRaw(prevCursorStop(from: _cursor.offset))
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.moveCursorRight [status=implemented hash=199a8a605258]
    public func moveCursorRight() {
        assertAlive()
        if atomicRulesActive() {
            moveAtomic(right: true)
            return
        }
        setCursorByOffsetRaw(nextCursorStop(from: _cursor.offset))
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.moveCursorUp [status=implemented hash=3d0d1cbd4309]
    public func moveCursorUp() {
        assertAlive()
        guard _cursor.row > 0 else { return }
        refreshCursorFromRowCol(row: _cursor.row - 1, col: _desiredCol, updateDesired: false)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.moveCursorDown [status=implemented hash=2534bc1cb54d]
    public func moveCursorDown() {
        assertAlive()
        guard _cursor.row + 1 < textBuffer.getLineCount() else { return }
        refreshCursorFromRowCol(row: _cursor.row + 1, col: _desiredCol, updateDesired: false)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.gotoLine [status=implemented hash=7e9bc1b758f0]
    public func gotoLine(_ line: Int) {
        assertAlive()
        refreshCursorFromRowCol(row: line, col: 0, updateDesired: true)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setCursor [status=implemented hash=67d3bc56c701]
    public func setCursor(line: Int, col: Int) {
        assertAlive()
        refreshCursorFromRowCol(row: line, col: col, updateDesired: true)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setCursorToLineCol [status=implemented hash=b8eb23df1a3f]
    public func setCursorToLineCol(line: Int, col: Int) {
        setCursor(line: line, col: col)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setCursorByOffset [status=implemented hash=32840e5ae657]
    public func setCursorByOffset(_ offset: Int) {
        assertAlive()
        if atomicRulesActive() {
            setCursorByOffsetAtomic(offset)
            return
        }
        setCursorByOffsetRaw(offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getCursorPosition [status=implemented hash=509c70bd1488]
    public func getCursorPosition() -> LogicalCursor {
        assertAlive()
        return _cursor
    }

    // MARK: - Atomic Virtual Extmark Rules (Port of edit-buffer.zig)

    private func markCellSpan(_ mark: StoredEditMark) -> (start: Int, end: Int) {
        let start = textBuffer.documentCellOffset(forUTF8Offset: mark.startByte, roundDown: true)
        let end = textBuffer.documentCellOffset(forUTF8Offset: mark.endByte, roundDown: false)
        return (start, end)
    }

    private func oldestAtomic(at offset: Int, startMin: Int, endMax: Int) -> (start: Int, end: Int)? {
        var found: (start: Int, end: Int)? = nil
        var foundId: UInt32 = .max
        for mark in _marks {
            guard mark.atomic && mark.id <= foundId else { continue }
            let span = markCellSpan(mark)
            if span.start <= offset && offset < span.end && span.start >= startMin && span.end <= endMax {
                found = span
                foundId = mark.id
            }
        }
        return found
    }

    private func outsideAtomic(_ offset: Int, toEnd: Bool) -> Int {
        var x = offset
        var moved = true
        while moved {
            moved = false
            for mark in _marks where mark.atomic {
                let span = markCellSpan(mark)
                if span.start < x && x < span.end {
                    x = toEnd ? span.end : span.start
                    moved = true
                }
            }
        }
        return x
    }

    private func unitBeforeAtomic(_ start: Int) -> Int {
        let s = outsideAtomic(start, toEnd: false)
        let p = prevCursorStop(from: s)
        return oldestAtomic(at: p, startMin: 0, endMax: .max) != nil ? s : p
    }

    /// Moves a cursor inside virtual extmarks to their outer edge.
    internal func _keepOutside(direction: KeepOutsideDirection) {
        let c = _cursor.offset
        let start = outsideAtomic(c, toEnd: false)
        if start == c { return }
        let end = outsideAtomic(c, toEnd: true)
        let toEnd: Bool
        switch direction {
        case .nearer:
            toEnd = (end - c) <= (c - start)
        case .end:
            toEnd = true
        case .start:
            toEnd = false
        }
        setCursorByOffsetRaw(toEnd ? end : start)
    }

    private func moveAtomic(right: Bool) {
        let c = _cursor.offset
        let mark: (start: Int, end: Int)?
        if right {
            mark = oldestAtomic(at: c + 1, startMin: c, endMax: .max)
                ?? oldestAtomic(at: c, startMin: c, endMax: .max)
        } else {
            mark = c > 0 ? oldestAtomic(at: c - 1, startMin: 0, endMax: c) : nil
        }
        if let m = mark {
            setCursorByOffsetRaw(right ? m.end : unitBeforeAtomic(m.start))
        } else if right {
            setCursorByOffsetRaw(nextCursorStop(from: c))
        } else {
            setCursorByOffsetRaw(prevCursorStop(from: c))
        }
        _keepOutside(direction: right ? .end : .start)
    }

    private func setCursorByOffsetAtomic(_ offset: Int) {
        let c = _cursor.offset
        let mark: (start: Int, end: Int)?
        if offset > c {
            mark = oldestAtomic(at: offset, startMin: c, endMax: .max)
        } else if offset < c {
            mark = oldestAtomic(at: offset, startMin: 0, endMax: c)
        } else {
            mark = nil
        }
        if let m = mark {
            setCursorByOffsetRaw(offset > c ? m.end : unitBeforeAtomic(m.start))
        } else {
            setCursorByOffsetRaw(offset)
        }
        let dir: KeepOutsideDirection = offset > c ? .end : (offset < c ? .start : .nearer)
        _keepOutside(direction: dir)
    }

    internal func leaveAtomic(from: Int, down: Bool) {
        let c = _cursor.offset
        if let mark = oldestAtomic(at: c, startMin: 0, endMax: .max) {
            let p = prevCursorStop(from: mark.start)
            let end = outsideAtomic(mark.end, toEnd: true)
            let toStart = (c - mark.start < mark.end - c)
                ? (!down || p > from)
                : (!down && end >= from)
            setCursorByOffsetRaw(toStart ? outsideAtomic(p, toEnd: down) : end)
        }
        _keepOutside(direction: down ? .end : .start)
    }

    private func deleteAtomic(forward: Bool) {
        let c = _cursor.offset
        let mark: (start: Int, end: Int)?
        if forward {
            mark = oldestAtomic(at: c, startMin: c, endMax: .max)
        } else {
            mark = c > 0 ? oldestAtomic(at: c - 1, startMin: 0, endMax: c) : nil
        }
        if let m = mark {
            deleteOffsetRange(startOffset: m.start, endOffset: m.end)
        } else if forward {
            deleteForwardRaw()
        } else {
            deleteBackwardRaw()
        }
        _keepOutside(direction: .nearer)
    }

    // MARK: - Internal Native Mark CRUD (used by ExtmarksController)

    internal func _addMark(
        kind: UInt32,
        atomic: Bool,
        style: UInt32,
        priority: UInt32,
        start: Int,
        end: Int
    ) -> UInt32 {
        assertAlive()
        guard _marks.count < 65_536 && _nextMarkId < UInt32.max else { return 0 }
        let startByte = textBuffer.utf8Offset(forDocumentCellOffset: start, roundDown: true)
        let endByte = textBuffer.utf8Offset(forDocumentCellOffset: end, roundDown: true)
        let id = _nextMarkId
        _nextMarkId += 1
        let mark = StoredEditMark(
            id: id,
            kind: kind,
            atomic: atomic,
            style: style,
            priority: priority,
            startByte: startByte,
            endByte: max(startByte, endByte)
        )
        _marks.append(mark)
        _marks.sort(by: StoredEditMark.sortOrder)
        return id
    }

    internal func _removeMark(id: UInt32) -> Bool {
        assertAlive()
        guard let idx = _marks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        _marks.remove(at: idx)
        return true
    }

    internal func _clearMarks() {
        assertAlive()
        _marks.removeAll()
    }

    internal func _getMarks(id: UInt32? = nil, kind: UInt32? = nil) -> [NativeEditMark] {
        assertAlive()
        var result: [NativeEditMark] = []
        for mark in _marks {
            if let id, mark.id != id { continue }
            if let kind, mark.kind != kind { continue }
            let span = markCellSpan(mark)
            result.append(NativeEditMark(
                id: mark.id,
                kind: mark.kind,
                atomic: mark.atomic,
                style: mark.style,
                priority: mark.priority,
                start: span.start,
                end: span.end
            ))
        }
        return result
    }

    // MARK: - Word Boundaries & Position Queries

    // parity: core/src/edit-buffer.ts#EditBuffer.getNextWordBoundary [status=implemented hash=be5e0347690f]
    public func getNextWordBoundary() -> LogicalCursor {
        assertAlive()
        let lineCount = textBuffer.getLineCount()
        guard _cursor.row < lineCount else { return _cursor }
        let line = textBuffer.getLine(_cursor.row)
        let tabWidth = textBuffer.getTabWidth()
        let method = textBuffer.widthMethod
        let clusters = _TextEngineMetrics.lineClusters(line, tabWidth: tabWidth, widthMethod: method)
        let lineWidth = clusters.last?.colEnd ?? 0

        if _cursor.col < lineWidth {
            // Find cluster at or after cursor.col
            var idx = 0
            while idx < clusters.count && clusters[idx].colEnd <= _cursor.col {
                idx += 1
            }
            if idx < clusters.count {
                let startClass = _TextEngineMetrics.classifyWord(clusters[idx].character)
                var i = idx + 1
                // Consume run of same class (note: CJK characters break individually or at script transition)
                if startClass != .cjk {
                    while i < clusters.count && _TextEngineMetrics.classifyWord(clusters[i].character) == startClass {
                        i += 1
                    }
                }
                // If we started on whitespace, also consume the following word/punctuation run?
                // Match upstream word boundary: stop after whitespace run or at transition into next word.
                if startClass == .asciiWord || startClass == .punctuation {
                    // Advance past trailing whitespace if next boundary is after a delimiter
                    while i < clusters.count && _TextEngineMetrics.classifyWord(clusters[i].character) == .whitespace {
                        i += 1
                    }
                }
                let targetCol = i < clusters.count ? clusters[i].colStart : lineWidth
                let offset = textBuffer.positionToOffset(row: _cursor.row, col: targetCol)
                return LogicalCursor(row: _cursor.row, col: targetCol, offset: offset)
            }
        }

        if _cursor.row + 1 < lineCount {
            let offset = textBuffer.positionToOffset(row: _cursor.row + 1, col: 0)
            return LogicalCursor(row: _cursor.row + 1, col: 0, offset: offset)
        }
        let offset = textBuffer.positionToOffset(row: _cursor.row, col: lineWidth)
        return LogicalCursor(row: _cursor.row, col: lineWidth, offset: offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getPrevWordBoundary [status=implemented hash=262d351305d1]
    public func getPrevWordBoundary() -> LogicalCursor {
        assertAlive()
        if _cursor.row == 0 && _cursor.col == 0 {
            return _cursor
        }
        if _cursor.col == 0 && _cursor.row > 0 {
            let prevRow = _cursor.row - 1
            let prevLine = textBuffer.getLine(prevRow)
            let prevWidth = _TextEngineMetrics.lineDisplayWidth(
                prevLine,
                tabWidth: textBuffer.getTabWidth(),
                widthMethod: textBuffer.widthMethod
            )
            let offset = textBuffer.positionToOffset(row: prevRow, col: prevWidth)
            return LogicalCursor(row: prevRow, col: prevWidth, offset: offset)
        }

        let line = textBuffer.getLine(_cursor.row)
        let clusters = _TextEngineMetrics.lineClusters(
            line,
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
        // Find last cluster strictly before cursor.col
        var idx = clusters.count - 1
        while idx >= 0 && clusters[idx].colStart >= _cursor.col {
            idx -= 1
        }
        if idx < 0 {
            let offset = textBuffer.positionToOffset(row: _cursor.row, col: 0)
            return LogicalCursor(row: _cursor.row, col: 0, offset: offset)
        }

        // Skip trailing whitespace before cursor
        while idx >= 0 && _TextEngineMetrics.classifyWord(clusters[idx].character) == .whitespace {
            idx -= 1
        }
        if idx < 0 {
            let offset = textBuffer.positionToOffset(row: _cursor.row, col: 0)
            return LogicalCursor(row: _cursor.row, col: 0, offset: offset)
        }

        let targetClass = _TextEngineMetrics.classifyWord(clusters[idx].character)
        if targetClass != .cjk {
            while idx > 0 && _TextEngineMetrics.classifyWord(clusters[idx - 1].character) == targetClass {
                idx -= 1
            }
        }
        let targetCol = clusters[idx].colStart
        let offset = textBuffer.positionToOffset(row: _cursor.row, col: targetCol)
        return LogicalCursor(row: _cursor.row, col: targetCol, offset: offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getEOL [status=implemented hash=4c1c65a9e39d]
    public func getEOL() -> LogicalCursor {
        assertAlive()
        let lineCount = textBuffer.getLineCount()
        guard _cursor.row < lineCount else { return _cursor }
        let line = textBuffer.getLine(_cursor.row)
        let width = _TextEngineMetrics.lineDisplayWidth(
            line,
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
        let offset = textBuffer.positionToOffset(row: _cursor.row, col: width)
        return LogicalCursor(row: _cursor.row, col: width, offset: offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.offsetToPosition [status=implemented hash=668541d1b163]
    public func offsetToPosition(_ offset: Int) -> (row: Int, col: Int)? {
        assertAlive()
        return textBuffer.offsetToPosition(offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.positionToOffset [status=implemented hash=0e56c17f9434]
    public func positionToOffset(row: Int, col: Int) -> Int {
        assertAlive()
        return textBuffer.positionToOffset(row: row, col: col)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getLineStartOffset [status=implemented hash=a40e0617679a]
    public func getLineStartOffset(_ row: Int) -> Int {
        assertAlive()
        return textBuffer.getLineStartOffset(row)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.measureText [status=implemented hash=d58c46d2f5c1]
    public func measureText(_ text: String) -> Int {
        assertAlive()
        let normalized = _TextEngineMetrics.normalizeLineEndings(text)
        return _TextEngineMetrics.documentDisplayWidth(
            normalized,
            tabWidth: textBuffer.getTabWidth(),
            widthMethod: textBuffer.widthMethod
        )
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.stringIndexToCellOffset [status=implemented hash=c895ff1c55a5]
    public func stringIndexToCellOffset(_ index: Int) -> Int {
        assertAlive()
        return textBuffer.stringIndexToCellOffset(index)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.cellOffsetToStringIndex [status=implemented hash=b7aefc149a9a]
    public func cellOffsetToStringIndex(_ offset: Int) -> Int {
        assertAlive()
        return textBuffer.cellOffsetToStringIndex(offset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getTextRange [status=implemented hash=2b0acdbc2d7c]
    public func getTextRange(startOffset: Int, endOffset: Int) -> String {
        assertAlive()
        return textBuffer.getTextRange(startOffset: startOffset, endOffset: endOffset)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getTextRangeByCoords [status=implemented hash=106b7d14d2da]
    public func getTextRangeByCoords(startRow: Int, startCol: Int, endRow: Int, endCol: Int) -> String {
        assertAlive()
        return textBuffer.getTextRangeByCoords(startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.debugLogRope [status=implemented hash=a2e40aaf641a]
    public func debugLogRope() -> String {
        assertAlive()
        let m = textBuffer._rope.metrics
        return "Rope(utf8=\(m.utf8Length), utf16=\(m.utf16Length), lines=\(textBuffer._rope.lineCount), leaves=\(m.leafCount), depth=\(m.depth))"
    }

    // MARK: - Undo / Redo

    // parity: core/src/edit-buffer.ts#EditBuffer.undo [status=implemented hash=ec58842770f1]
    @discardableResult
    public func undo() -> String? {
        assertAlive()
        guard let previous = _undoStack.popLast() else { return nil }
        _redoStack.append(EditHistorySnapshot(
            rope: textBuffer._rope.snapshot(),
            cursor: _cursor,
            marks: _marks,
            metadata: previous.metadata
        ))
        textBuffer.replaceRope(previous.rope)
        _marks = previous.marks
        _cursor = previous.cursor
        _desiredCol = previous.cursor.col
        notifyCursorChanged()
        return previous.metadata ?? ""
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.redo [status=implemented hash=3974e5440a5b]
    @discardableResult
    public func redo() -> String? {
        assertAlive()
        guard let next = _redoStack.popLast() else { return nil }
        _undoStack.append(EditHistorySnapshot(
            rope: textBuffer._rope.snapshot(),
            cursor: _cursor,
            marks: _marks,
            metadata: next.metadata
        ))
        textBuffer.replaceRope(next.rope)
        _marks = next.marks
        _cursor = next.cursor
        _desiredCol = next.cursor.col
        notifyCursorChanged()
        return next.metadata ?? ""
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.canUndo [status=implemented hash=89d600059513]
    public func canUndo() -> Bool {
        assertAlive()
        return !_undoStack.isEmpty
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.canRedo [status=implemented hash=d78a903c85de]
    public func canRedo() -> Bool {
        assertAlive()
        return !_redoStack.isEmpty
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.clearHistory [status=implemented hash=5e5dce9c2344]
    public func clearHistory() {
        assertAlive()
        _undoStack.removeAll()
        _redoStack.removeAll()
    }

    // MARK: - Defaults & Highlights

    // parity: core/src/edit-buffer.ts#EditBuffer.setDefaultFg [status=implemented hash=7aa4d6292eb4]
    public func setDefaultFg(_ fg: RGBA?) {
        assertAlive()
        textBuffer.setDefaultFg(fg)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setDefaultBg [status=implemented hash=7480da1a6ee0]
    public func setDefaultBg(_ bg: RGBA?) {
        assertAlive()
        textBuffer.setDefaultBg(bg)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.setDefaultAttributes [status=implemented hash=74d76150dbee]
    public func setDefaultAttributes(_ attributes: UInt32?) {
        assertAlive()
        textBuffer.setDefaultAttributes(attributes)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.resetDefaults [status=implemented hash=0c56e124127d]
    public func resetDefaults() {
        assertAlive()
        textBuffer.resetDefaults()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.addHighlight [status=implemented hash=a0da54ba434d]
    public func addHighlight(lineIdx: Int, highlight: Highlight) {
        assertAlive()
        textBuffer.addHighlight(lineIdx: lineIdx, highlight: highlight)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.addHighlightByCharRange [status=implemented hash=98e4d276f24c]
    public func addHighlightByCharRange(_ highlight: Highlight) {
        assertAlive()
        textBuffer.addHighlightByCharRange(highlight)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.removeHighlightsByRef [status=implemented hash=1c3b0adc0247]
    public func removeHighlightsByRef(_ hlRef: Int) {
        assertAlive()
        textBuffer.removeHighlightsByRef(hlRef)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.clearLineHighlights [status=implemented hash=2398396746ea]
    public func clearLineHighlights(_ lineIdx: Int) {
        assertAlive()
        textBuffer.clearLineHighlights(lineIdx)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.clearAllHighlights [status=implemented hash=7130e621c8b7]
    public func clearAllHighlights() {
        assertAlive()
        textBuffer.clearAllHighlights()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.getLineHighlights [status=implemented hash=c43ff9f36f42]
    public func getLineHighlights(_ lineIdx: Int) -> [Highlight] {
        assertAlive()
        return textBuffer.getLineHighlights(lineIdx)
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.clear [status=implemented hash=b261f63ebd08]
    public func clear() {
        assertAlive()
        guard !textBuffer._rope.isEmpty else { return }
        pushUndo()
        let oldLen = textBuffer._rope.utf8Count
        textBuffer.clear()
        spliceMarks(startByte: 0, deletedBytes: oldLen, insertedBytes: 0)
        _cursor = LogicalCursor(row: 0, col: 0, offset: 0)
        _desiredCol = 0
        notifyCursorChanged()
    }

    // parity: core/src/edit-buffer.ts#EditBuffer.destroy [status=implemented hash=e5c0326a9856]
    public func destroy() {
        guard !_destroyed else { return }
        _destroyed = true
        _undoStack.removeAll()
        _redoStack.removeAll()
        _marks.removeAll()
        _onHistoryReset?()
        _cursorListeners.removeAll()
        textBuffer.destroy()
    }
}

// MARK: - EditorView

/// Pure-Swift editor viewport, wrapped visual navigation, selection, placeholder, and extmarks host.
// parity: core/src/editor-view.ts#EditorView [status=implemented hash=b405254c06d4]
public final class EditorView {
    public let editBuffer: EditBuffer
    public let textBufferView: TextBufferView

    private var _destroyed: Bool = false
    private var _scrollMargin: Double = 0.15
    private var _desiredVisualCol: Int? = nil
    private var _placeholderChunks: [TextChunk] = []
    private var _extmarksController: ExtmarksController? = nil
    private var _cursorListenerId: Int = 0

    /// Set while an `ExtmarksController` lives on this view.
    internal var _atomic: Bool = false

    public init(editBuffer: EditBuffer, viewportWidth: Int, viewportHeight: Int) {
        self.editBuffer = editBuffer
        self.textBufferView = TextBufferView(textBuffer: editBuffer.textBuffer)
        self.textBufferView.setViewport(x: 0, y: 0, width: max(0, viewportWidth), height: max(0, viewportHeight))
        self._cursorListenerId = editBuffer.addCursorListener { [weak self] in
            self?.handleCursorChanged()
        }
    }

    // parity: core/src/editor-view.ts#EditorView.create [status=implemented hash=5f3318e065de]
    public static func create(editBuffer: EditBuffer, viewportWidth: Int, viewportHeight: Int) -> EditorView {
        EditorView(editBuffer: editBuffer, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }

    // parity: core/src/editor-view.ts#EditorView.isDestroyed [status=implemented hash=0ebb2d8ca234]
    public var isDestroyed: Bool {
        _destroyed
    }

    public var placeholderChunks: [TextChunk] {
        _placeholderChunks
    }

    private func assertAlive() {
        precondition(!_destroyed, "EditorView is destroyed")
        precondition(!editBuffer.isDestroyed, "Backing EditBuffer is destroyed")
    }

    private func handleCursorChanged() {
        guard !_destroyed && !editBuffer.isDestroyed else { return }
        _desiredVisualCol = nil
        if !textBufferView.hasSelection() {
            ensureCursorVisible()
        }
    }

    private func atomicRulesActive() -> Bool {
        _atomic && !hasSelection()
    }

    // MARK: - Viewport Management

    // parity: core/src/editor-view.ts#EditorView.setViewportSize [status=implemented hash=7087934a6300]
    public func setViewportSize(width: Int, height: Int) {
        assertAlive()
        textBufferView.setViewportSize(width: width, height: height)
        ensureCursorVisible()
    }

    // parity: core/src/editor-view.ts#EditorView.setViewport [status=implemented hash=6bdb6d2a287e]
    public func setViewport(x: Int, y: Int, width: Int, height: Int, moveCursor: Bool = true) {
        assertAlive()
        textBufferView.setViewport(x: x, y: y, width: width, height: height)
        if moveCursor {
            makeCursorVisible()
        }
    }

    // parity: core/src/editor-view.ts#EditorView.getViewport [status=implemented hash=aa8f8899a69b]
    public func getViewport() -> EditorViewport {
        assertAlive()
        let vp = textBufferView.viewport ?? ViewportBounds(x: 0, y: 0, width: 0, height: 0)
        return EditorViewport(offsetY: vp.y, offsetX: vp.x, height: vp.height, width: vp.width)
    }

    // parity: core/src/editor-view.ts#EditorView.setScrollMargin [status=implemented hash=ea61b6a5b492]
    public func setScrollMargin(_ margin: Double) {
        assertAlive()
        _scrollMargin = max(0.0, min(0.5, margin))
    }

    private func ensureCursorVisible() {
        guard let vp = textBufferView.viewport, vp.height > 0 && vp.width > 0 else { return }
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        let totalLines = max(1, textBufferView.getVirtualLineCount())
        let marginRows = Int((Double(vp.height) * _scrollMargin).rounded(.down))

        var newY = vp.y
        if abs.visualRow < newY + marginRows {
            newY = max(0, abs.visualRow - marginRows)
        } else if abs.visualRow >= newY + vp.height - marginRows {
            newY = max(0, abs.visualRow - vp.height + 1 + marginRows)
        }
        let maxY = max(0, totalLines - vp.height)
        newY = max(0, min(newY, maxY))

        var newX = vp.x
        if textBufferView.wrapMode == .none {
            if abs.visualCol < newX {
                newX = abs.visualCol
            } else if abs.visualCol >= newX + vp.width {
                newX = max(0, abs.visualCol - vp.width + 1)
            }
        } else {
            newX = 0
        }

        if newX != vp.x || newY != vp.y {
            textBufferView.setViewport(x: newX, y: newY, width: vp.width, height: vp.height)
        }
    }

    private func makeCursorVisible() {
        guard let vp = textBufferView.viewport, vp.height > 0 && vp.width > 0 else { return }
        let vlines = textBufferView.virtualLines()
        guard !vlines.isEmpty else { return }
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        if abs.visualRow < vp.y {
            let targetVLine = vlines[min(vp.y, vlines.count - 1)]
            let targetCol = min(abs.visualCol, targetVLine.widthCols)
            editBuffer.setCursorByOffset(targetVLine.documentCellOffset + targetCol)
        } else if abs.visualRow >= vp.y + vp.height {
            let targetIdx = min(vp.y + vp.height - 1, vlines.count - 1)
            let targetVLine = vlines[max(0, targetIdx)]
            let targetCol = min(abs.visualCol, targetVLine.widthCols)
            editBuffer.setCursorByOffset(targetVLine.documentCellOffset + targetCol)
        }
    }

    // parity: core/src/editor-view.ts#EditorView.setWrapMode [status=implemented hash=9431310efb6f]
    public func setWrapMode(_ mode: TextWrapMode) {
        assertAlive()
        textBufferView.setWrapMode(mode)
        ensureCursorVisible()
    }

    // parity: core/src/editor-view.ts#EditorView.getVirtualLineCount [status=implemented hash=08f99a948b6e]
    public func getVirtualLineCount() -> Int {
        assertAlive()
        return textBufferView.visibleVirtualLines().count
    }

    // parity: core/src/editor-view.ts#EditorView.getTotalVirtualLineCount [status=implemented hash=fa0356721c82]
    public func getTotalVirtualLineCount() -> Int {
        assertAlive()
        return textBufferView.getVirtualLineCount()
    }

    // MARK: - Selection Operations

    // parity: core/src/editor-view.ts#EditorView.setSelection [status=implemented hash=1bbdb1f890f1]
    public func setSelection(start: Int, end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        textBufferView.setSelection(start: start, end: end, bgColor: bgColor, fgColor: fgColor)
    }

    // parity: core/src/editor-view.ts#EditorView.updateSelection [status=implemented hash=bd5b8bf5b15b]
    public func updateSelection(end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        textBufferView.updateSelection(end: end, bgColor: bgColor, fgColor: fgColor)
    }

    // parity: core/src/editor-view.ts#EditorView.resetSelection [status=implemented hash=c2dca2a01c66]
    public func resetSelection() {
        assertAlive()
        textBufferView.resetSelection()
    }

    // parity: core/src/editor-view.ts#EditorView.getSelection [status=implemented hash=3433e127f42e]
    public func getSelection() -> TextSelectionRange? {
        assertAlive()
        return textBufferView.getSelection()
    }

    // parity: core/src/editor-view.ts#EditorView.hasSelection [status=implemented hash=edf5bc87304e]
    public func hasSelection() -> Bool {
        assertAlive()
        return textBufferView.hasSelection()
    }

    // parity: core/src/editor-view.ts#EditorView.setLocalSelection [status=implemented hash=5dacc2b2fd5f]
    @discardableResult
    public func setLocalSelection(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        bgColor: RGBA? = nil,
        fgColor: RGBA? = nil,
        updateCursor: Bool = false,
        followCursor: Bool = false,
        behavior: SelectionBehavior = .cell
    ) -> Bool {
        assertAlive()
        let changed = textBufferView.setLocalSelection(
            anchorX: anchorX,
            anchorY: anchorY,
            focusX: focusX,
            focusY: focusY,
            bgColor: bgColor,
            fgColor: fgColor,
            behavior: behavior
        )
        if updateCursor, let vp = textBufferView.viewport {
            let offset = textBufferView.localCoordsToDocumentOffset(
                localX: focusX + vp.x,
                vlineIndex: focusY + vp.y,
                viewportWidth: vp.width
            )
            editBuffer.setCursorByOffset(offset)
            if followCursor {
                ensureCursorVisible()
            }
        }
        return changed
    }

    // parity: core/src/editor-view.ts#EditorView.updateLocalSelection [status=implemented hash=2489f8c90bdf]
    @discardableResult
    public func updateLocalSelection(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        bgColor: RGBA? = nil,
        fgColor: RGBA? = nil,
        updateCursor: Bool = false,
        followCursor: Bool = false,
        behavior: SelectionBehavior = .cell
    ) -> Bool {
        setLocalSelection(
            anchorX: anchorX,
            anchorY: anchorY,
            focusX: focusX,
            focusY: focusY,
            bgColor: bgColor,
            fgColor: fgColor,
            updateCursor: updateCursor,
            followCursor: followCursor,
            behavior: behavior
        )
    }

    // parity: core/src/editor-view.ts#EditorView.resetLocalSelection [status=implemented hash=42a60c6f0fa2]
    public func resetLocalSelection() {
        assertAlive()
        textBufferView.resetLocalSelection()
    }

    // parity: core/src/editor-view.ts#EditorView.convertSelectionToCell [status=implemented hash=d49ddadc9e34]
    @discardableResult
    public func convertSelectionToCell() -> Bool {
        assertAlive()
        return textBufferView.convertSelectionToCell()
    }

    // parity: core/src/editor-view.ts#EditorView.setSelectionOccupancy [status=implemented hash=d5b94eba5484]
    public func setSelectionOccupancy(_ occupancy: SelectionOccupancy) {
        assertAlive()
        textBufferView.setSelectionOccupancy(occupancy)
    }

    // parity: core/src/editor-view.ts#EditorView.getSelectionOccupancy [status=implemented hash=785a00112104]
    public func getSelectionOccupancy() -> SelectionOccupancy {
        assertAlive()
        return textBufferView.getSelectionOccupancy()
    }

    // parity: core/src/editor-view.ts#EditorView.setSelectionInclusive [status=implemented hash=0c65ce1dce0c]
    public func setSelectionInclusive(start: Int, end: Int, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        textBufferView.setSelectionInclusive(start: start, end: end, bgColor: bgColor, fgColor: fgColor)
    }

    // parity: core/src/editor-view.ts#EditorView.setSelectionColors [status=implemented hash=be9059e9e325]
    public func setSelectionColors(bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
        assertAlive()
        textBufferView.setSelectionColors(bgColor: bgColor, fgColor: fgColor)
    }

    // parity: core/src/editor-view.ts#EditorView.getSelectedText [status=implemented hash=e782a7fd50cc]
    public func getSelectedText() -> String {
        assertAlive()
        return textBufferView.getSelectedText()
    }

    // parity: core/src/editor-view.ts#EditorView.deleteSelectedText [status=implemented hash=d5b34ca1259a]
    public func deleteSelectedText() {
        assertAlive()
        guard let sel = textBufferView.getSelection(), sel.start < sel.end else { return }
        textBufferView.resetSelection()
        editBuffer.deleteOffsetRange(startOffset: sel.start, endOffset: sel.end)
    }

    /// Replaces the active selection (or inserts at cursor if none) in one atomic undoable edit.
    public func replaceSelectedText(_ text: String) {
        assertAlive()
        if let sel = textBufferView.getSelection(), sel.start < sel.end {
            textBufferView.resetSelection()
            editBuffer.replaceOffsetRange(startOffset: sel.start, endOffset: sel.end, with: text)
        } else {
            editBuffer.insertText(text)
        }
    }

    // MARK: - Cursor & Visual Navigation

    // parity: core/src/editor-view.ts#EditorView.getCursor [status=implemented hash=6beb017deb1a]
    public func getCursor() -> (row: Int, col: Int) {
        assertAlive()
        let pos = editBuffer.getCursorPosition()
        return (pos.row, pos.col)
    }

    // parity: core/src/editor-view.ts#EditorView.getText [status=implemented hash=e9d8fde5d0b3]
    public func getText() -> String {
        assertAlive()
        return editBuffer.getText()
    }

    private func absoluteVisualPosition(for logical: LogicalCursor) -> (visualRow: Int, visualCol: Int) {
        let vlines = textBufferView.virtualLines()
        guard !vlines.isEmpty else { return (0, 0) }
        var matchedRow = 0
        for (idx, vline) in vlines.enumerated() where vline.sourceLine == logical.row {
            matchedRow = idx
            let start = vline.sourceColStart
            let end = start + vline.widthCols
            if logical.col >= start && logical.col <= end {
                // If exact end and there is another wrap segment of the same line starting at end,
                // keep on current segment unless logical.col > end.
                let isLastWrapForLine = (idx + 1 >= vlines.count) || (vlines[idx + 1].sourceLine != logical.row)
                if logical.col < end || isLastWrapForLine {
                    return (idx, logical.col - start)
                }
            }
        }
        let fallback = vlines[matchedRow]
        return (matchedRow, max(0, logical.col - fallback.sourceColStart))
    }

    private func toVisualCursor(_ logical: LogicalCursor) -> VisualCursor {
        let abs = absoluteVisualPosition(for: logical)
        let vp = textBufferView.viewport ?? ViewportBounds(x: 0, y: 0, width: 0, height: 0)
        return VisualCursor(
            visualRow: abs.visualRow - vp.y,
            visualCol: abs.visualCol - vp.x,
            logicalRow: logical.row,
            logicalCol: logical.col,
            offset: logical.offset
        )
    }

    // parity: core/src/editor-view.ts#EditorView.getVisualCursor [status=implemented hash=85c014f8ed23]
    public func getVisualCursor() -> VisualCursor {
        assertAlive()
        return toVisualCursor(editBuffer.getCursorPosition())
    }

    // parity: core/src/editor-view.ts#EditorView.moveUpVisual [status=implemented hash=f0ad3f549d3b]
    public func moveUpVisual() {
        assertAlive()
        let vlines = textBufferView.virtualLines()
        let beforeOffset = editBuffer.getCursorPosition().offset
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        guard abs.visualRow > 0 else { return }
        let desiredCol = _desiredVisualCol ?? abs.visualCol
        let targetVLine = vlines[abs.visualRow - 1]
        let clampedCol = min(desiredCol, targetVLine.widthCols)
        let snapped = _TextEngineMetrics.snapColDown(
            clampedCol,
            in: targetVLine.text,
            tabWidth: editBuffer.getTabWidth(),
            widthMethod: editBuffer.textBuffer.widthMethod
        )
        editBuffer.setCursor(line: targetVLine.sourceLine, col: targetVLine.sourceColStart + snapped)
        if atomicRulesActive() {
            editBuffer.leaveAtomic(from: beforeOffset, down: false)
        }
        _desiredVisualCol = desiredCol
    }

    // parity: core/src/editor-view.ts#EditorView.moveDownVisual [status=implemented hash=3018c7604d63]
    public func moveDownVisual() {
        assertAlive()
        let vlines = textBufferView.virtualLines()
        let beforeOffset = editBuffer.getCursorPosition().offset
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        guard abs.visualRow + 1 < vlines.count else { return }
        let desiredCol = _desiredVisualCol ?? abs.visualCol
        let targetVLine = vlines[abs.visualRow + 1]
        let clampedCol = min(desiredCol, targetVLine.widthCols)
        let snapped = _TextEngineMetrics.snapColDown(
            clampedCol,
            in: targetVLine.text,
            tabWidth: editBuffer.getTabWidth(),
            widthMethod: editBuffer.textBuffer.widthMethod
        )
        editBuffer.setCursor(line: targetVLine.sourceLine, col: targetVLine.sourceColStart + snapped)
        if atomicRulesActive() {
            editBuffer.leaveAtomic(from: beforeOffset, down: true)
        }
        _desiredVisualCol = desiredCol
    }

    // parity: core/src/editor-view.ts#EditorView.setCursorByOffset [status=implemented hash=d767c178c7ef]
    public func setCursorByOffset(_ offset: Int) {
        assertAlive()
        editBuffer.setCursorByOffset(offset)
    }

    // parity: core/src/editor-view.ts#EditorView.getNextWordBoundary [status=implemented hash=1d826f3fedc8]
    public func getNextWordBoundary() -> VisualCursor {
        assertAlive()
        return toVisualCursor(editBuffer.getNextWordBoundary())
    }

    // parity: core/src/editor-view.ts#EditorView.getPrevWordBoundary [status=implemented hash=8420b299dda6]
    public func getPrevWordBoundary() -> VisualCursor {
        assertAlive()
        return toVisualCursor(editBuffer.getPrevWordBoundary())
    }

    // parity: core/src/editor-view.ts#EditorView.getEOL [status=implemented hash=5c72bec2f2b3]
    public func getEOL() -> VisualCursor {
        assertAlive()
        return toVisualCursor(editBuffer.getEOL())
    }

    // parity: core/src/editor-view.ts#EditorView.getVisualSOL [status=implemented hash=32e95175e4ea]
    public func getVisualSOL() -> VisualCursor {
        assertAlive()
        let vlines = textBufferView.virtualLines()
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        guard abs.visualRow < vlines.count else { return getVisualCursor() }
        let vline = vlines[abs.visualRow]
        let logical = LogicalCursor(
            row: vline.sourceLine,
            col: vline.sourceColStart,
            offset: vline.documentCellOffset
        )
        return toVisualCursor(logical)
    }

    // parity: core/src/editor-view.ts#EditorView.getVisualEOL [status=implemented hash=d02720f7b3be]
    public func getVisualEOL() -> VisualCursor {
        assertAlive()
        let vlines = textBufferView.virtualLines()
        let abs = absoluteVisualPosition(for: editBuffer.getCursorPosition())
        guard abs.visualRow < vlines.count else { return getVisualCursor() }
        let vline = vlines[abs.visualRow]
        let logical = LogicalCursor(
            row: vline.sourceLine,
            col: vline.sourceColStart + vline.widthCols,
            offset: vline.documentCellOffset + vline.widthCols
        )
        return toVisualCursor(logical)
    }

    // parity: core/src/editor-view.ts#EditorView.gotoVisualLineEnd [status=implemented hash=c82a62335412]
    public func gotoVisualLineEnd() {
        assertAlive()
        let eol = getVisualEOL()
        editBuffer.setCursor(line: eol.logicalRow, col: eol.logicalCol)
    }

    // parity: core/src/editor-view.ts#EditorView.getLineInfo [status=implemented hash=f643d5104220]
    public func getLineInfo() -> LineInfo {
        assertAlive()
        return textBufferView.lineInfo
    }

    // parity: core/src/editor-view.ts#EditorView.getLogicalLineInfo [status=implemented hash=44f82128ed8d]
    public func getLogicalLineInfo() -> LineInfo {
        assertAlive()
        return textBufferView.logicalLineInfo
    }

    internal func _keepCursorOutside(direction: KeepOutsideDirection) {
        if atomicRulesActive() {
            editBuffer._keepOutside(direction: direction)
        }
    }

    // parity: core/src/editor-view.ts#EditorView.extmarks [status=implemented hash=8f42bb0b052f]
    public var extmarks: ExtmarksController {
        assertAlive()
        if let existing = _extmarksController {
            return existing
        }
        let controller = createExtmarksController(editBuffer, self)
        _extmarksController = controller
        return controller
    }

    // parity: core/src/editor-view.ts#EditorView.setPlaceholderStyledText [status=implemented hash=d655389c4327]
    public func setPlaceholderStyledText(_ chunks: [TextChunk]) {
        assertAlive()
        _placeholderChunks = chunks
    }

    // parity: core/src/editor-view.ts#EditorView.setTabIndicator [status=implemented hash=6316cdc1ca07]
    public func setTabIndicator(_ indicator: String) {
        assertAlive()
        textBufferView.setTabIndicator(indicator)
    }

    public func setTabIndicator(codePoint: UInt32) {
        assertAlive()
        textBufferView.setTabIndicator(codePoint: codePoint)
    }

    // parity: core/src/editor-view.ts#EditorView.setTabIndicatorColor [status=implemented hash=27892a9ad80f]
    public func setTabIndicatorColor(_ color: RGBA) {
        assertAlive()
        textBufferView.setTabIndicatorColor(color)
    }

    // parity: core/src/editor-view.ts#EditorView.measureForDimensions [status=implemented hash=65f9e4ce4e17]
    public func measureForDimensions(width: Int, height: Int) -> MeasureResult? {
        assertAlive()
        return textBufferView.measureForDimensions(width: width, height: height)
    }

    // parity: core/src/editor-view.ts#EditorView.destroy [status=implemented hash=c8c068a40ea6]
    public func destroy() {
        guard !_destroyed else { return }
        _destroyed = true
        editBuffer.removeCursorListener(_cursorListenerId)
        _extmarksController?.destroy()
        _extmarksController = nil
        textBufferView.destroy()
    }
}

// MARK: - Single-Line InputModel (input-max-length.conformance.json Engine)

/// Strips ASCII LF (`\n`) and CR (`\r`) characters without altering other Unicode scalars.
public func stripInputNewlines(_ text: String) -> String {
    guard text.utf8.contains(0x0A) || text.utf8.contains(0x0D) else {
        return text
    }
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars where scalar.value != 0x0A && scalar.value != 0x0D {
        out.unicodeScalars.append(scalar)
    }
    return out
}

/// Cuts `text` to at most `maxLength` UTF-16 code units, never splitting a character,
/// surrogate pair, or combining grapheme cluster: any character that does not fit whole is left out.
public func fitUTF16(_ text: String, maxLength: Int) -> String {
    guard maxLength > 0, !text.isEmpty else { return "" }
    if text.utf16.count <= maxLength {
        return text
    }
    var result = ""
    result.reserveCapacity(min(text.utf8.count, maxLength * 3))
    var units = 0
    for ch in text {
        let chUnits = ch.utf16.count
        if units + chUnits > maxLength {
            break
        }
        result.append(ch)
        units += chUnits
    }
    return result
}

/// Pure-Swift single-line input model implementing OpenTUI's `InputRenderable` editing semantics
/// and `input-max-length.conformance.json` rules:
/// - Newlines (`\n`, `\r`) are stripped before applying `maxLength`.
/// - `maxLength` and `minLength` count UTF-16 code units.
/// - Cuts never split a character, surrogate pair, or combining sequence.
/// - Inserting text over an active selection frees the selected text's UTF-16 length.
public final class InputModel {
    public let editBuffer: EditBuffer
    public let editorView: EditorView

    private var _maxLength: Int
    private var _minLength: Int
    private var _placeholder: String
    private var _lastCommittedValue: String
    private var _selectionAnchorOffset: Int? = nil

    public static let defaultMaxLength: Int = 1000

    public init(
        value: String = "",
        maxLength: Int = InputModel.defaultMaxLength,
        minLength: Int = 0,
        placeholder: String = "",
        viewportWidth: Int = 80,
        widthMethod: TextWidthMethod = .unicode
    ) {
        let clampedMax = max(0, maxLength)
        precondition(minLength <= clampedMax, "InputModel: minLength (\(minLength)) cannot be greater than maxLength (\(clampedMax))")
        self._maxLength = clampedMax
        self._minLength = max(0, minLength)
        self._placeholder = placeholder
        self.editBuffer = EditBuffer(widthMethod: widthMethod)
        self.editorView = EditorView(editBuffer: editBuffer, viewportWidth: viewportWidth, viewportHeight: 1)
        self.editorView.setWrapMode(.none)

        let initialValue = fitUTF16(stripInputNewlines(value), maxLength: clampedMax)
        self.editBuffer.setText(initialValue)
        if !initialValue.isEmpty {
            self.editBuffer.setCursorByOffset(self.editBuffer.getEOL().offset)
        }
        self._lastCommittedValue = initialValue
    }

    /// Single-line text value (indexed in UTF-16 code units for `maxLength` / `minLength`).
    public var value: String {
        get { editBuffer.getText() }
        set {
            let newValue = fitUTF16(stripInputNewlines(newValue), maxLength: _maxLength)
            if newValue != editBuffer.getText() {
                clearSelection()
                editBuffer.setText(newValue)
                editBuffer.setCursorByOffset(editBuffer.getEOL().offset)
            }
        }
    }

    /// Maximum allowed length in UTF-16 code units. Setting a smaller value truncates without splitting characters.
    public var maxLength: Int {
        get { _maxLength }
        set {
            let clamped = max(0, newValue)
            let current = editBuffer.getText()
            if current.utf16.count > clamped {
                clearSelection()
                editBuffer.setText(fitUTF16(current, maxLength: clamped))
            }
            _maxLength = clamped
        }
    }

    /// Minimum required length in UTF-16 code units for `submit()`.
    public var minLength: Int {
        get { _minLength }
        set {
            precondition(newValue <= _maxLength, "InputModel: minLength (\(newValue)) cannot be greater than maxLength (\(_maxLength))")
            _minLength = max(0, newValue)
        }
    }

    public var placeholder: String {
        get { _placeholder }
        set { _placeholder = newValue }
    }

    public var cursorOffset: Int {
        get { editBuffer.getCursorPosition().offset }
        set {
            clearSelection()
            editBuffer.setCursorByOffset(newValue)
        }
    }

    public var hasSelection: Bool {
        editorView.hasSelection()
    }

    public func getSelectedText() -> String {
        editorView.getSelectedText()
    }

    public func clearSelection() {
        _selectionAnchorOffset = nil
        editorView.resetSelection()
    }

    /// Single-line input ignores newlines.
    public func newLine() -> Bool {
        false
    }

    /// Inserts `text`, stripping newlines first and enforcing UTF-16 `maxLength`
    /// (freeing any active selection's UTF-16 length).
    public func insertText(_ text: String) {
        let sanitized = stripInputNewlines(text)
        guard !sanitized.isEmpty else { return }

        let currentUTF16 = editBuffer.getText().utf16.count
        let selectedUTF16 = editorView.getSelectedText().utf16.count
        let room = _maxLength - currentUTF16 + selectedUTF16
        let toInsert = fitUTF16(sanitized, maxLength: room)
        guard !toInsert.isEmpty else { return }

        _selectionAnchorOffset = nil
        editorView.replaceSelectedText(toInsert)
    }

    /// Moves cursor left by one grapheme cluster; when `selecting` is `true`, mirrors Shift+Left.
    public func moveCursorLeft(selecting: Bool = false) {
        if selecting {
            if _selectionAnchorOffset == nil {
                _selectionAnchorOffset = editBuffer.getCursorPosition().offset
            }
            editBuffer.moveCursorLeft()
            updateSelectionFromAnchor()
        } else {
            if let sel = editorView.getSelection() {
                clearSelection()
                editBuffer.setCursorByOffset(sel.start)
            } else {
                editBuffer.moveCursorLeft()
            }
        }
    }

    /// Moves cursor right by one grapheme cluster; when `selecting` is `true`, mirrors Shift+Right.
    public func moveCursorRight(selecting: Bool = false) {
        if selecting {
            if _selectionAnchorOffset == nil {
                _selectionAnchorOffset = editBuffer.getCursorPosition().offset
            }
            editBuffer.moveCursorRight()
            updateSelectionFromAnchor()
        } else {
            if let sel = editorView.getSelection() {
                clearSelection()
                editBuffer.setCursorByOffset(sel.end)
            } else {
                editBuffer.moveCursorRight()
            }
        }
    }

    public func selectAll() {
        let eol = editBuffer.getEOL().offset
        guard eol > 0 else {
            clearSelection()
            return
        }
        _selectionAnchorOffset = 0
        editBuffer.setCursorByOffset(eol)
        editorView.setSelection(start: 0, end: eol)
    }

    private func updateSelectionFromAnchor() {
        guard let anchor = _selectionAnchorOffset else { return }
        let focus = editBuffer.getCursorPosition().offset
        if anchor == focus {
            editorView.resetSelection()
        } else {
            editorView.setSelection(start: anchor, end: focus)
        }
    }

    @discardableResult
    public func deleteCharBackward() -> Bool {
        if editorView.hasSelection() {
            _selectionAnchorOffset = nil
            editorView.deleteSelectedText()
            return true
        }
        let before = editBuffer.getText()
        editBuffer.deleteCharBackward()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteChar() -> Bool {
        if editorView.hasSelection() {
            _selectionAnchorOffset = nil
            editorView.deleteSelectedText()
            return true
        }
        let before = editBuffer.getText()
        editBuffer.deleteChar()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteLine() -> Bool {
        clearSelection()
        let before = editBuffer.getText()
        editBuffer.deleteLine()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteWordBackward() -> Bool {
        clearSelection()
        let before = editBuffer.getText()
        editBuffer.deleteWordBackward()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteWordForward() -> Bool {
        clearSelection()
        let before = editBuffer.getText()
        editBuffer.deleteWordForward()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteToLineStart() -> Bool {
        clearSelection()
        let before = editBuffer.getText()
        editBuffer.deleteToLineStart()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func deleteToLineEnd() -> Bool {
        clearSelection()
        let before = editBuffer.getText()
        editBuffer.deleteToLineEnd()
        return editBuffer.getText() != before
    }

    @discardableResult
    public func undo() -> Bool {
        clearSelection()
        return editBuffer.undo() != nil
    }

    @discardableResult
    public func redo() -> Bool {
        clearSelection()
        return editBuffer.redo() != nil
    }

    /// Validates `minLength` (in UTF-16 code units) and commits the current value.
    @discardableResult
    public func submit() -> Bool {
        let current = editBuffer.getText()
        guard current.utf16.count >= _minLength else {
            return false
        }
        _lastCommittedValue = current
        return true
    }

    public var lastCommittedValue: String {
        _lastCommittedValue
    }

    public func destroy() {
        editorView.destroy()
        editBuffer.destroy()
    }
}
