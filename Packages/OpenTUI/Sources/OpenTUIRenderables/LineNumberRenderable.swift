import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - LineNumber Supporting Types

/// Custom before/after gutter markers for an individual logical line.
// parity: core/src/renderables/LineNumberRenderable.ts#LineSign [status=implemented hash=6d4a4c36e9e5]
public struct LineSign: Equatable, Hashable, Sendable {
    public var before: String?
    public var beforeColor: Color?
    public var after: String?
    public var afterColor: Color?

    public init(
        before: String? = nil,
        beforeColor: Color? = nil,
        after: String? = nil,
        afterColor: Color? = nil
    ) {
        self.before = before
        self.beforeColor = beforeColor
        self.after = after
        self.afterColor = afterColor
    }
}

/// Separate gutter and content background colors for a highlighted logical line.
// parity: core/src/renderables/LineNumberRenderable.ts#LineColorConfig [status=implemented hash=387345c6be92]
public struct LineColorConfig: Equatable, Hashable, Sendable {
    public var gutter: Color?
    public var content: Color?

    public init(gutter: Color? = nil, content: Color? = nil) {
        self.gutter = gutter
        self.content = content
    }
}

/// Flexible line-color entry matching upstream `string | RGBA | LineColorConfig`.
public enum LineColorValue: Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    case color(Color)
    case config(LineColorConfig)

    public init(stringLiteral value: String) {
        self = .color(.string(value))
    }

    public static func rgba(_ rgba: RGBA) -> LineColorValue {
        .color(.rgba(rgba))
    }
}

/// Horizontal spacing and minimum-width configuration for `GutterRenderable`.
// parity: core/src/renderables/LineNumberRenderable.ts#GutterLayout [status=implemented hash=6929c3b53fc4]
public struct GutterLayout: Equatable, Hashable, Sendable {
    public var minWidth: Int
    /// Columns before the line numbers, painted in each line's gutter color. Defaults to 1.
    public var paddingLeft: Int
    public var paddingRight: Int
    /// Reserve room for at least this many line-number digits.
    public var minDigits: Int
    /// Reserve at least this many columns for `after` signs, even when no line has one.
    public var minAfterWidth: Int

    public init(
        minWidth: Int = 3,
        paddingLeft: Int = 1,
        paddingRight: Int = 1,
        minDigits: Int = 0,
        minAfterWidth: Int = 0
    ) {
        self.minWidth = minWidth
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.minDigits = minDigits
        self.minAfterWidth = minAfterWidth
    }
}

/// Configuration options for `LineNumberRenderable`.
// parity: core/src/renderables/LineNumberRenderable.ts#LineNumberOptions [status=implemented hash=991d33f7f168]
public struct LineNumberOptions {
    public var base: RenderableOptions
    public var target: (Renderable & LineInfoProvider)?
    public var fg: Color?
    public var bg: Color?
    public var minWidth: Int?
    public var paddingRight: Int?
    public var lineColors: [Int: LineColorValue]?
    public var lineSigns: [Int: LineSign]?
    public var lineNumberOffset: Int?
    public var hideLineNumbers: Set<Int>?
    public var lineNumbers: [Int: Int]?
    public var showLineNumbers: Bool?

    public init(
        id: String? = nil,
        target: (Renderable & LineInfoProvider)? = nil,
        width: FlexValue? = nil,
        height: FlexValue? = nil,
        minWidth: Int? = nil,
        paddingRight: Int? = nil,
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
        fg: Color? = nil,
        bg: Color? = nil,
        lineColors: [Int: LineColorValue]? = nil,
        lineSigns: [Int: LineSign]? = nil,
        lineNumberOffset: Int? = nil,
        hideLineNumbers: Set<Int>? = nil,
        lineNumbers: [Int: Int]? = nil,
        showLineNumbers: Bool? = nil
    ) {
        self.base = RenderableOptions(
            id: id,
            width: width,
            height: height,
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
            visible: visible
        )
        self.target = target
        self.fg = fg
        self.bg = bg
        self.minWidth = minWidth
        self.paddingRight = paddingRight
        self.lineColors = lineColors
        self.lineSigns = lineSigns
        self.lineNumberOffset = lineNumberOffset
        self.hideLineNumbers = hideLineNumbers
        self.lineNumbers = lineNumbers
        self.showLineNumbers = showLineNumbers
    }

    public init(
        base: RenderableOptions,
        target: (Renderable & LineInfoProvider)? = nil,
        fg: Color? = nil,
        bg: Color? = nil,
        minWidth: Int? = nil,
        paddingRight: Int? = nil,
        lineColors: [Int: LineColorValue]? = nil,
        lineSigns: [Int: LineSign]? = nil,
        lineNumberOffset: Int? = nil,
        hideLineNumbers: Set<Int>? = nil,
        lineNumbers: [Int: Int]? = nil,
        showLineNumbers: Bool? = nil
    ) {
        self.base = base
        self.target = target
        self.fg = fg
        self.bg = bg
        self.minWidth = minWidth
        self.paddingRight = paddingRight
        self.lineColors = lineColors
        self.lineSigns = lineSigns
        self.lineNumberOffset = lineNumberOffset
        self.hideLineNumbers = hideLineNumbers
        self.lineNumbers = lineNumbers
        self.showLineNumbers = showLineNumbers
    }
}

// MARK: - Helpers

private let defaultGutterFg = parseColor("#888888")
private let defaultGutterBg = RGBA.fromValues(0, 0, 0, 0)
private let gutterTransparent = RGBA.fromValues(0, 0, 0, 0)

private func darkenColor(_ color: RGBA) -> RGBA {
    RGBA.fromValues(color.r * 0.8, color.g * 0.8, color.b * 0.8, color.a)
}

private func decimalDigitCount(_ value: Int) -> Int {
    if value <= 0 { return 1 }
    var n = value
    var digits = 0
    while n > 0 {
        digits += 1
        n /= 10
    }
    return digits
}

private func targetTextRows(_ target: Renderable) -> (top: Int, height: Int) {
    let padding = target.layoutNode.computedLayout.padding
    let top = Int(padding.top.rounded(.toNearestOrAwayFromZero))
    let bottom = Int(padding.bottom.rounded(.toNearestOrAwayFromZero))
    let contentHeight = max(0, target.height - top - bottom)
    return (top: top, height: contentHeight)
}

// MARK: - GutterRenderable

/// Internal/public gutter sibling renderable drawing line numbers, before/after signs,
/// and per-line gutter backgrounds aligned with a `LineInfoProvider` target.
public final class GutterRenderable: Renderable, @unchecked Sendable {
    private unowned let target: Renderable & LineInfoProvider
    private var _fg: RGBA
    private var _bg: RGBA
    private var _layout: GutterLayout
    private var _lineColorsGutter: [Int: RGBA]
    private var _lineColorsContent: [Int: RGBA]
    private var _lineSigns: [Int: LineSign]
    private var _lineNumberOffset: Int
    private var _hideLineNumbers: Set<Int>
    private var _lineNumbers: [Int: Int]
    private var _maxBeforeWidth: Int = 0
    private var _maxAfterWidth: Int = 0
    private var _lastKnownLineCount: Int = 0
    private var _signWidths: [String: Int] = [:]
    private var _signWidthMethod: WidthMethod? = nil

    public init(
        ctx: any RenderContext,
        target: Renderable & LineInfoProvider,
        id: String? = nil,
        fg: RGBA,
        bg: RGBA,
        layout: GutterLayout,
        lineColorsGutter: [Int: RGBA],
        lineColorsContent: [Int: RGBA],
        lineSigns: [Int: LineSign],
        lineNumberOffset: Int,
        hideLineNumbers: Set<Int>,
        lineNumbers: [Int: Int] = [:]
    ) {
        self.target = target
        self._fg = fg
        self._bg = bg
        self._layout = layout
        self._lineColorsGutter = lineColorsGutter
        self._lineColorsContent = lineColorsContent
        self._lineSigns = lineSigns
        self._lineNumberOffset = lineNumberOffset
        self._hideLineNumbers = hideLineNumbers
        self._lineNumbers = lineNumbers
        self._lastKnownLineCount = target.virtualLineCount

        super.init(
            ctx: ctx,
            options: RenderableOptions(
                id: id,
                width: .auto,
                height: .auto,
                flexGrow: 0,
                flexShrink: 0
            )
        )

        calculateSignWidths()
        setupMeasureFunc()

        setBuiltinLifecyclePass { [weak self] in
            guard let self, !self.isDestroyed else { return }
            let currentLineCount = self.target.virtualLineCount
            let signsStale = self.ctx.widthMethod != self._signWidthMethod
            if signsStale {
                self.calculateSignWidths()
            }
            if currentLineCount != self._lastKnownLineCount || signsStale {
                self._lastKnownLineCount = currentLineCount
                self.invalidateIntrinsicSize()
                self.requestRender()
            }
        }
    }

    private func setupMeasureFunc() {
        setMeasureProvider { [weak self] _, _, _, _ in
            guard let self, !self.isDestroyed else {
                return FlexSize(width: 0, height: 0)
            }
            let gutterWidth = self.calculateWidth()
            let gutterHeight = self.target.virtualLineCount
            return FlexSize(width: Float(gutterWidth), height: Float(gutterHeight))
        }
    }

    public func remeasure() {
        invalidateIntrinsicSize()
        requestRender()
    }

    public func setLineNumberOffset(_ offset: Int) {
        guard _lineNumberOffset != offset else { return }
        _lineNumberOffset = offset
        invalidateIntrinsicSize()
        requestRender()
    }

    public func setHideLineNumbers(_ hideLineNumbers: Set<Int>) {
        _hideLineNumbers = hideLineNumbers
        invalidateIntrinsicSize()
        requestRender()
    }

    public func setLineNumbers(_ lineNumbers: [Int: Int]) {
        _lineNumbers = lineNumbers
        invalidateIntrinsicSize()
        requestRender()
    }

    public func setLayout(_ layout: GutterLayout) {
        _layout = layout
        calculateSignWidths()
        invalidateIntrinsicSize()
        requestRender()
    }

    private func calculateSignWidths() {
        _maxBeforeWidth = 0
        _maxAfterWidth = _layout.minAfterWidth
        _signWidths.removeAll()
        _signWidthMethod = ctx.widthMethod

        for sign in _lineSigns.values {
            if let before = sign.before {
                _maxBeforeWidth = max(_maxBeforeWidth, signWidth(before))
            }
            if let after = sign.after {
                _maxAfterWidth = max(_maxAfterWidth, signWidth(after))
            }
        }
    }

    private func signWidth(_ sign: String) -> Int {
        if sign.isEmpty { return 0 }
        let bytes = Array(sign.utf8)
        if isAsciiOnly(bytes) {
            return bytes.count
        }
        if let cached = _signWidths[sign] {
            return cached
        }
        let w = Int(calculateTextWidth(
            bytes,
            tabWidth: 2,
            controlDisplay: .hidden,
            widthMethod: _signWidthMethod ?? ctx.widthMethod
        ))
        _signWidths[sign] = w
        return w
    }

    public func calculateWidth() -> Int {
        let totalLines = max(target.lineCount, target.virtualLineCount)
        var maxLineNumber = totalLines + _lineNumberOffset
        for customNum in _lineNumbers.values {
            maxLineNumber = max(maxLineNumber, customNum)
        }

        let digits = max(decimalDigitCount(maxLineNumber), _layout.minDigits)
        let baseWidth = max(_layout.minWidth, digits + _layout.paddingLeft + _layout.paddingRight)
        return baseWidth + _maxBeforeWidth + _maxAfterWidth
    }

    public func setLineColors(gutter: [Int: RGBA], content: [Int: RGBA]) {
        _lineColorsGutter = gutter
        _lineColorsContent = content
        requestRender()
    }

    public var fg: RGBA { _fg }

    public func setFg(_ fg: RGBA) {
        guard _fg != fg else { return }
        _fg = fg
        requestRender()
    }

    public var bg: RGBA { _bg }

    public func setBg(_ bg: RGBA) {
        guard _bg != bg else { return }
        _bg = bg
        requestRender()
    }

    public func getLineColors() -> (gutter: [Int: RGBA], content: [Int: RGBA]) {
        (gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    public func setLineSigns(_ lineSigns: [Int: LineSign]) {
        let oldMaxBefore = _maxBeforeWidth
        let oldMaxAfter = _maxAfterWidth

        _lineSigns = lineSigns
        calculateSignWidths()

        if _maxBeforeWidth != oldMaxBefore || _maxAfterWidth != oldMaxAfter {
            invalidateIntrinsicSize()
        }
        requestRender()
    }

    public func getLineSigns() -> [Int: LineSign] {
        _lineSigns
    }

    public override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        let origin = paintOrigin(for: buffer)
        let x = origin.x
        let y = origin.y
        let start = max(0, -y)
        let end = min(height, buffer.height - y)
        guard end > start && x < buffer.width && x + width > 0 else { return }

        let (top, rows) = targetTextRows(target)
        let from = max(start, top)
        let to = max(from, min(end, top + rows))

        for row in start..<end where row < from || row >= to {
            buffer.fillRect(x: x, y: y + row, width: width, height: 1, bg: _bg)
        }

        let startLine = target.scrollY + from - top
        let sourceStart = max(0, startLine - 1)
        let sourceOffset = startLine - sourceStart
        let countNeeded = max(0, to - from + sourceOffset)
        let sources = target.getLineSources(startLine: sourceStart, lineCount: countNeeded)
        var lastSource = (sourceOffset > 0 && !sources.isEmpty) ? sources[0] : -1

        for i in sourceOffset..<(to - from + sourceOffset) {
            let row = y + from + i - sourceOffset
            let logicalLine: Int? = i < sources.count ? sources[i] : nil
            let lineBg = logicalLine.flatMap { _lineColorsGutter[$0] }

            if lineBg == nil || (lineBg?.a ?? 0) < 1.0 {
                buffer.fillRect(x: x, y: row, width: width, height: 1, bg: _bg)
            }
            if let lineBg {
                buffer.fillRect(x: x, y: row, width: width, height: 1, bg: lineBg)
            }

            if let logicalLine, logicalLine != lastSource {
                if let sign = _lineSigns[logicalLine], let before = sign.before, !before.isEmpty {
                    let beforeX = x + _maxBeforeWidth - signWidth(before)
                    let beforeColor = sign.beforeColor?.resolved() ?? _fg
                    buffer.drawText(before, x: beforeX, y: row, fg: beforeColor, bg: gutterTransparent)
                }

                if !_hideLineNumbers.contains(logicalLine) {
                    let displayNum = _lineNumbers[logicalLine] ?? (logicalLine + 1 + _lineNumberOffset)
                    let lineNumStr = String(displayNum)
                    let lineNumX = width - _maxAfterWidth - _layout.paddingRight - lineNumStr.count
                    if lineNumX >= _maxBeforeWidth + _layout.paddingLeft {
                        buffer.drawText(lineNumStr, x: x + lineNumX, y: row, fg: _fg, bg: gutterTransparent)
                    }
                }

                if let sign = _lineSigns[logicalLine], let after = sign.after, !after.isEmpty {
                    let afterX = x + width - _layout.paddingRight - _maxAfterWidth
                    let afterColor = sign.afterColor?.resolved() ?? _fg
                    buffer.drawText(after, x: afterX, y: row, fg: afterColor, bg: gutterTransparent)
                }
            }

            if let logicalLine {
                lastSource = logicalLine
            }
        }
    }
}

// MARK: - LineNumberRenderable

/// Wrapper container rendering a line-number & sign gutter alongside any `Renderable & LineInfoProvider`,
/// plus optional full-width per-line gutter and content background highlights.
// parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable [status=implemented hash=7ebd8de21e08]
open class LineNumberRenderable: Renderable, @unchecked Sendable {
    public private(set) var gutter: GutterRenderable? = nil
    public private(set) var target: (Renderable & LineInfoProvider)? = nil

    private var _lineColorsGutter: [Int: RGBA] = [:]
    private var _lineColorsContent: [Int: RGBA] = [:]
    private var _lineSigns: [Int: LineSign] = [:]
    private var _fg: RGBA
    private var _bg: RGBA
    private var _layout: GutterLayout
    private var _lineNumberOffset: Int
    private var _hideLineNumbers: Set<Int>
    private var _lineNumbers: [Int: Int]
    private var _showLineNumbers: Bool
    private var _isDestroying: Bool = false
    private var targetLineInfoToken: RenderableListenerToken? = nil

    public init(ctx: any RenderContext, options: LineNumberOptions = LineNumberOptions()) {
        self._fg = options.fg?.resolved() ?? defaultGutterFg
        self._bg = options.bg?.resolved() ?? defaultGutterBg
        self._layout = GutterLayout(
            minWidth: options.minWidth ?? 3,
            paddingLeft: 1,
            paddingRight: options.paddingRight ?? 1,
            minDigits: 0,
            minAfterWidth: 0
        )
        self._lineNumberOffset = options.lineNumberOffset ?? 0
        self._hideLineNumbers = options.hideLineNumbers ?? []
        self._lineNumbers = options.lineNumbers ?? [:]
        self._showLineNumbers = options.showLineNumbers ?? true

        var baseOptions = options.base
        baseOptions.flexDirection = .row
        baseOptions.height = .auto
        super.init(ctx: ctx, options: baseOptions)

        if let lineColors = options.lineColors {
            setLineColors(lineColors)
        }
        if let lineSigns = options.lineSigns {
            _lineSigns = lineSigns
        }
        if let target = options.target {
            _ = setTarget(target)
        }
    }

    private func parseLineColor(_ line: Int, _ value: LineColorValue) {
        switch value {
        case .config(let config):
            if let gutterColor = config.gutter?.resolved() {
                _lineColorsGutter[line] = gutterColor
            }
            if let contentColor = config.content?.resolved() {
                _lineColorsContent[line] = contentColor
            } else if let gutterColor = config.gutter?.resolved() {
                _lineColorsContent[line] = darkenColor(gutterColor)
            }
        case .color(let color):
            let parsed = color.resolved()
            _lineColorsGutter[line] = parsed
            _lineColorsContent[line] = darkenColor(parsed)
        }
    }

    @discardableResult
    private func setTarget(_ target: Renderable & LineInfoProvider) -> Bool {
        guard !isDestroyed && !target.isDestroyed else { return false }
        self.target = target

        targetLineInfoToken = target.on("line-info-change") { [weak self] in
            self?.gutter?.remeasure()
            self?.requestRender()
        }

        let createdGutter = GutterRenderable(
            ctx: ctx,
            target: target,
            id: "\(id)-gutter",
            fg: _fg,
            bg: _bg,
            layout: _layout,
            lineColorsGutter: _lineColorsGutter,
            lineColorsContent: _lineColorsContent,
            lineSigns: _lineSigns,
            lineNumberOffset: _lineNumberOffset,
            hideLineNumbers: _hideLineNumbers,
            lineNumbers: _lineNumbers
        )
        createdGutter.visible = _showLineNumbers
        self.gutter = createdGutter

        let gutterIdx = super.add(createdGutter)
        let targetIdx = super.add(target)
        if gutterIdx < 0 || targetIdx < 0 {
            clearTarget()
            return false
        }
        return true
    }

    /// Intercepts child insertion and attaches the first `LineInfoProvider` as the target.
    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.add [status=implemented hash=f1a16106a2cc]
    @discardableResult
    open override func add(_ child: Renderable, index: Int? = nil) -> Int {
        guard !isDestroyed else { return -1 }
        if target == nil, let provider = child as? (Renderable & LineInfoProvider) {
            return setTarget(provider) ? (getChildrenCount() - 1) : -1
        }
        return -1
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.remove [status=adapted hash=f7141dae06d8]
    open override func remove(_ child: Renderable) {
        if _isDestroying {
            super.remove(child)
            return
        }
        if let gutter, child === gutter {
            if gutter.isDestroyed {
                clearTarget()
            }
            return
        }
        if let target, child === target {
            if target.isDestroyed {
                clearTarget()
            }
            return
        }
        super.remove(child)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearTarget [status=implemented hash=4c973da79758]
    public func clearTarget() {
        let currentTarget = target
        let currentGutter = gutter
        guard currentTarget != nil || currentGutter != nil else { return }

        if let currentTarget {
            if let token = targetLineInfoToken {
                currentTarget.off(token)
                targetLineInfoToken = nil
            }
            if currentTarget.parent === self {
                super.remove(currentTarget)
            }
            target = nil
        }

        if let currentGutter {
            if currentGutter.parent === self {
                super.remove(currentGutter)
            }
            gutter = nil
            currentGutter.destroy()
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.destroy [status=implemented hash=3e0df50a22b4]
    open override func destroy() {
        guard !isDestroyed else { return }
        _isDestroying = true
        super.destroy()
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.destroyRecursively [status=implemented hash=576b1fe4ed30]
    open override func destroyRecursively() {
        guard !isDestroyed else { return }
        _isDestroying = true
        super.destroyRecursively()
    }

    open override func destroySelf() {
        if let currentTarget = target, let token = targetLineInfoToken {
            currentTarget.off(token)
            targetLineInfoToken = nil
        }
        let currentGutter = gutter
        gutter = nil
        target = nil
        if let currentGutter, !currentGutter.isDestroyed {
            currentGutter.destroy()
        }
        super.destroySelf()
    }

    open override func renderSelf(buffer: OptimizedBuffer, deltaTime: Double) {
        guard let target, let gutter, !_lineColorsContent.isEmpty else { return }

        let origin = paintOrigin(for: buffer)
        let x = origin.x
        let y = origin.y
        let start = max(0, -y)
        let end = min(height, buffer.height - y)
        guard end > start && x < buffer.width && x + width > 0 else { return }

        let (top, rows) = targetTextRows(target)
        let from = max(start, top)
        let lineCountNeeded = max(0, min(end, top + rows) - from)
        let sources = target.getLineSources(
            startLine: target.scrollY + from - top,
            lineCount: lineCountNeeded
        )

        let gutterWidth = gutter.visible ? gutter.width : 0
        let contentWidth = max(0, width - gutterWidth)
        guard contentWidth > 0 else { return }

        for i in 0..<sources.count {
            let logicalLine = sources[i]
            if let lineBg = _lineColorsContent[logicalLine] {
                buffer.fillRect(x: x + gutterWidth, y: y + from + i, width: contentWidth, height: 1, bg: lineBg)
            }
        }
    }

    // MARK: - Properties & Mutators

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.showLineNumbers [status=implemented hash=df4c19c708a6]
    public var showLineNumbers: Bool {
        get { gutter?.visible ?? _showLineNumbers }
        set {
            _showLineNumbers = newValue
            gutter?.visible = newValue
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.fg [status=implemented hash=9be35c345043]
    public var fg: RGBA {
        get { _fg }
        set {
            _fg = newValue
            gutter?.setFg(newValue)
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.bg [status=implemented hash=243845f8004a]
    public var bg: RGBA {
        get { _bg }
        set {
            _bg = newValue
            gutter?.setBg(newValue)
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setLineColor [status=implemented hash=c7ece54898a7]
    public func setLineColor(_ line: Int, _ color: LineColorValue) {
        parseLineColor(line, color)
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearLineColor [status=implemented hash=fd020c36d38e]
    public func clearLineColor(_ line: Int) {
        _lineColorsGutter.removeValue(forKey: line)
        _lineColorsContent.removeValue(forKey: line)
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearAllLineColors [status=implemented hash=2832fd10e617]
    public func clearAllLineColors() {
        _lineColorsGutter.removeAll()
        _lineColorsContent.removeAll()
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.lineColors [status=implemented hash=207a5aedddc0]
    public var lineColors: [Int: LineColorValue]? {
        get {
            var map: [Int: LineColorValue] = [:]
            let allKeys = Set(_lineColorsGutter.keys).union(_lineColorsContent.keys)
            for key in allKeys {
                map[key] = .config(LineColorConfig(
                    gutter: _lineColorsGutter[key].map { .rgba($0) },
                    content: _lineColorsContent[key].map { .rgba($0) }
                ))
            }
            return map
        }
        set {
            if let newValue {
                setLineColors(newValue)
            } else {
                clearAllLineColors()
            }
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setLineColors [status=implemented hash=f0322fa610ad]
    public func setLineColors(_ lineColors: [Int: LineColorValue]) {
        _lineColorsGutter.removeAll()
        _lineColorsContent.removeAll()
        for (line, color) in lineColors {
            parseLineColor(line, color)
        }
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.getLineColors [status=implemented hash=32dd448e6c32]
    public func getLineColors() -> (gutter: [Int: RGBA], content: [Int: RGBA]) {
        (gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setLineSign [status=implemented hash=9d0bfbee7910]
    public func setLineSign(_ line: Int, _ sign: LineSign) {
        _lineSigns[line] = sign
        gutter?.setLineSigns(_lineSigns)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearLineSign [status=implemented hash=cb2fc59f640e]
    public func clearLineSign(_ line: Int) {
        _lineSigns.removeValue(forKey: line)
        gutter?.setLineSigns(_lineSigns)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearAllLineSigns [status=implemented hash=fbe7a938cd94]
    public func clearAllLineSigns() {
        _lineSigns.removeAll()
        gutter?.setLineSigns(_lineSigns)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setLineSigns [status=implemented hash=a369d47f2793]
    public func setLineSigns(_ lineSigns: [Int: LineSign]) {
        _lineSigns = lineSigns
        gutter?.setLineSigns(_lineSigns)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.lineSigns [status=implemented hash=9f3c2b205312]
    public var lineSigns: [Int: LineSign]? {
        get { _lineSigns }
        set {
            if let newValue {
                setLineSigns(newValue)
            } else {
                clearAllLineSigns()
            }
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.getLineSigns [status=implemented hash=e4ee1bbca64c]
    public func getLineSigns() -> [Int: LineSign] {
        _lineSigns
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.getGutterLayout [status=implemented hash=14122815dcaa]
    public func getGutterLayout() -> GutterLayout {
        _layout
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setGutterLayout [status=implemented hash=c0a5a72688a1]
    public func setGutterLayout(_ layout: GutterLayout) {
        guard _layout != layout else { return }
        _layout = layout
        gutter?.setLayout(layout)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.lineNumberOffset [status=implemented hash=945638eeaa0c]
    public var lineNumberOffset: Int {
        get { _lineNumberOffset }
        set {
            guard _lineNumberOffset != newValue else { return }
            _lineNumberOffset = newValue
            gutter?.setLineNumberOffset(newValue)
        }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setHideLineNumbers [status=implemented hash=2149a6d5bfb6]
    public func setHideLineNumbers(_ hideLineNumbers: Set<Int>) {
        _hideLineNumbers = hideLineNumbers
        gutter?.setHideLineNumbers(hideLineNumbers)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.getHideLineNumbers [status=implemented hash=64ff6fb05412]
    public func getHideLineNumbers() -> Set<Int> {
        _hideLineNumbers
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.hideLineNumbers [status=implemented hash=200261d032f3]
    public var hideLineNumbers: Set<Int> {
        get { _hideLineNumbers }
        set { setHideLineNumbers(newValue) }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.setLineNumbers [status=implemented hash=5bf3e8b9ea67]
    public func setLineNumbers(_ lineNumbers: [Int: Int]) {
        _lineNumbers = lineNumbers
        gutter?.setLineNumbers(lineNumbers)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.getLineNumbers [status=implemented hash=91be7948a661]
    public func getLineNumbers() -> [Int: Int] {
        _lineNumbers
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.lineNumbers [status=implemented hash=e88770eeaa61]
    public var lineNumbers: [Int: Int] {
        get { _lineNumbers }
        set { setLineNumbers(newValue) }
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.highlightLines [status=implemented hash=6aba4e6581cd]
    public func highlightLines(startLine: Int, endLine: Int, color: LineColorValue) {
        guard startLine <= endLine else { return }
        for line in startLine...endLine {
            parseLineColor(line, color)
        }
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }

    // parity: core/src/renderables/LineNumberRenderable.ts#LineNumberRenderable.clearHighlightLines [status=implemented hash=a9d5ca7b895f]
    public func clearHighlightLines(startLine: Int, endLine: Int) {
        guard startLine <= endLine else { return }
        for line in startLine...endLine {
            _lineColorsGutter.removeValue(forKey: line)
            _lineColorsContent.removeValue(forKey: line)
        }
        gutter?.setLineColors(gutter: _lineColorsGutter, content: _lineColorsContent)
    }
}
