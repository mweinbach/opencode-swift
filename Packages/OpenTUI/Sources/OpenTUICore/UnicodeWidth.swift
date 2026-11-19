/// Pure-Swift Unicode display-cell width, grapheme cluster segmentation, tab/line-break scanning,
/// and layout wrap-break classification matching `packages/native/src/utf8.zig`.

/// The method used when calculating the display-cell width of a grapheme cluster.
// parity: native/src/utf8.zig#WidthMethod [status=implemented hash=17337bae6570]
public enum WidthMethod: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case wcwidth = "wcwidth"
    case unicode = "unicode"
    case noZWJ = "no-zwj"
    case unicodeWide = "unicode-wide"
}

/// How layout measures control characters (C0 other than tab/LF/CR, DEL, and C1).
// parity: native/src/utf8.zig#ControlDisplay [status=implemented hash=2fd139c6a1a2]
public enum ControlDisplay: UInt8, Equatable, Hashable, Sendable, Codable {
    /// Zero width. Read-only text hides controls.
    case hidden = 0
    /// Vim notation: C0 controls and DEL show as `^@`..`^_` and `^?` (2 cells),
    /// and C1 controls as `<80>`..`<9f>` (4 cells).
    case notation = 1
}

/// Kind of line terminator detected by `findLineBreaks`.
// parity: native/src/utf8.zig#LineBreakKind [status=implemented hash=b5390d7d7163]
public enum LineBreakKind: Equatable, Hashable, Sendable, Codable {
    case lf
    case cr
    case crlf
}

/// Position and kind of a line break in UTF-8 byte offsets.
// parity: native/src/utf8.zig#LineBreak [status=implemented hash=3458f8385690]
public struct LineBreak: Equatable, Hashable, Sendable, Codable {
    public var pos: Int
    public var kind: LineBreakKind

    public init(pos: Int, kind: LineBreakKind) {
        self.pos = pos
        self.kind = kind
    }
}

/// Classifies a layout break opportunity for line wrapping and editor word motion.
// parity: native/src/utf8.zig#LayoutWrapBreakKind [status=implemented hash=7ee4c6217e68]
public enum LayoutWrapBreakKind: UInt8, Equatable, Hashable, Sendable, Codable {
    case none = 0
    case whitespace = 1
    case preservedWhitespace = 2
    case punctuation = 3
    case scriptTransition = 4
    case cjkIntercharacter = 5

    /// True when the break also ends a word. Word motion skips breaks that are
    /// line-break opportunities only.
    // parity: native/src/utf8.zig#LayoutWrapBreakKind.isWordBoundary [status=implemented hash=b5194b3a9483]
    public var isWordBoundary: Bool {
        switch self {
        case .whitespace, .preservedWhitespace, .punctuation, .scriptTransition:
            return true
        case .none, .cjkIntercharacter:
            return false
        }
    }
}

/// Direct byte and display-column metadata for a wrap opportunity.
// parity: native/src/utf8.zig#LayoutWrapBreak [status=implemented hash=98f759ec6553]
public struct LayoutWrapBreak: Equatable, Hashable, Sendable, Codable {
    public var byteStart: UInt32
    public var colStart: UInt32
    public var byteLen: UInt32
    public var widthCols: UInt32
    public var kind: LayoutWrapBreakKind

    public init(
        byteStart: UInt32,
        colStart: UInt32,
        byteLen: UInt32,
        widthCols: UInt32,
        kind: LayoutWrapBreakKind
    ) {
        self.byteStart = byteStart
        self.colStart = colStart
        self.byteLen = byteLen
        self.widthCols = widthCols
        self.kind = kind
    }

    // parity: native/src/utf8.zig#LayoutWrapBreak.colEnd [status=implemented hash=b838fcb2731e]
    public var colEnd: UInt32 { colStart + widthCols }
    // parity: native/src/utf8.zig#LayoutWrapBreak.byteEnd [status=implemented hash=14a2e17178fc]
    public var byteEnd: UInt32 { byteStart + byteLen }
}

/// Script classification for predictable word boundaries in mixed ASCII/CJK text.
// parity: native/src/utf8.zig#WordClass [status=implemented hash=906c714ab5de]
public enum WordClass: Equatable, Hashable, Sendable, Codable {
    case asciiWord
    case cjkWord
    case other
}

/// Endpoint word classes supporting script transitions across chunk boundaries.
// parity: native/src/utf8.zig#WordClassEdges [status=implemented hash=586432d51e24]
public struct WordClassEdges: Equatable, Hashable, Sendable, Codable {
    public var first: WordClass
    public var last: WordClass
    public var hasCjkBreaks: Bool

    public init(first: WordClass, last: WordClass, hasCjkBreaks: Bool = false) {
        self.first = first
        self.last = last
        self.hasCjkBreaks = hasCjkBreaks
    }
}

/// Result of scanning a chunk for wrap and word break opportunities.
// parity: native/src/utf8.zig#ChunkLayoutInfo [status=implemented hash=45c37e7b2220]
public struct ChunkLayoutInfo: Equatable, Hashable, Sendable, Codable {
    public var wrapBreaks: [LayoutWrapBreak]
    public var cjkBreaks: [LayoutWrapBreak]
    public var wordClasses: WordClassEdges

    public init(
        wrapBreaks: [LayoutWrapBreak],
        cjkBreaks: [LayoutWrapBreak] = [],
        wordClasses: WordClassEdges
    ) {
        self.wrapBreaks = wrapBreaks
        self.cjkBreaks = cjkBreaks
        self.wordClasses = wordClasses
    }
}

/// Result of wrapping a byte slice by column width.
// parity: native/src/utf8.zig#WrapByWidthResult [status=implemented hash=bf246ced590c]
public struct WrapByWidthResult: Equatable, Hashable, Sendable, Codable {
    public var byteOffset: UInt32
    public var graphemeCount: UInt32
    public var columnsUsed: UInt32

    public init(byteOffset: UInt32, graphemeCount: UInt32, columnsUsed: UInt32) {
        self.byteOffset = byteOffset
        self.graphemeCount = graphemeCount
        self.columnsUsed = columnsUsed
    }
}

/// Result of finding a byte position by display-column width.
// parity: native/src/utf8.zig#PosByWidthResult [status=implemented hash=e740f727d07a]
public struct PosByWidthResult: Equatable, Hashable, Sendable, Codable {
    public var byteOffset: UInt32
    public var graphemeCount: UInt32
    public var columnsUsed: UInt32

    public init(byteOffset: UInt32, graphemeCount: UInt32, columnsUsed: UInt32) {
        self.byteOffset = byteOffset
        self.graphemeCount = graphemeCount
        self.columnsUsed = columnsUsed
    }
}

/// Start byte offset and display width of the previous visible grapheme before a byte offset.
// parity: native/src/utf8.zig#PrevGraphemeResult [status=implemented hash=ccbccaa5ce1c]
public struct PrevGraphemeResult: Equatable, Hashable, Sendable, Codable {
    public var startOffset: Int
    public var width: UInt32

    public init(startOffset: Int, width: UInt32) {
        self.startOffset = startOffset
        self.width = width
    }
}

/// Sparse metadata for multibyte grapheme clusters and tabs within a UTF-8 byte sequence.
// parity: native/src/utf8.zig#RenderClusterInfo [status=implemented hash=8e3988f61ef1]
public struct RenderClusterInfo: Equatable, Hashable, Sendable, Codable {
    public var byteStart: UInt32
    public var byteLen: UInt32
    public var widthCols: UInt32
    public var colStart: UInt32

    public init(byteStart: UInt32, byteLen: UInt32, widthCols: UInt32, colStart: UInt32) {
        self.byteStart = byteStart
        self.byteLen = byteLen
        self.widthCols = widthCols
        self.colStart = colStart
    }
}

// MARK: - East Asian Wide / Fullwidth Range Table (Unicode 16.0)

private let eastAsianWideRanges: [(UInt32, UInt32)] = [
    (0x1100, 0x115F),
    (0x231A, 0x231B),
    (0x2329, 0x232A),
    (0x23E9, 0x23EC),
    (0x23F0, 0x23F0),
    (0x23F3, 0x23F3),
    (0x25FD, 0x25FE),
    (0x2614, 0x2615),
    (0x2648, 0x2653),
    (0x267F, 0x267F),
    (0x2693, 0x2693),
    (0x26A1, 0x26A1),
    (0x26AA, 0x26AB),
    (0x26BD, 0x26BE),
    (0x26C4, 0x26C5),
    (0x26CE, 0x26CE),
    (0x26D4, 0x26D4),
    (0x26EA, 0x26EA),
    (0x26F2, 0x26F3),
    (0x26F5, 0x26F5),
    (0x26FA, 0x26FA),
    (0x26FD, 0x26FD),
    (0x2705, 0x2705),
    (0x270A, 0x270B),
    (0x2728, 0x2728),
    (0x274C, 0x274C),
    (0x274E, 0x274E),
    (0x2753, 0x2755),
    (0x2757, 0x2757),
    (0x2795, 0x2797),
    (0x27B0, 0x27B0),
    (0x27BF, 0x27BF),
    (0x2B1B, 0x2B1C),
    (0x2B50, 0x2B50),
    (0x2B55, 0x2B55),
    (0x2E80, 0x2E99),
    (0x2E9B, 0x2EF3),
    (0x2F00, 0x2FD5),
    (0x2FF0, 0x303E),
    (0x3041, 0x3096),
    (0x3099, 0x30FF),
    (0x3105, 0x312F),
    (0x3131, 0x318E),
    (0x3190, 0x31E5),
    (0x31EF, 0x321E),
    (0x3220, 0x3247),
    (0x3250, 0x4DBF),
    (0x4E00, 0xA48C),
    (0xA490, 0xA4C6),
    (0xA960, 0xA97C),
    (0xAC00, 0xD7A3),
    (0xF900, 0xFAFF),
    (0xFE10, 0xFE19),
    (0xFE30, 0xFE52),
    (0xFE54, 0xFE66),
    (0xFE68, 0xFE6B),
    (0xFF01, 0xFF60),
    (0xFFE0, 0xFFE6),
    (0x16FE0, 0x16FE4),
    (0x16FF0, 0x16FF1),
    (0x17000, 0x187F7),
    (0x18800, 0x18CD5),
    (0x18CFF, 0x18D08),
    (0x1AFF0, 0x1AFF3),
    (0x1AFF5, 0x1AFFB),
    (0x1AFFD, 0x1AFFE),
    (0x1B000, 0x1B122),
    (0x1B132, 0x1B132),
    (0x1B150, 0x1B152),
    (0x1B155, 0x1B155),
    (0x1B164, 0x1B167),
    (0x1B170, 0x1B2FB),
    (0x1F004, 0x1F004),
    (0x1F0CF, 0x1F0CF),
    (0x1F18E, 0x1F18E),
    (0x1F191, 0x1F19A),
    (0x1F200, 0x1F202),
    (0x1F210, 0x1F23B),
    (0x1F240, 0x1F248),
    (0x1F250, 0x1F251),
    (0x1F260, 0x1F265),
    (0x1F300, 0x1F320),
    (0x1F32D, 0x1F335),
    (0x1F337, 0x1F37C),
    (0x1F37E, 0x1F393),
    (0x1F3A0, 0x1F3CA),
    (0x1F3CF, 0x1F3D3),
    (0x1F3E0, 0x1F3F0),
    (0x1F3F4, 0x1F3F4),
    (0x1F3F8, 0x1F43E),
    (0x1F440, 0x1F440),
    (0x1F442, 0x1F4FC),
    (0x1F4FF, 0x1F53D),
    (0x1F54B, 0x1F54E),
    (0x1F550, 0x1F567),
    (0x1F57A, 0x1F57A),
    (0x1F595, 0x1F596),
    (0x1F5A4, 0x1F5A4),
    (0x1F5FB, 0x1F64F),
    (0x1F680, 0x1F6C5),
    (0x1F6CC, 0x1F6CC),
    (0x1F6D0, 0x1F6D2),
    (0x1F6D5, 0x1F6D7),
    (0x1F6DC, 0x1F6DF),
    (0x1F6EB, 0x1F6EC),
    (0x1F6F4, 0x1F6FC),
    (0x1F7E0, 0x1F7EB),
    (0x1F7F0, 0x1F7F0),
    (0x1F90C, 0x1F93A),
    (0x1F93C, 0x1F945),
    (0x1F947, 0x1F9FF),
    (0x1FA70, 0x1FA7C),
    (0x1FA80, 0x1FA89),
    (0x1FA8F, 0x1FAC6),
    (0x1FACE, 0x1FADC),
    (0x1FADF, 0x1FAE9),
    (0x1FAF0, 0x1FAF8),
    (0x20000, 0x2FFFD),
    (0x30000, 0x3FFFD),
]

@inline(__always)
private func isEastAsianWideOrFullwidth(_ cp: UInt32) -> Bool {
    if cp < 0x1100 { return false }
    var lo = 0
    var hi = eastAsianWideRanges.count - 1
    while lo <= hi {
        let mid = lo + (hi - lo) / 2
        let (start, end) = eastAsianWideRanges[mid]
        if cp < start {
            if mid == 0 { return false }
            hi = mid - 1
        } else if cp > end {
            lo = mid + 1
        } else {
            return true
        }
    }
    return false
}

// MARK: - Basic ASCII & Scalar Predicates

/// Length of the leading run of printable ASCII (0x20...0x7E) in `bytes`.
// parity: native/src/utf8.zig#printableAsciiPrefixLen [status=implemented hash=fd1daf08532a]
public func printableAsciiPrefixLen(_ bytes: [UInt8]) -> Int {
    var pos = 0
    while pos < bytes.count {
        let b = bytes[pos]
        if b < 32 || b > 126 { break }
        pos += 1
    }
    return pos
}

public func printableAsciiPrefixLen(_ bytes: ArraySlice<UInt8>) -> Int {
    var count = 0
    for b in bytes {
        if b < 32 || b > 126 { break }
        count += 1
    }
    return count
}

/// Returns `true` if `bytes` is non-empty and contains only printable ASCII (0x20...0x7E).
// parity: native/src/utf8.zig#isAsciiOnly [status=implemented hash=ec33bbfb4992]
public func isAsciiOnly(_ bytes: [UInt8]) -> Bool {
    !bytes.isEmpty && printableAsciiPrefixLen(bytes) == bytes.count
}

public func isAsciiOnly(_ text: String) -> Bool {
    let utf8 = text.utf8
    guard !utf8.isEmpty else { return false }
    for b in utf8 {
        if b < 32 || b > 126 { return false }
    }
    return true
}

/// Returns `true` if `cp` is a C0 control, DEL (0x7F), or C1 control (0x80...0x9F).
// parity: native/src/utf8.zig#isControl [status=implemented hash=229c40362450]
@inline(__always)
public func isControl(_ cp: UInt32) -> Bool {
    cp < 0x20 || (cp >= 0x7F && cp < 0xA0)
}

/// Returns `true` if the UTF-8 byte sequence contains any C0, DEL, or C1 control character.
// parity: native/src/utf8.zig#containsControl [status=implemented hash=a60422e662fe]
public func containsControl(_ bytes: [UInt8]) -> Bool {
    let count = bytes.count
    var i = 0
    while i < count {
        let byte = bytes[i]
        if byte < 0x20 || byte == 0x7F { return true }
        if byte == 0xC2 && i + 1 < count && bytes[i + 1] < 0xA0 { return true }
        i += 1
    }
    return false
}

public func containsControl(_ text: String) -> Bool {
    containsControl(Array(text.utf8))
}

/// Returns `true` if `cp` is a valid Unicode scalar value (0...0x10FFFF excluding surrogates).
// parity: native/src/utf8.zig#isScalar [status=implemented hash=b10b653f75f6]
@inline(__always)
public func isScalar(_ cp: UInt32) -> Bool {
    cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF)
}

/// Display cell count of the Vim notation for control `cp`, or `0` when `cp` has none
/// (including tab, LF, CR, and non-control scalars).
// parity: native/src/utf8.zig#controlNotationWidth [status=implemented hash=4080a8b4d03a]
public func controlNotationWidth(_ cp: UInt32) -> UInt32 {
    if cp == 0x09 || cp == 0x0A || cp == 0x0D { return 0 }
    if cp < 0x20 || cp == 0x7F { return 2 }
    if cp >= 0x80 && cp < 0xA0 { return 4 }
    return 0
}

private let notationHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Printable ASCII byte of notation cell `index` for control `cp`.
// parity: native/src/utf8.zig#controlNotationGlyph [status=implemented hash=d97d12aebeaa]
public func controlNotationGlyph(_ cp: UInt32, index: UInt32) -> UInt8 {
    switch index {
    case 0:
        return cp < 0x80 ? UInt8(ascii: "^") : UInt8(ascii: "<")
    case 1:
        return cp < 0x80 ? UInt8(cp ^ 0x40) : notationHexDigits[Int((cp >> 4) & 0xF)]
    case 2:
        return notationHexDigits[Int(cp & 0xF)]
    default:
        return UInt8(ascii: ">")
    }
}

/// Returns `true` if the scalar is a Unicode combining mark (Mn, Mc, or Me).
public func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return true
    default:
        return false
    }
}

/// Returns `true` if the leading UTF-8 codepoint in `bytes` is a combining mark.
// parity: native/src/utf8.zig#isCombiningMark [status=implemented hash=800581442efe]
public func isCombiningMark(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return false }
    let (cp, _) = decodeUtf8Scalar(bytes, at: 0)
    guard let scalar = Unicode.Scalar(cp) else { return false }
    return isCombiningMark(scalar)
}

@inline(__always)
private func scalarRawWidth(_ cp: UInt32) -> Int16 {
    if cp == 0 { return 0 }
    if isControl(cp) { return -1 }
    guard let scalar = Unicode.Scalar(cp) else { return 1 }
    if isCombiningMark(scalar) { return 0 }
    // Terminals draw default-ignorable codepoints in zero cells, except soft hyphen (U+00AD)
    // and Hangul Jamo fillers (U+115F, U+1160).
    if cp != 0x00AD && cp != 0x115F && cp != 0x1160 && scalar.properties.isDefaultIgnorableCodePoint {
        return 0
    }
    return isEastAsianWideOrFullwidth(cp) ? 2 : 1
}

/// Single-codepoint display width based on East Asian Width and Unicode properties.
// parity: native/src/utf8.zig#eastAsianWidth [status=implemented hash=6666ba7e5ca4]
public func eastAsianWidth(_ cp: UInt32) -> UInt32 {
    if cp > 0x10FFFF { return 0 }
    let w = scalarRawWidth(cp)
    return w > 0 ? UInt32(w) : 0
}

@inline(__always)
private func controlWidth(_ cp: UInt32, _ controlDisplay: ControlDisplay) -> UInt32 {
    switch controlDisplay {
    case .hidden:
        return 0
    case .notation:
        return controlNotationWidth(cp)
    }
}

@inline(__always)
private func asciiCharWidth(_ byte: UInt8, tabWidth: UInt8, controlDisplay: ControlDisplay) -> UInt32 {
    if byte == 0x09 { return UInt32(tabWidth) }
    if byte >= 32 && byte <= 126 { return 1 }
    return controlWidth(UInt32(byte), controlDisplay)
}

@inline(__always)
private func scalarCharWidth(_ cp: UInt32, tabWidth: UInt8, controlDisplay: ControlDisplay) -> UInt32 {
    if cp < 0x80 {
        return asciiCharWidth(UInt8(cp), tabWidth: tabWidth, controlDisplay: controlDisplay)
    }
    if cp > 0x10FFFF { return 0 }
    let w = scalarRawWidth(cp)
    if w < 0 { return controlWidth(cp, controlDisplay) }
    return w > 0 ? UInt32(w) : 0
}

/// Decodes one UTF-8 scalar at `pos`. Returns `(scalarValue, byteLength)`.
@inline(__always)
internal func decodeUtf8Scalar(_ bytes: [UInt8], at pos: Int) -> (cp: UInt32, len: Int) {
    let b0 = bytes[pos]
    if b0 < 0x80 {
        return (UInt32(b0), 1)
    }
    if (b0 & 0xE0) == 0xC0 {
        guard pos + 1 < bytes.count else { return (0xFFFD, 1) }
        let b1 = bytes[pos + 1]
        guard (b1 & 0xC0) == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
        guard cp >= 0x80 else { return (0xFFFD, 1) }
        return (cp, 2)
    }
    if (b0 & 0xF0) == 0xE0 {
        guard pos + 2 < bytes.count else { return (0xFFFD, 1) }
        let b1 = bytes[pos + 1]
        let b2 = bytes[pos + 2]
        guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
        guard cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF) else { return (0xFFFD, 1) }
        return (cp, 3)
    }
    if (b0 & 0xF8) == 0xF0 {
        guard pos + 3 < bytes.count else { return (0xFFFD, 1) }
        let b1 = bytes[pos + 1]
        let b2 = bytes[pos + 2]
        let b3 = bytes[pos + 3]
        guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x07) << 18)
            | (UInt32(b1 & 0x3F) << 12)
            | (UInt32(b2 & 0x3F) << 6)
            | UInt32(b3 & 0x3F)
        guard cp >= 0x10000 && cp <= 0x10FFFF else { return (0xFFFD, 1) }
        return (cp, 4)
    }
    return (0xFFFD, 1)
}

@inline(__always)
internal func isValidUtf8(_ bytes: [UInt8]) -> Bool {
    var pos = 0
    let count = bytes.count
    while pos < count {
        let b0 = bytes[pos]
        if b0 < 0x80 {
            pos += 1
            continue
        }
        if (b0 & 0xE0) == 0xC0 {
            guard pos + 1 < count else { return false }
            let b1 = bytes[pos + 1]
            guard (b1 & 0xC0) == 0x80 else { return false }
            let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            guard cp >= 0x80 else { return false }
            pos += 2
        } else if (b0 & 0xF0) == 0xE0 {
            guard pos + 2 < count else { return false }
            let b1 = bytes[pos + 1]
            let b2 = bytes[pos + 2]
            guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 else { return false }
            let cp = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
            guard cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF) else { return false }
            pos += 3
        } else if (b0 & 0xF8) == 0xF0 {
            guard pos + 3 < count else { return false }
            let b1 = bytes[pos + 1]
            let b2 = bytes[pos + 2]
            let b3 = bytes[pos + 3]
            guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80 else { return false }
            let cp = (UInt32(b0 & 0x07) << 18)
                | (UInt32(b1 & 0x3F) << 12)
                | (UInt32(b2 & 0x3F) << 6)
                | UInt32(b3 & 0x3F)
            guard cp >= 0x10000 && cp <= 0x10FFFF else { return false }
            pos += 4
        } else {
            return false
        }
    }
    return true
}

// MARK: - Grapheme Cluster Segmentation & Width Accumulation

private struct GraphemeWidthAccumulator {
    var width: UInt32
    var hasWidth: Bool
    var isRegionalIndicatorPair: Bool
    var isEmojiModifierBase: Bool
    var hasIndicVirama: Bool
    let widthMethod: WidthMethod

    init(firstScalar cp: UInt32, firstWidth: UInt32, widthMethod: WidthMethod) {
        self.width = firstWidth
        self.hasWidth = firstWidth > 0
        self.isRegionalIndicatorPair = (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        if let scalar = Unicode.Scalar(cp) {
            self.isEmojiModifierBase = scalar.properties.isEmojiModifierBase
        } else {
            self.isEmojiModifierBase = false
        }
        self.hasIndicVirama = false
        self.widthMethod = widthMethod
    }

    mutating func addCodepoint(_ cp: UInt32, cpWidth: UInt32) {
        if widthMethod == .wcwidth {
            let w = scalarRawWidth(cp)
            if w > 0 {
                width += UInt32(w)
                hasWidth = true
            }
            return
        }

        let isRI = (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        if cp == 0xFE0F {
            // Variation Selector-16 widens text-default width-1 emoji to 2 cells.
            if hasWidth && width == 1 {
                width = 2
            }
            return
        }

        let scalar = Unicode.Scalar(cp)
        let gc = scalar?.properties.generalCategory
        let isVirama = gc == .nonspacingMark
        if isVirama {
            hasIndicVirama = true
            return
        }

        let isSpacingMark = gc == .spacingMark
        let isDevanagariRa = (cp == 0x0930)
        let isDevanagariBase = (cp >= 0x0915 && cp <= 0x0939) || (cp >= 0x0958 && cp <= 0x095F)

        if isRegionalIndicatorPair && isRI {
            width += cpWidth
            hasWidth = true
        } else if !hasWidth && cpWidth > 0 {
            width = cpWidth
            hasWidth = true
        } else if isEmojiModifierBase && widthMethod != .unicodeWide && (scalar?.properties.isEmojiModifier ?? false) {
            width = 2
        } else if widthMethod == .unicodeWide && hasWidth && !isZeroWidthInGrapheme(cp, scalar: scalar) {
            width = max(width, 2)
        } else if hasWidth && isSpacingMark && cpWidth > 0 {
            width = max(width, 2)
        } else if hasWidth && hasIndicVirama && isDevanagariBase && cpWidth > 0 {
            if !isDevanagariRa {
                width += cpWidth
            }
            hasIndicVirama = false
        }
    }

    private func isZeroWidthInGrapheme(_ cp: UInt32, scalar: Unicode.Scalar?) -> Bool {
        if cp == 0x200D || cp == 0x200C || cp == 0xFE0E || cp == 0xFE0F { return true }
        guard let scalar else { return false }
        if isCombiningMark(scalar) { return true }
        return scalar.properties.isDefaultIgnorableCodePoint
    }
}

/// A single segmented grapheme cluster in UTF-8 byte coordinates along with its display width.
public struct GraphemeClusterSpan: Equatable, Hashable, Sendable {
    public var byteStart: Int
    public var byteEnd: Int
    public var width: UInt32
    public var firstScalar: UInt32

    public var byteLen: Int { byteEnd - byteStart }

    public init(byteStart: Int, byteEnd: Int, width: UInt32, firstScalar: UInt32) {
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.width = width
        self.firstScalar = firstScalar
    }
}

/// Segments UTF-8 `bytes` into display clusters according to `widthMethod` (respecting `.noZWJ`
/// and standalone U+FFFD semantics matching `utf8.zig`).
public func segmentGraphemeClusters(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    widthMethod: WidthMethod = .unicode
) -> [GraphemeClusterSpan] {
    guard !bytes.isEmpty else { return [] }

    // Fast path for pure printable ASCII
    if isAsciiOnly(bytes) {
        var result: [GraphemeClusterSpan] = []
        result.reserveCapacity(bytes.count)
        for i in 0..<bytes.count {
            result.append(GraphemeClusterSpan(
                byteStart: i,
                byteEnd: i + 1,
                width: 1,
                firstScalar: UInt32(bytes[i])
            ))
        }
        return result
    }

    // If the bytes are valid UTF-8, use Swift's UAX #29 grapheme cluster segmentation directly,
    // splitting any cluster at U+FFFD or (in .noZWJ mode) right after U+200D.
    if isValidUtf8(bytes) {
        let string = String(decoding: bytes, as: UTF8.self)
        var spans: [GraphemeClusterSpan] = []
        spans.reserveCapacity(bytes.count)
        var byteOffset = 0

        for character in string {
            let charByteCount = character.utf8.count
            let charEnd = byteOffset + charByteCount

            // Fast path: single-scalar cluster
            var scalarIterator = character.unicodeScalars.makeIterator()
            if let first = scalarIterator.next(), scalarIterator.next() == nil {
                let w = scalarCharWidth(first.value, tabWidth: tabWidth, controlDisplay: controlDisplay)
                spans.append(GraphemeClusterSpan(
                    byteStart: byteOffset,
                    byteEnd: charEnd,
                    width: w,
                    firstScalar: first.value
                ))
                byteOffset = charEnd
                continue
            }

            // Multi-scalar cluster: split if U+FFFD appears or if .noZWJ breaks after U+200D
            var subStart = byteOffset
            var cursor = byteOffset
            var acc: GraphemeWidthAccumulator? = nil
            var firstScalar: UInt32 = 0
            var prevWasZWJ = false
            var prevWasReplacement = false

            for scalar in character.unicodeScalars {
                let sLen = scalar.utf8.count
                let cp = scalar.value
                let forceBreak = (cp == 0xFFFD) || prevWasReplacement || (widthMethod == .noZWJ && prevWasZWJ)

                if forceBreak, let existing = acc {
                    spans.append(GraphemeClusterSpan(
                        byteStart: subStart,
                        byteEnd: cursor,
                        width: existing.width,
                        firstScalar: firstScalar
                    ))
                    acc = nil
                    subStart = cursor
                }

                let w = scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
                if acc == nil {
                    acc = GraphemeWidthAccumulator(firstScalar: cp, firstWidth: w, widthMethod: widthMethod)
                    firstScalar = cp
                } else {
                    acc!.addCodepoint(cp, cpWidth: w)
                }

                cursor += sLen
                prevWasZWJ = (cp == 0x200D)
                prevWasReplacement = (cp == 0xFFFD)
            }

            if let existing = acc {
                spans.append(GraphemeClusterSpan(
                    byteStart: subStart,
                    byteEnd: cursor,
                    width: existing.width,
                    firstScalar: firstScalar
                ))
            }
            byteOffset = charEnd
        }

        return spans
    }

    // Fallback for invalid UTF-8 slices: decode scalar-by-scalar with U+FFFD boundaries.
    var spans: [GraphemeClusterSpan] = []
    var pos = 0
    while pos < bytes.count {
        let (cp, len) = decodeUtf8Scalar(bytes, at: pos)
        let w = scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
        spans.append(GraphemeClusterSpan(
            byteStart: pos,
            byteEnd: pos + len,
            width: w,
            firstScalar: cp
        ))
        pos += len
    }
    return spans
}

// MARK: - Line Breaks & Tab Stops

/// Finds all `\t` byte positions in `bytes`.
// parity: native/src/utf8.zig#findTabStops [status=implemented hash=d3f8f3837bdd]
public func findTabStops(_ bytes: [UInt8]) -> [Int] {
    var positions: [Int] = []
    for i in 0..<bytes.count {
        if bytes[i] == 0x09 {
            positions.append(i)
        }
    }
    return positions
}

public func findTabStops(_ text: String) -> [Int] {
    findTabStops(Array(text.utf8))
}

/// Finds all LF, CR, and CRLF line break positions in `bytes`.
// parity: native/src/utf8.zig#findLineBreaks [status=implemented hash=544bbf893900]
public func findLineBreaks(_ bytes: [UInt8]) -> [LineBreak] {
    var breaks: [LineBreak] = []
    var pos = 0
    let count = bytes.count
    while pos < count {
        let b = bytes[pos]
        if b == 0x0A { // \n
            breaks.append(LineBreak(pos: pos, kind: .lf))
            pos += 1
        } else if b == 0x0D { // \r
            if pos + 1 < count && bytes[pos + 1] == 0x0A {
                breaks.append(LineBreak(pos: pos + 1, kind: .crlf))
                pos += 2
            } else {
                breaks.append(LineBreak(pos: pos, kind: .cr))
                pos += 1
            }
        } else {
            pos += 1
        }
    }
    return breaks
}

public func findLineBreaks(_ text: String) -> [LineBreak] {
    findLineBreaks(Array(text.utf8))
}

// MARK: - Word Classification & Wrap Breaks

@inline(__always)
private func isAsciiWrapBreak(_ b: UInt8) -> Bool {
    switch b {
    case 0x20, 0x09, // space, tab
         0x2D, // -
         0x2F, 0x5C, // /, \
         0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, // . , ; : ! ?
         0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D: // ( ) [ ] { }
        return true
    default:
        return false
    }
}

@inline(__always)
private func asciiLayoutWrapBreakKind(_ b: UInt8) -> LayoutWrapBreakKind {
    switch b {
    case 0x20, 0x09:
        return .whitespace
    case 0x2D, 0x2F, 0x5C,
         0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F,
         0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D:
        return .punctuation
    default:
        return .none
    }
}

@inline(__always)
private func unicodeLayoutWrapBreakKind(_ cp: UInt32) -> LayoutWrapBreakKind {
    switch cp {
    case 0x00A0, // NBSP
         0x1680, // OGHAM SPACE MARK
         0x2000...0x200A, // En quad..Hair space
         0x202F, // NARROW NO-BREAK SPACE
         0x205F, // MEDIUM MATHEMATICAL SPACE
         0x3000, // IDEOGRAPHIC SPACE
         0x200B: // ZERO WIDTH SPACE
        return .whitespace
    case 0x00AD, // SOFT HYPHEN
         0x2010, // HYPHEN
         0x3001, // IDEOGRAPHIC COMMA
         0x3002, // IDEOGRAPHIC FULL STOP
         0xFF01, // FULLWIDTH EXCLAMATION MARK
         0xFF0C, // FULLWIDTH COMMA
         0xFF1A, // FULLWIDTH COLON
         0xFF1F: // FULLWIDTH QUESTION MARK
        return .punctuation
    default:
        return .none
    }
}

@inline(__always)
private func isAsciiWordByte(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) // a-z
        || (b >= 0x41 && b <= 0x5A) // A-Z
        || (b >= 0x30 && b <= 0x39) // 0-9
        || b == 0x5F // _
}

@inline(__always)
private func isCjkWordCodepoint(_ cp: UInt32) -> Bool {
    // Han ideographs
    (cp >= 0x3400 && cp <= 0x4DBF)
        || (cp >= 0x4E00 && cp <= 0x9FFF)
        || (cp >= 0xF900 && cp <= 0xFAFF)
        || (cp >= 0x20000 && cp <= 0x2A6DF)
        || (cp >= 0x2A700 && cp <= 0x2B73F)
        || (cp >= 0x2B740 && cp <= 0x2B81F)
        || (cp >= 0x2B820 && cp <= 0x2CEAF)
        || (cp >= 0x2CEB0 && cp <= 0x2EBEF)
        || (cp >= 0x2EBF0 && cp <= 0x2EE5D)
        || (cp >= 0x2F800 && cp <= 0x2FA1F)
        // Hiragana + Katakana
        || (cp >= 0x3040 && cp <= 0x309F)
        || (cp >= 0x30A0 && cp <= 0x30FF)
        || (cp >= 0x31F0 && cp <= 0x31FF)
        || (cp >= 0xFF66 && cp <= 0xFF9D)
        // Hangul
        || (cp >= 0x1100 && cp <= 0x11FF)
        || (cp >= 0x3130 && cp <= 0x318F)
        || (cp >= 0xA960 && cp <= 0xA97F)
        || (cp >= 0xAC00 && cp <= 0xD7AF)
        || (cp >= 0xD7B0 && cp <= 0xD7FF)
}

@inline(__always)
public func classifyWordClass(_ cp: UInt32) -> WordClass {
    if cp <= 0x7F {
        return isAsciiWordByte(UInt8(cp)) ? .asciiWord : .other
    }
    return isCjkWordCodepoint(cp) ? .cjkWord : .other
}

/// Returns `true` if `cp` belongs to an ASCII or CJK word class.
// parity: native/src/utf8.zig#isWordCodepoint [status=implemented hash=c3cf50119606]
@inline(__always)
public func isWordCodepoint(_ cp: UInt32) -> Bool {
    classifyWordClass(cp) != .other
}

/// Returns `true` when adjacent CJK characters form a line-break opportunity.
// parity: native/src/utf8.zig#isCjkIntercharacterBreak [status=implemented hash=a900fde23396]
@inline(__always)
public func isCjkIntercharacterBreak(prevClass: WordClass, currClass: WordClass, currCp: UInt32) -> Bool {
    prevClass == .cjkWord
        && currClass == .cjkWord
        && currCp != 0x3099
        && currCp != 0x309A
        && currCp != 0x30A0
        && currCp != 0x30FB
}

/// Returns `true` when adjacent characters transition between CJK and ASCII word runs.
// parity: native/src/utf8.zig#isCjkAsciiTransition [status=implemented hash=6451a908ef58]
@inline(__always)
public func isCjkAsciiTransition(prevClass: WordClass, currClass: WordClass) -> Bool {
    (prevClass == .cjkWord && currClass == .asciiWord)
        || (prevClass == .asciiWord && currClass == .cjkWord)
}

/// Endpoint word classes of `bytes` without scanning the interior.
// parity: native/src/utf8.zig#chunkWordClassEdges [status=implemented hash=2dda5d71a882]
public func chunkWordClassEdges(_ bytes: [UInt8]) -> WordClassEdges {
    guard !bytes.isEmpty else {
        return WordClassEdges(first: .other, last: .other)
    }
    let first = decodeUtf8Scalar(bytes, at: 0).cp
    var lastStart = bytes.count - 1
    var contCount = 0
    while lastStart > 0 && (bytes[lastStart] & 0xC0) == 0x80 && contCount < 3 {
        lastStart -= 1
        contCount += 1
    }
    let last = decodeUtf8Scalar(bytes, at: lastStart).cp
    return WordClassEdges(first: classifyWordClass(first), last: classifyWordClass(last))
}

// MARK: - Width Measurement & Position Scanning

/// Calculates the display-cell width of `bytes` under `widthMethod`.
// parity: native/src/utf8.zig#calculateTextWidth [status=implemented hash=b8ff1a443a80]
public func calculateTextWidth(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> UInt32 {
    guard !bytes.isEmpty else { return 0 }
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        return UInt32(bytes.count)
    }

    if widthMethod == .wcwidth {
        var total: UInt32 = 0
        var pos = 0
        while pos < bytes.count {
            let (cp, len) = decodeUtf8Scalar(bytes, at: pos)
            total += scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
            pos += len
        }
        return total
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    var total: UInt32 = 0
    for span in spans {
        total += span.width
    }
    return total
}

public func calculateTextWidth(
    _ text: String,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    widthMethod: WidthMethod = .unicode
) -> UInt32 {
    if isAsciiOnly(text) {
        return UInt32(text.utf8.count)
    }
    return calculateTextWidth(
        Array(text.utf8),
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: false,
        widthMethod: widthMethod
    )
}

/// Returns the display-cell width of the unit starting at `byteOffset` in `bytes`.
// parity: native/src/utf8.zig#getWidthAt [status=implemented hash=7fb0fab975c3]
public func getWidthAt(
    _ bytes: [UInt8],
    byteOffset: Int,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    widthMethod: WidthMethod = .unicode
) -> UInt32 {
    guard byteOffset >= 0 && byteOffset < bytes.count else { return 0 }
    if widthMethod == .wcwidth {
        let (cp, _) = decodeUtf8Scalar(bytes, at: byteOffset)
        return scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
    }
    return getGraphemeWidthAt(
        bytes,
        byteOffset: byteOffset,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
}

/// Returns the display-cell width of the grapheme cluster starting at `byteOffset` in `bytes`.
// parity: native/src/utf8.zig#getGraphemeWidthAt [status=implemented hash=426855472b6b]
public func getGraphemeWidthAt(
    _ bytes: [UInt8],
    byteOffset: Int,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    widthMethod: WidthMethod = .unicode
) -> UInt32 {
    guard byteOffset >= 0 && byteOffset < bytes.count else { return 0 }
    if bytes[byteOffset] < 0x80 && (byteOffset + 1 == bytes.count || bytes[byteOffset + 1] < 0x80) {
        return asciiCharWidth(bytes[byteOffset], tabWidth: tabWidth, controlDisplay: controlDisplay)
    }
    let slice = Array(bytes[byteOffset...])
    let spans = segmentGraphemeClusters(
        slice,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    return spans.first?.width ?? 0
}

/// Finds the start byte offset and width of the last visible grapheme before `byteOffset`.
// parity: native/src/utf8.zig#getPrevGraphemeStart [status=implemented hash=d7423974ec7e]
public func getPrevGraphemeStart(
    _ bytes: [UInt8],
    byteOffset: Int,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    widthMethod: WidthMethod = .unicode
) -> PrevGraphemeResult? {
    guard byteOffset > 0 && byteOffset <= bytes.count && !bytes.isEmpty else { return nil }

    if widthMethod == .wcwidth {
        var pos = 0
        var last: PrevGraphemeResult? = nil
        while pos < byteOffset {
            let (cp, len) = decodeUtf8Scalar(bytes, at: pos)
            let w = scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
            if w > 0 {
                last = PrevGraphemeResult(startOffset: pos, width: w)
            }
            pos += len
        }
        return last
    }

    let lastByte = bytes[byteOffset - 1]
    let beforeByte: UInt8 = byteOffset > 1 ? bytes[byteOffset - 2] : 0
    if lastByte < 0x80 && beforeByte < 0x80 {
        let w = asciiCharWidth(lastByte, tabWidth: tabWidth, controlDisplay: controlDisplay)
        if w > 0 {
            return PrevGraphemeResult(startOffset: byteOffset - 1, width: w)
        }
    }

    let prefix = Array(bytes[0..<byteOffset])
    let spans = segmentGraphemeClusters(
        prefix,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    for span in spans.reversed() {
        if span.width > 0 {
            return PrevGraphemeResult(startOffset: span.byteStart, width: span.width)
        }
    }
    return nil
}

/// Finds the wrap position before exceeding `maxColumns`.
// parity: native/src/utf8.zig#findWrapPosByWidth [status=implemented hash=7545a26e7561]
public func findWrapPosByWidth(
    _ bytes: [UInt8],
    maxColumns: UInt32,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> WrapByWidthResult {
    guard !bytes.isEmpty && maxColumns > 0 else {
        return WrapByWidthResult(byteOffset: 0, graphemeCount: 0, columnsUsed: 0)
    }
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        let count = min(UInt32(bytes.count), maxColumns)
        return WrapByWidthResult(byteOffset: count, graphemeCount: count, columnsUsed: count)
    }

    if widthMethod == .wcwidth {
        var pos = 0
        var columnsUsed: UInt32 = 0
        var count: UInt32 = 0
        while pos < bytes.count {
            let (cp, len) = decodeUtf8Scalar(bytes, at: pos)
            let w = scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
            if columnsUsed >= maxColumns || columnsUsed + w > maxColumns {
                return WrapByWidthResult(byteOffset: UInt32(pos), graphemeCount: count, columnsUsed: columnsUsed)
            }
            columnsUsed += w
            count += 1
            pos += len
        }
        return WrapByWidthResult(byteOffset: UInt32(bytes.count), graphemeCount: count, columnsUsed: columnsUsed)
    }

    return findWrapPosByWidthGraphemeSafe(
        bytes,
        maxColumns: maxColumns,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: false,
        widthMethod: widthMethod
    )
}

/// Finds a wrap position without splitting a grapheme cluster.
// parity: native/src/utf8.zig#findWrapPosByWidthGraphemeSafe [status=implemented hash=b03770f94d95]
public func findWrapPosByWidthGraphemeSafe(
    _ bytes: [UInt8],
    maxColumns: UInt32,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> WrapByWidthResult {
    guard !bytes.isEmpty && maxColumns > 0 else {
        return WrapByWidthResult(byteOffset: 0, graphemeCount: 0, columnsUsed: 0)
    }
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        let count = min(UInt32(bytes.count), maxColumns)
        return WrapByWidthResult(byteOffset: count, graphemeCount: count, columnsUsed: count)
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    var columnsUsed: UInt32 = 0
    var graphemeCount: UInt32 = 0
    for span in spans {
        if columnsUsed + span.width > maxColumns {
            return WrapByWidthResult(
                byteOffset: UInt32(span.byteStart),
                graphemeCount: graphemeCount,
                columnsUsed: columnsUsed
            )
        }
        columnsUsed += span.width
        graphemeCount += 1
    }
    return WrapByWidthResult(
        byteOffset: UInt32(bytes.count),
        graphemeCount: graphemeCount,
        columnsUsed: columnsUsed
    )
}

/// Finds a byte position by display-column width, snapping forward (`includeStartBefore == true`)
/// or backward (`includeStartBefore == false`) at wide boundaries.
// parity: native/src/utf8.zig#findPosByWidth [status=implemented hash=d64364045e9e]
public func findPosByWidth(
    _ bytes: [UInt8],
    maxColumns: UInt32,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    includeStartBefore: Bool,
    widthMethod: WidthMethod = .unicode
) -> PosByWidthResult {
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        let count = min(UInt32(bytes.count), maxColumns)
        return PosByWidthResult(byteOffset: count, graphemeCount: count, columnsUsed: count)
    }

    if widthMethod == .wcwidth {
        var pos = 0
        var columnsUsed: UInt32 = 0
        var count: UInt32 = 0
        while pos < bytes.count {
            let (cp, len) = decodeUtf8Scalar(bytes, at: pos)
            let w = scalarCharWidth(cp, tabWidth: tabWidth, controlDisplay: controlDisplay)
            let startCol = columnsUsed
            let endCol = columnsUsed + w
            if includeStartBefore {
                if startCol >= maxColumns {
                    return PosByWidthResult(byteOffset: UInt32(pos), graphemeCount: count, columnsUsed: columnsUsed)
                }
            } else {
                if endCol > maxColumns {
                    return PosByWidthResult(byteOffset: UInt32(pos), graphemeCount: count, columnsUsed: columnsUsed)
                }
            }
            columnsUsed = endCol
            count += 1
            pos += len
        }
        return PosByWidthResult(byteOffset: UInt32(bytes.count), graphemeCount: count, columnsUsed: columnsUsed)
    }

    return findGraphemePosByWidth(
        bytes,
        maxColumns: maxColumns,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: false,
        includeStartBefore: includeStartBefore,
        widthMethod: widthMethod
    )
}

/// Finds a display position without splitting Unicode grapheme clusters.
// parity: native/src/utf8.zig#findGraphemePosByWidth [status=implemented hash=3c6ef88aa1fb]
public func findGraphemePosByWidth(
    _ bytes: [UInt8],
    maxColumns: UInt32,
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    includeStartBefore: Bool,
    widthMethod: WidthMethod = .unicode
) -> PosByWidthResult {
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        let count = min(UInt32(bytes.count), maxColumns)
        return PosByWidthResult(byteOffset: count, graphemeCount: count, columnsUsed: count)
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    var columnsUsed: UInt32 = 0
    var graphemeCount: UInt32 = 0
    for span in spans {
        let startCol = columnsUsed
        let endCol = columnsUsed + span.width
        if includeStartBefore {
            if startCol >= maxColumns {
                return PosByWidthResult(
                    byteOffset: UInt32(span.byteStart),
                    graphemeCount: graphemeCount,
                    columnsUsed: columnsUsed
                )
            }
            columnsUsed = endCol
            graphemeCount += 1
        } else {
            if endCol > maxColumns {
                return PosByWidthResult(
                    byteOffset: UInt32(span.byteStart),
                    graphemeCount: graphemeCount,
                    columnsUsed: columnsUsed
                )
            }
            columnsUsed = endCol
        }
    }
    return PosByWidthResult(
        byteOffset: UInt32(bytes.count),
        graphemeCount: graphemeCount,
        columnsUsed: columnsUsed
    )
}

/// Stateful monotonic cursor measuring cumulative display columns across increasing UTF-8 byte offsets.
// parity: native/src/utf8.zig#TextWidthCursor [status=implemented hash=adccb7e2160f]
public struct TextWidthCursor: Sendable {
    public let bytes: [UInt8]
    public let tabWidth: UInt8
    public let controlDisplay: ControlDisplay
    public let widthMethod: WidthMethod
    public private(set) var byteOffset: Int = 0
    public private(set) var columns: UInt32 = 0
    private let spans: [GraphemeClusterSpan]
    private var spanIndex: Int = 0

    public init(
        bytes: [UInt8],
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) {
        self.bytes = bytes
        self.tabWidth = tabWidth
        self.controlDisplay = controlDisplay
        self.widthMethod = widthMethod
        self.spans = segmentGraphemeClusters(
            bytes,
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            widthMethod: widthMethod
        )
    }

    public init(
        text: String,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) {
        self.init(
            bytes: Array(text.utf8),
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            widthMethod: widthMethod
        )
    }

    /// Advances the cursor to at least `byteEnd`, completing any grapheme cluster that straddles `byteEnd`.
    // parity: native/src/utf8.zig#TextWidthCursor.advanceTo [status=implemented hash=9b420c3d116b]
    @discardableResult
    public mutating func advanceTo(_ byteEnd: Int) -> UInt32 {
        let end = min(byteEnd, bytes.count)
        guard end > byteOffset else { return columns }
        while spanIndex < spans.count && byteOffset < end {
            let span = spans[spanIndex]
            columns += span.width
            byteOffset = span.byteEnd
            spanIndex += 1
        }
        return columns
    }
}

// MARK: - Render Cluster Info & Chunk Layout Wrap-Break Scanning

/// Finds sparse render-cluster metadata for multibyte clusters and tabs.
// parity: native/src/utf8.zig#findRenderClusterInfo [status=implemented hash=381a664ad917]
public func findRenderClusterInfo(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> [RenderClusterInfo] {
    guard !bytes.isEmpty else { return [] }
    let asciiOnly = isASCIIOnly ?? isAsciiOnly(bytes)
    if asciiOnly && widthMethod != .wcwidth {
        return []
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    var result: [RenderClusterInfo] = []
    var col: UInt32 = 0
    for span in spans {
        let isTab = span.byteLen == 1 && bytes[span.byteStart] == 0x09
        let isMultibyte = span.byteLen > 1 || bytes[span.byteStart] >= 0x80
        if (isMultibyte || isTab) && (span.width > 0 || widthMethod == .wcwidth) {
            result.append(RenderClusterInfo(
                byteStart: UInt32(span.byteStart),
                byteLen: UInt32(span.byteLen),
                widthCols: span.width,
                colStart: col
            ))
        }
        col += span.width
    }
    return result
}

private func scanChunkLayout(
    _ bytes: [UInt8],
    tabWidth: UInt8,
    controlDisplay: ControlDisplay,
    isASCIIOnly: Bool?,
    widthMethod: WidthMethod,
    wordOnly: Bool,
    emit: (LayoutWrapBreak) -> Void
) -> WordClassEdges {
    guard !bytes.isEmpty else {
        return WordClassEdges(first: .other, last: .other)
    }
    if isASCIIOnly ?? isAsciiOnly(bytes) {
        for i in 0..<bytes.count {
            let b = bytes[i]
            if isAsciiWrapBreak(b) {
                emit(LayoutWrapBreak(
                    byteStart: UInt32(i),
                    colStart: UInt32(i),
                    byteLen: 1,
                    widthCols: 1,
                    kind: asciiLayoutWrapBreakKind(b)
                ))
            }
        }
        return chunkWordClassEdges(bytes)
    }

    let spans = segmentGraphemeClusters(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        widthMethod: widthMethod
    )
    guard !spans.isEmpty else {
        return WordClassEdges(first: .other, last: .other)
    }

    var hasCjkBreaks = false
    var col: UInt32 = 0
    let firstClass = classifyWordClass(spans[0].firstScalar)
    var lastClass: WordClass = .other

    for i in 0..<spans.count {
        let span = spans[i]
        let currClass = classifyWordClass(span.firstScalar)
        lastClass = currClass

        // Classify break kind across all scalars in the cluster
        var clusterKind: LayoutWrapBreakKind = .none
        var cursor = span.byteStart
        var isFirst = true
        while cursor < span.byteEnd {
            let (cp, len) = decodeUtf8Scalar(bytes, at: cursor)
            let nextKind = cp < 0x80 ? asciiLayoutWrapBreakKind(UInt8(cp)) : unicodeLayoutWrapBreakKind(cp)
            if isFirst {
                clusterKind = nextKind
                isFirst = false
            } else if clusterKind == .whitespace || nextKind == .whitespace {
                clusterKind = (clusterKind == .whitespace && nextKind == .whitespace)
                    ? .whitespace
                    : .preservedWhitespace
            } else if clusterKind == .none {
                clusterKind = nextKind
            }
            cursor += len
        }

        let resolvedKind: LayoutWrapBreakKind
        if clusterKind != .none {
            resolvedKind = clusterKind
        } else if i + 1 < spans.count {
            let nextSpan = spans[i + 1]
            let nextClass = classifyWordClass(nextSpan.firstScalar)
            if isCjkAsciiTransition(prevClass: currClass, currClass: nextClass) {
                resolvedKind = .scriptTransition
            } else if span.width > 0 && isCjkIntercharacterBreak(
                prevClass: currClass,
                currClass: nextClass,
                currCp: nextSpan.firstScalar
            ) {
                hasCjkBreaks = true
                resolvedKind = wordOnly ? .none : .cjkIntercharacter
            } else {
                resolvedKind = .none
            }
        } else {
            resolvedKind = .none
        }

        if resolvedKind != .none {
            emit(LayoutWrapBreak(
                byteStart: UInt32(span.byteStart),
                colStart: col,
                byteLen: UInt32(span.byteLen),
                widthCols: span.width,
                kind: resolvedKind
            ))
        }
        col += span.width
    }

    return WordClassEdges(first: firstClass, last: lastClass, hasCjkBreaks: hasCjkBreaks)
}

/// Scans `bytes` for all line-wrapping and word-boundary opportunities.
// parity: native/src/utf8.zig#findChunkLayoutInfo [status=implemented hash=0f246d96e3e3]
public func findChunkLayoutInfo(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> ChunkLayoutInfo {
    var breaks: [LayoutWrapBreak] = []
    let edges = scanChunkLayout(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: isASCIIOnly,
        widthMethod: widthMethod,
        wordOnly: false
    ) { breaks.append($0) }
    return ChunkLayoutInfo(wrapBreaks: breaks, wordClasses: edges)
}

/// Scans `bytes` for word-boundary opportunities only (skipping line-only CJK intercharacter breaks).
// parity: native/src/utf8.zig#findWordChunkLayoutInfo [status=implemented hash=85ee2efc1535]
public func findWordChunkLayoutInfo(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> ChunkLayoutInfo {
    var breaks: [LayoutWrapBreak] = []
    let edges = scanChunkLayout(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: isASCIIOnly,
        widthMethod: widthMethod,
        wordOnly: true
    ) { breaks.append($0) }
    return ChunkLayoutInfo(wrapBreaks: breaks, wordClasses: edges)
}

/// Scans `bytes` and splits word-boundary breaks from line-only CJK breaks into disjoint lists.
// parity: native/src/utf8.zig#findLineAndWordChunkLayoutInfo [status=implemented hash=a1a68d86abe3]
public func findLineAndWordChunkLayoutInfo(
    _ bytes: [UInt8],
    tabWidth: UInt8 = 2,
    controlDisplay: ControlDisplay = .hidden,
    isASCIIOnly: Bool? = nil,
    widthMethod: WidthMethod = .unicode
) -> ChunkLayoutInfo {
    var wordBreaks: [LayoutWrapBreak] = []
    var cjkBreaks: [LayoutWrapBreak] = []
    let edges = scanChunkLayout(
        bytes,
        tabWidth: tabWidth,
        controlDisplay: controlDisplay,
        isASCIIOnly: isASCIIOnly,
        widthMethod: widthMethod,
        wordOnly: false
    ) { wb in
        if wb.kind.isWordBoundary {
            wordBreaks.append(wb)
        } else {
            cjkBreaks.append(wb)
        }
    }
    return ChunkLayoutInfo(wrapBreaks: wordBreaks, cjkBreaks: cjkBreaks, wordClasses: edges)
}
