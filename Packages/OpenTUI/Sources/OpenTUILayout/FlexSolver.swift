// Pure-Swift Yoga-compatible CSS Flexbox layout solver with terminal cell grid rounding.
// Zero OS / Foundation imports (Pure Tier).

public enum FlexSolver: Sendable {
    private static let epsilon: Float = 1e-4

    /// Runs a complete Flexbox layout pass rooted at `root` and rounds positions & dimensions
    /// to `root.pointScaleFactor` using absolute-edge rounding (zero sub-cell gaps or overlaps).
    public static func calculateLayout(
        root: FlexNode,
        availableWidth: Float? = nil,
        availableHeight: Float? = nil,
        direction: Direction = .ltr
    ) {
        let effectiveOwnerDirection: Direction = direction == .inherit ? .ltr : direction
        let rootDirection: Direction = root.style.direction == .inherit ? effectiveOwnerDirection : root.style.direction

        if root.style.display == .none {
            zeroSubtree(root, direction: rootDirection)
            return
        }

        var context = SolverContext()

        let marginLeft = root.style.margin.resolvePoints(.left, ownerSize: availableWidth, direction: rootDirection)
        let marginRight = root.style.margin.resolvePoints(.right, ownerSize: availableWidth, direction: rootDirection)
        let marginTop = root.style.margin.resolvePoints(.top, ownerSize: availableWidth, direction: rootDirection)
        let marginBottom = root.style.margin.resolvePoints(.bottom, ownerSize: availableWidth, direction: rootDirection)

        let pad = resolvePadding(style: root.style, ownerWidth: availableWidth, direction: rootDirection)
        let border = resolveBorder(style: root.style, direction: rootDirection)
        let pbH = pad.horizontal + border.horizontal
        let pbV = pad.vertical + border.vertical

        let minW = resolveBorderBoxBound(
            root.style.minWidth,
            ownerInnerSize: availableWidth,
            pb: pbH,
            boxSizing: root.style.boxSizing
        )
        let maxW = resolveBorderBoxBound(
            root.style.maxWidth,
            ownerInnerSize: availableWidth,
            pb: pbH,
            boxSizing: root.style.boxSizing
        )
        let minH = resolveBorderBoxBound(
            root.style.minHeight,
            ownerInnerSize: availableHeight,
            pb: pbV,
            boxSizing: root.style.boxSizing
        )
        let maxH = resolveBorderBoxBound(
            root.style.maxHeight,
            ownerInnerSize: availableHeight,
            pb: pbV,
            boxSizing: root.style.boxSizing
        )

        var rootW: Float?
        var rootWMode: MeasureMode
        if let explicitW = resolveBorderBoxBound(
            root.style.width,
            ownerInnerSize: availableWidth,
            pb: pbH,
            boxSizing: root.style.boxSizing
        ) {
            rootW = clampSize(explicitW, min: minW, max: maxW, floor: pbH)
            rootWMode = .exactly
        } else if let availableWidth {
            rootW = clampSize(max(0, availableWidth - marginLeft - marginRight), min: minW, max: maxW, floor: pbH)
            rootWMode = .exactly
        } else {
            rootW = nil
            rootWMode = .undefined
        }

        var rootH: Float?
        var rootHMode: MeasureMode
        if let explicitH = resolveBorderBoxBound(
            root.style.height,
            ownerInnerSize: availableHeight,
            pb: pbV,
            boxSizing: root.style.boxSizing
        ) {
            rootH = clampSize(explicitH, min: minH, max: maxH, floor: pbV)
            rootHMode = .exactly
        } else if let availableHeight {
            rootH = clampSize(max(0, availableHeight - marginTop - marginBottom), min: minH, max: maxH, floor: pbV)
            rootHMode = .exactly
        } else {
            rootH = nil
            rootHMode = .undefined
        }

        // Apply aspectRatio on root when exactly one axis is definite.
        if let ratio = validAspectRatio(root.style.aspectRatio) {
            if let w = rootW, rootH == nil {
                let derivedH = aspectHeight(fromWidth: w, ratio: ratio, pbH: pbH, pbV: pbV, boxSizing: root.style.boxSizing)
                rootH = clampSize(derivedH, min: minH, max: maxH, floor: pbV)
                rootHMode = .exactly
            } else if let h = rootH, rootW == nil {
                let derivedW = aspectWidth(fromHeight: h, ratio: ratio, pbH: pbH, pbV: pbV, boxSizing: root.style.boxSizing)
                rootW = clampSize(derivedW, min: minW, max: maxW, floor: pbH)
                rootWMode = .exactly
            }
        }

        let finalRootSize = computeNodeLayout(
            node: root,
            availableWidth: rootW,
            availableHeight: rootH,
            widthMode: rootWMode,
            heightMode: rootHMode,
            ownerWidth: availableWidth,
            ownerHeight: availableHeight,
            ownerDirection: effectiveOwnerDirection,
            performLayout: true,
            context: &context
        )

        var rootX = marginLeft
        var rootY = marginTop
        if root.style.positionType == .relative {
            let relOffset = resolveRelativeOffset(
                style: root.style,
                ownerWidth: availableWidth,
                ownerHeight: availableHeight,
                direction: rootDirection
            )
            rootX += relOffset.x
            rootY += relOffset.y
        }

        root.computedLayout.x = rootX
        root.computedLayout.y = rootY
        root.computedLayout.width = finalRootSize.width
        root.computedLayout.height = finalRootSize.height
        root.computedLayout.margin = FlexInsets(top: marginTop, right: marginRight, bottom: marginBottom, left: marginLeft)

        if root.pointScaleFactor > 0 {
            roundLayoutTree(
                node: root,
                parentAbsLeft: 0,
                parentAbsTop: 0,
                parentRoundedLeft: 0,
                parentRoundedTop: 0,
                scale: root.pointScaleFactor
            )
        }
    }

    // MARK: - Per-Pass Measurement Cache

    private struct MeasureCacheKey: Equatable {
        let availableWidth: Float?
        let widthMode: MeasureMode
        let availableHeight: Float?
        let heightMode: MeasureMode
        let ownerWidth: Float?
        let ownerHeight: Float?
        let ownerDirection: Direction
    }

    private struct MeasureCacheEntry {
        let key: MeasureCacheKey
        let size: FlexSize
    }

    private struct SolverContext {
        var cache: [ObjectIdentifier: [MeasureCacheEntry]] = [:]

        func lookup(node: FlexNode, key: MeasureCacheKey) -> FlexSize? {
            guard let entries = cache[ObjectIdentifier(node)] else { return nil }
            for entry in entries {
                if entry.key == key {
                    return entry.size
                }
            }
            return nil
        }

        mutating func store(node: FlexNode, key: MeasureCacheKey, size: FlexSize) {
            let id = ObjectIdentifier(node)
            var entries = cache[id] ?? []
            if entries.count >= 8 {
                entries.removeFirst()
            }
            entries.append(MeasureCacheEntry(key: key, size: size))
            cache[id] = entries
        }
    }

    // MARK: - Core Recursive Layout

    private static func computeNodeLayout(
        node: FlexNode,
        availableWidth: Float?,
        availableHeight: Float?,
        widthMode: MeasureMode,
        heightMode: MeasureMode,
        ownerWidth: Float?,
        ownerHeight: Float?,
        ownerDirection: Direction,
        performLayout: Bool,
        context: inout SolverContext
    ) -> FlexSize {
        let resolvedDirection: Direction = node.style.direction == .inherit ? ownerDirection : node.style.direction

        if node.style.display == .none {
            if performLayout {
                zeroSubtree(node, direction: resolvedDirection)
            }
            return .zero
        }

        let cacheKey = MeasureCacheKey(
            availableWidth: availableWidth,
            widthMode: widthMode,
            availableHeight: availableHeight,
            heightMode: heightMode,
            ownerWidth: ownerWidth,
            ownerHeight: ownerHeight,
            ownerDirection: ownerDirection
        )
        if !performLayout, let cached = context.lookup(node: node, key: cacheKey) {
            return cached
        }

        let style = node.style
        let pad = resolvePadding(style: style, ownerWidth: ownerWidth, direction: resolvedDirection)
        let border = resolveBorder(style: style, direction: resolvedDirection)
        let pbH = pad.horizontal + border.horizontal
        let pbV = pad.vertical + border.vertical

        let nodeMinW = resolveBorderBoxBound(style.minWidth, ownerInnerSize: ownerWidth, pb: pbH, boxSizing: style.boxSizing)
        let nodeMaxW = resolveBorderBoxBound(style.maxWidth, ownerInnerSize: ownerWidth, pb: pbH, boxSizing: style.boxSizing)
        let nodeMinH = resolveBorderBoxBound(style.minHeight, ownerInnerSize: ownerHeight, pb: pbV, boxSizing: style.boxSizing)
        let nodeMaxH = resolveBorderBoxBound(style.maxHeight, ownerInnerSize: ownerHeight, pb: pbV, boxSizing: style.boxSizing)

        // Leaf node with custom MeasureFunc
        if let measureFunc = node.measureFunc, node.children.isEmpty {
            let measuredSize = measureLeafNode(
                style: style,
                measureFunc: measureFunc,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                widthMode: widthMode,
                heightMode: heightMode,
                pbH: pbH,
                pbV: pbV,
                minW: nodeMinW,
                maxW: nodeMaxW,
                minH: nodeMinH,
                maxH: nodeMaxH
            )
            if performLayout {
                node.computedLayout.width = measuredSize.width
                node.computedLayout.height = measuredSize.height
                node.computedLayout.padding = pad
                node.computedLayout.border = border
                node.computedLayout.direction = resolvedDirection
                node.isDirty = false
                node.hasNewLayout = true
            } else {
                context.store(node: node, key: cacheKey, size: measuredSize)
            }
            return measuredSize
        }

        // Empty leaf without MeasureFunc
        if node.children.isEmpty {
            var w: Float
            if widthMode == .exactly, let availableWidth {
                w = max(pbH, availableWidth)
            } else {
                w = clampSize(pbH, min: nodeMinW, max: nodeMaxW, floor: pbH)
            }

            var h: Float
            if heightMode == .exactly, let availableHeight {
                h = max(pbV, availableHeight)
            } else {
                h = clampSize(pbV, min: nodeMinH, max: nodeMaxH, floor: pbV)
            }

            if let ratio = validAspectRatio(style.aspectRatio) {
                if widthMode == .exactly && heightMode != .exactly {
                    h = clampSize(
                        aspectHeight(fromWidth: w, ratio: ratio, pbH: pbH, pbV: pbV, boxSizing: style.boxSizing),
                        min: nodeMinH,
                        max: nodeMaxH,
                        floor: pbV
                    )
                } else if heightMode == .exactly && widthMode != .exactly {
                    w = clampSize(
                        aspectWidth(fromHeight: h, ratio: ratio, pbH: pbH, pbV: pbV, boxSizing: style.boxSizing),
                        min: nodeMinW,
                        max: nodeMaxW,
                        floor: pbH
                    )
                }
            }

            let result = FlexSize(width: w, height: h)
            if performLayout {
                node.computedLayout.width = w
                node.computedLayout.height = h
                node.computedLayout.padding = pad
                node.computedLayout.border = border
                node.computedLayout.direction = resolvedDirection
                node.isDirty = false
                node.hasNewLayout = true
            } else {
                context.store(node: node, key: cacheKey, size: result)
            }
            return result
        }

        // Flex Container Layout
        let isRow = style.flexDirection == .row || style.flexDirection == .rowReverse
        let isMainAxisReversed: Bool = isRow
            ? ((style.flexDirection == .rowReverse) != (resolvedDirection == .rtl))
            : (style.flexDirection == .columnReverse)
        let isCrossAxisReversed: Bool = isRow
            ? (style.flexWrap == .wrapReverse)
            : ((style.flexWrap == .wrapReverse) != (resolvedDirection == .rtl))

        let innerAvailableWidth: Float? = availableWidth.map { max(0, $0 - pbH) }
        let innerAvailableHeight: Float? = availableHeight.map { max(0, $0 - pbV) }

        let mainAvailable: Float? = isRow ? innerAvailableWidth : innerAvailableHeight
        let mainMode: MeasureMode = isRow ? widthMode : heightMode
        let crossAvailable: Float? = isRow ? innerAvailableHeight : innerAvailableWidth
        let crossMode: MeasureMode = isRow ? heightMode : widthMode
        let mainPB: Float = isRow ? pbH : pbV
        let crossPB: Float = isRow ? pbV : pbH

        let mainGap: Float = isRow
            ? style.gap.resolvePoints(.column, ownerSize: innerAvailableWidth)
            : style.gap.resolvePoints(.row, ownerSize: innerAvailableHeight)
        let crossGap: Float = isRow
            ? style.gap.resolvePoints(.row, ownerSize: innerAvailableHeight)
            : style.gap.resolvePoints(.column, ownerSize: innerAvailableWidth)

        // 1. Collect active flow children & absolute children (flattening display: .contents).
        var flowNodes: [FlexNode] = []
        var absoluteNodes: [FlexNode] = []
        collectEffectiveChildren(
            from: node,
            resolvedDirection: resolvedDirection,
            performLayout: performLayout,
            flow: &flowNodes,
            absolute: &absoluteNodes
        )

        // 2. Build flex items with flexBaseSize & hypotheticalMainSize.
        var items: [FlexItem] = []
        items.reserveCapacity(flowNodes.count)

        for child in flowNodes {
            let childStyle = child.style
            let childDirection: Direction = childStyle.direction == .inherit ? resolvedDirection : childStyle.direction

            let childPad = resolvePadding(style: childStyle, ownerWidth: innerAvailableWidth, direction: childDirection)
            let childBorder = resolveBorder(style: childStyle, direction: childDirection)
            let childPBH = childPad.horizontal + childBorder.horizontal
            let childPBV = childPad.vertical + childBorder.vertical
            let childMainPB = isRow ? childPBH : childPBV
            let childCrossPB = isRow ? childPBV : childPBH

            // Margins (percentages resolve against owner's inner width per CSS/Yoga).
            let mLeftVal = childStyle.margin.resolve(.left, direction: childDirection)
            let mRightVal = childStyle.margin.resolve(.right, direction: childDirection)
            let mTopVal = childStyle.margin.resolve(.top, direction: childDirection)
            let mBottomVal = childStyle.margin.resolve(.bottom, direction: childDirection)

            let mLeftAuto = mLeftVal.isAuto
            let mRightAuto = mRightVal.isAuto
            let mTopAuto = mTopVal.isAuto
            let mBottomAuto = mBottomVal.isAuto

            let mLeft = mLeftVal.resolve(against: innerAvailableWidth) ?? 0
            let mRight = mRightVal.resolve(against: innerAvailableWidth) ?? 0
            let mTop = mTopVal.resolve(against: innerAvailableWidth) ?? 0
            let mBottom = mBottomVal.resolve(against: innerAvailableWidth) ?? 0

            let marginMain = isRow ? (mLeft + mRight) : (mTop + mBottom)
            let marginCross = isRow ? (mTop + mBottom) : (mLeft + mRight)
            let marginCrossStartAuto = isRow ? mTopAuto : mLeftAuto
            let marginCrossEndAuto = isRow ? mBottomAuto : mRightAuto

            let childMinW = resolveBorderBoxBound(childStyle.minWidth, ownerInnerSize: innerAvailableWidth, pb: childPBH, boxSizing: childStyle.boxSizing)
            let childMaxW = resolveBorderBoxBound(childStyle.maxWidth, ownerInnerSize: innerAvailableWidth, pb: childPBH, boxSizing: childStyle.boxSizing)
            let childMinH = resolveBorderBoxBound(childStyle.minHeight, ownerInnerSize: innerAvailableHeight, pb: childPBV, boxSizing: childStyle.boxSizing)
            let childMaxH = resolveBorderBoxBound(childStyle.maxHeight, ownerInnerSize: innerAvailableHeight, pb: childPBV, boxSizing: childStyle.boxSizing)

            let minMain = isRow ? childMinW : childMinH
            let maxMain = isRow ? childMaxW : childMaxH
            let minCross = isRow ? childMinH : childMinW
            let maxCross = isRow ? childMaxH : childMaxW

            let definiteMainStyle = resolveBorderBoxBound(
                isRow ? childStyle.width : childStyle.height,
                ownerInnerSize: mainAvailable,
                pb: childMainPB,
                boxSizing: childStyle.boxSizing
            )
            let definiteCrossStyle = resolveBorderBoxBound(
                isRow ? childStyle.height : childStyle.width,
                ownerInnerSize: crossAvailable,
                pb: childCrossPB,
                boxSizing: childStyle.boxSizing
            )
            let definiteFlexBasis = resolveBorderBoxBound(
                childStyle.flexBasis,
                ownerInnerSize: mainAvailable,
                pb: childMainPB,
                boxSizing: childStyle.boxSizing
            )

            let effectiveAlign = childStyle.alignSelf == .auto ? style.alignItems : childStyle.alignSelf
            let ratio = validAspectRatio(childStyle.aspectRatio)

            let flexBaseSize: Float
            if let basis = definiteFlexBasis {
                flexBaseSize = max(childMainPB, basis)
            } else if let mainDim = definiteMainStyle {
                flexBaseSize = max(childMainPB, mainDim)
            } else if let ratio, let crossDim = definiteCrossStyle {
                let clampedCross = clampSize(crossDim, min: minCross, max: maxCross, floor: childCrossPB)
                if isRow {
                    flexBaseSize = max(childMainPB, aspectWidth(fromHeight: clampedCross, ratio: ratio, pbH: childPBH, pbV: childPBV, boxSizing: childStyle.boxSizing))
                } else {
                    flexBaseSize = max(childMainPB, aspectHeight(fromWidth: clampedCross, ratio: ratio, pbH: childPBH, pbV: childPBV, boxSizing: childStyle.boxSizing))
                }
            } else {
                // Measure intrinsic main size.
                let measureCrossAvail: Float?
                let measureCrossMode: MeasureMode
                if let crossDim = definiteCrossStyle {
                    measureCrossAvail = clampSize(crossDim, min: minCross, max: maxCross, floor: childCrossPB)
                    measureCrossMode = .exactly
                } else if style.flexWrap == .noWrap,
                          crossMode == .exactly,
                          let crossAvailable,
                          effectiveAlign == .stretch,
                          !marginCrossStartAuto && !marginCrossEndAuto
                {
                    measureCrossAvail = clampSize(max(0, crossAvailable - marginCross), min: minCross, max: maxCross, floor: childCrossPB)
                    measureCrossMode = .exactly
                } else if let maxCross {
                    let avail = crossAvailable.map { min(max(0, $0 - marginCross), maxCross) } ?? maxCross
                    measureCrossAvail = max(childCrossPB, avail)
                    measureCrossMode = .atMost
                } else if let crossAvailable {
                    measureCrossAvail = max(0, crossAvailable - marginCross)
                    measureCrossMode = .atMost
                } else {
                    measureCrossAvail = nil
                    measureCrossMode = .undefined
                }

                let measureMainAvail: Float?
                let measureMainMode: MeasureMode
                if let maxMain {
                    if isRow, let mainAvailable {
                        measureMainAvail = max(childMainPB, min(max(0, mainAvailable - marginMain), maxMain))
                    } else {
                        measureMainAvail = max(childMainPB, maxMain)
                    }
                    measureMainMode = .atMost
                } else if isRow, let mainAvailable, mainMode != .undefined {
                    measureMainAvail = max(0, mainAvailable - marginMain)
                    measureMainMode = .atMost
                } else {
                    measureMainAvail = nil
                    measureMainMode = .undefined
                }

                let mW = isRow ? measureMainAvail : measureCrossAvail
                let mWMode = isRow ? measureMainMode : measureCrossMode
                let mH = isRow ? measureCrossAvail : measureMainAvail
                let mHMode = isRow ? measureCrossMode : measureMainMode

                let measured = computeNodeLayout(
                    node: child,
                    availableWidth: mW,
                    availableHeight: mH,
                    widthMode: mWMode,
                    heightMode: mHMode,
                    ownerWidth: innerAvailableWidth,
                    ownerHeight: innerAvailableHeight,
                    ownerDirection: resolvedDirection,
                    performLayout: false,
                    context: &context
                )
                flexBaseSize = max(childMainPB, isRow ? measured.width : measured.height)
            }

            let hypotheticalMain = clampSize(flexBaseSize, min: minMain, max: maxMain, floor: childMainPB)

            items.append(FlexItem(
                node: child,
                direction: childDirection,
                marginLeft: mLeft,
                marginRight: mRight,
                marginTop: mTop,
                marginBottom: mBottom,
                marginLeftAuto: mLeftAuto,
                marginRightAuto: mRightAuto,
                marginTopAuto: mTopAuto,
                marginBottomAuto: mBottomAuto,
                childPBH: childPBH,
                childPBV: childPBV,
                childMainPB: childMainPB,
                childCrossPB: childCrossPB,
                minMain: minMain,
                maxMain: maxMain,
                minCross: minCross,
                maxCross: maxCross,
                definiteCrossStyle: definiteCrossStyle,
                flexBaseSize: flexBaseSize,
                hypotheticalMainSize: hypotheticalMain,
                targetMainSize: hypotheticalMain,
                hypotheticalCrossSize: 0,
                finalCrossSize: 0
            ))
        }

        // 3. Collect flex lines (`noWrap`, `wrap`, `wrapReverse`).
        var lines: [FlexLine] = []
        if !items.isEmpty {
            if style.flexWrap == .noWrap || mainAvailable == nil {
                lines.append(FlexLine(indices: Array(0..<items.count)))
            } else {
                let limit = mainAvailable!
                var currentIndices: [Int] = []
                var currentMain: Float = 0

                for i in 0..<items.count {
                    let outerHypMain = items[i].hypotheticalMainSize + items[i].marginMain(isRow: isRow)
                    let gapIfAdded: Float = currentIndices.isEmpty ? 0 : mainGap
                    if !currentIndices.isEmpty && (currentMain + gapIfAdded + outerHypMain > limit + epsilon) {
                        lines.append(FlexLine(indices: currentIndices))
                        currentIndices = [i]
                        currentMain = outerHypMain
                    } else {
                        currentIndices.append(i)
                        currentMain += gapIfAdded + outerHypMain
                    }
                }
                if !currentIndices.isEmpty {
                    lines.append(FlexLine(indices: currentIndices))
                }
            }
        }

        // 4. Resolve flexible lengths per line (CSS Flexbox §9.7 iterative freezing).
        for lineIdx in 0..<lines.count {
            let indices = lines[lineIdx].indices
            let totalGaps = mainGap * Float(max(0, indices.count - 1))
            var outerHypSum = totalGaps
            for i in indices {
                outerHypSum += items[i].hypotheticalMainSize + items[i].marginMain(isRow: isRow)
            }

            let targetLineMain: Float
            if let mainAvailable {
                switch mainMode {
                case .exactly:
                    targetLineMain = mainAvailable
                case .atMost:
                    targetLineMain = outerHypSum > mainAvailable ? mainAvailable : outerHypSum
                case .undefined:
                    targetLineMain = outerHypSum
                }
            } else {
                targetLineMain = outerHypSum
            }

            resolveFlexibleLengths(
                items: &items,
                indices: indices,
                isRow: isRow,
                targetMainSize: targetLineMain,
                totalGaps: totalGaps
            )
        }

        // 5. Determine hypothetical cross size of each item & cross size of each line.
        let isSingleLineContainer = style.flexWrap == .noWrap

        for lineIdx in 0..<lines.count {
            let indices = lines[lineIdx].indices
            var maxLineCross: Float = 0

            for i in indices {
                let child = items[i].node
                let childStyle = child.style
                let effectiveAlign = childStyle.alignSelf == .auto ? style.alignItems : childStyle.alignSelf
                let marginCross = items[i].marginCross(isRow: isRow)
                let marginCrossStartAuto = isRow ? items[i].marginTopAuto : items[i].marginLeftAuto
                let marginCrossEndAuto = isRow ? items[i].marginBottomAuto : items[i].marginRightAuto
                let ratio = validAspectRatio(childStyle.aspectRatio)

                let crossSize: Float
                if let defCross = items[i].definiteCrossStyle {
                    crossSize = clampSize(defCross, min: items[i].minCross, max: items[i].maxCross, floor: items[i].childCrossPB)
                } else if let ratio {
                    let derived = isRow
                        ? aspectHeight(fromWidth: items[i].targetMainSize, ratio: ratio, pbH: items[i].childPBH, pbV: items[i].childPBV, boxSizing: childStyle.boxSizing)
                        : aspectWidth(fromHeight: items[i].targetMainSize, ratio: ratio, pbH: items[i].childPBH, pbV: items[i].childPBV, boxSizing: childStyle.boxSizing)
                    crossSize = clampSize(derived, min: items[i].minCross, max: items[i].maxCross, floor: items[i].childCrossPB)
                } else if isSingleLineContainer,
                          crossMode == .exactly,
                          let crossAvailable,
                          effectiveAlign == .stretch,
                          !marginCrossStartAuto && !marginCrossEndAuto
                {
                    crossSize = clampSize(max(0, crossAvailable - marginCross), min: items[i].minCross, max: items[i].maxCross, floor: items[i].childCrossPB)
                } else {
                    let mCrossAvail: Float?
                    let mCrossMode: MeasureMode
                    if let maxCross = items[i].maxCross {
                        let bound = crossAvailable.map { min(max(0, $0 - marginCross), maxCross) } ?? maxCross
                        mCrossAvail = max(items[i].childCrossPB, bound)
                        mCrossMode = .atMost
                    } else if let crossAvailable, crossMode != .undefined {
                        mCrossAvail = max(0, crossAvailable - marginCross)
                        mCrossMode = .atMost
                    } else {
                        mCrossAvail = nil
                        mCrossMode = .undefined
                    }

                    let mW = isRow ? items[i].targetMainSize : mCrossAvail
                    let mWMode: MeasureMode = isRow ? .exactly : mCrossMode
                    let mH = isRow ? mCrossAvail : items[i].targetMainSize
                    let mHMode: MeasureMode = isRow ? mCrossMode : .exactly

                    let measured = computeNodeLayout(
                        node: child,
                        availableWidth: mW,
                        availableHeight: mH,
                        widthMode: mWMode,
                        heightMode: mHMode,
                        ownerWidth: innerAvailableWidth,
                        ownerHeight: innerAvailableHeight,
                        ownerDirection: resolvedDirection,
                        performLayout: false,
                        context: &context
                    )
                    let rawCross = isRow ? measured.height : measured.width
                    crossSize = clampSize(rawCross, min: items[i].minCross, max: items[i].maxCross, floor: items[i].childCrossPB)
                }

                items[i].hypotheticalCrossSize = crossSize
                let outerCross = crossSize + marginCross
                if outerCross > maxLineCross {
                    maxLineCross = outerCross
                }
            }

            if isSingleLineContainer, crossMode == .exactly, let crossAvailable {
                lines[lineIdx].crossSize = crossAvailable
            } else {
                lines[lineIdx].crossSize = maxLineCross
            }
        }

        // 6. Multi-line `alignContent: .stretch` expands lines to fill definite cross space.
        if !isSingleLineContainer,
           style.alignContent == .stretch,
           crossMode == .exactly,
           let crossAvailable,
           !lines.isEmpty
        {
            let totalCrossGaps = crossGap * Float(max(0, lines.count - 1))
            var usedCross = totalCrossGaps
            for line in lines {
                usedCross += line.crossSize
            }
            if crossAvailable > usedCross {
                let extraPerLine = (crossAvailable - usedCross) / Float(lines.count)
                for lineIdx in 0..<lines.count {
                    lines[lineIdx].crossSize += extraPerLine
                }
            }
        }

        // 7. Determine final cross size of each item (handling stretch).
        for lineIdx in 0..<lines.count {
            let lineCross = lines[lineIdx].crossSize
            for i in lines[lineIdx].indices {
                let childStyle = items[i].node.style
                let effectiveAlign = childStyle.alignSelf == .auto ? style.alignItems : childStyle.alignSelf
                let marginCross = items[i].marginCross(isRow: isRow)
                let marginCrossStartAuto = isRow ? items[i].marginTopAuto : items[i].marginLeftAuto
                let marginCrossEndAuto = isRow ? items[i].marginBottomAuto : items[i].marginRightAuto

                let canStretch = effectiveAlign == .stretch
                    && items[i].definiteCrossStyle == nil
                    && validAspectRatio(childStyle.aspectRatio) == nil
                    && !marginCrossStartAuto
                    && !marginCrossEndAuto

                if canStretch {
                    items[i].finalCrossSize = clampSize(
                        max(0, lineCross - marginCross),
                        min: items[i].minCross,
                        max: items[i].maxCross,
                        floor: items[i].childCrossPB
                    )
                } else {
                    items[i].finalCrossSize = items[i].hypotheticalCrossSize
                }
            }
        }

        // 8. Compute container's final border-box dimensions.
        var maxContentMain: Float = 0
        for line in lines {
            var lineMain = mainGap * Float(max(0, line.indices.count - 1))
            for i in line.indices {
                lineMain += items[i].targetMainSize + items[i].marginMain(isRow: isRow)
            }
            if lineMain > maxContentMain {
                maxContentMain = lineMain
            }
        }

        var totalContentCross = crossGap * Float(max(0, lines.count - 1))
        for line in lines {
            totalContentCross += line.crossSize
        }

        let nodeMainMin = isRow ? nodeMinW : nodeMinH
        let nodeMainMax = isRow ? nodeMaxW : nodeMaxH
        let nodeCrossMin = isRow ? nodeMinH : nodeMinW
        let nodeCrossMax = isRow ? nodeMaxH : nodeMaxW

        let containerMainSize: Float
        if mainMode == .exactly, let availableMain = (isRow ? availableWidth : availableHeight) {
            containerMainSize = max(mainPB, availableMain)
        } else {
            containerMainSize = clampSize(maxContentMain + mainPB, min: nodeMainMin, max: nodeMainMax, floor: mainPB)
        }

        let containerCrossSize: Float
        if crossMode == .exactly, let availableCross = (isRow ? availableHeight : availableWidth) {
            containerCrossSize = max(crossPB, availableCross)
        } else {
            containerCrossSize = clampSize(totalContentCross + crossPB, min: nodeCrossMin, max: nodeCrossMax, floor: crossPB)
        }

        let finalWidth = isRow ? containerMainSize : containerCrossSize
        let finalHeight = isRow ? containerCrossSize : containerMainSize

        if !performLayout {
            let result = FlexSize(width: finalWidth, height: finalHeight)
            context.store(node: node, key: cacheKey, size: result)
            return result
        }

        // 9. Position lines & items along main and cross axes, then recurse into flow children.
        let containerInnerWidth = max(0, finalWidth - pbH)
        let containerInnerHeight = max(0, finalHeight - pbV)
        let containerInnerMain = isRow ? containerInnerWidth : containerInnerHeight
        let containerInnerCross = isRow ? containerInnerHeight : containerInnerWidth
        let contentStartMain = isRow ? (border.left + pad.left) : (border.top + pad.top)
        let contentStartCross = isRow ? (border.top + pad.top) : (border.left + pad.left)

        // Position lines along cross axis (`alignContent`).
        let freeCross = containerInnerCross - totalContentCross
        var lineLeadingCross: Float = 0
        var lineBetweenCross: Float = crossGap

        switch style.alignContent {
        case .flexStart, .stretch, .auto, .baseline:
            lineLeadingCross = 0
        case .flexEnd:
            lineLeadingCross = freeCross
        case .center:
            lineLeadingCross = freeCross / 2
        case .spaceBetween:
            if lines.count > 1 && freeCross > 0 {
                lineBetweenCross = crossGap + freeCross / Float(lines.count - 1)
            }
        case .spaceAround:
            if !lines.isEmpty && freeCross > 0 {
                let step = freeCross / Float(lines.count)
                lineLeadingCross = step / 2
                lineBetweenCross = crossGap + step
            } else if !lines.isEmpty {
                lineLeadingCross = freeCross / 2
            }
        case .spaceEvenly:
            if !lines.isEmpty && freeCross > 0 {
                let step = freeCross / Float(lines.count + 1)
                lineLeadingCross = step
                lineBetweenCross = crossGap + step
            } else if !lines.isEmpty {
                lineLeadingCross = freeCross / 2
            }
        }

        if !isCrossAxisReversed {
            var crossCursor = contentStartCross + lineLeadingCross
            for lineIdx in 0..<lines.count {
                lines[lineIdx].crossPos = crossCursor
                crossCursor += lines[lineIdx].crossSize + lineBetweenCross
            }
        } else {
            var crossCursor = contentStartCross + containerInnerCross - lineLeadingCross
            for lineIdx in 0..<lines.count {
                crossCursor -= lines[lineIdx].crossSize
                lines[lineIdx].crossPos = crossCursor
                crossCursor -= lineBetweenCross
            }
        }

        // Position items within each line along main & cross axes.
        for lineIdx in 0..<lines.count {
            let line = lines[lineIdx]
            let indices = line.indices
            let count = indices.count
            guard count > 0 else { continue }

            var usedMain = mainGap * Float(max(0, count - 1))
            var mainAutoCount = 0
            for i in indices {
                usedMain += items[i].targetMainSize + items[i].marginMain(isRow: isRow)
                if isRow {
                    if items[i].marginLeftAuto { mainAutoCount += 1 }
                    if items[i].marginRightAuto { mainAutoCount += 1 }
                } else {
                    if items[i].marginTopAuto { mainAutoCount += 1 }
                    if items[i].marginBottomAuto { mainAutoCount += 1 }
                }
            }

            var freeMain = containerInnerMain - usedMain

            // Main-axis auto margins absorb positive remaining space before justifyContent.
            if mainAutoCount > 0 && freeMain > 0 {
                let perAuto = freeMain / Float(mainAutoCount)
                for i in indices {
                    if isRow {
                        if items[i].marginLeftAuto { items[i].marginLeft += perAuto }
                        if items[i].marginRightAuto { items[i].marginRight += perAuto }
                    } else {
                        if items[i].marginTopAuto { items[i].marginTop += perAuto }
                        if items[i].marginBottomAuto { items[i].marginBottom += perAuto }
                    }
                }
                freeMain = 0
            }

            var leadingMain: Float = 0
            var betweenMain: Float = mainGap

            switch style.justifyContent {
            case .flexStart:
                leadingMain = 0
            case .flexEnd:
                leadingMain = freeMain
            case .center:
                leadingMain = freeMain / 2
            case .spaceBetween:
                if count > 1 && freeMain > 0 {
                    betweenMain = mainGap + freeMain / Float(count - 1)
                }
            case .spaceAround:
                if freeMain > 0 {
                    let step = freeMain / Float(count)
                    leadingMain = step / 2
                    betweenMain = mainGap + step
                } else {
                    leadingMain = freeMain / 2
                }
            case .spaceEvenly:
                if freeMain > 0 {
                    let step = freeMain / Float(count + 1)
                    leadingMain = step
                    betweenMain = mainGap + step
                } else {
                    leadingMain = freeMain / 2
                }
            }

            var mainCursor: Float = isMainAxisReversed
                ? (contentStartMain + containerInnerMain - leadingMain)
                : (contentStartMain + leadingMain)

            for i in indices {
                let mMainStart = isRow ? items[i].marginLeft : items[i].marginTop
                let mMainEnd = isRow ? items[i].marginRight : items[i].marginBottom

                let mainPos: Float
                if !isMainAxisReversed {
                    mainPos = mainCursor + mMainStart
                    mainCursor += mMainStart + items[i].targetMainSize + mMainEnd + betweenMain
                } else {
                    mainCursor -= mMainEnd + items[i].targetMainSize
                    mainPos = mainCursor
                    mainCursor -= mMainStart + betweenMain
                }

                // Cross-axis alignment inside line
                let mCrossStartAuto = isRow ? items[i].marginTopAuto : items[i].marginLeftAuto
                let mCrossEndAuto = isRow ? items[i].marginBottomAuto : items[i].marginRightAuto
                var mCrossStart = isRow ? items[i].marginTop : items[i].marginLeft
                var mCrossEnd = isRow ? items[i].marginBottom : items[i].marginRight

                let itemFreeCross = line.crossSize - (items[i].finalCrossSize + mCrossStart + mCrossEnd)
                let crossOffset: Float

                if mCrossStartAuto && mCrossEndAuto {
                    if itemFreeCross > 0 {
                        let half = itemFreeCross / 2
                        mCrossStart += half
                        mCrossEnd += half
                    }
                    crossOffset = mCrossStart
                } else if mCrossStartAuto {
                    if itemFreeCross > 0 {
                        mCrossStart += itemFreeCross
                    }
                    crossOffset = mCrossStart
                } else if mCrossEndAuto {
                    if itemFreeCross > 0 {
                        mCrossEnd += itemFreeCross
                    }
                    crossOffset = mCrossStart
                } else {
                    let rawAlign = items[i].node.style.alignSelf == .auto
                        ? style.alignItems
                        : items[i].node.style.alignSelf
                    let effectiveCrossAlign: Align
                    switch rawAlign {
                    case .flexStart, .stretch, .auto, .baseline:
                        effectiveCrossAlign = isCrossAxisReversed ? .flexEnd : .flexStart
                    case .flexEnd:
                        effectiveCrossAlign = isCrossAxisReversed ? .flexStart : .flexEnd
                    case .center:
                        effectiveCrossAlign = .center
                    default:
                        effectiveCrossAlign = isCrossAxisReversed ? .flexEnd : .flexStart
                    }

                    switch effectiveCrossAlign {
                    case .flexEnd:
                        crossOffset = line.crossSize - items[i].finalCrossSize - mCrossEnd
                    case .center:
                        crossOffset = mCrossStart + itemFreeCross / 2
                    default:
                        crossOffset = mCrossStart
                    }
                }

                if isRow {
                    items[i].marginTop = mCrossStart
                    items[i].marginBottom = mCrossEnd
                } else {
                    items[i].marginLeft = mCrossStart
                    items[i].marginRight = mCrossEnd
                }

                let crossPos = line.crossPos + crossOffset
                var childX = isRow ? mainPos : crossPos
                var childY = isRow ? crossPos : mainPos

                // Apply `.relative` visual offsets (does not affect sibling flow).
                if items[i].node.style.positionType == .relative {
                    let offset = resolveRelativeOffset(
                        style: items[i].node.style,
                        ownerWidth: containerInnerWidth,
                        ownerHeight: containerInnerHeight,
                        direction: items[i].direction
                    )
                    childX += offset.x
                    childY += offset.y
                }

                let childW = isRow ? items[i].targetMainSize : items[i].finalCrossSize
                let childH = isRow ? items[i].finalCrossSize : items[i].targetMainSize

                _ = computeNodeLayout(
                    node: items[i].node,
                    availableWidth: childW,
                    availableHeight: childH,
                    widthMode: .exactly,
                    heightMode: .exactly,
                    ownerWidth: containerInnerWidth,
                    ownerHeight: containerInnerHeight,
                    ownerDirection: resolvedDirection,
                    performLayout: true,
                    context: &context
                )

                items[i].node.computedLayout.x = childX
                items[i].node.computedLayout.y = childY
                items[i].node.computedLayout.margin = FlexInsets(
                    top: items[i].marginTop,
                    right: items[i].marginRight,
                    bottom: items[i].marginBottom,
                    left: items[i].marginLeft
                )
            }
        }

        // 10. Lay out out-of-flow `.absolute` children against container's padding box.
        if !absoluteNodes.isEmpty {
            layoutAbsoluteChildren(
                absoluteNodes,
                containerStyle: style,
                containerWidth: finalWidth,
                containerHeight: finalHeight,
                containerPadding: pad,
                containerBorder: border,
                resolvedDirection: resolvedDirection,
                isRow: isRow,
                isMainAxisReversed: isMainAxisReversed,
                isCrossAxisReversed: isCrossAxisReversed,
                context: &context
            )
        }

        // 11. Finalize container layout metadata.
        node.computedLayout.width = finalWidth
        node.computedLayout.height = finalHeight
        node.computedLayout.padding = pad
        node.computedLayout.border = border
        node.computedLayout.direction = resolvedDirection
        node.isDirty = false
        node.hasNewLayout = true

        return FlexSize(width: finalWidth, height: finalHeight)
    }

    // MARK: - Flex Line Items & Flexible Length Resolution

    private struct FlexItem {
        let node: FlexNode
        let direction: Direction
        var marginLeft: Float
        var marginRight: Float
        var marginTop: Float
        var marginBottom: Float
        let marginLeftAuto: Bool
        let marginRightAuto: Bool
        let marginTopAuto: Bool
        let marginBottomAuto: Bool
        let childPBH: Float
        let childPBV: Float
        let childMainPB: Float
        let childCrossPB: Float
        let minMain: Float?
        let maxMain: Float?
        let minCross: Float?
        let maxCross: Float?
        let definiteCrossStyle: Float?
        let flexBaseSize: Float
        let hypotheticalMainSize: Float
        var targetMainSize: Float
        var hypotheticalCrossSize: Float
        var finalCrossSize: Float

        func marginMain(isRow: Bool) -> Float {
            isRow ? (marginLeft + marginRight) : (marginTop + marginBottom)
        }

        func marginCross(isRow: Bool) -> Float {
            isRow ? (marginTop + marginBottom) : (marginLeft + marginRight)
        }
    }

    private struct FlexLine {
        let indices: [Int]
        var crossSize: Float = 0
        var crossPos: Float = 0
    }

    private static func resolveFlexibleLengths(
        items: inout [FlexItem],
        indices: [Int],
        isRow: Bool,
        targetMainSize: Float,
        totalGaps: Float
    ) {
        let count = indices.count
        guard count > 0 else { return }

        var outerHypSum = totalGaps
        for i in indices {
            outerHypSum += items[i].hypotheticalMainSize + items[i].marginMain(isRow: isRow)
        }

        let usingGrow = outerHypSum < targetMainSize
        var frozen = Array(repeating: false, count: count)

        for local in 0..<count {
            let idx = indices[local]
            let factor = usingGrow ? max(0, items[idx].node.style.flexGrow) : max(0, items[idx].node.style.flexShrink)
            let violatesInDirection = usingGrow
                ? (items[idx].flexBaseSize > items[idx].hypotheticalMainSize + epsilon)
                : (items[idx].flexBaseSize < items[idx].hypotheticalMainSize - epsilon)
            if factor == 0 || violatesInDirection {
                frozen[local] = true
                items[idx].targetMainSize = items[idx].hypotheticalMainSize
            } else {
                items[idx].targetMainSize = items[idx].flexBaseSize
            }
        }

        var initialUsed = totalGaps
        for local in 0..<count {
            let idx = indices[local]
            initialUsed += (frozen[local] ? items[idx].targetMainSize : items[idx].flexBaseSize)
                + items[idx].marginMain(isRow: isRow)
        }
        let initialFreeSpace = targetMainSize - initialUsed

        var violations = Array(repeating: Float(0), count: count)

        while true {
            var unfrozenCount = 0
            var usedMain = totalGaps
            var sumFlexFactors: Float = 0
            var sumScaledShrink: Float = 0

            for local in 0..<count {
                let idx = indices[local]
                let marginMain = items[idx].marginMain(isRow: isRow)
                if frozen[local] {
                    usedMain += items[idx].targetMainSize + marginMain
                } else {
                    unfrozenCount += 1
                    usedMain += items[idx].flexBaseSize + marginMain
                    if usingGrow {
                        sumFlexFactors += max(0, items[idx].node.style.flexGrow)
                    } else {
                        let shrink = max(0, items[idx].node.style.flexShrink)
                        sumFlexFactors += shrink
                        sumScaledShrink += shrink * items[idx].flexBaseSize
                    }
                }
            }

            if unfrozenCount == 0 { break }

            var remainingFreeSpace = targetMainSize - usedMain
            if sumFlexFactors > 0 && sumFlexFactors < 1 {
                let scaledInitial = initialFreeSpace * sumFlexFactors
                if abs(scaledInitial) < abs(remainingFreeSpace) {
                    remainingFreeSpace = scaledInitial
                }
            }

            var totalViolation: Float = 0

            for local in 0..<count where !frozen[local] {
                let idx = indices[local]
                var candidate = items[idx].flexBaseSize

                if usingGrow {
                    if remainingFreeSpace > 0 && sumFlexFactors > 0 {
                        let grow = max(0, items[idx].node.style.flexGrow)
                        candidate = items[idx].flexBaseSize + remainingFreeSpace * (grow / sumFlexFactors)
                    }
                } else {
                    if remainingFreeSpace < 0 && sumScaledShrink > 0 {
                        let shrink = max(0, items[idx].node.style.flexShrink)
                        let ratio = (shrink * items[idx].flexBaseSize) / sumScaledShrink
                        candidate = items[idx].flexBaseSize + remainingFreeSpace * ratio
                    }
                }

                let clamped = clampSize(
                    candidate,
                    min: items[idx].minMain,
                    max: items[idx].maxMain,
                    floor: items[idx].childMainPB
                )
                let violation = clamped - candidate
                items[idx].targetMainSize = clamped
                violations[local] = violation
                totalViolation += violation
            }

            if abs(totalViolation) < 1e-5 {
                break
            }

            var frozeAny = false
            if totalViolation > 0 {
                for local in 0..<count where !frozen[local] && violations[local] > 1e-5 {
                    frozen[local] = true
                    frozeAny = true
                }
            } else {
                for local in 0..<count where !frozen[local] && violations[local] < -1e-5 {
                    frozen[local] = true
                    frozeAny = true
                }
            }

            if !frozeAny {
                break
            }
        }
    }

    // MARK: - Absolute Positioning

    private static func layoutAbsoluteChildren(
        _ children: [FlexNode],
        containerStyle: FlexStyle,
        containerWidth: Float,
        containerHeight: Float,
        containerPadding: FlexInsets,
        containerBorder: FlexInsets,
        resolvedDirection: Direction,
        isRow: Bool,
        isMainAxisReversed: Bool,
        isCrossAxisReversed: Bool,
        context: inout SolverContext
    ) {
        // Containing block is parent's padding box (inside parent's border).
        let cbX = containerBorder.left
        let cbY = containerBorder.top
        let cbWidth = max(0, containerWidth - containerBorder.horizontal)
        let cbHeight = max(0, containerHeight - containerBorder.vertical)

        let innerX = containerBorder.left + containerPadding.left
        let innerY = containerBorder.top + containerPadding.top
        let innerW = max(0, containerWidth - containerBorder.horizontal - containerPadding.horizontal)
        let innerH = max(0, containerHeight - containerBorder.vertical - containerPadding.vertical)

        for child in children {
            let childStyle = child.style
            let childDirection: Direction = childStyle.direction == .inherit ? resolvedDirection : childStyle.direction

            let childPad = resolvePadding(style: childStyle, ownerWidth: cbWidth, direction: childDirection)
            let childBorder = resolveBorder(style: childStyle, direction: childDirection)
            let childPBH = childPad.horizontal + childBorder.horizontal
            let childPBV = childPad.vertical + childBorder.vertical

            let mLeftVal = childStyle.margin.resolve(.left, direction: childDirection)
            let mRightVal = childStyle.margin.resolve(.right, direction: childDirection)
            let mTopVal = childStyle.margin.resolve(.top, direction: childDirection)
            let mBottomVal = childStyle.margin.resolve(.bottom, direction: childDirection)

            let mLeftAuto = mLeftVal.isAuto
            let mRightAuto = mRightVal.isAuto
            let mTopAuto = mTopVal.isAuto
            let mBottomAuto = mBottomVal.isAuto

            var mLeft = mLeftVal.resolve(against: cbWidth) ?? 0
            var mRight = mRightVal.resolve(against: cbWidth) ?? 0
            var mTop = mTopVal.resolve(against: cbWidth) ?? 0
            var mBottom = mBottomVal.resolve(against: cbWidth) ?? 0

            let posLeft = childStyle.position.resolve(.left, direction: childDirection).resolve(against: cbWidth)
            let posRight = childStyle.position.resolve(.right, direction: childDirection).resolve(against: cbWidth)
            let posTop = childStyle.position.resolve(.top, direction: childDirection).resolve(against: cbHeight)
            let posBottom = childStyle.position.resolve(.bottom, direction: childDirection).resolve(against: cbHeight)

            let minW = resolveBorderBoxBound(childStyle.minWidth, ownerInnerSize: cbWidth, pb: childPBH, boxSizing: childStyle.boxSizing)
            let maxW = resolveBorderBoxBound(childStyle.maxWidth, ownerInnerSize: cbWidth, pb: childPBH, boxSizing: childStyle.boxSizing)
            let minH = resolveBorderBoxBound(childStyle.minHeight, ownerInnerSize: cbHeight, pb: childPBV, boxSizing: childStyle.boxSizing)
            let maxH = resolveBorderBoxBound(childStyle.maxHeight, ownerInnerSize: cbHeight, pb: childPBV, boxSizing: childStyle.boxSizing)

            var width: Float?
            if let explicitW = resolveBorderBoxBound(childStyle.width, ownerInnerSize: cbWidth, pb: childPBH, boxSizing: childStyle.boxSizing) {
                width = clampSize(explicitW, min: minW, max: maxW, floor: childPBH)
            } else if let posLeft, let posRight {
                width = clampSize(max(0, cbWidth - posLeft - posRight - mLeft - mRight), min: minW, max: maxW, floor: childPBH)
            }

            var height: Float?
            if let explicitH = resolveBorderBoxBound(childStyle.height, ownerInnerSize: cbHeight, pb: childPBV, boxSizing: childStyle.boxSizing) {
                height = clampSize(explicitH, min: minH, max: maxH, floor: childPBV)
            } else if let posTop, let posBottom {
                height = clampSize(max(0, cbHeight - posTop - posBottom - mTop - mBottom), min: minH, max: maxH, floor: childPBV)
            }

            if let ratio = validAspectRatio(childStyle.aspectRatio) {
                if let w = width, height == nil {
                    height = clampSize(
                        aspectHeight(fromWidth: w, ratio: ratio, pbH: childPBH, pbV: childPBV, boxSizing: childStyle.boxSizing),
                        min: minH,
                        max: maxH,
                        floor: childPBV
                    )
                } else if let h = height, width == nil {
                    width = clampSize(
                        aspectWidth(fromHeight: h, ratio: ratio, pbH: childPBH, pbV: childPBV, boxSizing: childStyle.boxSizing),
                        min: minW,
                        max: maxW,
                        floor: childPBH
                    )
                }
            }

            if width == nil || height == nil {
                let measureW = width ?? maxW
                let measureWMode: MeasureMode = width != nil ? .exactly : (maxW != nil ? .atMost : .undefined)
                let measureH = height ?? maxH
                let measureHMode: MeasureMode = height != nil ? .exactly : (maxH != nil ? .atMost : .undefined)

                let measured = computeNodeLayout(
                    node: child,
                    availableWidth: measureW,
                    availableHeight: measureH,
                    widthMode: measureWMode,
                    heightMode: measureHMode,
                    ownerWidth: cbWidth,
                    ownerHeight: cbHeight,
                    ownerDirection: resolvedDirection,
                    performLayout: false,
                    context: &context
                )
                if width == nil {
                    width = clampSize(measured.width, min: minW, max: maxW, floor: childPBH)
                }
                if height == nil {
                    height = clampSize(measured.height, min: minH, max: maxH, floor: childPBV)
                }
            }

            let finalChildW = width!
            let finalChildH = height!

            // Horizontal position
            let childX: Float
            if let posLeft, let posRight {
                let freeH = cbWidth - posLeft - posRight - finalChildW - mLeft - mRight
                if mLeftAuto && mRightAuto && freeH > 0 {
                    mLeft += freeH / 2
                    mRight += freeH / 2
                } else if mLeftAuto && freeH > 0 {
                    mLeft += freeH
                } else if mRightAuto && freeH > 0 {
                    mRight += freeH
                }
                childX = cbX + posLeft + mLeft
            } else if let posLeft {
                childX = cbX + posLeft + mLeft
            } else if let posRight {
                childX = cbX + cbWidth - posRight - finalChildW - mRight
            } else {
                childX = staticAbsolutePosition(
                    isMainAxis: isRow,
                    isAxisReversed: isRow ? isMainAxisReversed : isCrossAxisReversed,
                    innerStart: innerX,
                    innerSize: innerW,
                    childSize: finalChildW,
                    marginStart: mLeft,
                    marginEnd: mRight,
                    justifyContent: containerStyle.justifyContent,
                    alignSelf: childStyle.alignSelf == .auto ? containerStyle.alignItems : childStyle.alignSelf
                )
            }

            // Vertical position
            let childY: Float
            if let posTop, let posBottom {
                let freeV = cbHeight - posTop - posBottom - finalChildH - mTop - mBottom
                if mTopAuto && mBottomAuto && freeV > 0 {
                    mTop += freeV / 2
                    mBottom += freeV / 2
                } else if mTopAuto && freeV > 0 {
                    mTop += freeV
                } else if mBottomAuto && freeV > 0 {
                    mBottom += freeV
                }
                childY = cbY + posTop + mTop
            } else if let posTop {
                childY = cbY + posTop + mTop
            } else if let posBottom {
                childY = cbY + cbHeight - posBottom - finalChildH - mBottom
            } else {
                childY = staticAbsolutePosition(
                    isMainAxis: !isRow,
                    isAxisReversed: !isRow ? isMainAxisReversed : isCrossAxisReversed,
                    innerStart: innerY,
                    innerSize: innerH,
                    childSize: finalChildH,
                    marginStart: mTop,
                    marginEnd: mBottom,
                    justifyContent: containerStyle.justifyContent,
                    alignSelf: childStyle.alignSelf == .auto ? containerStyle.alignItems : childStyle.alignSelf
                )
            }

            _ = computeNodeLayout(
                node: child,
                availableWidth: finalChildW,
                availableHeight: finalChildH,
                widthMode: .exactly,
                heightMode: .exactly,
                ownerWidth: cbWidth,
                ownerHeight: cbHeight,
                ownerDirection: resolvedDirection,
                performLayout: true,
                context: &context
            )

            child.computedLayout.x = childX
            child.computedLayout.y = childY
            child.computedLayout.margin = FlexInsets(top: mTop, right: mRight, bottom: mBottom, left: mLeft)
        }
    }

    private static func staticAbsolutePosition(
        isMainAxis: Bool,
        isAxisReversed: Bool,
        innerStart: Float,
        innerSize: Float,
        childSize: Float,
        marginStart: Float,
        marginEnd: Float,
        justifyContent: Justify,
        alignSelf: Align
    ) -> Float {
        let free = innerSize - childSize - marginStart - marginEnd
        if isMainAxis {
            switch justifyContent {
            case .center, .spaceAround, .spaceEvenly:
                return innerStart + marginStart + free / 2
            case .flexEnd:
                return isAxisReversed
                    ? (innerStart + marginStart)
                    : (innerStart + innerSize - childSize - marginEnd)
            case .flexStart, .spaceBetween:
                return isAxisReversed
                    ? (innerStart + innerSize - childSize - marginEnd)
                    : (innerStart + marginStart)
            }
        } else {
            switch alignSelf {
            case .center:
                return innerStart + marginStart + free / 2
            case .flexEnd:
                return isAxisReversed
                    ? (innerStart + marginStart)
                    : (innerStart + innerSize - childSize - marginEnd)
            default:
                return isAxisReversed
                    ? (innerStart + innerSize - childSize - marginEnd)
                    : (innerStart + marginStart)
            }
        }
    }

    // MARK: - Leaf MeasureFunc Evaluation

    private static func measureLeafNode(
        style: FlexStyle,
        measureFunc: FlexMeasureFunc,
        availableWidth: Float?,
        availableHeight: Float?,
        widthMode: MeasureMode,
        heightMode: MeasureMode,
        pbH: Float,
        pbV: Float,
        minW: Float?,
        maxW: Float?,
        minH: Float?,
        maxH: Float?
    ) -> FlexSize {
        if widthMode == .exactly, heightMode == .exactly,
           let availableWidth, let availableHeight
        {
            return FlexSize(
                width: max(pbH, availableWidth),
                height: max(pbV, availableHeight)
            )
        }

        let effectiveWidthMode: MeasureMode
        let innerWidthInput: Float
        if widthMode == .exactly, let availableWidth {
            effectiveWidthMode = .exactly
            innerWidthInput = max(0, availableWidth - pbH)
        } else if widthMode == .atMost, let availableWidth {
            let capped = maxW.map { min(availableWidth, $0) } ?? availableWidth
            effectiveWidthMode = .atMost
            innerWidthInput = max(0, capped - pbH)
        } else if let maxW {
            effectiveWidthMode = .atMost
            innerWidthInput = max(0, maxW - pbH)
        } else {
            effectiveWidthMode = .undefined
            innerWidthInput = .nan
        }

        let effectiveHeightMode: MeasureMode
        let innerHeightInput: Float
        if heightMode == .exactly, let availableHeight {
            effectiveHeightMode = .exactly
            innerHeightInput = max(0, availableHeight - pbV)
        } else if heightMode == .atMost, let availableHeight {
            let capped = maxH.map { min(availableHeight, $0) } ?? availableHeight
            effectiveHeightMode = .atMost
            innerHeightInput = max(0, capped - pbV)
        } else if let maxH {
            effectiveHeightMode = .atMost
            innerHeightInput = max(0, maxH - pbV)
        } else {
            effectiveHeightMode = .undefined
            innerHeightInput = .nan
        }

        let measured = measureFunc(innerWidthInput, effectiveWidthMode, innerHeightInput, effectiveHeightMode)
        let rawMeasuredW = measured.width.isFinite && measured.width > 0 ? measured.width : 0
        let rawMeasuredH = measured.height.isFinite && measured.height > 0 ? measured.height : 0

        let finalW: Float
        if widthMode == .exactly, let availableWidth {
            finalW = max(pbH, availableWidth)
        } else {
            finalW = clampSize(rawMeasuredW + pbH, min: minW, max: maxW, floor: pbH)
        }

        let finalH: Float
        if heightMode == .exactly, let availableHeight {
            finalH = max(pbV, availableHeight)
        } else {
            finalH = clampSize(rawMeasuredH + pbV, min: minH, max: maxH, floor: pbV)
        }

        return FlexSize(width: finalW, height: finalH)
    }

    // MARK: - Child Collection & Subtree Zeroing

    private static func collectEffectiveChildren(
        from parent: FlexNode,
        resolvedDirection: Direction,
        performLayout: Bool,
        flow: inout [FlexNode],
        absolute: inout [FlexNode]
    ) {
        for child in parent.children {
            let childDir: Direction = child.style.direction == .inherit ? resolvedDirection : child.style.direction
            switch child.style.display {
            case .none:
                if performLayout {
                    zeroSubtree(child, direction: childDir)
                }
            case .contents:
                if performLayout {
                    child.computedLayout = FlexComputedLayout(direction: childDir)
                    child.isDirty = false
                    child.hasNewLayout = true
                }
                collectEffectiveChildren(
                    from: child,
                    resolvedDirection: childDir,
                    performLayout: performLayout,
                    flow: &flow,
                    absolute: &absolute
                )
            case .flex:
                if child.style.positionType == .absolute {
                    absolute.append(child)
                } else {
                    flow.append(child)
                }
            }
        }
    }

    private static func zeroSubtree(_ node: FlexNode, direction: Direction) {
        node.computedLayout = FlexComputedLayout(direction: direction)
        node.isDirty = false
        node.hasNewLayout = true
        for child in node.children {
            zeroSubtree(child, direction: direction)
        }
    }

    // MARK: - Terminal Cell Grid Rounding (Absolute-Edge Rounding)

    // parity: native/src/yoga.zig#configSetRoundsPositionsFromAbsoluteEdges [status=adapted hash=a12098a32132]
    private static func roundLayoutTree(
        node: FlexNode,
        parentAbsLeft: Float,
        parentAbsTop: Float,
        parentRoundedLeft: Float,
        parentRoundedTop: Float,
        scale: Float
    ) {
        if node.style.display == .none {
            return
        }

        if node.style.display == .contents {
            for child in node.children {
                roundLayoutTree(
                    node: child,
                    parentAbsLeft: parentAbsLeft,
                    parentAbsTop: parentAbsTop,
                    parentRoundedLeft: parentRoundedLeft,
                    parentRoundedTop: parentRoundedTop,
                    scale: scale
                )
            }
            return
        }

        let absLeft = parentAbsLeft + node.computedLayout.x
        let absTop = parentAbsTop + node.computedLayout.y
        let absRight = absLeft + node.computedLayout.width
        let absBottom = absTop + node.computedLayout.height

        let roundedAbsLeft = roundToGrid(absLeft, scale: scale)
        let roundedAbsTop = roundToGrid(absTop, scale: scale)
        let roundedAbsRight = roundToGrid(absRight, scale: scale)
        let roundedAbsBottom = roundToGrid(absBottom, scale: scale)

        node.computedLayout.x = roundedAbsLeft - parentRoundedLeft
        node.computedLayout.y = roundedAbsTop - parentRoundedTop
        node.computedLayout.width = max(0, roundedAbsRight - roundedAbsLeft)
        node.computedLayout.height = max(0, roundedAbsBottom - roundedAbsTop)

        for child in node.children {
            roundLayoutTree(
                node: child,
                parentAbsLeft: absLeft,
                parentAbsTop: absTop,
                parentRoundedLeft: roundedAbsLeft,
                parentRoundedTop: roundedAbsTop,
                scale: scale
            )
        }
    }

    /// Rounds `value` to the cell grid (`scale = 1.0` for terminal cells) with Yoga-style
    /// floating-point epsilon tolerance so adjacent edges round identically.
    internal static func roundToGrid(_ value: Float, scale: Float) -> Float {
        guard scale > 0, value.isFinite else { return value }
        var scaled = Double(value) * Double(scale)
        var fractional = scaled.truncatingRemainder(dividingBy: 1.0)
        if fractional < 0 {
            fractional += 1.0
        }
        let eps = 1e-4
        if fractional < eps {
            scaled -= fractional
        } else if fractional > 1.0 - eps {
            scaled += (1.0 - fractional)
        } else if fractional >= 0.5 - eps {
            scaled = scaled.rounded(.down) + 1.0
        } else {
            scaled = scaled.rounded(.down)
        }
        return Float(scaled / Double(scale))
    }

    // MARK: - Box Model & Geometry Helpers

    private static func resolvePadding(style: FlexStyle, ownerWidth: Float?, direction: Direction) -> FlexInsets {
        let top = max(0, style.padding.resolvePoints(.top, ownerSize: ownerWidth, direction: direction))
        let right = max(0, style.padding.resolvePoints(.right, ownerSize: ownerWidth, direction: direction))
        let bottom = max(0, style.padding.resolvePoints(.bottom, ownerSize: ownerWidth, direction: direction))
        let left = max(0, style.padding.resolvePoints(.left, ownerSize: ownerWidth, direction: direction))
        return FlexInsets(top: top, right: right, bottom: bottom, left: left)
    }

    private static func resolveBorder(style: FlexStyle, direction: Direction) -> FlexInsets {
        let top = max(0, style.border.resolvePoints(.top, ownerSize: nil, direction: direction))
        let right = max(0, style.border.resolvePoints(.right, ownerSize: nil, direction: direction))
        let bottom = max(0, style.border.resolvePoints(.bottom, ownerSize: nil, direction: direction))
        let left = max(0, style.border.resolvePoints(.left, ownerSize: nil, direction: direction))
        return FlexInsets(top: top, right: right, bottom: bottom, left: left)
    }

    private static func resolveBorderBoxBound(
        _ value: FlexValue,
        ownerInnerSize: Float?,
        pb: Float,
        boxSizing: BoxSizing
    ) -> Float? {
        guard let resolved = value.resolve(against: ownerInnerSize) else { return nil }
        switch boxSizing {
        case .borderBox:
            return resolved
        case .contentBox:
            return max(0, resolved) + pb
        }
    }

    private static func clampSize(
        _ value: Float,
        min minBound: Float?,
        max maxBound: Float?,
        floor: Float
    ) -> Float {
        var result = value
        if let maxBound, result > maxBound {
            result = maxBound
        }
        if let minBound, result < minBound {
            result = minBound
        }
        return max(floor, result)
    }

    private static func validAspectRatio(_ ratio: Float?) -> Float? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }

    private static func aspectHeight(
        fromWidth width: Float,
        ratio: Float,
        pbH: Float,
        pbV: Float,
        boxSizing: BoxSizing
    ) -> Float {
        switch boxSizing {
        case .borderBox:
            return width / ratio
        case .contentBox:
            let contentW = max(0, width - pbH)
            return (contentW / ratio) + pbV
        }
    }

    private static func aspectWidth(
        fromHeight height: Float,
        ratio: Float,
        pbH: Float,
        pbV: Float,
        boxSizing: BoxSizing
    ) -> Float {
        switch boxSizing {
        case .borderBox:
            return height * ratio
        case .contentBox:
            let contentH = max(0, height - pbV)
            return (contentH * ratio) + pbH
        }
    }

    private static func resolveRelativeOffset(
        style: FlexStyle,
        ownerWidth: Float?,
        ownerHeight: Float?,
        direction: Direction
    ) -> (x: Float, y: Float) {
        let left = style.position.resolve(.left, direction: direction).resolve(against: ownerWidth)
        let right = style.position.resolve(.right, direction: direction).resolve(against: ownerWidth)
        let top = style.position.resolve(.top, direction: direction).resolve(against: ownerHeight)
        let bottom = style.position.resolve(.bottom, direction: direction).resolve(against: ownerHeight)

        let dx: Float
        if direction == .rtl {
            if let right {
                dx = -right
            } else if let left {
                dx = left
            } else {
                dx = 0
            }
        } else {
            if let left {
                dx = left
            } else if let right {
                dx = -right
            } else {
                dx = 0
            }
        }

        let dy: Float
        if let top {
            dy = top
        } else if let bottom {
            dy = -bottom
        } else {
            dy = 0
        }

        return (dx, dy)
    }
}
