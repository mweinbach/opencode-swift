import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import Testing

// MARK: - Shared Test SyntaxStyle Helper

private func makeRichSyntaxStyle() -> SyntaxStyle {
    SyntaxStyle.fromStyles([
        "default": StyleDefinitionInput(fg: "#E6EDF3"),
        "keyword": StyleDefinitionInput(fg: "#FF7B72", bold: true),
        "string": StyleDefinitionInput(fg: "#A5D6FF"),
        "number": StyleDefinitionInput(fg: "#79C0FF"),
        "comment": StyleDefinitionInput(fg: "#8B949E", italic: true),
        "function": StyleDefinitionInput(fg: "#D2A8FF"),
        "type": StyleDefinitionInput(fg: "#FFA657"),
        "markup.heading": StyleDefinitionInput(fg: "#58A6FF", bold: true),
        "markup.heading.1": StyleDefinitionInput(fg: "#79C0FF", bold: true),
        "markup.strong": StyleDefinitionInput(fg: "#FFFFFF", bold: true),
        "markup.italic": StyleDefinitionInput(fg: "#D2A8FF", italic: true),
        "markup.strikethrough": StyleDefinitionInput(fg: "#8B949E", strikethrough: true),
        "markup.raw": StyleDefinitionInput(fg: "#7EE787"),
        "markup.link.label": StyleDefinitionInput(fg: "#58A6FF", underline: true),
        "markup.link.url": StyleDefinitionInput(fg: "#79C0FF"),
        "markup.list": StyleDefinitionInput(fg: "#FFA657"),
        "markup.quote": StyleDefinitionInput(fg: "#8B949E", italic: true),
        "conceal": StyleDefinitionInput(fg: "#6E7681"),
    ])
}

// MARK: - CodeRenderable Tests

@Suite("CodeRenderable")
struct CodeRenderableTests {
    @Test("highlights Swift code with BuiltInSyntaxHighlighter and exposes line highlights")
    func highlightsSwiftCode() {
        let test = createTestRenderer(width: 40, height: 6)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let code = CodeRenderable(
            ctx: test.renderer,
            options: CodeOptions(
                id: "swift-code",
                content: "let count = 42\n// done",
                filetype: "swift",
                syntaxStyle: style,
                width: .point(40)
            )
        )
        test.root.add(code)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("let count = 42"))
        #expect(frame.contains("// done"))

        let spans = test.captureSpans()
        let line0Spans = spans.lines[0].spans
        let keywordSpan = line0Spans.first { $0.text.contains("let") }
        #expect(keywordSpan != nil)
        #expect(keywordSpan?.fg == parseColor("#FF7B72"))
        #expect(((keywordSpan?.attributes ?? 0) & TextAttributes.bold) != 0)

        let numberSpan = line0Spans.first { $0.text.contains("42") }
        #expect(numberSpan?.fg == parseColor("#79C0FF"))

        let line1Spans = spans.lines[1].spans
        let commentSpan = line1Spans.first { $0.text.contains("// done") }
        #expect(commentSpan?.fg == parseColor("#8B949E"))
        #expect(((commentSpan?.attributes ?? 0) & TextAttributes.italic) != 0)

        // TextBuffer line highlights are synchronized for getLineHighlights(_:)
        let line0Highlights = code.getLineHighlights(0)
        #expect(!line0Highlights.isEmpty)
        #expect(line0Highlights.contains { $0.start == 0 && $0.end == 3 })
        let line1Highlights = code.getLineHighlights(1)
        #expect(!line1Highlights.isEmpty)
    }

    @Test("renders plain text fallback when filetype is nil")
    func rendersPlainTextWithoutFiletype() {
        let test = createTestRenderer(width: 30, height: 4)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let code = CodeRenderable(
            ctx: test.renderer,
            options: CodeOptions(
                content: "plain text line",
                filetype: nil,
                syntaxStyle: style
            )
        )
        test.root.add(code)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("plain text line"))
        #expect(code.getLineHighlights(0).isEmpty)
    }

    @Test("applies conceal and remaps concealed line sources in lineInfo")
    func concealAndConcealLineSourceMapping() {
        let test = createTestRenderer(width: 30, height: 6)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        // Line 0: "```swift\n" (concealed line 0..8 with concealLines)
        // Line 1: "let x = 1\n" (offset 9..18)
        // Line 2: "```" (concealed line 19..22 with concealLines)
        let source = "```swift\nlet x = 1\n```"
        let highlights: [SimpleHighlight] = [
            SimpleHighlight(start: 0, end: 8, group: "conceal", meta: HighlightMeta(conceal: "", concealLines: "")),
            SimpleHighlight(start: 9, end: 12, group: "keyword"),
            SimpleHighlight(start: 19, end: 22, group: "conceal", meta: HighlightMeta(conceal: "", concealLines: "")),
        ]
        let mock = StaticSyntaxHighlighter(highlights: highlights)

        let code = CodeRenderable(
            ctx: test.renderer,
            options: CodeOptions(
                content: source,
                filetype: "markdown",
                syntaxStyle: style,
                highlighter: mock,
                conceal: true
            )
        )
        test.root.add(code)
        test.renderOnce()

        let concealedFrame = test.captureCharFrame()
        #expect(concealedFrame.contains("let x = 1"))
        #expect(!concealedFrame.contains("```swift"))
        // Rendered line 0 should remap back to source line 1
        #expect(code.lineInfo.lineSources.first == 1)

        // Disabling conceal reveals the fence markers again
        code.conceal = false
        test.renderOnce()
        let unconcealedFrame = test.captureCharFrame()
        #expect(unconcealedFrame.contains("```swift"))
        #expect(unconcealedFrame.contains("let x = 1"))
        #expect(code.lineInfo.lineSources.first == 0)
    }

    @Test("supports onHighlight, onChunks, streaming updates, and async highlighting with drawUnstyledText=false")
    func hooksStreamingAndAsyncHighlighting() async {
        let test = createTestRenderer(width: 40, height: 6)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        var highlightCallbackInvoked = false
        var chunksCallbackInvoked = false

        let code = CodeRenderable(
            ctx: test.renderer,
            options: CodeOptions(
                content: "const a = 1",
                filetype: "typescript",
                syntaxStyle: style,
                drawUnstyledText: false,
                streaming: true,
                onHighlight: { highlights, context in
                    highlightCallbackInvoked = true
                    #expect(context.filetype == "typescript")
                    return highlights
                },
                onChunks: { chunks, _ in
                    chunksCallbackInvoked = true
                    return chunks
                },
                autoHighlight: false
            )
        )
        test.root.add(code)
        test.renderOnce()

        // Before highlighting settles with drawUnstyledText=false, buffer is hidden
        let hiddenFrame = test.captureCharFrame()
        #expect(!hiddenFrame.contains("const a = 1"))

        await code.highlightAsync()
        test.renderOnce()

        #expect(highlightCallbackInvoked)
        #expect(chunksCallbackInvoked)
        let revealedFrame = test.captureCharFrame()
        #expect(revealedFrame.contains("const a = 1"))

        // Streaming append updates cleanly
        code.autoHighlight = true
        code.content = "const a = 1\nconst b = 2"
        test.renderOnce()
        let streamedFrame = test.captureCharFrame()
        #expect(streamedFrame.contains("const a = 1"))
        #expect(streamedFrame.contains("const b = 2"))
    }
}

// MARK: - DiffRenderable Tests

@Suite("DiffRenderable")
struct DiffRenderableTests {
    private static let samplePatch = """
    --- a/example.swift
    +++ b/example.swift
    @@ -1,4 +1,4 @@
     let greeting = "hello"
    -let target = "world"
    +let target = "swift"
     print(greeting)
     print(target)
    """

    private static let multiHunkPatch = """
    --- a/file.txt
    +++ b/file.txt
    @@ -1,3 +1,3 @@
     alpha
    -beta
    +BETA
     gamma
    @@ -10,2 +10,3 @@
     ten
    +eleven
     twelve
    """

    @Test("renders unified diff with line numbers, signs, colors, and hunk row offsets")
    func rendersUnifiedDiff() {
        let test = createTestRenderer(width: 50, height: 10)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let diffView = DiffRenderable(
            ctx: test.renderer,
            options: DiffOptions(
                id: "diff-unified",
                diff: Self.samplePatch,
                view: .unified,
                filetype: "swift",
                syntaxStyle: style,
                showLineNumbers: true,
                width: .point(50),
                height: .point(10)
            )
        )
        test.root.add(diffView)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("let greeting = \"hello\""))
        #expect(frame.contains("-"))
        #expect(frame.contains("let target = \"world\""))
        #expect(frame.contains("+"))
        #expect(frame.contains("let target = \"swift\""))
        #expect(diffView.getHunkRowOffsets() == [0])

        // Verify removed & added line backgrounds and word-level accent highlight on changed word ("world" vs "swift")
        let spans = test.captureSpans()
        let removedLine = spans.lines.first { line in
            line.spans.map(\.text).joined().contains("world")
        }
        let addedLine = spans.lines.first { line in
            line.spans.map(\.text).joined().contains("swift")
        }
        #expect(removedLine != nil)
        #expect(addedLine != nil)

        // Changed token "world" should have a distinct bg from unchanged token "let" on the same line
        let removedLetBg = removedLine?.spans.first { $0.text.contains("let") }?.bg
        let removedWordBg = removedLine?.spans.first { $0.text.contains("world") }?.bg
        #expect(removedLetBg != nil)
        #expect(removedWordBg != nil)
        #expect(removedLetBg != removedWordBg)

        let addedLetBg = addedLine?.spans.first { $0.text.contains("let") }?.bg
        let addedWordBg = addedLine?.spans.first { $0.text.contains("swift") }?.bg
        #expect(addedLetBg != nil)
        #expect(addedWordBg != nil)
        #expect(addedLetBg != addedWordBg)
    }

    @Test("renders split diff side-by-side and toggles between unified and split modes")
    func rendersSplitDiffAndTogglesView() {
        let test = createTestRenderer(width: 60, height: 10)
        defer { test.destroy() }

        let diffView = DiffRenderable(
            ctx: test.renderer,
            options: DiffOptions(
                id: "diff-split",
                diff: Self.multiHunkPatch,
                view: .split,
                showLineNumbers: true,
                width: .point(60),
                height: .point(10)
            )
        )
        test.root.add(diffView)
        test.renderOnce()

        let splitFrame = test.captureCharFrame()
        let lines = splitFrame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Row 1 should show old "- beta" on the left and new "+ BETA" on the right of the same row
        #expect(lines[1].contains("beta"))
        #expect(lines[1].contains("BETA"))
        // Hunk offsets: hunk 0 at row 0, hunk 1 at row 3
        #expect(diffView.getHunkRowOffsets() == [0, 3])
        #expect(diffView.leftSide != nil)
        #expect(diffView.rightSide != nil)

        // Toggle line numbers off
        diffView.showLineNumbers = false
        test.renderOnce()
        #expect(diffView.leftSide?.showLineNumbers == false)
        #expect(diffView.rightSide?.showLineNumbers == false)

        // Toggle back to unified view
        diffView.showLineNumbers = true
        diffView.view = .unified
        test.renderOnce()
        let unifiedFrame = test.captureCharFrame()
        #expect(unifiedFrame.contains("beta"))
        #expect(unifiedFrame.contains("BETA"))
        #expect(unifiedFrame.contains("eleven"))
        #expect(diffView.getChildren().count == 1)
    }

    @Test("aligns wrapped rows in split mode and responds to resize")
    func splitModeWrapAlignmentAndResize() {
        let test = createTestRenderer(width: 36, height: 12)
        defer { test.destroy() }

        let wrapPatch = """
        --- a/wrap.txt
        +++ b/wrap.txt
        @@ -1,3 +1,3 @@
         header
        -short old
        +this is a much longer replacement line that wraps
         footer
        """

        let diffView = DiffRenderable(
            ctx: test.renderer,
            options: DiffOptions(
                diff: wrapPatch,
                view: .split,
                wrapMode: .word,
                width: .percent(100),
                height: .percent(100)
            )
        )
        test.root.add(diffView)
        test.renderOnce()

        let frame = test.captureCharFrame()
        let rows = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // "footer" should appear on the same visual row in both left and right panes!
        let footerRow = rows.first { row in
            // Count occurrences of "footer" in the same row
            let parts = row.components(separatedBy: "footer")
            return parts.count >= 3
        }
        #expect(footerRow != nil)

        // Resize wider and ensure re-alignment still keeps both footers on the same row
        test.resize(width: 60, height: 12)
        test.renderOnce()
        let resizedFrame = test.captureCharFrame()
        let resizedRows = resizedFrame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let resizedFooterRow = resizedRows.first { row in
            row.components(separatedBy: "footer").count >= 3
        }
        #expect(resizedFooterRow != nil)
    }

    @Test("displays clean error fallback on invalid diff and recovers on valid diff")
    func invalidDiffErrorFallbackAndRecovery() {
        let test = createTestRenderer(width: 60, height: 10)
        defer { test.destroy() }

        let brokenPatch = """
        --- a/broken.txt
        +++ b/broken.txt
        @@ not-a-valid-range @@
        +line
        """

        let diffView = DiffRenderable(
            ctx: test.renderer,
            options: DiffOptions(
                diff: brokenPatch,
                width: .point(60),
                height: .point(10)
            )
        )
        test.root.add(diffView)
        test.renderOnce()

        #expect(diffView.parseError != nil)
        let errFrame = test.captureCharFrame()
        #expect(errFrame.contains("Error parsing diff:"))
        #expect(errFrame.contains("@@ not-a-valid-range @@"))

        // Updating to a valid patch clears the error view and restores diff rendering
        diffView.diff = Self.samplePatch
        test.renderOnce()
        #expect(diffView.parseError == nil)
        let recoveredFrame = test.captureCharFrame()
        #expect(!recoveredFrame.contains("Error parsing diff:"))
        #expect(recoveredFrame.contains("let target = \"swift\""))
    }
}

private extension String {
    func components(separatedBy separator: String) -> [String] {
        guard !separator.isEmpty else { return [self] }
        var result: [String] = []
        var searchStart = startIndex
        while let range = self[searchStart...].range(of: separator) {
            result.append(String(self[searchStart..<range.lowerBound]))
            searchStart = range.upperBound
        }
        result.append(String(self[searchStart..<endIndex]))
        return result
    }

    func range(of needle: String) -> Range<String.Index>? {
        self[startIndex..<endIndex].range(of: needle)
    }
}

private extension Substring {
    func range(of needle: String) -> Range<String.Index>? {
        let needleCount = needle.count
        guard needleCount > 0 else { return startIndex..<startIndex }
        var idx = startIndex
        while idx < endIndex {
            if self[idx...].hasPrefix(needle) {
                let end = index(idx, offsetBy: needleCount)
                return idx..<end
            }
            idx = index(after: idx)
        }
        return nil
    }
}

// MARK: - MarkdownDocument (StreamingMarkdownDocument) Tests

@Suite("MarkdownDocument")
struct MarkdownDocumentTests {
    @Test("tracks unchanged prefix blocks and committed count during incremental streaming")
    func incrementalStreamingDiffs() {
        let doc = MarkdownDocument.streaming()

        // Chunk 1: heading + start of paragraph
        let c1 = doc.write("# Hello\n\nFirst para", streaming: true)
        #expect(c1.unchangedPrefixCount == 0)
        #expect(c1.changed.count == 2)
        #expect(c1.removedFrom == nil)
        #expect(doc.committed == 1)
        #expect(!doc.finished)
        #expect(doc.blocks[0].kind == .heading)
        #expect(doc.blocks[1].kind == .paragraph)

        // Chunk 2: streaming more words into paragraph 1 -> block 0 stays unchanged!
        let c2 = doc.write("# Hello\n\nFirst paragraph complete", streaming: true)
        #expect(c2.unchangedPrefixCount == 1)
        #expect(c2.changed.count == 1)
        #expect(c2.changed[0].index == 1)
        #expect(c2.removedFrom == nil)
        #expect(doc.committed == 1)

        // Chunk 3: open fenced code block appended -> blocks 0 and 1 stay unchanged!
        let c3 = doc.write("# Hello\n\nFirst paragraph complete\n\n```swift\nlet x = 1", streaming: true)
        #expect(c3.unchangedPrefixCount == 2)
        #expect(c3.changed.count == 1)
        #expect(c3.changed[0].index == 2)
        #expect(c3.changed[0].kind == .code)
        #expect(c3.changed[0].isClosed == false)
        #expect(doc.committed == 2)

        // Chunk 4: close the fence and finish streaming
        let c4 = doc.write("# Hello\n\nFirst paragraph complete\n\n```swift\nlet x = 1\n```", streaming: false)
        #expect(c4.unchangedPrefixCount == 2)
        #expect(c4.changed.count == 1)
        #expect(c4.changed[0].isClosed == true)
        #expect(doc.committed == 3)
        #expect(doc.finished)

        // No-op write returns empty changes
        let c5 = doc.write(doc.content, streaming: false)
        #expect(c5.isEmpty)

        // Replacing with shorter content sets removedFrom
        let c6 = doc.write("# Short", streaming: false)
        #expect(c6.removedFrom == 1)
        #expect(doc.blocks.count == 1)
    }

    @Test("supports MarkdownDocument.diff(from:) value diffing and setOptions")
    func valueDiffAndOptions() {
        let prev = parseMarkdown("# One\n\nTwo\n\nThree")
        let next = parseMarkdown("# One\n\nTwo\n\nUpdated")
        let diff = next.diff(from: prev)
        #expect(diff.unchangedPrefixCount == 2)
        #expect(diff.changed.count == 1)
        #expect(diff.changed[0].index == 2)
        #expect(diff.removedFrom == nil)

        let streamDoc = StreamingMarkdownDocument()
        _ = streamDoc.write("$$\nx^2\n$$", streaming: false)
        let optChanges = streamDoc.setOptions(MarkdownParseOptions(enableGFM: true, enableMath: true))
        #expect(!optChanges.isEmpty)
        #expect(streamDoc.blocks.first?.kind == .code)
    }
}

// MARK: - MarkdownRenderable Tests

@Suite("MarkdownRenderable")
struct MarkdownRenderableTests {
    @Test("renders headings, inline formatting, links with OSC 8, lists, task lists, blockquotes, and rules")
    func rendersRichMarkdownElements() {
        let test = createTestRenderer(width: 60, height: 30)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let markdown = """
        # Title

        Hello **bold** *italic* ~~stale~~ `code` [OpenTUI](https://opentui.dev)

        - [x] Done task
        - [ ] Open task

        3. Third
        4. Fourth

        > Quoted line

        ---
        """

        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                id: "md-rich",
                content: markdown,
                syntaxStyle: style,
                conceal: true,
                width: .point(60)
            )
        )
        test.root.add(md)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("Title"))
        #expect(!frame.contains("# Title"))
        #expect(frame.contains("Hello bold italic stale code OpenTUI"))
        #expect(!frame.contains("**bold**"))
        #expect(frame.contains("☑"))
        #expect(frame.contains("Done task"))
        #expect(frame.contains("☐"))
        #expect(frame.contains("Open task"))
        #expect(frame.contains("3. Third"))
        #expect(frame.contains("4. Fourth"))
        #expect(frame.contains("Quoted line"))
        #expect(frame.contains("│")) // blockquote left border
        #expect(frame.contains("─")) // thematic break top border

        // Check bold/italic/strikethrough attributes & OSC 8 hyperlink on "OpenTUI"
        let spans = test.captureSpans()
        let paraLineIdx = spans.lines.firstIndex { line in
            line.spans.map(\.text).joined().contains("Hello bold")
        }
        #expect(paraLineIdx != nil)
        if let idx = paraLineIdx {
            let lineSpans = spans.lines[idx].spans
            let boldSpan = lineSpans.first { $0.text.contains("bold") }
            #expect(((boldSpan?.attributes ?? 0) & TextAttributes.bold) != 0)
            let italicSpan = lineSpans.first { $0.text.contains("italic") }
            #expect(((italicSpan?.attributes ?? 0) & TextAttributes.italic) != 0)
            let strikeSpan = lineSpans.first { $0.text.contains("stale") }
            #expect(((strikeSpan?.attributes ?? 0) & TextAttributes.strikethrough) != 0)

            // Locate column of "OpenTUI" and confirm OSC 8 hyperlink URL in LinkPool
            let lineText = lineSpans.map(\.text).joined()
            if let linkRange = lineText.range(of: "OpenTUI") {
                let col = lineText.distance(from: lineText.startIndex, to: linkRange.lowerBound)
                #expect(test.renderer.getLinkAt(x: col, y: idx) == "https://opentui.dev")
            } else {
                Issue.record("Expected OpenTUI link text in rendered line")
            }
        }
    }

    @Test("toggles conceal to reveal raw Markdown markers and task checkboxes")
    func togglesConcealMarkers() {
        let test = createTestRenderer(width: 60, height: 14)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: "## Sub\n\n**strong** `inline` [docs](https://swift.org)\n\n- [x] Ship",
                syntaxStyle: style,
                conceal: true,
                width: .point(60)
            )
        )
        test.root.add(md)
        test.renderOnce()

        let concealed = test.captureCharFrame()
        #expect(concealed.contains("Sub"))
        #expect(!concealed.contains("## Sub"))
        #expect(concealed.contains("☑"))

        md.conceal = false
        test.renderOnce()

        let raw = test.captureCharFrame()
        #expect(raw.contains("## Sub"))
        #expect(raw.contains("**strong**"))
        #expect(raw.contains("`inline`"))
        #expect(raw.contains("[docs](https://swift.org)"))
        #expect(raw.contains("[x]"))
    }

    @Test("renders fenced code blocks via CodeRenderable with infoStringToFiletype and GFM tables via TextTableRenderable")
    func rendersCodeBlocksAndGFMTables() {
        let test = createTestRenderer(width: 50, height: 22)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let markdown = """
        ```ts title=demo.ts
        const value = 7
        ```

        | Name | Score |
        | :--- | ---: |
        | Ada  | 100  |
        | Bob  | 95   |
        """

        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: markdown,
                syntaxStyle: style,
                tableOptions: MarkdownTableOptions(
                    widthMode: .content,
                    cellPadding: 1,
                    borders: true,
                    outerBorder: true
                ),
                width: .point(50)
            )
        )
        test.root.add(md)
        test.renderOnce()

        #expect(md.blocks.count == 2)
        let codeBlock = md.blocks[0].renderable as? CodeRenderable
        #expect(codeBlock != nil)
        #expect(codeBlock?.filetype == "typescript")

        let tableBlock = md.blocks[1].renderable as? TextTableRenderable
        #expect(tableBlock != nil)
        #expect(tableBlock?.columnAlignments == [TextAlign.left, TextAlign.right])

        let frame = test.captureCharFrame()
        #expect(frame.contains("const value = 7"))
        #expect(frame.contains("Name"))
        #expect(frame.contains("Score"))
        #expect(frame.contains("Ada"))
        #expect(frame.contains("100"))
        #expect(frame.contains("┌"))
        #expect(frame.contains("┘"))

        // Syntax highlighting applied to fenced code block ("const" gets keyword color)
        let spans = test.captureSpans()
        let codeRow = spans.lines.first { $0.spans.map(\.text).joined().contains("const value") }
        let constSpan = codeRow?.spans.first { $0.text.contains("const") }
        #expect(constSpan?.fg == parseColor("#FF7B72"))
    }

    @Test("reuses unchanged prefix block renderables during streaming updates and supports custom renderNode hook")
    func streamingReuseAndCustomRenderNode() {
        let test = createTestRenderer(width: 50, height: 18)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: "# Heading\n\nStreaming start",
                syntaxStyle: style,
                streaming: true,
                width: .point(50)
            )
        )
        test.root.add(md)
        test.renderOnce()

        #expect(md.blocks.count == 2)
        let initialHeadingRenderable = md.blocks[0].renderable
        let initialParagraphRenderable = md.blocks[1].renderable
        #expect(initialHeadingRenderable != nil)
        #expect(initialParagraphRenderable != nil)

        // Append to second block while streaming: block 0 MUST be identical instance; block 1 updates in place!
        md.content = "# Heading\n\nStreaming start and more words"
        test.renderOnce()

        #expect(md.blocks[0].renderable === initialHeadingRenderable)
        #expect(md.blocks[1].renderable === initialParagraphRenderable)
        #expect(test.captureCharFrame().contains("Streaming start and more words"))

        // Append a third block and finish streaming: blocks 0 and 1 stay identical!
        md.content = "# Heading\n\nStreaming start and more words\n\nThird block"
        md.streaming = false
        test.renderOnce()

        #expect(md.blocks.count == 3)
        #expect(md.blocks[0].renderable === initialHeadingRenderable)
        #expect(md.blocks[1].renderable === initialParagraphRenderable)
        #expect(md.committedBlockCount == 3)
        #expect(test.captureCharFrame().contains("Third block"))

        // Custom renderNode override hook replaces code blocks while delegating other blocks to defaultRender()
        let customMd = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: "Intro\n\n```mermaid\ngraph TD\n```",
                syntaxStyle: style,
                renderNode: createMarkdownCodeBlockRenderer([
                    "mermaid": { block, _ in
                        TextRenderable(
                            ctx: test.renderer,
                            options: TextOptions(content: .string("[DIAGRAM:\(block.text)]"))
                        )
                    },
                ]),
                width: .point(50)
            )
        )
        test.root.remove(md)
        test.root.add(customMd)
        test.renderOnce()

        let customFrame = test.captureCharFrame()
        #expect(customFrame.contains("Intro"))
        #expect(customFrame.contains("[DIAGRAM:graph TD]"))
    }

    @Test("supports inlineHook with targetAt hit-testing and borderless columns table style")
    func inlineHookTargetAtAndColumnsTable() {
        let test = createTestRenderer(width: 50, height: 14)
        defer { test.destroy() }

        let style = makeRichSyntaxStyle()
        var hookCount = 0
        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: "See ISSUE-42 now\n\n| ColA | ColB |\n| --- | --- |\n| 1 | 2 |",
                syntaxStyle: style,
                tableOptions: MarkdownTableOptions(style: .columns),
                inlineHook: { spans, ctx in
                    hookCount += 1
                    guard !ctx.tableCell else { return spans }
                    return spans.map { span in
                        if span.text.contains("ISSUE-42") {
                            var next = span
                            next.target = "issue:42"
                            return next
                        }
                        return span
                    }
                },
                inlineHookFilter: ["ISSUE-"],
                width: .point(50)
            )
        )
        test.root.add(md)
        test.renderOnce()

        #expect(hookCount == 1)
        #expect(md.targetAt(x: 4, y: 0) == "issue:42")

        let frame = test.captureCharFrame()
        #expect(frame.contains("ColA"))
        #expect(frame.contains("ColB"))
        #expect(!frame.contains("┌")) // borderless columns preset

        md.rerunInlineHook { $0.contains("ISSUE-") }
        #expect(hookCount == 2)
    }
}
