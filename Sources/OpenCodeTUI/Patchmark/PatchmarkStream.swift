/// If the last line holds only a bare block opener (`-`, `*`, `+`, `##`, `12.`, `>`, ```` ``` ````, `$$`),
/// holds that line back until its first content character or newline arrives.
/// Prevents 1-frame paragraph-to-heading/list kind pops during token streaming.
// parity: patchmark/src/stream.ts#splitPendingMarker [status=implemented hash=e1dab229618e]
public func splitPendingMarker(_ text: String) -> (visible: String, held: String) {
    let u = Array(text.utf16)
    var lastNl = -1
    for i in stride(from: u.count - 1, through: 0, by: -1) {
        if u[i] == 0x0A {
            lastNl = i
            break
        }
    }
    let lineStart = lastNl + 1
    let tailLen = u.count - lineStart
    if tailLen == 0 || tailLen > 12 { return (text, "") }

    let tailLine = String(decoding: u[lineStart..<u.count], as: UTF16.self)
    let trimmed = trimJsWhitespace(tailLine)
    let trimU = Array(trimmed.utf16)
    if trimU.isEmpty { return (text, "") }

    let first = trimU[0]
    if first == 0x23 /* # */
        || first == 0x60 /* ` */
        || first == 0x7E /* ~ */
        || first == 0x2D /* - */
        || first == 0x2A /* * */
        || first == 0x5F /* _ */
        || first == 0x24 /* $ */
        || first == 0x3D /* = */
    {
        var allSame = true
        for i in 1..<trimU.count where trimU[i] != first {
            allSame = false
            break
        }
        if allSame {
            let maxHold = first == 0x23 ? 6 : (first == 0x60 || first == 0x7E) ? 3 : 2
            if trimU.count <= maxHold {
                let visible = String(decoding: u[0..<lineStart], as: UTF16.self)
                return (visible, tailLine)
            }
        }
    }

    if trimmed == "+" || trimmed == "•" || trimmed == ">" || trimmed == "\\[" {
        let visible = String(decoding: u[0..<lineStart], as: UTF16.self)
        return (visible, tailLine)
    }

    var d = 0
    while d < trimU.count && isAsciiDigit(trimU[d]) { d += 1 }
    if d > 0 {
        let restLen = trimU.count - d
        if restLen == 0 || (restLen == 1 && (trimU[d] == 0x2E || trimU[d] == 0x29)) {
            let visible = String(decoding: u[0..<lineStart], as: UTF16.self)
            return (visible, tailLine)
        }
    }

    return (text, "")
}

/// Matches `/^[ \t]*(?:-+|=+)[ \t]*$/`.
private func isSetextCandidate(_ s: String) -> Bool {
    let u = Array(s.utf16)
    let n = u.count
    var i = 0
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    guard i < n else { return false }
    let ch = u[i]
    guard ch == 0x2D || ch == 0x3D else { return false }
    while i < n && u[i] == ch { i += 1 }
    while i < n && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    return i == n
}

/// Matches `/^[ \t]{0,3}\[/`.
private func startsWithPossibleRefDef(_ s: String) -> Bool {
    let u = Array(s.utf16)
    var i = 0
    while i < u.count && i < 3 && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    return i < u.count && u[i] == 0x5B
}

private struct ConvertedBlock {
    let kind: BlockKind?
    let used: Set<String>
    let unresolved: Set<String>
}

private final class ConvertContext {
    let refmap: RefMap
    let cacheable: Bool
    let inTail: Bool
    let partialLine: Bool
    let healTarget: BNode?
    let heal: TailHeal?
    var used: Set<String>
    var unresolved: Set<String>

    init(
        refmap: RefMap,
        cacheable: Bool,
        inTail: Bool,
        partialLine: Bool,
        healTarget: BNode?,
        heal: TailHeal?,
        used: Set<String> = [],
        unresolved: Set<String> = []
    ) {
        self.refmap = refmap
        self.cacheable = cacheable
        self.inTail = inTail
        self.partialLine = partialLine
        self.healTarget = healTarget
        self.heal = heal
        self.used = used
        self.unresolved = unresolved
    }

    func childContext(used: Set<String> = [], unresolved: Set<String> = []) -> ConvertContext {
        ConvertContext(
            refmap: refmap,
            cacheable: cacheable,
            inTail: inTail,
            partialLine: partialLine,
            healTarget: healTarget,
            heal: heal,
            used: used,
            unresolved: unresolved
        )
    }
}

private struct SettledMeta {
    let docIndex: Int
    let lastIndex: Int
    var unresolved: Set<String>
}

private struct CachedItem {
    let version: Int
    let item: ListItemNode
    let used: Set<String>
    let unresolved: Set<String>
}

private struct TailRawCache {
    var startLine: Int
    var upTo: Int
    var text: String
}

/// Incremental CommonMark + GFM + Math streaming markdown parser emitting minimal `BlockPatch` frames.
// parity: patchmark/src/stream.ts#PatchmarkStream [status=implemented hash=86baf18d4609]
public final class PatchmarkStream {
    private let options: StreamOptions
    private var text = ""
    private var parser: BlockParser!
    /// UTF-16 offset just past the last complete line.
    private var fed = 0
    /// Text after the last complete line.
    private var partial = ""
    private var lineStarts: [Int] = []
    /// Complete lines, without and with their line terminators.
    private var lines: [String] = []
    private var lineRaw: [String] = []
    private var tailRaw: TailRawCache?
    private var finished = false
    private var blocks: [MarkdownBlock] = []
    private var settledCount = 0
    private var settledNodes = 0
    private var settledMeta: [SettledMeta] = []
    private var waiting: [String: Set<Int>] = [:]
    private var refsSeen = 0
    private var provisionalRefs: [String] = []
    private var nextId = 0
    private var cache: [Int: (version: Int, result: ConvertedBlock)] = [:]
    private var itemCache: [Int: CachedItem] = [:]
    private var disallowMath: Set<Int> = []

    public init(_ options: StreamOptions = StreamOptions()) {
        self.options = options
        resetState()
    }

    private func resetState() {
        text = ""
        disallowMath = []
        parser = BlockParser(options: ParserOptions(gfm: options.gfm, math: options.math), disallowMath: disallowMath)
        fed = 0
        partial = ""
        lineStarts = []
        lines = []
        lineRaw = []
        tailRaw = nil
        finished = false
        blocks = []
        settledCount = 0
        settledNodes = 0
        settledMeta = []
        waiting = [:]
        refsSeen = 0
        provisionalRefs = []
        cache = [:]
        itemCache = [:]
    }

    /// Resets the stream to empty state.
    // parity: patchmark/src/stream.ts#PatchmarkStream.reset [status=implemented hash=a39cf843d48d]
    public func reset() {
        resetState()
        nextId = 0
    }

    // parity: patchmark/src/stream.ts#PatchmarkStream.getBlocks [status=implemented hash=1f0135a11115]
    public func getBlocks() -> [MarkdownBlock] {
        blocks
    }

    // parity: patchmark/src/stream.ts#PatchmarkStream.getText [status=implemented hash=c57b7d9927cb]
    public func getText() -> String {
        text
    }

    /// Appends a streaming delta chunk.
    // parity: patchmark/src/stream.ts#PatchmarkStream.append [status=implemented hash=74d91d7abb47]
    @discardableResult
    public func append(_ delta: String) -> StreamFrame {
        if delta.isEmpty { return emptyFrame() }
        if finished { return update(text + delta, streaming: true) }
        text.append(delta)
        partial.append(delta)
        return step(streaming: true)
    }

    /// Finalizes the stream: flushes held markers and settles every block.
    // parity: patchmark/src/stream.ts#PatchmarkStream.finalize [status=implemented hash=6d54a925b134]
    @discardableResult
    public func finalize() -> StreamFrame {
        update(text, streaming: false)
    }

    /// Declarative update: prefix appends are incremental; anything else re-parses and patches the difference.
    // parity: patchmark/src/stream.ts#PatchmarkStream.update [status=implemented hash=7f00e8dfa5ac]
    @discardableResult
    public func update(_ newText: String, streaming: Bool = true) -> StreamFrame {
        if finished || !newText.hasPrefix(text) {
            if finished && newText == text { return emptyFrame() }
            return rebuild(newText, streaming: streaming)
        }
        if newText.utf16.count == text.utf16.count && streaming && !blocks.isEmpty {
            return emptyFrame()
        }
        let suffixStart = newText.utf16.index(newText.utf16.startIndex, offsetBy: text.utf16.count)
        partial.append(String(newText[suffixStart...]))
        text = newText
        return step(streaming: streaming)
    }

    private func emptyFrame() -> StreamFrame {
        StreamFrame(
            text: text,
            settledOffset: settledOffset(),
            blocks: blocks,
            patches: [],
            heldMarker: "",
            charsScanned: 0
        )
    }

    private func settledOffset() -> Int {
        if settledCount == 0 { return 0 }
        return blocks[settledCount - 1].end
    }

    private func rebuild(_ newText: String, streaming: Bool) -> StreamFrame {
        let previous = blocks
        resetState()
        text = newText
        partial = newText
        let frame = step(streaming: streaming)
        var next = blocks
        var keep = 0
        while keep < previous.count
            && keep < next.count
            && previous[keep].status == .settled
            && next[keep].status == .settled
            && previous[keep].raw == next[keep].raw
            && previous[keep].start == next[keep].start
            && previous[keep].defs == next[keep].defs
        {
            next[keep] = previous[keep]
            keep += 1
        }
        for i in keep..<next.count {
            next[i].id = nextId
            nextId += 1
        }
        blocks = next
        var patches: [BlockPatch] = []
        if keep < previous.count {
            patches.append(.truncate(keepCount: keep))
        }
        for i in keep..<next.count {
            patches.append(.append(block: next[i]))
            if next[i].status == .settled {
                patches.append(.finalize(id: next[i].id, index: i, block: next[i]))
            }
        }
        return StreamFrame(
            text: frame.text,
            settledOffset: frame.settledOffset,
            blocks: next,
            patches: patches,
            heldMarker: frame.heldMarker,
            charsScanned: frame.charsScanned
        )
    }

    private func step(streaming: Bool) -> StreamFrame {
        let before = fed
        feedCompleteLines(streaming: streaming)
        var curPartial = partial

        if !streaming {
            if !curPartial.isEmpty {
                let u = Array(curPartial.utf16)
                let stripped = (u.last == 0x0D)
                    ? String(decoding: u[0..<(u.count - 1)], as: UTF16.self)
                    : curPartial
                pushLine(stripped, raw: curPartial)
                parser.incorporateLine(lines[lines.count - 1])
                partial = ""
                curPartial = ""
            }
            parser.finish()
            while parser.unclosedMathAt != 0 { reparse(finish: true) }
            finished = true
        } else if parser.unclosedMathAt != 0 {
            reparse(finish: false)
        }

        let oldSettledCount = settledCount
        let prevTail = Array(blocks[oldSettledCount...])
        var nextBlocks: [MarkdownBlock] = []
        var newSettledMeta: [SettledMeta] = []

        var held = ""
        var visible = ""
        var preFork: (fork: BlockParser, tip: BNode)? = nil
        if streaming {
            visible = curPartial
            let visU = Array(visible.utf16)
            if visU.last == 0x0D {
                visible = String(decoding: visU[0..<(visU.count - 1)], as: UTF16.self)
            }
            if !visible.isEmpty && isSetextCandidate(visible) {
                held = visible
                visible = ""
            } else if !visible.isEmpty && options.holdPendingMarkers {
                let split = splitPendingMarker(visible)
                held = split.held
                visible = split.visible
            }
        }

        func ensureFork() -> (fork: BlockParser, tip: BNode) {
            if let existing = preFork { return existing }
            let fork = parser.fork()
            if !visible.isEmpty { fork.incorporateLine(visible) }
            let tip = fork.tip
            fork.finish()
            let created = (fork, tip)
            preFork = created
            return created
        }

        // 1. Newly settled top-level blocks (or groups of them)
        let children = parser.doc.children
        while settledNodes < children.count {
            let first = settledNodes
            let grouped = groupEnd(children, first: first)
            if grouped < 0 && streaming { break }
            let last = grouped < 0 ? children.count - 1 : grouped
            let node = children[first]
            let isLast = last == children.count - 1
            let early =
                options.settleOnComplete
                && first == last
                && node.open
                && isLast
                && streaming
                && (node.type == .heading || node.type == .thematicBreak)
            var isOpen = false
            for k in first...last where children[k].open {
                isOpen = true
                break
            }
            if isOpen && !early { break }

            if !options.settleOnComplete && streaming {
                var hasVisibleAfter = false
                if last + 1 < children.count {
                    for m in (last + 1)..<children.count {
                        if !children[m].open && !children[m].defsOnly {
                            hasVisibleAfter = true
                            break
                        }
                    }
                }
                if !hasVisibleAfter {
                    let lastChild = children.last
                    let openAfter = (lastChild != nil && lastChild!.open && children.count - 1 > last) ? lastChild : nil
                    if openAfter == nil && visible.isEmpty { break }
                    let mayBeDef =
                        (openAfter != nil && openAfter!.type == .paragraph && openAfter!.content.utf16.first == 0x5B)
                        || (openAfter == nil && startsWithPossibleRefDef(visible))
                    if mayBeDef {
                        let forked = ensureFork().fork
                        if !forked.doc.children.contains(where: { !$0.defsOnly }) { break }
                    }
                }
            }

            let ctx = ConvertContext(
                refmap: parser.refmap,
                cacheable: true,
                inTail: false,
                partialLine: false,
                healTarget: nil,
                heal: nil
            )
            if let kind = convertUnit(children, first: first, last: last, ctx: ctx) {
                let end = children[last]
                let rawEndLine: Int
                if !options.settleOnComplete {
                    rawEndLine = last + 1 < children.count ? children[last + 1].startLine - 1 : lines.count
                } else {
                    rawEndLine = end.open ? lines.count : end.endLine
                }
                let raw = joinLines(from: node.startLine, to: rawEndLine)
                nextBlocks.append(makeBlock(
                    id: -1,
                    start: lineStarts[node.startLine - 1],
                    raw: raw,
                    status: .settled,
                    kind: kind,
                    used: ctx.used,
                    refmap: parser.refmap,
                    liveRaw: nil
                ))
                newSettledMeta.append(SettledMeta(docIndex: first, lastIndex: last, unresolved: ctx.unresolved))
            }
            settledNodes = last + 1
            if early { break }
        }

        // 2. The streaming tail
        var tailRefmap: RefMap? = nil
        var tailRefsAdded: [String] = []
        if streaming {
            let tail = buildTail(visible: visible, preFork: preFork)
            tailRefmap = tail.refmap
            tailRefsAdded = tail.refsAdded
            nextBlocks.append(contentsOf: tail.blocks)
        }

        // 3. Reconcile against the previous tail and emit patches
        var patches: [BlockPatch] = []
        for j in 0..<nextBlocks.count {
            let index = oldSettledCount + j
            var block = nextBlocks[j]
            if j < prevTail.count {
                let prev = prevTail[j]
                block.id = prev.id
                if block.status == .settled {
                    patches.append(.finalize(id: block.id, index: index, block: block))
                } else if prev.raw == block.raw
                    && prev.liveRaw == block.liveRaw
                    && prev.status == block.status
                    && prev.defs == block.defs
                {
                    block = prev
                } else {
                    patches.append(.replace(id: block.id, index: index, block: block))
                }
            } else {
                block.id = nextId
                nextId += 1
                patches.append(.append(block: block))
                if block.status == .settled {
                    patches.append(.finalize(id: block.id, index: index, block: block))
                }
            }
            nextBlocks[j] = block
        }
        if prevTail.count > nextBlocks.count {
            patches.append(.truncate(keepCount: oldSettledCount + nextBlocks.count))
        }
        blocks.removeSubrange(oldSettledCount..<blocks.count)
        blocks.append(contentsOf: nextBlocks)

        for meta in newSettledMeta {
            let index = settledMeta.count
            settledMeta.append(meta)
            for label in meta.unresolved {
                waiting[label, default: []].insert(index)
            }
        }
        settledCount = oldSettledCount + newSettledMeta.count

        // 4. Reference definitions that arrived after the blocks that use them: patch those blocks
        backfillRefs(patches: &patches, tailRefmap: tailRefmap, tailRefsAdded: tailRefsAdded)

        return StreamFrame(
            text: text,
            settledOffset: settledOffset(),
            blocks: blocks,
            patches: patches,
            heldMarker: held,
            charsScanned: (fed - before) + curPartial.utf16.count
        )
    }

    private func backfillRefs(patches: inout [BlockPatch], tailRefmap: RefMap?, tailRefsAdded: [String]) {
        let added = parser.refsAdded
        let provisional = provisionalRefs
        provisionalRefs = tailRefsAdded
        if refsSeen >= added.count && tailRefsAdded.isEmpty && provisional.isEmpty { return }

        var touched = Set<Int>()
        for label in provisional {
            if let set = waiting[label] { touched.formUnion(set) }
        }
        if refsSeen < added.count {
            for i in refsSeen..<added.count {
                let label = added[i]
                if let set = waiting.removeValue(forKey: label) {
                    touched.formUnion(set)
                }
            }
        }
        refsSeen = added.count
        for label in tailRefsAdded {
            if let set = waiting[label] { touched.formUnion(set) }
        }

        let refmap = tailRefmap ?? parser.refmap
        for idx in touched.sorted() {
            let meta = settledMeta[idx]
            let ctx = ConvertContext(
                refmap: refmap,
                cacheable: false,
                inTail: false,
                partialLine: false,
                healTarget: nil,
                heal: nil
            )
            guard let kind = convertUnit(parser.doc.children, first: meta.docIndex, last: meta.lastIndex, ctx: ctx) else {
                continue
            }
            let old = blocks[idx]
            let updated = makeBlock(
                id: old.id,
                start: old.start,
                raw: old.raw,
                status: .settled,
                kind: kind,
                used: ctx.used,
                refmap: refmap,
                liveRaw: nil
            )
            settledMeta[idx].unresolved = ctx.unresolved
            for label in ctx.unresolved {
                waiting[label, default: []].insert(idx)
            }
            for label in ctx.used where parser.refmap[label] == nil {
                waiting[label, default: []].insert(idx)
            }

            var patchedInFrame = false
            for pIdx in patches.indices {
                switch patches[pIdx] {
                case .append(let blk) where blk.id == updated.id:
                    patches[pIdx] = .append(block: updated)
                    patchedInFrame = true
                case .replace(let id, let index, _) where id == updated.id:
                    patches[pIdx] = .replace(id: id, index: index, block: updated)
                    patchedInFrame = true
                case .finalize(let id, let index, _) where id == updated.id:
                    patches[pIdx] = .finalize(id: id, index: index, block: updated)
                    patchedInFrame = true
                default:
                    break
                }
            }
            if patchedInFrame {
                blocks[idx] = updated
            } else if old.defs != updated.defs || old.html != updated.html || old.kind != updated.kind {
                blocks[idx] = updated
                patches.append(.replace(id: updated.id, index: idx, block: updated))
            }
        }
    }

    private func joinLines(from: Int, to: Int) -> String {
        if to < from { return "" }
        if from == to { return lineRaw[from - 1] }
        var out = ""
        for i in (from - 1)..<to {
            out.append(lineRaw[i])
        }
        return out
    }

    private func pushLine(_ line: String, raw: String) {
        lineStarts.append(fed)
        lines.append(line)
        lineRaw.append(raw)
        fed += raw.utf16.count
    }

    private func feedCompleteLines(streaming: Bool) {
        let u = Array(partial.utf16)
        let len = u.count
        var pos = 0
        while pos < len {
            var idx = -1
            for k in pos..<len {
                let c = u[k]
                if c == 0x0A || c == 0x0D {
                    idx = k
                    break
                }
            }
            if idx < 0 { break }
            var term = 1
            if u[idx] == 0x0D {
                if idx + 1 < len {
                    term = u[idx + 1] == 0x0A ? 2 : 1
                } else if streaming {
                    break
                }
            }
            let line = String(decoding: u[pos..<idx], as: UTF16.self)
            let raw = String(decoding: u[pos..<(idx + term)], as: UTF16.self)
            pushLine(line, raw: raw)
            parser.incorporateLine(lines[lines.count - 1])
            pos = idx + term
            if parser.unclosedMathAt != 0 { reparse(finish: false) }
        }
        if pos > 0 {
            partial = String(decoding: u[pos..<len], as: UTF16.self)
        }
    }

    private func reparse(finish: Bool) {
        while parser.unclosedMathAt != 0 {
            disallowMath.insert(parser.unclosedMathAt)
            let nextParser = BlockParser(
                options: ParserOptions(gfm: options.gfm, math: options.math),
                disallowMath: disallowMath
            )
            for line in lines {
                nextParser.incorporateLine(line)
                if nextParser.unclosedMathAt != 0 { break }
            }
            if nextParser.unclosedMathAt == 0 && finish {
                nextParser.finish()
            }
            parser = nextParser
            cache = [:]
            itemCache = [:]
        }
        refsSeen = min(refsSeen, parser.refsAdded.count)
    }

    private func buildTail(
        visible: String,
        preFork: (fork: BlockParser, tip: BNode)?
    ) -> (blocks: [MarkdownBlock], refmap: RefMap?, refsAdded: [String]) {
        let children = parser.doc.children
        let last = children.last
        let openChild = (last != nil && last!.open) ? last : nil
        let openIndex = openChild != nil ? children.count - 1 : -1
        if settledNodes >= children.count && visible.isEmpty {
            return ([], nil, [])
        }

        let fork: BlockParser
        let tip: BNode
        if let preFork {
            fork = preFork.fork
            tip = preFork.tip
        } else {
            fork = parser.fork()
            if !visible.isEmpty { fork.incorporateLine(visible) }
            tip = fork.tip
            fork.finish()
        }

        var healTarget: BNode? = nil
        var heal: TailHeal? = nil
        if options.heal && (tip.type == .paragraph || tip.type == .heading || tip.type == .table) {
            let content = tip.type == .table ? (tip.rows.last ?? "") : tip.content
            if !content.isEmpty {
                let h = computeTailHeal(content)
                if h.strip > 0 || !h.append.isEmpty {
                    healTarget = tip
                    heal = h
                }
            }
        }

        let lineCount = lines.count
        let sliceEnd = openChild != nil ? openIndex : children.count
        var tailNodes: [BNode] = settledNodes < sliceEnd ? Array(children[settledNodes..<sliceEnd]) : []
        let skipFirst = (openChild != nil && openIndex < settledNodes) ? 1 : 0
        if skipFirst < fork.doc.children.count {
            tailNodes.append(contentsOf: fork.doc.children[skipFirst...])
        }

        var units: [(first: Int, last: Int, kind: BlockKind, ctx: ConvertContext)] = []
        var first = 0
        while first < tailNodes.count {
            var last = groupEnd(tailNodes, first: first)
            if last < 0 { last = tailNodes.count - 1 }
            let isLastUnit = last == tailNodes.count - 1
            let ctx = ConvertContext(
                refmap: fork.refmap,
                cacheable: fork.refmap.count == parser.refmap.count,
                inTail: true,
                partialLine: isLastUnit && !visible.isEmpty,
                healTarget: healTarget,
                heal: heal
            )
            if let kind = convertUnit(tailNodes, first: first, last: last, ctx: ctx) {
                units.append((first, last, kind, ctx))
            }
            first = last + 1
        }

        var out: [MarkdownBlock] = []
        for u in 0..<units.count {
            let unit = units[u]
            let node = tailNodes[unit.first]
            let end = tailNodes[unit.last]
            let isLastVisUnit = u == units.count - 1
            let raw: String
            let start: Int
            if node.startLine > lineCount {
                start = fed
                raw = visible
            } else {
                start = lineStarts[node.startLine - 1]
                if isLastVisUnit && (!options.settleOnComplete || unit.last == tailNodes.count - 1) {
                    raw = joinTail(from: node.startLine, to: lineCount) + visible
                } else {
                    let nextStart = !isLastVisUnit ? tailNodes[units[u + 1].first].startLine - 1 : end.endLine
                    let endLine = !options.settleOnComplete ? min(nextStart, lineCount) : min(end.endLine, lineCount)
                    raw = joinLines(from: node.startLine, to: endLine) + (end.endLine > lineCount ? visible : "")
                }
            }
            let liveRaw: String? = (heal != nil && isLastVisUnit && healTarget != nil) ? applyTailHeal(raw, heal!) : nil
            out.append(makeBlock(
                id: -1,
                start: start,
                raw: raw,
                status: .streaming,
                kind: unit.kind,
                used: unit.ctx.used,
                refmap: fork.refmap,
                liveRaw: liveRaw
            ))
        }
        return (out, fork.refmap, fork.refsAdded)
    }

    private func groupEnd(_ nodes: [BNode], first: Int) -> Int {
        if !options.groupHtmlBlocks { return first }
        var balance = htmlBalance(nodes[first])
        if balance <= 0 { return first }
        for k in (first + 1)..<nodes.count {
            balance += htmlBalance(nodes[k])
            if balance <= 0 { return k }
        }
        return -1
    }

    private func convertUnit(_ nodes: [BNode], first: Int, last: Int, ctx: ConvertContext) -> BlockKind? {
        if first == last { return convert(nodes[first], ctx: ctx) }
        var groupBlocks: [BlockKind] = []
        for k in first...last {
            if let kind = convert(nodes[k], ctx: ctx) {
                groupBlocks.append(kind)
            }
        }
        return .group(blocks: groupBlocks)
    }

    private func joinTail(from: Int, to: Int) -> String {
        if var cached = tailRaw, cached.startLine == from && cached.upTo <= to {
            if cached.upTo < to {
                cached.text.append(joinLines(from: cached.upTo + 1, to: to))
                cached.upTo = to
                tailRaw = cached
            }
            return cached.text
        }
        let joined = joinLines(from: from, to: to)
        tailRaw = TailRawCache(startLine: from, upTo: to, text: joined)
        return joined
    }

    private func makeBlock(
        id: Int,
        start: Int,
        raw: String,
        status: MarkdownBlockStatus,
        kind: BlockKind,
        used: Set<String>,
        refmap: RefMap,
        liveRaw: String?
    ) -> MarkdownBlock {
        let end = start + raw.utf16.count
        var defsStr: String? = nil
        if !used.isEmpty {
            var defs: [String] = []
            for label in used.sorted() {
                guard let def = refmap[label], let defRaw = def.raw else { continue }
                let defStart: Int
                if let defLine = def.line {
                    defStart = defLine <= lineStarts.count ? lineStarts[defLine - 1] : fed
                } else {
                    defStart = -1
                }
                if !options.settleOnComplete && defStart >= start && defStart < end { continue }
                defs.append(defRaw)
            }
            if !defs.isEmpty { defsStr = defs.joined(separator: "\n") }
        }
        let html = options.renderHtml
            ? renderBlockKindToHtml(kind, options: HtmlRenderOptions(gfm: options.gfm, math: options.math))
            : nil
        return MarkdownBlock(
            id: id,
            start: start,
            end: end,
            raw: raw,
            status: status,
            kind: kind,
            html: html,
            defs: defsStr,
            liveRaw: liveRaw
        )
    }

    private func convert(_ node: BNode, ctx: ConvertContext) -> BlockKind? {
        let persistent = ctx.cacheable && !node.open && !node.forked
        if persistent {
            if let hit = cache[node.serial], hit.version == ctx.refmap.count {
                ctx.used.formUnion(hit.result.used)
                ctx.unresolved.formUnion(hit.result.unresolved)
                return hit.result.kind
            }
            let sub = ctx.childContext()
            let kind = convertUncached(node, ctx: sub)
            cache[node.serial] = (version: ctx.refmap.count, result: ConvertedBlock(kind: kind, used: sub.used, unresolved: sub.unresolved))
            ctx.used.formUnion(sub.used)
            ctx.unresolved.formUnion(sub.unresolved)
            return kind
        }
        return convertUncached(node, ctx: ctx)
    }

    private func inlines(_ content: String, ctx: ConvertContext) -> [InlineNode] {
        parseInlinesTracking(
            content,
            options: InlineParseOptions(gfm: options.gfm, math: options.math, defs: ctx.refmap),
            trackRefs: true,
            usedRefs: &ctx.used,
            unresolvedRefs: &ctx.unresolved
        )
    }

    private func convertUncached(_ node: BNode, ctx: ConvertContext) -> BlockKind? {
        let healHere = ctx.healTarget === node && ctx.heal != nil
        switch node.type {
        case .paragraph:
            if node.defsOnly { return nil }
            let content = healHere ? applyTailHeal(node.content, ctx.heal!) : node.content
            return .paragraph(inlines: inlines(content, ctx: ctx))
        case .heading:
            let content = healHere ? applyTailHeal(node.content, ctx.heal!) : node.content
            let level = HeadingLevel(rawValue: max(1, min(6, node.level))) ?? .h1
            return .heading(level: level, inlines: inlines(content, ctx: ctx))
        case .thematicBreak:
            return .hr
        case .codeBlock:
            let literal = node.literal
            let info = node.info
            let (language, meta) = splitCodeInfo(info)
            let complete = node.isFenced ? node.fenceClosed : !node.forked
            let keepTrailingNewline = ctx.inTail && node.isFenced && !complete && !ctx.partialLine
            let source = (!keepTrailingNewline && literal.hasSuffix("\n")) ? String(literal.dropLast()) : literal
            let defaultHtmlLiteral = !source.isEmpty
                ? (source.hasSuffix("\n") && !complete ? source : "\(source)\n")
                : ""
            let htmlLiteral: String? = literal != defaultHtmlLiteral ? literal : nil
            if let language, language.lowercased() == "mermaid" {
                return .mermaid(source: source, htmlLiteral: htmlLiteral, complete: complete)
            }
            let fence = node.isFenced ? String(repeating: node.fenceChar, count: node.fenceLength) : ""
            return .code(
                language: language,
                meta: meta,
                source: source,
                htmlLiteral: htmlLiteral,
                fence: fence,
                indented: !node.isFenced,
                complete: complete
            )
        case .htmlBlock:
            return .htmlBlock(raw: node.literal)
        case .mathBlock:
            return .math(
                source: trimJsWhitespace(node.literal),
                delimiter: node.mathDelimiter == "$" ? .dollar : .doubleDollar,
                complete: node.mathClosed
            )
        case .blockQuote:
            var childBlocks: [BlockKind] = []
            for child in node.children {
                if let kind = convert(child, ctx: ctx) {
                    childBlocks.append(kind)
                }
            }
            return .blockquote(blocks: childBlocks)
        case .list:
            let ld = node.listData!
            let version = ctx.cacheable ? ctx.refmap.count : -1
            let memo = node.listMemo!
            if version < 0 || memo.version != version {
                memo.version = version
                memo.items = []
                memo.count = 0
                memo.used = []
                memo.unresolved = []
            }
            let ch = node.children
            var closedPrefix = ch.count
            while closedPrefix > 0 && ch[closedPrefix - 1].forked { closedPrefix -= 1 }
            if memo.count > closedPrefix {
                memo.items.removeSubrange(closedPrefix..<memo.items.count)
                memo.count = closedPrefix
            }
            for i in memo.count..<closedPrefix {
                let sub = ctx.childContext(used: memo.used, unresolved: memo.unresolved)
                memo.items.append(convertItemCached(ch[i], ctx: sub))
                memo.used = sub.used
                memo.unresolved = sub.unresolved
                memo.count = i + 1
            }
            ctx.used.formUnion(memo.used)
            ctx.unresolved.formUnion(memo.unresolved)
            var items = memo.items
            for i in closedPrefix..<ch.count {
                items.append(convertItemCached(ch[i], ctx: ctx))
            }
            return .list(
                ordered: ld.type == .ordered,
                marker: ld.type == .ordered ? (ld.delimiter ?? ".") : (ld.bulletChar ?? "-"),
                start: ld.type == .ordered ? ld.start : nil,
                tight: ld.tight,
                items: items
            )
        case .table:
            let width = node.header.count
            let version = ctx.cacheable ? ctx.refmap.count : -1
            let memo = node.tableMemo!
            if version < 0 || memo.version != version {
                memo.version = version
                memo.headers = nil
                memo.rows = []
                memo.rawRows = []
                memo.used = []
                memo.unresolved = []
            }
            func parseRow(_ split: [String], used: inout Set<String>, unresolved: inout Set<String>) -> [[InlineNode]] {
                let sub = ctx.childContext(used: used, unresolved: unresolved)
                var row: [[InlineNode]] = []
                row.reserveCapacity(width)
                for c in 0..<width {
                    row.append(c < split.count ? inlines(unescapePipes(split[c]), ctx: sub) : [])
                }
                used = sub.used
                unresolved = sub.unresolved
                return row
            }
            if memo.headers == nil {
                memo.headers = parseRow(node.header, used: &memo.used, unresolved: &memo.unresolved)
            }
            let headers = memo.headers ?? []
            let stableCount = (healHere && !node.rows.isEmpty) ? node.rows.count - 1 : node.rows.count
            var common = min(memo.rows.count, stableCount)
            while common > 0 && memo.rawRows[common - 1] != node.rows[common - 1] { common -= 1 }
            if common < memo.rows.count {
                memo.rows.removeSubrange(common..<memo.rows.count)
                memo.rawRows.removeSubrange(common..<memo.rawRows.count)
            }
            for r in common..<stableCount {
                let rowText = node.rows[r]
                memo.rawRows.append(rowText)
                memo.rows.append(parseRow(splitTableRow(rowText), used: &memo.used, unresolved: &memo.unresolved))
            }
            ctx.used.formUnion(memo.used)
            ctx.unresolved.formUnion(memo.unresolved)
            var rows = memo.rows
            if stableCount < node.rows.count {
                let rowText = applyTailHeal(node.rows[node.rows.count - 1], ctx.heal!)
                rows.append(parseRow(splitTableRow(rowText), used: &ctx.used, unresolved: &ctx.unresolved))
            }
            return .table(align: node.align, headers: headers, rows: rows)
        case .document, .item:
            return nil
        }
    }

    private func convertItemCached(_ item: BNode, ctx: ConvertContext) -> ListItemNode {
        if !ctx.cacheable || item.forked { return convertItem(item, ctx: ctx) }
        let version = ctx.refmap.count
        if let hit = itemCache[item.serial], hit.version == version {
            ctx.used.formUnion(hit.used)
            ctx.unresolved.formUnion(hit.unresolved)
            return hit.item
        }
        let sub = ctx.childContext()
        let result = convertItem(item, ctx: sub)
        itemCache[item.serial] = CachedItem(version: version, item: result, used: sub.used, unresolved: sub.unresolved)
        ctx.used.formUnion(sub.used)
        ctx.unresolved.formUnion(sub.unresolved)
        return result
    }

    private func convertItem(_ item: BNode, ctx: ConvertContext) -> ListItemNode {
        var blocks: [BlockKind] = []
        var checked: Bool? = nil
        let children = item.children
        for i in 0..<children.count {
            let child = children[i]
            if i == 0 && options.gfm && child.type == .paragraph && !child.defsOnly,
               let task = matchTask(child.content)
            {
                checked = task.checked
                let content = task.rest
                let leadingBr = hasLeadingSpacesBeforeNewline(content)
                let leadingWs = leadingBr ? "" : leadingHorizontalSpacesBeforeNonWs(content)
                let healed = (ctx.healTarget === child && ctx.heal != nil) ? applyTailHeal(content, ctx.heal!) : content
                var parsed = inlines(healed, ctx: ctx)
                if leadingBr {
                    parsed.insert(.br, at: 0)
                } else if !leadingWs.isEmpty && !parsed.isEmpty {
                    if case .text(let firstText) = parsed[0] {
                        parsed[0] = .text(leadingWs + firstText)
                    } else {
                        parsed.insert(.text(leadingWs), at: 0)
                    }
                }
                blocks.append(.paragraph(inlines: parsed))
                continue
            }
            if let kind = convert(child, ctx: ctx) {
                blocks.append(kind)
            }
        }
        return ListItemNode(checked: checked, blocks: blocks)
    }
}

// MARK: - Stream Helpers

private func splitCodeInfo(_ info: String) -> (language: String?, meta: String?) {
    if info.isEmpty { return (nil, nil) }
    let u = Array(info.utf16)
    var i = 0
    while i < u.count && !isJsWhitespace(u[i]) { i += 1 }
    if i == 0 { return (nil, nil) }
    let lang = String(decoding: u[0..<i], as: UTF16.self)
    let rest = trimJsWhitespace(String(decoding: u[i..<u.count], as: UTF16.self))
    return (lang, rest.isEmpty ? nil : rest)
}

private let voidHtmlTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
]

private func stripHtmlComments(_ s: String) -> String {
    let u = Array(s.utf16)
    let n = u.count
    var out: [UInt16] = []
    out.reserveCapacity(n)
    var i = 0
    while i < n {
        if i + 3 < n && u[i] == 0x3C && u[i + 1] == 0x21 && u[i + 2] == 0x2D && u[i + 3] == 0x2D {
            var j = i + 4
            var closed = false
            while j + 2 < n {
                if u[j] == 0x2D && u[j + 1] == 0x2D && u[j + 2] == 0x3E {
                    i = j + 3
                    closed = true
                    break
                }
                j += 1
            }
            if !closed { break }
            continue
        }
        out.append(u[i])
        i += 1
    }
    return String(decoding: out, as: UTF16.self)
}

/// Open minus closed (non-void) tags in an HTML block.
private func htmlBalance(_ node: BNode) -> Int {
    if node.type != .htmlBlock { return 0 }
    if node.htmlBlockType <= 5 { return 0 }
    let raw = node.open ? node.content : node.literal
    let stripped = stripHtmlComments(raw)
    let u = Array(stripped.utf16)
    let n = u.count
    var balance = 0
    var i = 0
    while i < n {
        if u[i] == 0x3C /* < */ {
            var j = i + 1
            let isClosing = j < n && u[j] == 0x2F
            if isClosing { j += 1 }
            if j < n && isAsciiLetter(u[j]) {
                let nameStart = j
                j += 1
                while j < n && (isAsciiAlnum(u[j]) || u[j] == 0x2D) { j += 1 }
                let nameEnd = j
                // Word boundary check (\b): next char must not be word char
                let boundaryOk = j >= n || (!isAsciiAlnum(u[j]) && u[j] != 0x5F)
                if boundaryOk {
                    // Scan attributes until unquoted '>'
                    var foundEnd = false
                    var selfClosing = false
                    while j < n {
                        let c = u[j]
                        if c == 0x3E /* > */ {
                            selfClosing = (j > nameEnd && u[j - 1] == 0x2F)
                            foundEnd = true
                            j += 1
                            break
                        }
                        if c == 0x22 || c == 0x27 {
                            let q = c
                            j += 1
                            while j < n && u[j] != q { j += 1 }
                            if j < n { j += 1 }
                            continue
                        }
                        j += 1
                    }
                    if foundEnd {
                        let tagName = String(decoding: u[nameStart..<nameEnd], as: UTF16.self).lowercased()
                        if !selfClosing && !voidHtmlTags.contains(tagName) {
                            balance += isClosing ? -1 : 1
                        }
                        i = j
                        continue
                    }
                }
            }
        }
        i += 1
    }
    return balance
}

private func unescapePipes(_ cell: String) -> String {
    guard cell.contains("\\|") else { return cell }
    let u = Array(cell.utf16)
    var out: [UInt16] = []
    out.reserveCapacity(u.count)
    var i = 0
    while i < u.count {
        if u[i] == 0x5C && i + 1 < u.count && u[i + 1] == 0x7C {
            out.append(0x7C)
            i += 2
        } else {
            out.append(u[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF16.self)
}

private func matchTask(_ content: String) -> (checked: Bool, rest: String)? {
    let u = Array(content.utf16)
    guard u.count >= 4, u[0] == 0x5B, u[2] == 0x5D else { return nil }
    let mark = u[1]
    guard mark == 0x20 || mark == 0x78 || mark == 0x58 else { return nil }
    let after = u[3]
    guard after == 0x20 || after == 0x09 || after == 0x0A else { return nil }
    let tail = String(decoding: u[3..<u.count], as: UTF16.self)
    guard !trimJsWhitespace(tail).isEmpty else { return nil }
    return (checked: mark != 0x20, rest: String(decoding: u[4..<u.count], as: UTF16.self))
}

private func hasLeadingSpacesBeforeNewline(_ s: String) -> Bool {
    let u = Array(s.utf16)
    var i = 0
    while i < u.count && u[i] == 0x20 { i += 1 }
    return i > 0 && i < u.count && u[i] == 0x0A
}

private func leadingHorizontalSpacesBeforeNonWs(_ s: String) -> String {
    let u = Array(s.utf16)
    var i = 0
    while i < u.count && (u[i] == 0x20 || u[i] == 0x09) { i += 1 }
    if i > 0 && i < u.count && !isJsWhitespace(u[i]) {
        return String(decoding: u[0..<i], as: UTF16.self)
    }
    return ""
}

/// Creates a new incremental `PatchmarkStream` with the given options.
// parity: patchmark/src/stream.ts#createMarkdownStream [status=implemented hash=3aa1166d4ca5]
public func createMarkdownStream(_ options: StreamOptions = StreamOptions()) -> PatchmarkStream {
    PatchmarkStream(options)
}
