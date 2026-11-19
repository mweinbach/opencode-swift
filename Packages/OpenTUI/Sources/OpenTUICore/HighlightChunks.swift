/// Tree-sitter highlight range and HAST (Hypertext Abstract Syntax Tree) converters to `[TextChunk]`
/// and `StyledText`, matching `packages/core/src/lib/tree-sitter-styled-text.ts`,
/// `packages/core/src/lib/tree-sitter/types.ts`, and `packages/core/src/lib/hast-styled-text.ts`.

// MARK: - Tree-Sitter Highlight Types

/// Line-local highlight span with start/end column offsets and scope group.
// parity: core/src/lib/tree-sitter/types.ts#HighlightRange [status=implemented hash=447be4613ff8]
public struct HighlightRange: Equatable, Hashable, Sendable, Codable {
    public var startCol: Int
    public var endCol: Int
    public var group: String

    public init(startCol: Int, endCol: Int, group: String) {
        self.startCol = startCol
        self.endCol = endCol
        self.group = group
    }
}

extension SimpleHighlight {
    /// Labeled convenience initializer matching `SimpleHighlight(start:end:group:meta:)`.
    public init(start: Int, end: Int, group: String, meta: HighlightMeta? = nil) {
        self.init(start, end, group, meta)
    }
}

/// Concealment configuration for tree-sitter text chunk conversion.
public struct ConcealOptions: Equatable, Hashable, Sendable, Codable {
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// Options for `treeSitterToStyledText`.
// parity: core/src/lib/tree-sitter-styled-text.ts#TreeSitterToStyledTextOptions [status=implemented hash=fc94d8a6ba34]
public struct TreeSitterToStyledTextOptions: Equatable, Hashable, Sendable, Codable {
    public var conceal: ConcealOptions?
    public var baseHighlight: String?

    public init(conceal: ConcealOptions? = nil, baseHighlight: String? = nil) {
        self.conceal = conceal
        self.baseHighlight = baseHighlight
    }
}

/// Detailed output returned by `treeSitterToTextChunksWithMetadata`, including source ranges and style group sets.
public struct TreeSitterChunkResult: Equatable, Hashable, Sendable {
    public var chunks: [TextChunk]
    public var ranges: [Range<Int>]
    public var names: [[String]]

    public init(chunks: [TextChunk], ranges: [Range<Int>], names: [[String]]) {
        self.chunks = chunks
        self.ranges = ranges
        self.names = names
    }
}

// MARK: - Tree-Sitter Highlight Conversion

private enum BoundaryKind: Int {
    case end = 0
    case start = 1
}

private struct HighlightBoundary {
    let offset: Int
    let kind: BoundaryKind
    let highlightIndex: Int
}

@inline(__always)
private func scopeSpecificity(_ group: String) -> Int {
    var count = 1
    for byte in group.utf8 where byte == UInt8(ascii: ".") {
        count += 1
    }
    return count
}

@inline(__always)
private func shouldSuppressInInjection(group: String, meta: HighlightMeta?) -> Bool {
    if meta?.isInjection == true {
        return false
    }
    return group == "markup.raw.block"
}

@inline(__always)
private func textAttributes(for style: StyleDefinition?) -> UInt32 {
    guard let style else { return TextAttributes.none }
    return createTextAttributes(
        bold: style.bold ?? false,
        italic: style.italic ?? false,
        underline: style.underline ?? false,
        dim: style.dim ?? false,
        strikethrough: style.strikethrough ?? false
    )
}

@inline(__always)
private func utf16Slice(_ units: [UInt16], start: Int, end: Int) -> String {
    let lo = max(0, min(start, units.count))
    let hi = max(lo, min(end, units.count))
    if lo == hi { return "" }
    return String(decoding: units[lo..<hi], as: UTF16.self)
}

private func mergeStyleDefinition(_ base: inout StyleDefinition, overlay: StyleDefinition) {
    if let fg = overlay.fg { base.fg = fg }
    if let bg = overlay.bg { base.bg = bg }
    if let bold = overlay.bold { base.bold = bold }
    if let italic = overlay.italic { base.italic = italic }
    if let underline = overlay.underline { base.underline = underline }
    if let dim = overlay.dim { base.dim = dim }
    if let strikethrough = overlay.strikethrough { base.strikethrough = strikethrough }
}

private func hasAnyStyleField(_ style: StyleDefinition) -> Bool {
    style.fg != nil
        || style.bg != nil
        || style.bold != nil
        || style.italic != nil
        || style.underline != nil
        || style.dim != nil
        || style.strikethrough != nil
}

/// Converts source text and tree-sitter `SimpleHighlight` ranges into styled `TextChunk` segments,
/// handling nested specificity cascading, injection container suppression, and concealment predicates.
// parity: core/src/lib/tree-sitter-styled-text.ts#treeSitterToTextChunks [status=implemented hash=27232c48b26b]
public func treeSitterToTextChunks(
    content: String,
    highlights: [SimpleHighlight],
    syntaxStyle: SyntaxStyle,
    conceal: ConcealOptions = ConcealOptions(),
    baseHighlight: String? = nil
) -> [TextChunk] {
    treeSitterToTextChunksWithMetadata(
        content: content,
        highlights: highlights,
        syntaxStyle: syntaxStyle,
        conceal: conceal,
        baseHighlight: baseHighlight
    ).chunks
}

/// Full-metadata variant of `treeSitterToTextChunks` returning chunk ranges and resolved scope group names.
public func treeSitterToTextChunksWithMetadata(
    content: String,
    highlights: [SimpleHighlight],
    syntaxStyle: SyntaxStyle,
    conceal: ConcealOptions = ConcealOptions(),
    baseHighlight: String? = nil
) -> TreeSitterChunkResult {
    let utf16 = Array(content.utf16)
    let utf16Count = utf16.count

    var chunks: [TextChunk] = []
    var ranges: [Range<Int>] = []
    var names: [[String]] = []

    let defaultStyle = syntaxStyle.getStyle("default")
    let concealEnabled = conceal.enabled
    let baseStyle = baseHighlight.flatMap { syntaxStyle.getStyle($0) }
    let registeredNames = syntaxStyle.getRegisteredNames()

    var injectionContainerRanges: [Range<Int>] = []
    var boundaries: [HighlightBoundary] = []
    boundaries.reserveCapacity(highlights.count * 2)

    for i in highlights.indices {
        let h = highlights[i]
        if h.start == h.end || h.start > h.end { continue }
        if h.meta?.containsInjection == true {
            injectionContainerRanges.append(h.start..<h.end)
        }
        boundaries.append(HighlightBoundary(offset: h.start, kind: .start, highlightIndex: i))
        boundaries.append(HighlightBoundary(offset: h.end, kind: .end, highlightIndex: i))
    }

    // Sort boundaries by offset ascending, closing ended ranges before opening new ones at the same offset.
    boundaries.sort { lhs, rhs in
        if lhs.offset != rhs.offset {
            return lhs.offset < rhs.offset
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return false
    }

    // Maintain active highlight indices in insertion order to match JS Set iteration semantics.
    var activeHighlights: [Int] = []
    var currentOffset = 0

    for boundary in boundaries {
        if currentOffset < boundary.offset && !activeHighlights.isEmpty {
            let segmentText = utf16Slice(utf16, start: currentOffset, end: boundary.offset)

            var activeGroups: [(group: String, meta: HighlightMeta?, index: Int)] = []
            activeGroups.reserveCapacity(activeHighlights.count)
            for idx in activeHighlights {
                let h = highlights[idx]
                activeGroups.append((group: h.group, meta: h.meta, index: idx))
            }

            let concealHighlight = concealEnabled
                ? activeGroups.first {
                    $0.meta?.conceal != nil || $0.group == "conceal" || $0.group.hasPrefix("conceal.")
                }
                : nil

            if let concealHighlight {
                let replacementText: String
                if let explicit = concealHighlight.meta?.conceal {
                    replacementText = explicit
                } else if concealHighlight.group == "conceal.with.space" {
                    replacementText = " "
                } else {
                    replacementText = ""
                }

                if !replacementText.isEmpty {
                    chunks.append(
                        TextChunk(
                            text: replacementText,
                            fg: defaultStyle?.fg,
                            bg: defaultStyle?.bg,
                            attributes: textAttributes(for: defaultStyle)
                        )
                    )
                    ranges.append(currentOffset..<boundary.offset)
                }
            } else {
                let insideInjectionContainer = injectionContainerRanges.contains { range in
                    currentOffset >= range.lowerBound && currentOffset < range.upperBound
                }

                let validGroups = activeGroups.filter { entry in
                    if insideInjectionContainer && shouldSuppressInInjection(group: entry.group, meta: entry.meta) {
                        return false
                    }
                    return true
                }

                let sortedGroups = validGroups.sorted { lhs, rhs in
                    let aSpec = scopeSpecificity(lhs.group)
                    let bSpec = scopeSpecificity(rhs.group)
                    if aSpec != bSpec { return aSpec < bSpec }
                    return lhs.index < rhs.index
                }

                var mergedStyle = baseStyle ?? StyleDefinition()
                for entry in sortedGroups {
                    if let styleForGroup = syntaxStyle.getStyle(entry.group) {
                        mergeStyleDefinition(&mergedStyle, overlay: styleForGroup)
                    }
                }

                let merged = hasAnyStyleField(mergedStyle)
                let finalStyle = merged ? mergedStyle : defaultStyle

                let strikes: (String) -> Bool = { group in
                    group == "markup.strikethrough"
                        && !registeredNames.contains { $0 == group || $0 == "markup" }
                }
                names.append(
                    merged
                        ? sortedGroups.flatMap { strikes($0.group) ? ["default", $0.group] : [$0.group] }
                        : ["default"]
                )

                chunks.append(
                    TextChunk(
                        text: segmentText,
                        fg: finalStyle?.fg,
                        bg: finalStyle?.bg,
                        attributes: textAttributes(for: finalStyle)
                    )
                )
                ranges.append(currentOffset..<boundary.offset)
            }
        } else if currentOffset < boundary.offset {
            let text = utf16Slice(utf16, start: currentOffset, end: boundary.offset)
            let style = baseStyle ?? defaultStyle
            names.append(["default"])
            chunks.append(
                TextChunk(
                    text: text,
                    fg: style?.fg,
                    bg: style?.bg,
                    attributes: textAttributes(for: style)
                )
            )
            ranges.append(currentOffset..<boundary.offset)
        }

        if boundary.kind == .start {
            if !activeHighlights.contains(boundary.highlightIndex) {
                activeHighlights.append(boundary.highlightIndex)
            }
        } else {
            activeHighlights.removeAll { $0 == boundary.highlightIndex }

            if concealEnabled {
                let h = highlights[boundary.highlightIndex]
                if h.meta?.concealLines != nil {
                    if boundary.offset >= 0 && boundary.offset < utf16Count && utf16[boundary.offset] == 0x0A {
                        currentOffset = boundary.offset + 1
                        continue
                    }
                }

                if let concealVal = h.meta?.conceal {
                    if concealVal == " " {
                        if boundary.offset >= 0 && boundary.offset < utf16Count && utf16[boundary.offset] == 0x20 {
                            currentOffset = boundary.offset + 1
                            continue
                        }
                    } else if concealVal.isEmpty && h.group == "conceal" && h.meta?.isInjection != true {
                        if boundary.offset >= 0 && boundary.offset < utf16Count && utf16[boundary.offset] == 0x20 {
                            currentOffset = boundary.offset + 1
                            continue
                        }
                    }
                }
            }
        }

        currentOffset = boundary.offset
    }

    if currentOffset < utf16Count {
        let text = utf16Slice(utf16, start: currentOffset, end: utf16Count)
        let style = baseStyle ?? defaultStyle
        names.append(["default"])
        chunks.append(
            TextChunk(
                text: text,
                fg: style?.fg,
                bg: style?.bg,
                attributes: textAttributes(for: style)
            )
        )
        ranges.append(currentOffset..<utf16Count)
    }

    return TreeSitterChunkResult(chunks: chunks, ranges: ranges, names: names)
}

/// Converts source text and tree-sitter highlights into a `StyledText` value,
/// falling back to a single `"default"` styled chunk when there are no highlights or `baseHighlight`.
// parity: core/src/lib/tree-sitter-styled-text.ts#treeSitterToStyledText [status=implemented hash=7699ad5a7e8b]
public func treeSitterToStyledText(
    content: String,
    highlights: [SimpleHighlight],
    syntaxStyle: SyntaxStyle,
    options: TreeSitterToStyledTextOptions? = nil
) -> StyledText {
    if !highlights.isEmpty || options?.baseHighlight != nil {
        let chunks = treeSitterToTextChunks(
            content: content,
            highlights: highlights,
            syntaxStyle: syntaxStyle,
            conceal: options?.conceal ?? ConcealOptions(enabled: true),
            baseHighlight: options?.baseHighlight
        )
        return StyledText(chunks: chunks)
    } else {
        let defaultStyle = syntaxStyle.mergeStyles("default")
        let chunk = TextChunk(
            text: content,
            fg: defaultStyle.fg,
            bg: defaultStyle.bg,
            attributes: defaultStyle.attributes
        )
        return StyledText(chunks: [chunk])
    }
}

// MARK: - HAST Styled Text

/// HAST text leaf node matching `HASTText` in `hast-styled-text.ts`.
// parity: core/src/lib/hast-styled-text.ts#HASTText [status=implemented hash=50b50b04a3cb]
public struct HASTText: Equatable, Hashable, Sendable, Codable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

/// HAST element node matching `HASTElement` in `hast-styled-text.ts`.
// parity: core/src/lib/hast-styled-text.ts#HASTElement [status=implemented hash=40454e5bbdf3]
public struct HASTElement: Equatable, Hashable, Sendable, Codable {
    public var tagName: String
    public var properties: [String: String]
    public var children: [HASTNode]

    public init(tagName: String, properties: [String: String] = [:], children: [HASTNode] = []) {
        self.tagName = tagName
        self.properties = properties
        self.children = children
    }
}

/// Hypertext Abstract Syntax Tree node converted into styled terminal `TextChunk`s.
// parity: core/src/lib/hast-styled-text.ts#HASTNode [status=implemented hash=29c6c02098bf]
public indirect enum HASTNode: Equatable, Hashable, Sendable, Codable {
    case element(tagName: String, properties: [String: String], children: [HASTNode])
    case text(String)
    case root([HASTNode])

    public static func element(
        tagName: String,
        className: String? = nil,
        children: [HASTNode] = []
    ) -> HASTNode {
        var props: [String: String] = [:]
        if let className {
            props["className"] = className
        }
        return .element(tagName: tagName, properties: props, children: children)
    }

    public init(_ text: HASTText) {
        self = .text(text.value)
    }

    public init(_ element: HASTElement) {
        self = .element(tagName: element.tagName, properties: element.properties, children: element.children)
    }
}

/// Recursively converts a `HASTNode` tree into `[TextChunk]` using space-separated `className`
/// properties merged through `syntaxStyle`.
public func hastToTextChunks(
    node: HASTNode,
    syntaxStyle: SyntaxStyle,
    parentStyles: [String] = []
) -> [TextChunk] {
    var chunks: [TextChunk] = []

    switch node {
    case .text(let value):
        let stylesToMerge = parentStyles.isEmpty ? ["default"] : parentStyles
        let mergedStyle = syntaxStyle.mergeStyles(stylesToMerge)
        chunks.append(
            TextChunk(
                text: value,
                fg: mergedStyle.fg,
                bg: mergedStyle.bg,
                attributes: mergedStyle.attributes
            )
        )

    case .element(_, let properties, let children):
        var currentStyles = parentStyles
        if let className = properties["className"] ?? properties["class"], !className.isEmpty {
            let classes = className.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            currentStyles.append(contentsOf: classes)
        }
        for child in children {
            chunks.append(contentsOf: hastToTextChunks(node: child, syntaxStyle: syntaxStyle, parentStyles: currentStyles))
        }

    case .root(let children):
        for child in children {
            chunks.append(contentsOf: hastToTextChunks(node: child, syntaxStyle: syntaxStyle, parentStyles: parentStyles))
        }
    }

    return chunks
}

/// Converts a `HASTNode` tree into a `StyledText` container.
// parity: core/src/lib/hast-styled-text.ts#hastToStyledText [status=implemented hash=a5f2e50b46d3]
public func hastToStyledText(_ hast: HASTNode, syntaxStyle: SyntaxStyle) -> StyledText {
    StyledText(chunks: hastToTextChunks(node: hast, syntaxStyle: syntaxStyle))
}
