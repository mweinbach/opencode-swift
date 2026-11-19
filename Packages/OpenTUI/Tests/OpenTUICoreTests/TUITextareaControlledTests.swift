import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Testing

@Suite("TUITextareaControlled")
struct TUITextareaControlledTests {
    @Test("Controlled mount prefers value over initialValue, places cursor at EOL, and avoids spurious mount onContentChange")
    func controlledMountAndInitialCursor() throws {
        let test = createTestRenderer(width: 44, height: 8)
        defer { test.destroy() }

        final class Store {
            var value = "Initial prompt"
            var changeCount = 0
        }
        let store = Store()

        let root = test.mountView {
            TUITextarea(
                value: store.value,
                initialValue: "Ignored fallback",
                placeholder: "Type here...",
                onContentChange: { _ in
                    store.changeCount += 1
                }
            )
            .id("controlled-ta")
            .key("controlled-ta")
            .width(40)
            .height(4)
            .focused(true)
        }

        test.renderOnce(force: true)
        let textarea = try #require(root.findRenderable(id: "controlled-ta") as? TextareaRenderable)
        #expect(textarea.plainText == "Initial prompt")
        #expect(store.changeCount == 0)

        // Cursor starts at EOL so typing appends cleanly
        test.mockInput.typeText("!")
        #expect(textarea.plainText == "Initial prompt!")
        #expect(store.changeCount == 1)
    }

    @Test("Controlled value preserves user typing and mid-buffer cursor across unrelated re-renders")
    func preservesUserTypingAndCursorWhenValueMatches() throws {
        let test = createTestRenderer(width: 50, height: 10)
        defer { test.destroy() }

        final class Store {
            var prompt = ""
            var headerCounter = 0
            var changeCount = 0
        }
        let store = Store()

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            VStack(spacing: 0) {
                TUIText("Tick \(store.headerCounter)")
                    .key("tick")
                TUITextarea(
                    value: store.prompt,
                    placeholder: "Ask anything",
                    onContentChange: { _ in
                        store.changeCount += 1
                        if let ta = root.findRenderable(id: "prompt-ta") as? TextareaRenderable {
                            store.prompt = ta.plainText
                        }
                    }
                )
                .id("prompt-ta")
                .key("prompt-ta")
                .width(46)
                .height(4)
                .focused(true)
            }
        }

        test.renderOnce(force: true)
        let textareaBefore = try #require(root.findRenderable(id: "prompt-ta") as? TextareaRenderable)

        // User types text and moves cursor into the middle ("hello| world")
        test.mockInput.typeText("hello world")
        for _ in 0..<6 {
            test.mockInput.pressArrow(.left)
        }
        #expect(store.prompt == "hello world")
        #expect(textareaBefore.plainText == "hello world")
        #expect(textareaBefore.cursorOffset == 5)
        let changesAfterTyping = store.changeCount
        #expect(changesAfterTyping > 0)

        // Trigger unrelated state re-render while controlled value still equals buffer
        store.headerCounter += 1
        root.invalidate(renderNow: true)

        let textareaAfter = try #require(root.findRenderable(id: "prompt-ta") as? TextareaRenderable)
        #expect(textareaAfter === textareaBefore)
        #expect(textareaAfter.plainText == "hello world")
        #expect(textareaAfter.cursorOffset == 5)
        #expect(store.changeCount == changesAfterTyping)

        // User continues typing at preserved mid-buffer cursor
        test.mockInput.typeText(" swift")
        #expect(textareaAfter.plainText == "hello swift world")
        #expect(store.prompt == "hello swift world")
        #expect(textareaAfter.cursorOffset == 11)
        #expect(test.captureCharFrame().contains("Tick 1"))
    }

    @Test("Controlled value syncs programmatic replacements (empty, multiline, UTF-8/CJK/emoji, CRLF) to EOL without onContentChange loops")
    func programmaticReplacementsMoveCursorToEOLWithoutLoops() throws {
        let test = createTestRenderer(width: 56, height: 12)
        defer { test.destroy() }

        final class Store {
            var prompt = "draft text"
            var changeCount = 0
            var cursorChangeCount = 0
            var reentrantInvalidations = 0
        }
        let store = Store()

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            TUITextarea(
                value: store.prompt,
                placeholder: "Message...",
                wrapMode: .word,
                onContentChange: { _ in
                    store.changeCount += 1
                    if let ta = root.findRenderable(id: "sync-ta") as? TextareaRenderable {
                        store.prompt = ta.plainText
                        store.reentrantInvalidations += 1
                        root.invalidate()
                    }
                },
                onCursorChange: { _ in
                    store.cursorChangeCount += 1
                }
            )
            .id("sync-ta")
            .key("sync-ta")
            .width(50)
            .height(6)
            .focused(true)
        }

        test.renderOnce(force: true)
        let textarea = try #require(root.findRenderable(id: "sync-ta") as? TextareaRenderable)
        #expect(textarea.plainText == "draft text")
        #expect(store.changeCount == 0)

        // Select all so we also verify stale selections are cleared cleanly on controlled replacement
        _ = textarea.selectAll()
        #expect(textarea.hasSelection())

        // 1. Programmatic clear to empty string (e.g., after submit)
        store.prompt = ""
        root.invalidate(renderNow: true)
        #expect(textarea.plainText == "")
        #expect(!textarea.hasSelection())
        #expect(textarea.cursorOffset == 0)
        #expect(store.changeCount == 0)
        #expect(store.cursorChangeCount == 0)

        // User can type normally immediately after programmatic clear
        test.mockInput.typeText("hi")
        #expect(textarea.plainText == "hi")
        #expect(store.prompt == "hi")
        let countAfterUserHi = store.changeCount
        #expect(countAfterUserHi == 2)

        // 2. Programmatic multiline replacement (e.g., history recall or stash restore)
        store.prompt = "First line\nSecond line\nThird"
        root.invalidate(renderNow: true)
        #expect(textarea.plainText == "First line\nSecond line\nThird")
        #expect(store.changeCount == countAfterUserHi)

        // Cursor must be at EOL of the final line so typing appends to "Third"
        test.mockInput.typeText("!")
        #expect(textarea.plainText == "First line\nSecond line\nThird!")
        #expect(store.prompt == "First line\nSecond line\nThird!")
        let countAfterMultilineAppend = store.changeCount
        #expect(countAfterMultilineAppend == countAfterUserHi + 1)

        // 3. Programmatic UTF-8 / CJK / emoji / ZWJ cluster replacement
        let unicodePrompt = "Hello 🚀\n日本語 🇺🇸👨‍👩‍👧‍👦"
        store.prompt = unicodePrompt
        root.invalidate(renderNow: true)
        #expect(textarea.plainText == unicodePrompt)
        #expect(store.changeCount == countAfterMultilineAppend)

        test.mockInput.typeText(" OK")
        #expect(textarea.plainText == "\(unicodePrompt) OK")
        #expect(store.prompt == "\(unicodePrompt) OK")
        let countAfterUnicodeAppend = store.changeCount
        #expect(countAfterUnicodeAppend == countAfterMultilineAppend + 3)

        // 4. Programmatic CRLF replacement normalizes cleanly without resetting cursor on re-renders
        store.prompt = "win1\r\nwin2"
        root.invalidate(renderNow: true)
        #expect(textarea.plainText == "win1\nwin2")
        #expect(store.changeCount == countAfterUnicodeAppend)

        // Move cursor left 2 characters and re-render with the same CRLF value -> cursor must stay put
        test.mockInput.pressArrow(.left)
        test.mockInput.pressArrow(.left)
        let savedCursor = textarea.cursorOffset
        root.invalidate(renderNow: true)
        #expect(textarea.cursorOffset == savedCursor)
        #expect(store.changeCount == countAfterUnicodeAppend)
    }

    @Test("Uncontrolled TUITextarea (value == nil) preserves initialValue compatibility and live edits")
    func uncontrolledModeRemainsBackwardCompatible() throws {
        let test = createTestRenderer(width: 40, height: 8)
        defer { test.destroy() }

        final class Store {
            var tick = 0
        }
        let store = Store()

        let root = test.mountView {
            VStack {
                TUIText("Frame \(store.tick)")
                TUITextarea(
                    initialValue: "Start",
                    placeholder: "Notes",
                    wrapMode: .word
                )
                .id("uncontrolled-ta")
                .key("uncontrolled-ta")
                .width(36)
                .height(4)
                .focused(true)
            }
        }

        test.renderOnce(force: true)
        let textarea = try #require(root.findRenderable(id: "uncontrolled-ta") as? TextareaRenderable)
        #expect(textarea.plainText == "Start")

        textarea.gotoBufferEnd()
        test.mockInput.typeText(" + edits")
        #expect(textarea.plainText == "Start + edits")

        // Re-rendering with unchanged initialValue must NOT clobber live uncontrolled edits
        store.tick = 1
        root.invalidate(renderNow: true)
        #expect(textarea.plainText == "Start + edits")
    }

    @Test("TUITextarea passes through optional maxHeight and keyBindings on mount and patch")
    func maxHeightAndKeyBindingsPassthrough() throws {
        let test = createTestRenderer(width: 40, height: 10)
        defer { test.destroy() }

        final class Store {
            var maxHeight: FlexValue = 3
            var customBindings: [TextareaKeyBinding]? = [
                KeyBinding(name: "return", action: .submit),
            ]
            var submitCount = 0
        }
        let store = Store()

        let root = test.mountView {
            TUITextarea(
                value: "alpha",
                maxHeight: store.maxHeight,
                keyBindings: store.customBindings,
                onSubmit: { _ in store.submitCount += 1 }
            )
            .id("configured-ta")
            .key("configured-ta")
            .width(36)
            .focused(true)
        }

        test.renderOnce(force: true)
        let textarea = try #require(root.findRenderable(id: "configured-ta") as? TextareaRenderable)
        #expect(textarea.maxHeight == .point(3))

        // Bare Enter submits because customBindings overrode "return" -> .submit
        test.mockInput.pressEnter()
        #expect(store.submitCount == 1)
        #expect(textarea.plainText == "alpha")

        // Patch maxHeight and clear customBindings -> restores default newline on Enter
        store.maxHeight = 5
        store.customBindings = nil
        root.invalidate(renderNow: true)
        #expect(textarea.maxHeight == .point(5))

        test.mockInput.pressEnter()
        #expect(store.submitCount == 1)
        #expect(textarea.plainText == "alpha\n")
    }
}
