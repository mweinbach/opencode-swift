import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - DiffRenderableOptions / DiffOptions

/// Configuration options for `DiffRenderable`, supporting unified and side-by-side split views,
/// syntax highlighting, gutter/sign customization, and word-level intra-line diff highlights.
// parity: core/src/renderables/Diff.ts#DiffRenderableOptions [status=implemented hash=608518978a27]
public struct DiffOptions {
    public var base: RenderableOptions
    public var diff: String?
    public var syncScroll: Bool?
    public var view: DiffViewMode?

    // CodeRenderable options
    public var fg: Color?
    public var filetype: String?
    public var syntaxStyle: SyntaxStyle?
    public var wrapMode: TextWrapMode?
    public var conceal: Bool?
    public var selectionBg: Color?
    public var selectionFg: Color?
    public var highlighter: (any SyntaxHighlighter)?

    // LineNumberRenderable options
    public var showLineNumbers: Bool?
    public var lineNumberFg: Color?
    public var lineNumberBg: Color?
    public var gutter: DiffGutterOptions?

    // Diff styling
    public var addedBg: Color?
    public var removedBg: Color?
    public var contextBg: Color?
    public var emptyBg: Color?
    public var addedContentBg: Color?
    public var removedContentBg: Color?
    public var contextContentBg: Color?
    public var addedWordBg: Color?
    public var removedWordBg: Color?
    public var showWordDiff: Bool?
    public var addedSignColor: Color?
    public var removedSignColor: Color?
    public var addedLineNumberBg: Color?
    public var removedLineNumberBg: Color?

    public init(
        id: String? = nil,
        diff: String? = nil,
        syncScroll: Bool? = nil,
        view: DiffViewMode? = nil,
        fg: Color? = nil,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        wrapMode: TextWrapMode? = nil,
        conceal: Bool? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        showLineNumbers: Bool? = nil,
        lineNumberFg: Color? = nil,
        lineNumberBg: Color? = nil,
        gutter: DiffGutterOptions? = nil,
        addedBg: Color? = nil,
        removedBg: Color? = nil,
        contextBg: Color? = nil,
        emptyBg: Color? = nil,
        addedContentBg: Color? = nil,
        removedContentBg: Color? = nil,
        contextContentBg: Color? = nil,
        addedWordBg: Color? = nil,
        removedWordBg: Color? = nil,
        showWordDiff: Bool? = nil,
        addedSignColor: Color? = nil,
        removedSignColor: Color? = nil,
        addedLineNumberBg: Color? = nil,
        removedLineNumberBg: Color? = nil,
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
        overflow: Overflow? = nil,
        zIndex: Int? = nil,
        visible: Bool? = nil,
        buffered: Bool? = nil
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
            overflow: overflow,
            zIndex: zIndex,
            visible: visible,
            buffered: buffered
        )
        self.diff = diff
        self.syncScroll = syncScroll
        self.view = view
        self.fg = fg
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.wrapMode = wrapMode
        self.conceal = conceal
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.highlighter = highlighter
        self.showLineNumbers = showLineNumbers
        self.lineNumberFg = lineNumberFg
        self.lineNumberBg = lineNumberBg
        self.gutter = gutter
        self.addedBg = addedBg
        self.removedBg = removedBg
        self.contextBg = contextBg
        self.emptyBg = emptyBg
        self.addedContentBg = addedContentBg
        self.removedContentBg = removedContentBg
        self.contextContentBg = contextContentBg
        self.addedWordBg = addedWordBg
        self.removedWordBg = removedWordBg
        self.showWordDiff = showWordDiff
        self.addedSignColor = addedSignColor
        self.removedSignColor = removedSignColor
        self.addedLineNumberBg = addedLineNumberBg
        self.removedLineNumberBg = removedLineNumberBg
    }

    public init(
        base: RenderableOptions,
        diff: String? = nil,
        syncScroll: Bool? = nil,
        view: DiffViewMode? = nil,
        fg: Color? = nil,
        filetype: String? = nil,
        syntaxStyle: SyntaxStyle? = nil,
        wrapMode: TextWrapMode? = nil,
        conceal: Bool? = nil,
        selectionBg: Color? = nil,
        selectionFg: Color? = nil,
        highlighter: (any SyntaxHighlighter)? = nil,
        showLineNumbers: Bool? = nil,
        lineNumberFg: Color? = nil,
        lineNumberBg: Color? = nil,
        gutter: DiffGutterOptions? = nil,
        addedBg: Color? = nil,
        removedBg: Color? = nil,
        contextBg: Color? = nil,
        emptyBg: Color? = nil,
        addedContentBg: Color? = nil,
        removedContentBg: Color? = nil,
        contextContentBg: Color? = nil,
        addedWordBg: Color? = nil,
        removedWordBg: Color? = nil,
        showWordDiff: Bool? = nil,
        addedSignColor: Color? = nil,
        removedSignColor: Color? = nil,
        addedLineNumberBg: Color? = nil,
        removedLineNumberBg: Color? = nil
    ) {
        self.base = base
        self.diff = diff
        self.syncScroll = syncScroll
        self.view = view
        self.fg = fg
        self.filetype = filetype
        self.syntaxStyle = syntaxStyle
        self.wrapMode = wrapMode
        self.conceal = conceal
        self.selectionBg = selectionBg
        self.selectionFg = selectionFg
        self.highlighter = highlighter
        self.showLineNumbers = showLineNumbers
        self.lineNumberFg = lineNumberFg
        self.lineNumberBg = lineNumberBg
        self.gutter = gutter
        self.addedBg = addedBg
        self.removedBg = removedBg
        self.contextBg = contextBg
        self.emptyBg = emptyBg
        self.addedContentBg = addedContentBg
        self.removedContentBg = removedContentBg
        self.contextContentBg = contextContentBg
        self.addedWordBg = addedWordBg
        self.removedWordBg = removedWordBg
        self.showWordDiff = showWordDiff
        self.addedSignColor = addedSignColor
        self.removedSignColor = removedSignColor
        self.addedLineNumberBg = addedLineNumberBg
        self.removedLineNumberBg = removedLineNumberBg
    }
}

/// Alias matching upstream `DiffRenderableOptions`.
public typealias DiffRenderableOptions = DiffOptions

// MARK: - Internal Models & Word-Level Diff Helpers

private let diffSignWidth = 2

private enum DiffDefaultColors {
    static let lineNumberFg = parseColor("#888888")
    static let lineNumberBg = RGBA.fromValues(0, 0, 0, 0)
    static let addedBg = parseColor("#1a4d1a")
    static let removedBg = parseColor("#4d1a1a")
    static let contextBg = RGBA.fromValues(0, 0, 0, 0)
    static let emptyBg = RGBA.fromValues(0, 0, 0, 0)
    static let addedSignColor = parseColor("#22c55e")
    static let removedSignColor = parseColor("#ef4444")
    static let addedLineNumberBg = RGBA.fromValues(0, 0, 0, 0)
    static let removedLineNumberBg = RGBA.fromValues(0, 0, 0, 0)

    static func wordAccent(from base: RGBA) -> RGBA {
        guard base.a > 0 else { return base }
        return RGBA.fromValues(
            min(1.0, base.r * 1.65 + 0.06),
            min(1.0, base.g * 1.65 + 0.06),
            min(1.0, base.b * 1.65 + 0.06),
            base.a
        )
    }
}

private struct DiffLogicalLine {
    var content: String
    var lineNum: Int?
    var hideLineNumber: Bool
    var kind: DiffLineKind
    var sign: LineSign?
    var hunkStart: Bool
    /// UTF-16 ranges within `content` that changed relative to the paired line.
    var wordHighlights: [Range<Int>]
}

private struct WordHighlightSpan {
    let start: Int
    let end: Int
    let bg: RGBA
}

private struct WordToken {
    let text: String
    let startUTF16: Int
    let endUTF16: Int
}

private func tokenizeForWordDiff(_ line: String) -> [WordToken] {
    guard !line.isEmpty else { return [] }
    let units = Array(line.utf16)
    let n = units.count

    func charClass(_ u: UInt16) -> Int {
        if (u >= 0x30 && u <= 0x39)
            || (u >= 0x41 && u <= 0x5A)
            || (u >= 0x61 && u <= 0x7A)
            || u == 0x5F
        {
            return 1 // word
        }
        if u == 0x20 || u == 0x09 {
            return 2 // inline whitespace
        }
        return 3 // punctuation / other
    }

    var tokens: [WordToken] = []
    var i = 0
    while i < n {
        let start = i
        let cls = charClass(units[i])
        if cls == 3 {
            // Treat individual punctuation/symbol (or surrogate pair) as its own token for tight diffs.
            if i + 1 < n && units[i] >= 0xD800 && units[i] <= 0xDBFF && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
                i += 2
            } else {
                i += 1
            }
        } else {
            i += 1
            while i < n && charClass(units[i]) == cls {
                i += 1
            }
        }
        let text = String(decoding: units[start..<i], as: UTF16.self)
        tokens.append(WordToken(text: text, startUTF16: start, endUTF16: i))
    }
    return tokens
}

private func mergeAdjacentRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
    guard ranges.count > 1 else { return ranges }
    var merged: [Range<Int>] = [ranges[0]]
    for i in 1..<ranges.count {
        let next = ranges[i]
        if next.lowerBound <= merged[merged.count - 1].upperBound {
            merged[merged.count - 1] = merged[merged.count - 1].lowerBound..<max(merged[merged.count - 1].upperBound, next.upperBound)
        } else {
            merged.append(next)
        }
    }
    return merged
}

/// Computes UTF-16 ranges of changed tokens between an old line and a new line using token-level LCS.
private func computeWordDiffRanges(oldLine: String, newLine: String) -> (oldRanges: [Range<Int>], newRanges: [Range<Int>]) {
    if oldLine == newLine || oldLine.isEmpty || newLine.isEmpty {
        return ([], [])
    }

    let oldTokens = tokenizeForWordDiff(oldLine)
    let newTokens = tokenizeForWordDiff(newLine)
    let m = oldTokens.count
    let n = newTokens.count
    guard m > 0 && n > 0 else { return ([], []) }

    // Trim common prefix and suffix tokens first so LCS runs on only the middle window.
    var prefix = 0
    while prefix < m && prefix < n && oldTokens[prefix].text == newTokens[prefix].text {
        prefix += 1
    }
    var suffix = 0
    while suffix < (m - prefix) && suffix < (n - prefix)
        && oldTokens[m - 1 - suffix].text == newTokens[n - 1 - suffix].text
    {
        suffix += 1
    }

    let oldMidCount = m - prefix - suffix
    let newMidCount = n - prefix - suffix
    if oldMidCount == 0 && newMidCount == 0 {
        return ([], [])
    }

    // Bound DP table size for pathologically long minified lines.
    if oldMidCount * newMidCount > 16_384 {
        let oldRanges: [Range<Int>] = oldMidCount > 0
            ? [oldTokens[prefix].startUTF16..<oldTokens[m - suffix - 1].endUTF16]
            : []
        let newRanges: [Range<Int>] = newMidCount > 0
            ? [newTokens[prefix].startUTF16..<newTokens[n - suffix - 1].endUTF16]
            : []
        return (oldRanges, newRanges)
    }

    // Standard LCS DP over the middle token slices.
    let cols = newMidCount + 1
    var dp = Array(repeating: 0, count: (oldMidCount + 1) * cols)
    for i in stride(from: oldMidCount - 1, through: 0, by: -1) {
        let oldText = oldTokens[prefix + i].text
        for j in stride(from: newMidCount - 1, through: 0, by: -1) {
            if oldText == newTokens[prefix + j].text {
                dp[i * cols + j] = dp[(i + 1) * cols + (j + 1)] + 1
            } else {
                dp[i * cols + j] = max(dp[(i + 1) * cols + j], dp[i * cols + (j + 1)])
            }
        }
    }

    var oldMatched = Array(repeating: false, count: oldMidCount)
    var newMatched = Array(repeating: false, count: newMidCount)
    var i = 0
    var j = 0
    while i < oldMidCount && j < newMidCount {
        if oldTokens[prefix + i].text == newTokens[prefix + j].text {
            oldMatched[i] = true
            newMatched[j] = true
            i += 1
            j += 1
        } else if dp[(i + 1) * cols + j] >= dp[i * cols + (j + 1)] {
            i += 1
        } else {
            j += 1
        }
    }

    var oldChanged: [Range<Int>] = []
    for k in 0..<oldMidCount where !oldMatched[k] {
        let tok = oldTokens[prefix + k]
        oldChanged.append(tok.startUTF16..<tok.endUTF16)
    }
    var newChanged: [Range<Int>] = []
    for k in 0..<newMidCount where !newMatched[k] {
        let tok = newTokens[prefix + k]
        newChanged.append(tok.startUTF16..<tok.endUTF16)
    }

    return (mergeAdjacentRanges(oldChanged), mergeAdjacentRanges(newChanged))
}

/// Overlays UTF-16 document-offset background spans onto styled `TextChunk`s without clobbering
/// syntax-highlighted `fg`, `attributes`, or `link`.
private func applyWordHighlightSpans(
    chunks: [TextChunk],
    spans: [WordHighlightSpan]
) -> [TextChunk] {
    guard !chunks.isEmpty && !spans.isEmpty else { return chunks }

    var out: [TextChunk] = []
    out.reserveCapacity(chunks.count + spans.count)

    var chunkStart = 0
    var spanIdx = 0

    for chunk in chunks {
        let units = Array(chunk.text.utf16)
        let chunkEnd = chunkStart + units.count
        if units.isEmpty {
            out.append(chunk)
            continue
        }

        while spanIdx < spans.count && spans[spanIdx].end <= chunkStart {
            spanIdx += 1
        }

        if spanIdx >= spans.count || spans[spanIdx].start >= chunkEnd {
            out.append(chunk)
            chunkStart = chunkEnd
            continue
        }

        var cursor = chunkStart
        var localSpan = spanIdx
        while cursor < chunkEnd {
            while localSpan < spans.count && spans[localSpan].end <= cursor {
                localSpan += 1
            }
            if localSpan >= spans.count || spans[localSpan].start >= chunkEnd {
                let slice = String(decoding: units[(cursor - chunkStart)..<units.count], as: UTF16.self)
                out.append(TextChunk(text: slice, fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes, link: chunk.link))
                break
            }

            let span = spans[localSpan]
            if cursor < span.start {
                let segEnd = min(span.start, chunkEnd)
                let slice = String(decoding: units[(cursor - chunkStart)..<(segEnd - chunkStart)], as: UTF16.self)
                out.append(TextChunk(text: slice, fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes, link: chunk.link))
                cursor = segEnd
            } else {
                let segEnd = min(span.end, chunkEnd)
                let slice = String(decoding: units[(cursor - chunkStart)..<(segEnd - chunkStart)], as: UTF16.self)
                out.append(TextChunk(text: slice, fg: chunk.fg, bg: span.bg, attributes: chunk.attributes, link: chunk.link))
                cursor = segEnd
            }
        }

        chunkStart = chunkEnd
    }

    return out
}

// MARK: - DiffRenderable

/// Unified and side-by-side split diff viewer renderable composing `LineNumberRenderable`
/// and `CodeRenderable` over `parseUnifiedDiff` / `buildUnifiedDiffLines` / `buildSplitDiffLines`.
// parity: core/src/renderables/Diff.ts#DiffRenderable [status=implemented hash=ac5236e6279d]
open class DiffRenderable: Renderable, @unchecked Sendable {
    private var _diff: String
    private var _syncScroll: Bool
    private var _view: DiffViewMode
    private var _parsedDiff: ParsedDiff? = nil
    private var _parseError: DiffParseError? = nil

    private var _hunkStartLines: [Int] = []
    private var _hunkRowOffsets: [Int]? = nil

    // CodeRenderable options
    private var _fg: RGBA?
    private var _filetype: String?
    private var _syntaxStyle: SyntaxStyle?
    private var _fallbackSyntaxStyle: SyntaxStyle? = nil
    private var _wrapMode: TextWrapMode?
    private var _conceal: Bool
    private var _selectionBg: RGBA?
    private var _selectionFg: RGBA?
    private var _highlighter: (any SyntaxHighlighter)?

    // LineNumberRenderable options
    private var _showLineNumbers: Bool
    private var _lineNumberFg: RGBA
    private var _lineNumberBg: RGBA
    private var _gutter: DiffGutterOptions

    // Diff styling
    private var _addedBg: RGBA
    private var _removedBg: RGBA
    private var _contextBg: RGBA
    private var _emptyBg: RGBA
    private var _addedContentBg: RGBA?
    private var _removedContentBg: RGBA?
    private var _contextContentBg: RGBA?
    private var _addedWordBg: RGBA?
    private var _removedWordBg: RGBA?
    private var _showWordDiff: Bool
    private var _addedSignColor: RGBA
    private var _removedSignColor: RGBA
    private var _addedLineNumberBg: RGBA
    private var _removedLineNumberBg: RGBA

    // Managed pane renderables
    public private(set) var leftSide: LineNumberRenderable? = nil
    public private(set) var rightSide: LineNumberRenderable? = nil
    private var leftSideAdded: Bool = false
    private var rightSideAdded: Bool = false

    public private(set) var leftCodeRenderable: CodeRenderable? = nil
    public private(set) var rightCodeRenderable: CodeRenderable? = nil

    private var errorTextRenderable: TextRenderable? = nil
    private var errorCodeRenderable: CodeRenderable? = nil

    private var _lastCodeWidths: (Int, Int) = (0, 0)
    private var _needsSplitWrapAlignment: Bool = false
    private var _leftLineInfoToken: RenderableListenerToken? = nil
    private var _rightLineInfoToken: RenderableListenerToken? = nil

    public init(ctx: any RenderContext, options: DiffOptions = DiffOptions()) {
        let initialView = options.view ?? .unified
        self._diff = options.diff ?? ""
        self._syncScroll = options.syncScroll ?? false
        self._view = initialView

        self._fg = options.fg.map { RGBA.clone($0.resolved()) }
        self._filetype = options.filetype
        self._syntaxStyle = options.syntaxStyle
        self._wrapMode = options.wrapMode
        self._conceal = options.conceal ?? false
        self._selectionBg = options.selectionBg.map { RGBA.clone($0.resolved()) }
        self._selectionFg = options.selectionFg.map { RGBA.clone($0.resolved()) }
        self._highlighter = options.highlighter

        self._showLineNumbers = options.showLineNumbers ?? true
        self._lineNumberFg = RGBA.clone(options.lineNumberFg?.resolved() ?? DiffDefaultColors.lineNumberFg)
        self._lineNumberBg = RGBA.clone(options.lineNumberBg?.resolved() ?? DiffDefaultColors.lineNumberBg)
        self._gutter = options.gutter ?? DiffGutterOptions()

        self._addedBg = RGBA.clone(options.addedBg?.resolved() ?? DiffDefaultColors.addedBg)
        self._removedBg = RGBA.clone(options.removedBg?.resolved() ?? DiffDefaultColors.removedBg)
        self._contextBg = RGBA.clone(options.contextBg?.resolved() ?? DiffDefaultColors.contextBg)
        self._emptyBg = RGBA.clone(options.emptyBg?.resolved() ?? DiffDefaultColors.emptyBg)
        self._addedContentBg = options.addedContentBg.map { RGBA.clone($0.resolved()) }
        self._removedContentBg = options.removedContentBg.map { RGBA.clone($0.resolved()) }
        self._contextContentBg = options.contextContentBg.map { RGBA.clone($0.resolved()) }
        self._addedWordBg = options.addedWordBg.map { RGBA.clone($0.resolved()) }
        self._removedWordBg = options.removedWordBg.map { RGBA.clone($0.resolved()) }
        self._showWordDiff = options.showWordDiff ?? true
        self._addedSignColor = RGBA.clone(options.addedSignColor?.resolved() ?? DiffDefaultColors.addedSignColor)
        self._removedSignColor = RGBA.clone(options.removedSignColor?.resolved() ?? DiffDefaultColors.removedSignColor)
        self._addedLineNumberBg = RGBA.clone(options.addedLineNumberBg?.resolved() ?? DiffDefaultColors.addedLineNumberBg)
        self._removedLineNumberBg = RGBA.clone(options.removedLineNumberBg?.resolved() ?? DiffDefaultColors.removedLineNumberBg)

        var baseOptions = options.base
        baseOptions.flexDirection = initialView == .split ? .row : .column
        super.init(ctx: ctx, options: baseOptions)

        if !self._diff.isEmpty {
            parseDiff()
            buildView()
        }
    }

    // MARK: - Public Properties

    // parity: core/src/renderables/Diff.ts#DiffRenderable.diff [status=implemented hash=f309e2ab6625]
    public var diff: String {
        get { _diff }
        set {
            guard _diff != newValue else { return }
            _diff = newValue
            parseDiff()
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.syncScroll [status=implemented hash=81b0fb04f6f0]
    public var syncScroll: Bool {
        get { _syncScroll }
        set { _syncScroll = newValue }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.view [status=implemented hash=ef72814ecd3d]
    public var view: DiffViewMode {
        get { _view }
        set {
            guard _view != newValue else { return }
            _view = newValue
            self.flexDirection = newValue == .split ? .row : .column
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.filetype [status=implemented hash=ddae957c3d9e]
    public var filetype: String? {
        get { _filetype }
        set {
            guard _filetype != newValue else { return }
            _filetype = newValue
            buildView()
        }
    }

    /// Pluggable syntax highlighter forwarded to child `CodeRenderable` panes.
    // parity: core/src/renderables/Diff.ts#DiffRenderable.treeSitterClient [status=adapted hash=7638dcc53dce]
    public var highlighter: (any SyntaxHighlighter)? {
        get { _highlighter }
        set {
            _highlighter = newValue
            let resolved: any SyntaxHighlighter = newValue ?? BuiltInSyntaxHighlighter.shared
            for code in [leftCodeRenderable, rightCodeRenderable, errorCodeRenderable] {
                if let code, !code.isDestroyed {
                    code.highlighter = resolved
                }
            }
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.syntaxStyle [status=implemented hash=d9c6ee6c22af]
    public var syntaxStyle: SyntaxStyle? {
        get { _syntaxStyle }
        set {
            guard _syntaxStyle !== newValue else { return }
            _syntaxStyle = newValue
            let style = codeSyntaxStyle
            for code in [leftCodeRenderable, rightCodeRenderable, errorCodeRenderable] {
                if let code, !code.isDestroyed {
                    code.syntaxStyle = style
                }
            }
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.wrapMode [status=implemented hash=d9f15f4a4e2d]
    public var wrapMode: TextWrapMode? {
        get { _wrapMode }
        set {
            guard _wrapMode != newValue else { return }
            _wrapMode = newValue
            invalidateHunkRowOffsets()

            if _view == .unified, let left = leftCodeRenderable {
                left.wrapMode = newValue ?? .none
            } else if _view == .split {
                _needsSplitWrapAlignment = (newValue == .word || newValue == .char)
                buildView()
            }
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.showLineNumbers [status=implemented hash=ea3852dd1bdd]
    public var showLineNumbers: Bool {
        get { _showLineNumbers }
        set {
            guard _showLineNumbers != newValue else { return }
            _showLineNumbers = newValue
            leftSide?.showLineNumbers = newValue
            rightSide?.showLineNumbers = newValue
            if _view == .split && (_wrapMode == .word || _wrapMode == .char) {
                _needsSplitWrapAlignment = true
            }
            requestRender()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.addedBg [status=implemented hash=743d00c1a549]
    public var addedBg: RGBA {
        get { RGBA.clone(_addedBg) }
        set {
            _addedBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.removedBg [status=implemented hash=c110d20db69a]
    public var removedBg: RGBA {
        get { RGBA.clone(_removedBg) }
        set {
            _removedBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.contextBg [status=implemented hash=d6473b2e6123]
    public var contextBg: RGBA {
        get { RGBA.clone(_contextBg) }
        set {
            _contextBg = RGBA.clone(newValue)
            buildView()
        }
    }

    public var emptyBg: RGBA {
        get { RGBA.clone(_emptyBg) }
        set {
            _emptyBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.addedSignColor [status=implemented hash=3711b0eaf08e]
    public var addedSignColor: RGBA {
        get { RGBA.clone(_addedSignColor) }
        set {
            _addedSignColor = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.removedSignColor [status=implemented hash=54e2cd4c6f7e]
    public var removedSignColor: RGBA {
        get { RGBA.clone(_removedSignColor) }
        set {
            _removedSignColor = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.addedLineNumberBg [status=implemented hash=e6e7b6a7852e]
    public var addedLineNumberBg: RGBA {
        get { RGBA.clone(_addedLineNumberBg) }
        set {
            _addedLineNumberBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.removedLineNumberBg [status=implemented hash=e5b3e95724c3]
    public var removedLineNumberBg: RGBA {
        get { RGBA.clone(_removedLineNumberBg) }
        set {
            _removedLineNumberBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.lineNumberFg [status=implemented hash=a4853fe5f228]
    public var lineNumberFg: RGBA {
        get { RGBA.clone(_lineNumberFg) }
        set {
            _lineNumberFg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.lineNumberBg [status=implemented hash=678dcb6576b8]
    public var lineNumberBg: RGBA {
        get { RGBA.clone(_lineNumberBg) }
        set {
            _lineNumberBg = RGBA.clone(newValue)
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.gutter [status=implemented hash=b2c393451514]
    public var gutter: DiffGutterOptions {
        get { _gutter }
        set {
            guard _gutter != newValue else { return }
            _gutter = newValue
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.addedContentBg [status=implemented hash=7836efdcb13a]
    public var addedContentBg: RGBA? {
        get { _addedContentBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _addedContentBg != parsed else { return }
            _addedContentBg = parsed
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.removedContentBg [status=implemented hash=23ccbdaeb1f1]
    public var removedContentBg: RGBA? {
        get { _removedContentBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _removedContentBg != parsed else { return }
            _removedContentBg = parsed
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.contextContentBg [status=implemented hash=eb782ab026a5]
    public var contextContentBg: RGBA? {
        get { _contextContentBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _contextContentBg != parsed else { return }
            _contextContentBg = parsed
            buildView()
        }
    }

    public var addedWordBg: RGBA? {
        get { _addedWordBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _addedWordBg != parsed else { return }
            _addedWordBg = parsed
            buildView()
        }
    }

    public var removedWordBg: RGBA? {
        get { _removedWordBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _removedWordBg != parsed else { return }
            _removedWordBg = parsed
            buildView()
        }
    }

    public var showWordDiff: Bool {
        get { _showWordDiff }
        set {
            guard _showWordDiff != newValue else { return }
            _showWordDiff = newValue
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.selectionBg [status=implemented hash=0ffa10d53c68]
    public var selectionBg: RGBA? {
        get { _selectionBg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _selectionBg != parsed else { return }
            _selectionBg = parsed
            leftCodeRenderable?.selectionBg = parsed
            rightCodeRenderable?.selectionBg = parsed
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.selectionFg [status=implemented hash=fa0cbfd54b6b]
    public var selectionFg: RGBA? {
        get { _selectionFg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _selectionFg != parsed else { return }
            _selectionFg = parsed
            leftCodeRenderable?.selectionFg = parsed
            rightCodeRenderable?.selectionFg = parsed
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.conceal [status=implemented hash=b7c050deeec5]
    public var conceal: Bool {
        get { _conceal }
        set {
            guard _conceal != newValue else { return }
            _conceal = newValue
            buildView()
        }
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.fg [status=implemented hash=9c25bfcc5e8d]
    public var fg: RGBA? {
        get { _fg.map(RGBA.clone) }
        set {
            let parsed = newValue.map(RGBA.clone)
            guard _fg != parsed else { return }
            _fg = parsed
            if let parsed {
                leftCodeRenderable?.fg = parsed
                rightCodeRenderable?.fg = parsed
            }
        }
    }

    public var parseError: DiffParseError? {
        _parseError
    }

    // MARK: - Line Color Forwarding & Hunk Offsets

    // parity: core/src/renderables/Diff.ts#DiffRenderable.setLineColor [status=implemented hash=79e418889f5f]
    public func setLineColor(_ line: Int, _ color: LineColorValue) {
        leftSide?.setLineColor(line, color)
        rightSide?.setLineColor(line, color)
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.clearLineColor [status=implemented hash=b29e6a77205e]
    public func clearLineColor(_ line: Int) {
        leftSide?.clearLineColor(line)
        rightSide?.clearLineColor(line)
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.setLineColors [status=implemented hash=42c7e16a6520]
    public func setLineColors(_ lineColors: [Int: LineColorValue]) {
        leftSide?.setLineColors(lineColors)
        rightSide?.setLineColors(lineColors)
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.clearAllLineColors [status=implemented hash=b257c9ad0e6c]
    public func clearAllLineColors() {
        leftSide?.clearAllLineColors()
        rightSide?.clearAllLineColors()
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.highlightLines [status=implemented hash=398d4ddd2f66]
    public func highlightLines(startLine: Int, endLine: Int, color: LineColorValue) {
        leftSide?.highlightLines(startLine: startLine, endLine: endLine, color: color)
        rightSide?.highlightLines(startLine: startLine, endLine: endLine, color: color)
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.clearHighlightLines [status=implemented hash=a96921c51bc4]
    public func clearHighlightLines(startLine: Int, endLine: Int) {
        leftSide?.clearHighlightLines(startLine: startLine, endLine: endLine)
        rightSide?.clearHighlightLines(startLine: startLine, endLine: endLine)
    }

    // parity: core/src/renderables/Diff.ts#DiffRenderable.getHunkRowOffsets [status=implemented hash=5d423aff0ef5]
    public func getHunkRowOffsets() -> [Int] {
        if let cached = _hunkRowOffsets {
            return cached
        }
        let computed = computeHunkRowOffsets()
        _hunkRowOffsets = computed
        return computed
    }

    private func computeHunkRowOffsets() -> [Int] {
        guard !_hunkStartLines.isEmpty else { return [] }
        guard let sources = leftCodeRenderable?.lineInfo.lineSources, !sources.isEmpty else {
            return _hunkStartLines
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(_hunkStartLines.count)
        var visualRow = 0

        for hunkStartLine in _hunkStartLines {
            while visualRow < sources.count && sources[visualRow] < hunkStartLine {
                visualRow += 1
            }
            offsets.append(visualRow < sources.count ? visualRow : hunkStartLine)
        }
        return offsets
    }

    // MARK: - Events, Resize, Update & Cleanup

    open override func onMouseEvent(_ event: MouseEvent) {
        guard event.type == .scroll, _view == .split, _syncScroll else { return }
        guard let left = leftCodeRenderable, let right = rightCodeRenderable else { return }
        guard let target = event.target else { return }

        if isInsideSide(target, container: left) {
            right.scrollY = left.scrollY
            right.scrollX = left.scrollX
        } else if isInsideSide(target, container: right) {
            left.scrollY = right.scrollY
            left.scrollX = right.scrollX
        }
    }

    open override func onResize(width: Int, height: Int) {
        if _view == .split && (_wrapMode == .word || _wrapMode == .char) {
            _needsSplitWrapAlignment = true
        }
        invalidateHunkRowOffsets()
        super.onResize(width: width, height: height)
    }

    open override func onUpdate(deltaTime: Double) {
        super.onUpdate(deltaTime: deltaTime)

        guard !isDestroyed, _view == .split, (_wrapMode == .word || _wrapMode == .char) else {
            return
        }
        guard let left = leftCodeRenderable, let right = rightCodeRenderable else {
            return
        }
        let currentWidths = (left.width, right.width)
        guard currentWidths.0 > 0 && currentWidths.1 > 0 else { return }

        if _needsSplitWrapAlignment || currentWidths != _lastCodeWidths {
            _needsSplitWrapAlignment = false
            buildSplitView(withPaneWidths: currentWidths)
            relayoutPanesInPlace()
        }
    }

    open override func destroyRecursively() {
        guard !isDestroyed else { return }
        detachLineInfoListeners()
        leftSideAdded = false
        rightSideAdded = false
        super.destroyRecursively()
    }

    open override func destroySelf() {
        detachLineInfoListeners()
        let owned: [Renderable?] = [
            leftSide,
            rightSide,
            leftCodeRenderable,
            rightCodeRenderable,
            errorTextRenderable,
            errorCodeRenderable,
        ]
        for child in owned {
            if let child, !child.isDestroyed {
                child.destroyRecursively()
            }
        }
        leftSide = nil
        rightSide = nil
        leftCodeRenderable = nil
        rightCodeRenderable = nil
        errorTextRenderable = nil
        errorCodeRenderable = nil
        _fallbackSyntaxStyle?.destroy()
        _fallbackSyntaxStyle = nil
        super.destroySelf()
    }

    // MARK: - Parsing & View Construction

    private var codeSyntaxStyle: SyntaxStyle {
        if let explicit = _syntaxStyle {
            return explicit
        }
        if let fallback = _fallbackSyntaxStyle, !fallback.isDestroyed {
            return fallback
        }
        let created = SyntaxStyle.create()
        _fallbackSyntaxStyle = created
        return created
    }

    private func isInsideSide(_ target: Renderable?, container: CodeRenderable) -> Bool {
        var current = target
        while let node = current {
            if node === container { return true }
            current = node.parent
        }
        return false
    }

    private func invalidateHunkRowOffsets() {
        _hunkRowOffsets = nil
    }

    private func parseDiff() {
        guard !_diff.isEmpty else {
            _parsedDiff = nil
            _parseError = nil
            return
        }
        do {
            let parsed = try parseUnifiedDiff(_diff)
            _parsedDiff = parsed
            _parseError = nil
        } catch {
            _parsedDiff = nil
            _parseError = error
        }
    }

    private func buildView() {
        guard !isDestroyed else { return }
        _hunkStartLines = []
        invalidateHunkRowOffsets()

        if _parseError != nil {
            buildErrorView()
            return
        }

        guard let parsed = _parsedDiff, !parsed.hunks.isEmpty else {
            detachErrorViews()
            detachDiffPanes()
            requestRender()
            return
        }

        if _view == .unified {
            buildUnifiedView(parsed: parsed)
        } else {
            buildSplitView(withPaneWidths: nil)
        }
        requestRender()
    }

    private func detachErrorViews() {
        if let errText = errorTextRenderable, errText.parent === self {
            super.remove(errText)
        }
        if let errCode = errorCodeRenderable, errCode.parent === self {
            super.remove(errCode)
        }
    }

    private func detachDiffPanes() {
        if let left = leftSide, leftSideAdded {
            super.remove(left)
            leftSideAdded = false
        }
        if let right = rightSide, rightSideAdded {
            super.remove(right)
            rightSideAdded = false
        }
    }

    private func buildErrorView() {
        self.flexDirection = .column
        detachDiffPanes()

        let errorMessage = "Error parsing diff: \(_parseError?.description ?? "Unknown error")\n"
        if let existing = errorTextRenderable {
            existing.setContent(errorMessage)
            if existing.parent !== self {
                super.add(existing)
            }
        } else {
            let errText = TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    id: "\(id)-error-text",
                    content: .string(errorMessage),
                    width: .percent(100),
                    flexShrink: 0,
                    fg: "#ef4444"
                )
            )
            errorTextRenderable = errText
            super.add(errText)
        }

        if let existing = errorCodeRenderable {
            existing.content = _diff
            existing.wrapMode = _wrapMode ?? .none
            existing.syntaxStyle = codeSyntaxStyle
            if existing.parent !== self {
                super.add(existing)
            }
        } else {
            let errCode = CodeRenderable(
                ctx: ctx,
                options: CodeOptions(
                    id: "\(id)-error-code",
                    content: _diff,
                    filetype: "diff",
                    syntaxStyle: codeSyntaxStyle,
                    highlighter: _highlighter,
                    conceal: _conceal,
                    width: .percent(100),
                    flexGrow: 1,
                    flexShrink: 1,
                    wrapMode: _wrapMode ?? TextWrapMode.none
                )
            )
            errorCodeRenderable = errCode
            super.add(errCode)
        }
    }

    private func buildUnifiedView(parsed: ParsedDiff) {
        self.flexDirection = .column
        detachErrorViews()

        let (unifiedLines, hunkOffsets) = buildUnifiedDiffLines(parsed)
        _hunkStartLines = hunkOffsets

        // Compute intra-line word diff ranges across paired contiguous removed/added blocks.
        var wordHighlightsPerLine: [[Range<Int>]] = Array(repeating: [], count: unifiedLines.count)
        if _showWordDiff {
            var idx = 0
            while idx < unifiedLines.count {
                if unifiedLines[idx].kind == .context || unifiedLines[idx].kind == .empty {
                    idx += 1
                    continue
                }
                var removedIndices: [Int] = []
                var addedIndices: [Int] = []
                while idx < unifiedLines.count && (unifiedLines[idx].kind == .removed || unifiedLines[idx].kind == .added) {
                    if unifiedLines[idx].kind == .removed {
                        removedIndices.append(idx)
                    } else {
                        addedIndices.append(idx)
                    }
                    idx += 1
                }
                let pairCount = min(removedIndices.count, addedIndices.count)
                for p in 0..<pairCount {
                    let rIdx = removedIndices[p]
                    let aIdx = addedIndices[p]
                    let (oldRanges, newRanges) = computeWordDiffRanges(
                        oldLine: unifiedLines[rIdx].content,
                        newLine: unifiedLines[aIdx].content
                    )
                    wordHighlightsPerLine[rIdx] = oldRanges
                    wordHighlightsPerLine[aIdx] = newRanges
                }
            }
        }

        var contentLines: [String] = []
        contentLines.reserveCapacity(unifiedLines.count)
        var lineColors: [Int: LineColorValue] = [:]
        var lineSigns: [Int: LineSign] = [:]
        var lineNumbers: [Int: Int] = [:]
        var hideLineNumbers: Set<Int> = []
        var documentWordSpans: [WordHighlightSpan] = []

        let resolvedAddedWordBg = _addedWordBg ?? DiffDefaultColors.wordAccent(from: _addedContentBg ?? _addedBg)
        let resolvedRemovedWordBg = _removedWordBg ?? DiffDefaultColors.wordAccent(from: _removedContentBg ?? _removedBg)

        var utf16Cursor = 0
        for (lineIndex, line) in unifiedLines.enumerated() {
            contentLines.append(line.content)
            let lineUTF16Len = line.content.utf16.count

            switch line.kind {
            case .added:
                lineColors[lineIndex] = .config(LineColorConfig(
                    gutter: .rgba(_addedLineNumberBg),
                    content: .rgba(_addedContentBg ?? _addedBg)
                ))
                lineSigns[lineIndex] = LineSign(after: " +", afterColor: .rgba(_addedSignColor))
                if let n = line.newLineNumber { lineNumbers[lineIndex] = n }
                for range in wordHighlightsPerLine[lineIndex] {
                    documentWordSpans.append(WordHighlightSpan(
                        start: utf16Cursor + range.lowerBound,
                        end: utf16Cursor + range.upperBound,
                        bg: resolvedAddedWordBg
                    ))
                }

            case .removed:
                lineColors[lineIndex] = .config(LineColorConfig(
                    gutter: .rgba(_removedLineNumberBg),
                    content: .rgba(_removedContentBg ?? _removedBg)
                ))
                lineSigns[lineIndex] = LineSign(after: " -", afterColor: .rgba(_removedSignColor))
                if let n = line.oldLineNumber { lineNumbers[lineIndex] = n }
                for range in wordHighlightsPerLine[lineIndex] {
                    documentWordSpans.append(WordHighlightSpan(
                        start: utf16Cursor + range.lowerBound,
                        end: utf16Cursor + range.upperBound,
                        bg: resolvedRemovedWordBg
                    ))
                }

            case .context:
                lineColors[lineIndex] = .config(LineColorConfig(
                    gutter: .rgba(_lineNumberBg),
                    content: .rgba(_contextContentBg ?? _contextBg)
                ))
                if let n = line.newLineNumber ?? line.oldLineNumber { lineNumbers[lineIndex] = n }

            case .empty:
                hideLineNumbers.insert(lineIndex)
                if _emptyBg.a > 0 {
                    lineColors[lineIndex] = .config(LineColorConfig(
                        gutter: .rgba(_lineNumberBg),
                        content: .rgba(_emptyBg)
                    ))
                }
            }

            utf16Cursor += lineUTF16Len + 1 // +1 for "\n"
        }

        let content = contentLines.joined(separator: "\n")
        let wordOverlay = makeWordOverlayCallback(spans: documentWordSpans)
        let codeRenderable = createOrUpdateCodeRenderable(
            side: .left,
            content: content,
            wrapMode: _wrapMode,
            onChunks: wordOverlay
        )
        attachLineInfoListeners()

        createOrUpdateSide(
            side: .left,
            target: codeRenderable,
            lineColors: lineColors,
            lineSigns: lineSigns,
            lineNumbers: lineNumbers,
            hideLineNumbers: hideLineNumbers,
            width: .percent(100)
        )

        if let right = rightSide, rightSideAdded {
            super.remove(right)
            rightSideAdded = false
        }
    }

    private func buildSplitView(withPaneWidths paneWidths: (Int, Int)?) {
        guard let parsed = _parsedDiff else { return }
        self.flexDirection = .row
        detachErrorViews()

        let (rawLeft, rawRight, hunkOffsets) = buildSplitDiffLines(parsed)
        let hunkOffsetSet = Set(hunkOffsets)

        var leftLogical: [DiffLogicalLine] = []
        var rightLogical: [DiffLogicalLine] = []
        leftLogical.reserveCapacity(rawLeft.count)
        rightLogical.reserveCapacity(rawRight.count)

        for idx in 0..<rawLeft.count {
            let l = rawLeft[idx]
            let r = rawRight[idx]
            let isHunkStart = hunkOffsetSet.contains(idx)

            let (oldWordRanges, newWordRanges): ([Range<Int>], [Range<Int>])
            if _showWordDiff && l.kind == .removed && r.kind == .added {
                (oldWordRanges, newWordRanges) = computeWordDiffRanges(oldLine: l.content, newLine: r.content)
            } else {
                (oldWordRanges, newWordRanges) = ([], [])
            }

            leftLogical.append(
                DiffLogicalLine(
                    content: l.content,
                    lineNum: l.oldLineNumber,
                    hideLineNumber: l.kind == .empty,
                    kind: l.kind,
                    sign: l.kind == .removed ? LineSign(after: " -", afterColor: .rgba(_removedSignColor)) : nil,
                    hunkStart: isHunkStart,
                    wordHighlights: oldWordRanges
                )
            )
            rightLogical.append(
                DiffLogicalLine(
                    content: r.content,
                    lineNum: r.newLineNumber,
                    hideLineNumber: r.kind == .empty,
                    kind: r.kind,
                    sign: r.kind == .added ? LineSign(after: " +", afterColor: .rgba(_addedSignColor)) : nil,
                    hunkStart: isHunkStart,
                    wordHighlights: newWordRanges
                )
            )
        }

        let effectiveWrapMode = _wrapMode
        let isWrapping = effectiveWrapMode == .word || effectiveWrapMode == .char
        let preLeftContent = leftLogical.map(\.content).joined(separator: "\n")
        let preRightContent = rightLogical.map(\.content).joined(separator: "\n")

        let leftCode = createOrUpdateCodeRenderable(
            side: .left,
            content: preLeftContent,
            wrapMode: effectiveWrapMode,
            onChunks: nil
        )
        let rightCode = createOrUpdateCodeRenderable(
            side: .right,
            content: preRightContent,
            wrapMode: effectiveWrapMode,
            onChunks: nil
        )
        attachLineInfoListeners()

        let resolvedLeftWidth = paneWidths?.0 ?? leftCode.width
        let resolvedRightWidth = paneWidths?.1 ?? rightCode.width
        let canDoWrapAlignment = isWrapping && resolvedLeftWidth > 0 && resolvedRightWidth > 0

        let finalLeft: [DiffLogicalLine]
        let finalRight: [DiffLogicalLine]

        if canDoWrapAlignment {
            _lastCodeWidths = (resolvedLeftWidth, resolvedRightWidth)
            leftCode.highlightNow()
            rightCode.highlightNow()
            leftCode.textBufferView.setWrapWidth(resolvedLeftWidth)
            rightCode.textBufferView.setWrapWidth(resolvedRightWidth)

            let leftSources = leftCode.lineInfo.lineSources
            let rightSources = rightCode.lineInfo.lineSources

            var leftVisualCounts: [Int: Int] = [:]
            var rightVisualCounts: [Int: Int] = [:]
            for s in leftSources { leftVisualCounts[s, default: 0] += 1 }
            for s in rightSources { rightVisualCounts[s, default: 0] += 1 }

            var alignedLeft: [DiffLogicalLine] = []
            var alignedRight: [DiffLogicalLine] = []
            var leftVisualPos = 0
            var rightVisualPos = 0

            let padLine = DiffLogicalLine(
                content: "",
                lineNum: nil,
                hideLineNumber: true,
                kind: .empty,
                sign: nil,
                hunkStart: false,
                wordHighlights: []
            )

            for i in 0..<leftLogical.count {
                let lCount = leftVisualCounts[i] ?? 0
                let rCount = rightVisualCounts[i] ?? 0

                if leftVisualPos < rightVisualPos {
                    let pad = rightVisualPos - leftVisualPos
                    for _ in 0..<pad { alignedLeft.append(padLine) }
                    leftVisualPos += pad
                } else if rightVisualPos < leftVisualPos {
                    let pad = leftVisualPos - rightVisualPos
                    for _ in 0..<pad { alignedRight.append(padLine) }
                    rightVisualPos += pad
                }

                alignedLeft.append(leftLogical[i])
                alignedRight.append(rightLogical[i])

                leftVisualPos += lCount
                rightVisualPos += rCount
            }

            if leftVisualPos < rightVisualPos {
                for _ in 0..<(rightVisualPos - leftVisualPos) { alignedLeft.append(padLine) }
            } else if rightVisualPos < leftVisualPos {
                for _ in 0..<(leftVisualPos - rightVisualPos) { alignedRight.append(padLine) }
            }

            finalLeft = alignedLeft
            finalRight = alignedRight
        } else {
            if isWrapping {
                _needsSplitWrapAlignment = true
            }
            finalLeft = leftLogical
            finalRight = rightLogical
        }

        _hunkStartLines = []
        let resolvedAddedWordBg = _addedWordBg ?? DiffDefaultColors.wordAccent(from: _addedContentBg ?? _addedBg)
        let resolvedRemovedWordBg = _removedWordBg ?? DiffDefaultColors.wordAccent(from: _removedContentBg ?? _removedBg)

        var leftLineColors: [Int: LineColorValue] = [:]
        var leftLineSigns: [Int: LineSign] = [:]
        var leftLineNumbers: [Int: Int] = [:]
        var leftHideLineNumbers: Set<Int> = []
        var leftWordSpans: [WordHighlightSpan] = []

        var leftUTF16Cursor = 0
        for (index, line) in finalLeft.enumerated() {
            if line.hunkStart {
                _hunkStartLines.append(index)
            }
            if let num = line.lineNum {
                leftLineNumbers[index] = num
            }
            if line.hideLineNumber {
                leftHideLineNumbers.insert(index)
            }
            switch line.kind {
            case .removed:
                leftLineColors[index] = .config(LineColorConfig(
                    gutter: .rgba(_removedLineNumberBg),
                    content: .rgba(_removedContentBg ?? _removedBg)
                ))
                for range in line.wordHighlights {
                    leftWordSpans.append(WordHighlightSpan(
                        start: leftUTF16Cursor + range.lowerBound,
                        end: leftUTF16Cursor + range.upperBound,
                        bg: resolvedRemovedWordBg
                    ))
                }
            case .context:
                leftLineColors[index] = .config(LineColorConfig(
                    gutter: .rgba(_lineNumberBg),
                    content: .rgba(_contextContentBg ?? _contextBg)
                ))
            case .empty:
                if _emptyBg.a > 0 {
                    leftLineColors[index] = .config(LineColorConfig(
                        gutter: .rgba(_lineNumberBg),
                        content: .rgba(_emptyBg)
                    ))
                }
            case .added:
                break
            }
            if let sign = line.sign {
                leftLineSigns[index] = sign
            }
            leftUTF16Cursor += line.content.utf16.count + 1
        }

        var rightLineColors: [Int: LineColorValue] = [:]
        var rightLineSigns: [Int: LineSign] = [:]
        var rightLineNumbers: [Int: Int] = [:]
        var rightHideLineNumbers: Set<Int> = []
        var rightWordSpans: [WordHighlightSpan] = []

        var rightUTF16Cursor = 0
        for (index, line) in finalRight.enumerated() {
            if let num = line.lineNum {
                rightLineNumbers[index] = num
            }
            if line.hideLineNumber {
                rightHideLineNumbers.insert(index)
            }
            switch line.kind {
            case .added:
                rightLineColors[index] = .config(LineColorConfig(
                    gutter: .rgba(_addedLineNumberBg),
                    content: .rgba(_addedContentBg ?? _addedBg)
                ))
                for range in line.wordHighlights {
                    rightWordSpans.append(WordHighlightSpan(
                        start: rightUTF16Cursor + range.lowerBound,
                        end: rightUTF16Cursor + range.upperBound,
                        bg: resolvedAddedWordBg
                    ))
                }
            case .context:
                rightLineColors[index] = .config(LineColorConfig(
                    gutter: .rgba(_lineNumberBg),
                    content: .rgba(_contextContentBg ?? _contextBg)
                ))
            case .empty:
                if _emptyBg.a > 0 {
                    rightLineColors[index] = .config(LineColorConfig(
                        gutter: .rgba(_lineNumberBg),
                        content: .rgba(_emptyBg)
                    ))
                }
            case .removed:
                break
            }
            if let sign = line.sign {
                rightLineSigns[index] = sign
            }
            rightUTF16Cursor += line.content.utf16.count + 1
        }

        leftCode.onChunks = makeWordOverlayCallback(spans: leftWordSpans)
        rightCode.onChunks = makeWordOverlayCallback(spans: rightWordSpans)
        leftCode.content = finalLeft.map(\.content).joined(separator: "\n")
        rightCode.content = finalRight.map(\.content).joined(separator: "\n")

        createOrUpdateSide(
            side: .left,
            target: leftCode,
            lineColors: leftLineColors,
            lineSigns: leftLineSigns,
            lineNumbers: leftLineNumbers,
            hideLineNumbers: leftHideLineNumbers,
            width: .percent(50)
        )
        createOrUpdateSide(
            side: .right,
            target: rightCode,
            lineColors: rightLineColors,
            lineSigns: rightLineSigns,
            lineNumbers: rightLineNumbers,
            hideLineNumbers: rightHideLineNumbers,
            width: .percent(50)
        )
    }

    private func makeWordOverlayCallback(spans: [WordHighlightSpan]) -> OnChunksCallback? {
        guard !spans.isEmpty else { return nil }
        return { chunks, _ in
            applyWordHighlightSpans(chunks: chunks, spans: spans)
        }
    }

    private func relayoutPanesInPlace() {
        guard width > 0 && height > 0 else { return }
        layoutNode.calculateLayout(availableWidth: Float(width), availableHeight: Float(height))
        for child in getChildren() {
            child.updateFromLayout()
        }
    }

    // MARK: - Pane Creation & Updating

    private enum DiffPaneSide: String {
        case left
        case right
    }

    private func createOrUpdateCodeRenderable(
        side: DiffPaneSide,
        content: String,
        wrapMode: TextWrapMode?,
        onChunks: OnChunksCallback?
    ) -> CodeRenderable {
        let existing = (side == .left) ? leftCodeRenderable : rightCodeRenderable
        let resolvedWrapMode = wrapMode ?? .none

        if let existing, !existing.isDestroyed {
            existing.onChunks = onChunks
            existing.wrapMode = resolvedWrapMode
            existing.conceal = _conceal
            existing.filetype = _filetype
            existing.syntaxStyle = codeSyntaxStyle
            if let selBg = _selectionBg { existing.selectionBg = selBg }
            if let selFg = _selectionFg { existing.selectionFg = selFg }
            if let fg = _fg { existing.fg = fg }
            existing.content = content
            return existing
        }

        let created = CodeRenderable(
            ctx: ctx,
            options: CodeOptions(
                id: "\(id)-\(side.rawValue)-code",
                content: content,
                filetype: _filetype,
                syntaxStyle: codeSyntaxStyle,
                highlighter: _highlighter,
                conceal: _conceal,
                onChunks: onChunks,
                width: .auto,
                height: .auto,
                minWidth: .point(0),
                flexGrow: 1,
                flexShrink: 1,
                fg: _fg.map { .rgba($0) },
                selectionBg: _selectionBg.map { .rgba($0) },
                selectionFg: _selectionFg.map { .rgba($0) },
                wrapMode: resolvedWrapMode
            )
        )
        if side == .left {
            leftCodeRenderable = created
        } else {
            rightCodeRenderable = created
        }
        return created
    }

    private func gutterLayout() -> GutterLayout {
        GutterLayout(
            minWidth: 0,
            paddingLeft: _gutter.paddingLeft,
            paddingRight: _gutter.paddingRight,
            minDigits: _gutter.minDigits ?? 0,
            minAfterWidth: _gutter.minDigits == nil ? 0 : diffSignWidth
        )
    }

    private func createOrUpdateSide(
        side: DiffPaneSide,
        target: CodeRenderable,
        lineColors: [Int: LineColorValue],
        lineSigns: [Int: LineSign],
        lineNumbers: [Int: Int],
        hideLineNumbers: Set<Int>,
        width: FlexValue
    ) {
        let existing = (side == .left) ? leftSide : rightSide
        let isAdded = (side == .left) ? leftSideAdded : rightSideAdded

        if let existing, !existing.isDestroyed {
            existing.setWidth(width)
            existing.fg = _lineNumberFg
            existing.bg = _lineNumberBg
            existing.showLineNumbers = _showLineNumbers
            existing.setGutterLayout(gutterLayout())
            existing.setLineColors(lineColors)

            var mergedSigns = lineSigns
            if let paddingSign = existing.getLineSigns()[-1] {
                mergedSigns[-1] = paddingSign
            }
            existing.setLineSigns(mergedSigns)
            existing.setLineNumbers(lineNumbers)
            existing.setHideLineNumbers(hideLineNumbers)

            if !isAdded {
                super.add(existing)
                if side == .left {
                    leftSideAdded = true
                } else {
                    rightSideAdded = true
                }
            }
        } else {
            let newSide = LineNumberRenderable(
                ctx: ctx,
                options: LineNumberOptions(
                    id: "\(id)-\(side.rawValue)",
                    target: target,
                    width: width,
                    height: .percent(100),
                    minWidth: 0,
                    paddingRight: _gutter.paddingRight,
                    fg: .rgba(_lineNumberFg),
                    bg: .rgba(_lineNumberBg),
                    lineColors: lineColors,
                    lineSigns: lineSigns,
                    lineNumberOffset: 0,
                    hideLineNumbers: hideLineNumbers,
                    lineNumbers: lineNumbers,
                    showLineNumbers: _showLineNumbers
                )
            )
            newSide.setGutterLayout(gutterLayout())
            super.add(newSide)

            if side == .left {
                leftSide = newSide
                leftSideAdded = true
            } else {
                rightSide = newSide
                rightSideAdded = true
            }
        }
    }

    private func attachLineInfoListeners() {
        detachLineInfoListeners()
        if let left = leftCodeRenderable {
            _leftLineInfoToken = left.on("line-info-change") { [weak self] in
                self?.invalidateHunkRowOffsets()
            }
        }
        if let right = rightCodeRenderable {
            _rightLineInfoToken = right.on("line-info-change") { [weak self] in
                self?.invalidateHunkRowOffsets()
            }
        }
    }

    private func detachLineInfoListeners() {
        if let token = _leftLineInfoToken, let left = leftCodeRenderable {
            left.off(token)
        }
        _leftLineInfoToken = nil
        if let token = _rightLineInfoToken, let right = rightCodeRenderable {
            right.off(token)
        }
        _rightLineInfoToken = nil
    }
}
