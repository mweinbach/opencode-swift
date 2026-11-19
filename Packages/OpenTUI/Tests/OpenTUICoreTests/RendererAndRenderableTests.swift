import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Test Helper Renderables

private final class FilledBox: Renderable, @unchecked Sendable {
    var fillChar: UInt32
    var fgColor: RGBA
    var bgColor: RGBA
    var label: String?
    var keyPresses: [KeyEvent] = []
    var pastes: [String] = []
    var mouseEvents: [MouseEventType] = []
    var scrollCount: Int = 0
    var canScroll: Bool = false
    var selectableText: String = ""
    private var hasActiveSelection: Bool = false
    private var selectedSubtext: String = ""

    init(
        ctx: any RenderContext,
        fillChar: UInt32 = 0x23, // '#'
        fgColor: RGBA = RGBA.fromInts(255, 255, 255, 255),
        bgColor: RGBA = RGBA.fromInts(0, 0, 0, 255),
        label: String? = nil,
        options: RenderableOptions = RenderableOptions()
    ) {
        self.fillChar = fillChar
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.label = label
        super.init(ctx: ctx, options: options)
    }

    override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        guard width > 0 && height > 0 else { return }
        for row in 0..<height {
            for col in 0..<width {
                buffer.setCellWithAlphaBlending(
                    x: origin.x + col,
                    y: origin.y + row,
                    cell: TerminalCell(
                        scalar: fillChar,
                        foreground: fgColor,
                        background: bgColor,
                        attributes: TextAttributes.none
                    )
                )
            }
        }
        if let label {
            buffer.drawText(
                label,
                x: origin.x,
                y: origin.y,
                fg: fgColor,
                bg: bgColor
            )
        }
    }

    override func handleKeyPress(_ key: KeyEvent) -> Bool {
        keyPresses.append(key)
        return true
    }

    override func handlePaste(_ event: PasteEvent) {
        pastes.append(decodePasteBytes(event.bytes))
    }

    override func onMouseEvent(_ event: MouseEvent) {
        mouseEvents.append(event.type)
        if event.type == .scroll && canScroll {
            _ = scrollOnce(event: event.scrollChainToken, scroller: self) {
                self.scrollCount += 1
                return true
            }
        }
    }

    override func shouldStartSelection(x: Int, y: Int) -> Bool {
        selectable && !selectableText.isEmpty
    }

    override func onSelectionChanged(_ selection: Selection?) -> Bool {
        guard let selection, selection.isActive, !selectableText.isEmpty else {
            hasActiveSelection = false
            selectedSubtext = ""
            return false
        }
        hasActiveSelection = true
        selectedSubtext = selectableText
        return true
    }

    override func getSelectedText() -> String {
        selectedSubtext
    }

    override func hasSelection() -> Bool {
        hasActiveSelection
    }
}

private final class MockThemeModeHost: RendererThemeModeHost {
    var queryCount: Int = 0
    var useSentinel: Bool

    init(useSentinel: Bool = false) {
        self.useSentinel = useSentinel
    }

    func queryThemeColors() -> Bool {
        queryCount += 1
        return useSentinel
    }
}

// MARK: - Clock Tests

@Suite("Clock & ManualClock Tests")
struct ClockTests {
    @Test("ManualClock schedules timeouts in chronological and FIFO order")
    func manualClockOrder() {
        let clock = ManualClock()
        var log: [String] = []

        clock.setTimeout({ log.append("t20-a") }, delayMs: 20)
        clock.setTimeout({ log.append("t10") }, delayMs: 10)
        clock.setTimeout({ log.append("t20-b") }, delayMs: 20)
        #expect(clock.pendingTimerCount == 3)

        clock.advance(by: 15)
        #expect(clock.now() == 15)
        #expect(log == ["t10"])
        #expect(clock.pendingTimerCount == 2)

        clock.advance(by: 5)
        #expect(clock.now() == 20)
        #expect(log == ["t10", "t20-a", "t20-b"])
        #expect(clock.pendingTimerCount == 0)
    }

    @Test("ManualClock supports clearTimeout, setInterval, clearInterval, and self-cancelling intervals")
    func manualClockIntervalsAndCancel() {
        let clock = ManualClock()
        var cancelledFired = false
        let h1 = clock.setTimeout({ cancelledFired = true }, delayMs: 10)
        clock.clearTimeout(h1)

        var ticks = 0
        var intervalHandle: TimerHandle?
        intervalHandle = clock.setInterval({
            ticks += 1
            if ticks == 3, let h = intervalHandle {
                clock.clearInterval(h)
            }
        }, delayMs: 10)

        clock.advance(by: 50)
        #expect(!cancelledFired)
        #expect(ticks == 3)
        #expect(clock.pendingTimerCount == 0)
    }

    @Test("ManualClock setTime advances forward and jumps backward cleanly")
    func manualClockSetTime() {
        let clock = ManualClock()
        var firedAt: Double? = nil
        clock.setTimeout({ firedAt = clock.now() }, delayMs: 25)

        clock.setTime(40.9)
        #expect(firedAt == 25)
        #expect(clock.now() == 40)

        clock.setTime(5)
        #expect(clock.now() == 5)
    }

    @Test("SystemClock returns monotonically non-decreasing milliseconds and fires/cancels timers")
    func systemClockBasics() async throws {
        let clock = SystemClock()
        let t0 = clock.now()
        try await Task.sleep(for: .milliseconds(5))
        let t1 = clock.now()
        #expect(t1 >= t0)

        var cancelledFired = false
        let cancelledHandle = clock.setTimeout({ cancelledFired = true }, delayMs: 5)
        clock.clearTimeout(cancelledHandle)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!cancelledFired)
    }
}

// MARK: - ThemeMode Conformance Tests

@Suite("ThemeMode Conformance & Lifecycle Tests")
struct ThemeModeConformanceTests {
    @Test("Passes 100% (11/11 rows) of upstream theme-mode.conformance.json")
    func upstreamConformanceVectors() throws {
        let rows = try ThemeModeConformanceLoader.load()
        #expect(rows.count == 11)

        for row in rows {
            let clock = ManualClock()
            let host = MockThemeModeHost()
            let state = RendererThemeMode(host: host, clock: clock)

            let result = state.handleSequence(row.reply)
            #expect(result.handled, "Row \(row.index) (\(row.name)) should be handled")
            #expect(
                result.changedMode?.rawValue == row.expectedMode,
                "Row \(row.index) (\(row.name)) expected \(row.expectedMode), got \(String(describing: result.changedMode?.rawValue))"
            )
            #expect(state.themeMode?.rawValue == row.expectedMode)
        }
    }

    @Test("OSC 10 foreground is consumed without setting mode; combined OSC 10+11 applies OSC 11")
    func osc10AndCombinedReplies() {
        let clock = ManualClock()
        let host = MockThemeModeHost()
        let state = RendererThemeMode(host: host, clock: clock)

        let fgOnly = state.handleSequence("\u{1B}]10;rgb:ffff/ffff/ffff\u{07}")
        #expect(fgOnly.handled)
        #expect(fgOnly.changedMode == nil)
        #expect(state.themeMode == nil)

        let combined = state.handleSequence("\u{1B}]10;rgb:0000/0000/0000\u{07}\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\")
        #expect(combined.handled)
        #expect(combined.changedMode == .light)
        #expect(state.themeMode == .light)

        // Repeated identical mode reports handled=true, changedMode=nil
        let same = state.handleSequence("\u{1B}]11;#ffffff\u{07}")
        #expect(same.handled)
        #expect(same.changedMode == nil)

        // Transition light -> dark
        let dark = state.handleSequence("\u{1B}]11;#111111\u{07}")
        #expect(dark.handled)
        #expect(dark.changedMode == .dark)
        #expect(state.themeMode == .dark)
    }

    @Test("DSR ?997;1n and ?997;2n deduplicate refresh queries until reply, cancelRefresh, or 250ms timeout")
    func dsrThemeNotifications() {
        let clock = ManualClock()
        let host = MockThemeModeHost(useSentinel: false)
        let state = RendererThemeMode(host: host, clock: clock)

        let r1 = state.handleSequence("\u{1B}[?997;1n")
        #expect(r1.handled && r1.changedMode == nil)
        #expect(host.queryCount == 1)

        // Duplicate while pending is ignored
        let r2 = state.handleSequence("\u{1B}[?997;2n")
        #expect(r2.handled && r2.changedMode == nil)
        #expect(host.queryCount == 1)

        // After 250ms timeout, next notification queries again
        clock.advance(by: 250)
        _ = state.handleSequence("\u{1B}[?997;2n")
        #expect(host.queryCount == 2)

        // OSC 11 reply cancels pending refresh immediately
        let reply = state.handleSequence("\u{1B}]11;#000000\u{07}")
        #expect(reply.changedMode == .dark)
        #expect(clock.pendingTimerCount == 0)

        _ = state.handleSequence("\u{1B}[?997;1n")
        #expect(host.queryCount == 3)
    }

    @Test("waitForThemeMode resolves on OSC 11 reply, timeout, and dispose")
    func themeModeWaiters() {
        let clock = ManualClock()
        let host = MockThemeModeHost()
        let state = RendererThemeMode(host: host, clock: clock)

        var timedOutResult: ThemeMode?? = nil
        state.waitForThemeMode(timeoutMs: 100, isDestroyed: false) { mode in
            timedOutResult = .some(mode)
        }
        clock.advance(by: 100)
        #expect(timedOutResult == .some(nil))

        var replyResult: ThemeMode?? = nil
        state.waitForThemeMode(timeoutMs: 500, isDestroyed: false) { mode in
            replyResult = .some(mode)
        }
        _ = state.handleSequence("\u{1B}]11;#fdf6e3\u{07}")
        #expect(replyResult == .some(.light))
        #expect(clock.pendingTimerCount == 0)

        // Already-known mode resolves immediately
        var immediateResult: ThemeMode?? = nil
        state.waitForThemeMode(timeoutMs: 500, isDestroyed: false) { mode in
            immediateResult = .some(mode)
        }
        #expect(immediateResult == .some(.light))

        // Dispose resolves pending waiters even when unknown
        let state2 = RendererThemeMode(host: host, clock: clock)
        var disposedResult: ThemeMode?? = nil
        state2.waitForThemeMode(timeoutMs: 500, isDestroyed: false) { mode in
            disposedResult = .some(mode)
        }
        state2.dispose()
        #expect(disposedResult == .some(nil))
        #expect(clock.pendingTimerCount == 0)
    }
}

// MARK: - Renderable Tree, Layout, Clipping, Opacity, Focus & Live Tests

@Suite("Renderable Core Tests")
struct RenderableTests {
    @Test("Tree operations: add, index insertion, insertBefore, remove, lookup, reparent, destroyRecursively")
    func treeOperations() {
        let test = createTestRenderer(width: 40, height: 10)
        defer { test.destroy() }

        let parent = Renderable(ctx: test.renderer, options: RenderableOptions(id: "parent"))
        let a = Renderable(ctx: test.renderer, options: RenderableOptions(id: "a"))
        let b = Renderable(ctx: test.renderer, options: RenderableOptions(id: "b"))
        let c = Renderable(ctx: test.renderer, options: RenderableOptions(id: "c"))
        let leaf = Renderable(ctx: test.renderer, options: RenderableOptions(id: "leaf"))

        test.root.add(parent)
        #expect(parent.add(a) == 0)
        #expect(parent.add(c) == 1)
        #expect(parent.insertBefore(b, anchor: c) == 1)
        #expect(parent.getChildren().map(\.id) == ["a", "b", "c"])
        #expect(parent.getChildrenCount() == 3)
        #expect(parent.getRenderable("b") === b)

        b.add(leaf)
        #expect(test.root.findDescendantById("leaf") === leaf)

        // Reparent leaf from b -> a
        a.add(leaf)
        #expect(b.getChildrenCount() == 0)
        #expect(a.getChildrenCount() == 1)
        #expect(leaf.parent === a)

        parent.remove(b)
        #expect(parent.getChildrenCount() == 2)
        #expect(b.parent == nil)

        parent.destroyRecursively()
        #expect(parent.isDestroyed)
        #expect(a.isDestroyed)
        #expect(leaf.isDestroyed)
        #expect(c.isDestroyed)
        #expect(test.root.getChildrenCount() == 0)
    }

    @Test("Flexbox layout props compute positions and sizes on renderOnce")
    func flexboxLayoutIntegration() {
        let test = createTestRenderer(width: 20, height: 6)
        defer { test.destroy() }

        let row = Renderable(
            ctx: test.renderer,
            options: RenderableOptions(
                id: "row",
                width: 20,
                height: 4,
                flexDirection: .row,
                padding: 1,
                gap: 2
            )
        )
        let left = FilledBox(
            ctx: test.renderer,
            fillChar: 0x41, // 'A'
            options: RenderableOptions(id: "left", width: 6, height: 2)
        )
        let right = FilledBox(
            ctx: test.renderer,
            fillChar: 0x42, // 'B'
            options: RenderableOptions(id: "right", height: 2, flexGrow: 1)
        )

        row.add(left)
        row.add(right)
        test.root.add(row)
        test.renderOnce()

        // Inner width = 20 - 2 (padding) = 18; left = 6, gap = 2 -> right = 10 at x = 1 + 6 + 2 = 9
        #expect(left.screenX == 1)
        #expect(left.screenY == 1)
        #expect(left.width == 6)
        #expect(left.height == 2)

        #expect(right.screenX == 9)
        #expect(right.screenY == 1)
        #expect(right.width == 10)
        #expect(right.height == 2)

        let frame = test.captureCharFrame()
        let lines = frame.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(String(lines[1]) == " AAAAAA  BBBBBBBBBB ")
    }

    @Test("Z-index sorting paints higher zIndex on top and preserves sibling order on ties")
    func zIndexOrdering() {
        let test = createTestRenderer(width: 6, height: 2)
        defer { test.destroy() }

        let back = FilledBox(
            ctx: test.renderer,
            fillChar: 0x31, // '1'
            options: RenderableOptions(id: "back", width: 4, height: 1, position: .absolute, top: 0, left: 0, zIndex: 10)
        )
        let front = FilledBox(
            ctx: test.renderer,
            fillChar: 0x32, // '2'
            options: RenderableOptions(id: "front", width: 4, height: 1, position: .absolute, top: 0, left: 0, zIndex: 5)
        )
        let tieTop = FilledBox(
            ctx: test.renderer,
            fillChar: 0x33, // '3'
            options: RenderableOptions(id: "tieTop", width: 2, height: 1, position: .absolute, top: 0, left: 0, zIndex: 10)
        )

        test.root.add(back)
        test.root.add(front)
        test.root.add(tieTop)
        test.renderOnce()

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false)
        // tieTop (z=10, later) covers cols 0..1 with '3'; back (z=10, earlier) covers cols 2..3 with '1' over front (z=5)
        #expect(String(lines[0]) == "3311  ")
        #expect(test.renderer.hitTest(x: 0, y: 0) == tieTop.num)
        #expect(test.renderer.hitTest(x: 2, y: 0) == back.num)
    }

    @Test("Scissor clipping clips child rendering and hit-testing when overflow is hidden")
    func scissorClippingOverflowHidden() {
        let test = createTestRenderer(width: 10, height: 3)
        defer { test.destroy() }

        let container = Renderable(
            ctx: test.renderer,
            options: RenderableOptions(
                id: "clip",
                width: 4,
                height: 2,
                position: .absolute,
                top: 0,
                left: 1,
                overflow: .hidden
            )
        )
        let oversized = FilledBox(
            ctx: test.renderer,
            fillChar: 0x58, // 'X'
            options: RenderableOptions(id: "wide", width: 8, height: 2, position: .absolute, top: 0, left: 0)
        )
        container.add(oversized)
        test.root.add(container)
        test.renderOnce()

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false)
        // Only columns 1..<5 should contain 'X'
        #expect(String(lines[0]) == " XXXX     ")
        #expect(test.renderer.hitTest(x: 4, y: 0) == oversized.num)
        #expect(test.renderer.hitTest(x: 5, y: 0) == 0)
    }

    @Test("Opacity stack blends renderable colors against destination buffer")
    func opacityCompositing() {
        let test = createTestRenderer(
            width: 4,
            height: 2,
            backgroundColor: RGBA.fromInts(0, 0, 0, 255)
        )
        defer { test.destroy() }

        let overlay = FilledBox(
            ctx: test.renderer,
            fillChar: 0x20,
            fgColor: RGBA.fromInts(255, 255, 255, 255),
            bgColor: RGBA.fromInts(200, 100, 0, 255),
            options: RenderableOptions(id: "overlay", width: 2, height: 1, opacity: 0.5)
        )
        test.root.add(overlay)
        test.renderOnce()

        let cell = test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        let (r, g, b, _) = (cell?.background ?? RGBA.fromInts(0, 0, 0, 0)).toInts()
        #expect(r >= 95 && r <= 105)
        #expect(g >= 45 && g <= 55)
        #expect(b == 0)
    }

    @Test("Buffered renderable draws into offscreen frameBuffer and composites onto destination")
    func bufferedRenderable() {
        let test = createTestRenderer(width: 8, height: 3)
        defer { test.destroy() }

        let bufferedBox = FilledBox(
            ctx: test.renderer,
            fillChar: 0x40, // '@'
            label: "HI",
            options: RenderableOptions(
                id: "buf",
                width: 4,
                height: 2,
                position: .absolute,
                top: 1,
                left: 2,
                buffered: true
            )
        )
        test.root.add(bufferedBox)
        test.renderOnce()

        #expect(bufferedBox.frameBuffer != nil)
        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(String(lines[1]) == "  HI@@  ")
        #expect(String(lines[2]) == "  @@@@  ")
    }

    @Test("Live count propagates to RootRenderable and triggers requestLive / dropLive")
    func liveCountPropagation() {
        let test = createTestRenderer(width: 10, height: 4)
        defer { test.destroy() }

        let box = Renderable(ctx: test.renderer, options: RenderableOptions(id: "live", live: true))
        #expect(test.renderer.liveRequestCount == 0)

        test.root.add(box)
        #expect(test.renderer.liveRequestCount == 1)
        #expect(test.renderer.controlState == .autoStarted)

        box.visible = false
        #expect(test.renderer.liveRequestCount == 0)
        #expect(test.renderer.controlState == .idle)

        box.visible = true
        #expect(test.renderer.liveRequestCount == 1)

        test.root.remove(box)
        #expect(test.renderer.liveRequestCount == 0)
    }

    @Test("Lifecycle passes, renderBefore, renderAfter, onSizeChange, and setRenderableProp work")
    func hooksAndSetProp() {
        let test = createTestRenderer(width: 10, height: 4)
        defer { test.destroy() }

        var order: [String] = []
        var sizeChangedCount = 0

        let node = FilledBox(
            ctx: test.renderer,
            fillChar: 0x2E, // '.'
            options: RenderableOptions(
                id: "hooked",
                width: 5,
                height: 2,
                focusable: true,
                renderBefore: { _, _ in order.append("before") },
                renderAfter: { _, _ in order.append("after") },
                onSizeChange: { sizeChangedCount += 1 },
                onLifecyclePass: { order.append("lifecycle") }
            )
        )
        test.root.add(node)
        test.renderOnce()

        #expect(order == ["lifecycle", "before", "after"])
        #expect(sizeChangedCount == 1)

        setRenderableProp(node, name: "focused", value: true)
        #expect(node.focused)
        #expect(test.renderer.currentFocusedRenderable === node)

        setRenderableProp(node, name: "style", value: ["width": 8, "zIndex": 3], prev: ["width": 5])
        #expect(node.zIndex == 3)
        test.renderOnce()
        #expect(node.width == 8)
        #expect(sizeChangedCount == 2)
    }
}

// MARK: - CliRenderer & TestRenderer Integration Tests

@Suite("CliRenderer & TestRenderer Integration Tests")
struct CliRendererAndTestRendererTests {
    @Test("Frame diffing emits ANSI on first render, empty on no-op frame, and minimal diff on mutation")
    func frameDiffAndCaptureSpans() {
        let test = createTestRenderer(width: 10, height: 3)
        defer { test.destroy() }

        let box = FilledBox(
            ctx: test.renderer,
            fillChar: 0x2A, // '*'
            label: "OK",
            options: RenderableOptions(id: "box", width: 4, height: 1)
        )
        test.root.add(box)
        test.renderOnce()

        #expect(test.outputLog.count == 1)
        #expect(!test.outputLog[0].isEmpty)

        // Identical second frame emits no ANSI diff output
        test.renderOnce()
        #expect(test.outputLog.count == 1)

        // Mutating label triggers new diff output
        box.label = "GO"
        test.renderOnce()
        #expect(test.outputLog.count == 2)

        let spans = test.captureSpans()
        #expect(spans.cols == 10)
        #expect(spans.rows == 3)
        #expect(spans.lines.count == 3)
        #expect(spans.lines[0].spans.map(\.text).joined().hasPrefix("GO**"))
    }

    @Test("MockInput routes standard, Kitty, paste, and Escape timeout events to focused renderable")
    func keyboardAndPasteRouting() {
        let test = createTestRenderer(width: 20, height: 4)
        defer { test.destroy() }

        let inputBox = FilledBox(
            ctx: test.renderer,
            options: RenderableOptions(id: "input", width: 10, height: 1, focusable: true)
        )
        var onKeyDownNames: [String] = []
        inputBox.onKeyDown = { key in
            onKeyDownNames.append(key.name)
            if key.name == "x" {
                key.preventDefault()
            }
        }
        test.root.add(inputBox)
        inputBox.focus()

        test.mockInput.typeText("ax")
        test.mockInput.pressArrow(.right, modifiers: MockKeyModifiers(shift: true))
        test.mockInput.pressEscape()
        test.mockInput.flushTimeouts()
        test.mockInput.pasteBracketedText("hello paste")

        #expect(onKeyDownNames == ["a", "x", "right", "escape"])
        // 'x' called preventDefault(), so handleKeyPress did not receive it
        #expect(inputBox.keyPresses.map(\.name) == ["a", "right", "escape"])
        #expect(inputBox.keyPresses[1].shift == true)
        #expect(inputBox.pastes == ["hello paste"])

        // Kitty keyboard mode test
        let kittyTest = createTestRenderer(width: 20, height: 4, kittyKeyboard: true)
        defer { kittyTest.destroy() }
        let kittyBox = FilledBox(ctx: kittyTest.renderer, options: RenderableOptions(id: "k", focusable: true))
        kittyTest.root.add(kittyBox)
        kittyBox.focus()

        kittyTest.mockInput.pressKey("a", modifiers: MockKeyModifiers(shift: true, ctrl: true))
        kittyTest.mockInput.pressEnter(modifiers: MockKeyModifiers(shift: true))
        #expect(kittyBox.keyPresses.count == 2)
        #expect(kittyBox.keyPresses[0].name == "a")
        #expect(kittyBox.keyPresses[0].ctrl == true)
        #expect(kittyBox.keyPresses[0].shift == true)
        #expect(kittyBox.keyPresses[1].name == "return")
        #expect(kittyBox.keyPresses[1].shift == true)
    }

    @Test("MockMouse drives autoFocus, hover over/out, drag/drop, and scrollOnce chaining")
    func mouseInteractionAndScrollChain() {
        let test = createTestRenderer(width: 20, height: 6)
        defer { test.destroy() }

        let outer = FilledBox(
            ctx: test.renderer,
            fillChar: 0x20,
            options: RenderableOptions(id: "outer", width: 20, height: 6)
        )
        outer.canScroll = true

        let left = FilledBox(
            ctx: test.renderer,
            fillChar: 0x4C,
            options: RenderableOptions(id: "left", width: 6, height: 3, position: .absolute, top: 0, left: 0, focusable: true)
        )
        left.canScroll = true

        let right = FilledBox(
            ctx: test.renderer,
            fillChar: 0x52,
            options: RenderableOptions(id: "right", width: 6, height: 3, position: .absolute, top: 0, left: 8, focusable: true)
        )
        var droppedSourceId: String? = nil
        right.onMouseDrop = { event in
            droppedSourceId = event.source?.id
        }

        outer.add(left)
        outer.add(right)
        test.root.add(outer)
        test.renderOnce()

        // Click left -> autoFocuses left
        test.mockMouse.click(x: 2, y: 1)
        #expect(left.focused)
        #expect(test.renderer.currentFocusedRenderable === left)
        #expect(left.mouseEvents.contains(.down))
        #expect(left.mouseEvents.contains(.up))

        // Hover move from left -> right triggers over/out
        test.mockMouse.moveTo(x: 2, y: 1)
        test.mockMouse.moveTo(x: 10, y: 1)
        #expect(left.mouseEvents.contains(.out))
        #expect(right.mouseEvents.contains(.over))

        // Drag from left -> right delivers dragEnd on left and drop(source: left) on right
        test.mockMouse.drag(startX: 2, startY: 1, endX: 10, endY: 1, steps: 2)
        #expect(left.mouseEvents.contains(.dragEnd))
        #expect(droppedSourceId == "left")

        // Scroll inside left: left consumes scrollOnce, so outer does NOT scroll
        test.mockMouse.scroll(x: 2, y: 1, direction: .down)
        #expect(left.scrollCount == 1)
        #expect(outer.scrollCount == 0)

        // When left cannot scroll, scroll bubbles and outer consumes it
        left.canScroll = false
        test.mockMouse.scroll(x: 2, y: 1, direction: .down)
        #expect(left.scrollCount == 1)
        #expect(outer.scrollCount == 1)
    }

    @Test("Mouse drag starts, updates, finishes, and clears text selection")
    func selectionLifecycle() {
        let test = createTestRenderer(width: 20, height: 4)
        defer { test.destroy() }

        let textBox = FilledBox(
            ctx: test.renderer,
            fillChar: 0x20,
            label: "Hello World",
            options: RenderableOptions(id: "sel", width: 12, height: 1, selectable: true)
        )
        textBox.selectableText = "Hello World"
        test.root.add(textBox)
        test.renderOnce()

        var finishedSelectionText: String? = nil
        _ = test.renderer.onSelection { sel in
            finishedSelectionText = sel.getSelectedText()
        }

        test.mockMouse.drag(startX: 0, startY: 0, endX: 5, endY: 0, steps: 2)
        #expect(test.renderer.hasSelection)
        #expect(finishedSelectionText == "Hello World")
        #expect(test.renderer.getSelection()?.getSelectedText() == "Hello World")
        #expect(test.renderer.getSelection()?.behavior == .cell)

        test.renderer.clearSelection()
        #expect(!test.renderer.hasSelection)
        #expect(!textBox.hasSelection())
    }

    @Test("Resize, debounced requestResize, suspend/resume, themeMode input, cursor, and TestRecorder")
    func lifecycleResizeThemeAndRecorder() {
        let test = createTestRenderer(width: 12, height: 4)
        defer { test.destroy() }

        var resizeHistory: [(Int, Int)] = []
        _ = test.renderer.onResize { w, h in
            resizeHistory.append((w, h))
        }

        var detectedModes: [ThemeMode] = []
        _ = test.renderer.onThemeMode { mode in
            detectedModes.append(mode)
        }

        test.recorder.rec()
        #expect(test.recorder.isRecording)

        let box = FilledBox(
            ctx: test.renderer,
            fillChar: 0x2B, // '+'
            options: RenderableOptions(id: "grow", width: .percent(100), height: 2)
        )
        test.root.add(box)
        test.renderer.setCursorPosition(x: 3, y: 2, visible: true)
        test.renderer.setCursorStyle(CursorStyleOptions(style: .line, blinking: true))
        test.renderOnce()

        #expect(box.width == 12)
        #expect(test.renderer.getCursorState().x == 3)
        #expect(test.renderer.getCursorState().y == 2)
        #expect(test.renderer.getCursorState().style == .line)
        #expect(test.recorder.recordedFrames.count == 1)

        // Immediate resize
        test.resize(width: 20, height: 5)
        test.renderOnce()
        #expect(box.width == 20)
        #expect(resizeHistory.count == 1)
        #expect(resizeHistory[0] == (20, 5))
        #expect(test.recorder.recordedFrames.count == 2)

        // Debounced resize via ManualClock
        test.renderer.requestResize(width: 16, height: 6)
        #expect(test.renderer.width == 20)
        test.advanceClock(by: 100)
        #expect(test.renderer.width == 16)
        #expect(test.renderer.height == 6)

        // Theme mode OSC 11 through feedInput
        test.renderer.feedInput("\u{1B}]11;#1e1e1e\u{07}")
        #expect(test.renderer.themeMode == .dark)
        #expect(detectedModes == [.dark])

        // Suspend / resume
        test.renderer.start()
        #expect(test.renderer.isRunning)
        test.renderer.suspend()
        #expect(test.renderer.controlState == .explicitSuspended)
        #expect(!test.renderer.isRunning)
        test.renderer.resume()
        #expect(test.renderer.controlState == .explicitStarted)
        #expect(test.renderer.isRunning)
        test.renderer.pause()
        #expect(test.renderer.controlState == .explicitPaused)
        test.renderer.stop()
        #expect(test.renderer.controlState == .explicitStopped)

        // Palette retrieval
        let palette = test.renderer.getPalette(options: GetPaletteOptions(size: 16))
        #expect(palette.palette.count == 16)

        test.recorder.stop()
        #expect(!test.recorder.isRecording)
    }
}
