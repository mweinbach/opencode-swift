import Testing
import OpenTUICore
import OpenTUILayout

@Suite("FlexLayout Tests")
struct FlexLayoutTests {
    // MARK: - FlexValue, FlexEdgeValues, FlexGapValues

    @Test("FlexValue resolution, unit mapping, and string/option parsing")
    func flexValueBasics() {
        #expect(FlexValue.undefined.unit == .undefined)
        #expect(FlexValue.undefined.isUndefined)
        #expect(!FlexValue.undefined.isDefined)
        #expect(FlexValue.undefined.rawValue.isNaN)

        #expect(FlexValue.auto.unit == .auto)
        #expect(FlexValue.auto.isAuto)
        #expect(!FlexValue.auto.isDefined)
        #expect(FlexValue.auto.resolve(against: 100) == nil)

        let pt: FlexValue = 12
        #expect(pt == .point(12))
        #expect(pt.unit == .point)
        #expect(pt.isDefined)
        #expect(pt.resolve(against: nil) == 12)

        let pct = FlexValue.percent(25)
        #expect(pct.unit == .percent)
        #expect(pct.resolve(against: 80) == 20)
        #expect(pct.resolve(against: nil) == nil)

        #expect(FlexValue.parse("auto") == .auto)
        #expect(FlexValue.parse(" 50% ") == .percent(50))
        #expect(FlexValue.parse("16.5") == .point(16.5))
        #expect(FlexValue.parse("") == .undefined)
        #expect(FlexValue.parse("invalid") == .undefined)
        #expect(FlexValue.parse(LayoutOptionValue.number(10)) == .point(10))
        #expect(FlexValue.parse(LayoutOptionValue.string("75%")) == .percent(75))
        #expect(FlexValue.parse(LayoutOptionValue.null) == .undefined)
    }

    @Test("FlexEdgeValues specificity hierarchy in LTR and RTL")
    func flexEdgePrecedence() {
        var edges = FlexEdgeValues()
        edges.set(.all, .point(1))
        #expect(edges.resolve(.left, direction: .ltr) == .point(1))
        #expect(edges.resolve(.top, direction: .ltr) == .point(1))

        edges.set(.horizontal, .point(2))
        edges.set(.vertical, .point(3))
        #expect(edges.resolve(.left, direction: .ltr) == .point(2))
        #expect(edges.resolve(.right, direction: .ltr) == .point(2))
        #expect(edges.resolve(.top, direction: .ltr) == .point(3))
        #expect(edges.resolve(.bottom, direction: .ltr) == .point(3))

        edges.set(.left, .point(4))
        edges.set(.top, .point(5))
        #expect(edges.resolve(.left, direction: .ltr) == .point(4))
        #expect(edges.resolve(.right, direction: .ltr) == .point(2))
        #expect(edges.resolve(.top, direction: .ltr) == .point(5))

        // Logical start/end override physical left/right depending on direction
        edges.set(.start, .point(6))
        edges.set(.end, .point(7))
        #expect(edges.resolve(.left, direction: .ltr) == .point(6))
        #expect(edges.resolve(.right, direction: .ltr) == .point(7))
        #expect(edges.resolve(.left, direction: .rtl) == .point(7))
        #expect(edges.resolve(.right, direction: .rtl) == .point(6))
    }

    @Test("FlexGapValues resolution and negative clamping")
    func flexGapResolution() {
        var gap = FlexGapValues()
        gap.set(.all, .point(2))
        #expect(gap.resolvePoints(.row, ownerSize: 100) == 2)
        #expect(gap.resolvePoints(.column, ownerSize: 100) == 2)

        gap.set(.column, .point(5))
        #expect(gap.resolvePoints(.row, ownerSize: 100) == 2)
        #expect(gap.resolvePoints(.column, ownerSize: 100) == 5)

        gap.set(.row, .percent(10))
        #expect(gap.resolvePoints(.row, ownerSize: 50) == 5)

        gap.set(.column, .point(-3))
        #expect(gap.resolvePoints(.column, ownerSize: 50) == 0)
    }

    // MARK: - FlexNode Tree Management & Dirty Propagation

    @Test("FlexNode tree operations, dirty propagation, and lifecycle")
    func nodeTreeAndDirtyPropagation() {
        let root = FlexNode(style: FlexStyle(width: 40, height: 20))
        let mid = FlexNode(style: FlexStyle(flexGrow: 1))
        let leaf = FlexNode(style: FlexStyle(width: 10, height: 5))

        root.insertChild(mid, at: 0)
        mid.insertChild(leaf, at: 0)

        #expect(root.childCount == 1)
        #expect(root.getChild(at: 0) === mid)
        #expect(mid.parent === root)
        #expect(leaf.parent === mid)

        // Prevent self-insertion and ancestor cycles
        leaf.insertChild(root, at: 0)
        leaf.insertChild(leaf, at: 0)
        #expect(leaf.childCount == 0)

        root.calculateLayout(availableWidth: 40, availableHeight: 20)
        #expect(!root.isDirty)
        #expect(!mid.isDirty)
        #expect(!leaf.isDirty)
        #expect(root.hasNewLayout)
        root.markLayoutSeen()
        #expect(!root.hasNewLayout)

        // Mutating leaf style marks leaf and propagates dirtiness up to root
        leaf.style.width = 15
        #expect(leaf.isDirty)
        #expect(mid.isDirty)
        #expect(root.isDirty)

        // Re-parenting removes from old parent
        root.insertChild(leaf, at: 1)
        #expect(mid.childCount == 0)
        #expect(root.childCount == 2)
        #expect(leaf.parent === root)

        root.removeChild(mid)
        #expect(mid.parent == nil)
        #expect(root.childCount == 1)

        root.removeAllChildren()
        #expect(root.childCount == 0)
        #expect(leaf.parent == nil)
    }

    // MARK: - Display None & Contents

    @Test("display: .none produces zero layout, skips children, and skips measureFunc")
    func displayNoneShortCircuit() {
        let root = FlexNode(style: FlexStyle(
            flexDirection: .row,
            width: 40,
            height: 10,
            gap: FlexGapValues(all: 4)
        ))

        let first = FlexNode(style: FlexStyle(width: 10, height: 10))
        let hidden = FlexNode(style: FlexStyle(width: 20, height: 10, display: .none))
        let hiddenChild = FlexNode(
            style: FlexStyle(width: 8, height: 8),
            measureFunc: { _, _, _, _ in
                Issue.record("measureFunc should not run inside display: .none subtree")
                return FlexSize(width: 99, height: 99)
            }
        )
        hidden.appendChild(hiddenChild)
        let second = FlexNode(style: FlexStyle(width: 10, height: 10))

        root.appendChild(first)
        root.appendChild(hidden)
        root.appendChild(second)
        root.calculateLayout(availableWidth: 40, availableHeight: 10)

        #expect(first.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 10))
        #expect(hidden.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 0, height: 0))
        #expect(hiddenChild.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 0, height: 0))
        // Gap is only between `first` and `second` (not doubled by `hidden`)
        #expect(second.computedLayout.rect == LayoutRect(x: 14, y: 0, width: 10, height: 10))
    }

    @Test("display: .contents flattens children into parent flex line")
    func displayContentsFlattening() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 30, height: 10))
        let wrapper = FlexNode(style: FlexStyle(display: .contents))
        let a = FlexNode(style: FlexStyle(flexGrow: 1, height: 10))
        let b = FlexNode(style: FlexStyle(flexGrow: 1, height: 10))
        wrapper.appendChild(a)
        wrapper.appendChild(b)
        root.appendChild(wrapper)

        root.calculateLayout(availableWidth: 30, availableHeight: 10)
        #expect(wrapper.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 0, height: 0))
        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 15, height: 10))
        #expect(b.computedLayout.rect == LayoutRect(x: 15, y: 0, width: 15, height: 10))
    }

    // MARK: - FlexDirection & RTL

    @Test("flexDirection: row, rowReverse, column, columnReverse")
    func flexDirections() {
        func makePair(direction: FlexDirection) -> (FlexNode, FlexNode, FlexNode) {
            let root = FlexNode(style: FlexStyle(flexDirection: direction, width: 40, height: 20))
            let a = FlexNode(style: FlexStyle(width: 10, height: 4))
            let b = FlexNode(style: FlexStyle(width: 12, height: 6))
            root.appendChild(a)
            root.appendChild(b)
            root.calculateLayout(availableWidth: 40, availableHeight: 20)
            return (root, a, b)
        }

        let (_, rA, rB) = makePair(direction: .row)
        #expect(rA.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 4))
        #expect(rB.computedLayout.rect == LayoutRect(x: 10, y: 0, width: 12, height: 6))

        let (_, rrA, rrB) = makePair(direction: .rowReverse)
        #expect(rrA.computedLayout.rect == LayoutRect(x: 30, y: 0, width: 10, height: 4))
        #expect(rrB.computedLayout.rect == LayoutRect(x: 18, y: 0, width: 12, height: 6))

        let (_, cA, cB) = makePair(direction: .column)
        #expect(cA.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 4))
        #expect(cB.computedLayout.rect == LayoutRect(x: 0, y: 4, width: 12, height: 6))

        let (_, crA, crB) = makePair(direction: .columnReverse)
        #expect(crA.computedLayout.rect == LayoutRect(x: 0, y: 16, width: 10, height: 4))
        #expect(crB.computedLayout.rect == LayoutRect(x: 0, y: 10, width: 12, height: 6))
    }

    @Test("RTL direction reverses row flow and resolves start/end edges")
    func rtlDirection() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 40, height: 10))
        var aStyle = FlexStyle(width: 10, height: 10)
        aStyle.margin.set(.start, 2)
        let a = FlexNode(style: aStyle)
        let b = FlexNode(style: FlexStyle(width: 10, height: 10))
        root.appendChild(a)
        root.appendChild(b)

        root.calculateLayout(availableWidth: 40, availableHeight: 10, direction: .rtl)
        // In RTL row: start margin is physical right margin (2), item A sits at [28, 38], B at [18, 28]
        #expect(a.computedMargin(.right) == 2)
        #expect(a.computedMargin(.left) == 0)
        #expect(a.computedLayout.rect == LayoutRect(x: 28, y: 0, width: 10, height: 10))
        #expect(b.computedLayout.rect == LayoutRect(x: 18, y: 0, width: 10, height: 10))
    }

    // MARK: - FlexWrap & AlignContent

    @Test("flexWrap: wrap and wrapReverse with multi-line splitting and gaps")
    func flexWrapMultiLine() {
        let root = FlexNode(style: FlexStyle(
            flexDirection: .row,
            flexWrap: .wrap,
            width: 25,
            height: 20,
            gap: FlexGapValues(row: 2, column: 3)
        ))
        // Item widths: 10, 10 (10+3+10 = 23 <= 25 -> line 0), then 10 (23+3+10 = 36 > 25 -> line 1)
        let c0 = FlexNode(style: FlexStyle(width: 10, height: 4))
        let c1 = FlexNode(style: FlexStyle(width: 10, height: 6))
        let c2 = FlexNode(style: FlexStyle(width: 10, height: 5))
        root.appendChild(c0)
        root.appendChild(c1)
        root.appendChild(c2)

        root.calculateLayout(availableWidth: 25, availableHeight: 20)
        #expect(c0.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 4))
        #expect(c1.computedLayout.rect == LayoutRect(x: 13, y: 0, width: 10, height: 6))
        // Line 0 height = 6, row gap = 2 -> Line 1 starts at y = 8
        #expect(c2.computedLayout.rect == LayoutRect(x: 0, y: 8, width: 10, height: 5))

        // Now wrapReverse: Line 0 at bottom (y = 20 - 6 = 14), Line 1 above it (y = 14 - 2 - 5 = 7)
        root.style.flexWrap = .wrapReverse
        root.calculateLayout(availableWidth: 25, availableHeight: 20)
        #expect(c0.computedLayout.rect == LayoutRect(x: 0, y: 16, width: 10, height: 4))
        #expect(c1.computedLayout.rect == LayoutRect(x: 13, y: 14, width: 10, height: 6))
        #expect(c2.computedLayout.rect == LayoutRect(x: 0, y: 7, width: 10, height: 5))
    }

    @Test("alignContent distributes multi-line cross space (flexEnd, center, spaceBetween, stretch)")
    func alignContentModes() {
        func runAlignContent(_ mode: Align) -> [LayoutRect] {
            let root = FlexNode(style: FlexStyle(
                flexDirection: .row,
                flexWrap: .wrap,
                alignContent: mode,
                width: 10,
                height: 20
            ))
            let a = FlexNode(style: FlexStyle(width: 10, height: 4))
            let b = FlexNode(style: FlexStyle(width: 10, height: 4))
            root.appendChild(a)
            root.appendChild(b)
            root.calculateLayout(availableWidth: 10, availableHeight: 20)
            return [a.computedLayout.rect, b.computedLayout.rect]
        }

        let start = runAlignContent(.flexStart)
        #expect(start[0].y == 0 && start[1].y == 4)

        let end = runAlignContent(.flexEnd)
        #expect(end[0].y == 12 && end[1].y == 16)

        let center = runAlignContent(.center)
        #expect(center[0].y == 6 && center[1].y == 10)

        let between = runAlignContent(.spaceBetween)
        #expect(between[0].y == 0 && between[1].y == 16)

        let around = runAlignContent(.spaceAround)
        #expect(around[0].y == 3 && around[1].y == 13)

        let evenly = runAlignContent(.spaceEvenly)
        #expect(evenly[0].y == 4 && evenly[1].y == 12)

        // Stretch expands lines (each line becomes 10 tall) for auto-height children
        let rootStretch = FlexNode(style: FlexStyle(
            flexDirection: .row,
            flexWrap: .wrap,
            alignContent: .stretch,
            width: 10,
            height: 20
        ))
        let s0 = FlexNode(style: FlexStyle(width: 10))
        let s1 = FlexNode(style: FlexStyle(width: 10))
        rootStretch.appendChild(s0)
        rootStretch.appendChild(s1)
        rootStretch.calculateLayout(availableWidth: 10, availableHeight: 20)
        #expect(s0.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 10))
        #expect(s1.computedLayout.rect == LayoutRect(x: 0, y: 10, width: 10, height: 10))
    }

    // MARK: - FlexGrow, FlexShrink, FlexBasis & Iterative Min/Max Clamping

    @Test("flexGrow proportional distribution and iterative max-clamping freeze")
    func flexGrowAndMaxClamp() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 100, height: 10))
        let a = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0, maxWidth: 20))
        let b = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0))
        let c = FlexNode(style: FlexStyle(flexGrow: 3, flexBasis: 0))
        root.appendChild(a)
        root.appendChild(b)
        root.appendChild(c)

        root.calculateLayout(availableWidth: 100, availableHeight: 10)
        // Pass 1: a=20, b=20, c=60 (exact match since a hits 20) -> test stricter maxWidth=10!
        a.style.maxWidth = 10
        root.calculateLayout(availableWidth: 100, availableHeight: 10)
        // Pass 1: a gets 20 -> clamped to 10 & frozen. Remaining 90 split 1:3 -> b=22.5, c=67.5
        // Edge rounding: a [0..10] w=10, b [10..33] w=23, c [33..100] w=67
        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 10, height: 10))
        #expect(b.computedLayout.rect == LayoutRect(x: 10, y: 0, width: 23, height: 10))
        #expect(c.computedLayout.rect == LayoutRect(x: 33, y: 0, width: 67, height: 10))
        #expect(a.computedLayout.rect.width + b.computedLayout.rect.width + c.computedLayout.rect.width == 100)
    }

    @Test("fractional flexGrow < 1 only consumes proportional fraction of free space")
    func fractionalFlexGrow() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 100, height: 10))
        let a = FlexNode(style: FlexStyle(flexGrow: 0.25, flexBasis: 20))
        root.appendChild(a)

        root.calculateLayout(availableWidth: 100, availableHeight: 10)
        // Free space = 80; 0.25 * 80 = 20 -> final width = 40
        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 40, height: 10))
    }

    @Test("flexShrink weighted by flexBasis with iterative minWidth freeze")
    func flexShrinkAndMinClamp() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 100, height: 10))
        let a = FlexNode(style: FlexStyle(flexShrink: 1, width: 80, minWidth: 60))
        let b = FlexNode(style: FlexStyle(flexShrink: 1, width: 80))
        root.appendChild(a)
        root.appendChild(b)

        root.calculateLayout(availableWidth: 100, availableHeight: 10)
        // Overflow = 60. Pass 1: a=50 (clamped to 60 & frozen), b=50. Pass 2: b shrinks by 40 -> b=40.
        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 60, height: 10))
        #expect(b.computedLayout.rect == LayoutRect(x: 60, y: 0, width: 40, height: 10))
    }

    @Test("minWidth wins over maxWidth when min > max")
    func minOverridesMax() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 100, height: 10))
        let child = FlexNode(style: FlexStyle(width: 50, minWidth: 70, maxWidth: 40))
        root.appendChild(child)
        root.calculateLayout(availableWidth: 100, availableHeight: 10)
        #expect(child.computedLayout.rect.width == 70)
    }

    // MARK: - JustifyContent & AlignItems / AlignSelf

    @Test("justifyContent: flexStart, center, flexEnd, spaceBetween, spaceAround, spaceEvenly")
    func justifyContentModes() {
        func positions(_ justify: Justify) -> [Int] {
            let root = FlexNode(style: FlexStyle(flexDirection: .row, justifyContent: justify, width: 30, height: 5))
            let a = FlexNode(style: FlexStyle(width: 6, height: 5))
            let b = FlexNode(style: FlexStyle(width: 6, height: 5))
            root.appendChild(a)
            root.appendChild(b)
            root.calculateLayout(availableWidth: 30, availableHeight: 5)
            return [a.computedLayout.rect.x, b.computedLayout.rect.x]
        }

        // Total item width = 12, free space = 18
        #expect(positions(.flexStart) == [0, 6])
        #expect(positions(.center) == [9, 15])
        #expect(positions(.flexEnd) == [18, 24])
        #expect(positions(.spaceBetween) == [0, 24])
        // spaceAround: step = 9 -> leading = 4.5 (round -> 5), a=[4.5..10.5] x=5 w=6, b=[19.5..25.5] x=20 w=6
        #expect(positions(.spaceAround) == [5, 20])
        // spaceEvenly: step = 18 / 3 = 6 -> a at 6, b at 18
        #expect(positions(.spaceEvenly) == [6, 18])
    }

    @Test("alignItems and alignSelf overrides (stretch, flexStart, center, flexEnd)")
    func alignItemsAndAlignSelf() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, alignItems: .center, width: 40, height: 20))
        let a = FlexNode(style: FlexStyle(alignSelf: .auto, width: 10, height: 6))      // inherits center -> y=7
        let b = FlexNode(style: FlexStyle(alignSelf: .flexStart, width: 10, height: 6)) // y=0
        let c = FlexNode(style: FlexStyle(alignSelf: .flexEnd, width: 10, height: 6))   // y=14
        let d = FlexNode(style: FlexStyle(alignSelf: .stretch, width: 10))              // height=20, y=0
        root.appendChild(a)
        root.appendChild(b)
        root.appendChild(c)
        root.appendChild(d)

        root.calculateLayout(availableWidth: 40, availableHeight: 20)
        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 7, width: 10, height: 6))
        #expect(b.computedLayout.rect == LayoutRect(x: 10, y: 0, width: 10, height: 6))
        #expect(c.computedLayout.rect == LayoutRect(x: 20, y: 14, width: 10, height: 6))
        #expect(d.computedLayout.rect == LayoutRect(x: 30, y: 0, width: 10, height: 20))
    }

    // MARK: - Margins (incl. Auto Margins), Padding, Border & BoxSizing

    @Test("Auto margins center and push flex items along main and cross axes")
    func autoMargins() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, justifyContent: .flexStart, width: 40, height: 20))
        let leftItem = FlexNode(style: FlexStyle(width: 8, height: 4))
        var rightStyle = FlexStyle(width: 10, height: 6)
        rightStyle.margin.left = .auto
        rightStyle.margin.top = .auto
        rightStyle.margin.bottom = .auto
        let rightItem = FlexNode(style: rightStyle)

        root.appendChild(leftItem)
        root.appendChild(rightItem)
        root.calculateLayout(availableWidth: 40, availableHeight: 20)

        // leftItem at x=0; rightItem pushed to x=30 (marginLeft=22) and vertically centered at y=7 (marginTop/Bottom=7)
        #expect(leftItem.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 8, height: 4))
        #expect(rightItem.computedLayout.rect == LayoutRect(x: 30, y: 7, width: 10, height: 6))
        #expect(rightItem.computedMargin(.left) == 22)
        #expect(rightItem.computedMargin(.top) == 7)
        #expect(rightItem.computedMargin(.bottom) == 7)
    }

    @Test("padding, border, and boxSizing (borderBox vs contentBox)")
    func paddingBorderBoxSizing() {
        // borderBox: width 20 includes padding (2*2=4) + border (1*2=2), leaving inner width 14
        let borderBoxRoot = FlexNode(style: FlexStyle(
            flexDirection: .row,
            width: 20,
            height: 12,
            padding: .all(2),
            border: .all(1),
            boxSizing: .borderBox
        ))
        let bbChild = FlexNode(style: FlexStyle(flexGrow: 1))
        borderBoxRoot.appendChild(bbChild)
        borderBoxRoot.calculateLayout()

        #expect(borderBoxRoot.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 20, height: 12))
        #expect(bbChild.computedLayout.rect == LayoutRect(x: 3, y: 3, width: 14, height: 6))
        #expect(borderBoxRoot.computedPadding(.left) == 2)
        #expect(borderBoxRoot.computedBorder(.top) == 1)

        // contentBox: width 20 is inner content size; border-box adds padding (4) + border (2) = 26
        let contentBoxRoot = FlexNode(style: FlexStyle(
            flexDirection: .row,
            width: 20,
            height: 12,
            padding: .all(2),
            border: .all(1),
            boxSizing: .contentBox
        ))
        let cbChild = FlexNode(style: FlexStyle(flexGrow: 1))
        contentBoxRoot.appendChild(cbChild)
        contentBoxRoot.calculateLayout()

        #expect(contentBoxRoot.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 26, height: 18))
        #expect(cbChild.computedLayout.rect == LayoutRect(x: 3, y: 3, width: 20, height: 12))
    }

    // MARK: - PositionType (.absolute, .relative, .static) & AspectRatio

    @Test("positionType: .absolute insets, stretching, percent sizing, and parent border containing block")
    func absolutePositioning() {
        let root = FlexNode(style: FlexStyle(
            flexDirection: .column,
            width: 42,
            height: 22,
            padding: .all(3),
            border: .all(1)
        ))
        // Containing block for absolute children is padding box: origin (1,1), size 40x20.

        // 1. Explicit top/right + explicit size
        let badge = FlexNode(style: FlexStyle(
            width: 8,
            height: 2,
            position: FlexEdgeValues(top: 1, right: 2),
            positionType: .absolute
        ))

        // 2. Inset stretching via left+right and top+bottom
        let stretched = FlexNode(style: FlexStyle(
            position: FlexEdgeValues(top: 4, right: 5, bottom: 6, left: 5),
            positionType: .absolute
        ))

        // 3. Percent position and size against 40x20 padding box
        let percentOverlay = FlexNode(style: FlexStyle(
            width: .percent(50),
            height: .percent(50),
            position: FlexEdgeValues(top: .percent(25), left: .percent(25)),
            positionType: .absolute
        ))

        // 4. Normal flow child should ignore absolute siblings
        let flowChild = FlexNode(style: FlexStyle(width: 10, height: 4))

        root.appendChild(badge)
        root.appendChild(stretched)
        root.appendChild(percentOverlay)
        root.appendChild(flowChild)
        root.calculateLayout()

        // badge: x = 1 + 40 - 2 - 8 = 31, y = 1 + 1 = 2
        #expect(badge.computedLayout.rect == LayoutRect(x: 31, y: 2, width: 8, height: 2))
        // stretched: x = 1 + 5 = 6, y = 1 + 4 = 5, w = 40 - 10 = 30, h = 20 - 10 = 10
        #expect(stretched.computedLayout.rect == LayoutRect(x: 6, y: 5, width: 30, height: 10))
        // percentOverlay: x = 1 + 10 = 11, y = 1 + 5 = 6, w = 20, h = 10
        #expect(percentOverlay.computedLayout.rect == LayoutRect(x: 11, y: 6, width: 20, height: 10))
        // flowChild starts inside border + padding = (4, 4)
        #expect(flowChild.computedLayout.rect == LayoutRect(x: 4, y: 4, width: 10, height: 4))
    }

    @Test("positionType: .relative offsets child visually without shifting siblings; .static ignores insets")
    func relativeAndStaticPositioning() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 40, height: 10))
        let rel = FlexNode(style: FlexStyle(
            width: 10,
            height: 4,
            position: FlexEdgeValues(top: 3, left: 2),
            positionType: .relative
        ))
        let stat = FlexNode(style: FlexStyle(
            width: 10,
            height: 4,
            position: FlexEdgeValues(top: 5, left: 5),
            positionType: .static
        ))
        root.appendChild(rel)
        root.appendChild(stat)
        root.calculateLayout()

        #expect(rel.computedLayout.rect == LayoutRect(x: 2, y: 3, width: 10, height: 4))
        // `stat` is placed right after `rel`'s original flow box (x=10) and ignores its own insets
        #expect(stat.computedLayout.rect == LayoutRect(x: 10, y: 0, width: 10, height: 4))
    }

    @Test("aspectRatio derives missing dimension in borderBox and contentBox")
    func aspectRatioSizing() {
        let root = FlexNode(style: FlexStyle(flexDirection: .row, width: 40, height: 40))
        let a = FlexNode(style: FlexStyle(alignSelf: .flexStart, width: 20, aspectRatio: 2.0))
        let b = FlexNode(style: FlexStyle(alignSelf: .flexStart, height: 10, aspectRatio: 1.5))
        root.appendChild(a)
        root.appendChild(b)
        root.calculateLayout()

        #expect(a.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 20, height: 10))
        #expect(b.computedLayout.rect == LayoutRect(x: 20, y: 0, width: 15, height: 10))
    }

    // MARK: - Custom MeasureFunc (Wrapped Text / Intrinsic Sizing)

    @Test("Custom MeasureFunc wraps text to parent column width and flex-grow row width")
    func wrappedTextMeasureFunc() {
        // Simple character-wrapping text measurer for a 50-character string
        let textLength = 50
        let textMeasure: FlexMeasureFunc = { maxWidth, widthMode, _, _ in
            switch widthMode {
            case .undefined:
                return FlexSize(width: Float(textLength), height: 1)
            case .exactly, .atMost:
                let cols = max(1, Int(maxWidth.rounded(.down)))
                let lines = (textLength + cols - 1) / cols
                let usedW = min(textLength, cols)
                return FlexSize(width: Float(widthMode == .exactly ? cols : usedW), height: Float(lines))
            }
        }

        // Case 1: Column with fixed width 20 and auto height -> 50 chars wraps to 3 lines
        let colRoot = FlexNode(style: FlexStyle(flexDirection: .column, width: 20))
        let textNode = FlexNode(style: FlexStyle(), measureFunc: textMeasure)
        colRoot.appendChild(textNode)
        colRoot.calculateLayout()

        #expect(colRoot.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 20, height: 3))
        #expect(textNode.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 20, height: 3))

        // Case 2: Split-pane row (width 40, auto height): sidebar 15 + flexGrow text pane (width 25 -> 2 lines)
        let rowRoot = FlexNode(style: FlexStyle(flexDirection: .row, alignItems: .flexStart, width: 40))
        let sidebar = FlexNode(style: FlexStyle(width: 15, height: 1))
        let mainText = FlexNode(
            style: FlexStyle(flexGrow: 1, flexShrink: 1, flexBasis: 0),
            measureFunc: textMeasure
        )
        rowRoot.appendChild(sidebar)
        rowRoot.appendChild(mainText)
        rowRoot.calculateLayout()

        #expect(rowRoot.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 40, height: 2))
        #expect(sidebar.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 15, height: 1))
        #expect(mainText.computedLayout.rect == LayoutRect(x: 15, y: 0, width: 25, height: 2))
    }

    @Test("MeasureFunc respects padding and skips invocation when both axes are exactly constrained")
    func measureFuncPaddingAndSkip() {
        let paddedText = FlexNode(
            style: FlexStyle(padding: .all(1), border: .all(1)),
            measureFunc: { _, _, _, _ in FlexSize(width: 10, height: 2) }
        )
        let root = FlexNode(style: FlexStyle(flexDirection: .column, alignItems: .flexStart))
        root.appendChild(paddedText)
        root.calculateLayout()
        // Inner 10x2 + horizontal pb 4 + vertical pb 4 = 14x6
        #expect(paddedText.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 14, height: 6))

        // Fixed size leaf should not call measureFunc
        let fixedNode = FlexNode(
            style: FlexStyle(width: 12, height: 4),
            measureFunc: { _, _, _, _ in
                Issue.record("measureFunc should be skipped when width and height are both exact")
                return FlexSize(width: 99, height: 99)
            }
        )
        let fixedRoot = FlexNode(style: FlexStyle(width: 30, height: 10))
        fixedRoot.appendChild(fixedNode)
        fixedRoot.calculateLayout()
        #expect(fixedNode.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 12, height: 4))
    }

    // MARK: - Terminal Integer Cell Grid Rounding (Zero Sub-Cell Gaps / Overlaps)

    @Test("Absolute-edge cell grid rounding prevents sub-cell gaps and overlaps across fractional siblings")
    func terminalCellGridRounding() {
        // 3 equal flexGrow items in 10 cells -> 3.333 each -> 3 + 4 + 3 = 10, contiguous!
        let row3 = FlexNode(style: FlexStyle(flexDirection: .row, width: 10, height: 5))
        let items3 = (0..<3).map { _ in FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0)) }
        for item in items3 { row3.appendChild(item) }
        row3.calculateLayout()

        #expect(items3[0].computedLayout.rect == LayoutRect(x: 0, y: 0, width: 3, height: 5))
        #expect(items3[1].computedLayout.rect == LayoutRect(x: 3, y: 0, width: 4, height: 5))
        #expect(items3[2].computedLayout.rect == LayoutRect(x: 7, y: 0, width: 3, height: 5))

        // 7 equal flexGrow items in 80 cells -> verify strict contiguity & exact sum == 80
        let row7 = FlexNode(style: FlexStyle(flexDirection: .row, width: 80, height: 10))
        let items7 = (0..<7).map { _ in FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0)) }
        for item in items7 { row7.appendChild(item) }
        row7.calculateLayout()

        var cursor = 0
        for item in items7 {
            let r = item.computedLayout.rect
            #expect(r.x == cursor)
            #expect(r.width >= 11 && r.width <= 12)
            cursor += r.width
        }
        #expect(cursor == 80)

        // Nested fractional container: parent split 3 ways in 10, middle pane split 2 ways -> exact alignment
        let nestedRoot = FlexNode(style: FlexStyle(flexDirection: .row, width: 10, height: 4))
        let leftPane = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0))
        let midPane = FlexNode(style: FlexStyle(flexDirection: .row, flexGrow: 1, flexBasis: 0))
        let midA = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0))
        let midB = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0))
        midPane.appendChild(midA)
        midPane.appendChild(midB)
        let rightPane = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0))
        nestedRoot.appendChild(leftPane)
        nestedRoot.appendChild(midPane)
        nestedRoot.appendChild(rightPane)
        nestedRoot.calculateLayout()

        let midRect = midPane.computedLayout.rect
        let midARect = midA.computedLayout.rect
        let midBRect = midB.computedLayout.rect
        #expect(midRect.x == leftPane.computedLayout.rect.width)
        #expect(midARect.x == 0)
        #expect(midARect.x + midARect.width == midBRect.x)
        #expect(midBRect.x + midBRect.width == midRect.width)
    }

    // MARK: - Full Realistic Terminal UI Composition

    @Test("Realistic 80x24 TUI layout: header + sidebar/content + footer + modal overlay")
    func fullTUIScreenLayout() {
        let screen = FlexNode(style: FlexStyle(flexDirection: .column))

        let header = FlexNode(style: FlexStyle(height: 1))
        let body = FlexNode(style: FlexStyle(flexDirection: .row, flexGrow: 1, flexBasis: 0))
        let sidebar = FlexNode(style: FlexStyle(width: 24, border: .all(1)))
        let content = FlexNode(style: FlexStyle(flexGrow: 1, flexBasis: 0, padding: .symmetric(horizontal: 2, vertical: 1)))
        let contentText = FlexNode(
            style: FlexStyle(),
            measureFunc: { w, _, _, _ in
                let cols = max(1, Int(w.rounded(.down)))
                // 104 chars in inner width 52 -> 2 lines
                return FlexSize(width: Float(cols), height: Float((104 + cols - 1) / cols))
            }
        )
        content.appendChild(contentText)
        body.appendChild(sidebar)
        body.appendChild(content)

        let footer = FlexNode(style: FlexStyle(height: 1))

        let modal = FlexNode(style: FlexStyle(
            width: 40,
            height: 10,
            position: FlexEdgeValues(top: 7, left: 20),
            positionType: .absolute
        ))

        screen.appendChild(header)
        screen.appendChild(body)
        screen.appendChild(footer)
        screen.appendChild(modal)

        screen.calculateLayout(availableWidth: 80, availableHeight: 24)

        #expect(screen.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 80, height: 24))
        #expect(header.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 80, height: 1))
        #expect(body.computedLayout.rect == LayoutRect(x: 0, y: 1, width: 80, height: 22))
        #expect(sidebar.computedLayout.rect == LayoutRect(x: 0, y: 0, width: 24, height: 22))
        #expect(content.computedLayout.rect == LayoutRect(x: 24, y: 0, width: 56, height: 22))
        // content inner width = 56 - 4 = 52 -> 104 / 52 = 2 lines at (2, 1)
        #expect(contentText.computedLayout.rect == LayoutRect(x: 2, y: 1, width: 52, height: 2))
        #expect(footer.computedLayout.rect == LayoutRect(x: 0, y: 23, width: 80, height: 1))
        #expect(modal.computedLayout.rect == LayoutRect(x: 20, y: 7, width: 40, height: 10))
    }
}
