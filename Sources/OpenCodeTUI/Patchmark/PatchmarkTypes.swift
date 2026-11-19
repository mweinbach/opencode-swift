/// Delimiter style for inline TeX math nodes (`$...$`, `$$...$$`, `\(...\)`).
// parity: patchmark/src/types.ts#MathDelimiter [status=implemented hash=52486f67ab1d]
public enum MathDelimiter: String, Equatable, Hashable, Sendable, Codable {
    case dollar
    case doubleDollar = "double-dollar"
    case paren
}

/// Delimiter style for block display math (`$$` or `$`).
public enum BlockMathDelimiter: String, Equatable, Hashable, Sendable, Codable {
    case doubleDollar = "double-dollar"
    case dollar
}

/// Parsed inline AST node produced by Patchmark's CommonMark + GFM + Math inline parser.
// parity: patchmark/src/types.ts#InlineNode [status=implemented hash=3b283b941ea3]
public indirect enum InlineNode: Equatable, Hashable, Sendable, Codable {
    case text(String)
    case strong([InlineNode])
    case em([InlineNode])
    case del([InlineNode])
    case code(String)
    case math(source: String, delimiter: MathDelimiter, display: Bool)
    case link(href: String, title: String? = nil, children: [InlineNode])
    case image(src: String, alt: String, title: String? = nil, children: [InlineNode]? = nil)
    case htmlInline(String)
    case br

    public var typeName: String {
        switch self {
        case .text: return "text"
        case .strong: return "strong"
        case .em: return "em"
        case .del: return "del"
        case .code: return "code"
        case .math: return "math"
        case .link: return "link"
        case .image: return "image"
        case .htmlInline: return "html_inline"
        case .br: return "br"
        }
    }
}

/// Column alignment in a GFM table (`left`, `center`, `right`, or `nil` for unspecified).
// parity: patchmark/src/types.ts#TableAlign [status=implemented hash=461279619137]
public enum TableAlign: String, Equatable, Hashable, Sendable, Codable {
    case left
    case center
    case right
}

/// ATX / Setext heading depth (`1` through `6`).
// parity: patchmark/src/types.ts#HeadingLevel [status=implemented hash=4f3c1d8e6a6e]
public enum HeadingLevel: Int, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case h1 = 1
    case h2 = 2
    case h3 = 3
    case h4 = 4
    case h5 = 5
    case h6 = 6
}

/// Single list item node, with optional GFM task list checkbox state (`checked`).
// parity: patchmark/src/types.ts#ListItemNode [status=implemented hash=141381c2b506]
public struct ListItemNode: Equatable, Hashable, Sendable, Codable {
    public var checked: Bool?
    public var blocks: [BlockKind]

    public init(checked: Bool? = nil, blocks: [BlockKind]) {
        self.checked = checked
        self.blocks = blocks
    }
}

/// Parsed top-level or nested block payload.
// parity: patchmark/src/types.ts#BlockKind [status=implemented hash=eb82f9ad8511]
public indirect enum BlockKind: Equatable, Hashable, Sendable, Codable {
    case paragraph(inlines: [InlineNode])
    case heading(level: HeadingLevel, inlines: [InlineNode])
    case code(
        language: String? = nil,
        meta: String? = nil,
        source: String,
        htmlLiteral: String? = nil,
        fence: String,
        indented: Bool = false,
        complete: Bool
    )
    case mermaid(source: String, htmlLiteral: String? = nil, complete: Bool)
    case math(source: String, delimiter: BlockMathDelimiter, complete: Bool)
    case blockquote(blocks: [BlockKind])
    case list(ordered: Bool, marker: String, start: Int? = nil, tight: Bool, items: [ListItemNode])
    case table(align: [TableAlign?], headers: [[InlineNode]], rows: [[[InlineNode]]])
    case htmlBlock(raw: String)
    case hr
    case group(blocks: [BlockKind])

    public var typeName: String {
        switch self {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .code: return "code"
        case .mermaid: return "mermaid"
        case .math: return "math"
        case .blockquote: return "blockquote"
        case .list: return "list"
        case .table: return "table"
        case .htmlBlock: return "html_block"
        case .hr: return "hr"
        case .group: return "group"
        }
    }
}

/// Lifecycle state of an emitted `MarkdownBlock`.
public enum MarkdownBlockStatus: String, Equatable, Hashable, Sendable, Codable {
    case streaming
    case settled
}

/// Incremental markdown block emitted by `PatchmarkStream`.
// parity: patchmark/src/types.ts#MarkdownBlock [status=implemented hash=d71fd488efab]
public struct MarkdownBlock: Equatable, Hashable, Sendable, Codable {
    /// Monotonic stable block ID within the stream (0, 1, 2, ...).
    public var id: Int
    /// Start offset in the source string (UTF-16 code units).
    public var start: Int
    /// End offset in the source string (UTF-16 code units).
    public var end: Int
    /// Raw markdown slice for this block.
    public var raw: String
    /// Whether this block is settled (immutable) or still actively growing at the stream tail.
    public var status: MarkdownBlockStatus
    /// Parsed block payload and inline AST.
    public var kind: BlockKind
    /// Lazily or eagerly rendered HTML when requested.
    public var html: String?
    /// Source of the reference definitions this block uses, for renderers that parse one block at a time.
    public var defs: String?
    /// For a streaming block: `raw` with the tail healed (open markers closed, dangling markers hidden).
    public var liveRaw: String?

    public init(
        id: Int,
        start: Int,
        end: Int,
        raw: String,
        status: MarkdownBlockStatus,
        kind: BlockKind,
        html: String? = nil,
        defs: String? = nil,
        liveRaw: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.raw = raw
        self.status = status
        self.kind = kind
        self.html = html
        self.defs = defs
        self.liveRaw = liveRaw
    }
}

/// Minimal patch operation transforming the previous frame's block list into the new frame's blocks.
// parity: patchmark/src/types.ts#BlockPatch [status=implemented hash=a7ed09f43143]
public enum BlockPatch: Equatable, Hashable, Sendable, Codable {
    case append(block: MarkdownBlock)
    case replace(id: Int, index: Int, block: MarkdownBlock)
    case finalize(id: Int, index: Int, block: MarkdownBlock)
    case truncate(keepCount: Int)

    public var op: String {
        switch self {
        case .append: return "append"
        case .replace: return "replace"
        case .finalize: return "finalize"
        case .truncate: return "truncate"
        }
    }
}

/// Snapshot and incremental patch list emitted after a stream `append`, `update`, or `finalize`.
// parity: patchmark/src/types.ts#StreamFrame [status=implemented hash=919ff7d776c8]
public struct StreamFrame: Equatable, Hashable, Sendable, Codable {
    /// Full accumulated source text.
    public let text: String
    /// UTF-16 code unit offset up to which blocks are settled and will never be reparsed on append.
    public let settledOffset: Int
    /// Current blocks array.
    public let blocks: [MarkdownBlock]
    /// Minimal patch list transforming the previous frame's blocks into `blocks`.
    public let patches: [BlockPatch]
    /// Any trailing bare marker held back to prevent 1-frame paragraph-to-heading/list pops.
    public let heldMarker: String
    /// Exact number of source UTF-16 code units scanned during this step.
    public let charsScanned: Int

    public init(
        text: String,
        settledOffset: Int,
        blocks: [MarkdownBlock],
        patches: [BlockPatch],
        heldMarker: String,
        charsScanned: Int
    ) {
        self.text = text
        self.settledOffset = settledOffset
        self.blocks = blocks
        self.patches = patches
        self.heldMarker = heldMarker
        self.charsScanned = charsScanned
    }
}

/// Configuration options for `PatchmarkStream`.
// parity: patchmark/src/types.ts#StreamOptions [status=implemented hash=bac27a38f12f]
public struct StreamOptions: Equatable, Hashable, Sendable, Codable {
    /// Enable GFM tables, strikethrough, task lists, and autolinks (default: true).
    public var gfm: Bool
    /// Enable TeX math (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`) with Pandoc currency rules (default: true).
    public var math: Bool
    /// Repair unclosed inline syntax on the active streaming tail block (default: true).
    public var heal: Bool
    /// Hold bare trailing block markers (`-`, `##`, `1.`, `>`) until their first word arrives (default: true).
    public var holdPendingMarkers: Bool
    /// Settle top-level blocks as soon as CommonMark closes them, or wait until a later visible block begins (default: true).
    public var settleOnComplete: Bool
    /// Keep an HTML block that opens a tag together with following blocks up to the closing block as one `group` block (default: false).
    public var groupHtmlBlocks: Bool
    /// Eagerly populate `block.html` on each emitted block (default: false).
    public var renderHtml: Bool

    public init(
        gfm: Bool = true,
        math: Bool = true,
        heal: Bool = true,
        holdPendingMarkers: Bool = true,
        settleOnComplete: Bool = true,
        groupHtmlBlocks: Bool = false,
        renderHtml: Bool = false
    ) {
        self.gfm = gfm
        self.math = math
        self.heal = heal
        self.holdPendingMarkers = holdPendingMarkers
        self.settleOnComplete = settleOnComplete
        self.groupHtmlBlocks = groupHtmlBlocks
        self.renderHtml = renderHtml
    }
}
