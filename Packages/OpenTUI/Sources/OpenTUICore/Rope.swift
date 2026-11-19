/// Aggregate metrics maintained on every node in a `Rope`.
public struct RopeMetrics: Equatable, Hashable, Sendable {
    /// Total UTF-8 byte count in this subtree.
    public var utf8Length: Int
    /// Total UTF-16 code unit count in this subtree.
    public var utf16Length: Int
    /// Total number of ASCII line feed (`\n`, U+000A) bytes in this subtree.
    public var newlineCount: Int
    /// Number of non-empty leaf chunks in this subtree.
    public var leafCount: Int
    /// Height (depth) of this subtree; a leaf has depth 1.
    public var depth: Int

    public static let zero = RopeMetrics(
        utf8Length: 0,
        utf16Length: 0,
        newlineCount: 0,
        leafCount: 0,
        depth: 0
    )

    public init(
        utf8Length: Int,
        utf16Length: Int,
        newlineCount: Int,
        leafCount: Int,
        depth: Int
    ) {
        self.utf8Length = utf8Length
        self.utf16Length = utf16Length
        self.newlineCount = newlineCount
        self.leafCount = leafCount
        self.depth = depth
    }

    internal static func measureLeaf(_ text: String) -> RopeMetrics {
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
        }
        return RopeMetrics(
            utf8Length: text.utf8.count,
            utf16Length: text.utf16.count,
            newlineCount: newlines,
            leafCount: text.isEmpty ? 0 : 1,
            depth: 1
        )
    }

    internal static func combine(_ lhs: RopeMetrics, _ rhs: RopeMetrics) -> RopeMetrics {
        RopeMetrics(
            utf8Length: lhs.utf8Length + rhs.utf8Length,
            utf16Length: lhs.utf16Length + rhs.utf16Length,
            newlineCount: lhs.newlineCount + rhs.newlineCount,
            leafCount: lhs.leafCount + rhs.leafCount,
            depth: max(lhs.depth, rhs.depth) + 1
        )
    }
}

private enum RopeNodeStorage: Sendable {
    case leaf(String)
    case branch(left: RopeNode, right: RopeNode)
}

/// Immutable, persistent AVL-balanced binary tree node backing `Rope`.
private final class RopeNode: Sendable {
    static let maxLeafUTF8: Int = 512
    static let mergeLeafUTF8: Int = 256

    let storage: RopeNodeStorage
    let metrics: RopeMetrics

    private init(leaf text: String) {
        self.storage = .leaf(text)
        self.metrics = RopeMetrics.measureLeaf(text)
    }

    private init(left: RopeNode, right: RopeNode) {
        self.storage = .branch(left: left, right: right)
        self.metrics = RopeMetrics.combine(left.metrics, right.metrics)
    }

    static func makeLeaf(_ text: String) -> RopeNode? {
        guard !text.isEmpty else { return nil }
        if text.utf8.count <= maxLeafUTF8 {
            return RopeNode(leaf: text)
        }
        var leaves: [RopeNode] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        let end = utf8.endIndex
        while start < end {
            var next = utf8.index(start, offsetBy: maxLeafUTF8, limitedBy: end) ?? end
            if next < end {
                // Step back to a valid Unicode scalar boundary (UTF-8 leading byte).
                while next > start && (utf8[next] & 0xC0) == 0x80 {
                    next = utf8.index(before: next)
                }
                if next == start {
                    // Single scalar larger than step (unreachable with 512), advance to next boundary.
                    next = utf8.index(after: start)
                    while next < end && (utf8[next] & 0xC0) == 0x80 {
                        next = utf8.index(after: next)
                    }
                }
            }
            leaves.append(RopeNode(leaf: String(text[start..<next])))
            start = next
        }
        return buildBalanced(leaves[...])
    }

    private static func buildBalanced(_ leaves: ArraySlice<RopeNode>) -> RopeNode? {
        let count = leaves.count
        if count == 0 { return nil }
        if count == 1 { return leaves[leaves.startIndex] }
        let mid = leaves.startIndex + count / 2
        let left = buildBalanced(leaves[leaves.startIndex..<mid])!
        let right = buildBalanced(leaves[mid..<leaves.endIndex])!
        return RopeNode(left: left, right: right)
    }

    private var height: Int { metrics.depth }

    private static func balanceFactor(_ left: RopeNode, _ right: RopeNode) -> Int {
        left.height - right.height
    }

    private static func makeBranch(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        // Coalesce adjacent small leaves to prevent fragmentation after many small edits.
        if case .leaf(let lText) = left.storage,
           case .leaf(let rText) = right.storage,
           left.metrics.utf8Length + right.metrics.utf8Length <= mergeLeafUTF8
        {
            return RopeNode(leaf: lText + rText)
        }
        return RopeNode(left: left, right: right)
    }

    private static func rebalance(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        let diff = balanceFactor(left, right)
        if diff > 1 {
            guard case .branch(let ll, let lr) = left.storage else {
                return makeBranch(left, right)
            }
            if balanceFactor(ll, lr) < 0, case .branch(let lrl, let lrr) = lr.storage {
                return makeBranch(makeBranch(ll, lrl), makeBranch(lrr, right))
            }
            return makeBranch(ll, makeBranch(lr, right))
        } else if diff < -1 {
            guard case .branch(let rl, let rr) = right.storage else {
                return makeBranch(left, right)
            }
            if balanceFactor(rl, rr) > 0, case .branch(let rll, let rlr) = rl.storage {
                return makeBranch(makeBranch(left, rll), makeBranch(rlr, rr))
            }
            return makeBranch(makeBranch(left, rl), rr)
        }
        return makeBranch(left, right)
    }

    /// Joins two AVL-balanced rope trees in O(|height(left) - height(right)|) = O(log n).
    static func join(_ left: RopeNode?, _ right: RopeNode?) -> RopeNode? {
        guard let left else { return right }
        guard let right else { return left }

        if left.height > right.height + 1 {
            guard case .branch(let ll, let lr) = left.storage else {
                return rebalance(left, right)
            }
            let joinedRight = join(lr, right)!
            return rebalance(ll, joinedRight)
        } else if right.height > left.height + 1 {
            guard case .branch(let rl, let rr) = right.storage else {
                return rebalance(left, right)
            }
            let joinedLeft = join(left, rl)!
            return rebalance(joinedLeft, rr)
        }
        return rebalance(left, right)
    }

    /// Splits a subtree at UTF-8 byte offset `offset` (clamped to `[0, utf8Length]`, aligned down to scalar boundary).
    func split(atUTF8 offset: Int) -> (RopeNode?, RopeNode?) {
        if offset <= 0 {
            return (nil, self)
        }
        if offset >= metrics.utf8Length {
            return (self, nil)
        }
        switch storage {
        case .leaf(let text):
            let utf8 = text.utf8
            var idx = utf8.index(utf8.startIndex, offsetBy: offset)
            while idx > utf8.startIndex && (utf8[idx] & 0xC0) == 0x80 {
                idx = utf8.index(before: idx)
            }
            let leftText = String(text[utf8.startIndex..<idx])
            let rightText = String(text[idx..<utf8.endIndex])
            return (RopeNode.makeLeaf(leftText), RopeNode.makeLeaf(rightText))

        case .branch(let left, let right):
            let leftLen = left.metrics.utf8Length
            if offset == leftLen {
                return (left, right)
            } else if offset < leftLen {
                let (ll, lr) = left.split(atUTF8: offset)
                return (ll, RopeNode.join(lr, right))
            } else {
                let (rl, rr) = right.split(atUTF8: offset - leftLen)
                return (RopeNode.join(left, rl), rr)
            }
        }
    }

    func collect(into result: inout String) {
        switch storage {
        case .leaf(let text):
            result.append(text)
        case .branch(let left, let right):
            left.collect(into: &result)
            right.collect(into: &result)
        }
    }

    func collectSlice(utf8Start: Int, utf8End: Int, into result: inout String) {
        let clampedStart = max(0, utf8Start)
        let clampedEnd = min(metrics.utf8Length, utf8End)
        guard clampedStart < clampedEnd else { return }

        if clampedStart == 0 && clampedEnd == metrics.utf8Length {
            collect(into: &result)
            return
        }

        switch storage {
        case .leaf(let text):
            let utf8 = text.utf8
            var s = utf8.index(utf8.startIndex, offsetBy: clampedStart)
            var e = utf8.index(utf8.startIndex, offsetBy: clampedEnd)
            while s > utf8.startIndex && (utf8[s] & 0xC0) == 0x80 {
                s = utf8.index(before: s)
            }
            while e < utf8.endIndex && (utf8[e] & 0xC0) == 0x80 {
                e = utf8.index(after: e)
            }
            if s < e {
                result.append(contentsOf: text[s..<e])
            }

        case .branch(let left, let right):
            let leftLen = left.metrics.utf8Length
            if clampedStart < leftLen {
                left.collectSlice(
                    utf8Start: clampedStart,
                    utf8End: min(clampedEnd, leftLen),
                    into: &result
                )
            }
            if clampedEnd > leftLen {
                right.collectSlice(
                    utf8Start: max(0, clampedStart - leftLen),
                    utf8End: clampedEnd - leftLen,
                    into: &result
                )
            }
        }
    }

    /// Returns the UTF-8 byte offset of the `nth` (0-based) `\n` in this subtree, or `nil` if fewer than `nth + 1` newlines.
    func utf8OffsetOfNewline(_ nth: Int) -> Int? {
        guard nth >= 0 && nth < metrics.newlineCount else { return nil }
        switch storage {
        case .leaf(let text):
            var seen = 0
            var byteOffset = 0
            for byte in text.utf8 {
                if byte == 0x0A {
                    if seen == nth {
                        return byteOffset
                    }
                    seen += 1
                }
                byteOffset += 1
            }
            return nil

        case .branch(let left, let right):
            let leftNewlines = left.metrics.newlineCount
            if nth < leftNewlines {
                return left.utf8OffsetOfNewline(nth)
            }
            guard let rightPos = right.utf8OffsetOfNewline(nth - leftNewlines) else {
                return nil
            }
            return left.metrics.utf8Length + rightPos
        }
    }

    /// Counts newlines strictly before UTF-8 byte offset `offset`.
    func newlineCountBefore(utf8Offset offset: Int) -> Int {
        if offset <= 0 { return 0 }
        if offset >= metrics.utf8Length { return metrics.newlineCount }
        switch storage {
        case .leaf(let text):
            var count = 0
            var i = 0
            for byte in text.utf8 {
                if i >= offset { break }
                if byte == 0x0A { count += 1 }
                i += 1
            }
            return count

        case .branch(let left, let right):
            let leftLen = left.metrics.utf8Length
            if offset <= leftLen {
                return left.newlineCountBefore(utf8Offset: offset)
            }
            return left.metrics.newlineCount + right.newlineCountBefore(utf8Offset: offset - leftLen)
        }
    }

    /// Converts a UTF-16 code unit offset in this subtree to the corresponding UTF-8 byte offset.
    func utf8Offset(forUTF16Offset target: Int) -> Int {
        if target <= 0 { return 0 }
        if target >= metrics.utf16Length { return metrics.utf8Length }
        switch storage {
        case .leaf(let text):
            var utf16Seen = 0
            var utf8Seen = 0
            for scalar in text.unicodeScalars {
                let u16 = scalar.utf16.count
                if utf16Seen + u16 > target {
                    return utf8Seen
                }
                utf16Seen += u16
                utf8Seen += scalar.utf8.count
                if utf16Seen == target {
                    return utf8Seen
                }
            }
            return utf8Seen

        case .branch(let left, let right):
            let leftUTF16 = left.metrics.utf16Length
            if target <= leftUTF16 {
                return left.utf8Offset(forUTF16Offset: target)
            }
            return left.metrics.utf8Length + right.utf8Offset(forUTF16Offset: target - leftUTF16)
        }
    }

    /// Converts a UTF-8 byte offset in this subtree to the corresponding UTF-16 code unit offset.
    func utf16Offset(forUTF8Offset target: Int) -> Int {
        if target <= 0 { return 0 }
        if target >= metrics.utf8Length { return metrics.utf16Length }
        switch storage {
        case .leaf(let text):
            var utf8Seen = 0
            var utf16Seen = 0
            for scalar in text.unicodeScalars {
                let u8 = scalar.utf8.count
                if utf8Seen + u8 > target {
                    return utf16Seen
                }
                utf8Seen += u8
                utf16Seen += scalar.utf16.count
                if utf8Seen == target {
                    return utf16Seen
                }
            }
            return utf16Seen

        case .branch(let left, let right):
            let leftUTF8 = left.metrics.utf8Length
            if target <= leftUTF8 {
                return left.utf16Offset(forUTF8Offset: target)
            }
            return left.metrics.utf16Length + right.utf16Offset(forUTF8Offset: target - leftUTF8)
        }
    }
}

/// Pure-Swift persistent, balanced binary-tree `Rope` with O(log n) `insert`, `delete`, `slice`,
/// line-count / UTF-8 / UTF-16 weight tracking, and O(1) undo-friendly COW snapshots.
///
/// Mirrors the persistent rope architecture in `packages/native/src/rope.zig`.
public struct Rope: Sendable, CustomStringConvertible {
    private var root: RopeNode?

    public init() {
        self.root = nil
    }

    public init(_ text: String) {
        self.root = RopeNode.makeLeaf(text)
    }

    private init(root: RopeNode?) {
        self.root = root
    }

    /// Aggregate metrics of the entire rope.
    public var metrics: RopeMetrics {
        root?.metrics ?? .zero
    }

    public var isEmpty: Bool {
        utf8Count == 0
    }

    /// Total UTF-8 byte count.
    public var utf8Count: Int {
        root?.metrics.utf8Length ?? 0
    }

    /// Total UTF-16 code unit count (matching JavaScript `String.length`).
    public var utf16Count: Int {
        root?.metrics.utf16Length ?? 0
    }

    /// Total number of `\n` line breaks.
    public var newlineCount: Int {
        root?.metrics.newlineCount ?? 0
    }

    /// Number of logical lines (`newlineCount + 1`). An empty rope has 1 empty line.
    public var lineCount: Int {
        newlineCount + 1
    }

    /// Tree height; guaranteed O(log n).
    public var depth: Int {
        root?.metrics.depth ?? 0
    }

    /// Number of leaf chunks in the rope.
    public var leafCount: Int {
        root?.metrics.leafCount ?? 0
    }

    /// Materializes the entire text as a `String`.
    public var text: String {
        guard let root else { return "" }
        var result = ""
        result.reserveCapacity(root.metrics.utf8Length)
        root.collect(into: &result)
        return result
    }

    public var description: String {
        text
    }

    /// Returns an O(1) persistent immutable snapshot of this rope for undo/redo stacks.
    public func snapshot() -> Rope {
        self
    }

    /// Concatenates two ropes in O(log n) time while maintaining tree balance.
    public static func concat(_ lhs: Rope, _ rhs: Rope) -> Rope {
        Rope(root: RopeNode.join(lhs.root, rhs.root))
    }

    /// Splits the rope at UTF-8 byte offset `offset` in O(log n) time.
    public func split(atUTF8 offset: Int) -> (Rope, Rope) {
        guard let root else { return (Rope(), Rope()) }
        let (l, r) = root.split(atUTF8: offset)
        return (Rope(root: l), Rope(root: r))
    }

    /// Returns a new rope with `text` inserted at UTF-8 byte offset `offset` in O(log n) time.
    public func inserting(_ text: String, atUTF8 offset: Int) -> Rope {
        guard !text.isEmpty else { return self }
        let middle = RopeNode.makeLeaf(text)
        guard let root else { return Rope(root: middle) }
        let clamped = max(0, min(offset, root.metrics.utf8Length))
        if clamped == 0 {
            return Rope(root: RopeNode.join(middle, root))
        }
        if clamped == root.metrics.utf8Length {
            return Rope(root: RopeNode.join(root, middle))
        }
        let (left, right) = root.split(atUTF8: clamped)
        return Rope(root: RopeNode.join(RopeNode.join(left, middle), right))
    }

    /// Mutating O(log n) insert at a UTF-8 byte offset.
    public mutating func insert(_ text: String, atUTF8 offset: Int) {
        self = inserting(text, atUTF8: offset)
    }

    /// Returns a new rope with `text` inserted at UTF-16 code unit offset `offset` in O(log n) time.
    public func inserting(_ text: String, atUTF16 offset: Int) -> Rope {
        inserting(text, atUTF8: utf8Offset(forUTF16Offset: offset))
    }

    /// Mutating O(log n) insert at a UTF-16 code unit offset.
    public mutating func insert(_ text: String, atUTF16 offset: Int) {
        self = inserting(text, atUTF16: offset)
    }

    /// Returns a new rope with UTF-8 byte range `range` deleted in O(log n) time.
    public func deleting(utf8Range range: Range<Int>) -> Rope {
        guard let root else { return self }
        let start = max(0, min(range.lowerBound, root.metrics.utf8Length))
        let end = max(start, min(range.upperBound, root.metrics.utf8Length))
        guard start < end else { return self }
        if start == 0 && end == root.metrics.utf8Length {
            return Rope()
        }
        let (left, remainder) = root.split(atUTF8: start)
        let (_, right) = remainder?.split(atUTF8: end - start) ?? (nil, nil)
        return Rope(root: RopeNode.join(left, right))
    }

    /// Mutating O(log n) delete of a UTF-8 byte range.
    public mutating func delete(utf8Range range: Range<Int>) {
        self = deleting(utf8Range: range)
    }

    /// Returns a new rope with UTF-16 code unit range `range` deleted in O(log n) time.
    public func deleting(utf16Range range: Range<Int>) -> Rope {
        let start = utf8Offset(forUTF16Offset: range.lowerBound)
        let end = utf8Offset(forUTF16Offset: range.upperBound)
        return deleting(utf8Range: start..<end)
    }

    /// Mutating O(log n) delete of a UTF-16 code unit range.
    public mutating func delete(utf16Range range: Range<Int>) {
        self = deleting(utf16Range: range)
    }

    /// Returns a new rope with `utf8Range` replaced by `text` in O(log n) time.
    public func replacing(utf8Range range: Range<Int>, with text: String) -> Rope {
        let start = max(0, min(range.lowerBound, utf8Count))
        let end = max(start, min(range.upperBound, utf8Count))
        guard let root else {
            return Rope(text)
        }
        let (left, remainder) = root.split(atUTF8: start)
        let (_, right) = remainder?.split(atUTF8: end - start) ?? (nil, nil)
        let middle = RopeNode.makeLeaf(text)
        return Rope(root: RopeNode.join(RopeNode.join(left, middle), right))
    }

    /// Extracts a substring covering UTF-8 byte range `utf8Range` in O(log n + k) time.
    public func slice(utf8Range range: Range<Int>) -> String {
        guard let root else { return "" }
        let start = max(0, min(range.lowerBound, root.metrics.utf8Length))
        let end = max(start, min(range.upperBound, root.metrics.utf8Length))
        guard start < end else { return "" }
        var result = ""
        result.reserveCapacity(end - start)
        root.collectSlice(utf8Start: start, utf8End: end, into: &result)
        return result
    }

    /// Extracts a substring covering UTF-16 code unit range `utf16Range` in O(log n + k) time.
    public func slice(utf16Range range: Range<Int>) -> String {
        let start = utf8Offset(forUTF16Offset: range.lowerBound)
        let end = utf8Offset(forUTF16Offset: range.upperBound)
        return slice(utf8Range: start..<end)
    }

    /// Returns the UTF-8 byte range of 0-based logical line `lineIndex`, excluding any trailing `\n`.
    public func lineRange(at lineIndex: Int) -> Range<Int>? {
        guard lineIndex >= 0 && lineIndex < lineCount else { return nil }
        guard let root else {
            return lineIndex == 0 ? 0..<0 : nil
        }
        let start: Int
        if lineIndex == 0 {
            start = 0
        } else {
            guard let prevNewline = root.utf8OffsetOfNewline(lineIndex - 1) else { return nil }
            start = prevNewline + 1
        }
        let end: Int
        if lineIndex < root.metrics.newlineCount {
            guard let nextNewline = root.utf8OffsetOfNewline(lineIndex) else { return nil }
            end = nextNewline
        } else {
            end = root.metrics.utf8Length
        }
        return start..<end
    }

    /// Returns the UTF-8 byte range of 0-based logical line `lineIndex`, including its trailing `\n` if present.
    public func lineRangeIncludingNewline(at lineIndex: Int) -> Range<Int>? {
        guard let range = lineRange(at: lineIndex) else { return nil }
        let end = lineIndex < newlineCount ? range.upperBound + 1 : range.upperBound
        return range.lowerBound..<end
    }

    /// Returns the UTF-16 code unit range of 0-based logical line `lineIndex`, excluding any trailing `\n`.
    public func lineUTF16Range(at lineIndex: Int) -> Range<Int>? {
        guard let utf8Range = lineRange(at: lineIndex) else { return nil }
        return utf16Offset(forUTF8Offset: utf8Range.lowerBound)..<utf16Offset(forUTF8Offset: utf8Range.upperBound)
    }

    /// Returns the text of 0-based logical line `lineIndex`, excluding any trailing `\n`.
    public func line(at lineIndex: Int) -> String? {
        guard let range = lineRange(at: lineIndex) else { return nil }
        return slice(utf8Range: range)
    }

    /// Returns the 0-based logical line index containing UTF-8 byte offset `offset`.
    public func lineIndex(forUTF8Offset offset: Int) -> Int {
        guard let root else { return 0 }
        return root.newlineCountBefore(utf8Offset: max(0, min(offset, root.metrics.utf8Length)))
    }

    /// Returns the 0-based logical line index containing UTF-16 code unit offset `offset`.
    public func lineIndex(forUTF16Offset offset: Int) -> Int {
        lineIndex(forUTF8Offset: utf8Offset(forUTF16Offset: offset))
    }

    /// Converts a UTF-16 code unit offset to a UTF-8 byte offset in O(log n) time.
    public func utf8Offset(forUTF16Offset offset: Int) -> Int {
        guard let root else { return 0 }
        return root.utf8Offset(forUTF16Offset: offset)
    }

    /// Converts a UTF-8 byte offset to a UTF-16 code unit offset in O(log n) time.
    public func utf16Offset(forUTF8Offset offset: Int) -> Int {
        guard let root else { return 0 }
        return root.utf16Offset(forUTF8Offset: offset)
    }
}

extension Rope: Equatable {
    public static func == (lhs: Rope, rhs: Rope) -> Bool {
        if lhs.root === rhs.root { return true }
        let lm = lhs.metrics
        let rm = rhs.metrics
        guard lm.utf8Length == rm.utf8Length,
              lm.utf16Length == rm.utf16Length,
              lm.newlineCount == rm.newlineCount
        else {
            return false
        }
        return lhs.text == rhs.text
    }
}

extension Rope: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
    }
}

// MARK: - Internal Self-Contained Text Measurement & Grapheme Helpers

/// Display-width measurement policy matching OpenTUI's `WidthMethod` without colliding with sibling modules.
public enum TextWidthMethod: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case wcwidth = "wcwidth"
    case unicode = "unicode"
    case unicodeWide = "unicode-wide"
}

internal enum _TextEngineMetrics {
    /// Normalizes CRLF and lone CR line endings to LF (`\n`), matching upstream OpenTUI buffer ingestion.
    static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let s = scalars[i]
            if s.value == 0x0D {
                let next = scalars.index(after: i)
                if next < scalars.endIndex && scalars[next].value == 0x0A {
                    i = next
                }
                out.append("\n")
            } else {
                out.unicodeScalars.append(s)
            }
            i = scalars.index(after: i)
        }
        return out
    }

    /// Returns whether a Unicode scalar is a zero-width combining/control/format scalar.
    static func isZeroWidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0x0000 || v == 0x200B || v == 0x200C || v == 0x200D || v == 0x2060 || v == 0xFEFF {
            return true
        }
        // Combining Diacritical Marks & extensions
        if (0x0300...0x036F).contains(v)
            || (0x1AB0...0x1AFF).contains(v)
            || (0x1DC0...0x1DFF).contains(v)
            || (0x20D0...0x20FF).contains(v)
            || (0xFE20...0xFE2F).contains(v)
        {
            return true
        }
        // Variation selectors
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) {
            return true
        }
        // Emoji skin tone modifiers (part of emoji cluster)
        if (0x1F3FB...0x1F3FF).contains(v) {
            return true
        }
        // C0/C1 control characters (excluding \t and \n which are handled explicitly)
        if v < 0x20 || (0x7F...0x9F).contains(v) {
            return true
        }
        return false
    }

    /// Returns whether a scalar has East Asian Wide / Fullwidth or Emoji presentation width = 2.
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x1100 { return false }
        if (0x1100...0x115F).contains(v)
            || v == 0x2329 || v == 0x232A
            || (0x231A...0x231B).contains(v)
            || (0x23E9...0x23EC).contains(v)
            || v == 0x23F0 || v == 0x23F3
            || (0x25FD...0x25FE).contains(v)
            || (0x2614...0x2615).contains(v)
            || (0x2648...0x2653).contains(v)
            || v == 0x267F || v == 0x2693 || v == 0x26A1
            || (0x26AA...0x26AB).contains(v)
            || (0x26BD...0x26BE).contains(v)
            || (0x26C4...0x26C5).contains(v)
            || v == 0x26CE || v == 0x26D4 || v == 0x26EA
            || (0x26F2...0x26F3).contains(v)
            || v == 0x26F5 || v == 0x26FA || v == 0x26FD
            || v == 0x2705 || (0x270A...0x270B).contains(v)
            || v == 0x2728 || v == 0x274C || v == 0x274E
            || (0x2753...0x2755).contains(v) || v == 0x2757
            || (0x2795...0x2797).contains(v) || v == 0x27B0 || v == 0x27BF
            || (0x2B1B...0x2B1C).contains(v) || v == 0x2B50 || v == 0x2B55
            || (0x2E80...0x303E).contains(v)
            || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0xA4CF).contains(v)
            || (0xA960...0xA97C).contains(v)
            || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE19).contains(v)
            || (0xFE30...0xFE6F).contains(v)
            || (0xFF01...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
            || (0x1B000...0x1B122).contains(v)
            || (0x1F004...0x1F0CF).contains(v)
            || (0x1F18E...0x1F251).contains(v)
            || (0x1F300...0x1FAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v)
        {
            return true
        }
        return false
    }

    /// Display-cell width of a single extended grapheme cluster (not `\n`).
    static func graphemeWidth(
        _ character: Character,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> Int {
        if character == "\t" {
            return max(1, tabWidth)
        }
        if character == "\n" || character == "\r" || character == "\r\n" {
            return 1
        }
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.count == 1 {
            if first.value >= 0x20 && first.value <= 0x7E {
                return 1
            }
            if isZeroWidthScalar(first) {
                return 0
            }
            return isWideScalar(first) ? 2 : 1
        }

        // Regional indicator flag pairs (e.g. 🇺🇸)
        if scalars.count == 2 {
            let second = scalars[scalars.index(after: scalars.startIndex)]
            if (0x1F1E6...0x1F1FF).contains(first.value) && (0x1F1E6...0x1F1FF).contains(second.value) {
                return 2
            }
        }

        // Explicit emoji presentation selector (U+FE0F) makes symbol wide (2 cells),
        // unless widthMethod == .wcwidth on BMP non-wide symbols.
        let hasVS16 = scalars.contains { $0.value == 0xFE0F }
        let hasVS15 = scalars.contains { $0.value == 0xFE0E }
        let hasZWJ = scalars.contains { $0.value == 0x200D }
        let hasKeycap = scalars.contains { $0.value == 0x20E3 }

        if hasKeycap {
            return widthMethod == .wcwidth ? 1 : 2
        }
        if hasZWJ {
            return 2
        }
        if hasVS15 {
            return 1
        }
        if hasVS16 {
            return widthMethod == .wcwidth ? (isWideScalar(first) ? 2 : 1) : 2
        }
        if isWideScalar(first) {
            return 2
        }
        if isZeroWidthScalar(first) {
            return 0
        }
        return 1
    }

    /// Display width of a single line (no `\n`).
    static func lineDisplayWidth(
        _ line: String,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> Int {
        var width = 0
        for ch in line {
            width += graphemeWidth(ch, tabWidth: tabWidth, widthMethod: widthMethod)
        }
        return width
    }

    /// Total document display width where every `\n` counts as 1 cell (OpenTUI document cell offset space).
    static func documentDisplayWidth(
        _ text: String,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> Int {
        var width = 0
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                width += 1
            } else {
                width += graphemeWidth(ch, tabWidth: tabWidth, widthMethod: widthMethod)
            }
        }
        return width
    }

    /// Total display width of all lines excluding newlines (matching `TextBuffer.getLength()`).
    static func totalContentWidth(
        _ text: String,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> Int {
        var width = 0
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                continue
            }
            width += graphemeWidth(ch, tabWidth: tabWidth, widthMethod: widthMethod)
        }
        return width
    }

    /// Detailed cluster record within a single logical line (no `\n`).
    struct LineCluster: Sendable {
        let character: Character
        let colStart: Int
        let width: Int
        let utf8Start: Int
        let utf8Length: Int
        let utf16Start: Int
        let utf16Length: Int

        var colEnd: Int { colStart + width }
        var utf8End: Int { utf8Start + utf8Length }
        var utf16End: Int { utf16Start + utf16Length }
    }

    static func lineClusters(
        _ line: String,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> [LineCluster] {
        var clusters: [LineCluster] = []
        clusters.reserveCapacity(line.count)
        var col = 0
        var u8 = 0
        var u16 = 0
        for ch in line {
            let w = graphemeWidth(ch, tabWidth: tabWidth, widthMethod: widthMethod)
            let b = ch.utf8.count
            let c16 = ch.utf16.count
            clusters.append(LineCluster(
                character: ch,
                colStart: col,
                width: w,
                utf8Start: u8,
                utf8Length: b,
                utf16Start: u16,
                utf16Length: c16
            ))
            col += w
            u8 += b
            u16 += c16
        }
        return clusters
    }

    /// Snaps a column within a line down to a valid grapheme boundary.
    static func snapColDown(
        _ col: Int,
        in line: String,
        tabWidth: Int = 2,
        widthMethod: TextWidthMethod = .unicode
    ) -> Int {
        if col <= 0 { return 0 }
        var currentCol = 0
        for ch in line {
            let w = graphemeWidth(ch, tabWidth: tabWidth, widthMethod: widthMethod)
            if currentCol + w > col {
                return currentCol
            }
            currentCol += w
            if currentCol == col {
                return currentCol
            }
        }
        return currentCol
    }

    /// Returns whether a scalar is a CJK ideograph / Kana / Hangul character.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x30FF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x2FA1F).contains(v)
    }

    enum WordClass {
        case whitespace
        case asciiWord
        case cjk
        case punctuation
    }

    static func classifyWord(_ ch: Character) -> WordClass {
        guard let scalar = ch.unicodeScalars.first else { return .punctuation }
        let v = scalar.value
        if v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D || v == 0xA0 || v == 0x3000 {
            return .whitespace
        }
        if isCJK(scalar) {
            return .cjk
        }
        if (v >= 0x30 && v <= 0x39)
            || (v >= 0x41 && v <= 0x5A)
            || (v >= 0x61 && v <= 0x7A)
            || v == 0x5F
            || scalar.properties.isAlphabetic
            || scalar.properties.numericType != nil
        {
            return .asciiWord
        }
        return .punctuation
    }

    /// Ghostty-style word boundary separators used by double-click word selection (`text-buffer-view.zig`).
    static func isSelectionWordBoundary(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x20, 0x09, 0x27, 0x22, 0x2502, 0x60, 0x7C, 0x3A, 0x3B, 0x2C,
             0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E, 0x24:
            return true
        default:
            return false
        }
    }

    /// Returns whether a character is a wrap break opportunity in word-wrap mode.
    static func isWordWrapBreak(_ ch: Character) -> Bool {
        switch classifyWord(ch) {
        case .whitespace, .cjk:
            return true
        case .punctuation:
            guard let scalar = ch.unicodeScalars.first else { return false }
            return scalar == "-" || scalar == "/" || scalar == "\\"
        case .asciiWord:
            return false
        }
    }
}
