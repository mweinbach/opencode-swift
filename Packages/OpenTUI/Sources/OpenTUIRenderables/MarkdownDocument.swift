import OpenTUICore
import OpenTUILayout

// MARK: - Markdown Block Kind & Incremental Block State

/// Kind of block in a rendered Markdown document, matching `core/src/renderables/Markdown.ts#MarkdownBlockKind`.
// parity: core/src/renderables/Markdown.ts#MarkdownBlockKind [status=implemented hash=387074e8c778]
public enum MarkdownBlockKind: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case paragraph
    case heading
    case code
    case html
    case rule
    case table
    case row
    case cell
    case quote
    case list
    case item
}

public extension MarkdownBlock {
    /// Returns the coarse `MarkdownBlockKind` corresponding to this parsed AST block.
    var blockKind: MarkdownBlockKind {
        switch self {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .codeBlock: return .code
        case .htmlBlock: return .html
        case .thematicBreak: return .rule
        case .blockquote: return .quote
        case .list: return .list
        case .table: return .table
        }
    }
}

/// Tracked state for a single top-level block inside an incremental streaming Markdown document.
public struct MarkdownBlockState: Equatable, Hashable, Sendable {
    /// 0-based index of this top-level block within the document.
    public var index: Int
    /// Coarse block kind.
    public var kind: MarkdownBlockKind
    /// Parsed AST node for this block.
    public var block: MarkdownBlock
    /// Best-effort raw Markdown source slice corresponding to this block.
    public var raw: String
    /// UTF-8 byte range in the document source covering this block.
    public var sourceRange: Range<Int>
    /// Whether this block is structurally finalized (part of the stable committed prefix).
    public var isCommitted: Bool
    /// For fenced code / math blocks, whether the closing delimiter has arrived (always `true` for non-fenced blocks).
    public var isClosed: Bool
    /// Monotonically increasing revision incremented whenever this block's AST or closure state changes.
    public var revision: Int

    public init(
        index: Int,
        kind: MarkdownBlockKind,
        block: MarkdownBlock,
        raw: String,
        sourceRange: Range<Int>,
        isCommitted: Bool,
        isClosed: Bool,
        revision: Int
    ) {
        self.index = index
        self.kind = kind
        self.block = block
        self.raw = raw
        self.sourceRange = sourceRange
        self.isCommitted = isCommitted
        self.isClosed = isClosed
        self.revision = revision
    }
}

/// Incremental diff report returned by `StreamingMarkdownDocument.write(_:streaming:)` and `setOptions(_:)`.
/// Blocks at `removedFrom` and after were removed; `changed` lists blocks that were added or modified.
// parity: core/src/renderables/markdown-document.ts#MarkdownChanges [status=implemented hash=6acf7a6cbf03]
public struct MarkdownChanges: Equatable, Hashable, Sendable {
    public var removedFrom: Int?
    public var changed: [MarkdownBlockState]
    /// Number of leading blocks whose AST and state were completely unchanged and can be reused directly.
    public var unchangedPrefixCount: Int

    public init(
        removedFrom: Int? = nil,
        changed: [MarkdownBlockState] = [],
        unchangedPrefixCount: Int = 0
    ) {
        self.removedFrom = removedFrom
        self.changed = changed
        self.unchangedPrefixCount = unchangedPrefixCount
    }

    public var isEmpty: Bool {
        removedFrom == nil && changed.isEmpty
    }

    public static let unchanged = MarkdownChanges(removedFrom: nil, changed: [], unchangedPrefixCount: 0)
}

// MARK: - StreamingMarkdownDocument

/// Incremental streaming Markdown document tracker layered over `parseMarkdown` (`MarkdownParser.swift`).
///
/// Tracks an unchanged committed prefix of top-level `MarkdownBlockState` entries vs. trailing
/// unstable or modified blocks so streaming LLM Markdown updates only rebuild changed blocks.
///
/// Note: `MarkdownParser.swift` already defines the immutable `MarkdownDocument` AST snapshot struct
/// (`parseMarkdown` return type); `StreamingMarkdownDocument` implements the stateful incremental
/// write/diff engine from `core/src/renderables/markdown-document.ts`.
public final class StreamingMarkdownDocument: @unchecked Sendable {
    public private(set) var blocks: [MarkdownBlockState] = []
    public private(set) var parsedDocument: MarkdownDocument
    public private(set) var options: MarkdownParseOptions

    private var _content: String = ""
    private var _committed: Int = 0
    private var _finished: Bool = false
    private var _isDestroyed: Bool = false
    private var _boundNodes: [Int: WeakBoundNode] = [:]

    private struct WeakBoundNode {
        weak var node: Renderable?
    }

    public init(options: MarkdownParseOptions = MarkdownParseOptions()) {
        self.options = options
        self.parsedDocument = MarkdownDocument(source: "", options: options, blocks: [], definitions: [:])
    }

    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.content [status=implemented hash=ebe008abea36]
    public var content: String {
        _content
    }

    /// Number of leading top-level blocks that are structurally final.
    /// Never decreases while streaming content only grows by appending.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.committed [status=implemented hash=5132d4301b77]
    public var committed: Int {
        _committed
    }

    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.finished [status=implemented hash=51d0a73b2098]
    public var finished: Bool {
        _finished
    }

    public var isDestroyed: Bool {
        _isDestroyed
    }

    /// Updates the document with `content`. When `streaming == true`, trailing blocks remain mutable
    /// and unchanged prefix blocks are preserved so renderers only rebuild changed blocks.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.write [status=implemented hash=dc7f699898c3]
    @discardableResult
    public func write(_ content: String, streaming: Bool = false) -> MarkdownChanges {
        guard !_isDestroyed else { return .unchanged }
        if content == _content && _finished == !streaming {
            return MarkdownChanges(removedFrom: nil, changed: [], unchangedPrefixCount: blocks.count)
        }

        let isAppend = !_finished && !_content.isEmpty && content.hasPrefix(_content)
        _content = content
        _finished = !streaming

        return reconcile(isAppend: isAppend, streaming: streaming)
    }

    /// Ergonomic alias for `write(_:streaming:)`.
    @discardableResult
    public func update(_ content: String, streaming: Bool = false) -> MarkdownChanges {
        write(content, streaming: streaming)
    }

    /// Updates parse options (such as GFM or math extensions) and recomputes incremental block diffs.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.setOptions [status=implemented hash=3ad86ee85141]
    @discardableResult
    public func setOptions(_ options: MarkdownParseOptions) -> MarkdownChanges {
        guard !_isDestroyed else { return .unchanged }
        guard self.options != options else {
            return MarkdownChanges(removedFrom: nil, changed: [], unchangedPrefixCount: blocks.count)
        }
        self.options = options
        return reconcile(isAppend: false, streaming: !_finished)
    }

    /// Returns the parsed `MarkdownBlock` at `index`, if within bounds.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.readLeaf [status=adapted hash=3c040548605c]
    public func readLeaf(_ index: Int) -> MarkdownBlock? {
        guard !_isDestroyed && index >= 0 && index < blocks.count else { return nil }
        return blocks[index].block
    }

    /// Returns the raw Markdown source slice for block `index`.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.readSource [status=implemented hash=6e1ee187af13]
    public func readSource(_ index: Int) -> String {
        guard !_isDestroyed && index >= 0 && index < blocks.count else { return "" }
        return blocks[index].raw
    }

    /// Returns the document's source string, or the UTF-8 byte slice `[start..<end]`.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.source [status=implemented hash=63a8aafabf4a]
    public func source(start: Int? = nil, end: Int? = nil) -> String {
        guard !_isDestroyed else { return "" }
        if start == nil && end == nil {
            return _content
        }
        let bytes = Array(_content.utf8)
        let lo = max(0, min(start ?? 0, bytes.count))
        let hi = max(lo, min(end ?? bytes.count, bytes.count))
        if lo == hi { return "" }
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    /// Associates a mounted `Renderable` with top-level block `index`.
    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.bind [status=adapted hash=5458bc0e2cb8]
    public func bind(_ index: Int, node: Renderable) {
        guard !_isDestroyed else { return }
        _boundNodes[index] = WeakBoundNode(node: node)
    }

    /// Returns the bound `Renderable` for block `index`, if still alive.
    public func boundNode(at index: Int) -> Renderable? {
        _boundNodes[index]?.node
    }

    // parity: core/src/renderables/markdown-document.ts#MarkdownDocument.destroy [status=implemented hash=599e7e43150d]
    public func destroy() {
        guard !_isDestroyed else { return }
        _isDestroyed = true
        blocks.removeAll()
        _boundNodes.removeAll()
        _content = ""
        _committed = 0
        _finished = true
    }

    // MARK: - Incremental Reconciliation

    private func reconcile(isAppend: Bool, streaming: Bool) -> MarkdownChanges {
        let parsed = parseMarkdown(_content, options: options)
        self.parsedDocument = parsed

        let newBlocks = parsed.blocks
        let oldStates = self.blocks
        let scanInfo = scanTopLevelSourceSegments(_content, blockCount: newBlocks.count, enableMath: options.enableMath)

        // Compute longest identical prefix by AST equality and fence closure state.
        var unchangedPrefix = 0
        let sharedCount = min(oldStates.count, newBlocks.count)
        while unchangedPrefix < sharedCount {
            let oldState = oldStates[unchangedPrefix]
            let newBlock = newBlocks[unchangedPrefix]
            let newClosed = computeIsClosed(
                block: newBlock,
                isLast: unchangedPrefix == newBlocks.count - 1,
                streaming: streaming,
                hasUnclosedFence: scanInfo.hasUnclosedTrailingFence
            )
            if oldState.block == newBlock && oldState.isClosed == newClosed {
                unchangedPrefix += 1
            } else {
                break
            }
        }

        // Compute committed prefix count.
        let nextCommitted: Int
        if !streaming {
            nextCommitted = newBlocks.count
        } else if newBlocks.isEmpty {
            nextCommitted = 0
        } else if scanInfo.endsWithBlankLine && !scanInfo.hasUnclosedTrailingFence {
            nextCommitted = newBlocks.count
        } else {
            let structuralCommitted = max(0, newBlocks.count - 1)
            nextCommitted = isAppend ? max(_committed, structuralCommitted) : structuralCommitted
        }
        _committed = min(nextCommitted, newBlocks.count)

        // Assemble updated block states and collect only added/modified blocks.
        var updatedStates: [MarkdownBlockState] = []
        updatedStates.reserveCapacity(newBlocks.count)
        var changedStates: [MarkdownBlockState] = []

        for idx in 0..<newBlocks.count {
            let block = newBlocks[idx]
            let isCommitted = idx < _committed
            let isClosed = computeIsClosed(
                block: block,
                isLast: idx == newBlocks.count - 1,
                streaming: streaming,
                hasUnclosedFence: scanInfo.hasUnclosedTrailingFence
            )
            let range = idx < scanInfo.ranges.count ? scanInfo.ranges[idx] : (0..<0)
            let rawSlice = idx < scanInfo.raws.count ? scanInfo.raws[idx] : ""

            if idx < unchangedPrefix {
                var kept = oldStates[idx]
                kept.isCommitted = isCommitted
                if kept.raw.isEmpty && !rawSlice.isEmpty {
                    kept.raw = rawSlice
                    kept.sourceRange = range
                }
                updatedStates.append(kept)
            } else {
                let prevRevision = idx < oldStates.count ? oldStates[idx].revision : 0
                let state = MarkdownBlockState(
                    index: idx,
                    kind: block.blockKind,
                    block: block,
                    raw: rawSlice,
                    sourceRange: range,
                    isCommitted: isCommitted,
                    isClosed: isClosed,
                    revision: prevRevision + 1
                )
                updatedStates.append(state)
                changedStates.append(state)
            }
        }

        let removedFrom: Int? = newBlocks.count < oldStates.count ? newBlocks.count : nil
        if let from = removedFrom {
            for key in _boundNodes.keys where key >= from {
                _boundNodes.removeValue(forKey: key)
            }
        }

        self.blocks = updatedStates
        return MarkdownChanges(
            removedFrom: removedFrom,
            changed: changedStates,
            unchangedPrefixCount: unchangedPrefix
        )
    }

    private func computeIsClosed(
        block: MarkdownBlock,
        isLast: Bool,
        streaming: Bool,
        hasUnclosedFence: Bool
    ) -> Bool {
        guard case .codeBlock(_, _, let fenced, let isMath) = block else {
            return true
        }
        if !fenced && !isMath {
            return true
        }
        if !streaming {
            return true
        }
        if isLast && hasUnclosedFence {
            return false
        }
        return true
    }
}

// MARK: - MarkdownDocument Extensions

public extension MarkdownDocument {
    /// Creates a new stateful incremental `StreamingMarkdownDocument` for streaming updates.
    static func streaming(options: MarkdownParseOptions = MarkdownParseOptions()) -> StreamingMarkdownDocument {
        StreamingMarkdownDocument(options: options)
    }

    /// Computes a `MarkdownChanges` diff between a previous `MarkdownDocument` snapshot and `self`.
    func diff(from previous: MarkdownDocument) -> MarkdownChanges {
        let shared = min(previous.blocks.count, blocks.count)
        var unchanged = 0
        while unchanged < shared && previous.blocks[unchanged] == blocks[unchanged] {
            unchanged += 1
        }
        let scan = scanTopLevelSourceSegments(source, blockCount: blocks.count, enableMath: options.enableMath)
        var changed: [MarkdownBlockState] = []
        for idx in unchanged..<blocks.count {
            let block = blocks[idx]
            let range = idx < scan.ranges.count ? scan.ranges[idx] : (0..<0)
            let raw = idx < scan.raws.count ? scan.raws[idx] : ""
            changed.append(
                MarkdownBlockState(
                    index: idx,
                    kind: block.blockKind,
                    block: block,
                    raw: raw,
                    sourceRange: range,
                    isCommitted: true,
                    isClosed: true,
                    revision: 1
                )
            )
        }
        let removedFrom = blocks.count < previous.blocks.count ? blocks.count : nil
        return MarkdownChanges(
            removedFrom: removedFrom,
            changed: changed,
            unchangedPrefixCount: unchanged
        )
    }
}

// MARK: - Pure-Swift Top-Level Source & Fence Scanner

private struct SourceScanInfo {
    let ranges: [Range<Int>]
    let raws: [String]
    let hasUnclosedTrailingFence: Bool
    let endsWithBlankLine: Bool
}

private func scanTopLevelSourceSegments(_ source: String, blockCount: Int, enableMath: Bool) -> SourceScanInfo {
    guard !source.isEmpty else {
        return SourceScanInfo(ranges: [], raws: [], hasUnclosedTrailingFence: false, endsWithBlankLine: false)
    }

    let bytes = Array(source.utf8)
    let n = bytes.count

    // Check trailing blank line (`\n\n` or `\r\n\r\n` with optional spaces/tabs on final blank line)
    var endsWithBlankLine = false
    if n >= 2 {
        var idx = n - 1
        var newlineCount = 0
        while idx >= 0 {
            let b = bytes[idx]
            if b == 0x0A {
                newlineCount += 1
                idx -= 1
                if idx >= 0 && bytes[idx] == 0x0D { idx -= 1 }
                if newlineCount >= 2 {
                    endsWithBlankLine = true
                    break
                }
            } else if b == 0x20 || b == 0x09 || b == 0x0D {
                idx -= 1
            } else {
                break
            }
        }
    }

    // Track fenced code blocks & split coarse top-level segments at blank lines outside fences.
    var inFence = false
    var fenceChar: UInt8 = 0
    var fenceLen = 0
    var inMathBlock = false
    var mathChar: UInt8 = 0

    var segments: [Range<Int>] = []
    var currentStart: Int? = nil
    var currentEnd: Int = 0

    var lineStart = 0
    while lineStart < n {
        var lineEnd = lineStart
        while lineEnd < n && bytes[lineEnd] != 0x0A {
            lineEnd += 1
        }
        let nextLineStart = lineEnd < n ? lineEnd + 1 : n
        var contentEnd = lineEnd
        if contentEnd > lineStart && bytes[contentEnd - 1] == 0x0D {
            contentEnd -= 1
        }

        // Count leading indentation (spaces only for quick top-level check)
        var nonBlank = lineStart
        var indent = 0
        while nonBlank < contentEnd && (bytes[nonBlank] == 0x20 || bytes[nonBlank] == 0x09) {
            indent += (bytes[nonBlank] == 0x09) ? 4 : 1
            nonBlank += 1
        }
        let isBlank = nonBlank >= contentEnd

        if inMathBlock {
            currentEnd = nextLineStart
            if indent <= 3 && !isBlank {
                var trimmedEnd = contentEnd
                while trimmedEnd > nonBlank && (bytes[trimmedEnd - 1] == 0x20 || bytes[trimmedEnd - 1] == 0x09) {
                    trimmedEnd -= 1
                }
                if trimmedEnd - nonBlank == 2 {
                    let closesDollar = mathChar == 0x24 && bytes[nonBlank] == 0x24 && bytes[nonBlank + 1] == 0x24
                    let closesBracket = mathChar == 0x5C && bytes[nonBlank] == 0x5C && bytes[nonBlank + 1] == 0x5D
                    if closesDollar || closesBracket {
                        inMathBlock = false
                    }
                }
            }
        } else if inFence {
            currentEnd = nextLineStart
            if indent <= 3 && !isBlank && bytes[nonBlank] == fenceChar {
                var run = nonBlank
                while run < contentEnd && bytes[run] == fenceChar { run += 1 }
                if run - nonBlank >= fenceLen {
                    var rest = run
                    while rest < contentEnd && (bytes[rest] == 0x20 || bytes[rest] == 0x09) { rest += 1 }
                    if rest == contentEnd {
                        inFence = false
                    }
                }
            }
        } else if isBlank {
            if let start = currentStart {
                segments.append(start..<currentEnd)
                currentStart = nil
            }
        } else {
            // Check for opening fence or math block
            var openedFence = false
            if indent <= 3 {
                let first = bytes[nonBlank]
                if first == 0x60 || first == 0x7E {
                    var run = nonBlank
                    while run < contentEnd && bytes[run] == first { run += 1 }
                    let runLen = run - nonBlank
                    if runLen >= 3 {
                        var validInfo = true
                        if first == 0x60 {
                            for k in run..<contentEnd where bytes[k] == 0x60 {
                                validInfo = false
                                break
                            }
                        }
                        if validInfo {
                            if let start = currentStart {
                                segments.append(start..<currentEnd)
                            }
                            currentStart = lineStart
                            currentEnd = nextLineStart
                            inFence = true
                            fenceChar = first
                            fenceLen = runLen
                            openedFence = true
                        }
                    }
                } else if enableMath && (first == 0x24 || first == 0x5C) && nonBlank + 1 < contentEnd {
                    var trimmedEnd = contentEnd
                    while trimmedEnd > nonBlank && (bytes[trimmedEnd - 1] == 0x20 || bytes[trimmedEnd - 1] == 0x09) {
                        trimmedEnd -= 1
                    }
                    let isDollar = first == 0x24 && bytes[nonBlank + 1] == 0x24
                    let isBracket = first == 0x5C && bytes[nonBlank + 1] == 0x5B
                    if (isDollar || isBracket) && trimmedEnd - nonBlank == 2 {
                        if let start = currentStart {
                            segments.append(start..<currentEnd)
                        }
                        currentStart = lineStart
                        currentEnd = nextLineStart
                        inMathBlock = true
                        mathChar = first
                        openedFence = true
                    }
                }
            }

            if !openedFence {
                if currentStart == nil {
                    currentStart = lineStart
                }
                currentEnd = nextLineStart
            }
        }

        lineStart = nextLineStart
    }

    if let start = currentStart {
        segments.append(start..<currentEnd)
    }

    var ranges: [Range<Int>] = []
    var raws: [String] = []
    ranges.reserveCapacity(blockCount)
    raws.reserveCapacity(blockCount)

    for idx in 0..<blockCount {
        let range: Range<Int>
        if idx < segments.count {
            range = segments[idx]
        } else if !segments.isEmpty {
            range = segments[segments.count - 1]
        } else {
            range = 0..<n
        }
        ranges.append(range)
        raws.append(String(decoding: bytes[range], as: UTF8.self))
    }

    return SourceScanInfo(
        ranges: ranges,
        raws: raws,
        hasUnclosedTrailingFence: inFence || inMathBlock,
        endsWithBlankLine: endsWithBlankLine
    )
}
