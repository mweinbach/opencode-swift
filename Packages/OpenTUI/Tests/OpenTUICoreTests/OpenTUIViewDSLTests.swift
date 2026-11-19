import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUITerminal
import OpenTUIView
import Synchronization
import Testing

// MARK: - Helpers

private func waitUntil(
    timeoutMs: Int = 2_000,
    pollMs: Int = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
    while !condition() {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return true
}

private func substringOffset(of needle: String, in haystack: String) -> Int? {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty, n.count <= h.count else { return nil }
    for i in 0...(h.count - n.count) {
        var matched = true
        for j in 0..<n.count {
            if h[i + j] != n[j] {
                matched = false
                break
            }
        }
        if matched { return i }
    }
    return nil
}

private struct IdentifiableItem: Identifiable, Sendable {
    let id: String
    var label: String
}

private final class CustomBadgeRenderable: Renderable, @unchecked Sendable {
    var badgeText: String {
        didSet {
            if badgeText != oldValue {
                requestRender()
            }
        }
    }

    init(ctx: any RenderContext, text: String) {
        self.badgeText = text
        super.init(ctx: ctx, options: RenderableOptions(height: .point(1)))
    }

    override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard width > 0 && height > 0 else { return }
        let origin = paintOrigin(for: buffer)
        buffer.drawText("[\(badgeText)]", x: origin.x, y: origin.y, fg: RGBA.fromHex("#00FF88"))
    }
}

private struct CompositeHeaderView: TUIView {
    let title: String
    let subtitle: String?

    var body: some TUIView {
        VStack(spacing: 0) {
            TUIText(title, attributes: TextAttributes.bold)
                .id("header-title")
            if let subtitle {
                TUIText(subtitle)
                    .id("header-subtitle")
            }
        }
    }
}

// MARK: - 1. Declarative Layout & ResultBuilder Tests

@Suite("OpenTUIViewDSL")
struct OpenTUIViewDSLTests {
    @Test("Composes VStack, HStack, TUIBox, TUIText, TUISpacer, conditionals, and TUIForEach")
    func declarativeLayoutComposition() {
        let test = createTestRenderer(width: 44, height: 16)
        defer { test.destroy() }

        let items = [
            IdentifiableItem(id: "a", label: "Alpha"),
            IdentifiableItem(id: "b", label: "Beta"),
            IdentifiableItem(id: "c", label: "Gamma"),
        ]
        let showWarning = true
        let useAltBranch = false

        let viewRoot = test.mountView {
            VStack(spacing: 1) {
                CompositeHeaderView(title: "OPENTUI SWIFT", subtitle: "Declarative DSL")

                TUIBox(border: true, borderStyle: .single, title: "Items", titleAlignment: .left) {
                    VStack(spacing: 0) {
                        TUIForEach(items) { item in
                            HStack(spacing: 1) {
                                TUIText("- \(item.label)")
                                TUISpacer()
                                TUIText("OK")
                            }
                            .width(.percent(100))
                        }
                    }
                }
                .width(36)
                .height(6)

                if showWarning {
                    TUIText("STATUS: ACTIVE")
                }

                if useAltBranch {
                    TUIText("BRANCH-A")
                } else {
                    TUIText("BRANCH-B")
                }

                TUIGroup {
                    for index in 0..<2 {
                        TUIText("Loop-\(index)")
                    }
                }
            }
            .width(.percent(100))
            .height(.percent(100))
        }

        test.renderOnce(force: true)
        let frame = test.captureCharFrame()

        #expect(viewRoot.isMounted)
        #expect(frame.contains("OPENTUI SWIFT"))
        #expect(frame.contains("Declarative DSL"))
        #expect(frame.contains("Items"))
        #expect(frame.contains("┌"))
        #expect(frame.contains("└"))
        #expect(frame.contains("- Alpha"))
        #expect(frame.contains("- Beta"))
        #expect(frame.contains("- Gamma"))
        #expect(frame.contains("OK"))
        #expect(frame.contains("STATUS: ACTIVE"))
        #expect(frame.contains("BRANCH-B"))
        #expect(!frame.contains("BRANCH-A"))
        #expect(frame.contains("Loop-0"))
        #expect(frame.contains("Loop-1"))

        // Verify TUISpacer pushed "OK" to the right edge inside the 36-wide bordered box (inner width = 34)
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let alphaLine = lines.first { $0.contains("- Alpha") }
        #expect(alphaLine != nil)
        if let alphaLine {
            let alphaPos = substringOffset(of: "- Alpha", in: alphaLine)
            let okPos = substringOffset(of: "OK", in: alphaLine)
            #expect(alphaPos != nil && okPos != nil)
            if let alphaPos, let okPos {
                #expect(okPos - alphaPos > 15)
            }
        }
    }

    @Test("Supports StyledText in TUIText, KeyPath TUIForEach, TUIGroup modifier propagation, and alignment-first stacks")
    func styledTextKeyPathForEachAndGroupModifiers() throws {
        let test = createTestRenderer(width: 40, height: 10)
        defer { test.destroy() }

        struct Metric {
            let code: String
            let value: Int
        }
        let metrics = [
            Metric(code: "CPU", value: 42),
            Metric(code: "MEM", value: 68),
        ]
        let rich = StyledText(chunks: [
            TextChunk(text: "OK: ", fg: RGBA.fromHex("#00FF00")),
            TextChunk(text: "Healthy", fg: RGBA.fromHex("#FFFFFF")),
        ])

        let root = test.mountView {
            VStack(alignment: .flexStart, spacing: 0) {
                TUIText(rich)
                    .id("rich-text")

                TUIGroup {
                    TUIForEach(metrics, id: \.code) { metric in
                        HStack(alignment: .center, spacing: 1) {
                            TUIText(metric.code)
                            TUIText("\(metric.value)%")
                        }
                        .id("metric-\(metric.code)")
                    }
                }
                .opacity(0.9)
            }
            .width(.percent(100))
        }

        test.renderOnce(force: true)
        let frame = test.captureCharFrame()
        #expect(frame.contains("OK: Healthy"))
        #expect(frame.contains("CPU 42%"))
        #expect(frame.contains("MEM 68%"))

        let cpuRow = try #require(root.findRenderable(id: "metric-CPU"))
        let memRow = try #require(root.findRenderable(id: "metric-MEM"))
        #expect(cpuRow.opacity == 0.9)
        #expect(memRow.opacity == 0.9)
    }

    @Test("ZStack overlays layers in painter order with optional explicit positioning")
    func zStackOverlayComposition() {
        let test = createTestRenderer(width: 30, height: 6)
        defer { test.destroy() }

        _ = test.mountView {
            ZStack {
                TUIBox(border: true, backgroundColor: "#101020") {
                    TUIText("BASE-LAYER")
                }
                .width(24)
                .height(5)

                TUIText("OVERLAY")
                    .position(.absolute, top: 2, left: 6)
                    .zIndex(5)
            }
            .width(24)
            .height(5)
        }

        test.renderOnce(force: true)
        let frame = test.captureCharFrame()
        #expect(frame.contains("BASE-LAYER"))
        #expect(frame.contains("OVERLAY"))
    }

    @Test("TUICustomRenderable mounts and patches arbitrary Renderable subclasses")
    func customRenderableEscapeHatch() throws {
        let test = createTestRenderer(width: 30, height: 5)
        defer { test.destroy() }

        final class Model {
            var label = "v1"
        }
        let model = Model()

        let root = test.mountView {
            VStack {
                TUICustomRenderable(
                    kind: "badge",
                    make: { ctx in CustomBadgeRenderable(ctx: ctx, text: model.label) },
                    update: { badge in badge.badgeText = model.label }
                )
                .id("my-badge")
                .width(12)
            }
        }

        test.renderOnce(force: true)
        #expect(test.captureCharFrame().contains("[v1]"))

        let firstInstance = try #require(root.findRenderable(id: "my-badge") as? CustomBadgeRenderable)
        model.label = "v2"
        root.invalidate(renderNow: true)

        let secondInstance = try #require(root.findRenderable(id: "my-badge") as? CustomBadgeRenderable)
        #expect(firstInstance === secondInstance)
        #expect(test.captureCharFrame().contains("[v2]"))
    }

    @Test("Modifiers apply sizing, flex, appearance, visibility, and reset cleanly when removed")
    func modifierApplicationAndReset() throws {
        let test = createTestRenderer(width: 40, height: 10)
        defer { test.destroy() }

        final class State {
            var styled = true
            var visible = true
        }
        let state = State()

        let root = test.mountView {
            VStack {
                if state.styled {
                    TUIText("Styled")
                        .id("target")
                        .width(20)
                        .height(3)
                        .padding(top: 1, right: 2, bottom: 1, left: 2)
                        .margin(1)
                        .foreground("#00FF00")
                        .background("#220033")
                        .opacity(0.5)
                        .zIndex(7)
                        .visible(state.visible)
                        .overflow(.hidden)
                } else {
                    TUIText("Styled")
                        .id("target")
                }
            }
        }

        test.renderOnce(force: true)
        let node = try #require(root.findRenderable(id: "target") as? TextRenderable)
        #expect(node.widthStyle == .point(20))
        #expect(node.heightStyle == .point(3))
        #expect(node.paddingTop == .point(1))
        #expect(node.paddingLeft == .point(2))
        #expect(node.margin == .point(1))
        #expect(node.fg == parseColor("#00FF00"))
        #expect(node.bg == parseColor("#220033"))
        #expect(node.opacity == 0.5)
        #expect(node.zIndex == 7)
        #expect(node.visible == true)
        #expect(node.overflow == .hidden)

        // Toggle visibility off
        state.visible = false
        root.invalidate(renderNow: true)
        #expect(node.visible == false)
        #expect(!test.captureCharFrame().contains("Styled"))

        // Remove modifiers -> reconciled node resets removed slots back to defaults
        state.styled = false
        root.invalidate(renderNow: true)
        let sameNode = try #require(root.findRenderable(id: "target") as? TextRenderable)
        #expect(sameNode === node)
        #expect(sameNode.visible == true)
        #expect(sameNode.opacity == 1.0)
        #expect(sameNode.zIndex == 0)
        #expect(sameNode.overflow == .visible)
        #expect(sameNode.paddingTop == .undefined)
        #expect(sameNode.margin == .undefined)
        #expect(test.captureCharFrame().contains("Styled"))
    }
}

// MARK: - 2. ViewReconciler Identity, State Preservation & Diffing Tests

@Suite("ViewReconciler")
struct ViewReconcilerTests {
    @Test("Keyed TUIInput preserves Renderable identity, focus, text, and cursor offset across re-renders")
    func keyedInputPreservesStateAcrossRerenders() throws {
        let test = createTestRenderer(width: 50, height: 10)
        defer { test.destroy() }

        final class AppState {
            var counter = 0
            var showBannerAbove = false
        }
        let state = AppState()

        let root = test.mountView {
            VStack(spacing: 0) {
                if state.showBannerAbove {
                    TUIText("ALERT BANNER")
                        .key("banner")
                }
                TUIText("Count: \(state.counter)")
                    .key("counter-label")
                TUIInput(placeholder: "Enter name")
                    .id("name-input")
                    .key("name-input")
                    .width(30)
                    .focused(true)
            }
            .width(.percent(100))
        }

        test.renderOnce(force: true)
        let inputBefore = try #require(root.findRenderable(id: "name-input") as? InputRenderable)
        #expect(inputBefore.focused)

        // Type text and move cursor left by 2 characters
        test.mockInput.typeText("hello")
        test.mockInput.pressArrow(.left)
        test.mockInput.pressArrow(.left)
        #expect(inputBefore.plainText == "hello")
        #expect(inputBefore.cursorOffset == 3)

        // Mutate state & insert a keyed sibling BEFORE the input, then reconcile!
        state.counter = 42
        state.showBannerAbove = true
        root.invalidate(renderNow: true)

        let inputAfter = try #require(root.findRenderable(id: "name-input") as? InputRenderable)
        #expect(inputAfter === inputBefore)
        #expect(inputAfter.focused)
        #expect(inputAfter.plainText == "hello")
        #expect(inputAfter.cursorOffset == 3)

        // Typing continues seamlessly at preserved cursor position (3 -> "helXlo")
        test.mockInput.typeText("X")
        #expect(inputAfter.plainText == "helXlo")
        #expect(inputAfter.cursorOffset == 4)

        test.renderOnce()
        let frame = test.captureCharFrame()
        #expect(frame.contains("ALERT BANNER"))
        #expect(frame.contains("Count: 42"))
        #expect(frame.contains("helXlo"))
    }

    @Test("Keyed TUIScrollBox preserves scroll offset across content updates")
    func keyedScrollBoxPreservesScrollPosition() throws {
        let test = createTestRenderer(width: 30, height: 8)
        defer { test.destroy() }

        final class Model {
            var header = "Log v1"
            var count = 20
        }
        let model = Model()

        let root = test.mountView {
            VStack {
                TUIText(model.header)
                    .key("hdr")
                TUIScrollBox(border: true) {
                    TUIForEach(0..<model.count) { i in
                        TUIText("Line \(i)")
                    }
                }
                .id("log-scroll")
                .key("log-scroll")
                .width(26)
                .height(6)
            }
        }

        test.renderOnce(force: true)
        let scrollBox = try #require(root.findRenderable(id: "log-scroll") as? ScrollBoxRenderable)
        scrollBox.scrollTo(5)
        test.renderOnce()
        #expect(scrollBox.scrollTop == 5)

        // Re-render with updated header and extra lines appended
        model.header = "Log v2"
        model.count = 25
        root.invalidate(renderNow: true)

        let scrollBoxAfter = try #require(root.findRenderable(id: "log-scroll") as? ScrollBoxRenderable)
        #expect(scrollBoxAfter === scrollBox)
        #expect(scrollBoxAfter.scrollTop == 5)
        #expect(test.captureCharFrame().contains("Log v2"))
    }

    @Test("Keyed TUIForEach reorders existing Renderables without recreating them and destroys removed nodes")
    func keyedReorderAndRemoval() throws {
        let test = createTestRenderer(width: 30, height: 8)
        defer { test.destroy() }

        final class Model {
            var items = [
                IdentifiableItem(id: "1", label: "ONE"),
                IdentifiableItem(id: "2", label: "TWO"),
                IdentifiableItem(id: "3", label: "THREE"),
            ]
        }
        let model = Model()

        let root = test.mountView {
            VStack {
                TUIForEach(model.items) { item in
                    TUIText(item.label)
                        .id("row-\(item.id)")
                }
            }
        }

        test.renderOnce(force: true)
        let r1 = try #require(root.findRenderable(id: "row-1"))
        let r2 = try #require(root.findRenderable(id: "row-2"))
        let r3 = try #require(root.findRenderable(id: "row-3"))

        // Reorder: [3, 1, 2]
        model.items = [
            IdentifiableItem(id: "3", label: "THREE"),
            IdentifiableItem(id: "1", label: "ONE-UPDATED"),
            IdentifiableItem(id: "2", label: "TWO"),
        ]
        root.invalidate(renderNow: true)

        let stack = try #require(root.mountedRenderables.first)
        let children = stack.getChildren()
        #expect(children.count == 3)
        #expect(children[0] === r3)
        #expect(children[1] === r1)
        #expect(children[2] === r2)

        let lines = test.captureCharFrame().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].contains("THREE"))
        #expect(lines[1].contains("ONE-UPDATED"))
        #expect(lines[2].contains("TWO"))

        // Remove item "2" -> r2 is detached & destroyed; r3 and r1 remain intact
        model.items = [
            IdentifiableItem(id: "3", label: "THREE"),
            IdentifiableItem(id: "1", label: "ONE-UPDATED"),
        ]
        root.invalidate(renderNow: true)

        #expect(r2.isDestroyed)
        #expect(!r1.isDestroyed)
        #expect(!r3.isDestroyed)
        #expect(stack.getChildren().count == 2)
        #expect(root.findRenderable(id: "row-2") == nil)

        // Unmount destroys everything cleanly
        root.unmount()
        #expect(!root.isMounted)
        #expect(r1.isDestroyed)
        #expect(r3.isDestroyed)
        #expect(test.root.getChildrenCount() == 0)
    }
}

// MARK: - 3. Interactive Controls & Display Widgets Tests

@Suite("OpenTUIViewInteractiveControls")
struct OpenTUIViewInteractiveControlsTests {
    @Test("TUISelect responds to MockInput arrows & Enter and updates reactive state")
    func selectInteractiveControl() {
        let test = createTestRenderer(width: 44, height: 12)
        defer { test.destroy() }

        final class Store {
            var activeIdx = 0
            var chosen = "None"
            var changeEvents: [Int] = []
        }
        let store = Store()
        let options = [
            SelectOption(name: "Build", description: "Compile workspace"),
            SelectOption(name: "Test", description: "Run Swift Testing"),
            SelectOption(name: "Deploy", description: "Publish release"),
        ]

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            VStack(spacing: 1) {
                TUIText("Selected: \(store.chosen)")
                TUISelect(
                    options: options,
                    selectedIndex: store.activeIdx,
                    wrapSelection: true,
                    onChange: { idx, _ in
                        store.activeIdx = idx
                        store.changeEvents.append(idx)
                        root.invalidate()
                    },
                    onSelect: { _, opt in
                        store.chosen = opt.name
                        root.invalidate()
                    }
                )
                .id("action-select")
                .key("action-select")
                .height(6)
                .focused(true)
            }
            .width(.percent(100))
        }

        test.renderOnce(force: true)
        #expect(test.captureCharFrame().contains("Selected: None"))
        #expect(test.captureCharFrame().contains("▶ Build"))

        // Press Down twice -> index 2 ("Deploy"), then press Enter -> selects "Deploy"
        test.mockInput.pressArrow(.down)
        test.mockInput.pressArrow(.down)
        test.mockInput.pressEnter()
        test.renderOnce()

        #expect(store.changeEvents == [1, 2])
        #expect(store.activeIdx == 2)
        #expect(store.chosen == "Deploy")
        let frame = test.captureCharFrame()
        #expect(frame.contains("Selected: Deploy"))
        #expect(frame.contains("▶ Deploy"))

        // Wrap around to index 0 with Down
        test.mockInput.pressArrow(.down)
        test.renderOnce()
        #expect(store.activeIdx == 0)
    }

    @Test("TUITabSelect responds to MockInput left/right & Enter")
    func tabSelectInteractiveControl() {
        let test = createTestRenderer(width: 60, height: 8)
        defer { test.destroy() }

        final class Store {
            var tabIndex = 0
            var activated = ""
        }
        let store = Store()
        let tabs = [
            TabSelectOption(name: "Overview", description: "System summary"),
            TabSelectOption(name: "Metrics", description: "CPU and latency"),
            TabSelectOption(name: "Logs", description: "Live output"),
        ]

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            VStack {
                TUITabSelect(
                    options: tabs,
                    selectedIndex: store.tabIndex,
                    tabWidth: 16,
                    onChange: { idx, _ in
                        store.tabIndex = idx
                        root.invalidate()
                    },
                    onSelect: { _, tab in
                        store.activated = tab.name
                        root.invalidate()
                    }
                )
                .key("tabs")
                .width(50)
                .focused(true)

                TUIText("ActiveTab: \(store.activated)")
            }
        }

        test.renderOnce(force: true)
        #expect(test.captureCharFrame().contains("System summary"))

        test.mockInput.pressArrow(.right)
        test.mockInput.pressEnter()
        test.renderOnce()

        #expect(store.tabIndex == 1)
        #expect(store.activated == "Metrics")
        let frame = test.captureCharFrame()
        #expect(frame.contains("CPU and latency"))
        #expect(frame.contains("ActiveTab: Metrics"))
    }

    @Test("TUIInput and TUITextarea handle typing, content change, and submit via MockInput")
    func inputAndTextareaControls() throws {
        let test = createTestRenderer(width: 44, height: 10)
        defer { test.destroy() }

        final class Store {
            var liveInputs: [String] = []
            var submittedInput: String? = nil
            var textareaChanges = 0
            var textareaSubmitted = false
        }
        let store = Store()

        let root = test.mountView {
            VStack(spacing: 1) {
                TUIInput(
                    placeholder: "Search...",
                    maxLength: 20,
                    onInput: { val in store.liveInputs.append(val) },
                    onSubmit: { val in store.submittedInput = val }
                )
                .id("search-input")
                .width(24)
                .focused(true)

                TUITextarea(
                    initialValue: "Line1",
                    placeholder: "Notes",
                    wrapMode: .word,
                    onContentChange: { _ in store.textareaChanges += 1 },
                    onSubmit: { _ in store.textareaSubmitted = true }
                )
                .id("notes-area")
                .width(24)
                .height(4)
            }
        }

        test.renderOnce(force: true)
        test.mockInput.typeText("swift")
        test.mockInput.pressEnter()
        test.renderOnce()

        #expect(store.liveInputs.last == "swift")
        #expect(store.submittedInput == "swift")
        #expect(test.captureCharFrame().contains("swift"))

        // Switch focus to textarea, type newline + text, then Meta+Enter submit
        let textarea = try #require(root.findRenderable(id: "notes-area") as? TextareaRenderable)
        textarea.focus()
        textarea.gotoBufferEnd()
        test.mockInput.pressEnter()
        test.mockInput.typeText("Line2")
        test.mockInput.pressEnter(modifiers: MockKeyModifiers(meta: true))
        test.renderOnce()

        #expect(textarea.plainText == "Line1\nLine2")
        #expect(store.textareaChanges > 0)
        #expect(store.textareaSubmitted == true)
    }

    @Test("TUISlider and mouse/key interaction modifiers respond to MockMouse and MockInput")
    func sliderAndInteractionModifiers() {
        let test = createTestRenderer(width: 40, height: 10)
        defer { test.destroy() }

        final class Store {
            var sliderValue: Double = 0
            var downCount = 0
            var upCount = 0
            var scrollCount = 0
            var keyCount = 0
        }
        let store = Store()

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            VStack(spacing: 1) {
                TUISlider(
                    min: 0,
                    max: 100,
                    value: store.sliderValue,
                    orientation: .horizontal,
                    onChange: { next in
                        store.sliderValue = next
                        root.invalidate()
                    }
                )
                .key("vol-slider")
                .width(20)
                .height(1)

                TUIBox(border: true) {
                    TUIText("Interactive")
                }
                .key("interactive-box")
                .width(20)
                .height(3)
                .focusable(true)
                .focused(true)
                .onKeyDown { _ in store.keyCount += 1 }
                .onMouseDown { _ in store.downCount += 1 }
                .onMouseUp { _ in store.upCount += 1 }
                .onMouseScroll { _ in store.scrollCount += 1 }
            }
        }

        test.renderOnce(force: true)

        // Click midpoint of slider (x=10, y=0) -> updates sliderValue near 50
        test.mockMouse.click(x: 10, y: 0)
        test.renderOnce()
        #expect(store.sliderValue >= 45 && store.sliderValue <= 55)

        // Click & scroll inside the interactive box (rows 2..4, cols 0..19)
        test.mockMouse.click(x: 5, y: 3)
        test.mockMouse.scroll(x: 5, y: 3, direction: .down)
        test.mockInput.pressKey("a")

        #expect(store.downCount == 1)
        #expect(store.upCount == 1)
        #expect(store.scrollCount == 1)
        #expect(store.keyCount == 1)
    }

    @Test("TUIScrollBox responds to MockMouse wheel scroll through TUIViewRoot")
    func scrollBoxMouseWheel() throws {
        let test = createTestRenderer(width: 30, height: 8)
        defer { test.destroy() }

        let root = test.mountView {
            TUIScrollBox(showVerticalScrollbar: true, border: true) {
                TUIForEach(0..<30) { row in
                    TUIText("Entry-\(row)")
                }
            }
            .id("wheel-scroll")
            .width(26)
            .height(6)
        }

        test.renderOnce(force: true)
        let scrollBox = try #require(root.findRenderable(id: "wheel-scroll") as? ScrollBoxRenderable)
        #expect(scrollBox.scrollTop == 0)

        test.mockMouse.scroll(x: 4, y: 2, direction: .down)
        test.mockMouse.scroll(x: 4, y: 2, direction: .down)
        test.renderOnce()
        #expect(scrollBox.scrollTop > 0)
    }

    @Test("Display components TUIQRCode, TUIASCIIFont, TUITable, TUIFrameBuffer, and TUIImage render cleanly")
    func displayWidgetsRender() {
        // 1. Table + ASCIIFont + FrameBuffer + Image
        let test1 = createTestRenderer(width: 50, height: 18)
        defer { test1.destroy() }

        let redSquare = PixelImage.solid(width: 4, height: 4, color: RGBA.fromInts(255, 0, 0, 255))

        _ = test1.mountView {
            VStack(spacing: 1) {
                TUIASCIIFont("HI", font: .tiny, color: "#00FFFF")

                TUITable(
                    rows: [
                        ["Service", "Status"],
                        ["API", "UP"],
                        ["DB", "UP"],
                    ],
                    showBorders: true,
                    columnWidthMode: .content
                )

                HStack(spacing: 2) {
                    TUIFrameBuffer(width: 6, height: 2) { fb in
                        fb.drawText("CANVAS", x: 0, y: 0, fg: RGBA.fromHex("#FFFF00"))
                    }

                    TUIImage(redSquare, fit: .fill)
                        .width(4)
                        .height(2)
                }
            }
        }

        test1.renderOnce(force: true)
        let frame1 = test1.captureCharFrame()
        #expect(frame1.contains("Service"))
        #expect(frame1.contains("Status"))
        #expect(frame1.contains("API"))
        #expect(frame1.contains("CANVAS"))
        #expect(frame1.contains("█"))

        // 2. QRCode
        let test2 = createTestRenderer(width: 40, height: 20)
        defer { test2.destroy() }

        _ = test2.mountView {
            TUIQRCode("https://opencode.ai", ecl: .M, fg: "#000000", bg: "#FFFFFF")
        }

        test2.renderOnce(force: true)
        let frame2 = test2.captureCharFrame()
        #expect(frame2.contains("█") || frame2.contains("▀") || frame2.contains("▄"))
    }

    @Test("Rich content components TUICode, TUIDiff, and TUIMarkdown mount and reconcile cleanly")
    func richContentViewsRenderAndPatch() throws {
        let test = createTestRenderer(width: 60, height: 22)
        defer { test.destroy() }

        let sampleDiff = """
        --- a/main.swift
        +++ b/main.swift
        @@ -1,2 +1,2 @@
        -let greeting = "old"
        +let greeting = "new"
         print(greeting)
        """

        final class Store {
            var codeText = "let x = 1"
            var mdText = "# Hello\n\nWorld"
        }
        let store = Store()

        let root = TUIViewRoot(testRenderer: test)
        root.render {
            VStack(spacing: 1) {
                TUICode(store.codeText, filetype: "swift")
                    .id("code-block")
                    .key("code-block")
                TUIDiff(sampleDiff, view: .unified, filetype: "swift")
                    .id("diff-block")
                    .key("diff-block")
                    .height(4)
                TUIMarkdown(store.mdText)
                    .id("md-block")
                    .key("md-block")
            }
        }

        test.renderOnce(force: true)
        let frame1 = test.captureCharFrame()
        #expect(frame1.contains("let x = 1"))
        #expect(frame1.contains("greeting"))
        #expect(frame1.contains("Hello"))

        let mountedCode = try #require(root.findRenderable(id: "code-block") as? CodeRenderable)
        store.codeText = "let x = 42"
        store.mdText = "# Updated\n\nDone"
        root.invalidate()
        test.renderOnce(force: true)

        #expect(root.findRenderable(id: "code-block") === mountedCode)
        let frame2 = test.captureCharFrame()
        #expect(frame2.contains("let x = 42"))
        #expect(frame2.contains("Updated"))
    }
}

// MARK: - 4. Full-Stack End-to-End SSH + Declarative OpenTUIView App Test

@Suite("OpenTUIViewSSHEndToEnd")
struct OpenTUIViewSSHEndToEndTests {
    @Test("Serves interactive declarative TUIView dashboard over SSH with navigation, selection, resize, and clean teardown")
    func sshDeclarativeDashboardEndToEnd() async throws {
        let hostKey = generateEd25519KeyPair()
        let driver = InMemorySSHTransportDriver()

        let capturedCli = Mutex<CliRenderer?>(nil)
        let capturedAdapter = Mutex<SSHCliRendererAdapter?>(nil)
        let appReady = Mutex(false)
        let selectedAction = Mutex<String>("None")

        let server = try createCliSSHServer(
            config: SSHServerConfig(
                auth: .open,
                hostKey: .pem(hostKey.privatePem),
                startupBanner: false
            ),
            rendererConfig: SSHCliRendererConfig(
                screenMode: .alternateScreen,
                exitOnCtrlC: false,
                debounceDelay: 0,
                useMouse: true,
                clockFactory: { ManualClock() }
            ),
            driver: driver
        )
        .serve { session in
            guard let cli = session.cliRenderer, let adapter = session.cliRendererAdapter else {
                Issue.record("Expected CliRenderer attached to SSH session")
                return
            }
            capturedCli.withLock { $0 = cli }
            capturedAdapter.withLock { $0 = adapter }

            struct DashboardSnapshot: Sendable {
                var selectedIndex = 0
                var chosenItem = "None"
                var cols: Int
                var rows: Int
            }

            let state = Mutex(DashboardSnapshot(cols: cli.width, rows: cli.height))
            let menuOptions = [
                SelectOption(name: "Cluster Health", description: "Inspect node status"),
                SelectOption(name: "Deploy Release", description: "Roll out latest build"),
                SelectOption(name: "Tail Logs", description: "Stream production logs"),
            ]

            let viewRoot = TUIViewRoot(renderer: cli)
            viewRoot.autoRenderOnInvalidate = true

            viewRoot.render {
                let snap = state.withLock { $0 }
                VStack(spacing: 1) {
                    TUIBox(border: true, borderStyle: .single, title: "SSH Dashboard") {
                        VStack(spacing: 0) {
                            TUIText("User: \(session.identity.username) | Size: \(snap.cols)x\(snap.rows)")
                            TUIText("Chosen: \(snap.chosenItem)")
                        }
                    }
                    .width(.percent(100))
                    .height(4)

                    TUIBox(border: true, title: "Actions") {
                        TUISelect(
                            options: menuOptions,
                            selectedIndex: snap.selectedIndex,
                            wrapSelection: true,
                            onChange: { idx, _ in
                                state.withLock { $0.selectedIndex = idx }
                                viewRoot.invalidate()
                            },
                            onSelect: { _, opt in
                                state.withLock { $0.chosenItem = opt.name }
                                selectedAction.withLock { $0 = opt.name }
                                viewRoot.invalidate()
                            }
                        )
                        .id("ssh-menu")
                        .key("ssh-menu")
                        .height(6)
                        .focused(true)
                    }
                    .width(.percent(100))
                    .height(8)
                }
                .width(.percent(100))
                .height(.percent(100))
            }

            _ = session.onResize { cols, rows in
                state.withLock {
                    $0.cols = cols
                    $0.rows = rows
                }
                viewRoot.invalidate()
            }

            cli.renderOnce(force: true)
            await adapter.flushOutput()
            appReady.withLock { $0 = true }
        }

        let listenInfo = try await server.listen(port: 0, host: "127.0.0.1")
        #expect(listenInfo.port > 0)

        let client = driver.connect()
        let authResult = await client.authenticate(method: "none", username: "dev")
        #expect(authResult == .accepted)
        client.emitReady()

        let sessionChannel = client.openSession()
        #expect(sessionChannel.requestPty(term: "xterm-256color", cols: 70, rows: 20))
        let channel = try #require(sessionChannel.requestShell())

        #expect(await waitUntil { appReady.withLock { $0 } })
        let cli = try #require(capturedCli.withLock { $0 })
        let adapter = try #require(capturedAdapter.withLock { $0 })

        // 1. Verify initial ANSI frame over SSH stdout
        #expect(await waitUntil {
            let out = channel.writtenText
            return out.contains(ANSI.switchToAlternateScreen)
                && out.contains("SSH Dashboard")
                && out.contains("User: dev | Size: 70x20")
                && out.contains("Cluster Health")
        })

        // 2. Send Arrow-Down + Enter over SSH stdin -> selects "Deploy Release" & emits diffed ANSI frame
        let bytesBeforeSelect = channel.writtenText.count
        channel.receiveText(KeyCodes.arrowDown)
        channel.receiveText(KeyCodes.return)
        await adapter.flushOutput()

        #expect(selectedAction.withLock { $0 } == "Deploy Release")
        #expect(cli.captureCharFrame().contains("Chosen: Deploy Release"))
        // AnsiDiffRenderer diffs only the changed suffix ("Deploy Release") onto the "Chosen: " row
        #expect(await waitUntil {
            let delta = String(channel.writtenText.dropFirst(bytesBeforeSelect))
            return delta.contains("Deploy Release")
        })

        // 3. Send SSH window-change resize -> dashboard re-layouts & emits updated size over SSH stdout
        let bytesBeforeResize = channel.writtenText.count
        sessionChannel.sendWindowChange(cols: 100, rows: 30)
        await adapter.flushOutput()

        #expect(cli.width == 100)
        #expect(cli.height == 30)
        #expect(cli.captureCharFrame().contains("User: dev | Size: 100x30"))
        #expect(await waitUntil {
            let delta = String(channel.writtenText.dropFirst(bytesBeforeResize))
            return delta.contains("100x30")
        })

        // 4. Clean teardown on client disconnect
        channel.emitClose()
        #expect(await waitUntil { cli.isDestroyed && server.activeSessions == 0 })
        #expect(adapter.isDestroyed)

        await server.close()
    }
}
