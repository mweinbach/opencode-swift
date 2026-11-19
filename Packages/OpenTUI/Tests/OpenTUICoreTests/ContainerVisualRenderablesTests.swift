import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Helper Renderable for Scroll/Layout Verification

private final class MarkerChild: Renderable, @unchecked Sendable {
    let label: String
    var renderCount: Int = 0
    var bg: RGBA

    init(
        ctx: any RenderContext,
        id: String? = nil,
        label: String,
        width: FlexValue = .point(10),
        height: FlexValue = .point(1),
        bg: RGBA = RGBA.fromInts(0, 0, 0, 255)
    ) {
        self.label = label
        self.bg = bg
        super.init(
            ctx: ctx,
            options: RenderableOptions(
                id: id,
                width: width,
                height: height,
                flexShrink: 0
            )
        )
    }

    override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        renderCount += 1
        guard width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        buffer.drawText(
            label,
            x: origin.x,
            y: origin.y,
            fg: RGBA.fromInts(255, 255, 255, 255),
            bg: bg
        )
    }
}

// MARK: - Container & Visual Renderables Test Suite

@Suite("Container & Visual Renderables (Phase 3B)")
struct ContainerVisualRenderablesTests {

    // MARK: 1. BoxRenderable

    @Test("BoxRenderable renders borders, titles, background fill, and insets children")
    func boxRenderableBordersTitlesAndChildInset() {
        let test = createTestRenderer(width: 20, height: 6)
        defer { test.destroy() }

        let box = BoxRenderable(
            ctx: test.renderer,
            options: BoxOptions(
                id: "panel",
                width: .point(16),
                height: .point(5),
                backgroundColor: "#102030",
                borderStyle: .rounded,
                border: .enabled(true),
                borderColor: "#CCCCCC",
                title: "Info",
                titleAlignment: .center,
                bottomTitle: "OK",
                bottomTitleAlignment: .right
            )
        )

        let child = MarkerChild(ctx: test.renderer, label: "HELLO", width: .point(5), height: .point(1))
        box.add(child)
        test.root.add(box)
        test.renderOnce()

        // Child must be inset by 1 cell on left & top due to border synchronization into layoutNode
        #expect(child.screenX == 1)
        #expect(child.screenY == 1)

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("╭"))
        #expect(lines[0].contains("Info"))
        #expect(lines[0].contains("╮"))
        #expect(lines[1].contains("│HELLO"))
        #expect(lines[4].hasPrefix("╰"))
        #expect(lines[4].contains("OK"))
        #expect(lines[4].contains("╯"))
    }

    @Test("BoxRenderable auto-enables border, switches focused border color, and supports partial sides & custom chars")
    func boxRenderableAutoBorderFocusAndCustomChars() {
        let test = createTestRenderer(width: 12, height: 4)
        defer { test.destroy() }

        let box = BoxRenderable(
            ctx: test.renderer,
            options: BoxOptions(
                width: .point(10),
                height: .point(4),
                focusable: true,
                borderColor: "#112233",
                focusedBorderColor: "#FF00AA"
            )
        )
        #expect(box.border == .enabled(true))
        test.root.add(box)
        test.renderOnce()

        let unfocusedCell = test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        #expect(unfocusedCell?.foreground == RGBA.fromHex("#112233"))

        box.focus()
        test.renderOnce()
        let focusedCell = test.renderer.currentRenderBuffer.cell(atX: 0, y: 0)
        #expect(focusedCell?.foreground == RGBA.fromHex("#FF00AA"))

        // Partial border sides & custom chars
        box.border = .sides([.top, .left])
        box.customBorderChars = BorderCharacters(
            topLeft: "+", topRight: "+", bottomLeft: "+", bottomRight: "+",
            horizontal: "-", vertical: "|",
            topT: "+", bottomT: "+", leftT: "+", rightT: "+", cross: "+"
        )
        test.renderOnce()

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("+---------"))
        #expect(lines[1].hasPrefix("|"))
        #expect(box.layoutNode.style.border.bottom == .point(0))
        #expect(box.layoutNode.style.border.right == .point(0))
        #expect(box.layoutNode.style.border.top == .point(1))
        #expect(box.layoutNode.style.border.left == .point(1))

        // Gap passthrough
        box.setGap(.point(2))
        #expect(box.gap == .point(2))
        box.setRowGap(.point(3))
        #expect(box.rowGap == .point(3))
        box.setColumnGap(.point(4))
        #expect(box.columnGap == .point(4))
    }

    // MARK: 2. SliderRenderable

    @Test("SliderRenderable renders half-block precision thumbs horizontally and vertically")
    func sliderRenderableHalfBlockRendering() {
        let test = createTestRenderer(width: 20, height: 10)
        defer { test.destroy() }

        let hSlider = SliderRenderable(
            ctx: test.renderer,
            options: SliderOptions(
                orientation: .horizontal,
                width: .point(10),
                height: .point(1),
                value: 25,
                min: 0,
                max: 100,
                viewPortSize: 25
            )
        )
        let vSlider = SliderRenderable(
            ctx: test.renderer,
            options: SliderOptions(
                orientation: .vertical,
                width: .point(1),
                height: .point(6),
                value: 50,
                min: 0,
                max: 100,
                viewPortSize: 20
            )
        )

        test.root.add(hSlider)
        test.root.add(vSlider)
        test.renderOnce()

        let frame = test.captureCharFrame()
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Horizontal slider uses full block or left/right half blocks
        let hLine = String(lines[0].prefix(10))
        #expect(hLine.contains("█") || hLine.contains("▌") || hLine.contains("▐"))

        // Vertical slider thumb occupies rows 1..6 in column 0
        var verticalThumbChars = ""
        for r in 1..<7 {
            if let ch = lines[r].first {
                verticalThumbChars.append(ch)
            }
        }
        #expect(verticalThumbChars.contains("█") || verticalThumbChars.contains("▀") || verticalThumbChars.contains("▄"))
    }

    @Test("SliderRenderable handles track click jump, thumb drag, clamping, and onChange")
    func sliderRenderableMouseInteraction() {
        let test = createTestRenderer(width: 20, height: 4)
        defer { test.destroy() }

        var reported: [Double] = []
        let slider = SliderRenderable(
            ctx: test.renderer,
            options: SliderOptions(
                orientation: .horizontal,
                width: .point(10),
                height: .point(1),
                value: 0,
                min: 0,
                max: 100,
                viewPortSize: 20,
                onChange: { reported.append($0) }
            )
        )
        test.root.add(slider)
        test.renderOnce()

        // Click near right side of track -> jumps directly
        test.mockMouse.click(x: 8, y: 0)
        #expect(slider.value == 80)
        #expect(reported.last == 80)

        // Drag from current thumb position back toward left
        test.mockMouse.drag(startX: 8, startY: 0, endX: 2, endY: 0, steps: 3)
        #expect(slider.value < 50)
        #expect(reported.count >= 2)

        // Min/max clamping
        slider.value = 500
        #expect(slider.value == 100)
        slider.value = -50
        #expect(slider.value == 0)
    }

    // MARK: 3. ScrollBarRenderable & ArrowRenderable

    @Test("ScrollBarRenderable composes slider + arrows, auto-visibility, keyboard, units, and arrow repeat")
    func scrollBarRenderableFullBehavior() {
        let test = createTestRenderer(width: 10, height: 12)
        defer { test.destroy() }

        var changes: [Int] = []
        let bar = ScrollBarRenderable(
            ctx: test.renderer,
            options: ScrollBarOptions(
                orientation: .vertical,
                width: .point(1),
                height: .point(10),
                showArrows: true,
                scrollStep: 3,
                onChange: { changes.append($0) }
            )
        )
        test.root.add(bar)

        // Auto-visibility: hidden when scrollSize <= viewportSize, visible when scrollSize > viewportSize
        bar.viewportSize = 10
        bar.scrollSize = 10
        #expect(bar.visible == false)

        bar.scrollSize = 50
        #expect(bar.visible == true)

        test.renderOnce()
        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("▲"))
        #expect(lines[9].hasPrefix("▼"))

        // Scroll units
        bar.scrollBy(2, unit: .step)
        #expect(bar.scrollPosition == 6)
        bar.scrollBy(1, unit: .viewport)
        #expect(bar.scrollPosition == 16)
        bar.scrollBy(1, unit: .content)
        #expect(bar.scrollPosition == 40) // clamped to scrollSize - viewportSize
        bar.scrollBy(-1, unit: .content)
        #expect(bar.scrollPosition == 0)
        #expect(!changes.isEmpty)

        // Keyboard navigation
        bar.focus()
        test.mockInput.pressArrow(.down) // 1/5 viewport = 2
        #expect(bar.scrollPosition == 2)
        test.mockInput.pressKey(KeyCodes.end)
        #expect(bar.scrollPosition == 40)
        test.mockInput.pressKey(KeyCodes.home)
        #expect(bar.scrollPosition == 0)

        // Arrow press + hold repeat via deterministic ManualClock
        test.renderOnce()
        test.mockMouse.pressDown(x: 0, y: 9) // endArrow (down): immediate 0.5 viewport = 5
        #expect(bar.scrollPosition == 5)
        test.advanceClock(by: 500) // after 500ms: +0.5 viewport = 10
        #expect(bar.scrollPosition == 10)
        test.advanceClock(by: 200) // repeat every 200ms: +0.2 viewport = 12
        #expect(bar.scrollPosition == 12)
        test.mockMouse.release(x: 0, y: 9)
        test.advanceClock(by: 600) // stopped repeating
        #expect(bar.scrollPosition == 12)

        // Manual visibility override & resetVisibilityControl
        bar.visible = false
        bar.scrollSize = 100
        #expect(bar.visible == false)
        bar.resetVisibilityControl()
        #expect(bar.visible == true)
    }

    // MARK: 4. ScrollBoxRenderable

    @Test("ScrollBoxRenderable scrolls, scissor-clips, culls offscreen children, and pins sticky bottom")
    func scrollBoxScrollingClippingCullingAndSticky() {
        let test = createTestRenderer(width: 24, height: 10)
        defer { test.destroy() }

        let scrollBox = ScrollBoxRenderable(
            ctx: test.renderer,
            options: ScrollBoxOptions(
                id: "scroller",
                width: .point(20),
                height: .point(8),
                borderStyle: .single,
                border: .enabled(true),
                stickyScroll: true,
                stickyStart: .bottom,
                scrollY: true,
                viewportCulling: true
            )
        )

        var items: [MarkerChild] = []
        for i in 0..<25 {
            let item = MarkerChild(
                ctx: test.renderer,
                id: "row-\(i)",
                label: "ROW-\(i < 10 ? "0" : "")\(i)",
                width: .point(16),
                height: .point(1)
            )
            items.append(item)
            scrollBox.content.add(item)
        }

        test.root.add(scrollBox)
        test.renderOnce()

        // Viewport height = 8 - 2 (borders) = 6; scrollHeight = 25; sticky bottom -> scrollTop = 19
        #expect(scrollBox.viewport.height == 6)
        #expect(scrollBox.scrollHeight == 25)
        #expect(scrollBox.scrollTop == 19)
        #expect(scrollBox.verticalScrollBar.visible == true)

        // Viewport culling: only visible rows (19..24) rendered, row 0 was culled
        #expect(items[0].renderCount == 0)
        #expect(items[24].renderCount == 1)

        // Frame shows bottom rows clipped cleanly inside borders
        let frameBottom = test.captureCharFrame()
        #expect(frameBottom.contains("ROW-24"))
        #expect(!frameBottom.contains("ROW-00"))

        // Adding another row while stuck at bottom keeps pinned to new bottom
        let extra = MarkerChild(ctx: test.renderer, id: "row-25", label: "ROW-25", width: .point(16), height: .point(1))
        scrollBox.add(extra)
        test.renderOnce()
        #expect(scrollBox.scrollTop == 20)
        #expect(test.captureCharFrame().contains("ROW-25"))

        // Scrolling to top unsticks and reveals ROW-00
        scrollBox.scrollTo(0)
        test.renderOnce()
        #expect(scrollBox.scrollTop == 0)
        let frameTop = test.captureCharFrame()
        #expect(frameTop.contains("ROW-00"))
        #expect(!frameTop.contains("ROW-25"))

        // Scroll child into view
        scrollBox.scrollChildIntoView("row-15", options: ScrollIntoViewOptions(align: .start))
        test.renderOnce()
        #expect(scrollBox.scrollTop == 15)
    }

    @Test("ScrollBoxRenderable wheel chaining, acceleration, keyboard navigation, and afterLayout")
    func scrollBoxWheelChainingAndKeyboard() {
        let test = createTestRenderer(width: 24, height: 12)
        defer { test.destroy() }

        let outer = ScrollBoxRenderable(
            ctx: test.renderer,
            options: ScrollBoxOptions(
                id: "outer",
                width: .point(22),
                height: .point(10),
                scrollY: true,
                scrollAcceleration: MacOSScrollAccel()
            )
        )
        let inner = ScrollBoxRenderable(
            ctx: test.renderer,
            options: ScrollBoxOptions(
                id: "inner",
                width: .point(20),
                height: .point(5),
                scrollY: true
            )
        )

        for i in 0..<8 {
            inner.add(MarkerChild(ctx: test.renderer, label: "IN-\(i)", width: .point(18), height: .point(1)))
        }
        outer.add(inner)
        for i in 0..<15 {
            outer.add(MarkerChild(ctx: test.renderer, label: "OUT-\(i)", width: .point(18), height: .point(1)))
        }

        var afterLayoutFired = 0
        outer.afterLayout {
            afterLayoutFired += 1
        }

        test.root.add(outer)
        test.renderOnce()
        #expect(afterLayoutFired == 1)

        // Wheel down inside inner: inner consumes while it can scroll, outer stays at 0
        test.mockMouse.scroll(x: 2, y: 2, direction: .down)
        #expect(inner.scrollTop == 1)
        #expect(outer.scrollTop == 0)

        // Push inner to bottom (maxScrollY = 8 - 5 = 3)
        inner.scrollTop = 3
        test.renderOnce()

        // Next wheel down inside inner bubbles to outer because inner is at its bottom edge!
        test.mockMouse.scroll(x: 2, y: 2, direction: .down)
        #expect(outer.scrollTop > 0)

        // Keyboard navigation when focused
        outer.focus()
        let beforeKey = outer.scrollTop
        test.mockInput.pressArrow(.down)
        #expect(outer.scrollTop > beforeKey)
        test.mockInput.pressKey(KeyCodes.home)
        #expect(outer.scrollTop == 0)
    }

    // MARK: 5. FrameBufferRenderable

    @Test("FrameBufferRenderable blits offscreen buffer, respects alpha, and resizes")
    func frameBufferRenderableBlitAndResize() {
        let test = createTestRenderer(width: 20, height: 6)
        defer { test.destroy() }

        let bgBox = BoxRenderable(
            ctx: test.renderer,
            options: BoxOptions(
                width: .point(20),
                height: .point(6),
                backgroundColor: "#223344",
                shouldFill: true
            )
        )
        let fbNode = FrameBufferRenderable(
            ctx: test.renderer,
            options: FrameBufferOptions(
                width: 8,
                height: 3,
                respectAlpha: true,
                position: .absolute,
                top: .point(1),
                left: .point(2)
            )
        )

        fbNode.frameBuffer?.clear(bg: RGBA.fromValues(0, 0, 0, 0), char: defaultSpaceChar)
        fbNode.frameBuffer?.drawText("PIXELS", x: 1, y: 1, fg: RGBA.fromHex("#00FF00"))

        test.root.add(bgBox)
        test.root.add(fbNode)
        test.renderOnce()

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[2].contains("PIXELS"))
        // Transparent cells in fbNode preserve bgBox background
        let cell = test.renderer.currentRenderBuffer.cell(atX: 2, y: 1)
        #expect(cell?.background == RGBA.fromHex("#223344"))

        // Resize synchronizes underlying OptimizedBuffer
        fbNode.width = 12
        fbNode.height = 4
        test.renderOnce()
        #expect(fbNode.frameBuffer?.width == 12)
        #expect(fbNode.frameBuffer?.height == 4)
    }

    // MARK: 6. ASCIIFontRenderable

    @Test("ASCIIFontRenderable renders banner glyphs and supports mouse range selection")
    func asciiFontRenderableAndSelection() {
        let test = createTestRenderer(width: 40, height: 8)
        defer { test.destroy() }

        let banner = ASCIIFontRenderable(
            ctx: test.renderer,
            options: ASCIIFontOptions(
                text: "HI",
                font: .tiny,
                color: "#00FFAA",
                selectionBg: "#334455",
                selectionFg: "#FFFFFF"
            )
        )
        let expectedSize = measureAsciiText("HI", font: .tiny)
        #expect(banner.width == expectedSize.width)
        #expect(banner.height == expectedSize.height)

        test.root.add(banner)
        test.renderOnce()

        let frame = test.captureCharFrame()
        #expect(frame.contains("█") || frame.contains("▀") || frame.contains("▄"))

        // Drag selection across the full banner
        #expect(banner.shouldStartSelection(x: 0, y: 0) == true)
        test.mockMouse.drag(startX: 0, startY: 0, endX: banner.width - 1, endY: 0, steps: 2)
        #expect(banner.hasSelection() == true)
        #expect(banner.getSelectedText() == "HI")

        // Updating text updates dimensions on layout
        banner.text = "OPEN"
        test.renderOnce()
        let nextSize = measureAsciiText("OPEN", font: .tiny)
        #expect(banner.width == nextSize.width)
        #expect(banner.height == nextSize.height)
    }

    // MARK: 7. QRCodeRenderable

    @Test("QRCodeRenderable encodes, sizes intrinsically, renders half-blocks, and falls back when constrained")
    func qrCodeRenderableSizingRenderingAndFallback() {
        let test = createTestRenderer(width: 40, height: 24)
        defer { test.destroy() }

        let qr = QRCodeRenderable(
            ctx: test.renderer,
            options: QRCodeOptions(
                content: "OPENTUI",
                errorCorrectionLevel: .M,
                quietZone: 4,
                scale: 1,
                fit: .contain,
                fg: "#000000",
                bg: "#FFFFFF",
                alignSelf: .flexStart
            )
        )
        test.root.add(qr)
        test.renderOnce()

        // Version 1 QR code has 21 modules; + 2*4 quiet zone = 29 cols x ceil(29/2) = 15 rows
        #expect(qr.version == 1)
        #expect(qr.moduleCount == 21)
        #expect(qr.width == 29)
        #expect(qr.height == 15)

        let frame = test.captureCharFrame()
        #expect(frame.contains("█"))
        #expect(frame.contains("▀") || frame.contains("▄"))

        // Invert swaps dark/light polarity
        qr.invert = true
        test.renderOnce()
        let invertedFrame = test.captureCharFrame()
        #expect(invertedFrame != frame)
        // Top-left quiet-zone corner becomes dark ('█') when inverted
        #expect(invertedFrame.first == "█")

        // Fallback when container is too small to fit scale >= 1
        let small = createTestRenderer(width: 10, height: 4)
        defer { small.destroy() }

        let fallbackQR = QRCodeRenderable(
            ctx: small.renderer,
            options: QRCodeOptions(
                content: "OPENTUI",
                fit: .contain,
                fallbackContent: "SCAN-URL"
            )
        )
        small.root.add(fallbackQR)
        small.renderOnce()
        #expect(small.captureCharFrame().contains("SCAN-URL"))
    }

    // MARK: 8. TimeToFirstDrawRenderable

    @Test("TimeToFirstDrawRenderable captures first draw time, locks it, formats decimals, and resets")
    func timeToFirstDrawRenderableTimingAndReset() {
        let test = createTestRenderer(width: 40, height: 3)
        defer { test.destroy() }

        let ttfd = TimeToFirstDrawRenderable(
            ctx: test.renderer,
            options: TimeToFirstDrawOptions(
                fg: "#CCCCCC",
                label: "First paint",
                precision: 2
            )
        )
        // Advance deterministic clock to 37ms before adding & drawing
        test.advanceClock(by: 37)
        test.root.add(ttfd)
        #expect(ttfd.runtimeMs == nil)
        test.renderOnce()

        #expect(ttfd.runtimeMs == 37.0)
        #expect(test.captureCharFrame().contains("First paint: 37.00ms"))

        // Subsequent draws keep locked first-draw timing
        test.advanceClock(by: 100)
        test.renderOnce()
        #expect(ttfd.runtimeMs == 37.0)
        #expect(test.captureCharFrame().contains("First paint: 37.00ms"))

        // Precision & label updates + reset re-captures current clock time
        ttfd.decimals = 0
        ttfd.textLabel = "Boot"
        test.renderOnce()
        #expect(test.captureCharFrame().contains("Boot: 37ms"))

        ttfd.reset()
        #expect(ttfd.runtimeMs == nil)
        test.renderOnce()
        #expect(ttfd.runtimeMs == 137.0)
        #expect(test.captureCharFrame().contains("Boot: 137ms"))
    }

    @Test("ScrollBoxRenderable supports horizontal scrolling, Shift+wheel axis swap, anchor, and bar drag/arrow clicks")
    func scrollBoxHorizontalAnchorAndBarInteraction() {
        let test = createTestRenderer(width: 24, height: 10)
        defer { test.destroy() }

        let scrollBox = ScrollBoxRenderable(
            ctx: test.renderer,
            options: ScrollBoxOptions(
                id: "h-and-v",
                width: .point(12),
                height: .point(6),
                verticalScrollbarOptions: ScrollBarOptions(orientation: .vertical, showArrows: true),
                scrollX: true,
                scrollY: true
            )
        )
        let anchoredItem = MarkerChild(ctx: test.renderer, id: "anchor-target", label: "ANCHOR-ROW", width: .point(24), height: .point(1))
        for i in 0..<4 {
            scrollBox.add(MarkerChild(ctx: test.renderer, label: "PRE-\(i)-LONG-CONTENT-XYZ", width: .point(24), height: .point(1)))
        }
        scrollBox.add(anchoredItem)
        for i in 0..<8 {
            scrollBox.add(MarkerChild(ctx: test.renderer, label: "POST-\(i)-LONG-CONTENT-XYZ", width: .point(24), height: .point(1)))
        }

        test.root.add(scrollBox)
        test.renderOnce()

        #expect(scrollBox.scrollWidth == 24)
        #expect(scrollBox.horizontalScrollBar.visible == true)
        #expect(scrollBox.verticalScrollBar.visible == true)

        // Shift + wheel down converts to horizontal right scroll via wheelDirection
        test.mockMouse.scroll(x: 2, y: 2, direction: .down, modifiers: MouseModifiers(shift: true))
        #expect(scrollBox.scrollLeft == 1)

        // Anchor holds anchoredItem at its viewport-relative row even when a new row is inserted before it
        scrollBox.scrollTop = 2
        test.renderOnce()
        let beforeScreenY = anchoredItem.screenY
        let releaseAnchor = scrollBox.anchor(anchoredItem)
        let insertedAbove = MarkerChild(ctx: test.renderer, label: "INSERTED", width: .point(24), height: .point(1))
        scrollBox.insertBefore(insertedAbove, anchor: anchoredItem)
        test.renderOnce()
        #expect(anchoredItem.screenY == beforeScreenY)
        releaseAnchor()

        // Clicking vertical bar's down arrow scrolls down by 0.5 viewport
        let prevTop = scrollBox.scrollTop
        test.mockMouse.click(x: 11, y: 5)
        #expect(scrollBox.scrollTop > prevTop)
    }

    @Test("ArrowRenderable renders directional glyphs and custom arrowChars")
    func arrowRenderableCustomGlyphs() {
        let test = createTestRenderer(width: 8, height: 2)
        defer { test.destroy() }

        let arrow = ArrowRenderable(
            ctx: test.renderer,
            options: ArrowOptions(
                direction: .left,
                height: .point(1),
                arrowChars: ArrowChars(left: "<", right: ">")
            )
        )
        test.root.add(arrow)
        test.renderOnce()
        #expect(test.captureCharFrame().hasPrefix("<"))

        arrow.direction = .right
        test.renderOnce()
        #expect(test.captureCharFrame().hasPrefix(">"))
    }
}
