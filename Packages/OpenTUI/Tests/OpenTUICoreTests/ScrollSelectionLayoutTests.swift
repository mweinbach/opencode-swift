import Testing
import OpenTUICore
import OpenTUILayout

// MARK: - Test Doubles

private final class MockScrollNode: ScrollChainNode {
    let name: String
    weak var parent: MockScrollNode?

    init(name: String, parent: MockScrollNode? = nil) {
        self.name = name
        self.parent = parent
    }

    var scrollChainParent: (any ScrollChainNode)? {
        parent
    }
}

private final class MockSelectableRenderable: SelectableRenderable {
    var x: Int
    var y: Int
    var isDestroyed: Bool
    var text: String

    init(x: Int, y: Int, text: String, isDestroyed: Bool = false) {
        self.x = x
        self.y = y
        self.text = text
        self.isDestroyed = isDestroyed
    }

    func getSelectedText() -> String {
        text
    }
}

// MARK: - Scroll Acceleration & Chaining

@Suite("Scroll Acceleration and Chaining Tests")
struct ScrollAccelerationAndChainingTests {
    @Test("LinearScrollAccel always returns 1.0")
    func linearScrollAccelConstant() {
        let accel = LinearScrollAccel()
        #expect(accel.tick(now: 0) == 1.0)
        #expect(accel.tick(now: 10) == 1.0)
        #expect(accel.tick(now: 20) == 1.0)
        accel.reset()
        #expect(accel.tick(now: 25) == 1.0)
    }

    @Test("MacOSScrollAccel first tick, timeout reset, and minTickInterval debounce")
    func macOSScrollAccelTimingRules() {
        var accel = MacOSScrollAccel()

        // First tick starts streak and returns 1
        #expect(accel.tick(now: 1000) == 1.0)

        // Sub-6ms tick (e.g. Ghostty duplicate event at dt = 4ms) is ignored without advancing lastTickTime
        #expect(accel.tick(now: 1004) == 1.0)

        // Tick at 1050 has dt = 50ms from 1000 -> velocity = 2.0, x = 2/3, 1 + 0.8 * (exp(2/3) - 1)
        let m1 = accel.tick(now: 1050)
        // exp(2/3) ≈ 1.9477340410546757 -> 1 + 0.8 * 0.9477340410546757 = 1.7581872328437406
        #expect(abs(m1 - 1.7581872328437406) < 1e-12)

        // Exactly at streakTimeout (dt = 150ms) does NOT reset
        let mBoundary = accel.tick(now: 1200)
        // history = [50, 150], avg = 100, velocity = 1.0, x = 1/3
        // exp(1/3) ≈ 1.3956124250860895 -> 1 + 0.8 * 0.3956124250860895 = 1.3164899400688716
        #expect(abs(mBoundary - 1.3164899400688716) < 1e-12)

        // Beyond streakTimeout (dt = 151ms) resets streak and returns 1.0
        #expect(accel.tick(now: 1351) == 1.0)
    }

    @Test("MacOSScrollAccel moving window of size 3, clamping, A=0, and reset")
    func macOSScrollAccelWindowAndClamping() {
        var accel = MacOSScrollAccel(A: 0.8, tau: 3.0, maxMultiplier: 6.0)
        #expect(accel.tick(now: 100) == 1.0)

        // 4 rapid ticks at 10ms intervals: velocity = 10, x = 10/3 -> 1 + 0.8 * (exp(10/3) - 1) ≈ 22.62 -> clamped to 6.0
        let mFast1 = accel.tick(now: 110)
        #expect(mFast1 == 6.0)

        // Now send slower ticks (100ms apart) so the 3-element window shifts out the 10ms entry
        let mSlow1 = accel.tick(now: 210) // history = [10, 100], avg = 55
        let mSlow2 = accel.tick(now: 310) // history = [10, 100, 100], avg = 70
        let mSlow3 = accel.tick(now: 410) // history = [100, 100, 100], avg = 100 -> velocity = 1, x = 1/3
        #expect(mSlow1 > mSlow2)
        #expect(mSlow2 > mSlow3)
        #expect(abs(mSlow3 - 1.3164899400688716) < 1e-12)

        // Reset clears history and lastTickTime
        accel.reset()
        #expect(accel.tick(now: 420) == 1.0)

        // A = 0 disables acceleration
        var zeroAccel = MacOSScrollAccel(A: 0.0)
        #expect(zeroAccel.tick(now: 100) == 1.0)
        #expect(zeroAccel.tick(now: 110) == 1.0)
    }

    @Test("wheelDirection maps shift-modified and unmodified wheel axes")
    func wheelDirectionMapping() {
        #expect(wheelDirection(direction: nil, shift: false) == nil)
        #expect(wheelDirection(direction: nil, shift: true) == nil)

        #expect(wheelDirection(direction: .up, shift: false) == .up)
        #expect(wheelDirection(direction: .down, shift: false) == .down)
        #expect(wheelDirection(direction: .left, shift: false) == .left)
        #expect(wheelDirection(direction: .right, shift: false) == .right)

        #expect(wheelDirection(direction: .up, shift: true) == .left)
        #expect(wheelDirection(direction: .down, shift: true) == .right)
        #expect(wheelDirection(direction: .right, shift: true) == .down)
        #expect(wheelDirection(direction: .left, shift: true) == .up)

        #expect(wheelDirection(ScrollWheelEvent(direction: .down, shift: true)) == .right)
        #expect(wheelDirection(ScrollWheelEvent(direction: nil, shift: true)) == nil)
    }

    @Test("scrollOnce claims event for innermost scroller and blocks ancestors")
    func scrollOnceChaining() {
        let root = MockScrollNode(name: "root")
        let outer = MockScrollNode(name: "outer", parent: root)
        let inner = MockScrollNode(name: "inner", parent: outer)
        let sibling = MockScrollNode(name: "sibling", parent: root)

        // Case 1: inner consumes -> outer and root do not run
        let event1 = ScrollChainToken()
        var ran: [String] = []
        #expect(scrollOnce(event: event1, scroller: inner) {
            ran.append("inner")
            return true
        } == true)
        #expect(scrollOnce(event: event1, scroller: outer) {
            ran.append("outer")
            return true
        } == false)
        #expect(scrollOnce(event: event1, scroller: root) {
            ran.append("root")
            return true
        } == false)
        #expect(ran == ["inner"])

        // Unrelated sibling is not an ancestor of inner, so it may still run
        #expect(scrollOnce(event: event1, scroller: sibling) {
            ran.append("sibling")
            return true
        } == true)
        #expect(ran == ["inner", "sibling"])

        // Case 2: inner cannot scroll (returns false) -> bubbles to outer, then blocks root
        let event2 = ScrollChainToken()
        var ran2: [String] = []
        #expect(scrollOnce(event: event2, scroller: inner) {
            ran2.append("inner")
            return false
        } == false)
        #expect(scrollOnce(event: event2, scroller: outer) {
            ran2.append("outer")
            return true
        } == true)
        #expect(scrollOnce(event: event2, scroller: root) {
            ran2.append("root")
            return true
        } == false)
        #expect(ran2 == ["inner", "outer"])
    }
}

// MARK: - Selection

@Suite("Selection State and Bounds Tests")
struct SelectionStateAndBoundsTests {
    @Test("Selection defaults, inclusive bounds, and reverse drag")
    func selectionBoundsAndState() {
        let renderable = MockSelectableRenderable(x: 2, y: 3, text: "Hello")
        let sel = Selection(
            anchorRenderable: renderable,
            anchor: SelectionPoint(x: 2, y: 3),
            focus: SelectionPoint(x: 2, y: 3)
        )

        #expect(sel.isActive == true)
        #expect(sel.isDragging == true)
        #expect(sel.isStart == false)
        #expect(sel.behavior == .cell)
        #expect(sel.anchor == SelectionPoint(x: 2, y: 3))
        #expect(sel.focus == SelectionPoint(x: 2, y: 3))
        #expect(sel.bounds == SelectionBounds(x: 2, y: 3, width: 1, height: 1))

        // Forward drag (2,3) -> (7,6) covers 6x4 inclusive cells
        sel.focus = SelectionPoint(x: 7, y: 6)
        #expect(sel.bounds == SelectionBounds(x: 2, y: 3, width: 6, height: 4))

        // Reverse drag (2,3) -> (0,1) normalizes min/max
        sel.focus = SelectionPoint(x: 0, y: 1)
        #expect(sel.bounds == SelectionBounds(x: 0, y: 1, width: 3, height: 3))

        // Anchor dynamically tracks movement of anchorRenderable
        renderable.x = 12
        renderable.y = 13
        #expect(sel.anchor == SelectionPoint(x: 12, y: 13))
        #expect(sel.bounds == SelectionBounds(x: 0, y: 1, width: 13, height: 13))

        sel.isStart = true
        sel.isDragging = false
        sel.isActive = false
        #expect(sel.isStart == true)
        #expect(sel.isDragging == false)
        #expect(sel.isActive == false)
    }

    @Test("Selection reading-order text assembly, multiline merging, and destroyed filtering")
    func selectionTextAssembly() {
        let r1 = MockSelectableRenderable(x: 0, y: 0, text: "Hello ")
        let r2 = MockSelectableRenderable(x: 6, y: 0, text: "World")
        let r3 = MockSelectableRenderable(x: 0, y: 1, text: "Second row")
        let destroyed = MockSelectableRenderable(x: 0, y: 2, text: "Should vanish", isDestroyed: true)
        let empty = MockSelectableRenderable(x: 10, y: 1, text: "")

        let sel = Selection(
            anchorRenderable: r1,
            anchor: SelectionPoint(x: 0, y: 0),
            focus: SelectionPoint(x: 10, y: 2)
        )
        // Supply out of reading order to verify sorting
        sel.updateSelectedRenderables([r3, r2, destroyed, empty, r1])
        sel.updateTouchedRenderables([r1, r2, r3])

        #expect(sel.selectedRenderables.count == 5)
        #expect(sel.touchedRenderables.count == 3)
        #expect(sel.getSelectedText() == "Hello World\nSecond row")

        // Multiline same-row renderables merge per visual row
        let leftCol = MockSelectableRenderable(x: 0, y: 5, text: "A1\nA2")
        let rightCol = MockSelectableRenderable(x: 4, y: 5, text: "B1\nB2")
        sel.updateSelectedRenderables([rightCol, leftCol])
        #expect(sel.getSelectedText() == "A1B1\nA2B2")

        // Preserves empty lines on LF split (including CRLF)
        let crlf = MockSelectableRenderable(x: 0, y: 0, text: "line1\n\nline3")
        sel.updateSelectedRenderables([crlf])
        #expect(sel.getSelectedText() == "line1\n\nline3")
    }

    @Test("convertGlobalToLocalSelection offsets coordinates and handles inactive/nil")
    func globalToLocalSelectionConversion() {
        let r = MockSelectableRenderable(x: 10, y: 20, text: "abc")
        let sel = Selection(
            anchorRenderable: r,
            anchor: SelectionPoint(x: 12, y: 21),
            focus: SelectionPoint(x: 18, y: 25),
            behavior: .word
        )

        #expect(convertGlobalToLocalSelection(nil, localX: 10, localY: 20) == nil)

        let local = convertGlobalToLocalSelection(sel, localX: 10, localY: 20)
        #expect(
            local == LocalSelectionBounds(
                anchorX: 2,
                anchorY: 1,
                focusX: 8,
                focusY: 5,
                isActive: true,
                behavior: .word
            )
        )

        sel.isActive = false
        #expect(convertGlobalToLocalSelection(sel, localX: 10, localY: 20) == nil)
    }
}

// MARK: - Yoga Options

@Suite("Yoga Options Parser Tests")
struct YogaOptionsParserTests {
    @Test("parseBoxSizing")
    func testParseBoxSizing() {
        #expect(parseBoxSizing("border-box") == .borderBox)
        #expect(parseBoxSizing("content-box") == .contentBox)
        #expect(parseBoxSizing("BORDER-BOX") == .borderBox)
        #expect(parseBoxSizing("CONTENT-BOX") == .contentBox)
        #expect(parseBoxSizing("invalid") == .borderBox)
        #expect(parseBoxSizing(nil) == .borderBox)
    }

    @Test("parseDimension")
    func testParseDimension() {
        #expect(parseDimension("width") == .width)
        #expect(parseDimension("height") == .height)
        #expect(parseDimension("WIDTH") == .width)
        #expect(parseDimension("HEIGHT") == .height)
        #expect(parseDimension("invalid") == .width)
        #expect(parseDimension(nil) == .width)
    }

    @Test("parseDirection")
    func testParseDirection() {
        #expect(parseDirection("inherit") == .inherit)
        #expect(parseDirection("ltr") == .ltr)
        #expect(parseDirection("rtl") == .rtl)
        #expect(parseDirection("INHERIT") == .inherit)
        #expect(parseDirection("LTR") == .ltr)
        #expect(parseDirection("RTL") == .rtl)
        #expect(parseDirection("invalid") == .ltr)
        #expect(parseDirection(nil) == .ltr)
    }

    @Test("parseDisplay")
    func testParseDisplay() {
        #expect(parseDisplay("flex") == .flex)
        #expect(parseDisplay("none") == .none)
        #expect(parseDisplay("contents") == .contents)
        #expect(parseDisplay("FLEX") == .flex)
        #expect(parseDisplay("NONE") == .none)
        #expect(parseDisplay("CONTENTS") == .contents)
        #expect(parseDisplay("invalid") == .flex)
        #expect(parseDisplay(nil) == .flex)
    }

    @Test("parseEdge")
    func testParseEdge() {
        #expect(parseEdge("left") == .left)
        #expect(parseEdge("top") == .top)
        #expect(parseEdge("right") == .right)
        #expect(parseEdge("bottom") == .bottom)
        #expect(parseEdge("start") == .start)
        #expect(parseEdge("end") == .end)
        #expect(parseEdge("horizontal") == .horizontal)
        #expect(parseEdge("vertical") == .vertical)
        #expect(parseEdge("all") == .all)
        #expect(parseEdge("LEFT") == .left)
        #expect(parseEdge("TOP") == .top)
        #expect(parseEdge("invalid") == .all)
        #expect(parseEdge(nil) == .all)
    }

    @Test("parseGutter")
    func testParseGutter() {
        #expect(parseGutter("column") == .column)
        #expect(parseGutter("row") == .row)
        #expect(parseGutter("all") == .all)
        #expect(parseGutter("COLUMN") == .column)
        #expect(parseGutter("ROW") == .row)
        #expect(parseGutter("ALL") == .all)
        #expect(parseGutter("invalid") == .all)
        #expect(parseGutter(nil) == .all)
    }

    @Test("parseLogLevel")
    func testParseLogLevel() {
        #expect(parseLogLevel("error") == .error)
        #expect(parseLogLevel("warn") == .warn)
        #expect(parseLogLevel("info") == .info)
        #expect(parseLogLevel("debug") == .debug)
        #expect(parseLogLevel("verbose") == .verbose)
        #expect(parseLogLevel("fatal") == .fatal)
        #expect(parseLogLevel("ERROR") == .error)
        #expect(parseLogLevel("WARN") == .warn)
        #expect(parseLogLevel("INFO") == .info)
        #expect(parseLogLevel("invalid") == .info)
        #expect(parseLogLevel(nil) == .info)
    }

    @Test("parseMeasureMode")
    func testParseMeasureMode() {
        #expect(parseMeasureMode("undefined") == .undefined)
        #expect(parseMeasureMode("exactly") == .exactly)
        #expect(parseMeasureMode("at-most") == .atMost)
        #expect(parseMeasureMode("UNDEFINED") == .undefined)
        #expect(parseMeasureMode("EXACTLY") == .exactly)
        #expect(parseMeasureMode("AT-MOST") == .atMost)
        #expect(parseMeasureMode("invalid") == .undefined)
        #expect(parseMeasureMode(nil) == .undefined)
    }

    @Test("parseUnit")
    func testParseUnit() {
        #expect(parseUnit("undefined") == .undefined)
        #expect(parseUnit("point") == .point)
        #expect(parseUnit("percent") == .percent)
        #expect(parseUnit("auto") == .auto)
        #expect(parseUnit("UNDEFINED") == .undefined)
        #expect(parseUnit("POINT") == .point)
        #expect(parseUnit("PERCENT") == .percent)
        #expect(parseUnit("AUTO") == .auto)
        #expect(parseUnit("invalid") == .point)
        #expect(parseUnit(nil) == .point)
    }

    @Test("parseAlign, parseAlignItems, parseAlignContent defaults and values")
    func testParseAlignments() {
        let cases: [(String?, Align?)] = [
            ("auto", .auto),
            ("flex-start", .flexStart),
            ("center", .center),
            ("CENTER", .center),
            ("flex-end", .flexEnd),
            ("stretch", .stretch),
            ("baseline", .baseline),
            ("space-between", .spaceBetween),
            ("space-around", .spaceAround),
            ("space-evenly", .spaceEvenly),
            (nil, nil),
            ("invalid", nil),
        ]

        for (input, expected) in cases {
            #expect(parseAlign(input) == (expected ?? .auto))
            #expect(parseAlignItems(input) == (expected ?? .stretch))
            #expect(parseAlignContent(input) == (expected ?? .flexStart))
        }
    }

    @Test("parseFlexDirection and native ABI raw values")
    func testParseFlexDirection() {
        #expect(parseFlexDirection("column") == .column)
        #expect(parseFlexDirection("column-reverse") == .columnReverse)
        #expect(parseFlexDirection("row") == .row)
        #expect(parseFlexDirection("row-reverse") == .rowReverse)
        #expect(parseFlexDirection("ROW") == .row)
        #expect(parseFlexDirection(nil) == .column)
        #expect(parseFlexDirection("invalid") == .column)

        #expect(FlexDirection.column.yogaRawValue == 0)
        #expect(FlexDirection.columnReverse.yogaRawValue == 1)
        #expect(FlexDirection.row.yogaRawValue == 2)
        #expect(FlexDirection.rowReverse.yogaRawValue == 3)
    }

    @Test("parseJustify")
    func testParseJustify() {
        #expect(parseJustify("flex-start") == .flexStart)
        #expect(parseJustify("center") == .center)
        #expect(parseJustify("flex-end") == .flexEnd)
        #expect(parseJustify("space-between") == .spaceBetween)
        #expect(parseJustify("space-around") == .spaceAround)
        #expect(parseJustify("space-evenly") == .spaceEvenly)
        #expect(parseJustify("CENTER") == .center)
        #expect(parseJustify(nil) == .flexStart)
        #expect(parseJustify("invalid") == .flexStart)
    }

    @Test("parseLayoutMode")
    func testParseLayoutMode() {
        #expect(parseLayoutMode("flex") == .flex)
        #expect(parseLayoutMode("list") == .list)
        #expect(parseLayoutMode("LIST") == .list)
        #expect(parseLayoutMode(nil) == .flex)
        #expect(parseLayoutMode("invalid") == .flex)
        #expect(LayoutMode.flex.rawValue == 0)
        #expect(LayoutMode.list.rawValue == 1)
    }

    @Test("parseOverflow")
    func testParseOverflow() {
        #expect(parseOverflow("visible") == .visible)
        #expect(parseOverflow("hidden") == .hidden)
        #expect(parseOverflow("scroll") == .scroll)
        #expect(parseOverflow("HIDDEN") == .hidden)
        #expect(parseOverflow(nil) == .visible)
        #expect(parseOverflow("invalid") == .visible)
    }

    @Test("parsePositionType preserves nil -> relative vs invalid -> static")
    func testParsePositionType() {
        #expect(parsePositionType("static") == .static)
        #expect(parsePositionType("relative") == .relative)
        #expect(parsePositionType("absolute") == .absolute)
        #expect(parsePositionType("ABSOLUTE") == .absolute)
        #expect(parsePositionType(nil) == .relative)
        #expect(parsePositionType("invalid") == .static)
    }

    @Test("parseWrap")
    func testParseWrap() {
        #expect(parseWrap("no-wrap") == .noWrap)
        #expect(parseWrap("wrap") == .wrap)
        #expect(parseWrap("wrap-reverse") == .wrapReverse)
        #expect(parseWrap("WRAP") == .wrap)
        #expect(parseWrap(nil) == .noWrap)
        #expect(parseWrap("invalid") == .noWrap)
    }
}

// MARK: - Renderable Validations

@Suite("Renderable Validation Tests")
struct RenderableValidationTests {
    @Test("validateOptions accepts valid sizes and throws on negative width or height")
    func testValidateOptions() throws {
        try validateOptions(id: "test", options: RenderableValidationOptions(width: 100, height: 100))
        try validateOptions(id: "test", options: RenderableValidationOptions(width: 0, height: 0))
        try validateOptions(id: "test", options: RenderableValidationOptions(width: "50%", height: "auto"))
        try validateOptions(id: "test", options: RenderableValidationOptions())

        #expect(throws: RenderableValidationError.invalidWidth(id: "test", value: -100)) {
            try validateOptions(id: "test", options: RenderableValidationOptions(width: -100, height: 100))
        }

        #expect(throws: RenderableValidationError.invalidHeight(id: "test", value: -100)) {
            try validateOptions(id: "test", options: RenderableValidationOptions(width: 100, height: -100))
        }

        #expect(
            RenderableValidationError.invalidWidth(id: "box1", value: -10).description
                == "Invalid width for Renderable box1: -10"
        )
        #expect(
            RenderableValidationError.invalidHeight(id: "box2", value: -2.5).description
                == "Invalid height for Renderable box2: -2.5"
        )
    }

    @Test("isValidPercentage matches JavaScript parseFloat semantics")
    func testIsValidPercentage() {
        #expect(isValidPercentage("50%") == true)
        #expect(isValidPercentage("0%") == true)
        #expect(isValidPercentage("100.5%") == true)
        #expect(isValidPercentage(".5%") == true)
        #expect(isValidPercentage("-12.5%") == true)
        #expect(isValidPercentage(" 42%") == true)
        #expect(isValidPercentage("Infinity%") == true)
        #expect(isValidPercentage("abc") == false)
        #expect(isValidPercentage("abc%") == false)
        #expect(isValidPercentage("%") == false)
        #expect(isValidPercentage(".%") == false)
        #expect(isValidPercentage("-%") == false)
        #expect(isValidPercentage("50") == false)
        #expect(isValidPercentage(50) == false)
        #expect(isValidPercentage(nil) == false)
    }

    @Test("isMarginType")
    func testIsMarginType() {
        #expect(isMarginType(10) == true)
        #expect(isMarginType("auto") == true)
        #expect(isMarginType("50%") == true)
        #expect(isMarginType(.number(.nan)) == false)
        #expect(isMarginType("invalid") == false)
        #expect(isMarginType(nil) == false)
    }

    @Test("isPaddingType")
    func testIsPaddingType() {
        #expect(isPaddingType(10) == true)
        #expect(isPaddingType("50%") == true)
        #expect(isPaddingType("auto") == false)
        #expect(isPaddingType(.number(.nan)) == false)
        #expect(isPaddingType(nil) == false)
    }

    @Test("isPositionType and isDimensionType")
    func testIsPositionAndDimensionType() {
        #expect(isPositionType(10) == true)
        #expect(isPositionType("auto") == true)
        #expect(isPositionType("50%") == true)
        #expect(isPositionType(.number(.nan)) == false)
        #expect(isPositionType(nil) == false)

        #expect(isDimensionType(100) == true)
        #expect(isDimensionType("auto") == true)
        #expect(isDimensionType("50%") == true)
        #expect(isDimensionType(.number(.nan)) == false)
        #expect(isDimensionType(nil) == false)
    }

    @Test("isFlexBasisType")
    func testIsFlexBasisType() {
        #expect(isFlexBasisType(100) == true)
        #expect(isFlexBasisType("auto") == true)
        #expect(isFlexBasisType(nil) == true)
        #expect(isFlexBasisType(.number(.nan)) == false)
        #expect(isFlexBasisType("50%") == false)
    }

    @Test("isSizeType")
    func testIsSizeType() {
        #expect(isSizeType(100) == true)
        #expect(isSizeType("50%") == true)
        #expect(isSizeType(nil) == true)
        #expect(isSizeType(.number(.nan)) == false)
        #expect(isSizeType("auto") == false)
    }

    @Test("isPositionTypeType")
    func testIsPositionTypeType() {
        #expect(isPositionTypeType("relative") == true)
        #expect(isPositionTypeType("absolute") == true)
        #expect(isPositionTypeType("static") == false)
        #expect(isPositionTypeType("fixed") == false)
        #expect(isPositionTypeType(10) == false)
        #expect(isPositionTypeType(nil) == false)
    }

    @Test("isOverflowType")
    func testIsOverflowType() {
        #expect(isOverflowType("visible") == true)
        #expect(isOverflowType("hidden") == true)
        #expect(isOverflowType("scroll") == true)
        #expect(isOverflowType("auto") == false)
        #expect(isOverflowType(10) == false)
        #expect(isOverflowType(nil) == false)
    }
}
