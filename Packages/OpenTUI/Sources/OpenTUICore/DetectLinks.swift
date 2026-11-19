/// Metadata attached to a syntax highlight capture.
// parity: core/src/lib/tree-sitter/types.ts#HighlightMeta [status=implemented hash=3810d7f01e80]
public struct HighlightMeta: Equatable, Hashable, Sendable, Codable {
    public var isInjection: Bool?
    public var injectionLang: String?
    public var containsInjection: Bool?
    public var conceal: String?
    public var concealLines: String?

    public init(
        isInjection: Bool? = nil,
        injectionLang: String? = nil,
        containsInjection: Bool? = nil,
        conceal: String? = nil,
        concealLines: String? = nil
    ) {
        self.isInjection = isInjection
        self.injectionLang = injectionLang
        self.containsInjection = containsInjection
        self.conceal = conceal
        self.concealLines = concealLines
    }
}

/// A syntax highlight span indexed in UTF-16 code units matching JavaScript string indices.
// parity: core/src/lib/tree-sitter/types.ts#SimpleHighlight [status=implemented hash=ce5c31c24407]
public struct SimpleHighlight: Equatable, Hashable, Sendable, Codable {
    /// Start offset in UTF-16 code units.
    public var start: Int
    /// End offset in UTF-16 code units (exclusive).
    public var end: Int
    /// Scope / capture group name (e.g. `"markup.link.url"`, `"markup.link.label"`, `"conceal"`, `"markup.raw"`).
    public var group: String
    public var meta: HighlightMeta?

    public init(_ start: Int, _ end: Int, _ group: String, _ meta: HighlightMeta? = nil) {
        self.start = start
        self.end = end
        self.group = group
        self.meta = meta
    }
}

/// Source range in UTF-16 code units corresponding to an output `TextChunk`.
public struct LinkSourceRange: Equatable, Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Merged style properties applied to bare HTTP(S) URL chunks during link detection.
public struct LinkMergedStyle: Equatable, Hashable, Sendable, Codable {
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32

    public init(fg: RGBA? = nil, bg: RGBA? = nil, attributes: UInt32 = TextAttributes.none) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

/// Abstraction for resolving merged scope styles (such as `"markup.link.label"`) during `detectLinks`.
public protocol LinkStyleResolving: Sendable {
    func mergeLinkStyles(_ styleNames: [String]) -> LinkMergedStyle?
}

/// Lightweight pure-Swift scope-style lookup table conforming to `LinkStyleResolving`.
public struct LinkStyleTable: LinkStyleResolving, Equatable, Sendable {
    public var styles: [String: StyleAttrs]

    public init(_ styles: [String: StyleAttrs] = [:]) {
        self.styles = styles
    }

    public func mergeLinkStyles(_ styleNames: [String]) -> LinkMergedStyle? {
        var fg: RGBA?
        var bg: RGBA?
        var bold = false
        var italic = false
        var underline = false
        var dim = false
        var blink = false
        var inverse = false
        var reverse = false
        var hidden = false
        var strikethrough = false

        for name in styleNames {
            let resolved: StyleAttrs?
            if let exact = styles[name] {
                resolved = exact
            } else if let dotIndex = name.firstIndex(of: ".") {
                resolved = styles[String(name[..<dotIndex])]
            } else {
                resolved = nil
            }

            guard let style = resolved else { continue }
            if let fgColor = style.fg {
                fg = fgColor.resolved()
            }
            if let bgColor = style.bg {
                bg = bgColor.resolved()
            }
            if let v = style.bold { bold = v }
            if let v = style.italic { italic = v }
            if let v = style.underline { underline = v }
            if let v = style.dim { dim = v }
            if let v = style.blink { blink = v }
            if let v = style.inverse { inverse = v }
            if let v = style.reverse { reverse = v }
            if let v = style.hidden { hidden = v }
            if let v = style.strikethrough { strikethrough = v }
        }

        let attrs = createTextAttributes(
            bold: bold,
            italic: italic,
            underline: underline,
            dim: dim,
            blink: blink,
            inverse: inverse,
            reverse: reverse,
            hidden: hidden,
            strikethrough: strikethrough
        )
        return LinkMergedStyle(fg: fg, bg: bg, attributes: attrs)
    }
}

/// Input context for `detectLinks(_:context:)`.
public struct DetectLinksContext: Sendable {
    public var content: String
    public var highlights: [SimpleHighlight]
    public var sourceRanges: [LinkSourceRange]?
    public var syntaxStyle: (any LinkStyleResolving)?

    public init(
        content: String,
        highlights: [SimpleHighlight] = [],
        sourceRanges: [LinkSourceRange]? = nil,
        syntaxStyle: (any LinkStyleResolving)? = nil
    ) {
        self.content = content
        self.highlights = highlights
        self.sourceRanges = sourceRanges
        self.syntaxStyle = syntaxStyle
    }
}

private struct DetectedLinkRange {
    var start: Int
    var end: Int
    var url: String
    var label: Bool
    var bare: Bool
}

@inline(__always)
private func isMarkdownEscapableASCIIPunctuation(_ unit: UInt16) -> Bool {
    (unit >= 0x21 && unit <= 0x2F)
        || (unit >= 0x3A && unit <= 0x40)
        || (unit >= 0x5B && unit <= 0x60)
        || (unit >= 0x7B && unit <= 0x7E)
}

@inline(__always)
private func isURLScope(_ group: String) -> Bool {
    group == "markup.link.url" || group == "string.special.url"
}

@inline(__always)
private func isJSWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0009...0x000D,
         0x0020,
         0x00A0,
         0x1680,
         0x2000...0x200A,
         0x2028,
         0x2029,
         0x202F,
         0x205F,
         0x3000,
         0xFEFF:
        return true
    default:
        return false
    }
}

@inline(__always)
private func isBareURLTerminator(_ unit: UInt16) -> Bool {
    if isJSWhitespace(unit) {
        return true
    }
    switch unit {
    case 0x3C, 0x3E, 0x22, 0x60: // < > " `
        return true
    default:
        return false
    }
}

@inline(__always)
private func isTrailingURLPunctuation(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x2E, // .
         0x2C, // ,
         0x21, // !
         0x3F, // ?
         0x3B, // ;
         0x3A, // :
         0x5D, // ]
         0x7D, // }
         0x27: // '
        return true
    default:
        return false
    }
}

@inline(__always)
private func isConcealMarkerOnly(_ utf16: [UInt16], start: Int, end: Int) -> Bool {
    let lo = max(0, min(start, utf16.count))
    let hi = max(lo, min(end, utf16.count))
    guard hi > lo else { return false }
    for idx in lo..<hi {
        let u = utf16[idx]
        if u != 0x2A && u != 0x5F && u != 0x7E { // * _ ~
            return false
        }
    }
    return true
}

@inline(__always)
private func asciiLower(_ unit: UInt16) -> UInt16 {
    (unit >= 0x41 && unit <= 0x5A) ? (unit + 32) : unit
}

/// Returns the length of an `http://` (7) or `https://` (8) prefix starting at `index`, or `0` if none.
@inline(__always)
private func httpSchemeLength(_ utf16: [UInt16], at index: Int) -> Int {
    let count = utf16.count
    guard index + 7 <= count else { return 0 }
    if asciiLower(utf16[index]) != 0x68 // h
        || asciiLower(utf16[index + 1]) != 0x74 // t
        || asciiLower(utf16[index + 2]) != 0x74 // t
        || asciiLower(utf16[index + 3]) != 0x70 // p
    {
        return 0
    }
    var offset = index + 4
    if offset < count && asciiLower(utf16[offset]) == 0x73 { // s
        offset += 1
    }
    guard offset + 3 <= count else { return 0 }
    if utf16[offset] == 0x3A // :
        && utf16[offset + 1] == 0x2F // /
        && utf16[offset + 2] == 0x2F // /
    {
        return (offset + 3) - index
    }
    return 0
}

private func containsHTTPPrefix(_ utf16: [UInt16]) -> Bool {
    guard utf16.count >= 7 else { return false }
    var i = 0
    let limit = utf16.count - 7
    while i <= limit {
        let u = utf16[i]
        if (u == 0x68 || u == 0x48) && httpSchemeLength(utf16, at: i) > 0 { // h / H
            return true
        }
        i += 1
    }
    return false
}

@inline(__always)
private func utf16Slice(_ utf16: [UInt16], start: Int, end: Int) -> String {
    let count = utf16.count
    let lo = start < 0 ? max(0, count + start) : min(start, count)
    let hi = end < 0 ? max(0, count + end) : min(end, count)
    guard hi > lo else { return "" }
    return String(decoding: utf16[lo..<hi], as: UTF16.self)
}

@inline(__always)
private func utf16EqualsSlice(_ utf16: [UInt16], start: Int, end: Int, other: [UInt16]) -> Bool {
    let count = utf16.count
    let lo = start < 0 ? max(0, count + start) : min(start, count)
    let hi = end < 0 ? max(0, count + end) : min(end, count)
    let sliceLen = max(0, hi - lo)
    guard sliceLen == other.count else { return false }
    for i in 0..<sliceLen {
        if utf16[lo + i] != other[i] {
            return false
        }
    }
    return true
}

private func utf16IndexOf(_ haystack: [UInt16], needle: [UInt16], fromIndex: Int) -> Int? {
    let hCount = haystack.count
    let nCount = needle.count
    let startPos = max(0, fromIndex)
    if nCount == 0 {
        return min(startPos, hCount)
    }
    guard startPos + nCount <= hCount else { return nil }
    let first = needle[0]
    let lastStart = hCount - nCount
    var i = startPos
    while i <= lastStart {
        if haystack[i] == first {
            var match = true
            var j = 1
            while j < nCount {
                if haystack[i + j] != needle[j] {
                    match = false
                    break
                }
                j += 1
            }
            if match {
                return i
            }
        }
        i += 1
    }
    return nil
}

/// Unescapes backslash-escaped ASCII punctuation in a Markdown inline link destination.
// parity: core/src/lib/detect-links.ts#normalizeMarkdownLinkTarget [status=implemented hash=991d9947ed52]
public func normalizeMarkdownLinkTarget(_ destination: String) -> String {
    let units = Array(destination.utf16)
    guard !units.isEmpty else { return destination }

    var out: [UInt16] = []
    out.reserveCapacity(units.count)
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit == 0x5C, // \
           index + 1 < units.count,
           isMarkdownEscapableASCIIPunctuation(units[index + 1])
        {
            out.append(units[index + 1])
            index += 2
        } else {
            out.append(unit)
            index += 1
        }
    }
    return String(decoding: out, as: UTF16.self)
}

/// Attaches hyperlink metadata to `TextChunk` arrays from syntax highlight URL scopes,
/// Markdown `[label](url)` link associations, and bare `http(s)://` URLs.
///
/// All highlight offsets and `sourceRanges` are interpreted as UTF-16 code-unit offsets
/// matching JavaScript string indices.
// parity: core/src/lib/detect-links.ts#detectLinks [status=implemented hash=3c77b6254638]
public func detectLinks(_ chunks: [TextChunk], context: DetectLinksContext) -> [TextChunk] {
    let utf16 = Array(context.content.utf16)
    let highlights = context.highlights
    let hasBareUrl = containsHTTPPrefix(utf16)
    if !hasBareUrl && !highlights.contains(where: { isURLScope($0.group) }) {
        return chunks
    }

    var ranges: [DetectedLinkRange] = []
    var rawRanges: [(start: Int, end: Int)] = []
    var labels: [Int: (start: Int, end: Int)] = [:]
    var concealedDelimiters: [Int: Int] = [:]

    for highlight in highlights {
        let start = highlight.start
        let end = highlight.end
        let group = highlight.group

        if group == "conceal",
           highlight.meta?.conceal == "",
           isConcealMarkerOnly(utf16, start: start, end: end)
        {
            concealedDelimiters[end] = start
        }
        if group == "markup.raw" || group.hasPrefix("markup.raw.") {
            rawRanges.append((start: start, end: end))
        }
        if group == "markup.link.label" {
            if let existing = labels[end] {
                if start < existing.start {
                    labels[end] = (start: start, end: end)
                }
            } else {
                labels[end] = (start: start, end: end)
            }
        }
        if !isURLScope(group) {
            continue
        }

        let url = utf16Slice(utf16, start: start, end: end)
        if url.isEmpty {
            continue
        }
        ranges.append(DetectedLinkRange(start: start, end: end, url: url, label: false, bare: false))
    }

    let highlightedCount = ranges.count
    for index in 0..<highlightedCount {
        var labelEnd = ranges[index].start
        if labelEnd > 0 && labelEnd <= utf16.count && utf16[labelEnd - 1] == 0x3C { // <
            labelEnd -= 1
        }
        while labelEnd > 0 && labelEnd <= utf16.count && isJSWhitespace(utf16[labelEnd - 1]) {
            labelEnd -= 1
        }
        guard labelEnd >= 2,
              labelEnd <= utf16.count,
              utf16[labelEnd - 1] == 0x28, // (
              utf16[labelEnd - 2] == 0x5D // ]
        else {
            continue
        }

        guard let label = labels[labelEnd - 2] else { continue }
        let normalizedUrl = normalizeMarkdownLinkTarget(ranges[index].url)
        ranges[index].url = normalizedUrl
        ranges.append(
            DetectedLinkRange(
                start: label.start,
                end: label.end,
                url: normalizedUrl,
                label: true,
                bare: false
            )
        )
    }

    if hasBareUrl {
        rawRanges.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.end > b.end
        }
        ranges.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.end > b.end
        }

        var rawIndex = 0
        var highlightedIndex = 0
        var pos = 0
        let count = utf16.count

        while pos < count {
            let u = utf16[pos]
            guard u == 0x68 || u == 0x48 else { // h / H
                pos += 1
                continue
            }
            let prefixLen = httpSchemeLength(utf16, at: pos)
            guard prefixLen > 0 else {
                pos += 1
                continue
            }

            var matchEnd = pos + prefixLen
            while matchEnd < count && !isBareURLTerminator(utf16[matchEnd]) {
                matchEnd += 1
            }

            guard matchEnd > pos + prefixLen else {
                pos += 1
                continue
            }

            let start = pos
            pos = matchEnd

            var openParens = 0
            var closeParens = 0
            for idx in start..<matchEnd {
                let ch = utf16[idx]
                if ch == 0x28 { openParens += 1 } // (
                if ch == 0x29 { closeParens += 1 } // )
            }

            var urlEnd = matchEnd
            while urlEnd > start {
                if let delimiterStart = concealedDelimiters[urlEnd], delimiterStart >= start {
                    urlEnd = delimiterStart
                    continue
                }
                let last = utf16[urlEnd - 1]
                if last == 0x29 && closeParens > openParens { // )
                    closeParens -= 1
                } else if !isTrailingURLPunctuation(last) {
                    break
                }
                urlEnd -= 1
            }

            let end = urlEnd
            if end <= start {
                continue
            }

            while rawIndex < rawRanges.count && rawRanges[rawIndex].end <= start {
                rawIndex += 1
            }
            if rawIndex < rawRanges.count && rawRanges[rawIndex].start < end {
                continue
            }

            while highlightedIndex < ranges.count && ranges[highlightedIndex].end <= start {
                highlightedIndex += 1
            }
            if highlightedIndex < ranges.count && ranges[highlightedIndex].start < end {
                continue
            }

            let url = String(decoding: utf16[start..<end], as: UTF16.self)
            ranges.append(DetectedLinkRange(start: start, end: end, url: url, label: false, bare: true))
        }
    }

    if ranges.isEmpty {
        return chunks
    }

    ranges.sort { a, b in
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end > b.end }
        return a.label && !b.label
    }

    let bareStyle = context.syntaxStyle?.mergeLinkStyles(["markup.link.label"])
    var linkedChunks: [TextChunk] = []
    linkedChunks.reserveCapacity(chunks.count)

    var contentPos = 0
    var rangeIndex = 0

    for index in chunks.indices {
        let chunk = chunks[index]
        if chunk.text.isEmpty || chunk.link != nil {
            linkedChunks.append(chunk)
            continue
        }

        let chunkUTF16 = Array(chunk.text.utf16)
        let providedRange: LinkSourceRange? =
            if let sourceRanges = context.sourceRanges, index < sourceRanges.count {
                sourceRanges[index]
            } else {
                nil
            }

        let start: Int
        if let providedRange {
            start = providedRange.start
        } else if let found = utf16IndexOf(utf16, needle: chunkUTF16, fromIndex: contentPos) {
            start = found
        } else {
            linkedChunks.append(chunk)
            continue
        }
        if start < 0 {
            linkedChunks.append(chunk)
            continue
        }

        let end = providedRange?.end ?? (start + chunkUTF16.count)
        contentPos = end

        while rangeIndex < ranges.count && ranges[rangeIndex].end <= start {
            rangeIndex += 1
        }

        if !utf16EqualsSlice(utf16, start: start, end: end, other: chunkUTF16) {
            var updated = chunk
            if rangeIndex < ranges.count {
                let range = ranges[rangeIndex]
                if range.label && range.start < end {
                    updated.link = TextChunkLink(url: range.url)
                }
            }
            linkedChunks.append(updated)
            continue
        }

        var position = start
        while rangeIndex < ranges.count {
            let range = ranges[rangeIndex]
            if range.end <= position {
                rangeIndex += 1
                continue
            }
            if range.start >= end {
                break
            }

            let linkStart = max(position, range.start)
            let linkEnd = min(end, range.end)
            if linkStart > position {
                var prefix = chunk
                prefix.text = utf16Slice(chunkUTF16, start: position - start, end: linkStart - start)
                linkedChunks.append(prefix)
            }

            var linked = chunk
            if !(linkStart == start && linkEnd == end) {
                linked.text = utf16Slice(chunkUTF16, start: linkStart - start, end: linkEnd - start)
            }
            linked.link = TextChunkLink(url: range.url)
            if range.bare, let bareStyle {
                if let fg = bareStyle.fg { linked.fg = fg }
                if let bg = bareStyle.bg { linked.bg = bg }
                linked.attributes = (linked.attributes ?? 0) | bareStyle.attributes
            }
            linkedChunks.append(linked)

            position = linkEnd
            if position == end {
                break
            }
            rangeIndex += 1
        }

        if position == start {
            linkedChunks.append(chunk)
        } else if position < end {
            var suffix = chunk
            suffix.text = utf16Slice(chunkUTF16, start: position - start, end: chunkUTF16.count)
            linkedChunks.append(suffix)
        }
    }

    return linkedChunks
}
