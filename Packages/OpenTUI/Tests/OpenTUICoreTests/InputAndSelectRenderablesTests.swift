import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// MARK: - EditBufferRenderable Tests

@Suite("EditBufferRenderable Tests")
struct EditBufferRenderableTests {
    @Test("Branding, traits, and LineInfoProvider")
    func brandingTraitsAndLineInfo() {
        let tr = createTestRenderer(width: 40, height: 10)
        defer { tr.destroy() }

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(width: .point(20), height: .point(4), wrapMode: .word)
        )
        tr.root.add(editor)
        editor.setText("hello world\nsecond line\nthird")
        tr.renderOnce()

        #expect(isEditBufferRenderable(editor))
        #expect(!isEditBufferRenderable(tr.root))
        #expect(!isEditBufferRenderable(nil))

        var traitChanges: [(EditorTraits, EditorTraits)] = []
        _ = editor.onTraitsChanged { next, prev in
            traitChanges.append((next, prev))
        }
        editor.traits = EditorTraits(capture: [.escape, .submit], suspend: true, status: "COMMAND")
        editor.traits = EditorTraits(capture: [.escape, .submit], suspend: true, status: "COMMAND")
        #expect(traitChanges.count == 1)
        #expect(traitChanges[0].0.status == "COMMAND")
        #expect(traitChanges[0].1 == EditorTraits())

        #expect(editor.lineCount == 3)
        #expect(editor.virtualLineCount == 3)
        #expect(editor.scrollY == 0)
        #expect(editor.lineInfo.lineSources == [0, 1, 2])
        #expect(editor.getLineSources(startLine: 1, lineCount: 2) == [1, 2])
    }

    @Test("Intrinsic FlexNode measure function sizes auto-dimensioned editor")
    func intrinsicMeasureFunction() {
        let tr = createTestRenderer(width: 30, height: 15)
        defer { tr.destroy() }

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(wrapMode: .word)
        )
        editor.setText("line one\nlonger line two\nthree")
        tr.root.add(editor)
        tr.renderOnce()

        #expect(editor.height == 3)
        #expect(editor.width >= 15)

        editor.setText("a\nb\nc\nd\ne")
        tr.renderOnce()
        #expect(editor.height == 5)
    }

    @Test("Cursor reporting to RenderContext on focus, movement, showCursor, and blur")
    func cursorReporting() {
        let tr = createTestRenderer(width: 40, height: 10)
        defer { tr.destroy() }

        let red = RGBA.fromHex("#ff0000")
        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(
                width: .point(20),
                height: .point(3),
                position: .absolute,
                top: .point(2),
                left: .point(4),
                cursorColor: .rgba(red),
                cursorStyle: CursorStyleOptions(style: .line, blinking: false)
            )
        )
        editor.setText("abcdef")
        tr.root.add(editor)
        editor.focus()
        editor.setCursor(row: 0, col: 3)
        tr.renderOnce()

        let state = tr.renderer.getCursorState()
        #expect(state.visible == true)
        #expect(state.x == 4 + 3 + 1)
        #expect(state.y == 2 + 0 + 1)
        #expect(state.style == .line)
        #expect(state.blinking == false)
        #expect(state.color == red)

        editor.showCursor = false
        tr.renderOnce()
        #expect(tr.renderer.getCursorState().visible == false)

        editor.showCursor = true
        tr.renderOnce()
        #expect(tr.renderer.getCursorState().visible == true)

        editor.blur()
        #expect(tr.renderer.getCursorState().visible == false)
    }

    @Test("Renders visible lines, syntax highlights, tab indicators, and control notation")
    func renderingHighlightsTabsAndControls() {
        let tr = createTestRenderer(width: 30, height: 4)
        defer { tr.destroy() }

        let style = SyntaxStyle.create()
        let kwColor = RGBA.fromHex("#00ff00")
        let kwId = style.registerStyle("keyword", StyleDefinitionInput(fg: .rgba(kwColor), bold: true))

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(
                width: .point(30),
                height: .point(4),
                wrapMode: TextWrapMode.none,
                syntaxStyle: style,
                tabIndicator: "→",
                tabIndicatorColor: "#888888"
            )
        )
        editor.setText("let x\n\tindented\nA\u{07}B\u{1B}C\u{0C}D\u{85}E")
        editor.addHighlight(lineIdx: 0, highlight: Highlight(start: 0, end: 3, styleId: kwId))
        tr.root.add(editor)
        tr.renderOnce()

        let frame = tr.captureCharFrame()
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("let x"))
        #expect(lines[1].hasPrefix("→ indented"))
        #expect(lines[2].hasPrefix("A^GB^[C^LD<85>E"))

        let cellL = tr.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        #expect(cellL?.foreground == kwColor)
        #expect(((cellL?.attributes ?? 0) & TextAttributes.bold) != 0)
    }

    @Test("Mouse drag selection, double-click word, triple-click line, and occupancy modes")
    func mouseSelectionAndOccupancy() {
        let tr = createTestRenderer(width: 30, height: 5)
        defer { tr.destroy() }

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(
                width: .point(30),
                height: .point(4),
                selectionBg: "#224466",
                selectionFg: "#ffffff"
            )
        )
        editor.setText("hello world foo\nsecond line")
        tr.root.add(editor)
        tr.renderOnce()

        // Drag across "world" (cols 6..10 inclusive in .cell occupancy)
        tr.mockMouse.drag(startX: 6, startY: 0, endX: 10, endY: 0)
        tr.renderOnce()
        #expect(editor.hasSelection())
        #expect(editor.getSelectedText() == "world")

        // Advance clock past double-click window before testing double-click
        tr.advanceClock(by: 600)
        tr.mockMouse.doubleClick(x: 7, y: 0)
        tr.renderOnce()
        #expect(editor.getSelectedText() == "world")

        // Triple click within 500ms selects the full line
        tr.advanceClock(by: 20)
        tr.mockMouse.click(x: 7, y: 0)
        tr.renderOnce()
        #expect(editor.getSelectedText() == "hello world foo")

        // Boundary vs cell occupancy on keyboard shift-selection
        tr.advanceClock(by: 600)
        editor.setText("ab你cd")
        editor.cursorOffset = 0
        editor.selectionOccupancy = .cell
        editor.moveCursorRight(select: true)
        editor.moveCursorRight(select: true)
        #expect(editor.getSelectedText() == "ab你")

        editor.selectionOccupancy = .boundary
        #expect(editor.getSelectedText() == "ab")
    }

    @Test("Mouse scroll wheel scrolls vertically and horizontally")
    func mouseScrollWheel() {
        let tr = createTestRenderer(width: 20, height: 4)
        defer { tr.destroy() }

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(width: .point(10), height: .point(3), wrapMode: TextWrapMode.none)
        )
        editor.setText((0..<12).map { "line-\($0)-longtext" }.joined(separator: "\n"))
        tr.root.add(editor)
        tr.renderOnce()

        #expect(editor.scrollY == 0)
        tr.mockMouse.scroll(x: 2, y: 1, direction: .down)
        tr.renderOnce()
        #expect(editor.scrollY > 0)

        tr.mockMouse.scroll(x: 2, y: 1, direction: .up)
        tr.renderOnce()
        #expect(editor.scrollY == 0)

        tr.mockMouse.scroll(x: 2, y: 1, direction: .right)
        tr.renderOnce()
        #expect(editor.editorView.getViewport().offsetX > 0)
    }

    @Test("Extmarks integrate with EditBufferRenderable and render styled marks")
    func extmarksIntegration() {
        let tr = createTestRenderer(width: 30, height: 3)
        defer { tr.destroy() }

        let style = SyntaxStyle.create()
        let badgeColor = RGBA.fromHex("#ffaa00")
        let badgeId = style.registerStyle("badge", StyleDefinitionInput(fg: .rgba(badgeColor)))

        let editor = EditBufferRenderable(
            ctx: tr.renderer,
            options: EditBufferOptions(width: .point(30), height: .point(3), syntaxStyle: style)
        )
        editor.setText("hi @alice ok")
        let markId = editor.extmarks.create(ExtmarkOptions(start: 3, end: 9, virtual: true, styleId: Int(badgeId)))
        #expect(markId > 0)

        tr.root.add(editor)
        tr.renderOnce()

        let cellAt = tr.renderer.currentRenderBuffer.cell(atX: 3, y: 0)
        #expect(cellAt?.foreground == badgeColor)

        // Atomic virtual extmark skip on moveCursorRight
        editor.cursorOffset = 2
        editor.moveCursorRight()
        #expect(editor.cursorOffset == 9)
    }
}

// MARK: - TextareaRenderable Tests

@Suite("TextareaRenderable Tests")
struct TextareaRenderableTests {
    @Test("Multi-line typing, newline, deletion actions, undo/redo, and callbacks")
    func multiLineEditingAndCallbacks() {
        let tr = createTestRenderer(width: 40, height: 10, kittyKeyboard: true)
        defer { tr.destroy() }

        var contentChanges = 0
        var cursorEvents: [CursorChangeEvent] = []
        var submitCount = 0

        let textarea = TextareaRenderable(
            ctx: tr.renderer,
            options: TextareaOptions(
                width: .point(30),
                height: .point(6),
                placeholder: "Type here...",
                onSubmit: { _ in submitCount += 1 },
                onCursorChange: { cursorEvents.append($0) },
                onContentChange: { _ in contentChanges += 1 }
            )
        )
        tr.root.add(textarea)
        tr.renderOnce()

        // Placeholder renders when empty
        #expect(tr.captureCharFrame().contains("Type here..."))

        textarea.focus()
        tr.mockInput.typeText("hello world")
        tr.mockInput.pressEnter()
        tr.mockInput.typeText("second line")
        tr.renderOnce()

        #expect(textarea.plainText == "hello world\nsecond line")
        #expect(contentChanges > 0)
        #expect(!cursorEvents.isEmpty)
        #expect(tr.captureCharFrame().contains("hello world"))
        #expect(tr.captureCharFrame().contains("second line"))

        // Ctrl+W deletes previous word ("line")
        tr.mockInput.pressKey("w", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.plainText == "hello world\nsecond ")

        // Ctrl+U deletes to start of line
        tr.mockInput.pressKey("u", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.plainText == "hello world\n")

        // Undo restores "second "
        tr.mockInput.pressKey("-", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.plainText == "hello world\nsecond ")

        // Redo deletes it again
        tr.mockInput.pressKey(".", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.plainText == "hello world\n")

        // Alt+Return submits
        tr.mockInput.pressEnter(modifiers: MockKeyModifiers(meta: true))
        #expect(submitCount == 1)
    }

    @Test("Cursor motion, line/buffer home/end, shift selection, selectAll, and deleteLine")
    func navigationAndSelectionActions() {
        let tr = createTestRenderer(width: 40, height: 10, kittyKeyboard: true)
        defer { tr.destroy() }

        let textarea = TextareaRenderable(
            ctx: tr.renderer,
            options: TextareaOptions(
                width: .point(30),
                height: .point(5),
                initialValue: "alpha beta\ngamma delta"
            )
        )
        tr.root.add(textarea)
        tr.renderOnce()
        textarea.focus()

        // Ctrl+E -> line end of line 0
        tr.mockInput.pressKey("e", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.logicalCursor.row == 0)
        #expect(textarea.logicalCursor.col == 10)

        // Ctrl+A -> line start of line 0
        tr.mockInput.pressKey("a", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.logicalCursor.col == 0)

        // End -> buffer end
        tr.mockInput.pressKey(KeyCodes.end)
        #expect(textarea.logicalCursor.row == 1)
        #expect(textarea.logicalCursor.col == 11)

        // Home -> buffer home
        tr.mockInput.pressKey(KeyCodes.home)
        #expect(textarea.logicalCursor.row == 0)
        #expect(textarea.logicalCursor.col == 0)

        // Ctrl+K -> delete to line end
        tr.mockInput.pressKey("k", modifiers: MockKeyModifiers(ctrl: true))
        #expect(textarea.plainText == "\ngamma delta")

        // Ctrl+Shift+D -> delete line
        tr.mockInput.pressKey("d", modifiers: MockKeyModifiers(shift: true, ctrl: true))
        #expect(textarea.plainText == "gamma delta")

        // Super+A -> select all, then type to replace
        tr.mockInput.pressKey("a", modifiers: MockKeyModifiers(super: true))
        #expect(textarea.getSelectedText() == "gamma delta")
        tr.mockInput.typeText("fresh")
        #expect(textarea.plainText == "fresh")
    }

    @Test("Bracketed paste strips ANSI sequences and inserts multi-line content")
    func bracketedPaste() {
        let tr = createTestRenderer(width: 40, height: 10)
        defer { tr.destroy() }

        let textarea = TextareaRenderable(
            ctx: tr.renderer,
            options: TextareaOptions(width: .point(30), height: .point(5))
        )
        tr.root.add(textarea)
        tr.renderOnce()
        textarea.focus()

        tr.mockInput.pasteBracketedText("\u{1B}[31mhello\u{1B}[0m\nworld")
        #expect(textarea.plainText == "hello\nworld")
    }

    @Test("Custom keyBindings, keyAliasMap, and suspended traits")
    func customKeyBindingsAndSuspend() {
        let tr = createTestRenderer(width: 30, height: 5)
        defer { tr.destroy() }

        var submitted = 0
        let textarea = TextareaRenderable(
            ctx: tr.renderer,
            options: TextareaOptions(
                width: .point(25),
                height: .point(4),
                initialValue: "hello",
                keyBindings: [KeyBinding(name: "enter", action: .submit)],
                onSubmit: { _ in submitted += 1 }
            )
        )
        tr.root.add(textarea)
        tr.renderOnce()
        textarea.focus()

        // Default alias maps "enter" -> "return"
        tr.mockInput.pressEnter()
        #expect(submitted == 1)

        // Suspend traits ignores bound actions while still accepting plain text
        textarea.traits = EditorTraits(suspend: true)
        tr.mockInput.pressEnter()
        #expect(submitted == 1)
    }

    @Test("Focused/unfocused colors and placeholder color updates")
    func focusedColorsAndPlaceholder() {
        let tr = createTestRenderer(width: 20, height: 3)
        defer { tr.destroy() }

        let unfocusedBg = RGBA.fromHex("#111111")
        let focusedBg = RGBA.fromHex("#222222")
        let placeholderRed = RGBA.fromHex("#ff0000")

        let textarea = TextareaRenderable(
            ctx: tr.renderer,
            options: TextareaOptions(
                width: .point(20),
                height: .point(2),
                backgroundColor: .rgba(unfocusedBg),
                focusedBackgroundColor: .rgba(focusedBg),
                placeholder: "kept"
            )
        )
        tr.root.add(textarea)
        tr.renderOnce()

        #expect(tr.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.background == unfocusedBg)

        // Linked placeholder is rejected without poisoning subsequent placeholderColor updates
        let linked = StyledText(chunks: [TextChunk(text: "bad", link: TextChunkLink(url: "https://example.com"))])
        textarea.placeholder = .styled(linked)
        textarea.placeholderColor = placeholderRed
        textarea.focus()
        tr.renderOnce()

        #expect(tr.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.background == focusedBg)
        #expect(tr.renderer.currentRenderBuffer.cell(atX: 0, y: 0)?.foreground == placeholderRed)
        #expect(tr.captureCharFrame().contains("kept"))
    }
}

// MARK: - InputRenderable Tests

@Suite("InputRenderable Tests")
struct InputRenderableTests {
    @Test("All 14 rows of upstream input-max-length.conformance.json pass across constructor, value, and maxLength paths")
    func upstreamMaxLengthConformance() throws {
        let rows = try TextEngineConformanceLoader.loadInputMaxLength()
        #expect(rows.count == 14)

        let tr = createTestRenderer(width: 40, height: 10)
        defer { tr.destroy() }

        for row in rows {
            for path in ["constructor", "value", "maxLength"] {
                let input = InputRenderable(
                    ctx: tr.renderer,
                    options: InputOptions(
                        width: .point(20),
                        value: path == "value" ? "" : row.value,
                        maxLength: path == "maxLength" ? nil : row.maxLength
                    )
                )
                tr.root.add(input)
                if path == "value" {
                    input.value = row.value
                }
                if path == "maxLength" {
                    input.maxLength = row.maxLength
                }
                input.focus()
                for _ in 0..<row.select {
                    tr.mockInput.pressArrow(.left, modifiers: MockKeyModifiers(shift: true))
                }
                input.insertText(row.insert)
                #expect(
                    input.value == row.expected,
                    "Row #\(row.index) (\(row.name)) via \(path): expected \(row.expected), got \(input.value)"
                )
                input.destroy()
            }
        }
    }

    @Test("Single-line constraints: height 1, newlines stripped, Enter submits, minLength enforced")
    func singleLineConstraintsAndSubmit() {
        let tr = createTestRenderer(width: 30, height: 5)
        defer { tr.destroy() }

        var inputs: [String] = []
        var changes: [String] = []
        var submits: [String] = []

        let input = InputRenderable(
            ctx: tr.renderer,
            options: InputOptions(
                width: .point(20),
                value: "a\nb\rc",
                minLength: 3,
                maxLength: 10,
                placeholder: "enter...",
                onInput: { inputs.append($0) },
                onChange: { changes.append($0) },
                onSubmit: { submits.append($0) }
            )
        )
        tr.root.add(input)
        tr.renderOnce()

        #expect(input.height == 1)
        #expect(input.wrapMode == .none)
        #expect(input.value == "abc")
        #expect(input.newLine() == false)
        #expect(tr.captureCharFrame().contains("abc"))

        input.focus()
        // Delete 1 char -> "ab" (length 2 < minLength 3)
        tr.mockInput.pressBackspace()
        #expect(input.value == "ab")
        #expect(inputs.last == "ab")

        // Enter should NOT submit when below minLength
        tr.mockInput.pressEnter()
        #expect(submits.isEmpty)

        // Paste text with newlines
        tr.mockInput.pasteBracketedText("c\nd\re")
        #expect(input.value == "abcde")

        // Enter now submits and emits change + enter
        tr.mockInput.pressEnter()
        #expect(changes == ["abcde"])
        #expect(submits == ["abcde"])

        // Blur without further edits does not re-emit change
        input.blur()
        #expect(changes == ["abcde"])

        // Focus, edit, blur emits change
        input.focus()
        input.deleteCharacter(.backward)
        #expect(input.value == "abcd")
        input.blur()
        #expect(changes == ["abcde", "abcd"])
    }

    @Test("Placeholder renders when input value is empty")
    func placeholderRendering() {
        let tr = createTestRenderer(width: 30, height: 3)
        defer { tr.destroy() }

        let input = InputRenderable(
            ctx: tr.renderer,
            options: InputOptions(
                width: .point(20),
                placeholder: "Search...",
                placeholderColor: "#777777"
            )
        )
        tr.root.add(input)
        tr.renderOnce()

        #expect(tr.captureCharFrame().contains("Search..."))
        input.value = "query"
        tr.renderOnce()
        #expect(tr.captureCharFrame().contains("query"))
        #expect(!tr.captureCharFrame().contains("Search..."))
    }
}

// MARK: - SelectRenderable Tests

@Suite("SelectRenderable Tests")
struct SelectRenderableTests {
    private static let sampleOptions: [SelectOption] = [
        SelectOption(name: "Option 1", description: "First option", value: "v1"),
        SelectOption(name: "Option 2", description: "Second option", value: "v2"),
        SelectOption(name: "Option 3", description: "Third option", value: "v3"),
        SelectOption(name: "Option 4", description: "Fourth option", value: "v4"),
        SelectOption(name: "Option 5", description: "Fifth option", value: "v5"),
    ]

    @Test("Initialization, off-screen initial selectedIndex scroll, and indicator rendering")
    func initAndScrollIndicator() {
        let tr = createTestRenderer(width: 30, height: 10)
        defer { tr.destroy() }

        let many = (0..<20).map { SelectOption(name: "Item \($0)", description: "") }
        let select = SelectRenderable(
            ctx: tr.renderer,
            options: SelectOptions(
                width: .point(20),
                height: .point(5),
                options: many,
                selectedIndex: 12,
                showScrollIndicator: true,
                showDescription: false
            )
        )
        tr.root.add(select)
        tr.renderOnce()

        #expect(select.focusable == true)
        #expect(select.getSelectedIndex() == 12)
        #expect(select.getSelectedOption()?.name == "Item 12")

        let lines = tr.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.contains("▶ Item 12") })
        let indicatorRow = lines.firstIndex { $0.contains("█") }
        #expect(indicatorRow == 3)
    }

    @Test("Keyboard navigation: up/down, j/k, fast scroll, wrapSelection, and selectCurrent")
    func keyboardNavigationAndWrapping() {
        let tr = createTestRenderer(width: 30, height: 10)
        defer { tr.destroy() }

        var changes: [Int] = []
        var selections: [String] = []

        let select = SelectRenderable(
            ctx: tr.renderer,
            options: SelectOptions(
                width: .point(25),
                height: .point(8),
                options: Self.sampleOptions,
                wrapSelection: true,
                fastScrollStep: 2,
                onChange: { idx, _ in changes.append(idx) },
                onSelect: { _, opt in selections.append(opt.name) }
            )
        )
        tr.root.add(select)
        tr.renderOnce()
        select.focus()

        // Wrap up from 0 -> 4
        tr.mockInput.pressArrow(.up)
        #expect(select.selectedIndex == 4)

        // Wrap down from 4 -> 0
        tr.mockInput.pressKey("j")
        #expect(select.selectedIndex == 0)

        // Fast scroll down by 2 -> index 2
        tr.mockInput.pressArrow(.down, modifiers: MockKeyModifiers(shift: true))
        #expect(select.selectedIndex == 2)

        // Enter selects current
        tr.mockInput.pressEnter()
        #expect(selections == ["Option 3"])
        #expect(changes == [4, 0, 2])

        // Disable wrapping: moving up past 0 clamps at 0
        select.wrapSelection = false
        select.moveUp(10)
        #expect(select.selectedIndex == 0)
        select.moveDown(10)
        #expect(select.selectedIndex == 4)
    }

    @Test("Mouse click selects item, second click confirms, and wheel scrolls")
    func mouseClickAndWheel() {
        let tr = createTestRenderer(width: 30, height: 10)
        defer { tr.destroy() }

        var changedTo: [Int] = []
        var confirmed: [String] = []

        let select = SelectRenderable(
            ctx: tr.renderer,
            options: SelectOptions(
                width: .point(25),
                height: .point(6),
                options: Self.sampleOptions,
                showDescription: false,
                onChange: { idx, _ in changedTo.append(idx) },
                onSelect: { _, opt in confirmed.append(opt.name) }
            )
        )
        tr.root.add(select)
        tr.renderOnce()

        // Click row 2 -> selects Option 3 (index 2)
        tr.mockMouse.click(x: 5, y: 2)
        tr.renderOnce()
        #expect(select.selectedIndex == 2)
        #expect(changedTo == [2])
        #expect(confirmed.isEmpty)

        // Click row 2 again -> confirms Option 3
        tr.advanceClock(by: 600)
        tr.mockMouse.click(x: 5, y: 2)
        #expect(confirmed == ["Option 3"])

        // Scroll wheel down -> index 3
        tr.mockMouse.scroll(x: 5, y: 2, direction: .down)
        #expect(select.selectedIndex == 3)

        // Scroll wheel up -> index 2
        tr.mockMouse.scroll(x: 5, y: 2, direction: .up)
        #expect(select.selectedIndex == 2)
    }

    @Test("Hiding selection indicator reclaims gutter and descriptions toggle cleanly")
    func selectionIndicatorAndDescriptionToggle() {
        let tr = createTestRenderer(width: 30, height: 6)
        defer { tr.destroy() }

        let select = SelectRenderable(
            ctx: tr.renderer,
            options: SelectOptions(
                width: .point(25),
                height: .point(5),
                options: Self.sampleOptions,
                showDescription: false,
                showSelectionIndicator: false
            )
        )
        tr.root.add(select)
        tr.renderOnce()

        let firstLine = tr.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false)[0]
        #expect(firstLine.hasPrefix(" Option 1"))

        select.showDescription = true
        tr.renderOnce()
        #expect(tr.captureCharFrame().contains("First option"))
    }
}

// MARK: - TabSelectRenderable Tests

@Suite("TabSelectRenderable Tests")
struct TabSelectRenderableTests {
    private static let tabs: [TabSelectOption] = [
        TabSelectOption(name: "Files", description: "Browse workspace files", value: "files"),
        TabSelectOption(name: "Search", description: "Search across project", value: "search"),
        TabSelectOption(name: "Git", description: "Source control status", value: "git"),
        TabSelectOption(name: "Debug", description: "Breakpoints and stack", value: "debug"),
        TabSelectOption(name: "Output", description: "Build and task logs", value: "output"),
    ]

    @Test("Dynamic height, underline, description, and horizontal scroll arrows")
    func dynamicHeightAndHorizontalWindowing() {
        let tr = createTestRenderer(width: 30, height: 6)
        defer { tr.destroy() }

        let tabSelect = TabSelectRenderable(
            ctx: tr.renderer,
            options: TabSelectOptions(
                width: .point(24),
                options: Self.tabs,
                tabWidth: 10,
                showScrollArrows: true,
                showDescription: true,
                showUnderline: true
            )
        )
        tr.root.add(tabSelect)
        tr.renderOnce()

        // Height = 1 (tabs) + 1 (underline) + 1 (description) = 3
        #expect(tabSelect.height == 3)

        let frame1 = tr.captureCharFrame()
        let lines1 = frame1.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines1[0].contains("Files"))
        #expect(lines1[0].contains("›"))
        #expect(!lines1[0].contains("‹"))
        #expect(lines1[1].contains("▬"))
        #expect(lines1[2].contains("Browse workspace files"))

        // Move right to scroll horizontally so left arrow appears
        tabSelect.setSelectedIndex(3)
        tr.renderOnce()
        let lines2 = tr.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines2[0].contains("‹"))
        #expect(lines2[0].contains("Debug"))
        #expect(lines2[2].contains("Breakpoints and stack"))

        // Toggle underline and description updates height dynamically
        tabSelect.showUnderline = false
        tr.renderOnce()
        #expect(tabSelect.height == 2)

        tabSelect.showDescription = false
        tr.renderOnce()
        #expect(tabSelect.height == 1)
    }

    @Test("Keyboard navigation: left/right, [/], wrapSelection, and Enter selection")
    func keyboardNavigation() {
        let tr = createTestRenderer(width: 50, height: 5)
        defer { tr.destroy() }

        var changes: [Int] = []
        var selected: [String] = []

        let tabSelect = TabSelectRenderable(
            ctx: tr.renderer,
            options: TabSelectOptions(
                width: .point(50),
                options: Self.tabs,
                tabWidth: 10,
                wrapSelection: true,
                onChange: { idx, _ in changes.append(idx) },
                onSelect: { _, opt in selected.append(opt.name) }
            )
        )
        tr.root.add(tabSelect)
        tr.renderOnce()
        tabSelect.focus()

        tr.mockInput.pressArrow(.right)
        #expect(tabSelect.getSelectedIndex() == 1)

        tr.mockInput.pressKey("]")
        #expect(tabSelect.getSelectedIndex() == 2)

        tr.mockInput.pressKey("[")
        #expect(tabSelect.getSelectedIndex() == 1)

        // Wrap left past 0 -> 4
        tr.mockInput.pressArrow(.left)
        tr.mockInput.pressArrow(.left)
        #expect(tabSelect.getSelectedIndex() == 4)

        tr.mockInput.pressEnter()
        #expect(selected == ["Output"])
        #expect(changes == [1, 2, 1, 0, 4])
    }

    @Test("Mouse click on tabs, scroll arrows, and mouse wheel navigation")
    func mouseInteraction() {
        let tr = createTestRenderer(width: 40, height: 5)
        defer { tr.destroy() }

        var selected: [String] = []
        let tabSelect = TabSelectRenderable(
            ctx: tr.renderer,
            options: TabSelectOptions(
                width: .point(30),
                options: Self.tabs,
                tabWidth: 10,
                showScrollArrows: true,
                onSelect: { _, opt in selected.append(opt.name) }
            )
        )
        tr.root.add(tabSelect)
        tr.renderOnce()

        // Click tab 1 (x = 12, y = 0)
        tr.mockMouse.click(x: 12, y: 0)
        tr.renderOnce()
        #expect(tabSelect.selectedIndex == 1)

        // Click tab 1 again confirms it
        tr.advanceClock(by: 600)
        tr.mockMouse.click(x: 12, y: 0)
        #expect(selected == ["Search"])

        // Mouse wheel down/right moves right, up/left moves left
        tr.mockMouse.scroll(x: 5, y: 0, direction: .right)
        #expect(tabSelect.selectedIndex == 2)

        tr.mockMouse.scroll(x: 5, y: 0, direction: .left)
        #expect(tabSelect.selectedIndex == 1)
    }
}
