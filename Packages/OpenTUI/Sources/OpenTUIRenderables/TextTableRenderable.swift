import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - TextTable Types

private let textTableMeasureHeight = 10_000

/// Content of a single table cell: plain text, `StyledText`, `[TextChunk]`, or empty.
// parity: core/src/renderables/TextTable.ts#TextTableCellContent [status=implemented hash=467e427cd44d]
public enum TextTableCellContent: Equatable, Hashable, Sendable,
    ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral
{
    case empty
    case text(String)
    case styled(StyledText)
    case chunks([TextChunk])

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public init(arrayLiteral elements: TextChunk...) {
        self = .chunks(elements)
    }

    public func toStyledText() -> StyledText {
        switch self {
        case .empty:
            return stringToStyledText("")
        case .text(let s):
            return stringToStyledText(s)
        case .styled(let st):
            return st
        case .chunks(let chunks):
            return StyledText(chunks: chunks)
        }
    }
}

/// 2D row-major matrix of table cell contents.
// parity: core/src/renderables/TextTable.ts#TextTableContent [status=implemented hash=428286caa824]
public typealias TextTableContent = [[TextTableCellContent]]

/// How columns expand into available container width.
// parity: core/src/renderables/TextTable.ts#TextTableColumnWidthMode [status=implemented hash=216142a6e5b7]
public enum TextTableColumnWidthMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case content
    case full
}

// parity: core/src/renderables/TextTable.ts#TextTableColumnFitter [status=implemented hash=6d42e9400e96]
public extension TextTableColumnFitter {}

/// Per-column horizontal text alignment.
// parity: core/src/renderables/TextTable.ts#TextTableColumnAlignment [status=implemented hash=10d7d87fc309]
public typealias TextTableColumnAlignment = TextAlign

/// Configuration options for `TextTableRenderable`.
// parity: core/src/renderables/TextTable.ts#TextTableOptions [status=implemented hash=100c17efdbe9]
public struct TextTableOptions {
    public var base: RenderableOptions
    public var content: TextTableContent?
    public var wrapMode: TextWrapMode?
    public var columnWidthMode: TextTableColumnWidthMode?
    public var columnFitter: TextTableColumnFitter?
    public var columnAlignments: [TextTableColumnAlignment]?
    public var cellPadding: Int?
    public var cellPaddingX: Int?
    public var cellPaddingY: Int?
    public var columnGap: Int?
    public var showBorders: Bool?
    public var border: Bool?
    public var outerBorder: Bool?
    public var selectable: Bool?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var borderStyle: BorderStyle?
    public var borderColor: Color?
    public var borderBackgroundColor: Color?
    public var backgroundColor: Color?
    public var fg: Color?
    public var bg: Color?
    public var attributes: UInt32?

    public init(
        id: String? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: FlexValue? = nil,
        maxWidth: FlexValue? = nil,
        minHeight: FlexValue? = nil,
        maxHeight: FlexValue? = nil,
        flexGrow: Float? = nil,
        flexShrink: Float? = nil,
        position: PositionType? = nil,
        top: FlexValue? = nil,
        right: FlexValue? = nil,
        bottom: FlexValue? = nil,
        left: FlexValue? = nil,
        margin: FlexValue? = nil,
        padding: FlexValue? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        buffered: Bool? = nil,
        content: TextTableContent? = nil,
        wrapMode: TextWrapMode? = nil,
        columnWidthMode: TextTableColumnWidthMode? = nil,
        columnFitter: TextTableColumnFitter? = nil,
        columnAlignments: [TextTableColumnAlignment]? = nil,
        cellPadding: Int? = nil,
        cellPaddingX: Int? = nil,
        cellPaddingY: Int? = nil,
        columnGap: Int? = nil,
        showBorders: Bool? = nil,
        border: Bool? = nil,
        outerBorder: Bool? = nil,
        selectable: Bool? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        borderStyle: BorderStyle? = nil,
        borderColor: Color? = nil,
        borderBackgroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        attributes: UInt32? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            flexGrow: flexGrow,
            flexShrink: flexShrink,
            position: position,
            top: top,
            right: right,
            bottom: bottom,
            left: left,
            margin: margin,
            padding: padding,
            zIndex: zIndex,
            visible: visible,
            selectable: selectable,
            buffered: buffered
        )
        self.content = content
        self.wrapMode = wrapMode
        self.columnWidthMode = columnWidthMode
        self.columnFitter = columnFitter
        self.columnAlignments = columnAlignments
        self.cellPadding = cellPadding
        self.cellPaddingX = cellPaddingX
        self.cellPaddingY = cellPaddingY
        self.columnGap = columnGap
        self.showBorders = showBorders
        self.border = border
        self.outerBorder = outerBorder
        self.selectable = selectable
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.borderStyle = borderStyle
        self.borderColor = borderColor
        self.borderBackgroundColor = borderBackgroundColor
        self.backgroundColor = backgroundColor
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

// MARK: - Internal Layout & Selection Structures

private struct ResolvedTableBorderLayout {
    let left: Bool
    let right: Bool
    let top: Bool
    let bottom: Bool
    let innerVertical: Bool
    let innerHorizontal: Bool
}

private struct TextTableCellState {
    let textBuffer: TextBuffer
    let textBufferView: TextBufferView
}

private struct TextTableLayout {
    var columnWidths: [Int]
    var rowHeights: [Int]
    var columnOffsets: [Int]
    var rowOffsets: [Int]
    var tableWidth: Int
    var tableHeight: Int

    static let empty = TextTableLayout(
        columnWidths: [],
        rowHeights: [],
        columnOffsets: [0],
        rowOffsets: [0],
        tableWidth: 0,
        tableHeight: 0
    )
}

private struct CellPosition: Equatable {
    let rowIdx: Int
    let colIdx: Int
}

private enum TableSelectionMode: Equatable {
    case singleCell
    case columnLocked
    case grid
}

private struct SelectionResolution {
    let mode: TableSelectionMode
    let anchorCell: CellPosition?
    let anchorColumn: Int?
}

private struct CellSelectionCoords {
    let anchorX: Int
    let anchorY: Int
    let focusX: Int
    let focusY: Int
}

// MARK: - Box-Drawing Grid Renderer

private func drawTableGrid(
    into buffer: OptimizedBuffer,
    borderChars: [UInt32],
    borderFg: RGBA,
    borderBg: RGBA,
    columnOffsets: [Int],
    rowOffsets: [Int],
    originX: Int,
    originY: Int,
    drawInner: Bool,
    drawOuter: Bool
) {
    guard columnOffsets.count >= 2 && rowOffsets.count >= 2 && borderChars.count >= 11 else { return }

    let lastCol = columnOffsets.count - 1
    let lastRow = rowOffsets.count - 1

    let spanStartX = drawOuter ? (originX + columnOffsets[0]) : (originX + columnOffsets[0] + 1)
    let spanEndX = drawOuter ? (originX + columnOffsets[lastCol]) : (originX + columnOffsets[lastCol])
    let spanStartY = drawOuter ? (originY + rowOffsets[0]) : (originY + rowOffsets[0] + 1)
    let spanEndY = drawOuter ? (originY + rowOffsets[lastRow]) : (originY + rowOffsets[lastRow])

    func isRowLineDrawn(_ rowIdx: Int) -> Bool {
        if rowIdx == 0 || rowIdx == lastRow { return drawOuter }
        return drawInner
    }

    func isColLineDrawn(_ colIdx: Int) -> Bool {
        if colIdx == 0 || colIdx == lastCol { return drawOuter }
        return drawInner
    }

    // Horizontal rules
    let hScalar = borderChars[BorderCharIndex.horizontal.rawValue]
    if spanStartX <= spanEndX {
        for rowIdx in 0...lastRow where isRowLineDrawn(rowIdx) {
            let gy = originY + rowOffsets[rowIdx]
            for gx in spanStartX...spanEndX {
                buffer.drawChar(hScalar, x: gx, y: gy, fg: borderFg, bg: borderBg)
            }
        }
    }

    // Vertical rules
    let vScalar = borderChars[BorderCharIndex.vertical.rawValue]
    if spanStartY <= spanEndY {
        for colIdx in 0...lastCol where isColLineDrawn(colIdx) {
            let gx = originX + columnOffsets[colIdx]
            for gy in spanStartY...spanEndY {
                buffer.drawChar(vScalar, x: gx, y: gy, fg: borderFg, bg: borderBg)
            }
        }
    }

    // Intersections / Corners / T-Junctions
    for rowIdx in 0...lastRow where isRowLineDrawn(rowIdx) {
        let gy = originY + rowOffsets[rowIdx]
        let isTop = rowIdx == 0
        let isBottom = rowIdx == lastRow
        for colIdx in 0...lastCol where isColLineDrawn(colIdx) {
            let gx = originX + columnOffsets[colIdx]
            let isLeft = colIdx == 0
            let isRight = colIdx == lastCol

            let charIndex: BorderCharIndex
            if isTop && isLeft {
                charIndex = .topLeft
            } else if isTop && isRight {
                charIndex = .topRight
            } else if isBottom && isLeft {
                charIndex = .bottomLeft
            } else if isBottom && isRight {
                charIndex = .bottomRight
            } else if isTop {
                charIndex = .topT
            } else if isBottom {
                charIndex = .bottomT
            } else if isLeft {
                charIndex = .leftT
            } else if isRight {
                charIndex = .rightT
            } else {
                charIndex = .cross
            }
            buffer.drawChar(borderChars[charIndex.rawValue], x: gx, y: gy, fg: borderFg, bg: borderBg)
        }
    }
}

// MARK: - TextTableRenderable

/// Full-featured terminal table renderable with proportional/balanced column width fitting,
/// wrapped multi-line styled cells, box-drawing grid borders & junctions, and cross-cell selection.
// parity: core/src/renderables/TextTable.ts#TextTableRenderable [status=implemented hash=426e7ae9321a]
open class TextTableRenderable: Renderable, @unchecked Sendable {
    private static let defaultBorderColor = parseColor("#FFFFFF")
    private static let defaultFgColor = parseColor("#FFFFFF")
    private static let defaultTransparent = RGBA.fromValues(0, 0, 0, 0)

    private var _content: TextTableContent = []
    private var _cellWidthMethod: WidthMethod? = nil
    private var _selectionInCells: Bool = false
    private var _pressedCell: CellPosition? = nil
    private var _wrapMode: TextWrapMode
    private var _columnWidthMode: TextTableColumnWidthMode
    private var _columnFitter: TextTableColumnFitter
    private var _columnAlignments: [TextTableColumnAlignment]
    private var _cellPaddingX: Int
    private var _cellPaddingY: Int
    private var _columnGap: Int
    private var _showBorders: Bool
    private var _border: Bool
    private var _outerBorder: Bool
    private var _hasExplicitOuterBorder: Bool
    private var _borderStyle: BorderStyle
    private var _borderColor: RGBA
    private var _borderBackgroundColor: RGBA
    private var _backgroundColor: RGBA
    private var _defaultFg: RGBA
    private var _defaultBg: RGBA
    private var _defaultAttributes: UInt32
    private var _selectionBg: RGBA?
    private var _selectionFg: RGBA?
    private var _lastLocalSelection: LocalSelectionBounds? = nil
    private var _lastSelectionMode: TableSelectionMode? = nil

    private var _cells: [[TextTableCellState]] = []
    private var _prevCellContent: [[TextTableCellContent]] = []
    private var _rowCount: Int = 0
    private var _columnCount: Int = 0

    private var _layout: TextTableLayout = .empty
    private var _layoutDirty: Bool = true
    private var _cachedMeasureLayout: TextTableLayout? = nil
    private var _cachedMeasureWidth: Int? = nil

    public init(ctx: any RenderContext, options: TextTableOptions = TextTableOptions()) {
        self._wrapMode = options.wrapMode ?? .word
        self._columnWidthMode = options.columnWidthMode ?? .full
        self._columnFitter = options.columnFitter ?? .proportional
        self._columnAlignments = options.columnAlignments ?? []
        self._cellPaddingX = max(0, options.cellPaddingX ?? options.cellPadding ?? 0)
        self._cellPaddingY = max(0, options.cellPaddingY ?? options.cellPadding ?? 0)
        self._columnGap = max(0, options.columnGap ?? 0)
        self._showBorders = options.showBorders ?? true
        self._border = options.border ?? true
        self._hasExplicitOuterBorder = options.outerBorder != nil
        self._outerBorder = options.outerBorder ?? self._border
        self._borderStyle = options.borderStyle ?? .single
        self._borderColor = options.borderColor?.resolved() ?? Self.defaultBorderColor
        self._borderBackgroundColor = options.borderBackgroundColor?.resolved() ?? Self.defaultTransparent
        self._backgroundColor = options.backgroundColor?.resolved() ?? Self.defaultTransparent
        self._defaultFg = options.fg?.resolved() ?? Self.defaultFgColor
        self._defaultBg = options.bg?.resolved() ?? Self.defaultTransparent
        self._defaultAttributes = options.attributes ?? TextAttributes.none
        self._selectionBg = options.selectionBg?.resolved()
        self._selectionFg = options.selectionFg?.resolved()

        var baseOptions = options.base
        if baseOptions.flexShrink == nil {
            baseOptions.flexShrink = 0
        }
        baseOptions.selectable = options.selectable ?? baseOptions.selectable ?? true

        super.init(ctx: ctx, options: baseOptions)
        self.selectable = options.selectable ?? options.base.selectable ?? true

        setupMeasureFunc()
        rebuildCells(options.content ?? [])
        setBuiltinLifecyclePass { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.ctx.widthMethod != self._cellWidthMethod {
                self.followWidthMethod()
            }
        }
    }

    private func followWidthMethod() {
        let method = ctx.widthMethod
        let textMethod = textBufferWidthMethod(method)
        for row in _cells {
            for cell in row {
                cell.textBuffer.setWidthMethod(textMethod)
            }
        }
        _cellWidthMethod = method
        if _lastLocalSelection?.isActive == true {
            _selectionInCells = true
        }
        invalidateLayout()
    }

    // MARK: - Public Properties

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.content [status=implemented hash=408050ecf9bb]
    public var content: TextTableContent {
        get { _content }
        set { rebuildCells(newValue) }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.wrapMode [status=implemented hash=2c0f1bdddb66]
    public var wrapMode: TextWrapMode {
        get { _wrapMode }
        set {
            guard _wrapMode != newValue else { return }
            _wrapMode = newValue
            for row in _cells {
                for cell in row {
                    cell.textBufferView.setWrapMode(newValue)
                }
            }
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.columnWidthMode [status=implemented hash=0dad2c962aa1]
    public var columnWidthMode: TextTableColumnWidthMode {
        get { _columnWidthMode }
        set {
            guard _columnWidthMode != newValue else { return }
            _columnWidthMode = newValue
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.columnFitter [status=implemented hash=4dfe50f0556d]
    public var columnFitter: TextTableColumnFitter {
        get { _columnFitter }
        set {
            guard _columnFitter != newValue else { return }
            _columnFitter = newValue
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.columnAlignments [status=implemented hash=9a65b9deb652]
    public var columnAlignments: [TextTableColumnAlignment] {
        get { _columnAlignments }
        set {
            _columnAlignments = newValue
            invalidateLayout(markFlexDirty: false)
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.cellPadding [status=implemented hash=31484eec6f31]
    public var cellPadding: Int {
        get { _cellPaddingX == _cellPaddingY ? _cellPaddingX : 0 }
        set {
            let next = max(0, newValue)
            guard _cellPaddingX != next || _cellPaddingY != next else { return }
            _cellPaddingX = next
            _cellPaddingY = next
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.cellPaddingX [status=implemented hash=82d782eeda8a]
    public var cellPaddingX: Int {
        get { _cellPaddingX }
        set {
            let next = max(0, newValue)
            guard _cellPaddingX != next else { return }
            _cellPaddingX = next
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.cellPaddingY [status=implemented hash=621fa3cb18ed]
    public var cellPaddingY: Int {
        get { _cellPaddingY }
        set {
            let next = max(0, newValue)
            guard _cellPaddingY != next else { return }
            _cellPaddingY = next
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.columnGap [status=implemented hash=c10b7bf8e0c3]
    public var tableColumnGap: Int {
        get { _columnGap }
        set {
            let next = max(0, newValue)
            guard _columnGap != next else { return }
            _columnGap = next
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.showBorders [status=implemented hash=38d7c7965cb0]
    public var showBorders: Bool {
        get { _showBorders }
        set {
            guard _showBorders != newValue else { return }
            _showBorders = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.outerBorder [status=implemented hash=021eaab0aa11]
    public var outerBorder: Bool {
        get { _outerBorder }
        set {
            guard _outerBorder != newValue else { return }
            _hasExplicitOuterBorder = true
            _outerBorder = newValue
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.border [status=implemented hash=930506fbbaa4]
    public var border: Bool {
        get { _border }
        set {
            guard _border != newValue else { return }
            _border = newValue
            if !_hasExplicitOuterBorder {
                _outerBorder = newValue
            }
            invalidateLayout()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.borderStyle [status=implemented hash=89da544e8fa5]
    public var borderStyle: BorderStyle {
        get { _borderStyle }
        set {
            guard _borderStyle != newValue else { return }
            _borderStyle = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.borderColor [status=implemented hash=c0d1cecb90f6]
    public var borderColor: RGBA {
        get { _borderColor }
        set {
            _borderColor = newValue
            requestRender()
        }
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.fg [status=implemented hash=aaa4b7c66a42]
    public var fg: RGBA {
        get { _defaultFg }
        set {
            guard _defaultFg != newValue else { return }
            _defaultFg = newValue
            for row in _cells {
                for cell in row {
                    cell.textBuffer.setDefaultFg(newValue)
                }
            }
            requestRender()
        }
    }

    public var columnWidths: [Int] {
        ensureLayoutReady()
        return _layout.columnWidths
    }

    public var rowHeights: [Int] {
        ensureLayoutReady()
        return _layout.rowHeights
    }

    // MARK: - Selection

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.shouldStartSelection [status=implemented hash=feb790b524af]
    open override func shouldStartSelection(x: Int, y: Int) -> Bool {
        guard selectable else { return false }
        ensureLayoutReady()
        let localX = x - self.x
        let localY = y - self.y
        return getCellAtLocalPosition(localX: localX, localY: localY) != nil
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.onSelectionChanged [status=implemented hash=436d110e9e04]
    @discardableResult
    open override func onSelectionChanged(_ selection: Selection?) -> Bool {
        ensureLayoutReady()
        let localSelection = convertGlobalToLocalSelection(selection, localX: self.x, localY: self.y)
        _lastLocalSelection = localSelection
        _selectionInCells = false

        if let localSelection, localSelection.isActive {
            applySelectionToCells(localSelection, isStart: selection?.isStart ?? false)
        } else {
            resetCellSelections()
            _lastSelectionMode = nil
            _pressedCell = nil
        }

        requestRender()
        return hasSelection()
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.hasSelection [status=implemented hash=54066dca1e0f]
    open override func hasSelection() -> Bool {
        for row in _cells {
            for cell in row {
                if cell.textBufferView.hasSelection() {
                    return true
                }
            }
        }
        return false
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.getSelection [status=implemented hash=c57818fbdab7]
    public func getSelection() -> TextSelectionRange? {
        for row in _cells {
            for cell in row {
                if let sel = cell.textBufferView.getSelection() {
                    return sel
                }
            }
        }
        return nil
    }

    // parity: core/src/renderables/TextTable.ts#TextTableRenderable.getSelectedText [status=implemented hash=972d0562bb3e]
    open override func getSelectedText() -> String {
        var selectedRows: [String] = []
        for rowIdx in 0..<_rowCount {
            var rowSelections: [String] = []
            for colIdx in 0..<_columnCount {
                let cell = _cells[rowIdx][colIdx]
                guard cell.textBufferView.hasSelection() else { continue }
                let text = cell.textBufferView.getSelectedText()
                if !text.isEmpty {
                    rowSelections.append(text)
                }
            }
            if !rowSelections.isEmpty {
                selectedRows.append(rowSelections.joined(separator: "\t"))
            }
        }
        return selectedRows.joined(separator: "\n")
    }

    // MARK: - Resize, Render & Lifecycle

    open override func onResize(width: Int, height: Int) {
        invalidateLayout(markFlexDirty: false)
        super.onResize(width: width, height: height)
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard visible && !isDestroyed else { return }
        ensureLayoutReady()

        let origin = paintOrigin(for: buffer)
        let x = origin.x
        let y = origin.y
        let paintW = width > 0 ? width : _layout.tableWidth
        let paintH = height > 0 ? height : _layout.tableHeight
        guard paintW > 0 && paintH > 0 else { return }

        buffer.pushScissorRect(x: x, y: y, width: paintW, height: paintH)
        defer { buffer.popScissorRect() }

        if let fb = frameBuffer, buffer === fb {
            buffer.clear(bg: _backgroundColor, char: defaultSpaceChar)
        } else if _backgroundColor.a > 0 {
            buffer.fillRect(x: x, y: y, width: paintW, height: paintH, bg: _backgroundColor)
        }

        drawBorders(into: buffer, x: x, y: y)
        drawCells(into: buffer, x: x, y: y)
    }

    open override func destroySelf() {
        destroyCells()
        super.destroySelf()
    }

    // MARK: - Measure Provider & Cell Management

    private func setupMeasureFunc() {
        setMeasureProvider { [weak self] width, widthMode, _, _ in
            guard let self, !self.isDestroyed else {
                return FlexSize(width: 1, height: 1)
            }
            let hasWidthConstraint = widthMode != .undefined && width.isFinite
            let rawWidthConstraint: Int? = hasWidthConstraint ? max(1, Int(width.rounded(.down))) : nil
            let widthConstraint = self.resolveLayoutWidthConstraint(rawWidthConstraint)
            let measuredLayout = self.computeLayout(maxTableWidth: widthConstraint)
            self._cachedMeasureLayout = measuredLayout
            self._cachedMeasureWidth = widthConstraint

            var measuredWidth = measuredLayout.tableWidth > 0 ? measuredLayout.tableWidth : 1
            let measuredHeight = measuredLayout.tableHeight > 0 ? measuredLayout.tableHeight : 1

            if widthMode == .atMost, let raw = rawWidthConstraint, self.position != .absolute {
                measuredWidth = min(raw, measuredWidth)
            }

            return FlexSize(width: Float(measuredWidth), height: Float(measuredHeight))
        }
    }

    private func rebuildCells(_ content: TextTableContent) {
        let previous = _cells
        let previousContent = _prevCellContent
        let newRowCount = content.count
        let newColumnCount = content.reduce(0) { max($0, $1.count) }

        var newCells: [[TextTableCellState]] = []
        var newRefs: [[TextTableCellContent]] = []
        newCells.reserveCapacity(newRowCount)
        newRefs.reserveCapacity(newRowCount)

        let textMethod = textBufferWidthMethod(ctx.widthMethod)

        for rowIdx in 0..<newRowCount {
            let row = content[rowIdx]
            var cellRow: [TextTableCellState] = []
            var refRow: [TextTableCellContent] = []
            cellRow.reserveCapacity(newColumnCount)
            refRow.reserveCapacity(newColumnCount)

            for colIdx in 0..<newColumnCount {
                let cellContent: TextTableCellContent = colIdx < row.count ? row[colIdx] : .empty
                refRow.append(cellContent)

                if rowIdx < previous.count && colIdx < previous[rowIdx].count {
                    let existing = previous[rowIdx][colIdx]
                    let prevContent = previousContent[rowIdx][colIdx]
                    if prevContent != cellContent {
                        existing.textBuffer.setStyledText(cellContent.toStyledText())
                    }
                    existing.textBuffer.setWidthMethod(textMethod)
                    existing.textBufferView.setWrapMode(_wrapMode)
                    cellRow.append(existing)
                } else {
                    let created = createCell(content: cellContent, widthMethod: textMethod)
                    cellRow.append(created)
                }
            }
            newCells.append(cellRow)
            newRefs.append(refRow)
        }

        // Destroy any leftover cells from shrunk rows/columns
        for rowIdx in 0..<previous.count {
            for colIdx in 0..<previous[rowIdx].count {
                if rowIdx >= newRowCount || colIdx >= newColumnCount {
                    destroyCell(previous[rowIdx][colIdx])
                }
            }
        }

        _content = content
        _cells = newCells
        _prevCellContent = newRefs
        _rowCount = newRowCount
        _columnCount = newColumnCount
        _cellWidthMethod = ctx.widthMethod
        invalidateLayout()
    }

    private func createCell(content: TextTableCellContent, widthMethod: TextWidthMethod) -> TextTableCellState {
        let tb = TextBuffer.create(widthMethod: widthMethod)
        tb.setDefaultFg(_defaultFg)
        tb.setDefaultBg(_defaultBg)
        tb.setDefaultAttributes(_defaultAttributes)
        tb.setStyledText(content.toStyledText())

        let view = TextBufferView.create(tb)
        view.setWrapMode(_wrapMode)
        view.setSelectionColors(bgColor: _selectionBg, fgColor: _selectionFg)
        return TextTableCellState(textBuffer: tb, textBufferView: view)
    }

    private func destroyCell(_ cell: TextTableCellState) {
        cell.textBufferView.destroy()
        cell.textBuffer.destroy()
    }

    private func destroyCells() {
        let snapshot = _cells
        _cells.removeAll()
        _prevCellContent.removeAll()
        _rowCount = 0
        _columnCount = 0
        _layout = .empty
        for row in snapshot {
            for cell in row {
                destroyCell(cell)
            }
        }
    }

    // MARK: - Table Layout Computation

    private func ensureLayoutReady() {
        guard _layoutDirty else { return }
        rebuildLayoutForCurrentWidth()
    }

    private func rebuildLayoutForCurrentWidth() {
        let maxTableWidth = resolveLayoutWidthConstraint(width > 0 ? width : nil)
        let layout: TextTableLayout
        if let cached = _cachedMeasureLayout, _cachedMeasureWidth == maxTableWidth {
            layout = cached
        } else {
            layout = computeLayout(maxTableWidth: maxTableWidth)
        }
        _cachedMeasureLayout = nil
        _cachedMeasureWidth = nil

        _layout = layout
        applyLayoutToViews(layout)
        _layoutDirty = false

        if let local = _lastLocalSelection, local.isActive, !_selectionInCells {
            applySelectionToCells(local, isStart: true)
        }
    }

    private func computeLayout(maxTableWidth: Int?) -> TextTableLayout {
        guard _rowCount > 0 && _columnCount > 0 else { return .empty }

        let borderLayout = resolveBorderLayout()
        let intrinsicMeasures: [[MeasureResult?]] = _cells.map { row in
            row.map { cell in
                cell.textBufferView.measureForDimensions(width: 0, height: textTableMeasureHeight)
            }
        }
        let colWidths = computeColumnWidths(
            maxTableWidth: maxTableWidth,
            borderLayout: borderLayout,
            intrinsicMeasures: intrinsicMeasures
        )
        let rHeights = computeRowHeights(columnWidths: colWidths, intrinsicMeasures: intrinsicMeasures)
        let colOffsets = computeOffsets(
            parts: colWidths,
            startBoundary: borderLayout.left,
            endBoundary: borderLayout.right,
            includeInnerBoundaries: borderLayout.innerVertical,
            innerGap: getInterColumnGap(borderLayout)
        )
        let rOffsets = computeOffsets(
            parts: rHeights,
            startBoundary: borderLayout.top,
            endBoundary: borderLayout.bottom,
            includeInnerBoundaries: borderLayout.innerHorizontal,
            innerGap: 0
        )
        return TextTableLayout(
            columnWidths: colWidths,
            rowHeights: rHeights,
            columnOffsets: colOffsets,
            rowOffsets: rOffsets,
            tableWidth: (colOffsets.last ?? 0) + 1,
            tableHeight: (rOffsets.last ?? 0) + 1
        )
    }

    private func isFullWidthMode() -> Bool {
        _columnWidthMode == .full
    }

    private func computeColumnWidths(
        maxTableWidth: Int?,
        borderLayout: ResolvedTableBorderLayout,
        intrinsicMeasures: [[MeasureResult?]]
    ) -> [Int] {
        let horizontalPadding = getHorizontalCellPadding()
        var intrinsicWidths = Array(repeating: 1 + horizontalPadding, count: _columnCount)

        for rowIdx in 0..<_rowCount {
            for colIdx in 0..<_columnCount {
                let measure = intrinsicMeasures[rowIdx][colIdx]
                let measuredWidth = max(1, measure?.widthColsMax ?? 0) + horizontalPadding
                intrinsicWidths[colIdx] = max(intrinsicWidths[colIdx], measuredWidth)
            }
        }

        guard let maxTableWidth, maxTableWidth > 0 else {
            return intrinsicWidths
        }

        let maxContentWidth = max(
            1,
            maxTableWidth - getVerticalBorderCount(borderLayout) - getTotalInterColumnGap(borderLayout)
        )
        let currentWidth = intrinsicWidths.reduce(0, +)

        if currentWidth == maxContentWidth {
            return intrinsicWidths
        }

        if currentWidth < maxContentWidth {
            if isFullWidthMode() {
                return expandColumnWidths(intrinsicWidths, targetContentWidth: maxContentWidth)
            }
            return intrinsicWidths
        }

        if _wrapMode == .none {
            return intrinsicWidths
        }

        let minWidth = 1 + horizontalPadding
        return fitTextTableColumnWidths(
            intrinsicWidths,
            targetWidth: maxContentWidth,
            minWidth: minWidth,
            fitter: _columnFitter
        )
    }

    private func expandColumnWidths(_ widths: [Int], targetContentWidth: Int) -> [Int] {
        var expanded = widths.map { max(1, $0) }
        let totalBase = expanded.reduce(0, +)
        guard totalBase < targetContentWidth, !expanded.isEmpty else {
            return expanded
        }

        let extra = targetContentWidth - totalBase
        let shared = extra / expanded.count
        let remainder = extra % expanded.count
        for idx in 0..<expanded.count {
            expanded[idx] += shared + (idx < remainder ? 1 : 0)
        }
        return expanded
    }

    private func computeRowHeights(
        columnWidths: [Int],
        intrinsicMeasures: [[MeasureResult?]]
    ) -> [Int] {
        let horizontalPadding = getHorizontalCellPadding()
        let verticalPadding = getVerticalCellPadding()
        var rowHeights = Array(repeating: 1 + verticalPadding, count: _rowCount)

        for rowIdx in 0..<_rowCount {
            for colIdx in 0..<_columnCount {
                let cell = _cells[rowIdx][colIdx]
                let colContentWidth = max(1, columnWidths[colIdx] - horizontalPadding)
                let intrinsic = intrinsicMeasures[rowIdx][colIdx]
                let measure: MeasureResult?
                if let intrinsic, _wrapMode == .none || intrinsic.widthColsMax <= colContentWidth {
                    measure = intrinsic
                } else {
                    measure = cell.textBufferView.measureForDimensions(
                        width: colContentWidth,
                        height: textTableMeasureHeight
                    )
                }
                let lines = max(1, measure?.lineCount ?? 1)
                rowHeights[rowIdx] = max(rowHeights[rowIdx], lines + verticalPadding)
            }
        }
        return rowHeights
    }

    private func computeOffsets(
        parts: [Int],
        startBoundary: Bool,
        endBoundary: Bool,
        includeInnerBoundaries: Bool,
        innerGap: Int
    ) -> [Int] {
        var offsets: [Int] = [startBoundary ? 0 : -1]
        var cursor = offsets[0]
        for idx in 0..<parts.count {
            let size = parts[idx]
            let separatorAfter: Int
            if idx < parts.count - 1 {
                separatorAfter = includeInnerBoundaries ? 1 : innerGap
            } else {
                separatorAfter = endBoundary ? 1 : 0
            }
            cursor += size + separatorAfter
            offsets.append(cursor)
        }
        return offsets
    }

    private func getInterColumnGap(_ borderLayout: ResolvedTableBorderLayout) -> Int {
        borderLayout.innerVertical ? 0 : _columnGap
    }

    private func getTotalInterColumnGap(_ borderLayout: ResolvedTableBorderLayout) -> Int {
        max(0, _columnCount - 1) * getInterColumnGap(borderLayout)
    }

    private func applyLayoutToViews(_ layout: TextTableLayout) {
        let horizontalPadding = getHorizontalCellPadding()
        let verticalPadding = getVerticalCellPadding()

        for rowIdx in 0..<_rowCount {
            for colIdx in 0..<_columnCount {
                let cell = _cells[rowIdx][colIdx]
                let colWidth = layout.columnWidths[colIdx]
                let rowHeight = layout.rowHeights[rowIdx]
                let contentWidth = max(1, colWidth - horizontalPadding)
                let contentHeight = max(1, rowHeight - verticalPadding)
                cell.textBufferView.setViewport(x: 0, y: 0, width: contentWidth, height: contentHeight)
                if _wrapMode != .none {
                    cell.textBufferView.setWrapWidth(contentWidth)
                } else {
                    cell.textBufferView.setWrapWidth(nil)
                }
                let alignment: TextAlign = colIdx < _columnAlignments.count ? _columnAlignments[colIdx] : .left
                cell.textBufferView.setTextAlign(alignment)
            }
        }
    }

    private func resolveBorderLayout() -> ResolvedTableBorderLayout {
        ResolvedTableBorderLayout(
            left: _outerBorder,
            right: _outerBorder,
            top: _outerBorder,
            bottom: _outerBorder,
            innerVertical: _border && _columnCount > 1,
            innerHorizontal: _border && _rowCount > 1
        )
    }

    private func getVerticalBorderCount(_ borderLayout: ResolvedTableBorderLayout) -> Int {
        (borderLayout.left ? 1 : 0)
            + (borderLayout.right ? 1 : 0)
            + (borderLayout.innerVertical ? max(0, _columnCount - 1) : 0)
    }

    private func getHorizontalBorderCount(_ borderLayout: ResolvedTableBorderLayout) -> Int {
        (borderLayout.top ? 1 : 0)
            + (borderLayout.bottom ? 1 : 0)
            + (borderLayout.innerHorizontal ? max(0, _rowCount - 1) : 0)
    }

    // MARK: - Drawing

    private func borderCharArray(for style: BorderStyle) -> [UInt32] {
        switch style {
        case .single: return BorderCharArrays.single
        case .double: return BorderCharArrays.double
        case .rounded: return BorderCharArrays.rounded
        case .heavy: return BorderCharArrays.heavy
        }
    }

    private func drawBorders(into buffer: OptimizedBuffer, x: Int, y: Int) {
        guard _showBorders else { return }
        let borderLayout = resolveBorderLayout()
        guard getVerticalBorderCount(borderLayout) > 0 || getHorizontalBorderCount(borderLayout) > 0 else {
            return
        }

        drawTableGrid(
            into: buffer,
            borderChars: borderCharArray(for: _borderStyle),
            borderFg: _borderColor,
            borderBg: _borderBackgroundColor,
            columnOffsets: _layout.columnOffsets,
            rowOffsets: _layout.rowOffsets,
            originX: x,
            originY: y,
            drawInner: _border,
            drawOuter: _outerBorder
        )
    }

    private func drawCells(into buffer: OptimizedBuffer, x: Int, y: Int) {
        let colOffsets = _layout.columnOffsets
        let rowOffsets = _layout.rowOffsets
        let cellBaseX = x + 1 + _cellPaddingX

        for rowIdx in 0..<_rowCount {
            let cellY = y + rowOffsets[rowIdx] + 1 + _cellPaddingY
            for colIdx in 0..<_columnCount {
                let cell = _cells[rowIdx][colIdx]
                let cellX = cellBaseX + colOffsets[colIdx]
                drawTextBufferView(cell.textBufferView, into: buffer, x: cellX, y: cellY)
            }
        }
    }

    // MARK: - Selection Geometry Helpers

    private func getCellAtLocalPosition(localX: Int, localY: Int) -> CellPosition? {
        guard _rowCount > 0 && _columnCount > 0 else { return nil }
        guard localX >= 0 && localY >= 0 && localX < _layout.tableWidth && localY < _layout.tableHeight else {
            return nil
        }

        var rowIdx = -1
        for idx in 0..<_rowCount {
            let top = _layout.rowOffsets[idx] + 1
            let bottom = top + _layout.rowHeights[idx] - 1
            if localY >= top && localY <= bottom {
                rowIdx = idx
                break
            }
        }
        guard rowIdx >= 0 else { return nil }

        var colIdx = -1
        for idx in 0..<_columnCount {
            let left = _layout.columnOffsets[idx] + 1
            let right = left + _layout.columnWidths[idx] - 1
            if localX >= left && localX <= right {
                colIdx = idx
                break
            }
        }
        guard colIdx >= 0 else { return nil }

        return CellPosition(rowIdx: rowIdx, colIdx: colIdx)
    }

    private func applySelectionToCells(_ localSelection: LocalSelectionBounds, isStart: Bool) {
        if localSelection.anchorX == localSelection.focusX && localSelection.anchorY == localSelection.focusY {
            resetCellSelections()
            _lastSelectionMode = nil
            _pressedCell = getCellAtLocalPosition(localX: localSelection.anchorX, localY: localSelection.anchorY)
            if let pressed = _pressedCell {
                let cellX = localSelection.anchorX - (_layout.columnOffsets[pressed.colIdx] + 1 + _cellPaddingX)
                let cellY = localSelection.anchorY - (_layout.rowOffsets[pressed.rowIdx] + 1 + _cellPaddingY)
                _ = _cells[pressed.rowIdx][pressed.colIdx].textBufferView.setLocalSelection(
                    anchorX: cellX,
                    anchorY: cellY,
                    focusX: cellX,
                    focusY: cellY,
                    bgColor: _selectionBg,
                    fgColor: _selectionFg
                )
            }
            return
        }

        let minSelY = min(localSelection.anchorY, localSelection.focusY)
        let maxSelY = max(localSelection.anchorY, localSelection.focusY)
        let firstRow = findRowForLocalY(minSelY)
        let lastRow = findRowForLocalY(maxSelY)
        let resolution = resolveSelectionResolution(localSelection)
        let modeChanged = _lastSelectionMode != resolution.mode
        _lastSelectionMode = resolution.mode
        let lockToAnchorColumn = resolution.mode == .columnLocked && resolution.anchorColumn != nil

        for rowIdx in 0..<_rowCount {
            if rowIdx < firstRow || rowIdx > lastRow {
                resetRowSelection(rowIdx)
                continue
            }

            let cellTop = _layout.rowOffsets[rowIdx] + 1 + _cellPaddingY
            for colIdx in 0..<_columnCount {
                let cell = _cells[rowIdx][colIdx]
                if lockToAnchorColumn && colIdx != resolution.anchorColumn {
                    cell.textBufferView.resetLocalSelection()
                    continue
                }

                let cellLeft = _layout.columnOffsets[colIdx] + 1 + _cellPaddingX
                var coords = CellSelectionCoords(
                    anchorX: localSelection.anchorX - cellLeft,
                    anchorY: localSelection.anchorY - cellTop,
                    focusX: localSelection.focusX - cellLeft,
                    focusY: localSelection.focusY - cellTop
                )

                let isAnchorCell = resolution.anchorCell?.rowIdx == rowIdx
                    && resolution.anchorCell?.colIdx == colIdx

                if resolution.mode == .singleCell && !isAnchorCell {
                    cell.textBufferView.resetLocalSelection()
                    continue
                }

                let forceSet = isAnchorCell && resolution.mode != .singleCell
                if forceSet {
                    coords = getFullCellSelectionCoords(rowIdx: rowIdx, colIdx: colIdx)
                }

                let shouldUseSet = isStart || modeChanged || forceSet
                if shouldUseSet {
                    _ = cell.textBufferView.setLocalSelection(
                        anchorX: coords.anchorX,
                        anchorY: coords.anchorY,
                        focusX: coords.focusX,
                        focusY: coords.focusY,
                        bgColor: _selectionBg,
                        fgColor: _selectionFg
                    )
                } else {
                    _ = cell.textBufferView.updateLocalSelection(
                        anchorX: coords.anchorX,
                        anchorY: coords.anchorY,
                        focusX: coords.focusX,
                        focusY: coords.focusY,
                        bgColor: _selectionBg,
                        fgColor: _selectionFg
                    )
                }
            }
        }
    }

    private func resolveSelectionResolution(_ localSelection: LocalSelectionBounds) -> SelectionResolution {
        let anchorCell = getCellAtLocalPosition(localX: localSelection.anchorX, localY: localSelection.anchorY)
        let focusCell = getCellAtLocalPosition(localX: localSelection.focusX, localY: localSelection.focusY)
        let anchorColumn = anchorCell?.colIdx ?? getColumnAtLocalX(localSelection.anchorX)

        if let anchorCell, let focusCell, anchorCell == focusCell {
            return SelectionResolution(mode: .singleCell, anchorCell: anchorCell, anchorColumn: anchorColumn)
        }

        let focusColumn = getColumnAtLocalX(localSelection.focusX)
        if let anchorColumn, focusColumn == anchorColumn {
            return SelectionResolution(mode: .columnLocked, anchorCell: anchorCell, anchorColumn: anchorColumn)
        }

        return SelectionResolution(mode: .grid, anchorCell: anchorCell, anchorColumn: anchorColumn)
    }

    private func getColumnAtLocalX(_ localX: Int) -> Int? {
        guard _columnCount > 0 && localX >= 0 && localX < _layout.tableWidth else { return nil }
        for colIdx in 0..<_columnCount {
            let colStart = _layout.columnOffsets[colIdx] + 1
            let colEnd = colStart + _layout.columnWidths[colIdx] - 1
            if localX >= colStart && localX <= colEnd {
                return colIdx
            }
        }
        return nil
    }

    private func getFullCellSelectionCoords(rowIdx: Int, colIdx: Int) -> CellSelectionCoords {
        let contentWidth = max(1, _layout.columnWidths[colIdx] - getHorizontalCellPadding())
        let contentHeight = max(1, _layout.rowHeights[rowIdx] - getVerticalCellPadding())
        return CellSelectionCoords(anchorX: -1, anchorY: 0, focusX: contentWidth, focusY: contentHeight)
    }

    private func findRowForLocalY(_ localY: Int) -> Int {
        guard _rowCount > 0 else { return 0 }
        if localY < 0 { return 0 }
        for rowIdx in 0..<_rowCount {
            let rowStart = _layout.rowOffsets[rowIdx] + 1
            let rowEnd = rowStart + _layout.rowHeights[rowIdx] - 1
            if localY <= rowEnd { return rowIdx }
        }
        return _rowCount - 1
    }

    private func resetRowSelection(_ rowIdx: Int) {
        guard rowIdx >= 0 && rowIdx < _cells.count else { return }
        for cell in _cells[rowIdx] {
            cell.textBufferView.resetLocalSelection()
        }
    }

    private func resetCellSelections() {
        for rowIdx in 0..<_rowCount {
            resetRowSelection(rowIdx)
        }
    }

    private func resolveLayoutWidthConstraint(_ width: Int?) -> Int? {
        guard let width, width > 0 else { return nil }
        if _wrapMode != .none || isFullWidthMode() {
            return max(1, width)
        }
        return nil
    }

    private func getHorizontalCellPadding() -> Int {
        _cellPaddingX * 2
    }

    private func getVerticalCellPadding() -> Int {
        _cellPaddingY * 2
    }

    private func invalidateLayout(markFlexDirty: Bool = true) {
        _layoutDirty = true
        _cachedMeasureLayout = nil
        _cachedMeasureWidth = nil
        if markFlexDirty {
            invalidateIntrinsicSize()
        }
        requestRender()
    }
}
