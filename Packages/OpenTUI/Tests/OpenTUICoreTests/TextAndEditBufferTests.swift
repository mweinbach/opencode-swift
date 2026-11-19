import Testing
@testable import OpenTUICore

// MARK: - Rope Tests

@Suite("Rope")
struct RopeTests {
    @Test("empty rope metrics and invariants")
    func emptyRope() {
        let rope = Rope()
        #expect(rope.isEmpty)
        #expect(rope.utf8Count == 0)
        #expect(rope.utf16Count == 0)
        #expect(rope.newlineCount == 0)
        #expect(rope.lineCount == 1)
        #expect(rope.text == "")
        #expect(rope.line(at: 0) == "")
        #expect(rope.line(at: 1) == nil)
        #expect(rope.lineRange(at: 0) == 0..<0)
    }

    @Test("insert, delete, and slice across ASCII, CJK, emoji, and combining clusters")
    func unicodeOperations() {
        var rope = Rope("Hello 世界")
        #expect(rope.utf16Count == "Hello 世界".utf16.count)
        #expect(rope.utf8Count == "Hello 世界".utf8.count)

        rope.insert(" 😀", atUTF16: rope.utf16Count)
        #expect(rope.text == "Hello 世界 😀")
        #expect(rope.utf16Count == 11) // 6 + 2 + 1 + 2

        // Slice emoji via UTF-16 range [9, 11)
        #expect(rope.slice(utf16Range: 9..<11) == "😀")
        #expect(rope.slice(utf16Range: 6..<8) == "世界")

        // Delete "世界" via UTF-16 range [6, 8)
        rope.delete(utf16Range: 6..<8)
        #expect(rope.text == "Hello  😀")

        // Combining sequence e + combining acute accent
        rope.insert("e\u{0301}", atUTF16: 6)
        #expect(rope.text == "Hello e\u{0301} 😀")
        #expect(rope.slice(utf16Range: 6..<8) == "e\u{0301}")
    }

    @Test("lineCount, lineRange, line lookup, and offset-to-line mapping")
    func lineTracking() {
        let text = "first\nsecond line\n日本語\n😀end"
        let rope = Rope(text)
        #expect(rope.lineCount == 4)
        #expect(rope.newlineCount == 3)
        #expect(rope.line(at: 0) == "first")
        #expect(rope.line(at: 1) == "second line")
        #expect(rope.line(at: 2) == "日本語")
        #expect(rope.line(at: 3) == "😀end")
        #expect(rope.line(at: 4) == nil)

        #expect(rope.lineIndex(forUTF8Offset: 0) == 0)
        #expect(rope.lineIndex(forUTF8Offset: 5) == 0)
        #expect(rope.lineIndex(forUTF8Offset: 6) == 1)
        #expect(rope.lineIndex(forUTF16Offset: rope.utf16Count) == 3)

        let line2UTF16 = rope.lineUTF16Range(at: 2)
        #expect(line2UTF16 != nil)
        if let line2UTF16 {
            #expect(rope.slice(utf16Range: line2UTF16) == "日本語")
        }
    }

    @Test("persistent COW snapshots remain immutable across subsequent mutations")
    func cowSnapshots() {
        var rope = Rope("alpha beta")
        let snap1 = rope.snapshot()
        rope.insert(" gamma", atUTF8: rope.utf8Count)
        let snap2 = rope.snapshot()
        rope.delete(utf8Range: 0..<6)

        #expect(snap1.text == "alpha beta")
        #expect(snap2.text == "alpha beta gamma")
        #expect(rope.text == "beta gamma")
        #expect(snap1 != snap2)
        #expect(snap1 == Rope("alpha beta"))
    }

    @Test("balanced tree depth stays O(log n) under large sequential appends and random inserts")
    func balancedDepthUnderLoad() {
        var rope = Rope()
        var expected = ""
        for i in 0..<250 {
            let chunk = "line-\(i): The quick brown fox jumps over the lazy dog.\n"
            rope.insert(chunk, atUTF8: rope.utf8Count)
            expected.append(chunk)
        }
        #expect(rope.text == expected)
        #expect(rope.lineCount == 251)
        #expect(rope.leafCount > 10)
        // AVL height for <= 100 leaves must stay well under 16 (O(log n))
        #expect(rope.depth <= 12)

        // Mid-document splice & verify slice
        let mid = rope.utf8Count / 2
        rope.insert("<<<MARKER>>>", atUTF8: mid)
        let slice = rope.slice(utf8Range: mid..<(mid + 12))
        #expect(slice == "<<<MARKER>>>")
    }
}

// MARK: - TextBuffer & TextBufferView Tests

@Suite("TextBuffer")
struct TextBufferTests {
    @Test("plain text, append, styled text, defaults, clear, and reset")
    func basicTextBufferOperations() {
        let tb = TextBuffer.create(widthMethod: .unicode)
        tb.setText("Hello\r\nWorld")
        #expect(tb.getPlainText() == "Hello\nWorld")
        #expect(tb.getLineCount() == 2)
        #expect(tb.length == 10) // display cells excluding newline
        #expect(tb.byteSize == 11) // UTF-8 bytes including \n

        tb.append("\n日本語")
        #expect(tb.getLineCount() == 3)
        #expect(tb.getLine(2) == "日本語")
        #expect(tb.length == 16) // 5 + 5 + 6 cells

        #expect(tb.getTextRange(startOffset: 0, endOffset: 5) == "Hello")
        #expect(tb.getTextRange(startOffset: 6, endOffset: 11) == "World")
        #expect(tb.getTextRange(startOffset: 12, endOffset: 16) == "日本")

        let styled = StyledText(chunks: [red("ERR"), TextChunk(text: ": "), bold("fail")])
        tb.setStyledText(styled)
        #expect(tb.getPlainText() == "ERR: fail")
        #expect(tb.styledChunks.count == 3)

        tb.setDefaultFg(RGBA.fromInts(255, 0, 0))
        tb.setDefaultBg(RGBA.fromInts(0, 0, 0))
        tb.setDefaultAttributes(TextAttributes.bold)
        #expect(tb.defaultFg != nil)
        #expect(tb.defaultAttributes == TextAttributes.bold)

        tb.addHighlight(lineIdx: 0, highlight: Highlight(start: 0, end: 3, styleId: 7, priority: 1, hlRef: 42))
        #expect(tb.getHighlightCount() == 1)

        // clear() preserves highlights and defaults
        tb.clear()
        #expect(tb.getPlainText() == "")
        #expect(tb.getHighlightCount() == 1)
        #expect(tb.defaultFg != nil)

        // reset() clears highlights and defaults too
        tb.reset()
        #expect(tb.getHighlightCount() == 0)
        #expect(tb.defaultFg == nil)
        #expect(tb.defaultAttributes == nil)
    }

    @Test("highlights by line, by char range, and removal by ref")
    func highlightManagement() {
        let tb = TextBuffer.create()
        tb.setText("abcde\nfghij\nklmno")
        tb.addHighlightByCharRange(Highlight(start: 3, end: 12, styleId: 10, priority: 2, hlRef: 99))
        #expect(tb.getLineHighlights(0).count == 1)
        #expect(tb.getLineHighlights(0)[0].start == 3)
        #expect(tb.getLineHighlights(0)[0].end == 5)
        #expect(tb.getLineHighlights(1).count == 1)
        #expect(tb.getLineHighlights(1)[0].start == 0)
        #expect(tb.getLineHighlights(1)[0].end == 5)
        #expect(tb.getLineHighlights(2).count == 1)
        #expect(tb.getLineHighlights(2)[0].start == 0)
        #expect(tb.getLineHighlights(2)[0].end == 2)
        #expect(tb.getHighlightCount() == 3)

        tb.removeHighlightsByRef(99)
        #expect(tb.getHighlightCount() == 0)
    }

    @Test("TextBufferView char, word, and none wrapping + measureForDimensions")
    func viewWrapping() {
        let tb = TextBuffer.create()
        tb.setText("hello world foo bar")
        let view = TextBufferView.create(tb)

        // Unwrapped
        view.setWrapMode(.none)
        #expect(view.getVirtualLineCount() == 1)

        // Word wrap at width 11 -> "hello " (6) + "world " (6) would exceed 11, so wraps cleanly on word boundaries
        view.setWrapMode(.word)
        view.setWrapWidth(11)
        let wordLines = view.virtualLines().map(\.text)
        #expect(wordLines == ["hello ", "world foo ", "bar"])
        #expect(view.getVirtualLineCount() == 3)
        #expect(view.logicalLineInfo.lineSources == [0, 0, 0])
        #expect(view.logicalLineInfo.lineWraps == [0, 1, 2])

        // Char wrap at width 6
        view.setWrapMode(.char)
        view.setWrapWidth(6)
        let charLines = view.virtualLines().map(\.text)
        #expect(charLines == ["hello ", "world ", "foo ba", "r"])

        let measured = view.measureForDimensions(width: 10, height: 10)
        #expect(measured?.lineCount == 2)
        #expect(measured?.widthColsMax == 10)

        // First line offset narrows first line's first wrap row
        view.setWrapMode(.char)
        view.setWrapWidth(10)
        view.setFirstLineOffset(4)
        #expect(view.virtualLines().first?.widthCols == 6)
    }

    @Test("TextBufferView viewport windowing, truncation, and selection modes")
    func viewViewportAndSelection() {
        let tb = TextBuffer.create()
        tb.setText("alpha beta\ngamma delta\nepsilon zeta")
        let view = TextBufferView.create(tb)
        view.setViewport(x: 0, y: 1, width: 8, height: 2)
        view.setTruncate(true)

        let visible = view.visibleVirtualLines()
        #expect(visible.count == 2)
        #expect(visible[0].sourceLine == 1)
        #expect(visible[0].text == "gamma d…")
        #expect(visible[1].sourceLine == 2)
        #expect(view.getLineSources(startLine: 1, lineCount: 2) == [1, 2])

        // Global selection
        view.setViewport(x: 0, y: 0, width: 20, height: 5)
        view.setTruncate(false)
        view.setSelection(start: 6, end: 10)
        #expect(view.hasSelection())
        #expect(view.getSelectedText() == "beta")
        view.updateSelection(end: 16)
        #expect(view.getSelectedText() == "beta\ngamma")
        view.resetSelection()
        #expect(!view.hasSelection())

        // Local word selection (double-click on "delta" at row 1, col 7)
        let selectedWord = view.setLocalSelection(anchorX: 7, anchorY: 1, focusX: 7, focusY: 1, behavior: .word)
        #expect(selectedWord)
        #expect(view.getSelectedText() == "delta")

        // Local line selection (triple-click on row 2)
        let selectedLine = view.setLocalSelection(anchorX: 2, anchorY: 2, focusX: 2, focusY: 2, behavior: .line)
        #expect(selectedLine)
        #expect(view.getSelectedText() == "epsilon zeta")

        // Boundary vs cell occupancy on single-cell local selection
        view.setSelectionOccupancy(.cell)
        let cellHit = view.setLocalSelection(anchorX: 0, anchorY: 0, focusX: 0, focusY: 0, behavior: .cell)
        #expect(cellHit)
        #expect(view.getSelectedText() == "a")

        view.setSelectionOccupancy(.boundary)
        let boundaryEmpty = view.setLocalSelection(anchorX: 0, anchorY: 0, focusX: 0, focusY: 0, behavior: .cell)
        #expect(!boundaryEmpty)
        let boundarySpan = view.setLocalSelection(anchorX: 0, anchorY: 0, focusX: 5, focusY: 0, behavior: .cell)
        #expect(boundarySpan)
        #expect(view.getSelectedText() == "alpha")
    }
}

// MARK: - EditBuffer & EditorView Tests

@Suite("EditBuffer")
struct EditBufferTests {
    @Test("editing operations, grapheme motion, word motion, and undo/redo")
    func editingAndHistory() {
        let eb = EditBuffer.create()
        eb.setText("hello world")
        #expect(!eb.canUndo())

        eb.setCursorByOffset(eb.getEOL().offset)
        eb.insertText(" 😀")
        #expect(eb.getText() == "hello world 😀")
        #expect(eb.getCursorPosition().offset == 14) // 11 + 1 + 2 cells
        #expect(eb.canUndo())

        // Move left across 2-cell emoji in one grapheme step
        eb.moveCursorLeft()
        #expect(eb.getCursorPosition().offset == 12)
        eb.moveCursorRight()
        #expect(eb.getCursorPosition().offset == 14)

        // Backspace deletes entire emoji grapheme
        eb.deleteCharBackward()
        #expect(eb.getText() == "hello world ")
        #expect(eb.getCursorPosition().offset == 12)

        // Undo restores emoji
        #expect(eb.undo() != nil)
        #expect(eb.getText() == "hello world 😀")
        #expect(eb.canRedo())

        // Redo deletes emoji again
        #expect(eb.redo() != nil)
        #expect(eb.getText() == "hello world ")

        // Word deletion backward
        eb.setText("foo bar baz")
        eb.setCursorByOffset(eb.getEOL().offset)
        eb.deleteWordBackward()
        #expect(eb.getText() == "foo bar ")

        // Delete line
        eb.setText("line1\nline2\nline3")
        eb.gotoLine(1)
        eb.deleteLine()
        #expect(eb.getText() == "line1\nline3")
        #expect(eb.getLineCount() == 2)

        // replaceText preserves history while setText clears history
        eb.replaceText("replaced")
        #expect(eb.getText() == "replaced")
        #expect(eb.canUndo())
        eb.undo()
        #expect(eb.getText() == "line1\nline3")

        eb.setText("clean slate")
        #expect(!eb.canUndo())
        #expect(!eb.canRedo())
    }

    @Test("vertical cursor motion preserves desiredCol across shorter lines and line/word deletions")
    func desiredColAndRangeDeletions() {
        let eb = EditBuffer.create()
        eb.setText("123456\n12\n123456")
        eb.setCursor(line: 0, col: 5)
        eb.moveCursorDown()
        #expect(eb.getCursorPosition().row == 1)
        #expect(eb.getCursorPosition().col == 2)
        eb.moveCursorDown()
        #expect(eb.getCursorPosition().row == 2)
        #expect(eb.getCursorPosition().col == 5)

        eb.deleteToLineStart()
        #expect(eb.getText() == "123456\n12\n6")
        eb.setCursor(line: 0, col: 2)
        eb.deleteToLineEnd()
        #expect(eb.getText() == "12\n12\n6")
    }

    @Test("UTF-16 stringIndexToCellOffset and cellOffsetToStringIndex conversions + measureEditText")
    func offsetConversions() {
        let eb = EditBuffer.create()
        eb.setText("a日😀\te\u{0301}\nb")
        // Cells: a(1) 日(2) 😀(2) \t(2) é(1) \n(1) b(1) = 10 cells
        #expect(eb.measureText(eb.getText()) == 10)
        #expect(measureEditText(eb.getText(), widthMethod: .unicode, tabWidth: 2) == 10)
        #expect(measureEditText("\t", widthMethod: .unicode, tabWidth: 4) == 4)

        // UTF-16 indices: a(0..1), 日(1..2), 😀(2..4), \t(4..5), é(5..7), \n(7..8), b(8..9)
        #expect(eb.stringIndexToCellOffset(0) == 0)
        #expect(eb.stringIndexToCellOffset(1) == 1)
        #expect(eb.stringIndexToCellOffset(2) == 3)
        #expect(eb.stringIndexToCellOffset(3) == 3) // mid-surrogate rounds down
        #expect(eb.stringIndexToCellOffset(4) == 5)
        #expect(eb.stringIndexToCellOffset(5) == 7)
        #expect(eb.stringIndexToCellOffset(7) == 8)
        #expect(eb.stringIndexToCellOffset(8) == 9)

        #expect(eb.cellOffsetToStringIndex(0) == 0)
        #expect(eb.cellOffsetToStringIndex(1) == 1)
        #expect(eb.cellOffsetToStringIndex(2) == 1) // mid-wide CJK rounds down
        #expect(eb.cellOffsetToStringIndex(3) == 2)
        #expect(eb.cellOffsetToStringIndex(4) == 2) // mid-emoji rounds down
        #expect(eb.cellOffsetToStringIndex(5) == 4)
        #expect(eb.cellOffsetToStringIndex(7) == 5)
        #expect(eb.cellOffsetToStringIndex(8) == 7)
        #expect(eb.cellOffsetToStringIndex(9) == 8)
    }

    @Test("EditorView visual navigation, viewport scrolling, and selection deletion")
    func editorViewNavigationAndScrolling() {
        let eb = EditBuffer.create()
        eb.setText("0123456789abcdefghij\nline two\nline three\nline four\nline five")
        let view = EditorView.create(editBuffer: eb, viewportWidth: 10, viewportHeight: 3)
        view.setWrapMode(.char)

        // Line 0 wraps into 2 visual rows: "0123456789" and "abcdefghij"
        #expect(view.getTotalVirtualLineCount() == 6)

        eb.setCursor(line: 0, col: 3)
        #expect(view.getVisualCursor().visualRow == 0)
        #expect(view.getVisualCursor().visualCol == 3)

        // Move down one visual row -> lands on wrapped continuation ("abcdefghij", col 3 -> logical col 13)
        view.moveDownVisual()
        #expect(view.getCursor().row == 0)
        #expect(view.getCursor().col == 13)
        #expect(view.getVisualSOL().logicalCol == 10)
        #expect(view.getVisualEOL().logicalCol == 20)

        // Move down further scrolls viewport
        view.moveDownVisual()
        view.moveDownVisual()
        view.moveDownVisual()
        #expect(view.getViewport().offsetY > 0)

        // Selection & deleteSelectedText
        view.setSelection(start: 0, end: 10)
        #expect(view.getSelectedText() == "0123456789")
        view.deleteSelectedText()
        #expect(view.getText().hasPrefix("abcdefghij\n"))
        #expect(!view.hasSelection())

        // Placeholder chunks
        view.setPlaceholderStyledText([dim("Type here...")])
        #expect(view.placeholderChunks.count == 1)
    }
}

// MARK: - Extmarks Tests

@Suite("Extmarks")
struct ExtmarksTests {
    @Test("create, query, type registration, metadata, and delete")
    func extmarkBasics() {
        let eb = EditBuffer.create()
        eb.setText("Hello World")
        let view = EditorView.create(editBuffer: eb, viewportWidth: 40, viewportHeight: 5)
        let extmarks = view.extmarks

        let linkType = extmarks.registerType("link")
        let mentionType = extmarks.registerType("mention")
        #expect(linkType == 1)
        #expect(mentionType == 2)
        #expect(extmarks.registerType("link") == 1)
        #expect(extmarks.getTypeId("mention") == 2)
        #expect(extmarks.getTypeName(1) == "link")

        let id1 = extmarks.create(ExtmarkOptions(
            start: 0,
            end: 5,
            virtual: false,
            styleId: 3,
            priority: 10,
            data: "https://example.com",
            typeId: linkType,
            metadata: "meta-1"
        ))
        let id2 = extmarks.create(ExtmarkOptions(
            start: 6,
            end: 11,
            virtual: true,
            typeId: mentionType
        ))

        #expect(id1 == 1)
        #expect(id2 == 2)
        #expect(extmarks.get(id1)?.data as? String == "https://example.com")
        #expect(extmarks.getMetadataFor(id1) as? String == "meta-1")
        #expect(extmarks.get(id1)?.styleId == 3)
        #expect(extmarks.getVirtual().map(\.id) == [id2])
        #expect(extmarks.getAllForTypeId(linkType).map(\.id) == [id1])
        #expect(extmarks.getAtOffset(2).map(\.id) == [id1])
        #expect(extmarks.getAtOffset(5).isEmpty) // half-open [0, 5)
        #expect(extmarks.getAtOffset(6).map(\.id) == [id2])

        // Invalid ranges return 0
        #expect(extmarks.create(ExtmarkOptions(start: 5, end: 2)) == 0)
        #expect(extmarks.create(ExtmarkOptions(start: -1, end: 2)) == 0)

        #expect(extmarks.delete(id1))
        #expect(!extmarks.delete(id1))
        #expect(extmarks.get(id1) == nil)
        #expect(extmarks.getMetadataFor(id1) == nil)

        // IDs are never reused
        let id3 = extmarks.create(ExtmarkOptions(start: 0, end: 2))
        #expect(id3 == 3)
    }

    @Test("range shifting on edits, virtual drop on inner edit, undo/redo, and history reset")
    func extmarkShiftingAndHistory() {
        let eb = EditBuffer.create()
        eb.setText("Hello [chip] World")
        let view = EditorView.create(editBuffer: eb, viewportWidth: 40, viewportHeight: 5)
        let extmarks = view.extmarks

        let virtualId = extmarks.create(ExtmarkOptions(start: 6, end: 12, virtual: true, data: "chip-payload"))
        let normalId = extmarks.create(ExtmarkOptions(start: 13, end: 18, virtual: false, data: "word-payload"))

        // Insert before both marks -> both shift right by 3
        eb.setCursorByOffset(0)
        eb.insertText(">>>")
        #expect(extmarks.get(virtualId)?.start == 9)
        #expect(extmarks.get(virtualId)?.end == 15)
        #expect(extmarks.get(normalId)?.start == 16)
        #expect(extmarks.get(normalId)?.end == 21)

        // Insert inside normal mark -> normal mark grows
        eb.setCursorByOffset(18)
        eb.insertText("XX")
        #expect(extmarks.get(normalId)?.start == 16)
        #expect(extmarks.get(normalId)?.end == 23)

        // Atomic cursor rules: Backspace at virtual mark's end deletes whole virtual mark as one edit
        eb.setCursorByOffset(15)
        eb.deleteCharBackward()
        #expect(extmarks.get(virtualId) == nil)
        #expect(eb.getText() == ">>>Hello  WoXXrld")

        // Undo restores the virtual mark AND its payload!
        eb.undo()
        #expect(extmarks.get(virtualId)?.start == 9)
        #expect(extmarks.get(virtualId)?.end == 15)
        #expect(extmarks.get(virtualId)?.data as? String == "chip-payload")

        // Atomic cursor motion skips across virtual mark [9, 15)
        eb.setCursorByOffset(9)
        eb.moveCursorRight()
        #expect(eb.getCursorPosition().offset == 15)
        eb.moveCursorLeft()
        #expect(eb.getCursorPosition().offset == 8)

        // setText resets history and drops marks + payloads
        eb.setText("brand new")
        #expect(extmarks.getAll().isEmpty)
        #expect(extmarks.get(virtualId) == nil)
        #expect(extmarks.get(normalId) == nil)
    }

    @Test("multi-controller shared state, virtual drop on inner insert/overlap delete, and destroy lifecycle")
    func extmarkMultiControllerAndEdgeCases() {
        let eb = EditBuffer.create()
        eb.setText("abcdef ghijkl")
        let view1 = EditorView.create(editBuffer: eb, viewportWidth: 40, viewportHeight: 5)
        let view2 = EditorView.create(editBuffer: eb, viewportWidth: 40, viewportHeight: 5)
        let c1 = createExtmarksController(eb, view1)
        let c2 = createExtmarksController(eb, view2)

        let typeId = c1.registerType("tag")
        #expect(c2.getTypeId("tag") == typeId)

        let vId = c1.create(ExtmarkOptions(start: 0, end: 6, virtual: true, data: "v-data", typeId: typeId, metadata: "v-meta"))
        let nId = c1.create(ExtmarkOptions(start: 7, end: 13, virtual: false, data: "n-data", typeId: typeId))

        // Shared across controllers
        #expect(c2.get(vId)?.data as? String == "v-data")
        #expect(c2.getMetadataFor(vId) as? String == "v-meta")

        // Partial delete overlapping normal mark shrinks it; overlapping virtual mark drops it
        eb.deleteRange(startLine: 0, startCol: 4, endLine: 0, endCol: 9)
        #expect(c1.get(vId) == nil)
        #expect(c1.get(nId)?.start == 4)
        #expect(c1.get(nId)?.end == 8)

        // Undo restores both
        eb.undo()
        #expect(c1.get(vId)?.start == 0)
        #expect(c1.get(vId)?.end == 6)

        // Destroying c2 keeps marks, payloads, and type names alive for c1
        c2.destroy()
        #expect(c1.get(vId)?.data as? String == "v-data")
        #expect(c1.getTypeName(typeId) == "tag")
        #expect(c2.getAll().isEmpty)

        // Destroying c1 disables atomic cursor rules so cursor can step inside [0, 6)
        c1.destroy()
        eb.setCursorByOffset(2)
        #expect(eb.getCursorPosition().offset == 2)
    }
}

// MARK: - InputMaxLength Conformance Suite (ALL 14 Upstream Rows × 3 Orders)

@Suite("InputMaxLength")
struct InputMaxLengthConformanceTests {
    @Test("passes all 14 rows of input-max-length.conformance.json in every property order")
    func conformanceSuite() throws {
        let rows = try TextEngineConformanceLoader.loadInputMaxLength()
        #expect(rows.count == 14)

        for row in rows {
            // Order 1: constructor (value and maxLength together)
            do {
                let input = InputModel(value: row.value, maxLength: row.maxLength)
                for _ in 0..<row.select {
                    input.moveCursorLeft(selecting: true)
                }
                input.insertText(row.insert)
                #expect(
                    input.value == row.expected,
                    "Row \(row.index) (\(row.name)) [constructor]: expected \(row.expected.debugDescription), got \(input.value.debugDescription)"
                )
            }

            // Order 2: maxLength set before value
            do {
                let input = InputModel(value: "", maxLength: row.maxLength)
                input.value = row.value
                for _ in 0..<row.select {
                    input.moveCursorLeft(selecting: true)
                }
                input.insertText(row.insert)
                #expect(
                    input.value == row.expected,
                    "Row \(row.index) (\(row.name)) [maxLength-before-value]: expected \(row.expected.debugDescription), got \(input.value.debugDescription)"
                )
            }

            // Order 3: value set before maxLength
            do {
                let input = InputModel(value: row.value)
                input.maxLength = row.maxLength
                for _ in 0..<row.select {
                    input.moveCursorLeft(selecting: true)
                }
                input.insertText(row.insert)
                #expect(
                    input.value == row.expected,
                    "Row \(row.index) (\(row.name)) [value-before-maxLength]: expected \(row.expected.debugDescription), got \(input.value.debugDescription)"
                )
            }
        }
    }

    @Test("InputModel never splits combining sequences, enforces minLength, and ignores newLine")
    func inputModelAdditionalEdgeCases() {
        #expect(fitUTF16("ae\u{0301}", maxLength: 2) == "a")
        #expect(fitUTF16("ae\u{0301}", maxLength: 3) == "ae\u{0301}")
        #expect(fitUTF16("😀", maxLength: 1) == "")
        #expect(fitUTF16("😀", maxLength: 2) == "😀")

        let input = InputModel(value: "hi", maxLength: 10, minLength: 3)
        #expect(!input.newLine())
        #expect(!input.submit())
        input.insertText("!\r\nworld")
        #expect(input.value == "hi!world")
        #expect(input.submit())
        #expect(input.lastCommittedValue == "hi!world")
    }
}
