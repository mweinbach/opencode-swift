import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// Upstream v0.9.3–v0.9.5 behavior: paste control characters, Markdown task boxes, and resume after a stopped job.

@Suite("Upstream 0.9.5 sync: Textarea paste, Markdown task markers, CliRenderer resume")
struct Upstream095SyncTests {
    @Test("A paste drops control characters but tab, LF and CR")
    func pasteDropsControlCharacters() {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let area = TextareaRenderable(ctx: test.renderer, options: TextareaOptions(initialValue: ""))
        test.root.add(area)
        // NUL, BEL, form feed, DEL and NEL (C1) go; tab and LF stay.
        let pasted = "A\u{00}B\u{07}C\tD\nE\u{0C}F\u{7F}G\u{85}H"
        area.handlePaste(PasteEvent(bytes: Array(pasted.utf8)))
        #expect(area.plainText == "ABC\tD\nEFGH")
    }

    @Test("A paste strips escape sequences before dropping the remaining controls")
    func pasteStripsEscapesThenControls() {
        let test = createTestRenderer(width: 40, height: 4)
        defer { test.destroy() }
        let area = TextareaRenderable(ctx: test.renderer, options: TextareaOptions(initialValue: ""))
        test.root.add(area)
        area.handlePaste(PasteEvent(bytes: Array("\u{1B}[31mred\u{1B}[0m\u{08}!".utf8)))
        #expect(area.plainText == "red!")
    }

    private func renderTasks(conceal: Bool, markers: MarkdownTaskMarkers?) -> (TestRenderer, MarkdownRenderable, String) {
        let test = createTestRenderer(width: 40, height: 6)
        let md = MarkdownRenderable(ctx: test.renderer, options: MarkdownOptions(
            content: "- [ ] Open task\n- [x] Done task",
            conceal: conceal,
            taskMarkers: markers,
            width: .point(40)
        ))
        test.root.add(md)
        test.renderOnce()
        return (test, md, test.captureCharFrame())
    }

    @Test("Task boxes default to ☐ and ☑ with conceal on")
    func defaultTaskMarkers() {
        let (test, md, frame) = renderTasks(conceal: true, markers: nil)
        defer { test.destroy() }
        #expect(frame.contains("☐ Open task"))
        #expect(frame.contains("☑ Done task"))
        #expect(md.taskMarkers == MarkdownTaskMarkers(unchecked: "☐", checked: "☑"))
    }

    @Test("taskMarkers sets the boxes with conceal on, and updates items already on screen")
    func customTaskMarkers() {
        let (test, md, frame) = renderTasks(conceal: true, markers: MarkdownTaskMarkers(unchecked: "[ ]", checked: "[x]"))
        defer { test.destroy() }
        #expect(frame.contains("[ ] Open task"))
        #expect(frame.contains("[x] Done task"))

        md.taskMarkers = MarkdownTaskMarkers(unchecked: "o", checked: "*")
        test.renderOnce()
        let updated = test.captureCharFrame()
        #expect(updated.contains("o Open task"))
        #expect(updated.contains("* Done task"))

        md.taskMarkers = nil
        test.renderOnce()
        #expect(test.captureCharFrame().contains("☐ Open task"))
    }

    @Test("Without conceal, task items show the source's boxes whatever taskMarkers says")
    func taskMarkersWithoutConceal() {
        let (test, _, frame) = renderTasks(conceal: false, markers: MarkdownTaskMarkers(unchecked: "o", checked: "*"))
        defer { test.destroy() }
        #expect(frame.contains("[ ] Open task"))
        #expect(frame.contains("[x] Done task"))
    }

    // Each row: the terminal's size at resume, a size the app asked for while suspended, and the resumed size.
    @Test(
        "resume() applies a new terminal size, else a size requested while suspended",
        arguments: [
            (100, 24, nil, 100, 24),
            (80, 10, nil, 80, 10),
            (0, 0, nil, 80, 24),
            (80, 24, (71, 19), 71, 19),
            // A size the renderer rejects is dropped, as a live resize is.
            (80, 24, (0, 0), 80, 24),
        ] as [(Int, Int, (Int, Int)?, Int, Int)]
    )
    func resumeAppliesStoppedResize(columns: Int, rows: Int, requested: (Int, Int)?, width: Int, height: Int) {
        let test = createTestRenderer(width: 80, height: 24)
        defer { test.destroy() }
        let renderer = test.renderer
        renderer.suspend()
        renderer.terminalSizeProvider = { (width: columns, height: rows) }
        if let requested { renderer.requestResize(width: requested.0, height: requested.1) }
        renderer.resume()
        #expect(renderer.terminalWidth == width)
        #expect(renderer.terminalHeight == height)
    }
}
