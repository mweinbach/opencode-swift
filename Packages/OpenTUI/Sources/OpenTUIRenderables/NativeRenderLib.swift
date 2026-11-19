// Pure-Swift RenderLib backend facade (`core/src/zig.ts`).
// Zero OS / Foundation imports (Pure Tier).

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

// MARK: - Re-exported Audio Stream Enums & Core Handle Types

// parity: core/src/zig.ts#NativeAudioStreamState [status=implemented hash=3986b0a0e065]
public typealias RenderLibAudioStreamState = NativeAudioStreamState

// parity: core/src/zig.ts#NativeAudioStreamCloseReason [status=implemented hash=6a6777efa010]
public typealias RenderLibAudioStreamCloseReason = NativeAudioStreamCloseReason

// parity: core/src/zig.ts#NativeAudioStreamFormat [status=implemented hash=d33f814d4aa3]
public typealias RenderLibAudioStreamFormat = NativeAudioStreamFormat

// parity: core/src/zig.ts#NativeHandle [status=implemented hash=c7cda345b998]
public struct NativeHandle<Tag>: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ pointer: FFIPointer) {
        self.rawValue = pointer.address
    }

    public var pointer: FFIPointer { FFIPointer(address: rawValue) }
    public var isNull: Bool { rawValue == 0 }
}

// parity: core/src/zig.ts#NativeContextHandle [status=implemented hash=cd5614a005d8]
public extension NativeContextHandle {
    /// Zero/invalid sentinel context handle.
    static var invalid: NativeContextHandle { NativeContextHandle(contextId: 0) }
}

// parity: core/src/zig.ts#MAX_LINK_URL_BYTES [status=implemented hash=90c8cea76dfa]
public let MAX_LINK_URL_BYTES: Int = 512

// parity: core/src/zig.ts#NativeContextOptions [status=implemented hash=61bf0843635f]
public extension NativeContextOptions {
    static var defaultNativeOptions: NativeContextOptions {
        NativeContextOptions(objectCapacity: 65_536, renderCellsMax: 1_000_000)
    }
}

// parity: core/src/zig.ts#ContextObjectHandle [status=implemented hash=6e186c9c03e0]
public struct ContextObjectHandle: Equatable, Hashable, Sendable, Codable {
    public let context: NativeContextHandle
    public let contextId: UInt64
    public let slot: UInt32
    public let generation: UInt32

    public init(context: NativeContextHandle, slot: UInt32, generation: UInt32) {
        self.context = context
        self.contextId = context.contextId
        self.slot = slot
        self.generation = generation
    }

    public init(contextId: UInt64, slot: UInt32, generation: UInt32) {
        self.context = NativeContextHandle(contextId: contextId)
        self.contextId = contextId
        self.slot = slot
        self.generation = generation
    }

    public func toZigHandle() -> ZigHandle {
        ZigHandle(contextId: contextId, slot: slot, generation: generation)
    }
}

// parity: core/src/zig.ts#SessionHandle [status=implemented hash=53de61a7f5dd]
public extension SessionHandle {
    var contextHandle: NativeContextHandle { NativeContextHandle(contextId: contextId) }
    var objectHandle: ContextObjectHandle {
        ContextObjectHandle(contextId: contextId, slot: slot, generation: generation)
    }
}

// parity: core/src/zig.ts#SceneNodeHandle [status=implemented hash=7922d5ea5db2]
public extension SceneNodeHandle {
    var contextHandle: NativeContextHandle { NativeContextHandle(contextId: contextId) }
    var objectHandle: ContextObjectHandle {
        ContextObjectHandle(contextId: contextId, slot: slot, generation: generation)
    }
}

// parity: core/src/zig.ts#ContextBufferHandle [status=implemented hash=b34be3d52e26]
public struct ContextBufferHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextEditBufferHandle [status=implemented hash=f664317e83ee]
public struct ContextEditBufferHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextEditorViewHandle [status=implemented hash=75a9f1a02875]
public struct ContextEditorViewHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextSyntaxStyleHandle [status=implemented hash=d5e0a16ce38f]
public struct ContextSyntaxStyleHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextTextBufferHandle [status=implemented hash=f5db581fb6cc]
public struct ContextTextBufferHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextTextBufferViewHandle [status=implemented hash=d850cdee3ec1]
public struct ContextTextBufferViewHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextImageHandle [status=implemented hash=61978702e9e0]
public struct ContextImageHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextImagePixelsHandle [status=implemented hash=cc75de5835ad]
public struct ContextImagePixelsHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextUnicodeHandle [status=implemented hash=05c475e64da2]
public struct ContextUnicodeHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextMarkdownHandle [status=implemented hash=43a94a1abf34]
public struct ContextMarkdownHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// parity: core/src/zig.ts#ContextEmbeddedTerminalHandle [status=implemented hash=62bd132b0d30]
public struct ContextEmbeddedTerminalHandle: Equatable, Hashable, Sendable, Codable {
    public let raw: ContextObjectHandle
    public var context: NativeContextHandle { raw.context }
    public var contextId: UInt64 { raw.contextId }
    public var slot: UInt32 { raw.slot }
    public var generation: UInt32 { raw.generation }
    public init(_ raw: ContextObjectHandle) { self.raw = raw }
}

// MARK: - Markdown, Text/Edit Buffer, Scene & Session Types

// parity: core/src/zig.ts#NativeMarkdownOptions [status=implemented hash=91899db2896b]
public struct NativeMarkdownOptions: Equatable, Hashable, Sendable {
    public var flags: UInt32
    public var syntaxStyle: ContextSyntaxStyleHandle?
    public var hookFilter: [String]
    public var sourceByteLimit: Int?

    public init(
        flags: UInt32 = 0,
        syntaxStyle: ContextSyntaxStyleHandle? = nil,
        hookFilter: [String] = [],
        sourceByteLimit: Int? = nil
    ) {
        self.flags = flags
        self.syntaxStyle = syntaxStyle
        self.hookFilter = hookFilter
        self.sourceByteLimit = sourceByteLimit
    }
}

// parity: core/src/zig.ts#NativeMarkdownResult [status=implemented hash=2c5c3c1f9e3b]
public struct NativeMarkdownResult: Equatable, Hashable, Sendable, Codable {
    public var changed: Int
    public var committed: Int
    public var removedFrom: Int?

    public init(changed: Int = 0, committed: Int = 0, removedFrom: Int? = nil) {
        self.changed = changed
        self.committed = committed
        self.removedFrom = removedFrom
    }
}

// parity: core/src/zig.ts#NativeMarkdownBlock [status=implemented hash=a275a532740e]
public struct NativeMarkdownBlock: Equatable, Hashable, Sendable, Codable {
    public var index: Int
    public var parent: Int?
    public var kind: UInt32
    public var flags: UInt32
    public var sourceStart: Int
    public var sourceEnd: Int
    public var infoStart: Int
    public var infoEnd: Int
    public var number: Int

    public init(
        index: Int = 0,
        parent: Int? = nil,
        kind: UInt32 = 0,
        flags: UInt32 = 0,
        sourceStart: Int = 0,
        sourceEnd: Int = 0,
        infoStart: Int = 0,
        infoEnd: Int = 0,
        number: Int = 0
    ) {
        self.index = index
        self.parent = parent
        self.kind = kind
        self.flags = flags
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.infoStart = infoStart
        self.infoEnd = infoEnd
        self.number = number
    }
}

// parity: core/src/zig.ts#NativeMarkdownLeaf [status=implemented hash=168569731343]
public struct NativeMarkdownLeaf: Equatable, Sendable {
    public var chunks: [TextChunk]
    public var spans: [UInt32]

    public init(chunks: [TextChunk] = [], spans: [UInt32] = []) {
        self.chunks = chunks
        self.spans = spans
    }
}

// parity: core/src/zig.ts#SessionBuffer [status=implemented hash=470bc83ada1c]
public enum NativeSessionBufferSlot: String, Equatable, Hashable, Sendable, Codable {
    case current
    case next
}

// parity: core/src/zig.ts#NativeContextEditBufferOptions [status=implemented hash=7970872543aa]
public struct NativeContextEditBufferOptions: Equatable, Hashable, Sendable {
    public var widthMethod: TextWidthMethod
    public var followSessionWidth: Bool

    public init(widthMethod: TextWidthMethod = .unicode, followSessionWidth: Bool = false) {
        self.widthMethod = widthMethod
        self.followSessionWidth = followSessionWidth
    }
}

// parity: core/src/zig.ts#NativeEditBufferInfo [status=implemented hash=06ca68c1ea35]
public struct NativeEditBufferInfo: Equatable, Hashable, Sendable, Codable {
    public var contentEpoch: UInt64
    public var byteLength: Int
    public var lineCount: Int
    public var cursor: LogicalCursor
    public var canUndo: Bool
    public var canRedo: Bool
    public var tabWidth: Int

    public init(
        contentEpoch: UInt64 = 0,
        byteLength: Int = 0,
        lineCount: Int = 1,
        cursor: LogicalCursor = LogicalCursor(),
        canUndo: Bool = false,
        canRedo: Bool = false,
        tabWidth: Int = 2
    ) {
        self.contentEpoch = contentEpoch
        self.byteLength = byteLength
        self.lineCount = lineCount
        self.cursor = cursor
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.tabWidth = tabWidth
    }
}

// parity: core/src/zig.ts#NativeTextBufferInfo [status=implemented hash=e30822b2a380]
public struct NativeTextBufferInfo: Equatable, Hashable, Sendable, Codable {
    public var contentEpoch: UInt64
    public var byteLength: Int
    public var textLength: Int
    public var lineCount: Int
    public var highlightCount: Int
    public var tabWidth: Int

    public init(
        contentEpoch: UInt64 = 0,
        byteLength: Int = 0,
        textLength: Int = 0,
        lineCount: Int = 1,
        highlightCount: Int = 0,
        tabWidth: Int = 2
    ) {
        self.contentEpoch = contentEpoch
        self.byteLength = byteLength
        self.textLength = textLength
        self.lineCount = lineCount
        self.highlightCount = highlightCount
        self.tabWidth = tabWidth
    }
}

// parity: core/src/zig.ts#NativeEncodedStyledText [status=implemented hash=9e26a30dddfc]
public struct NativeEncodedStyledText: Equatable, Sendable {
    public var bytes: [UInt8]
    public var records: [UInt32]
    public var count: Int
    public var urlBytes: [UInt8]
    public var chunks: [TextChunk]

    public init(
        bytes: [UInt8] = [],
        records: [UInt32] = [],
        count: Int = 0,
        urlBytes: [UInt8] = [],
        chunks: [TextChunk] = []
    ) {
        self.bytes = bytes
        self.records = records
        self.count = count
        self.urlBytes = urlBytes
        self.chunks = chunks
    }
}

// parity: core/src/zig.ts#NativeTextViewCommand [status=implemented hash=d6e133b04083]
public enum NativeTextViewCommand: UInt32, Equatable, Hashable, Sendable, Codable {
    case wrapWidth = 0
    case wrapMode = 1
    case firstLineOffset = 2
    case tabIndicator = 3
    case truncate = 4
    case textAlign = 5
}

// parity: core/src/zig.ts#NativeEditCommand [status=implemented hash=b03be2de1287]
public enum NativeEditCommand: UInt32, Equatable, Hashable, Sendable, Codable {
    case deleteForward = 0
    case backspace = 1
    case newLine = 2
    case deleteLine = 3
    case moveLeft = 4
    case moveRight = 5
    case moveUp = 6
    case moveDown = 7
    case gotoLine = 8
    case cursorOffset = 9
    case clear = 10
    case clearHistory = 11
    case debugRope = 12
    case cursorOffsetAtomic = 13
    case keepOutside = 14
}

// parity: core/src/zig.ts#NativeEditAtomic [status=implemented hash=4b4069f6b65b]
public let NativeEditAtomic: UInt32 = 1

// parity: core/src/zig.ts#NativeEditPositionQuery [status=implemented hash=2968719d9a8f]
public enum NativeEditPositionQuery: UInt32, Equatable, Hashable, Sendable, Codable {
    case cursor = 0
    case nextWord = 1
    case prevWord = 2
    case eol = 3
    case offset = 4
    case coords = 5
    case lineStart = 6
    case end = 7
    case prevChar = 8
}

// parity: core/src/zig.ts#NativeEditorStyleMask [status=implemented hash=b5075294128d]
public struct NativeEditorStyleMask: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let foreground = NativeEditorStyleMask(rawValue: 1)
    public static let background = NativeEditorStyleMask(rawValue: 2)
    public static let attributes = NativeEditorStyleMask(rawValue: 4)
    public static let all: NativeEditorStyleMask = [.foreground, .background, .attributes]
}

// parity: core/src/zig.ts#NativeEditorStyle [status=implemented hash=2ec4e74813da]
public struct NativeEditorStyle: Equatable, Hashable, Sendable {
    public var fg: RGBA?
    public var bg: RGBA?
    public var attributes: UInt32?
    public var suppliedAttributes: UInt32?

    public init(
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        attributes: UInt32? = nil,
        suppliedAttributes: UInt32? = nil
    ) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.suppliedAttributes = suppliedAttributes
    }
}

// parity: core/src/zig.ts#NativeEditHighlightOperation [status=implemented hash=36534f0ec078]
public enum NativeEditHighlightOperation: UInt32, Equatable, Hashable, Sendable, Codable {
    case addLine = 0
    case addRange = 1
    case removeRef = 2
    case clearLine = 3
    case clearAll = 4
}

// parity: core/src/zig.ts#NativeEditMarkOperation [status=implemented hash=b282946f6f6c]
public enum NativeEditMarkOperation: UInt32, Equatable, Hashable, Sendable, Codable {
    case add = 0
    case remove = 1
    case clear = 2
}

// parity: core/src/zig.ts#NativeEditorViewport [status=implemented hash=d1756248e836]
public struct NativeEditorViewport: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// parity: core/src/zig.ts#NativeEditorCommand [status=implemented hash=07b6952f8479]
public enum NativeEditorCommand: UInt32, Equatable, Hashable, Sendable, Codable {
    case moveUp = 0
    case moveDown = 1
    case gotoLineEnd = 2
    case deleteSelection = 3
    case cursorOffset = 4
    case wrapMode = 5
    case tabIndicator = 6
}

// parity: core/src/zig.ts#NativeEditorSelectionOperation [status=implemented hash=08514a0a351e]
public enum NativeEditorSelectionOperation: UInt32, Equatable, Hashable, Sendable, Codable {
    case set = 0
    case update = 1
    case reset = 2
    case local = 3
    case localUpdate = 4
    case localReset = 5
    case cell = 6
    case occupancy = 7
    case inclusive = 8
    case colors = 9
}

// parity: core/src/zig.ts#NativeEditorSelection [status=implemented hash=d47a1cca0ef4]
public struct NativeEditorSelection: Equatable, Hashable, Sendable {
    public var operation: NativeEditorSelectionOperation
    public var behavior: SelectionBehavior
    public var start: Int?
    public var end: Int?
    public var anchorX: Int?
    public var anchorY: Int?
    public var focusX: Int?
    public var focusY: Int?
    public var updateCursor: Bool
    public var followCursor: Bool
    public var fg: RGBA?
    public var bg: RGBA?
    public var occupancy: SelectionOccupancy?

    public init(
        operation: NativeEditorSelectionOperation,
        behavior: SelectionBehavior = .cell,
        start: Int? = nil,
        end: Int? = nil,
        anchorX: Int? = nil,
        anchorY: Int? = nil,
        focusX: Int? = nil,
        focusY: Int? = nil,
        updateCursor: Bool = false,
        followCursor: Bool = false,
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        occupancy: SelectionOccupancy? = nil
    ) {
        self.operation = operation
        self.behavior = behavior
        self.start = start
        self.end = end
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.focusX = focusX
        self.focusY = focusY
        self.updateCursor = updateCursor
        self.followCursor = followCursor
        self.fg = fg
        self.bg = bg
        self.occupancy = occupancy
    }
}

// parity: core/src/zig.ts#NativeEditorViewInfo [status=implemented hash=7bf37403688b]
public struct NativeEditorViewInfo: Equatable, Hashable, Sendable, Codable {
    public var virtualLineCount: Int
    public var totalVirtualLineCount: Int
    public var selection: TextSelectionRange?
    public var selectionOccupancy: SelectionOccupancy

    public init(
        virtualLineCount: Int = 0,
        totalVirtualLineCount: Int = 0,
        selection: TextSelectionRange? = nil,
        selectionOccupancy: SelectionOccupancy = .cell
    ) {
        self.virtualLineCount = virtualLineCount
        self.totalVirtualLineCount = totalVirtualLineCount
        self.selection = selection
        self.selectionOccupancy = selectionOccupancy
    }
}

// parity: core/src/zig.ts#NativeEditorPositionQuery [status=implemented hash=91d94bae6099]
public enum NativeEditorPositionQuery: UInt32, Equatable, Hashable, Sendable, Codable {
    case cursor = 0
    case nextWord = 1
    case prevWord = 2
    case eol = 3
    case visualSol = 4
    case visualEol = 5
}

// parity: core/src/zig.ts#NativeEditEvent [status=implemented hash=3cbb37e20da9]
public struct NativeEditEvent: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let cursorChanged = NativeEditEvent(rawValue: 1)
    public static let contentChanged = NativeEditEvent(rawValue: 2)
    public static let historyCursorChanged = NativeEditEvent(rawValue: 4)
}

// parity: core/src/zig.ts#NativeEditEventName [status=implemented hash=2109716effcf]
public enum NativeEditEventName: String, Equatable, Hashable, Sendable, Codable {
    case cursorChangedKebab = "cursor-changed"
    case contentChanged = "content-changed"
    case cursorChanged = "cursorChanged"
}

// parity: core/src/zig.ts#NativeSceneEditorOptions [status=implemented hash=6d98883409d8]
public extension NativeSceneEditorOptions {
    static var defaultEditorOptions: NativeSceneEditorOptions { NativeSceneEditorOptions() }
}

// parity: core/src/zig.ts#NativeEditorReplacement [status=implemented hash=85c7337764fa]
public struct NativeEditorReplacement: Equatable, Hashable, Sendable, Codable {
    public var deleted: Bool
    public var inserted: Bool

    public init(deleted: Bool = false, inserted: Bool = false) {
        self.deleted = deleted
        self.inserted = inserted
    }
}

// parity: core/src/zig.ts#NativeSceneBoxDetails [status=implemented hash=b068568bcb61]
public extension NativeSceneBoxDetails {
    static var emptyDetails: NativeSceneBoxDetails { NativeSceneBoxDetails() }
}

// parity: core/src/zig.ts#NativeScenePaint [status=implemented hash=c97c26e5a817]
public extension NativeScenePaint {
    static var defaultPaint: NativeScenePaint { NativeScenePaint() }
}

// parity: core/src/zig.ts#NativeScenePaintUpdate [status=implemented hash=58492bb0c7fb]
public extension NativeScenePaintUpdate {
    static var emptyUpdate: NativeScenePaintUpdate { NativeScenePaintUpdate() }
}

// parity: core/src/zig.ts#NATIVE_SCENE_MUTATIONS_MAX [status=implemented hash=5884b2f05066]
public let NATIVE_SCENE_MUTATIONS_MAX: Int = Int(NativeABI.OT_SCENE_MUTATIONS_MAX)

// parity: core/src/zig.ts#NativeStyleGroup [status=implemented hash=1791af32e01c]
public enum NativeStyleGroup: UInt32, Equatable, Hashable, Sendable, Codable {
    case `enum` = 0
    case float = 1
    case value = 2
    case border = 3
    case dimension = 4
}

// parity: core/src/zig.ts#NativeStyleFlags [status=implemented hash=9971810273a7]
public struct NativeStyleFlags: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = NativeStyleFlags([])
    public static let disableFlexShrink = NativeStyleFlags(rawValue: 1)
    public static let content = NativeStyleFlags(rawValue: 2)
}

// parity: core/src/zig.ts#NATIVE_EDGE_NONE [status=implemented hash=aba144a2b51b]
public let NATIVE_EDGE_NONE: UInt32 = UInt32(NativeABI.OT_EDGE_NONE)

// parity: core/src/zig.ts#NativeBorder [status=implemented hash=fbef228f1e9a]
public struct NativeBorder: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = NativeBorder([])
    public static let left = NativeBorder(rawValue: UInt32(NativeABI.OT_BORDER_LEFT))
    public static let bottom = NativeBorder(rawValue: UInt32(NativeABI.OT_BORDER_BOTTOM))
    public static let right = NativeBorder(rawValue: UInt32(NativeABI.OT_BORDER_RIGHT))
    public static let top = NativeBorder(rawValue: UInt32(NativeABI.OT_BORDER_TOP))
    public static let all = NativeBorder(rawValue: UInt32(NativeABI.OT_BORDER_ALL))

    public var mask: NativeBorderMask {
        NativeBorderMask(rawValue: UInt8(truncatingIfNeeded: rawValue))
    }
}

// parity: core/src/zig.ts#NativeSceneLayout [status=implemented hash=bd468fbd9740]
public extension NativeSceneLayout {
    static var emptyLayout: NativeSceneLayout { .zero }
}

// parity: core/src/zig.ts#NativeSceneFrameOptions [status=implemented hash=174b2ca9d6d8]
public struct NativeSceneFrameOptions: Equatable, Hashable, Sendable {
    public var background: RGBA
    public var useMouse: Bool
    public var excludedHitNum: UInt32
    public var maxLayoutRounds: Int
    public var maxHostRequests: Int
    public var preserveUnwritten: Bool

    public init(
        background: RGBA = RGBA.fromInts(0, 0, 0, 255),
        useMouse: Bool = false,
        excludedHitNum: UInt32 = 0,
        maxLayoutRounds: Int = 8,
        maxHostRequests: Int = 64,
        preserveUnwritten: Bool = false
    ) {
        self.background = background
        self.useMouse = useMouse
        self.excludedHitNum = excludedHitNum
        self.maxLayoutRounds = maxLayoutRounds
        self.maxHostRequests = maxHostRequests
        self.preserveUnwritten = preserveUnwritten
    }
}

// parity: core/src/zig.ts#NativeSceneHook [status=implemented hash=07ad26602e48]
public struct NativeSceneHook: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let update = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_UPDATE))
    public static let resize = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_RESIZE))
    public static let layoutChanged = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_LAYOUT_CHANGED))
    public static let renderBefore = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_RENDER_BEFORE))
    public static let renderAfter = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_RENDER_AFTER))
    public static let renderSelf = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_RENDER_SELF))
    public static let idleUpdate = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_IDLE_UPDATE))
    public static let scroll = NativeSceneHook(rawValue: UInt32(NativeABI.OT_SCENE_HOOK_SCROLL))
}

// parity: core/src/zig.ts#NativeSceneFrame [status=implemented hash=61237c78ad99]
public extension NativeSceneFrame {
    var isTerminal: Bool { self == .done }
}

// parity: core/src/zig.ts#NativeScenePaintPhase [status=implemented hash=cb1378983bf2]
public enum NativeScenePaintPhase: UInt32, Equatable, Hashable, Sendable, Codable {
    case before = 0
    case `self` = 1
    case after = 2
}

// parity: core/src/zig.ts#NativeScenePaintSlot [status=implemented hash=7f4801b74ddb]
public struct NativeScenePaintSlot: Equatable, Sendable {
    public let node: SceneNodeHandle
    public let num: UInt32
    public let hooks: UInt32
    public let opacity: Double
    public let paintLayout: NativeSceneLayout
    public let publicLayout: NativeSceneLayout?

    public init(
        node: SceneNodeHandle,
        num: UInt32,
        hooks: UInt32,
        opacity: Double = 1.0,
        paintLayout: NativeSceneLayout = .zero,
        publicLayout: NativeSceneLayout? = nil
    ) {
        self.node = node
        self.num = num
        self.hooks = hooks
        self.opacity = opacity
        self.paintLayout = paintLayout
        self.publicLayout = publicLayout
    }
}

// parity: core/src/zig.ts#NativeSceneFrameRequest [status=implemented hash=efdc46e16b15]
public extension NativeSceneFrameRequest {
    var isDone: Bool { kind == .done }
}

// parity: core/src/zig.ts#NativeSplitSnapshot [status=implemented hash=6e30870b8e78]
public extension NativeSplitSnapshot {
    var hasRows: Bool { rowColumns > 0 }
}

// parity: core/src/zig.ts#NativeSessionSplitControl [status=implemented hash=e3676924822a]
public enum NativeSessionSplitControl: Equatable, Hashable, Sendable {
    case reset(seedRows: Int, pinnedRenderOffset: Int)
    case sync(pinnedRenderOffset: Int)
    case outputOffset(surfaceOffset: Int)
    case renderOffset(renderOffset: Int)
    case transition(
        mode: String,
        sourceTopLine: Int,
        sourceHeight: Int,
        targetTopLine: Int,
        targetHeight: Int,
        scrollLines: Int?
    )
    case clearTransition
}

// parity: core/src/zig.ts#NativeSceneTextOptions [status=implemented hash=a5cecf043455]
public extension NativeSceneTextOptions {
    static var defaultOptions: NativeSceneTextOptions { NativeSceneTextOptions() }
}

// parity: core/src/zig.ts#NativeBufferGrid [status=implemented hash=d0101d84e2e4]
public struct NativeBufferGrid: Equatable, Hashable, Sendable {
    public var borderChars: [UInt32]
    public var borderFg: RGBA
    public var borderBg: RGBA
    public var columnOffsets: [Int32]
    public var rowOffsets: [Int32]
    public var drawInner: Bool
    public var drawOuter: Bool

    public init(
        borderChars: [UInt32] = borderCharsToArray(BorderChars.single),
        borderFg: RGBA = .defaultForeground(),
        borderBg: RGBA = RGBA.fromInts(0, 0, 0, 0),
        columnOffsets: [Int32] = [],
        rowOffsets: [Int32] = [],
        drawInner: Bool = true,
        drawOuter: Bool = true
    ) {
        self.borderChars = borderChars
        self.borderFg = borderFg
        self.borderBg = borderBg
        self.columnOffsets = columnOffsets
        self.rowOffsets = rowOffsets
        self.drawInner = drawInner
        self.drawOuter = drawOuter
    }
}

// parity: core/src/zig.ts#NativeBufferStack [status=implemented hash=14ea966da7e6]
public enum NativeBufferStack: Equatable, Hashable, Sendable {
    case getOpacity
    case pushScissor(x: Int, y: Int, width: Int, height: Int)
    case popScissor
    case clearScissors
    case pushOpacity(Double)
    case popOpacity
    case clearOpacity
}

// parity: core/src/zig.ts#NativeDrawingTarget [status=implemented hash=46b019e81c78]
public enum NativeDrawingTarget: Equatable, Sendable {
    case buffer(context: NativeContextHandle, target: ContextBufferHandle)
    case frame(context: NativeContextHandle, target: SessionHandle, frame: NativeSceneFrameRequest)

    public var context: NativeContextHandle {
        switch self {
        case .buffer(let ctx, _): return ctx
        case .frame(let ctx, _, _): return ctx
        }
    }
}

// parity: core/src/zig.ts#NativeBufferDraw [status=implemented hash=6fcf5d0908f9]
public enum NativeBufferDraw: Equatable, Sendable {
    case clear(background: RGBA?)
    case fill(x: Int, y: Int, width: Int, height: Int, background: RGBA)
    case text(
        x: Int,
        y: Int,
        text: String,
        foreground: RGBA,
        background: RGBA?,
        attributes: UInt32,
        maxWidth: Int?,
        ellipsis: Bool
    )
    case cell(x: Int, y: Int, char: UInt32, foreground: RGBA, background: RGBA, attributes: UInt32)
    case cellBlend(x: Int, y: Int, char: UInt32, foreground: RGBA, background: RGBA, attributes: UInt32)
    case char(x: Int, y: Int, char: UInt32, foreground: RGBA, background: RGBA, attributes: UInt32)
    case box(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        foreground: RGBA,
        background: RGBA,
        titleColor: RGBA?,
        packedOptions: UInt32,
        borderChars: [UInt32]?,
        text: String?,
        bottomTitle: String?
    )
    case compose(
        x: Int,
        y: Int,
        source: ContextBufferHandle,
        sourceX: Int?,
        sourceY: Int?,
        sourceWidth: Int?,
        sourceHeight: Int?
    )
    case respectAlpha(enabled: Bool)
}

// parity: core/src/zig.ts#NativeContextImageDraw [status=implemented hash=f6fc12c8e95f]
public struct NativeContextImageDraw: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var sourceX: Int?
    public var sourceY: Int?
    public var sourceWidth: Int?
    public var sourceHeight: Int?
    public var imageProtocol: ImageRenderProtocol

    public init(
        x: Int = 0,
        y: Int = 0,
        width: Int,
        height: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sourceX: Int? = nil,
        sourceY: Int? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        imageProtocol: ImageRenderProtocol = .auto
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.imageProtocol = imageProtocol
    }
}

// parity: core/src/zig.ts#NativeSceneTextSelectionOptions [status=implemented hash=54bb07d88e98]
public struct NativeSceneTextSelectionOptions: Equatable, Hashable, Sendable {
    public var operation: NativeSceneTextSelectionOp
    public var anchorX: Int
    public var anchorY: Int
    public var focusX: Int
    public var focusY: Int
    public var behavior: SelectionBehavior
    public var bg: RGBA?
    public var fg: RGBA?

    public init(
        operation: NativeSceneTextSelectionOp,
        anchorX: Int = 0,
        anchorY: Int = 0,
        focusX: Int = 0,
        focusY: Int = 0,
        behavior: SelectionBehavior = .cell,
        bg: RGBA? = nil,
        fg: RGBA? = nil
    ) {
        self.operation = operation
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.focusX = focusX
        self.focusY = focusY
        self.behavior = behavior
        self.bg = bg
        self.fg = fg
    }
}

// parity: core/src/zig.ts#NativeSceneTextMetrics [status=implemented hash=b05059170fbf]
public extension NativeSceneTextMetrics {
    static var zeroMetrics: NativeSceneTextMetrics { NativeSceneTextMetrics() }
}

// parity: core/src/zig.ts#NativeSceneSliderOptions [status=implemented hash=ccc194052506]
public extension NativeSceneSliderOptions {
    static var defaultSlider: NativeSceneSliderOptions { NativeSceneSliderOptions() }
}

// parity: core/src/zig.ts#NativeSceneArrowOptions [status=implemented hash=29a957d6af7c]
public extension NativeSceneArrowOptions {
    static var defaultArrow: NativeSceneArrowOptions { NativeSceneArrowOptions() }
}

// parity: core/src/zig.ts#NativeSceneScrollBarOptions [status=implemented hash=e8bfc9ab7430]
public extension NativeSceneScrollBarOptions {
    static var defaultScrollBar: NativeSceneScrollBarOptions { NativeSceneScrollBarOptions() }
}

// parity: core/src/zig.ts#NativeSceneScrollOptions [status=implemented hash=7e0aa2c62aba]
public extension NativeSceneScrollOptions {
    static var defaultScroll: NativeSceneScrollOptions { NativeSceneScrollOptions() }
}

// parity: core/src/zig.ts#NativeSceneRect [status=implemented hash=0ce8cd745cfb]
public extension NativeSceneRect {
    func toZigRect() -> ZigSceneRect {
        ZigSceneRect(x: x, y: y, width: width, height: height)
    }
}

// parity: core/src/zig.ts#NativeSceneScrollBarState [status=implemented hash=70e633490ced]
public extension NativeSceneScrollBarState {
    func toZigScrollBarState() -> ZigScrollBarState {
        ZigScrollBarState(
            visible: visible,
            track: track.toZigRect(),
            startArrow: startArrow.toZigRect(),
            endArrow: endArrow.toZigRect(),
            thumbStart: thumbStart,
            thumbSize: thumbSize
        )
    }
}

// parity: core/src/zig.ts#NativeSceneScrollState [status=implemented hash=faf78eb2b293]
public extension NativeSceneScrollState {
    func toZigScrollState() -> ZigScrollState {
        ZigScrollState(
            changes: changes,
            offsetX: offsetX,
            offsetY: offsetY,
            maxX: maxX,
            maxY: maxY,
            content: content.toZigRect(),
            viewport: viewport.toZigRect(),
            horizontalBar: horizontalBar.toZigScrollBarState(),
            verticalBar: verticalBar.toZigScrollBarState()
        )
    }
}

// parity: core/src/zig.ts#emptySceneScrollState [status=implemented hash=e455cbcb87e2]
public func emptySceneScrollState() -> NativeSceneScrollState {
    .empty
}

// parity: core/src/zig.ts#NativeSessionBufferLease [status=implemented hash=a7edfe0e743c]
public struct NativeSessionBufferLease: Equatable, Hashable, Sendable, Codable {
    public let handle: ContextObjectHandle
    public let width: Int
    public let height: Int
    public let generation: UInt64
    public let char: FFIPointer
    public let fg: FFIPointer
    public let bg: FFIPointer
    public let attributes: FFIPointer

    public init(
        handle: ContextObjectHandle,
        width: Int,
        height: Int,
        generation: UInt64,
        char: FFIPointer = .null,
        fg: FFIPointer = .null,
        bg: FFIPointer = .null,
        attributes: FFIPointer = .null
    ) {
        self.handle = handle
        self.width = width
        self.height = height
        self.generation = generation
        self.char = char
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

// parity: core/src/zig.ts#NativeContextBufferLease [status=implemented hash=4d120400c182]
public typealias NativeContextBufferLease = NativeSessionBufferLease

// parity: core/src/zig.ts#NativeContextBufferOptions [status=implemented hash=0c70a42ca347]
public struct NativeContextBufferOptions: Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var widthMethod: WidthMethod
    public var respectAlpha: Bool

    public init(
        width: Int,
        height: Int,
        widthMethod: WidthMethod = .unicode,
        respectAlpha: Bool = false
    ) {
        self.width = width
        self.height = height
        self.widthMethod = widthMethod
        self.respectAlpha = respectAlpha
    }
}

// parity: core/src/zig.ts#NATIVE_BUFFER_TEXT_BYTES_MAX [status=implemented hash=83662c1a3d06]
public let NATIVE_BUFFER_TEXT_BYTES_MAX: Int = Int(NativeABI.OT_BUFFER_TEXT_BYTES_MAX)

// parity: core/src/zig.ts#NativeSessionOptions [status=implemented hash=a180ec7db97a]
public extension NativeSessionOptions {
    static var defaultSessionOptions: NativeSessionOptions { NativeSessionOptions() }
}

// parity: core/src/zig.ts#NativeOutputTicket [status=implemented hash=6c50cf0df2dc]
public struct NativeOutputTicket: Equatable, Hashable, Sendable, Codable {
    public let session: SessionHandle
    public let requestId: UInt64
    public let byteCount: Int

    public init(session: SessionHandle, requestId: UInt64, byteCount: Int) {
        self.session = session
        self.requestId = requestId
        self.byteCount = byteCount
    }
}

// parity: core/src/zig.ts#NativeSessionState [status=implemented hash=ac666b2d13b9]
public extension NativeSessionState {
    var isOpen: Bool { self == .open }
}

// parity: core/src/zig.ts#NativeSessionRendererOptions [status=implemented hash=4d807e44f14c]
public extension NativeSessionRendererOptions {
    static func standard(width: Int, height: Int) -> NativeSessionRendererOptions {
        NativeSessionRendererOptions(width: width, height: height)
    }
}

// parity: core/src/zig.ts#NativeSessionRenderStatus [status=implemented hash=016092a6f548]
public extension NativeSessionRenderStatus {
    var didPresent: Bool { self == .presented }
}

// parity: core/src/zig.ts#NativeSessionRendererState [status=implemented hash=3a36e19ec7fc]
public extension NativeSessionRendererState {
    static var emptyState: NativeSessionRendererState { NativeSessionRendererState() }
}

// parity: core/src/zig.ts#NativeSessionKittyImageTransportStatus [status=implemented hash=ab8c44a60663]
public extension NativeSessionKittyImageTransportStatus {
    static var emptyTransportStatus: NativeSessionKittyImageTransportStatus {
        NativeSessionKittyImageTransportStatus()
    }
}

// parity: core/src/zig.ts#NATIVE_SESSION_CONTROL_PACKET_BYTES [status=implemented hash=faa9529b991c]
public let NATIVE_SESSION_CONTROL_PACKET_BYTES: Int = Int(NativeABI.OT_SESSION_CONTROL_PACKET_BYTES)

// parity: core/src/zig.ts#NativeSessionTerminalOptions [status=implemented hash=088be70e09e6]
public extension NativeSessionTerminalOptions {
    static var defaultTerminalOptions: NativeSessionTerminalOptions { NativeSessionTerminalOptions() }
}

// parity: core/src/zig.ts#SynchronizedOutput [status=implemented hash=c7554e527bcc]
public typealias SynchronizedOutput = SynchronizedOutputMode

// parity: core/src/zig.ts#NativeSessionTerminalPhase [status=implemented hash=af3908c97ffe]
public extension NativeSessionTerminalPhase {
    var isActive: Bool { self == .active }
}

// parity: core/src/zig.ts#NativeSessionPumpStatus [status=implemented hash=6874ee60fab1]
public extension NativeSessionPumpStatus {
    var isClosed: Bool { self == .closed }
}

// parity: core/src/zig.ts#NativeSessionPumpResult [status=implemented hash=bc368b8fe78c]
public struct NativeSessionPumpResult: Equatable, Hashable, Sendable, Codable {
    public var status: NativeSessionPumpStatus
    public var deadlineNs: UInt64?

    public init(status: NativeSessionPumpStatus = .idle, deadlineNs: UInt64? = nil) {
        self.status = status
        self.deadlineNs = deadlineNs
    }
}

// parity: core/src/zig.ts#NativeInputDrain [status=implemented hash=139ef2a3038c]
public struct NativeInputDrain: Equatable, Hashable, Sendable, Codable {
    public var consumed: Int
    public var count: Int
    public var deadlineNs: UInt64?

    public init(consumed: Int = 0, count: Int = 0, deadlineNs: UInt64? = nil) {
        self.consumed = consumed
        self.count = count
        self.deadlineNs = deadlineNs
    }
}

// parity: core/src/zig.ts#NativeSessionControl [status=implemented hash=f26a7eb1cf7b]
public extension NativeSessionControl {
    var isModeRestore: Bool {
        if case .restoreModes = self { return true }
        return false
    }
}

// parity: core/src/zig.ts#NativeSessionCursorOptions [status=implemented hash=3c21b629b3e1]
public struct NativeSessionCursorOptions: Equatable, Hashable, Sendable {
    public var style: CursorStyle?
    public var blinking: Bool?
    public var color: RGBA?
    public var x: Int?
    public var y: Int?
    public var visible: Bool?

    public init(
        style: CursorStyle? = nil,
        blinking: Bool? = nil,
        color: RGBA? = nil,
        x: Int? = nil,
        y: Int? = nil,
        visible: Bool? = nil
    ) {
        self.style = style
        self.blinking = blinking
        self.color = color
        self.x = x
        self.y = y
        self.visible = visible
    }
}

// parity: core/src/zig.ts#NativeSessionCapabilities [status=implemented hash=fd0222f14a42]
public extension NativeSessionCapabilities {
    static var defaultSessionCapabilities: NativeSessionCapabilities { NativeSessionCapabilities() }
}

// parity: core/src/zig.ts#NativeStatus [status=implemented hash=768455e7c888]
public enum NativeStatus: Int32, Equatable, Hashable, Sendable, Codable {
    case ok = 0
    case invalidArgument = -1
    case unsupportedVersion = -2
    case outOfMemory = -3
    case wrongThread = -4
    case internalError = -5
    case contextBusy = -6
    case wrongContext = -7
    case wrongKind = -8
    case staleHandle = -9
    case wrongSession = -10
    case outputBackpressure = -11
    case sessionClosed = -12
    case outputBusy = -13
    case staleOutput = -14
    case outputFailed = -15
    case objectLimit = -16
    case rendererAttached = -17
    case rendererNotAttached = -18
    case invalidPhase = -19
    case controlPacketLimit = -20
    case leaseLimit = -21
    case leaseBytesLimit = -22
    case staleLease = -23
    case unsupportedResource = -24
    case staleFrame = -25
    case layoutLimit = -26
    case frameBusy = -27
    case frameRequestLimit = -28
    case videoFailed = -60
}

// parity: core/src/zig.ts#NativeVideoInfo [status=implemented hash=7825487cdc79]
public struct NativeVideoInfo: Equatable, Hashable, Sendable, Codable {
    public var durationUs: UInt64
    public var width: Int
    public var height: Int
    public var fpsNum: Int
    public var fpsDen: Int
    public var hasAudio: Bool

    public init(
        durationUs: UInt64 = 0,
        width: Int = 0,
        height: Int = 0,
        fpsNum: Int = 30,
        fpsDen: Int = 1,
        hasAudio: Bool = false
    ) {
        self.durationUs = durationUs
        self.width = width
        self.height = height
        self.fpsNum = fpsNum
        self.fpsDen = fpsDen
        self.hasAudio = hasAudio
    }
}

// parity: core/src/zig.ts#NativeVideoState [status=implemented hash=cf984b467ecd]
public struct NativeVideoState: Equatable, Hashable, Sendable, Codable {
    public var currentTimeUs: UInt64
    public var framePtsUs: UInt64
    public var playing: Bool
    public var ended: Bool
    public var buffering: Bool
    public var audio: Bool
    public var hasFrame: Bool
    public var failed: Bool
    public var qualityTier: Int

    public init(
        currentTimeUs: UInt64 = 0,
        framePtsUs: UInt64 = 0,
        playing: Bool = false,
        ended: Bool = false,
        buffering: Bool = false,
        audio: Bool = false,
        hasFrame: Bool = false,
        failed: Bool = false,
        qualityTier: Int = 0
    ) {
        self.currentTimeUs = currentTimeUs
        self.framePtsUs = framePtsUs
        self.playing = playing
        self.ended = ended
        self.buffering = buffering
        self.audio = audio
        self.hasFrame = hasFrame
        self.failed = failed
        self.qualityTier = qualityTier
    }
}

// parity: core/src/zig.ts#NativeError [status=implemented hash=dda91fd6bd6f]
public final class NativeError: Error, Sendable, CustomStringConvertible {
    public let operation: String
    public let status: NativeStatus
    public let reason: String

    public init(operation: String, status: NativeStatus, reason: String? = nil) {
        self.operation = operation
        self.status = status
        self.reason = reason ?? "status \(status.rawValue)"
    }

    public var description: String {
        "\(operation) failed: \(reason)"
    }
}

public enum AudioEngineHandleTag: Sendable {}

// parity: core/src/zig.ts#AudioEngineHandle [status=implemented hash=b9014ba0c291]
public typealias AudioEngineHandle = NativeHandle<AudioEngineHandleTag>

// parity: core/src/zig.ts#ImageHandle [status=implemented hash=fc50ff07d09c]
public typealias ImageHandle = ContextImageHandle

public enum ClipboardServiceHandleTag: Sendable {}
public enum ClipboardOperationHandleTag: Sendable {}

// parity: core/src/zig.ts#ClipboardServiceHandle [status=implemented hash=a5d270304927]
public typealias ClipboardServiceHandle = NativeHandle<ClipboardServiceHandleTag>

// parity: core/src/zig.ts#ClipboardOperationHandle [status=implemented hash=34f05c965256]
public typealias ClipboardOperationHandle = NativeHandle<ClipboardOperationHandleTag>

// parity: core/src/zig.ts#NativeClipboardOperationStatus [status=implemented hash=5c05578d1717]
public enum NativeClipboardOperationStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case pending = 0
    case read = 1
    case empty = 2
    case written = 3
    case cleared = 4
    case unsupported = 5
    case cancelled = 6
    case timedOut = 7
    case limitExceeded = 8
    case failed = 9
    case invalidHandle = 10
}

// parity: core/src/zig.ts#NativeClipboardStartStatus [status=implemented hash=c453d9aa0ec8]
public enum NativeClipboardStartStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case ok = 0
    case invalidService = 1
    case shuttingDown = 2
    case limitExceeded = 3
    case invalidArgument = 4
    case outOfMemory = 5
}

// parity: core/src/zig.ts#NativeClipboardCancelStatus [status=implemented hash=c9025091c943]
public enum NativeClipboardCancelStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case requested = 0
    case alreadyTerminal = 1
    case invalidHandle = 2
}

// parity: core/src/zig.ts#NativeClipboardCopyStatus [status=implemented hash=2d3858fb02a5]
public enum NativeClipboardCopyStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case ok = 0
    case bufferTooSmall = 1
    case invalidHandle = 2
    case invalidState = 3
    case invalidArgument = 4
}

// parity: core/src/zig.ts#NativeClipboardDestroyStatus [status=implemented hash=03c0313ef43b]
public enum NativeClipboardDestroyStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case destroyed = 0
    case notReady = 1
    case invalidHandle = 2
}

// parity: core/src/zig.ts#NativeClipboardShutdownStatus [status=implemented hash=97d3632e9cd9]
public enum NativeClipboardShutdownStatus: UInt32, Equatable, Hashable, Sendable, Codable {
    case pending = 0
    case ready = 1
    case invalidHandle = 2
}

// parity: core/src/zig.ts#EmbeddedTerminalCursor [status=implemented hash=29db6d71cc03]
public extension EmbeddedTerminalCursor {
    static var defaultCursor: EmbeddedTerminalCursor { EmbeddedTerminalCursor() }
}

// parity: core/src/zig.ts#EmbeddedTerminalKey [status=implemented hash=41f8a85873bc]
public struct EmbeddedTerminalKey: Equatable, Hashable, Sendable {
    public var action: String
    public var key: String?
    public var mods: UInt32
    public var consumedMods: UInt32
    public var composing: Bool
    public var text: String?
    public var unshiftedCodepoint: UInt32

    public init(
        action: String = "press",
        key: String? = nil,
        mods: UInt32 = 0,
        consumedMods: UInt32 = 0,
        composing: Bool = false,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0
    ) {
        self.action = action
        self.key = key
        self.mods = mods
        self.consumedMods = consumedMods
        self.composing = composing
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }
}

// parity: core/src/zig.ts#EmbeddedTerminalMouse [status=implemented hash=965e9b1ae86d]
public struct EmbeddedTerminalMouse: Equatable, Hashable, Sendable {
    public var action: String
    public var button: String
    public var mods: UInt32
    public var x: Int
    public var y: Int
    public var anyButtonPressed: Bool

    public init(
        action: String = "press",
        button: String = "left",
        mods: UInt32 = 0,
        x: Int = 0,
        y: Int = 0,
        anyButtonPressed: Bool = false
    ) {
        self.action = action
        self.button = button
        self.mods = mods
        self.x = x
        self.y = y
        self.anyButtonPressed = anyButtonPressed
    }
}

// parity: core/src/zig.ts#LogLevel [status=implemented hash=9ab7e8f8bab0]
public enum NativeLogLevel: UInt32, Equatable, Hashable, Sendable, Codable {
    case error = 0
    case warn = 1
    case info = 2
    case debug = 3
}

// parity: core/src/zig.ts#CursorState [status=implemented hash=e8c6913b2d85]
public struct CursorState: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var visible: Bool
    public var style: CursorStyle
    public var blinking: Bool
    public var color: RGBA

    public init(
        x: Int = 0,
        y: Int = 0,
        visible: Bool = false,
        style: CursorStyle = .block,
        blinking: Bool = false,
        color: RGBA = .defaultForeground()
    ) {
        self.x = x
        self.y = y
        self.visible = visible
        self.style = style
        self.blinking = blinking
        self.color = color
    }
}

// parity: core/src/zig.ts#NativeSpanFeedEventHandler [status=implemented hash=0a51ef54324b]
public typealias NativeSpanFeedEventHandler = @Sendable (UInt32, FFIPointer, UInt64) -> Void

// parity: core/src/zig.ts#NativeBufferedOutput [status=implemented hash=2d842536323e]
public enum NativeBufferedOutput: String, Equatable, Hashable, Sendable, Codable {
    case stdout
    case memory
}

// parity: core/src/zig.ts#NativeYogaLayout [status=implemented hash=479941bd39e2]
public struct NativeYogaLayout: Equatable, Hashable, Sendable, Codable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var width: Float
    public var height: Float

    public init(
        left: Float = 0,
        top: Float = 0,
        right: Float = 0,
        bottom: Float = 0,
        width: Float = 0,
        height: Float = 0
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.width = width
        self.height = height
    }
}

// parity: core/src/zig.ts#NativeYogaMeasureCallback [status=implemented hash=ff18fe26c683]
public typealias NativeYogaMeasureCallback = @Sendable (FFIPointer?, Float, UInt32, Float, UInt32) -> Void

// parity: core/src/zig.ts#NativeYogaDirtiedCallback [status=implemented hash=4a50d574e3b0]
public typealias NativeYogaDirtiedCallback = @Sendable (FFIPointer?) -> Void

// MARK: - SceneStaging (11 methods)

/// Decoded staged scene mutation consumed by `SwiftRenderLib.sceneFlush`.
public enum SceneStagingMutation: Equatable, Sendable {
    case style(
        node: SceneNodeHandle,
        group: UInt32,
        kind: UInt32,
        edge: UInt32,
        unit: UInt32,
        value: Float,
        flags: UInt32
    )
    case background(node: SceneNodeHandle, color: RGBA)
    case paint(node: SceneNodeHandle, update: NativeScenePaintUpdate)
}

// parity: core/src/zig.ts#SceneStaging [status=implemented hash=5cf3c96bc27c]
public final class SceneStaging: @unchecked Sendable {
    public static let limit: Int = NATIVE_SCENE_MUTATIONS_MAX

    private var context: NativeContextHandle?
    private var mutations: [SceneStagingMutation] = []
    private var borrowed: Bool = false
    private var encodedWords: Int = 0

    public init(initialCapacity: Int = 64) throws {
        guard initialCapacity >= 1 && initialCapacity <= Self.limit else {
            throw NativeError(operation: "SceneStaging.init", status: .invalidArgument, reason: "capacity out of range")
        }
        mutations.reserveCapacity(initialCapacity)
    }

    // parity: core/src/zig.ts#SceneStaging.pending [status=implemented hash=e00cf348161c]
    public var pending: Bool { !mutations.isEmpty }

    // parity: core/src/zig.ts#SceneStaging.count [status=implemented hash=551b24a86704]
    public var count: Int { mutations.count }

    // parity: core/src/zig.ts#SceneStaging.byteLength [status=implemented hash=6122bf4f02a6]
    public var byteLength: Int { encodedWords * 4 }

    // parity: core/src/zig.ts#SceneStaging.full [status=implemented hash=5cb7a533ca69]
    public var full: Bool { mutations.count >= Self.limit }

    // parity: core/src/zig.ts#SceneStaging.checkStyleValue [status=implemented hash=b1563723b1a6]
    public static func checkStyleValue(group: UInt32, value: Float) throws -> Float {
        if group == UInt32(NativeABI.OT_STYLE_ENUM) {
            guard value.isFinite, value >= 0 else {
                throw NativeError(operation: "SceneStaging.checkStyleValue", status: .invalidArgument)
            }
            return Float(UInt32(value))
        }
        return value
    }

    private func assertWritable() throws {
        if borrowed {
            throw NativeError(operation: "SceneStaging", status: .contextBusy, reason: "staged inputs borrowed")
        }
    }

    private func checkContext(_ ctx: NativeContextHandle) throws {
        try assertWritable()
        if let existing = context, existing != ctx {
            throw NativeError(operation: "Context handle", status: .wrongContext)
        }
        if context == nil { context = ctx }
    }

    // parity: core/src/zig.ts#SceneStaging.stageStyle [status=implemented hash=9d212868c617]
    @discardableResult
    public func stageStyle(
        context: NativeContextHandle,
        node: SceneNodeHandle,
        group: UInt32,
        kind: UInt32,
        edge: UInt32,
        unit: UInt32,
        value: Float,
        flags: UInt32
    ) throws -> Bool {
        try checkContext(context)
        if full { throw NativeError(operation: "ot_scene_flush", status: .objectLimit) }
        guard max(max(group, kind), max(edge, unit)) <= 0xFF else {
            throw NativeError(operation: "ot_scene_set_style", status: .invalidArgument)
        }
        let checked = try Self.checkStyleValue(group: group, value: value)
        let normalizedEdge = (group == UInt32(NativeABI.OT_STYLE_VALUE) && kind < UInt32(NativeABI.OT_STYLE_VALUE_MARGIN)) ? 0 : edge
        mutations.append(
            .style(
                node: node,
                group: group,
                kind: kind,
                edge: normalizedEdge,
                unit: unit,
                value: checked,
                flags: flags
            )
        )
        encodedWords += 10
        return true
    }

    // parity: core/src/zig.ts#SceneStaging.stageBackground [status=implemented hash=39d8af642354]
    @discardableResult
    public func stageBackground(context: NativeContextHandle, node: SceneNodeHandle, color: RGBA) throws -> Bool {
        try checkContext(context)
        if full { throw NativeError(operation: "ot_scene_flush", status: .objectLimit) }
        mutations.append(.background(node: node, color: color))
        encodedWords += 8
        return true
    }

    // parity: core/src/zig.ts#SceneStaging.stagePaint [status=implemented hash=81e806e6da04]
    @discardableResult
    public func stagePaint(
        context: NativeContextHandle,
        node: SceneNodeHandle,
        update: NativeScenePaintUpdate
    ) throws -> Bool {
        try checkContext(context)
        if full { throw NativeError(operation: "ot_scene_flush", status: .objectLimit) }
        mutations.append(.paint(node: node, update: update))
        encodedWords += 16
        return true
    }

    // parity: core/src/zig.ts#SceneStaging.clear [status=implemented hash=6b2f1ae07325]
    public func clear() throws {
        try assertWritable()
        mutations.removeAll(keepingCapacity: true)
        encodedWords = 0
        context = nil
    }

    // parity: core/src/zig.ts#SceneStaging.consume [status=implemented hash=32092d5418d2]
    public func consume<R>(
        _ expectedContext: NativeContextHandle,
        _ body: ([SceneStagingMutation]) throws -> R
    ) throws -> R {
        try assertWritable()
        if let existing = context, existing != expectedContext {
            throw NativeError(operation: "ot_scene_flush", status: .wrongContext)
        }
        borrowed = true
        defer { borrowed = false }
        let batch = mutations
        let result = try body(batch)
        mutations.removeAll(keepingCapacity: true)
        encodedWords = 0
        context = nil
        return result
    }

    // parity: core/src/zig.ts#SceneStaging.discard [status=implemented hash=06446cb567ba]
    public func discard() {
        borrowed = false
        mutations.removeAll(keepingCapacity: true)
        encodedWords = 0
        context = nil
    }
}

// MARK: - NativePaintRecorder (16 methods)

/// Recorded paint operation stored by `NativePaintRecorder`.
public enum RecordedPaintCommand: Equatable, Sendable {
    case slot(node: SceneNodeHandle, phase: NativeScenePaintPhase, opacity: Double)
    case draw(NativeBufferDraw)
    case stack(NativeBufferStack)
    case grid(NativeBufferGrid)
    case packed(width: Int, height: Int, x: Int, y: Int, bytes: [UInt8])
    case supersample(width: Int, height: Int, x: Int, y: Int, bytes: [UInt8])
    case grayscale(x: Int, y: Int, width: Int, height: Int, intensity: Double, flags: UInt32)
    case colorMatrix(x: Int, y: Int, width: Int, height: Int, matrix: [Float], strength: Double, target: UInt32)
    case view(handle: ContextObjectHandle, x: Int, y: Int, isEditor: Bool)
    case image(handle: ContextImageHandle, options: NativeContextImageDraw)
    case unicode(handle: ContextUnicodeHandle, x: Int, y: Int, fg: RGBA, bg: RGBA?, attributes: UInt32)
}

// parity: core/src/zig.ts#NativePaintRecorder [status=implemented hash=99b5a325057b]
public final class NativePaintRecorder: @unchecked Sendable {
    private var active: Bool = false
    private var opacityStack: [Double] = [1.0]
    public private(set) var commands: [RecordedPaintCommand] = []

    public init() {}

    // parity: core/src/zig.ts#NativePaintRecorder.begin [status=implemented hash=8e326cce8b98]
    public func begin() {
        active = true
        opacityStack = [1.0]
        commands.removeAll(keepingCapacity: true)
    }

    // parity: core/src/zig.ts#NativePaintRecorder.end [status=implemented hash=386ff26f900c]
    public func end() -> [RecordedPaintCommand] {
        active = false
        return commands
    }

    // parity: core/src/zig.ts#NativePaintRecorder.settle [status=implemented hash=a6f368cbbff1]
    public func settle() {
        active = false
        opacityStack = [1.0]
        commands.removeAll(keepingCapacity: true)
    }

    // parity: core/src/zig.ts#NativePaintRecorder.recording [status=implemented hash=1e2dc538be58]
    public var recording: Bool { active }

    // parity: core/src/zig.ts#NativePaintRecorder.slot [status=implemented hash=20add389433d]
    public func slot(node: SceneNodeHandle, phase: NativeScenePaintPhase, opacity: Double = 1.0) {
        guard active else { return }
        opacityStack = [opacity]
        commands.append(.slot(node: node, phase: phase, opacity: opacity))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.currentOpacity [status=implemented hash=f966409913f4]
    public var currentOpacity: Double {
        opacityStack.last ?? 1.0
    }

    // parity: core/src/zig.ts#NativePaintRecorder.draw [status=implemented hash=34aec2a8a334]
    public func draw(_ command: NativeBufferDraw) {
        guard active else { return }
        commands.append(.draw(command))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.stack [status=implemented hash=e8acc920cca4]
    @discardableResult
    public func stack(_ op: NativeBufferStack) -> Double {
        guard active else { return currentOpacity }
        switch op {
        case .getOpacity:
            return currentOpacity
        case .pushOpacity(let value):
            let next = max(0.0, min(1.0, currentOpacity * value))
            opacityStack.append(next)
        case .popOpacity:
            if opacityStack.count > 1 { opacityStack.removeLast() }
        case .clearOpacity:
            opacityStack = [1.0]
        case .pushScissor, .popScissor, .clearScissors:
            break
        }
        commands.append(.stack(op))
        return currentOpacity
    }

    // parity: core/src/zig.ts#NativePaintRecorder.grid [status=implemented hash=e2506165e737]
    public func grid(_ options: NativeBufferGrid) {
        guard active else { return }
        commands.append(.grid(options))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.packed [status=implemented hash=f5b84b5d3d32]
    public func packed(width: Int, height: Int, x: Int, y: Int, bytes: [UInt8]) {
        guard active else { return }
        commands.append(.packed(width: width, height: height, x: x, y: y, bytes: bytes))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.supersample [status=implemented hash=82ea08347910]
    public func supersample(width: Int, height: Int, x: Int, y: Int, bytes: [UInt8]) {
        guard active else { return }
        commands.append(.supersample(width: width, height: height, x: x, y: y, bytes: bytes))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.grayscale [status=implemented hash=5c9afd93b4b9]
    public func grayscale(x: Int, y: Int, width: Int, height: Int, intensity: Double = 1.0, flags: UInt32 = 3) {
        guard active else { return }
        commands.append(.grayscale(x: x, y: y, width: width, height: height, intensity: intensity, flags: flags))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.colorMatrix [status=implemented hash=7f039497ed23]
    public func colorMatrix(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        matrix: [Float],
        strength: Double = 1.0,
        target: UInt32 = 3
    ) {
        guard active else { return }
        commands.append(
            .colorMatrix(x: x, y: y, width: width, height: height, matrix: matrix, strength: strength, target: target)
        )
    }

    // parity: core/src/zig.ts#NativePaintRecorder.view [status=implemented hash=5d16e19e2d01]
    public func view(handle: ContextObjectHandle, x: Int, y: Int, isEditor: Bool = false) {
        guard active else { return }
        commands.append(.view(handle: handle, x: x, y: y, isEditor: isEditor))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.image [status=implemented hash=996b07a64477]
    public func image(handle: ContextImageHandle, options: NativeContextImageDraw) {
        guard active else { return }
        commands.append(.image(handle: handle, options: options))
    }

    // parity: core/src/zig.ts#NativePaintRecorder.unicode [status=implemented hash=5ae5bcd351f1]
    public func unicode(
        handle: ContextUnicodeHandle,
        x: Int,
        y: Int,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) {
        guard active else { return }
        commands.append(.unicode(handle: handle, x: x, y: y, fg: fg, bg: bg, attributes: attributes))
    }
}

// MARK: - Internal Handle Table State (Mutex-Isolated)

private final class EmbeddedTerminalState {
    var cols: Int
    var rows: Int
    var maxScrollback: Int
    var transparentBackground: Bool
    var lines: [String]
    var cursorX: Int = 0
    var cursorY: Int = 0
    var scrollOffset: Int = 0
    var selection: (startX: Int, startY: Int, endX: Int, endY: Int)?
    var responses: [[UInt8]] = []
    var invalidated: Bool = false

    init(cols: Int, rows: Int, maxScrollback: Int = 1_000, transparentBackground: Bool = false) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, maxScrollback)
        self.transparentBackground = transparentBackground
        self.lines = Array(repeating: "", count: max(1, rows))
    }

    func write(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        for ch in text {
            if ch == "\n" {
                cursorY += 1
                cursorX = 0
                if cursorY >= lines.count {
                    lines.append("")
                    if lines.count > rows + maxScrollback {
                        lines.removeFirst()
                        cursorY = max(0, lines.count - 1)
                    }
                }
            } else if ch == "\r" {
                cursorX = 0
            } else {
                while cursorY >= lines.count { lines.append("") }
                var chars = Array(lines[cursorY])
                while chars.count <= cursorX { chars.append(" ") }
                chars[cursorX] = ch
                lines[cursorY] = String(chars)
                cursorX += 1
                if cursorX >= cols {
                    cursorX = 0
                    cursorY += 1
                    if cursorY >= lines.count { lines.append("") }
                }
            }
        }
    }

    func selectedText() -> String {
        guard let sel = selection else { return "" }
        let sy = max(0, min(sel.startY, lines.count - 1))
        let ey = max(0, min(sel.endY, lines.count - 1))
        if sy > ey || lines.isEmpty { return "" }
        var parts: [String] = []
        for row in sy...ey {
            let chars = Array(lines[row])
            let lo = row == sy ? max(0, min(sel.startX, chars.count)) : 0
            let hi = row == ey ? max(lo, min(sel.endX, chars.count)) : chars.count
            parts.append(String(chars[lo..<hi]))
        }
        return parts.joined(separator: "\n")
    }
}

private final class VideoNodeState {
    var path: String = ""
    var info: NativeVideoInfo = NativeVideoInfo()
    var state: NativeVideoState = NativeVideoState()
    var loop: Bool = false
    var muted: Bool = false
    var volume: Float = 1.0
    var avSyncOffsetUs: Int64 = 0
    var maxFps: Float = 60.0
    var lastError: String = ""
}

private final class BufferLeaseRecord {
    let handle: ContextObjectHandle
    let generation: UInt64
    var active: Bool = true
    var charPtr: FFIPointer = .null
    var fgPtr: FFIPointer = .null
    var bgPtr: FFIPointer = .null
    var attrPtr: FFIPointer = .null

    init(handle: ContextObjectHandle, generation: UInt64) {
        self.handle = handle
        self.generation = generation
    }
}

private final class ActiveFrameRecord {
    let frameId: UInt64
    let session: SessionHandle
    let root: SceneNodeHandle
    let options: NativeSceneFrameOptions
    var requestSeq: UInt64 = 1
    var phase: NativeSceneFrame = .record
    var paintSlots: [NativeScenePaintSlot] = []
    var committed: Bool = false
    var cancelled: Bool = false
    var buffer: OptimizedBuffer

    init(
        frameId: UInt64,
        session: SessionHandle,
        root: SceneNodeHandle,
        options: NativeSceneFrameOptions,
        width: Int,
        height: Int
    ) {
        self.frameId = frameId
        self.session = session
        self.root = root
        self.options = options
        self.buffer = (try? OptimizedBuffer.create(width: max(1, width), height: max(1, height)))
            ?? OptimizedBuffer(width: max(1, width), height: max(1, height))
    }
}

private final class ContextState {
    let resourceContext: NativeResourceContext
    let runtime: NativeSessionRuntime
    var nextSlot: UInt32 = 1
    var generation: UInt32 = 1
    var nextFrameId: UInt64 = 1
    var nextOutputTicketId: UInt64 = 1
    var contentEpoch: UInt64 = 1
    var debugFlags: UInt32 = 0
    var diagnostics: [String] = []

    var buffers: [UInt32: (generation: UInt32, buffer: OptimizedBuffer)] = [:]
    var bufferLeases: [UInt64: BufferLeaseRecord] = [:]
    var nextLeaseGen: UInt64 = 1

    var unicodes: [UInt32: (generation: UInt32, text: String)] = [:]
    var embeddedTerminals: [UInt32: (generation: UInt32, terminal: EmbeddedTerminalState)] = [:]

    var textBuffers: [UInt32: (generation: UInt32, buffer: TextBuffer, epoch: UInt64, groupSets: [UInt32: [UInt32]])] = [:]
    var textBufferViews: [UInt32: (generation: UInt32, view: TextBufferView, ownerSlot: UInt32)] = [:]

    var editBuffers: [UInt32: (generation: UInt32, buffer: EditBuffer, epoch: UInt64, marks: [UInt32: NativeEditMark], nextMarkId: UInt32)] = [:]
    var editorViews: [UInt32: (generation: UInt32, view: EditorView, ownerSlot: UInt32)] = [:]
    var syntaxStyles: [UInt32: (generation: UInt32, style: SyntaxStyle)] = [:]
    var editEventListeners: [UInt64: @Sendable (ContextEditBufferHandle, NativeEditEvent) -> Void] = [:]
    var nextEditListenerId: UInt64 = 1

    var sessions: [UInt32: (generation: UInt32, session: NativeSession, sink: MemorySessionOutputSink, parser: StdinParser, writeLimit: Int, inputExpectFlags: UInt32, stdoutQueue: [[UInt8]], pendingTickets: [UInt64: Int], cursor: CursorState, splitPinnedOffset: Int)] = [:]

    var scene: NativeScene?
    var sceneNodes: [UInt32: (generation: UInt32, node: NativeSceneNode, kind: UInt32, hooks: UInt32, hookGen: UInt64)] = [:]
    var activeFrames: [UInt64: ActiveFrameRecord] = [:]
    var sceneStats: OpenTUICore.NativeRenderStats = OpenTUICore.NativeRenderStats()
    var sceneCursor: CursorState = CursorState()

    var markdowns: [UInt32: (generation: UInt32, doc: StreamingMarkdownDocument, options: NativeMarkdownOptions, lastBlocks: [NativeMarkdownBlock])] = [:]
    var videos: [UInt32: VideoNodeState] = [:]

    var images: [UInt32: (generation: UInt32, image: NativeImage, refCount: Int)] = [:]
    var imagePixels: [UInt32: (generation: UInt32, raw: OwnedRawImage)] = [:]
    var iccCacheRetainCount: Int = 0

    init(options: NativeContextOptions) {
        self.resourceContext = NativeResourceContext(options: options)
        self.runtime = NativeSessionRuntime()
    }

    func allocateHandle() -> ContextObjectHandle {
        let slot = nextSlot
        nextSlot &+= 1
        if nextSlot == 0 { nextSlot = 1 }
        return ContextObjectHandle(context: resourceContext.context, slot: slot, generation: generation)
    }

    func ensureScene() -> NativeScene {
        if let existing = scene { return existing }
        let sink = MemorySessionOutputSink()
        let session = (try? NativeSession(sink: sink, runtime: runtime))!
        let created = NativeScene(driver: session)
        scene = created
        return created
    }
}

private final class AudioStreamRecord {
    let id: UInt32
    var options: AudioStreamCreateOptions
    var bytes: [UInt8] = []
    var stats: NativeAudioStreamStats
    var ended: Bool = false

    init(id: UInt32, options: AudioStreamCreateOptions) {
        self.id = id
        self.options = options
        self.stats = NativeAudioStreamStats(
            state: NativeAudioStreamState.initializing.rawValue,
            sampleRate: options.sampleRate == 0 ? 48_000 : options.sampleRate,
            channels: options.channels == 0 ? 2 : options.channels,
            capacityFrames: max(1, options.capacityMs * 48)
        )
    }
}

private final class AudioEngineRecord {
    let engine: Audio
    var nextStreamId: UInt32 = 1
    var streams: [UInt32: AudioStreamRecord] = [:]

    init(engine: Audio) {
        self.engine = engine
    }
}

private final class ClipboardOperationRecord {
    let handle: ClipboardOperationHandle
    var status: NativeClipboardOperationStatus
    var mime: [UInt8]
    var data: [UInt8]
    var errorCode: Int32 = 0
    var diagnostic: [UInt8] = []

    init(
        handle: ClipboardOperationHandle,
        status: NativeClipboardOperationStatus,
        mime: [UInt8] = [],
        data: [UInt8] = []
    ) {
        self.handle = handle
        self.status = status
        self.mime = mime
        self.data = data
    }
}

private final class ClipboardServiceRecord {
    let handle: ClipboardServiceHandle
    var shuttingDown: Bool = false
    var storedMime: [UInt8] = Array("text/plain".utf8)
    var storedData: [UInt8] = []
    var hasValue: Bool = false
    var operations: [UInt64: ClipboardOperationRecord] = [:]

    init(handle: ClipboardServiceHandle) {
        self.handle = handle
    }
}

private final class SpanFeedRecord {
    let pointer: FFIPointer
    let feed: NativeSpanFeed
    var eventHandler: NativeSpanFeedEventHandler?
    var reservations: [UInt64: SpanReservation] = [:]

    init(pointer: FFIPointer, feed: NativeSpanFeed) {
        self.pointer = pointer
        self.feed = feed
    }
}

// MARK: - Protocols: AudioEngineLib & RenderLib

// parity: core/src/zig.ts#AudioEngineLib [status=implemented hash=9519c30c72f1]
public protocol AudioEngineLib: AnyObject, Sendable {
    func createAudioEngine(_ options: AudioCreateOptions) -> AudioEngineHandle
    func destroyAudioEngine(_ engine: AudioEngineHandle)
    func audioStart(_ engine: AudioEngineHandle, options: ZigAudioStartOptions?) -> Bool
    func audioStartMixer(_ engine: AudioEngineHandle) -> Bool
    func audioStop(_ engine: AudioEngineHandle) -> Bool
    func audioLoad(_ engine: AudioEngineHandle, data: [UInt8]) -> UInt32
    func audioUnload(_ engine: AudioEngineHandle, soundId: UInt32) -> Bool
    func audioPlay(_ engine: AudioEngineHandle, soundId: UInt32, options: AudioVoiceOptions?) -> UInt32
    func audioStopVoice(_ engine: AudioEngineHandle, voiceId: UInt32) -> Bool
    func audioSetVoiceGroup(_ engine: AudioEngineHandle, voiceId: UInt32, groupId: UInt32) -> Bool
    func audioCreateGroup(_ engine: AudioEngineHandle, name: String) -> UInt32
    func audioSetGroupVolume(_ engine: AudioEngineHandle, groupId: UInt32, volume: Float) -> Bool
    func audioSetMasterVolume(_ engine: AudioEngineHandle, volume: Float) -> Bool
    func audioGetStats(_ engine: AudioEngineHandle) -> ZigAudioStats?
}

// parity: core/src/zig.ts#RenderLib [status=implemented hash=b1f42f88ff33]
public protocol RenderLib: AudioEngineLib {
    func createContext(_ options: NativeContextOptions) throws -> NativeContextHandle
    func destroyContext(_ context: NativeContextHandle)
    func createContextBuffer(_ context: NativeContextHandle, options: NativeContextBufferOptions) throws -> ContextBufferHandle
    func destroyContextBuffer(_ context: NativeContextHandle, buffer: ContextBufferHandle)
    func contextDrawBuffer(_ target: NativeDrawingTarget, draw: NativeBufferDraw) throws
    func createContextTextBuffer(_ context: NativeContextHandle, options: NativeContextEditBufferOptions) throws -> ContextTextBufferHandle
    func createContextEditBuffer(_ context: NativeContextHandle, options: NativeContextEditBufferOptions) throws -> ContextEditBufferHandle
    func createContextEditorView(_ context: NativeContextHandle, editBuffer: ContextEditBufferHandle, width: Int, height: Int) throws -> ContextEditorViewHandle
    func createContextSyntaxStyle(_ context: NativeContextHandle) throws -> ContextSyntaxStyleHandle
    func createSession(_ context: NativeContextHandle, options: NativeSessionOptions) throws -> SessionHandle
    func destroySession(_ context: NativeContextHandle, session: SessionHandle)
    func sceneCreateNode(_ context: NativeContextHandle, kind: UInt32, num: UInt32) throws -> SceneNodeHandle
    func sceneDestroyNode(_ context: NativeContextHandle, node: SceneNodeHandle) throws
    func dispose()
}

// MARK: - SwiftRenderLib (`core/src/zig.ts#FFIRenderLib`, 395 methods)

// parity: core/src/zig.ts#FFIRenderLib [status=implemented hash=81bbe65ecfdf]
public final class SwiftRenderLib: RenderLib, @unchecked Sendable {
    private final class Store {
        var disposed: Bool = false
        var contexts: [UInt64: ContextState] = [:]

        var nextStandaloneHandle: UInt64 = 1
        var audioEngines: [UInt64: AudioEngineRecord] = [:]
        var spanFeeds: [UInt64: SpanFeedRecord] = [:]
        var clipboardServices: [UInt64: ClipboardServiceRecord] = [:]
        var clipboardOpToService: [UInt64: UInt64] = [:]

        let yogaHost = YogaHost()
        var yogaConfigs: [UInt64: YogaConfig] = [:]
        var yogaNodes: [UInt64: YogaNode] = [:]
        var yogaMeasureResults: [UInt64: (width: Float, height: Float)] = [:]
        var yogaMeasureCallbacks: [UInt64: NativeYogaMeasureCallback] = [:]
        var yogaDirtiedCallbacks: [UInt64: NativeYogaDirtiedCallback] = [:]

        var activeAllocations: UInt64 = 0
        var totalRequestedBytes: UInt64 = 0

        func allocId() -> UInt64 {
            let id = nextStandaloneHandle
            nextStandaloneHandle &+= 1
            if nextStandaloneHandle == 0 { nextStandaloneHandle = 1 }
            return id
        }
    }

    private let lock = Mutex<Store>(Store())
    public let ffiRuntime: SwiftFFIRuntime

    public init(ffiRuntime: SwiftFFIRuntime = .shared) {
        self.ffiRuntime = ffiRuntime
    }

    private func requireContext(_ store: Store, _ context: NativeContextHandle, op: String) throws -> ContextState {
        guard let ctx = store.contexts[context.contextId] else {
            throw NativeError(operation: op, status: .staleHandle)
        }
        return ctx
    }

    private func resolveTargetBuffer(_ store: Store, _ target: NativeDrawingTarget, op: String) throws -> (ContextState, OptimizedBuffer) {
        switch target {
        case .buffer(let context, let handle):
            let ctx = try requireContext(store, context, op: op)
            guard let entry = ctx.buffers[handle.slot], entry.generation == handle.generation else {
                throw NativeError(operation: op, status: .staleHandle)
            }
            return (ctx, entry.buffer)
        case .frame(let context, _, let frame):
            let ctx = try requireContext(store, context, op: op)
            guard let rec = ctx.activeFrames[frame.frameId], !rec.cancelled else {
                throw NativeError(operation: op, status: .staleFrame)
            }
            return (ctx, rec.buffer)
        }
    }

    // MARK: - Context, Unicode & Selection Record

    // parity: core/src/zig.ts#FFIRenderLib.createEditorSelectionRecord [status=adapted hash=01f6b26d3ef2]
    public func createEditorSelectionRecord(_ selection: NativeEditorSelection) -> [UInt32] {
        var words = Array(repeating: UInt32(0), count: 16)
        words[0] = 64
        words[1] = UInt32(NativeABI.OT_CONTEXT_ABI_VERSION)
        words[2] = selection.operation.rawValue
        words[3] = selection.behavior == .line ? 1 : 0
        words[4] = UInt32(bitPattern: Int32(selection.start ?? 0))
        words[5] = UInt32(bitPattern: Int32(selection.end ?? 0))
        words[6] = UInt32(bitPattern: Int32(selection.anchorX ?? 0))
        words[7] = UInt32(bitPattern: Int32(selection.anchorY ?? 0))
        words[8] = UInt32(bitPattern: Int32(selection.focusX ?? 0))
        words[9] = UInt32(bitPattern: Int32(selection.focusY ?? 0))
        var flags: UInt32 = 0
        if selection.updateCursor { flags |= 1 }
        if selection.followCursor { flags |= 2 }
        if selection.fg != nil { flags |= 4 }
        if selection.bg != nil { flags |= 8 }
        words[10] = flags
        return words
    }

    // parity: core/src/zig.ts#FFIRenderLib.createContext [status=implemented hash=c12bdf21ebbb]
    public func createContext(_ options: NativeContextOptions = NativeContextOptions()) throws -> NativeContextHandle {
        lock.withLock { store in
            let state = ContextState(options: options)
            store.contexts[state.resourceContext.context.contextId] = state
            store.activeAllocations &+= 1
            store.totalRequestedBytes &+= UInt64(options.objectCapacity * 16)
            return state.resourceContext.context
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContext [status=implemented hash=88afa16ddaa3]
    public func destroyContext(_ context: NativeContextHandle) {
        lock.withLock { store in
            guard let state = store.contexts.removeValue(forKey: context.contextId) else { return }
            for (_, entry) in state.buffers { entry.buffer.destroy() }
            for (_, entry) in state.textBufferViews { entry.view.destroy() }
            for (_, entry) in state.textBuffers { entry.buffer.destroy() }
            for (_, entry) in state.editorViews { entry.view.destroy() }
            for (_, entry) in state.editBuffers { entry.buffer.destroy() }
            for (_, entry) in state.syntaxStyles { entry.style.destroy() }
            for (_, entry) in state.markdowns { entry.doc.destroy() }
            for (_, entry) in state.images { entry.image.dispose() }
            for (_, entry) in state.sessions { entry.session.destroy() }
            state.resourceContext.destroy()
            if store.activeAllocations > 0 { store.activeAllocations -= 1 }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextGetLinkUrl [status=implemented hash=f6d1392a6ca8]
    public func contextGetLinkUrl(_ context: NativeContextHandle, linkId: UInt32) throws -> String? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_context_get_link_url")
            return try? ctx.resourceContext.linkPool.get(linkId)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createContextUnicode [status=implemented hash=ce84bd009fd3]
    public func createContextUnicode(_ context: NativeContextHandle, text: String) throws -> ContextUnicodeHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_unicode_create")
            let h = ctx.allocateHandle()
            ctx.unicodes[h.slot] = (h.generation, text)
            return ContextUnicodeHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.getContextUnicode [status=implemented hash=b65a0587dfec]
    public func getContextUnicode(_ context: NativeContextHandle, handle: ContextUnicodeHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_unicode_get")
            guard let entry = ctx.unicodes[handle.slot], entry.generation == handle.generation else {
                throw NativeError(operation: "ot_unicode_get", status: .staleHandle)
            }
            return entry.text
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextUnicode [status=implemented hash=3bdc313a50b0]
    public func destroyContextUnicode(_ context: NativeContextHandle, handle: ContextUnicodeHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            _ = ctx.unicodes.removeValue(forKey: handle.slot)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextBufferDrawUnicode [status=implemented hash=f2ed6a7bf966]
    public func contextBufferDrawUnicode(
        _ target: NativeDrawingTarget,
        unicode: ContextUnicodeHandle,
        x: Int,
        y: Int,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_unicode")
            guard let entry = ctx.unicodes[unicode.slot], entry.generation == unicode.generation else {
                throw NativeError(operation: "ot_buffer_draw_unicode", status: .staleHandle)
            }
            buffer.drawText(entry.text, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
        }
    }

    // MARK: - Context Buffers & Drawing

    // parity: core/src/zig.ts#FFIRenderLib.createContextBuffer [status=implemented hash=74b5bb9a02c0]
    public func createContextBuffer(
        _ context: NativeContextHandle,
        options: NativeContextBufferOptions
    ) throws -> ContextBufferHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_create")
            guard options.width > 0, options.height > 0 else {
                throw NativeError(operation: "ot_buffer_create", status: .invalidArgument)
            }
            let buf: OptimizedBuffer
            do {
                buf = try OptimizedBuffer.create(
                    width: options.width,
                    height: options.height,
                    widthMethod: options.widthMethod,
                    respectAlpha: options.respectAlpha,
                    graphemePool: ctx.resourceContext.graphemePool,
                    linkPool: ctx.resourceContext.linkPool
                )
            } catch {
                throw NativeError(operation: "ot_buffer_create", status: .invalidArgument, reason: "\(error)")
            }
            let h = ctx.allocateHandle()
            ctx.buffers[h.slot] = (h.generation, buf)
            store.activeAllocations &+= 1
            store.totalRequestedBytes &+= UInt64(options.width * options.height * 24)
            return ContextBufferHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextBuffer [status=implemented hash=fa76260c3d5d]
    public func destroyContextBuffer(_ context: NativeContextHandle, buffer: ContextBufferHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.buffers.removeValue(forKey: buffer.slot) {
                entry.buffer.destroy()
                if store.activeAllocations > 0 { store.activeAllocations -= 1 }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextResizeBuffer [status=implemented hash=8ac3ed6351cf]
    public func contextResizeBuffer(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle,
        width: Int,
        height: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_resize")
            guard let entry = ctx.buffers[buffer.slot], entry.generation == buffer.generation else {
                throw NativeError(operation: "ot_buffer_resize", status: .staleHandle)
            }
            do {
                try entry.buffer.resize(width: width, height: height)
            } catch {
                throw NativeError(operation: "ot_buffer_resize", status: .invalidArgument, reason: "\(error)")
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawBuffer [status=implemented hash=a2bf6ef5b8cb]
    public func contextDrawBuffer(_ target: NativeDrawingTarget, draw: NativeBufferDraw) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw")
            switch draw {
            case .clear(let bg):
                buffer.clear(bg: bg ?? RGBA.fromValues(0, 0, 0, 1))
            case .fill(let x, let y, let width, let height, let bg):
                buffer.fillRect(x: x, y: y, width: width, height: height, bg: bg)
            case .text(let x, let y, let text, let fg, let bg, let attributes, let maxWidth, let ellipsis):
                if let maxWidth {
                    buffer.drawTextFit(text, x: x, y: y, maxWidth: maxWidth, fg: fg, bg: bg, attributes: attributes, ellipsis: ellipsis)
                } else {
                    buffer.drawText(text, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
                }
            case .cell(let x, let y, let char, let fg, let bg, let attributes):
                let str = UnicodeScalar(char).map(String.init) ?? " "
                buffer.setCell(x: x, y: y, char: str, fg: fg, bg: bg, attributes: attributes)
            case .cellBlend(let x, let y, let char, let fg, let bg, let attributes):
                let str = UnicodeScalar(char).map(String.init) ?? " "
                buffer.setCellWithAlphaBlending(x: x, y: y, char: str, fg: fg, bg: bg, attributes: attributes)
            case .char(let x, let y, let char, let fg, let bg, let attributes):
                buffer.drawChar(char, x: x, y: y, fg: fg, bg: bg, attributes: attributes)
            case .box(let x, let y, let width, let height, let fg, let bg, let titleColor, let packedOptions, let borderChars, let text, let bottomTitle):
                let sides = BorderSidesConfig(
                    top: (packedOptions & UInt32(NativeABI.OT_BORDER_TOP)) != 0 || packedOptions == 0,
                    right: (packedOptions & UInt32(NativeABI.OT_BORDER_RIGHT)) != 0 || packedOptions == 0,
                    bottom: (packedOptions & UInt32(NativeABI.OT_BORDER_BOTTOM)) != 0 || packedOptions == 0,
                    left: (packedOptions & UInt32(NativeABI.OT_BORDER_LEFT)) != 0 || packedOptions == 0
                )
                let shouldFill = (packedOptions & (1 << 4)) != 0
                buffer.drawBox(
                    BoxDrawOptions(
                        x: x,
                        y: y,
                        width: width,
                        height: height,
                        borderStyle: .single,
                        customBorderChars: borderChars,
                        borderSides: sides,
                        borderColor: fg,
                        backgroundColor: bg,
                        titleColor: titleColor,
                        shouldFill: shouldFill,
                        title: text,
                        titleAlignment: .left,
                        bottomTitle: bottomTitle,
                        bottomTitleAlignment: .left
                    )
                )
            case .compose(let x, let y, let sourceHandle, let sourceX, let sourceY, let sourceWidth, let sourceHeight):
                guard let src = ctx.buffers[sourceHandle.slot], src.generation == sourceHandle.generation else {
                    throw NativeError(operation: "ot_buffer_draw", status: .staleHandle)
                }
                buffer.drawFrameBuffer(
                    destX: x,
                    destY: y,
                    frameBuffer: src.buffer,
                    sourceX: sourceX,
                    sourceY: sourceY,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight
                )
            case .respectAlpha(let enabled):
                buffer.setRespectAlpha(enabled)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextBufferStack [status=implemented hash=fd10db44770c]
    @discardableResult
    public func contextBufferStack(_ target: NativeDrawingTarget, op: NativeBufferStack) throws -> Double {
        try lock.withLock { store in
            let (_, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_stack")
            switch op {
            case .getOpacity:
                return buffer.getCurrentOpacity()
            case .pushScissor(let x, let y, let width, let height):
                buffer.pushScissorRect(x: x, y: y, width: width, height: height)
                return buffer.getCurrentOpacity()
            case .popScissor:
                buffer.popScissorRect()
                return buffer.getCurrentOpacity()
            case .clearScissors:
                buffer.clearScissorRects()
                return buffer.getCurrentOpacity()
            case .pushOpacity(let opacity):
                buffer.pushOpacity(opacity)
                return buffer.getCurrentOpacity()
            case .popOpacity:
                buffer.popOpacity()
                return buffer.getCurrentOpacity()
            case .clearOpacity:
                buffer.clearOpacity()
                return buffer.getCurrentOpacity()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawGrid [status=implemented hash=0abc429ba017]
    public func contextDrawGrid(_ target: NativeDrawingTarget, grid: NativeBufferGrid) throws {
        try lock.withLock { store in
            let (_, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_grid")
            let cols = grid.columnOffsets.map(Int.init)
            let rows = grid.rowOffsets.map(Int.init)
            guard cols.count >= 2, rows.count >= 2 else { return }
            let hChar = grid.borderChars.count > 4 ? grid.borderChars[4] : 0x2500
            let vChar = grid.borderChars.count > 5 ? grid.borderChars[5] : 0x2502
            let minX = cols.first!, maxX = cols.last!
            let minY = rows.first!, maxY = rows.last!
            for (rIdx, y) in rows.enumerated() {
                let isOuter = rIdx == 0 || rIdx == rows.count - 1
                if (isOuter && !grid.drawOuter) || (!isOuter && !grid.drawInner) { continue }
                for x in minX...maxX {
                    buffer.drawChar(hChar, x: x, y: y, fg: grid.borderFg, bg: grid.borderBg)
                }
            }
            for (cIdx, x) in cols.enumerated() {
                let isOuter = cIdx == 0 || cIdx == cols.count - 1
                if (isOuter && !grid.drawOuter) || (!isOuter && !grid.drawInner) { continue }
                for y in minY...maxY {
                    buffer.drawChar(vChar, x: x, y: y, fg: grid.borderFg, bg: grid.borderBg)
                }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawPackedBuffer [status=implemented hash=7de4d01f1ec0]
    public func contextDrawPackedBuffer(
        _ target: NativeDrawingTarget,
        bytes: [UInt8],
        width: Int,
        height: Int,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try lock.withLock { store in
            let (_, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_packed")
            let cellHeight = max(0, height / 2)
            for row in 0..<cellHeight {
                for col in 0..<width {
                    let topIdx = ((row * 2) * width + col) * 4
                    let botIdx = ((row * 2 + 1) * width + col) * 4
                    guard topIdx + 3 < bytes.count, botIdx + 3 < bytes.count else { continue }
                    let topColor = RGBA.fromInts(Int(bytes[topIdx]), Int(bytes[topIdx + 1]), Int(bytes[topIdx + 2]), Int(bytes[topIdx + 3]))
                    let botColor = RGBA.fromInts(Int(bytes[botIdx]), Int(bytes[botIdx + 1]), Int(bytes[botIdx + 2]), Int(bytes[botIdx + 3]))
                    buffer.drawChar(UInt32(0x2580), x: x + col, y: y + row, fg: topColor, bg: botColor)
                }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawSuperSampleBuffer [status=implemented hash=eade1536550c]
    public func contextDrawSuperSampleBuffer(
        _ target: NativeDrawingTarget,
        bytes: [UInt8],
        width: Int,
        height: Int,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try contextDrawPackedBuffer(target, bytes: bytes, width: width, height: height, x: x, y: y)
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawGrayscaleBuffer [status=implemented hash=32d304aeacaf]
    public func contextDrawGrayscaleBuffer(
        _ target: NativeDrawingTarget,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        intensity: Double = 1.0,
        flags: UInt32 = 3
    ) throws {
        try lock.withLock { store in
            let (_, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_grayscale")
            let clamped = max(0.0, min(1.0, intensity))
            let applyFg = (flags & UInt32(NativeABI.OT_SCENE_RECORD_GRAYSCALE_FOREGROUND)) != 0
            let applyBg = (flags & UInt32(NativeABI.OT_SCENE_RECORD_GRAYSCALE_BACKGROUND)) != 0
            for row in y..<(y + height) {
                for col in x..<(x + width) {
                    guard var cell = buffer.cell(atX: col, y: row) else { continue }
                    if applyFg {
                        let luma = 0.2126 * cell.foreground.r + 0.7152 * cell.foreground.g + 0.0722 * cell.foreground.b
                        cell.foreground = RGBA.fromValues(
                            cell.foreground.r + (luma - cell.foreground.r) * clamped,
                            cell.foreground.g + (luma - cell.foreground.g) * clamped,
                            cell.foreground.b + (luma - cell.foreground.b) * clamped,
                            cell.foreground.a
                        )
                    }
                    if applyBg {
                        let luma = 0.2126 * cell.background.r + 0.7152 * cell.background.g + 0.0722 * cell.background.b
                        cell.background = RGBA.fromValues(
                            cell.background.r + (luma - cell.background.r) * clamped,
                            cell.background.g + (luma - cell.background.g) * clamped,
                            cell.background.b + (luma - cell.background.b) * clamped,
                            cell.background.a
                        )
                    }
                    buffer.setCellRaw(x: col, y: row, cell: cell)
                }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextColorMatrixBuffer [status=implemented hash=3eb0aa30495d]
    public func contextColorMatrixBuffer(
        _ target: NativeDrawingTarget,
        matrix: [Float],
        x: Int = 0,
        y: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        strength: Double = 1.0,
        targetMask: UInt32 = 3
    ) throws {
        try lock.withLock { store in
            let (_, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_color_matrix")
            guard matrix.count >= 16 else { return }
            let w = width ?? buffer.width
            let h = height ?? buffer.height
            let s = max(0.0, min(1.0, strength))
            let apply: (RGBA) -> RGBA = { c in
                let nr = Double(matrix[0]) * c.r + Double(matrix[1]) * c.g + Double(matrix[2]) * c.b + Double(matrix[3])
                let ng = Double(matrix[4]) * c.r + Double(matrix[5]) * c.g + Double(matrix[6]) * c.b + Double(matrix[7])
                let nb = Double(matrix[8]) * c.r + Double(matrix[9]) * c.g + Double(matrix[10]) * c.b + Double(matrix[11])
                return RGBA.fromValues(
                    max(0, min(1, c.r + (nr - c.r) * s)),
                    max(0, min(1, c.g + (ng - c.g) * s)),
                    max(0, min(1, c.b + (nb - c.b) * s)),
                    c.a
                )
            }
            for row in y..<(y + h) {
                for col in x..<(x + w) {
                    guard var cell = buffer.cell(atX: col, y: row) else { continue }
                    if (targetMask & 1) != 0 { cell.foreground = apply(cell.foreground) }
                    if (targetMask & 2) != 0 { cell.background = apply(cell.background) }
                    buffer.setCellRaw(x: col, y: row, cell: cell)
                }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextAcquireBufferLease [status=adapted hash=3311e3fa70cf]
    public func contextAcquireBufferLease(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle
    ) throws -> NativeContextBufferLease {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_acquire_lease")
            guard let entry = ctx.buffers[buffer.slot], entry.generation == buffer.generation else {
                throw NativeError(operation: "ot_buffer_acquire_lease", status: .staleHandle)
            }
            let gen = ctx.nextLeaseGen
            ctx.nextLeaseGen &+= 1
            let rec = BufferLeaseRecord(handle: buffer.raw, generation: gen)
            let count = entry.buffer.width * entry.buffer.height
            rec.charPtr = ffiRuntime.pinBuffer(Array(repeating: 0, count: count * 4))
            rec.fgPtr = ffiRuntime.pinBuffer(Array(repeating: 0, count: count * 8))
            rec.bgPtr = ffiRuntime.pinBuffer(Array(repeating: 0, count: count * 8))
            rec.attrPtr = ffiRuntime.pinBuffer(Array(repeating: 0, count: count * 4))
            ctx.bufferLeases[gen] = rec
            return NativeContextBufferLease(
                handle: buffer.raw,
                width: entry.buffer.width,
                height: entry.buffer.height,
                generation: gen,
                char: rec.charPtr,
                fg: rec.fgPtr,
                bg: rec.bgPtr,
                attributes: rec.attrPtr
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextValidateBufferLease [status=adapted hash=6263620a2cc9]
    public func contextValidateBufferLease(_ context: NativeContextHandle, lease: NativeContextBufferLease) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_validate_lease")
            guard let rec = ctx.bufferLeases[lease.generation], rec.active else { return false }
            return rec.handle == lease.handle
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextReleaseBufferLease [status=adapted hash=bd3f35ddc5f6]
    public func contextReleaseBufferLease(_ context: NativeContextHandle, lease: NativeContextBufferLease) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let rec = ctx.bufferLeases.removeValue(forKey: lease.generation) {
                rec.active = false
                ffiRuntime.releaseBuffer(at: rec.charPtr)
                ffiRuntime.releaseBuffer(at: rec.fgPtr)
                ffiRuntime.releaseBuffer(at: rec.bgPtr)
                ffiRuntime.releaseBuffer(at: rec.attrPtr)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextBufferLeaseGetRealCharSize [status=implemented hash=d32ef53ac8f6]
    public func contextBufferLeaseGetRealCharSize(
        _ context: NativeContextHandle,
        lease: NativeContextBufferLease,
        addLineBreaks: Bool = false
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_get_real_char_size")
            guard let rec = ctx.bufferLeases[lease.generation], rec.active else {
                throw NativeError(operation: "ot_buffer_get_real_char_size", status: .staleLease)
            }
            guard let entry = ctx.buffers[lease.handle.slot] else {
                throw NativeError(operation: "ot_buffer_get_real_char_size", status: .staleHandle)
            }
            return entry.buffer.getRealCharBytes(addLineBreaks: addLineBreaks).count
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextBufferLeaseWriteResolvedChars [status=implemented hash=08541985f19e]
    public func contextBufferLeaseWriteResolvedChars(
        _ context: NativeContextHandle,
        lease: NativeContextBufferLease,
        addLineBreaks: Bool = false
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_buffer_write_resolved_chars")
            guard let rec = ctx.bufferLeases[lease.generation], rec.active else {
                throw NativeError(operation: "ot_buffer_write_resolved_chars", status: .staleLease)
            }
            guard let entry = ctx.buffers[lease.handle.slot] else {
                throw NativeError(operation: "ot_buffer_write_resolved_chars", status: .staleHandle)
            }
            return entry.buffer.getRealCharBytes(addLineBreaks: addLineBreaks)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawTextBufferView [status=implemented hash=70bba5bb692c]
    public func contextDrawTextBufferView(
        _ target: NativeDrawingTarget,
        view: ContextTextBufferViewHandle,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_text_view")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_buffer_draw_text_view", status: .staleHandle)
            }
            let tb = ctx.textBuffers[entry.ownerSlot]?.buffer
            let fg = tb?.defaultFg ?? .defaultForeground()
            let bg = tb?.defaultBg
            let attrs = tb?.defaultAttributes ?? TextAttributes.none
            let lines = entry.view.visibleVirtualLines()
            for (idx, vline) in lines.enumerated() {
                buffer.drawText(vline.text, x: x, y: y + idx, fg: fg, bg: bg, attributes: attrs)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawEditorView [status=implemented hash=457956d1e8a2]
    public func contextDrawEditorView(
        _ target: NativeDrawingTarget,
        view: ContextEditorViewHandle,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_editor_view")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_buffer_draw_editor_view", status: .staleHandle)
            }
            let lines = entry.view.getText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let vp = entry.view.getViewport()
            let startY = max(0, vp.offsetY)
            let maxRows = vp.height > 0 ? vp.height : lines.count
            for rowIdx in 0..<maxRows {
                let docRow = startY + rowIdx
                guard docRow < lines.count else { break }
                buffer.drawText(lines[docRow], x: x, y: y + rowIdx, fg: .defaultForeground())
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawSceneBody [status=implemented hash=82e305d8cba1]
    public func contextDrawSceneBody(
        _ target: NativeDrawingTarget,
        node: SceneNodeHandle,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_scene_body")
            guard let entry = ctx.sceneNodes[node.slot], entry.generation == node.generation else {
                throw NativeError(operation: "ot_buffer_draw_scene_body", status: .staleHandle)
            }
            let scene = ctx.ensureScene()
            try scene.drawBody(entry.node, buffer: buffer, x: x, y: y)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextDrawImage [status=implemented hash=8a1bac171a79]
    public func contextDrawImage(
        _ target: NativeDrawingTarget,
        image: ContextImageHandle,
        options: NativeContextImageDraw
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_buffer_draw_image")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_buffer_draw_image", status: .staleHandle)
            }
            ImageBufferRasterizer.render(
                entry.image,
                into: buffer,
                x: options.x,
                y: options.y,
                width: options.width,
                height: options.height
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.logContextDiagnostics [status=implemented hash=f2df598c7f1c]
    public func logContextDiagnostics(_ context: NativeContextHandle) -> [String] {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return [] }
            let drained = ctx.diagnostics
            ctx.diagnostics.removeAll(keepingCapacity: true)
            return drained
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.dispose [status=implemented hash=331791b63185]
    public func dispose() {
        lock.withLock { store in
            guard !store.disposed else { return }
            store.disposed = true
            for (_, ctx) in store.contexts {
                for (_, e) in ctx.buffers { e.buffer.destroy() }
                for (_, e) in ctx.textBufferViews { e.view.destroy() }
                for (_, e) in ctx.textBuffers { e.buffer.destroy() }
                for (_, e) in ctx.editorViews { e.view.destroy() }
                for (_, e) in ctx.editBuffers { e.buffer.destroy() }
                for (_, e) in ctx.syntaxStyles { e.style.destroy() }
                for (_, e) in ctx.markdowns { e.doc.destroy() }
                for (_, e) in ctx.images { e.image.dispose() }
                for (_, e) in ctx.sessions { e.session.destroy() }
                ctx.resourceContext.destroy()
            }
            store.contexts.removeAll()
            for (_, rec) in store.audioEngines { rec.engine.dispose() }
            store.audioEngines.removeAll()
            for (_, rec) in store.spanFeeds { rec.feed.close() }
            store.spanFeeds.removeAll()
            store.clipboardServices.removeAll()
            store.clipboardOpToService.removeAll()
            for (_, node) in store.yogaNodes { node.free() }
            store.yogaNodes.removeAll()
            for (_, cfg) in store.yogaConfigs { try? cfg.free() }
            store.yogaConfigs.removeAll()
            store.activeAllocations = 0
        }
    }

    // MARK: - Embedded Terminal (18 methods)

    // parity: core/src/zig.ts#FFIRenderLib.createContextEmbeddedTerminal [status=implemented hash=25c132351b71]
    public func createContextEmbeddedTerminal(
        _ context: NativeContextHandle,
        cols: Int = 80,
        rows: Int = 24,
        maxScrollback: Int = 1_000,
        transparentBackground: Bool = false
    ) throws -> ContextEmbeddedTerminalHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_create")
            let h = ctx.allocateHandle()
            let term = EmbeddedTerminalState(
                cols: cols,
                rows: rows,
                maxScrollback: maxScrollback,
                transparentBackground: transparentBackground
            )
            ctx.embeddedTerminals[h.slot] = (h.generation, term)
            return ContextEmbeddedTerminalHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextEmbeddedTerminal [status=implemented hash=4dc7a36c0d22]
    public func destroyContextEmbeddedTerminal(_ context: NativeContextHandle, terminal: ContextEmbeddedTerminalHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            _ = ctx.embeddedTerminals.removeValue(forKey: terminal.slot)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalWrite [status=implemented hash=35401c99291c]
    public func contextEmbeddedTerminalWrite(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        bytes: [UInt8]
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_write")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_write", status: .staleHandle)
            }
            entry.terminal.write(bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalResize [status=implemented hash=feb9c3230b2e]
    public func contextEmbeddedTerminalResize(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        cols: Int,
        rows: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_resize")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_resize", status: .staleHandle)
            }
            entry.terminal.cols = max(1, cols)
            entry.terminal.rows = max(1, rows)
            while entry.terminal.lines.count < entry.terminal.rows {
                entry.terminal.lines.append("")
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalInvalidate [status=implemented hash=53b0fad1624a]
    public func contextEmbeddedTerminalInvalidate(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_invalidate")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_invalidate", status: .staleHandle)
            }
            entry.terminal.invalidated = true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalScroll [status=implemented hash=e1fddc2cf4e5]
    public func contextEmbeddedTerminalScroll(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        delta: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_scroll")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_scroll", status: .staleHandle)
            }
            let maxOff = max(0, entry.terminal.lines.count - entry.terminal.rows)
            entry.terminal.scrollOffset = max(0, min(maxOff, entry.terminal.scrollOffset + delta))
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalClearSelection [status=implemented hash=133280d0e98f]
    public func contextEmbeddedTerminalClearSelection(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_clear_selection")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_clear_selection", status: .staleHandle)
            }
            entry.terminal.selection = nil
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalSetTransparentBackground [status=implemented hash=3be61a4c8e05]
    public func contextEmbeddedTerminalSetTransparentBackground(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        enabled: Bool
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_transparent_bg")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_transparent_bg", status: .staleHandle)
            }
            entry.terminal.transparentBackground = enabled
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalSetSelection [status=implemented hash=8820edbcfef0]
    public func contextEmbeddedTerminalSetSelection(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_set_selection")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_set_selection", status: .staleHandle)
            }
            entry.terminal.selection = (startX, startY, endX, endY)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalGetSelectedText [status=implemented hash=12ce7ad81e43]
    public func contextEmbeddedTerminalGetSelectedText(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_get_selected_text")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_get_selected_text", status: .staleHandle)
            }
            return entry.terminal.selectedText()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalCompose [status=implemented hash=4b951d0c40cf]
    public func contextEmbeddedTerminalCompose(
        _ target: NativeDrawingTarget,
        terminal: ContextEmbeddedTerminalHandle,
        x: Int = 0,
        y: Int = 0
    ) throws {
        try lock.withLock { store in
            let (ctx, buffer) = try resolveTargetBuffer(store, target, op: "ot_embedded_terminal_compose")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_compose", status: .staleHandle)
            }
            let t = entry.terminal
            let startRow = max(0, t.lines.count - t.rows - t.scrollOffset)
            for rowIdx in 0..<t.rows {
                let src = startRow + rowIdx
                guard src < t.lines.count else { break }
                buffer.drawText(t.lines[src], x: x, y: y + rowIdx, fg: .defaultForeground())
            }
            t.invalidated = false
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalCursor [status=implemented hash=aac949ca2ecc]
    public func contextEmbeddedTerminalCursor(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws -> EmbeddedTerminalCursor {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_cursor_get")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_cursor_get", status: .staleHandle)
            }
            return EmbeddedTerminalCursor(
                x: entry.terminal.cursorX,
                y: entry.terminal.cursorY,
                visible: true,
                style: .block,
                blinking: false
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalScrollbar [status=implemented hash=fecc5f02a889]
    public func contextEmbeddedTerminalScrollbar(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws -> EmbeddedTerminalScrollState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_scrollbar_get")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_scrollbar_get", status: .staleHandle)
            }
            return EmbeddedTerminalScrollState(
                offset: entry.terminal.scrollOffset,
                total: entry.terminal.lines.count,
                visible: entry.terminal.rows
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalEncodeKey [status=implemented hash=6e1f58bf57f6]
    public func contextEmbeddedTerminalEncodeKey(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        key: EmbeddedTerminalKey
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_encode_key")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_encode_key", status: .staleHandle)
            }
            if let text = key.text, !text.isEmpty { return Array(text.utf8) }
            switch key.key {
            case "enter", "return": return [0x0D]
            case "escape": return [0x1B]
            case "tab": return [0x09]
            case "backspace": return [0x7F]
            case "up": return Array("\u{1B}[A".utf8)
            case "down": return Array("\u{1B}[B".utf8)
            case "right": return Array("\u{1B}[C".utf8)
            case "left": return Array("\u{1B}[D".utf8)
            default:
                if let k = key.key { return Array(k.utf8) }
                return []
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalEncodeMouse [status=implemented hash=0530d40b56bf]
    public func contextEmbeddedTerminalEncodeMouse(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        mouse: EmbeddedTerminalMouse
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_encode_mouse")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_encode_mouse", status: .staleHandle)
            }
            let btn: Int = switch mouse.button {
            case "left": 0
            case "middle": 1
            case "right": 2
            default: 3
            }
            let suffix = mouse.action == "release" ? "m" : "M"
            return Array("\u{1B}[<\(btn);\(mouse.x + 1);\(mouse.y + 1)\(suffix)".utf8)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalEncodePaste [status=implemented hash=dd1961ea9cb7]
    public func contextEmbeddedTerminalEncodePaste(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        bytes: [UInt8]
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_encode_paste")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_encode_paste", status: .staleHandle)
            }
            return Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalEncodeFocus [status=implemented hash=eda173533cb3]
    public func contextEmbeddedTerminalEncodeFocus(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle,
        focused: Bool
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_encode_focus")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_encode_focus", status: .staleHandle)
            }
            return Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEmbeddedTerminalDrainResponses [status=implemented hash=761f8724fcc1]
    public func contextEmbeddedTerminalDrainResponses(
        _ context: NativeContextHandle,
        terminal: ContextEmbeddedTerminalHandle
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_embedded_terminal_drain_responses")
            guard let entry = ctx.embeddedTerminals[terminal.slot], entry.generation == terminal.generation else {
                throw NativeError(operation: "ot_embedded_terminal_drain_responses", status: .staleHandle)
            }
            let flat = entry.terminal.responses.flatMap { $0 }
            entry.terminal.responses.removeAll(keepingCapacity: true)
            return flat
        }
    }

    // MARK: - TextBuffer & TextBufferView (32 methods)

    // parity: core/src/zig.ts#FFIRenderLib.createContextTextBuffer [status=implemented hash=d06090bcdb82]
    public func createContextTextBuffer(
        _ context: NativeContextHandle,
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions()
    ) throws -> ContextTextBufferHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_create")
            let tb = TextBuffer(widthMethod: options.widthMethod)
            let h = ctx.allocateHandle()
            ctx.textBuffers[h.slot] = (h.generation, tb, 1, [:])
            return ContextTextBufferHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextTextBuffer [status=implemented hash=db6aeb1b01fd]
    public func destroyContextTextBuffer(_ context: NativeContextHandle, textBuffer: ContextTextBufferHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.textBuffers.removeValue(forKey: textBuffer.slot) {
                entry.buffer.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createContextTextBufferView [status=implemented hash=be4d5f755623]
    public func createContextTextBufferView(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle
    ) throws -> ContextTextBufferViewHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_create")
            guard let tbEntry = ctx.textBuffers[textBuffer.slot], tbEntry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_view_create", status: .staleHandle)
            }
            let view = TextBufferView.create(tbEntry.buffer)
            let h = ctx.allocateHandle()
            ctx.textBufferViews[h.slot] = (h.generation, view, textBuffer.slot)
            return ContextTextBufferViewHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextTextBufferView [status=implemented hash=3a09bf08d7ea]
    public func destroyContextTextBufferView(_ context: NativeContextHandle, view: ContextTextBufferViewHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.textBufferViews.removeValue(forKey: view.slot) {
                entry.view.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetText [status=implemented hash=58c09eb761a0]
    public func contextTextBufferSetText(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        text: String
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_text")
            guard var entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_text", status: .staleHandle)
            }
            entry.buffer.setText(text)
            entry.epoch &+= 1
            ctx.textBuffers[textBuffer.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferAppend [status=implemented hash=4e25b55c53db]
    public func contextTextBufferAppend(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        text: String
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_append")
            guard var entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_append", status: .staleHandle)
            }
            entry.buffer.append(text)
            entry.epoch &+= 1
            ctx.textBuffers[textBuffer.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferClear [status=implemented hash=23bf8e024282]
    public func contextTextBufferClear(_ context: NativeContextHandle, textBuffer: ContextTextBufferHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_clear")
            guard var entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_clear", status: .staleHandle)
            }
            entry.buffer.clear()
            entry.epoch &+= 1
            ctx.textBuffers[textBuffer.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetStyledText [status=implemented hash=f07aff175220]
    public func contextTextBufferSetStyledText(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        chunks: [TextChunk]
    ) throws {
        let encoded = encodeTextBufferStyledText(chunks)
        try contextTextBufferSetEncodedStyledText(context, textBuffer: textBuffer, encoded: encoded)
    }

    // parity: core/src/zig.ts#FFIRenderLib.encodeTextBufferStyledText [status=implemented hash=27cc49d1697f]
    public func encodeTextBufferStyledText(_ chunks: [TextChunk]) -> NativeEncodedStyledText {
        var bytes: [UInt8] = []
        var urlBytes: [UInt8] = []
        var records: [UInt32] = []
        for chunk in chunks {
            let textBytes = Array(chunk.text.utf8)
            bytes.append(contentsOf: textBytes)
            let linkOffset = UInt32(urlBytes.count)
            var linkLen: UInt32 = 0
            if let url = chunk.link?.url {
                let ub = Array(url.utf8)
                urlBytes.append(contentsOf: ub)
                linkLen = UInt32(ub.count)
            }
            let zigChunk = ZigTextChunk(
                byteCount: UInt32(textBytes.count),
                flags: (chunk.fg != nil ? 1 : 0) | (chunk.bg != nil ? 2 : 0) | (chunk.attributes != nil ? 4 : 0),
                foreground: chunk.fg ?? .defaultForeground(),
                background: chunk.bg ?? RGBA.fromInts(0, 0, 0, 0),
                attributes: chunk.attributes ?? TextAttributes.none,
                linkOffset: linkOffset,
                linkByteCount: linkLen
            )
            let packed = zigChunk.pack()
            for i in stride(from: 0, to: packed.count, by: 4) {
                records.append(ZigBinaryCodec.readU32(packed, at: i))
            }
        }
        return NativeEncodedStyledText(
            bytes: bytes,
            records: records,
            count: chunks.count,
            urlBytes: urlBytes,
            chunks: chunks
        )
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetEncodedStyledText [status=implemented hash=cbee1de0830f]
    public func contextTextBufferSetEncodedStyledText(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        encoded: NativeEncodedStyledText
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_styled_text")
            guard var entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_styled_text", status: .staleHandle)
            }
            if !encoded.chunks.isEmpty {
                entry.buffer.setStyledText(StyledText(chunks: encoded.chunks))
            } else {
                entry.buffer.setText(String(decoding: encoded.bytes, as: UTF8.self))
            }
            entry.epoch &+= 1
            ctx.textBuffers[textBuffer.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferReplaceStyledBatch [status=implemented hash=15f0e7876754]
    public func contextTextBufferReplaceStyledBatch(
        _ context: NativeContextHandle,
        updates: [(textBuffer: ContextTextBufferHandle, chunks: [TextChunk])]
    ) throws {
        for item in updates {
            try contextTextBufferSetStyledText(context, textBuffer: item.textBuffer, chunks: item.chunks)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetSyntaxStyle [status=implemented hash=ffc7fc258747]
    public func contextTextBufferSetSyntaxStyle(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        style: ContextSyntaxStyleHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_syntax_style")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_syntax_style", status: .staleHandle)
            }
            entry.buffer.syntaxStyleToken = style?.slot
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferGetInfo [status=implemented hash=17349ed61bf5]
    public func contextTextBufferGetInfo(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle
    ) throws -> NativeTextBufferInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_get_info")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_get_info", status: .staleHandle)
            }
            let text = entry.buffer.getPlainText()
            return NativeTextBufferInfo(
                contentEpoch: entry.epoch,
                byteLength: text.utf8.count,
                textLength: text.unicodeScalars.count,
                lineCount: entry.buffer.getLineCount(),
                highlightCount: entry.buffer.getHighlightCount(),
                tabWidth: entry.buffer.getTabWidth()
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferGetText [status=implemented hash=f393596e03b5]
    public func contextTextBufferGetText(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_get_text")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_get_text", status: .staleHandle)
            }
            return entry.buffer.getPlainText()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferGetRange [status=implemented hash=51b11247f497]
    public func contextTextBufferGetRange(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        startOffset: Int,
        endOffset: Int
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_get_range")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_get_range", status: .staleHandle)
            }
            return entry.buffer.getTextRange(startOffset: startOffset, endOffset: endOffset)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetDefaults [status=implemented hash=363183e6a9c8]
    public func contextTextBufferSetDefaults(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        style: NativeEditorStyle,
        reset: Bool = false
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_defaults")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_defaults", status: .staleHandle)
            }
            if reset {
                entry.buffer.resetDefaults()
            } else {
                if let fg = style.fg { entry.buffer.setDefaultFg(fg) }
                if let bg = style.bg { entry.buffer.setDefaultBg(bg) }
                if let attrs = style.attributes { entry.buffer.setDefaultAttributes(attrs) }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetTabWidth [status=implemented hash=52b7ae68a295]
    public func contextTextBufferSetTabWidth(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        tabWidth: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_tab_width")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_tab_width", status: .staleHandle)
            }
            entry.buffer.setTabWidth(tabWidth)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetWidthMethod [status=implemented hash=11ec96f60f70]
    public func contextTextBufferSetWidthMethod(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        method: TextWidthMethod
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_width_method")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_width_method", status: .staleHandle)
            }
            entry.buffer.setWidthMethod(method)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferHighlight [status=implemented hash=bb0c6fb83b3d]
    public func contextTextBufferHighlight(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        operation: NativeEditHighlightOperation,
        lineOrRef: Int = 0,
        highlight: Highlight? = nil
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_highlight")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_highlight", status: .staleHandle)
            }
            switch operation {
            case .addLine:
                if let hl = highlight { entry.buffer.addHighlight(lineIdx: lineOrRef, highlight: hl) }
            case .addRange:
                if let hl = highlight { entry.buffer.addHighlightByCharRange(hl) }
            case .removeRef:
                entry.buffer.removeHighlightsByRef(lineOrRef)
            case .clearLine:
                entry.buffer.clearLineHighlights(lineOrRef)
            case .clearAll:
                entry.buffer.clearAllHighlights()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextGroupSet [status=implemented hash=34293d9681c1]
    public func contextGroupSet(
        _ context: NativeContextHandle,
        target: ContextObjectHandle,
        groupIds: [UInt32]
    ) throws -> UInt32 {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_context_group_set")
            if var entry = ctx.textBuffers[target.slot] {
                let id = UInt32(entry.groupSets.count + 1)
                entry.groupSets[id] = groupIds
                ctx.textBuffers[target.slot] = entry
                return id
            }
            return groupIds.first ?? 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferSetLayer [status=implemented hash=a19ebeffb9da]
    public func contextTextBufferSetLayer(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        layer: UInt32,
        highlights: [Highlight]
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_set_layer")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_set_layer", status: .staleHandle)
            }
            let ref = Int(layer)
            entry.buffer.removeHighlightsByRef(ref)
            for var hl in highlights {
                hl.hlRef = ref
                entry.buffer.addHighlightByCharRange(hl)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferGetHighlights [status=implemented hash=2ba673680526]
    public func contextTextBufferGetHighlights(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        lineIdx: Int
    ) throws -> [Highlight] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_get_highlights")
            guard let entry = ctx.textBuffers[textBuffer.slot], entry.generation == textBuffer.generation else {
                throw NativeError(operation: "ot_text_buffer_get_highlights", status: .staleHandle)
            }
            return entry.buffer.getLineHighlights(lineIdx)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewSetViewport [status=implemented hash=5b1a2fbe66af]
    public func contextTextBufferViewSetViewport(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_set_viewport")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_set_viewport", status: .staleHandle)
            }
            entry.view.setViewport(x: x, y: y, width: width, height: height)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewCommand [status=implemented hash=3bf0c4202950]
    public func contextTextBufferViewCommand(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle,
        command: NativeTextViewCommand,
        argument: UInt32
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_command")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_command", status: .staleHandle)
            }
            switch command {
            case .wrapWidth:
                entry.view.setWrapWidth(argument == 0 ? nil : Int(argument))
            case .wrapMode:
                let mode: TextWrapMode = argument == 1 ? .char : (argument == 2 ? .word : .none)
                entry.view.setWrapMode(mode)
            case .firstLineOffset:
                entry.view.setFirstLineOffset(Int(argument))
            case .tabIndicator:
                entry.view.setTabIndicator(codePoint: argument)
            case .truncate:
                entry.view.setTruncate(argument != 0)
            case .textAlign:
                let align: TextAlign = argument == 1 ? .center : (argument == 2 ? .right : .left)
                entry.view.setTextAlign(align)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewSetTabColor [status=implemented hash=abded07a1794]
    public func contextTextBufferViewSetTabColor(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle,
        color: RGBA
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_set_tab_color")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_set_tab_color", status: .staleHandle)
            }
            entry.view.setTabIndicatorColor(color)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewSelect [status=implemented hash=cb0fb98eed23]
    @discardableResult
    public func contextTextBufferViewSelect(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle,
        selection: NativeEditorSelection
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_select")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_select", status: .staleHandle)
            }
            switch selection.operation {
            case .set:
                entry.view.setSelection(start: selection.start ?? 0, end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .update:
                entry.view.updateSelection(end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .reset:
                entry.view.resetSelection()
                return false
            case .local:
                return entry.view.setLocalSelection(
                    anchorX: selection.anchorX ?? 0,
                    anchorY: selection.anchorY ?? 0,
                    focusX: selection.focusX ?? 0,
                    focusY: selection.focusY ?? 0,
                    bgColor: selection.bg,
                    fgColor: selection.fg,
                    behavior: selection.behavior
                )
            case .localUpdate:
                return entry.view.updateLocalSelection(
                    anchorX: selection.anchorX ?? 0,
                    anchorY: selection.anchorY ?? 0,
                    focusX: selection.focusX ?? 0,
                    focusY: selection.focusY ?? 0,
                    bgColor: selection.bg,
                    fgColor: selection.fg,
                    behavior: selection.behavior
                )
            case .localReset:
                entry.view.resetLocalSelection()
                return false
            case .cell:
                return entry.view.hasSelection()
            case .occupancy:
                entry.view.setSelectionOccupancy(selection.occupancy ?? .cell)
                return entry.view.hasSelection()
            case .inclusive:
                entry.view.setSelectionInclusive(start: selection.start ?? 0, end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .colors:
                entry.view.setSelectionColors(bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewResetSelection [status=implemented hash=aa5c8a7dcf62]
    public func contextTextBufferViewResetSelection(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_reset_selection")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_reset_selection", status: .staleHandle)
            }
            entry.view.resetSelection()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewGetInfo [status=implemented hash=184db8d12516]
    public func contextTextBufferViewGetInfo(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle
    ) throws -> NativeEditorViewInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_get_info")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_get_info", status: .staleHandle)
            }
            let count = entry.view.getVirtualLineCount()
            return NativeEditorViewInfo(
                virtualLineCount: count,
                totalVirtualLineCount: count,
                selection: entry.view.getSelection(),
                selectionOccupancy: entry.view.getSelectionOccupancy()
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewGetSelectedText [status=implemented hash=9d9b9e581931]
    public func contextTextBufferViewGetSelectedText(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_get_selected_text")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_get_selected_text", status: .staleHandle)
            }
            return entry.view.getSelectedText()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewGetLines [status=implemented hash=873a67f0c08d]
    public func contextTextBufferViewGetLines(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle
    ) throws -> LineInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_get_lines")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_get_lines", status: .staleHandle)
            }
            return entry.view.lineInfo
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextTextBufferViewMeasure [status=implemented hash=84a06f476507]
    public func contextTextBufferViewMeasure(
        _ context: NativeContextHandle,
        view: ContextTextBufferViewHandle,
        width: Int,
        height: Int
    ) throws -> MeasureResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_text_buffer_view_measure")
            guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_text_buffer_view_measure", status: .staleHandle)
            }
            return entry.view.measureForDimensions(width: width, height: height)
                ?? MeasureResult(lineCount: 0, widthColsMax: 0)
        }
    }
}

// MARK: - EditBuffer, EditorView & SyntaxStyle (40 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.createContextEditBuffer [status=implemented hash=85f2f1af9951]
    public func createContextEditBuffer(
        _ context: NativeContextHandle,
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions()
    ) throws -> ContextEditBufferHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_create")
            let h = ctx.allocateHandle()
            let eb = EditBuffer(widthMethod: options.widthMethod, id: h.slot)
            ctx.editBuffers[h.slot] = (h.generation, eb, 1, [:], 1)
            return ContextEditBufferHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextEditBuffer [status=implemented hash=2905c2f1b001]
    public func destroyContextEditBuffer(_ context: NativeContextHandle, editBuffer: ContextEditBufferHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.editBuffers.removeValue(forKey: editBuffer.slot) {
                entry.buffer.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createContextEditorView [status=implemented hash=26e324403239]
    public func createContextEditorView(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        width: Int = 80,
        height: Int = 24
    ) throws -> ContextEditorViewHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_create")
            guard let ebEntry = ctx.editBuffers[editBuffer.slot], ebEntry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_editor_view_create", status: .staleHandle)
            }
            let view = EditorView.create(editBuffer: ebEntry.buffer, viewportWidth: width, viewportHeight: height)
            let h = ctx.allocateHandle()
            ctx.editorViews[h.slot] = (h.generation, view, editBuffer.slot)
            return ContextEditorViewHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextEditorView [status=implemented hash=456f43dfb5f9]
    public func destroyContextEditorView(_ context: NativeContextHandle, view: ContextEditorViewHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.editorViews.removeValue(forKey: view.slot) {
                entry.view.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createContextSyntaxStyle [status=implemented hash=fb753c2e5cfa]
    public func createContextSyntaxStyle(_ context: NativeContextHandle) throws -> ContextSyntaxStyleHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_syntax_style_create")
            let h = ctx.allocateHandle()
            ctx.syntaxStyles[h.slot] = (h.generation, SyntaxStyle.create())
            return ContextSyntaxStyleHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextSyntaxStyle [status=implemented hash=93cdfbce53af]
    public func destroyContextSyntaxStyle(_ context: NativeContextHandle, style: ContextSyntaxStyleHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.syntaxStyles.removeValue(forKey: style.slot) {
                entry.style.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferSetSyntaxStyle [status=implemented hash=32877bd4c4ce]
    public func contextEditBufferSetSyntaxStyle(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        style: ContextSyntaxStyleHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_set_syntax_style")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_set_syntax_style", status: .staleHandle)
            }
            entry.buffer.syntaxStyleToken = style?.slot
        }
    }

    private func notifyEditEvent(_ ctx: ContextState, handle: ContextEditBufferHandle, event: NativeEditEvent) {
        for listener in ctx.editEventListeners.values {
            listener(handle, event)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferSetText [status=implemented hash=d467d502ff49]
    public func contextEditBufferSetText(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        text: String,
        replace: Bool = false
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_set_text")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_set_text", status: .staleHandle)
            }
            if replace {
                entry.buffer.replaceText(text)
            } else {
                entry.buffer.setText(text)
            }
            entry.epoch &+= 1
            ctx.editBuffers[editBuffer.slot] = entry
            notifyEditEvent(ctx, handle: editBuffer, event: [.contentChanged, .cursorChanged])
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferInsertText [status=implemented hash=1ca5ed00cf8c]
    public func contextEditBufferInsertText(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        text: String
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_insert_text")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_insert_text", status: .staleHandle)
            }
            entry.buffer.insertText(text)
            entry.epoch &+= 1
            ctx.editBuffers[editBuffer.slot] = entry
            notifyEditEvent(ctx, handle: editBuffer, event: [.contentChanged, .cursorChanged])
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferDeleteRange [status=implemented hash=101ac2a365a5]
    public func contextEditBufferDeleteRange(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        startLine: Int,
        startCol: Int,
        endLine: Int,
        endCol: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_delete_range")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_delete_range", status: .staleHandle)
            }
            entry.buffer.deleteRange(startLine: startLine, startCol: startCol, endLine: endLine, endCol: endCol)
            entry.epoch &+= 1
            ctx.editBuffers[editBuffer.slot] = entry
            notifyEditEvent(ctx, handle: editBuffer, event: [.contentChanged, .cursorChanged])
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferSetCursor [status=implemented hash=6be563ba2543]
    public func contextEditBufferSetCursor(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        line: Int,
        col: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_set_cursor")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_set_cursor", status: .staleHandle)
            }
            entry.buffer.setCursor(line: line, col: col)
            notifyEditEvent(ctx, handle: editBuffer, event: .cursorChanged)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetText [status=implemented hash=2c78a619c83b]
    public func contextEditBufferGetText(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_text")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_text", status: .staleHandle)
            }
            return entry.buffer.getText()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetInfo [status=implemented hash=de54148ed432]
    public func contextEditBufferGetInfo(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle
    ) throws -> NativeEditBufferInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_info")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_info", status: .staleHandle)
            }
            let text = entry.buffer.getText()
            return NativeEditBufferInfo(
                contentEpoch: entry.epoch,
                byteLength: text.utf8.count,
                lineCount: entry.buffer.getLineCount(),
                cursor: entry.buffer.getCursorPosition(),
                canUndo: entry.buffer.canUndo(),
                canRedo: entry.buffer.canRedo(),
                tabWidth: entry.buffer.getTabWidth()
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferSetTabWidth [status=implemented hash=2beb4080e5f4]
    public func contextEditBufferSetTabWidth(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        tabWidth: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_set_tab_width")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_set_tab_width", status: .staleHandle)
            }
            entry.buffer.setTabWidth(tabWidth)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferCommand [status=implemented hash=d8c8178f309d]
    public func contextEditBufferCommand(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        command: NativeEditCommand,
        argument: UInt32 = 0
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_command")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_command", status: .staleHandle)
            }
            switch command {
            case .deleteForward: entry.buffer.deleteForward()
            case .backspace: entry.buffer.deleteBackward()
            case .newLine: entry.buffer.newLine()
            case .deleteLine: entry.buffer.deleteLine()
            case .moveLeft: entry.buffer.moveCursorLeft()
            case .moveRight: entry.buffer.moveCursorRight()
            case .moveUp: entry.buffer.moveCursorUp()
            case .moveDown: entry.buffer.moveCursorDown()
            case .gotoLine: entry.buffer.gotoLine(Int(argument))
            case .cursorOffset, .cursorOffsetAtomic: entry.buffer.setCursorByOffset(Int(argument))
            case .clear: entry.buffer.clear()
            case .clearHistory: entry.buffer.clearHistory()
            case .debugRope: _ = entry.buffer.debugLogRope()
            case .keepOutside: break
            }
            entry.epoch &+= 1
            ctx.editBuffers[editBuffer.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferHistory [status=implemented hash=474335335e2a]
    public func contextEditBufferHistory(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        redo: Bool
    ) throws -> String? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_history")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_history", status: .staleHandle)
            }
            let result = redo ? entry.buffer.redo() : entry.buffer.undo()
            entry.epoch &+= 1
            ctx.editBuffers[editBuffer.slot] = entry
            return result
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetPosition [status=implemented hash=f9435447358d]
    public func contextEditBufferGetPosition(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        query: NativeEditPositionQuery,
        arg0: Int = 0,
        arg1: Int = 0
    ) throws -> LogicalCursor? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_position")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_position", status: .staleHandle)
            }
            switch query {
            case .cursor: return entry.buffer.getCursorPosition()
            case .nextWord: return entry.buffer.getNextWordBoundary()
            case .prevWord: return entry.buffer.getPrevWordBoundary()
            case .eol: return entry.buffer.getEOL()
            case .offset:
                guard let pos = entry.buffer.offsetToPosition(arg0) else { return nil }
                return LogicalCursor(row: pos.row, col: pos.col, offset: arg0)
            case .coords:
                let off = entry.buffer.positionToOffset(row: arg0, col: arg1)
                return LogicalCursor(row: arg0, col: arg1, offset: off)
            case .lineStart:
                let off = entry.buffer.getLineStartOffset(arg0)
                return LogicalCursor(row: arg0, col: 0, offset: off)
            case .end:
                let lines = entry.buffer.getLineCount()
                let lastRow = max(0, lines - 1)
                let off = entry.buffer.getText().count
                return LogicalCursor(row: lastRow, col: 0, offset: off)
            case .prevChar:
                let cur = entry.buffer.getCursorPosition()
                let prev = max(0, cur.offset - 1)
                if let pos = entry.buffer.offsetToPosition(prev) {
                    return LogicalCursor(row: pos.row, col: pos.col, offset: prev)
                }
                return cur
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetRange [status=implemented hash=5f27a04c86df]
    public func contextEditBufferGetRange(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        byCoords: Bool = false,
        startA: Int,
        startB: Int = 0,
        endA: Int,
        endB: Int = 0
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_range")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_range", status: .staleHandle)
            }
            if byCoords {
                return entry.buffer.getTextRangeByCoords(startRow: startA, startCol: startB, endRow: endA, endCol: endB)
            }
            return entry.buffer.getTextRange(startOffset: startA, endOffset: endA)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferConvertOffset [status=implemented hash=282db6e97ad7]
    public func contextEditBufferConvertOffset(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        offset: Int,
        toCellOffset: Bool
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_convert_offset")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_convert_offset", status: .staleHandle)
            }
            return toCellOffset
                ? entry.buffer.stringIndexToCellOffset(offset)
                : entry.buffer.cellOffsetToStringIndex(offset)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferMeasureText [status=implemented hash=94b08002bbdb]
    public func contextEditBufferMeasureText(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        text: String
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_measure_text")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_measure_text", status: .staleHandle)
            }
            return entry.buffer.measureText(text)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.editMeasureText [status=implemented hash=c0771aab4143]
    public func editMeasureText(
        _ text: String,
        widthMethod: TextWidthMethod = .unicode,
        tabWidth: Int? = nil
    ) -> Int {
        measureEditText(text, widthMethod: widthMethod, tabWidth: tabWidth)
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferSetDefaults [status=implemented hash=9f590d7fa97c]
    public func contextEditBufferSetDefaults(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        style: NativeEditorStyle,
        reset: Bool = false
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_set_defaults")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_set_defaults", status: .staleHandle)
            }
            if reset {
                entry.buffer.resetDefaults()
            } else {
                if let fg = style.fg { entry.buffer.setDefaultFg(fg) }
                if let bg = style.bg { entry.buffer.setDefaultBg(bg) }
                if let attrs = style.attributes { entry.buffer.setDefaultAttributes(attrs) }
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextSyntaxStyleRegister [status=implemented hash=f207bd38c2ad]
    public func contextSyntaxStyleRegister(
        _ context: NativeContextHandle,
        style: ContextSyntaxStyleHandle,
        name: String,
        definition: NativeEditorStyle
    ) throws -> UInt32 {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_syntax_style_register")
            guard let entry = ctx.syntaxStyles[style.slot], entry.generation == style.generation else {
                throw NativeError(operation: "ot_syntax_style_register", status: .staleHandle)
            }
            let attrs = definition.attributes ?? 0
            let def = StyleDefinition(
                fg: definition.fg,
                bg: definition.bg,
                bold: (attrs & TextAttributes.bold) != 0 ? true : nil,
                italic: (attrs & TextAttributes.italic) != 0 ? true : nil,
                underline: (attrs & TextAttributes.underline) != 0 ? true : nil,
                dim: (attrs & TextAttributes.dim) != 0 ? true : nil,
                strikethrough: (attrs & TextAttributes.strikethrough) != 0 ? true : nil
            )
            return entry.style.registerStyle(name, def)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextSyntaxStyleResolveByName [status=implemented hash=cc636fcc69eb]
    public func contextSyntaxStyleResolveByName(
        _ context: NativeContextHandle,
        style: ContextSyntaxStyleHandle,
        name: String
    ) throws -> UInt32? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_syntax_style_resolve")
            guard let entry = ctx.syntaxStyles[style.slot], entry.generation == style.generation else {
                throw NativeError(operation: "ot_syntax_style_resolve", status: .staleHandle)
            }
            return entry.style.resolveStyleId(name)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextSyntaxStyleGetStyleCount [status=implemented hash=5d309872cb21]
    public func contextSyntaxStyleGetStyleCount(
        _ context: NativeContextHandle,
        style: ContextSyntaxStyleHandle
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_syntax_style_get_count")
            guard let entry = ctx.syntaxStyles[style.slot], entry.generation == style.generation else {
                throw NativeError(operation: "ot_syntax_style_get_count", status: .staleHandle)
            }
            return entry.style.getStyleCount()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferHighlight [status=implemented hash=2d2c3b531015]
    public func contextEditBufferHighlight(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        operation: NativeEditHighlightOperation,
        lineOrRef: Int = 0,
        highlight: Highlight? = nil
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_highlight")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_highlight", status: .staleHandle)
            }
            switch operation {
            case .addLine:
                if let hl = highlight { entry.buffer.addHighlight(lineIdx: lineOrRef, highlight: hl) }
            case .addRange:
                if let hl = highlight { entry.buffer.addHighlightByCharRange(hl) }
            case .removeRef:
                entry.buffer.removeHighlightsByRef(lineOrRef)
            case .clearLine:
                entry.buffer.clearLineHighlights(lineOrRef)
            case .clearAll:
                entry.buffer.clearAllHighlights()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetHighlights [status=implemented hash=7e0e149258a0]
    public func contextEditBufferGetHighlights(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        lineIdx: Int
    ) throws -> [Highlight] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_highlights")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_highlights", status: .staleHandle)
            }
            return entry.buffer.getLineHighlights(lineIdx)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferMark [status=implemented hash=e57806a1ad5e]
    @discardableResult
    public func contextEditBufferMark(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        operation: NativeEditMarkOperation,
        mark: NativeEditMark? = nil,
        markId: UInt32? = nil
    ) throws -> UInt32 {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_mark")
            guard var entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_mark", status: .staleHandle)
            }
            let assignedId: UInt32
            switch operation {
            case .add:
                let id = (mark?.id ?? 0) != 0 ? mark!.id : entry.nextMarkId
                entry.nextMarkId = max(entry.nextMarkId, id) &+ 1
                var stored = mark ?? NativeEditMark(id: id, kind: 0, atomic: false, style: 0, priority: 0, start: 0, end: 0)
                stored.id = id
                entry.marks[id] = stored
                assignedId = id
            case .remove:
                let id = markId ?? mark?.id ?? 0
                _ = entry.marks.removeValue(forKey: id)
                assignedId = id
            case .clear:
                entry.marks.removeAll()
                assignedId = 0
            }
            ctx.editBuffers[editBuffer.slot] = entry
            return assignedId
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditBufferGetMarks [status=implemented hash=4e3a96007f48]
    public func contextEditBufferGetMarks(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        kind: UInt32 = UInt32(truncatingIfNeeded: NativeABI.OT_EDIT_MARK_ANY_KIND)
    ) throws -> [NativeEditMark] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_buffer_get_marks")
            guard let entry = ctx.editBuffers[editBuffer.slot], entry.generation == editBuffer.generation else {
                throw NativeError(operation: "ot_edit_buffer_get_marks", status: .staleHandle)
            }
            let anyKind = UInt32(truncatingIfNeeded: NativeABI.OT_EDIT_MARK_ANY_KIND)
            return entry.marks.values
                .filter { kind == anyKind || $0.kind == kind }
                .sorted { $0.start < $1.start || ($0.start == $1.start && $0.id < $1.id) }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewSetViewport [status=implemented hash=23a3b3d6e8a4]
    public func contextEditorViewSetViewport(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        viewport: NativeEditorViewport,
        moveCursor: Bool = true
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_set_viewport")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_set_viewport", status: .staleHandle)
            }
            entry.view.setViewport(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height, moveCursor: moveCursor)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetViewport [status=implemented hash=4c497956825f]
    public func contextEditorViewGetViewport(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle
    ) throws -> NativeEditorViewport {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_viewport")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_viewport", status: .staleHandle)
            }
            let vp = entry.view.getViewport()
            return NativeEditorViewport(x: vp.offsetX, y: vp.offsetY, width: vp.width, height: vp.height)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewSetScrollMargin [status=implemented hash=65be8cd2a3b8]
    public func contextEditorViewSetScrollMargin(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        margin: Double
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_set_scroll_margin")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_set_scroll_margin", status: .staleHandle)
            }
            entry.view.setScrollMargin(margin)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewCommand [status=implemented hash=5cc44e8263f4]
    public func contextEditorViewCommand(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        command: NativeEditorCommand,
        argument: UInt32 = 0
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_command")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_command", status: .staleHandle)
            }
            switch command {
            case .moveUp: entry.view.moveUpVisual()
            case .moveDown: entry.view.moveDownVisual()
            case .gotoLineEnd: entry.view.gotoVisualLineEnd()
            case .deleteSelection: entry.view.deleteSelectedText()
            case .cursorOffset: entry.view.setCursorByOffset(Int(argument))
            case .wrapMode:
                let mode: TextWrapMode = argument == 1 ? .char : (argument == 2 ? .word : .none)
                entry.view.setWrapMode(mode)
            case .tabIndicator:
                entry.view.setTabIndicator(codePoint: argument)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewReplaceSelection [status=implemented hash=c87a9bf6c102]
    public func contextEditorViewReplaceSelection(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        text: String
    ) throws -> NativeEditorReplacement {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_replace_selection")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_replace_selection", status: .staleHandle)
            }
            let hadSelection = entry.view.hasSelection()
            entry.view.replaceSelectedText(text)
            return NativeEditorReplacement(deleted: hadSelection, inserted: !text.isEmpty)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewSetTabColor [status=implemented hash=54f4fc855ece]
    public func contextEditorViewSetTabColor(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        color: RGBA
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_set_tab_color")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_set_tab_color", status: .staleHandle)
            }
            entry.view.setTabIndicatorColor(color)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewSelect [status=implemented hash=662bc2091ab9]
    @discardableResult
    public func contextEditorViewSelect(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        selection: NativeEditorSelection
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_select")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_select", status: .staleHandle)
            }
            switch selection.operation {
            case .set:
                entry.view.setSelection(start: selection.start ?? 0, end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .update:
                entry.view.updateSelection(end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .reset:
                entry.view.resetSelection()
                return false
            case .local:
                return entry.view.setLocalSelection(
                    anchorX: selection.anchorX ?? 0,
                    anchorY: selection.anchorY ?? 0,
                    focusX: selection.focusX ?? 0,
                    focusY: selection.focusY ?? 0,
                    bgColor: selection.bg,
                    fgColor: selection.fg,
                    updateCursor: selection.updateCursor,
                    followCursor: selection.followCursor,
                    behavior: selection.behavior
                )
            case .localUpdate:
                return entry.view.updateLocalSelection(
                    anchorX: selection.anchorX ?? 0,
                    anchorY: selection.anchorY ?? 0,
                    focusX: selection.focusX ?? 0,
                    focusY: selection.focusY ?? 0,
                    bgColor: selection.bg,
                    fgColor: selection.fg,
                    updateCursor: selection.updateCursor,
                    followCursor: selection.followCursor,
                    behavior: selection.behavior
                )
            case .localReset:
                entry.view.resetLocalSelection()
                return false
            case .cell:
                return entry.view.convertSelectionToCell()
            case .occupancy:
                entry.view.setSelectionOccupancy(selection.occupancy ?? .cell)
                return entry.view.hasSelection()
            case .inclusive:
                entry.view.setSelectionInclusive(start: selection.start ?? 0, end: selection.end ?? 0, bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            case .colors:
                entry.view.setSelectionColors(bgColor: selection.bg, fgColor: selection.fg)
                return entry.view.hasSelection()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetInfo [status=implemented hash=386bb43c9585]
    public func contextEditorViewGetInfo(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle
    ) throws -> NativeEditorViewInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_info")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_info", status: .staleHandle)
            }
            return NativeEditorViewInfo(
                virtualLineCount: entry.view.getVirtualLineCount(),
                totalVirtualLineCount: entry.view.getTotalVirtualLineCount(),
                selection: entry.view.getSelection(),
                selectionOccupancy: entry.view.getSelectionOccupancy()
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetSelection [status=implemented hash=6601fc5a32fa]
    public func contextEditorViewGetSelection(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle
    ) throws -> TextSelectionRange? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_selection")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_selection", status: .staleHandle)
            }
            return entry.view.getSelection()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetSelectedText [status=implemented hash=6fc05d124310]
    public func contextEditorViewGetSelectedText(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_selected_text")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_selected_text", status: .staleHandle)
            }
            return entry.view.getSelectedText()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetPosition [status=implemented hash=011e6b266f1a]
    public func contextEditorViewGetPosition(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        query: NativeEditorPositionQuery
    ) throws -> VisualCursor {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_position")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_position", status: .staleHandle)
            }
            switch query {
            case .cursor: return entry.view.getVisualCursor()
            case .nextWord: return entry.view.getNextWordBoundary()
            case .prevWord: return entry.view.getPrevWordBoundary()
            case .eol: return entry.view.getEOL()
            case .visualSol: return entry.view.getVisualSOL()
            case .visualEol: return entry.view.getVisualEOL()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewGetLines [status=implemented hash=b4b8d86e1ca4]
    public func contextEditorViewGetLines(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        logical: Bool = false
    ) throws -> LineInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_get_lines")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_get_lines", status: .staleHandle)
            }
            return logical ? entry.view.getLogicalLineInfo() : entry.view.getLineInfo()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewMeasure [status=implemented hash=49d7cf3205a0]
    public func contextEditorViewMeasure(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        width: Int,
        height: Int
    ) throws -> MeasureResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_measure")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_measure", status: .staleHandle)
            }
            return entry.view.measureForDimensions(width: width, height: height)
                ?? MeasureResult(lineCount: 0, widthColsMax: 0)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.contextEditorViewSetPlaceholder [status=implemented hash=abd2a42e7edc]
    public func contextEditorViewSetPlaceholder(
        _ context: NativeContextHandle,
        view: ContextEditorViewHandle,
        chunks: [TextChunk]
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_editor_view_set_placeholder")
            guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                throw NativeError(operation: "ot_editor_view_set_placeholder", status: .staleHandle)
            }
            entry.view.setPlaceholderStyledText(chunks)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.onContextEditEvent [status=implemented hash=961e0dc04819]
    public func onContextEditEvent(
        _ context: NativeContextHandle,
        listener: @escaping @Sendable (ContextEditBufferHandle, NativeEditEvent) -> Void
    ) throws -> @Sendable () -> Void {
        let token: UInt64 = try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_edit_event_subscribe")
            let id = ctx.nextEditListenerId
            ctx.nextEditListenerId &+= 1
            ctx.editEventListeners[id] = listener
            return id
        }
        return { [weak self] in
            self?.lock.withLock { store in
                _ = store.contexts[context.contextId]?.editEventListeners.removeValue(forKey: token)
            }
        }
    }
}

// MARK: - Scene & Video (62 methods)

extension SwiftRenderLib {
    private func requireSceneNode(
        _ ctx: ContextState,
        _ node: SceneNodeHandle,
        op: String
    ) throws -> (scene: NativeScene, node: NativeSceneNode, kind: UInt32, hooks: UInt32, hookGen: UInt64) {
        guard let entry = ctx.sceneNodes[node.slot], entry.generation == node.generation else {
            throw NativeError(operation: op, status: .staleHandle)
        }
        return (ctx.ensureScene(), entry.node, entry.kind, entry.hooks, entry.hookGen)
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneCreateNode [status=implemented hash=dbf4032e83d9]
    public func sceneCreateNode(
        _ context: NativeContextHandle,
        kind: UInt32 = UInt32(NativeABI.OT_SCENE_BOX),
        num: UInt32 = 0
    ) throws -> SceneNodeHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_create_node")
            let scene = ctx.ensureScene()
            let node = try scene.createStandaloneNode(num: num == 0 ? nil : num)
            let h = node.handle
            ctx.sceneNodes[h.slot] = (h.generation, node, kind, 0, 0)
            return h
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneDestroyNode [status=implemented hash=3cfb98024494]
    public func sceneDestroyNode(_ context: NativeContextHandle, node: SceneNodeHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_destroy_node")
            guard let entry = ctx.sceneNodes.removeValue(forKey: node.slot), entry.generation == node.generation else {
                throw NativeError(operation: "ot_scene_destroy_node", status: .staleHandle)
            }
            _ = ctx.videos.removeValue(forKey: node.slot)
            try? ctx.ensureScene().destroyNode(handle: node)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetMeasure [status=implemented hash=acc11cf2e5aa]
    public func sceneSetMeasure(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        measure: FlexMeasureFunc?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_measure")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_measure")
            try scene.setMeasureFunc(sceneNode, measure: measure)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneHasMeasure [status=implemented hash=67a31c5e6899]
    public func sceneHasMeasure(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_has_measure")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_has_measure")
            return try scene.hasMeasureFunc(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneReachesHooks [status=implemented hash=08842f17ba91]
    public func sceneReachesHooks(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_reaches_hooks")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_reaches_hooks")
            return try scene.reachesHooks(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.scenePainted [status=implemented hash=14d3e600e908]
    public func scenePainted(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_painted")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_painted")
            return try scene.painted(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneMarkDirty [status=implemented hash=601a6b4abd79]
    public func sceneMarkDirty(_ context: NativeContextHandle, node: SceneNodeHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_mark_dirty")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_mark_dirty")
            try scene.markDirty(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneMoveNode [status=implemented hash=0d408a3eba9d]
    public func sceneMoveNode(
        _ context: NativeContextHandle,
        child: SceneNodeHandle,
        parent: SceneNodeHandle?,
        index: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_move_node")
            let (scene, _, _, _, _) = try requireSceneNode(ctx, child, op: "ot_scene_move_node")
            try scene.moveNode(handle: child, parent: parent, index: index)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetViewport [status=implemented hash=4887bb4437f0]
    public func sceneSetViewport(
        _ context: NativeContextHandle,
        content: SceneNodeHandle,
        viewport: SceneNodeHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_viewport")
            let (scene, contentNode, _, _, _) = try requireSceneNode(ctx, content, op: "ot_scene_set_viewport")
            let vpNode: NativeSceneNode?
            if let viewport {
                vpNode = try requireSceneNode(ctx, viewport, op: "ot_scene_set_viewport").node
            } else {
                vpNode = nil
            }
            try scene.setViewport(contentNode, viewport: vpNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetFocus [status=implemented hash=d09cabde947c]
    public func sceneSetFocus(_ context: NativeContextHandle, node: SceneNodeHandle, focused: Bool) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_focus")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_focus")
            try scene.setFocus(sceneNode, focused: focused)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetStyle [status=implemented hash=64fecf523f07]
    public func sceneGetStyle(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        group: NativeStyleGroup,
        kind: Int32,
        edge: Int32 = 0
    ) throws -> YogaValue {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_style")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_style")
            let yGroup = YogaStyleGroup(rawValue: Int32(group.rawValue)) ?? .value
            return try scene.getStyle(node: sceneNode, group: yGroup, kind: kind, edge: edge)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetBoxDetails [status=implemented hash=eda9ed3caca4]
    public func sceneSetBoxDetails(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        details: NativeSceneBoxDetails
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_box_details")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_box_details")
            try scene.setBoxDetails(sceneNode, details: details)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetSurface [status=implemented hash=e401134b470a]
    public func sceneSetSurface(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        buffer: ContextBufferHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_surface")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_surface")
            let optBuf: OptimizedBuffer?
            if let buffer {
                guard let entry = ctx.buffers[buffer.slot], entry.generation == buffer.generation else {
                    throw NativeError(operation: "ot_scene_set_surface", status: .staleHandle)
                }
                optBuf = entry.buffer
            } else {
                optBuf = nil
            }
            try scene.setSurface(sceneNode, buffer: optBuf)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFlush [status=implemented hash=315f7556fd1d]
    @discardableResult
    public func sceneFlush(_ context: NativeContextHandle, staging: SceneStaging) throws -> Int {
        try staging.consume(context) { batch in
            try lock.withLock { store in
                let ctx = try requireContext(store, context, op: "ot_scene_flush")
                var applied = 0
                for mutation in batch {
                    switch mutation {
                    case .style(let node, let group, let kind, let edge, let unit, let value, let flags):
                        let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_flush")
                        let yGroup = YogaStyleGroup(rawValue: Int32(group)) ?? .value
                        let yUnit = Unit(rawValue: Int32(unit)) ?? .point
                        let yFlags = YogaStyleFlags(rawValue: Int32(flags))
                        try scene.setStyle(
                            node: sceneNode,
                            group: yGroup,
                            kind: Int32(kind),
                            edge: Int32(edge),
                            unit: yUnit,
                            value: value,
                            flags: yFlags
                        )
                        applied += 1
                    case .background(let node, let color):
                        let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_flush")
                        try scene.setBackground(sceneNode, color: color)
                        applied += 1
                    case .paint(let node, let update):
                        let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_flush")
                        try scene.setPaint(sceneNode, update)
                        applied += 1
                    }
                }
                return applied
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetText [status=implemented hash=9421cf69cede]
    public func sceneSetText(_ context: NativeContextHandle, node: SceneNodeHandle, text: String) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_text")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_text")
            try scene.setText(sceneNode, text)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetStyledText [status=implemented hash=6ba63a2ad06b]
    public func sceneSetStyledText(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        styledText: StyledText
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_styled_text")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_styled_text")
            try scene.setText(sceneNode, styledText)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetTextByteAt [status=implemented hash=ba8d024ebce0]
    public func sceneGetTextByteAt(_ context: NativeContextHandle, node: SceneNodeHandle, x: Int, y: Int) throws -> Int? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_text_byte_at")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_text_byte_at")
            return try scene.textByteAt(sceneNode, x: x, y: y)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetTextView [status=implemented hash=7876a37f3d95]
    public func sceneSetTextView(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        view: ContextTextBufferViewHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_text_view")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_text_view")
            let resolved: TextBufferView?
            if let view {
                guard let entry = ctx.textBufferViews[view.slot], entry.generation == view.generation else {
                    throw NativeError(operation: "ot_scene_set_text_view", status: .staleHandle)
                }
                resolved = entry.view
            } else {
                resolved = nil
            }
            try scene.setTextView(sceneNode, view: resolved)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetTextViewPaint [status=implemented hash=ca5c611f551a]
    public func sceneSetTextViewPaint(_ context: NativeContextHandle, node: SceneNodeHandle, enabled: Bool) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_text_view_paint")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_text_view_paint")
            try scene.setTextViewPaint(sceneNode, enabled: enabled)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetEditorView [status=implemented hash=69b0a6adf3cd]
    public func sceneSetEditorView(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        view: ContextEditorViewHandle?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_editor_view")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_editor_view")
            let resolved: EditorView?
            if let view {
                guard let entry = ctx.editorViews[view.slot], entry.generation == view.generation else {
                    throw NativeError(operation: "ot_scene_set_editor_view", status: .staleHandle)
                }
                resolved = entry.view
            } else {
                resolved = nil
            }
            try scene.setEditorView(sceneNode, view: resolved)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetEditorOptions [status=implemented hash=03b2b0187b65]
    public func sceneSetEditorOptions(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneEditorOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_editor_options")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_editor_options")
            try scene.setEditorOptions(sceneNode, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetImage [status=implemented hash=f158ce9e6760]
    public func sceneSetImage(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        image: ContextImageHandle?,
        fit: ImageFit = .fit,
        imageProtocol: ImageRenderProtocol = .auto,
        buffer: ContextBufferHandle? = nil
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_image")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_image")
            var pixelImage: PixelImage? = nil
            if let image {
                guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                    throw NativeError(operation: "ot_scene_set_image", status: .staleHandle)
                }
                if let raw = try? entry.image.raw(format: .rgba8) {
                    pixelImage = try? PixelImage(width: raw.width, height: raw.height, pixels: raw.data)
                }
            }
            let optBuf = buffer.flatMap { ctx.buffers[$0.slot]?.buffer }
            try scene.setImage(sceneNode, image: pixelImage, fit: fit, protocol: imageProtocol, buffer: optBuf)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetVideo [status=implemented hash=2bcb5e921e4a]
    public func sceneSetVideo(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        fit: ImageFit = .fit,
        buffer: ContextBufferHandle? = nil
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_video")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_video")
            let optBuf = buffer.flatMap { ctx.buffers[$0.slot]?.buffer }
            try scene.setVideo(sceneNode, fit: fit, buffer: optBuf)
            if ctx.videos[node.slot] == nil {
                ctx.videos[node.slot] = VideoNodeState()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetCrop [status=implemented hash=02d5719472bc]
    public func sceneSetCrop(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        crop: ImageExtractOptions?
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_crop")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_crop")
            try scene.setCrop(sceneNode, crop: crop)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetSlider [status=implemented hash=86151bc2f835]
    public func sceneSetSlider(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneSliderOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_slider")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_slider")
            try scene.setSlider(sceneNode, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetSliderThumb [status=implemented hash=12011e6cdbbb]
    public func sceneGetSliderThumb(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> SliderThumb {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_slider_thumb")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_slider_thumb")
            return try scene.getSliderThumb(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetArrow [status=implemented hash=2691df717e95]
    public func sceneSetArrow(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneArrowOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_arrow")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_arrow")
            try scene.setArrow(sceneNode, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetScroll [status=implemented hash=c1d0e5103408]
    public func sceneSetScroll(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneScrollOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_scroll")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_scroll")
            try scene.setScroll(sceneNode, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetScrollArrow [status=implemented hash=8be672ca5753]
    public func sceneSetScrollArrow(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        axis: Int,
        end: Int,
        options: NativeSceneArrowOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_scroll_arrow")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_scroll_arrow")
            try scene.setScrollArrow(sceneNode, axis: axis, end: end, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneScrollTo [status=implemented hash=7d667b5c10ca]
    public func sceneScrollTo(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        x: Double,
        y: Double,
        relativeX: Bool = false,
        relativeY: Bool = false,
        reapply: Bool = false
    ) throws -> NativeSceneScrollState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_scroll_to")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_scroll_to")
            return try scene.scrollTo(sceneNode, x: x, y: y, relativeX: relativeX, relativeY: relativeY, reapply: reapply)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneScrollRequest [status=implemented hash=9f4b72911149]
    public func sceneScrollRequest(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        kind: NativeSceneScrollRequestKind,
        target: SceneNodeHandle? = nil,
        align: NativeSceneScrollAlign = .nearest,
        inset: Double = 0
    ) throws -> NativeSceneScrollState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_scroll_request")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_scroll_request")
            let targetNode = target.flatMap { ctx.sceneNodes[$0.slot]?.node }
            return try scene.scrollRequest(sceneNode, kind: kind, target: targetNode, align: align, inset: inset)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetScroll [status=implemented hash=d63a596a951b]
    public func sceneGetScroll(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> NativeSceneScrollState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_scroll")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_scroll")
            return try scene.getScroll(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetTextOptions [status=implemented hash=d6fd37712961]
    public func sceneSetTextOptions(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneTextOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_text_options")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_text_options")
            try scene.setTextOptions(sceneNode, options: options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetTextSelection [status=implemented hash=3a95c0afddb9]
    @discardableResult
    public func sceneSetTextSelection(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        options: NativeSceneTextSelectionOptions
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_text_selection")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_text_selection")
            let bounds = LocalSelectionBounds(
                anchorX: options.anchorX,
                anchorY: options.anchorY,
                focusX: options.focusX,
                focusY: options.focusY,
                isActive: options.operation != .reset
            )
            return try scene.setTextSelection(sceneNode, operation: options.operation, bounds: bounds, bg: options.bg, fg: options.fg)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetTextSelection [status=implemented hash=4785e005c058]
    public func sceneGetTextSelection(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> TextSelectionRange? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_text_selection")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_text_selection")
            return try scene.getTextSelection(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetSelectedText [status=implemented hash=3c62554b67f0]
    public func sceneGetSelectedText(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_selected_text")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_selected_text")
            return try scene.getSelectedText(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetTextMetrics [status=implemented hash=2aede12a7c2c]
    public func sceneGetTextMetrics(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> NativeSceneTextMetrics {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_text_info")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_text_info")
            return try scene.getTextMetrics(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetText [status=implemented hash=2e172fc6fac6]
    public func sceneGetText(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_text")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_text")
            return try scene.getText(sceneNode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetTextLineInfo [status=implemented hash=311771a5d181]
    public func sceneGetTextLineInfo(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        firstLine: Int = 0,
        lineCount: Int? = nil
    ) throws -> LineInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_text_lines")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_text_lines")
            return try scene.getTextLineInfo(sceneNode, firstLine: firstLine, lineCount: lineCount)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetLayout [status=implemented hash=7cf5bfce90f9]
    public func sceneGetLayout(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        kind: NativeSceneLayoutKind = .computed
    ) throws -> NativeSceneLayout {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_layout")
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_get_layout")
            return try scene.getLayout(sceneNode, kind: kind)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneMeasureLayout [status=implemented hash=95560df0e109]
    public func sceneMeasureLayout(
        _ context: NativeContextHandle,
        root: SceneNodeHandle,
        availableWidth: Float? = nil
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_measure_layout")
            let (scene, rootNode, _, _, _) = try requireSceneNode(ctx, root, op: "ot_scene_measure_layout")
            return try scene.measureSnapshot(rootNode, availableWidth: availableWidth)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameCopyBuffer [status=implemented hash=e5b0e5995728]
    public func sceneFrameCopyBuffer(
        _ context: NativeContextHandle,
        frame: NativeSceneFrameRequest,
        destination: ContextBufferHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_copy_buffer")
            guard let rec = ctx.activeFrames[frame.frameId], !rec.cancelled else {
                throw NativeError(operation: "ot_scene_frame_copy_buffer", status: .staleFrame)
            }
            guard let dst = ctx.buffers[destination.slot], dst.generation == destination.generation else {
                throw NativeError(operation: "ot_scene_frame_copy_buffer", status: .staleHandle)
            }
            try dst.buffer.copyFrom(rec.buffer)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetHooks [status=implemented hash=bbc5dcd416bf]
    public func sceneSetHooks(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        flags: UInt32,
        generation: UInt64 = 1,
        initialWidth: Int = 0,
        initialHeight: Int = 0
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_hooks")
            let (scene, sceneNode, kind, _, _) = try requireSceneNode(ctx, node, op: "ot_scene_set_hooks")
            try scene.setHooks(sceneNode, flags: flags, generation: generation, initialWidth: initialWidth, initialHeight: initialHeight)
            ctx.sceneNodes[node.slot] = (node.generation, sceneNode, kind, flags, generation)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameStep [status=implemented hash=87ac9c977627]
    public func sceneFrameStep(
        _ context: NativeContextHandle,
        session: SessionHandle,
        root: SceneNodeHandle,
        options: NativeSceneFrameOptions = NativeSceneFrameOptions(),
        previous: NativeSceneFrameRequest? = nil
    ) throws -> NativeSceneFrameRequest {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_step")
            guard let sessEntry = ctx.sessions[session.slot], sessEntry.generation == session.generation else {
                throw NativeError(operation: "ot_scene_frame_step", status: .staleHandle)
            }
            let width = max(1, sessEntry.session.rendererState.width)
            let height = max(1, sessEntry.session.rendererState.height)
            let scene = ctx.ensureScene()
            try scene.computeLayout(width: width, height: height)

            let record: ActiveFrameRecord
            if let prev = previous, let existing = ctx.activeFrames[prev.frameId] {
                record = existing
                record.phase = .done
            } else {
                let fid = ctx.nextFrameId
                ctx.nextFrameId &+= 1
                record = ActiveFrameRecord(frameId: fid, session: session, root: root, options: options, width: width, height: height)
                try scene.render(into: record.buffer, options: NativeScenePaintOptions(background: options.background), performLayout: false)
                record.paintSlots = ctx.sceneNodes.values.compactMap { entry in
                    guard entry.hooks != 0 else { return nil }
                    let layout = (try? scene.getLayout(entry.node, kind: .paint)) ?? .zero
                    return NativeScenePaintSlot(node: entry.node.handle, num: entry.node.num, hooks: entry.hooks, opacity: 1.0, paintLayout: layout)
                }
                record.phase = record.paintSlots.isEmpty ? .done : .record
                ctx.activeFrames[fid] = record
            }

            let reqId = record.requestSeq
            record.requestSeq &+= 1
            return NativeSceneFrameRequest(
                session: session,
                root: root,
                node: root,
                frameId: record.frameId,
                requestId: reqId,
                layoutEpoch: 1,
                hookGeneration: 1,
                kind: record.phase,
                num: 0,
                width: width,
                height: height
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.releaseAfterPaint [status=adapted hash=17eebbcbf6ac]
    public func releaseAfterPaint(_ cleanup: @escaping @Sendable () -> Void) {
        cleanup()
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameGetPaintSlots [status=implemented hash=36987b078032]
    public func sceneFrameGetPaintSlots(
        _ context: NativeContextHandle,
        frame: NativeSceneFrameRequest
    ) throws -> [NativeScenePaintSlot] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_get_paint_slots")
            guard let rec = ctx.activeFrames[frame.frameId], !rec.cancelled else {
                throw NativeError(operation: "ot_scene_frame_get_paint_slots", status: .staleFrame)
            }
            return rec.paintSlots
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameAcquireBufferLease [status=adapted hash=06e58c59de26]
    public func sceneFrameAcquireBufferLease(
        _ context: NativeContextHandle,
        frame: NativeSceneFrameRequest
    ) throws -> NativeSessionBufferLease {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_acquire_buffer_lease")
            guard let rec = ctx.activeFrames[frame.frameId], !rec.cancelled else {
                throw NativeError(operation: "ot_scene_frame_acquire_buffer_lease", status: .staleFrame)
            }
            let gen = ctx.nextLeaseGen
            ctx.nextLeaseGen &+= 1
            let leaseRec = BufferLeaseRecord(handle: frame.session.objectHandle, generation: gen)
            ctx.bufferLeases[gen] = leaseRec
            return NativeSessionBufferLease(
                handle: frame.session.objectHandle,
                width: rec.buffer.width,
                height: rec.buffer.height,
                generation: gen
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameCommit [status=implemented hash=aa177f6459ae]
    public func sceneFrameCommit(
        _ context: NativeContextHandle,
        frame: NativeSceneFrameRequest,
        force: Bool = false
    ) throws -> NativeSessionRenderStatus {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_commit")
            guard let rec = ctx.activeFrames.removeValue(forKey: frame.frameId), !rec.cancelled else {
                throw NativeError(operation: "ot_scene_frame_commit", status: .staleFrame)
            }
            rec.committed = true
            ctx.sceneStats.nativeFrameCount &+= 1
            ctx.sceneStats.frameWork.workFrameId = frame.frameId
            if let sessEntry = ctx.sessions[frame.session.slot] {
                return try sessEntry.session.render(force: force, frame: frame)
            }
            return .presented
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneFrameCancel [status=implemented hash=a77cd58bf7e4]
    public func sceneFrameCancel(_ context: NativeContextHandle, frame: NativeSceneFrameRequest) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_frame_cancel")
            if let rec = ctx.activeFrames.removeValue(forKey: frame.frameId) {
                rec.cancelled = true
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneHitTest [status=implemented hash=1853677b8254]
    public func sceneHitTest(
        _ context: NativeContextHandle,
        root: SceneNodeHandle,
        x: Int,
        y: Int,
        excludingNum: UInt32? = nil
    ) throws -> UInt32 {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_hit_test")
            let (scene, _, _, _, _) = try requireSceneNode(ctx, root, op: "ot_scene_hit_test")
            for entry in ctx.sceneNodes.values.reversed() {
                if let excl = excludingNum, entry.node.num == excl { continue }
                let layout = (try? scene.getLayout(entry.node, kind: .paint)) ?? .zero
                let rx = layout.screenX
                let ry = layout.screenY
                let rw = Int(layout.width)
                let rh = Int(layout.height)
                if x >= rx && x < rx + rw && y >= ry && y < ry + rh {
                    return entry.node.num
                }
            }
            return 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneSetDebugFlags [status=implemented hash=31d234c71215]
    public func sceneSetDebugFlags(_ context: NativeContextHandle, flags: UInt32) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_set_debug_flags")
            ctx.debugFlags = flags
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetStats [status=implemented hash=9231793198ae]
    public func sceneGetStats(_ context: NativeContextHandle) throws -> OpenTUICore.NativeRenderStats {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_stats")
            return ctx.sceneStats
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sceneGetCursorState [status=implemented hash=c1532e89333c]
    public func sceneGetCursorState(_ context: NativeContextHandle) throws -> CursorState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_scene_get_cursor_state")
            return ctx.sceneCursor
        }
    }

    // MARK: - Video (10 methods)

    // parity: core/src/zig.ts#FFIRenderLib.videoOpen [status=implemented hash=38e3d2d8ff92]
    public func videoOpen(
        _ context: NativeContextHandle,
        node: SceneNodeHandle,
        path: String
    ) throws -> NativeVideoInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_open")
            _ = try requireSceneNode(ctx, node, op: "ot_video_open")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.path = path
            v.info = NativeVideoInfo(durationUs: 0, width: 0, height: 0, fpsNum: 30, fpsDen: 1, hasAudio: false)
            v.state = NativeVideoState()
            v.lastError = ""
            ctx.videos[node.slot] = v
            return v.info
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoCall [status=implemented hash=4f878d7aeecd]
    public func videoCall(_ context: NativeContextHandle, node: SceneNodeHandle, command: String) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_call")
            _ = try requireSceneNode(ctx, node, op: "ot_video_call")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            switch command {
            case "play":
                v.state.playing = true
                v.state.ended = false
            case "pause":
                v.state.playing = false
            case "stop", "close":
                v.state.playing = false
                v.state.currentTimeUs = 0
            default:
                break
            }
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSeek [status=implemented hash=0a7a0e49f0c6]
    public func videoSeek(_ context: NativeContextHandle, node: SceneNodeHandle, timeUs: UInt64) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_seek")
            _ = try requireSceneNode(ctx, node, op: "ot_video_seek")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.state.currentTimeUs = timeUs
            v.state.framePtsUs = timeUs
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSetLoop [status=implemented hash=1afb58fb80d1]
    public func videoSetLoop(_ context: NativeContextHandle, node: SceneNodeHandle, loop: Bool) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_set_loop")
            _ = try requireSceneNode(ctx, node, op: "ot_video_set_loop")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.loop = loop
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSetMuted [status=implemented hash=f1da26b493e6]
    public func videoSetMuted(_ context: NativeContextHandle, node: SceneNodeHandle, muted: Bool) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_set_muted")
            _ = try requireSceneNode(ctx, node, op: "ot_video_set_muted")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.muted = muted
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSetVolume [status=implemented hash=181a8c5adaaf]
    public func videoSetVolume(_ context: NativeContextHandle, node: SceneNodeHandle, volume: Float) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_set_volume")
            _ = try requireSceneNode(ctx, node, op: "ot_video_set_volume")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.volume = max(0, min(1, volume))
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSetAvSyncOffset [status=implemented hash=430088207ae4]
    public func videoSetAvSyncOffset(_ context: NativeContextHandle, node: SceneNodeHandle, offsetUs: Int64) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_set_av_sync_offset")
            _ = try requireSceneNode(ctx, node, op: "ot_video_set_av_sync_offset")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.avSyncOffsetUs = offsetUs
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoSetMaxFps [status=implemented hash=0ee59abc767b]
    public func videoSetMaxFps(_ context: NativeContextHandle, node: SceneNodeHandle, maxFps: Float) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_set_max_fps")
            _ = try requireSceneNode(ctx, node, op: "ot_video_set_max_fps")
            let v = ctx.videos[node.slot] ?? VideoNodeState()
            v.maxFps = max(1, maxFps)
            ctx.videos[node.slot] = v
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoGetState [status=implemented hash=0102a319dff2]
    public func videoGetState(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> NativeVideoState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_get_state")
            _ = try requireSceneNode(ctx, node, op: "ot_video_get_state")
            return ctx.videos[node.slot]?.state ?? NativeVideoState()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.videoGetError [status=implemented hash=5b272f25b274]
    public func videoGetError(_ context: NativeContextHandle, node: SceneNodeHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_video_get_error")
            _ = try requireSceneNode(ctx, node, op: "ot_video_get_error")
            return ctx.videos[node.slot]?.lastError ?? ""
        }
    }
}

// MARK: - Session & Terminal Lifecycle (47 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.createSession [status=implemented hash=6e8e72b6e801]
    public func createSession(
        _ context: NativeContextHandle,
        options: NativeSessionOptions = NativeSessionOptions()
    ) throws -> SessionHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_create")
            let sink = MemorySessionOutputSink()
            let driverOpts = NativeSessionDriverOptions(outputBufferSize: max(1024, options.outputBufferSize))
            let session = try NativeSession(sink: sink, options: driverOpts, runtime: ctx.runtime)
            let h = ctx.allocateHandle()
            let handle = SessionHandle(contextId: h.contextId, slot: h.slot, generation: h.generation)
            ctx.sessions[h.slot] = (
                h.generation,
                session,
                sink,
                StdinParser(),
                max(1024, Int(options.outputBufferSize)),
                0,
                [],
                [:],
                CursorState(),
                0
            )
            return handle
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroySession [status=implemented hash=87bc5b5092e9]
    public func destroySession(_ context: NativeContextHandle, session: SessionHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.sessions.removeValue(forKey: session.slot) {
                entry.session.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetWriteLimit [status=implemented hash=29db7a4f4125]
    public func sessionGetWriteLimit(_ context: NativeContextHandle, session: SessionHandle) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_write_limit")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_write_limit", status: .staleHandle)
            }
            return entry.writeLimit
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionWrite [status=implemented hash=9ba03c5bef8e]
    @discardableResult
    public func sessionWrite(_ context: NativeContextHandle, session: SessionHandle, bytes: [UInt8]) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_write")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_write", status: .staleHandle)
            }
            return try entry.session.write(bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionAttachRenderer [status=implemented hash=17684848a5d3]
    public func sessionAttachRenderer(
        _ context: NativeContextHandle,
        session: SessionHandle,
        options: NativeSessionRendererOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_attach_renderer")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_attach_renderer", status: .staleHandle)
            }
            try entry.session.attachRenderer(options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionResizeRenderer [status=implemented hash=eaf80b099ecb]
    public func sessionResizeRenderer(
        _ context: NativeContextHandle,
        session: SessionHandle,
        width: Int,
        height: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_resize_renderer")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_resize_renderer", status: .staleHandle)
            }
            try entry.session.resize(width: width, height: height)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetDebugOverlay [status=implemented hash=e8fde507237d]
    public func sessionSetDebugOverlay(
        _ context: NativeContextHandle,
        session: SessionHandle,
        enabled: Bool,
        corner: DebugOverlayCorner = .bottomRight
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_debug_overlay")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_debug_overlay", status: .staleHandle)
            }
            _ = (entry, enabled, corner)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionUpdateStats [status=implemented hash=93d74236cd4c]
    public func sessionUpdateStats(
        _ context: NativeContextHandle,
        session: SessionHandle,
        fps: Double,
        frameCount: UInt64,
        lastFrameTimeMs: Double
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_update_stats")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_update_stats", status: .staleHandle)
            }
            _ = (entry, fps)
            ctx.sceneStats.nativeFrameCount = frameCount
            ctx.sceneStats.nativeLastFrameTime = lastFrameTimeMs
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionUpdateMemoryStats [status=implemented hash=cb67da8f510e]
    public func sessionUpdateMemoryStats(
        _ context: NativeContextHandle,
        session: SessionHandle,
        heapUsed: UInt64,
        heapTotal: UInt64,
        arrayBuffers: UInt64
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_update_memory_stats")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_update_memory_stats", status: .staleHandle)
            }
            _ = (entry, heapUsed, heapTotal, arrayBuffers)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionDumpHitGrid [status=implemented hash=3e16677c0065]
    public func sessionDumpHitGrid(_ context: NativeContextHandle, session: SessionHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_dump_hit_grid")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_dump_hit_grid", status: .staleHandle)
            }
            return "hit-grid(\(entry.session.rendererState.width)x\(entry.session.rendererState.height))"
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetRendererState [status=implemented hash=0bbb65f710c7]
    public func sessionGetRendererState(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> NativeSessionRendererState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_renderer_state")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_renderer_state", status: .staleHandle)
            }
            return entry.session.rendererState
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionAcquireBufferLease [status=adapted hash=564b67794eec]
    public func sessionAcquireBufferLease(
        _ context: NativeContextHandle,
        session: SessionHandle,
        slot: NativeSessionBufferSlot = .next
    ) throws -> NativeSessionBufferLease {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_acquire_buffer_lease")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_acquire_buffer_lease", status: .staleHandle)
            }
            _ = slot
            let gen = ctx.nextLeaseGen
            ctx.nextLeaseGen &+= 1
            let rec = BufferLeaseRecord(handle: session.objectHandle, generation: gen)
            ctx.bufferLeases[gen] = rec
            return NativeSessionBufferLease(
                handle: session.objectHandle,
                width: max(1, entry.session.rendererState.width),
                height: max(1, entry.session.rendererState.height),
                generation: gen
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetLinkId [status=implemented hash=bcbe5f917057]
    public func sessionGetLinkId(
        _ context: NativeContextHandle,
        session: SessionHandle,
        url: String
    ) throws -> UInt32 {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_link_id")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_link_id", status: .staleHandle)
            }
            _ = entry
            let id = try ctx.resourceContext.linkPool.acquire(url)
            return id
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetupTerminal [status=implemented hash=8580fe6bd19e]
    public func sessionSetupTerminal(
        _ context: NativeContextHandle,
        session: SessionHandle,
        options: NativeSessionTerminalOptions = NativeSessionTerminalOptions()
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_setup_terminal")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_setup_terminal", status: .staleHandle)
            }
            try entry.session.setupTerminal(options)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSuspend [status=implemented hash=37cbb866b4af]
    public func sessionSuspend(_ context: NativeContextHandle, session: SessionHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_suspend")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_suspend", status: .staleHandle)
            }
            try entry.session.suspend()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionResume [status=implemented hash=750a0b852f92]
    public func sessionResume(_ context: NativeContextHandle, session: SessionHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_resume")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_resume", status: .staleHandle)
            }
            try entry.session.resume()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetTerminalState [status=implemented hash=2a8fe3f0bafb]
    public func sessionGetTerminalState(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> NativeSessionTerminalPhase {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_terminal_state")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_terminal_state", status: .staleHandle)
            }
            return entry.session.terminalPhase
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionPump [status=implemented hash=bef5ea53ed0a]
    public func sessionPump(_ context: NativeContextHandle, session: SessionHandle) throws -> NativeSessionPumpResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_pump")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_pump", status: .staleHandle)
            }
            if entry.session.state == .closed || entry.session.state == .cancelled {
                return NativeSessionPumpResult(status: .closed)
            }
            _ = entry.session.flushOutput()
            return NativeSessionPumpResult(status: .idle)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionPumpExit [status=implemented hash=a3c0075bbf83]
    public func sessionPumpExit(_ context: NativeContextHandle, session: SessionHandle) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_pump_exit")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_pump_exit", status: .staleHandle)
            }
            return entry.session.restoreOnExit()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionInputFeed [status=implemented hash=ffd847d54573]
    public func sessionInputFeed(
        _ context: NativeContextHandle,
        session: SessionHandle,
        bytes: [UInt8]
    ) throws -> NativeInputDrain {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_input_feed")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_input_feed", status: .staleHandle)
            }
            let events = entry.session.feedInput(bytes)
            return NativeInputDrain(consumed: bytes.count, count: events.count, deadlineNs: nil)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionInputExpect [status=implemented hash=31fecaaf21b6]
    public func sessionInputExpect(
        _ context: NativeContextHandle,
        session: SessionHandle,
        flags: UInt32
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_input_expect")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_input_expect", status: .staleHandle)
            }
            entry.inputExpectFlags = flags
            ctx.sessions[session.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionInputReset [status=implemented hash=abdbcd8f79b5]
    public func sessionInputReset(
        _ context: NativeContextHandle,
        session: SessionHandle,
        flags: UInt32 = 0
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_input_reset")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_input_reset", status: .staleHandle)
            }
            if flags == 0 { entry.inputExpectFlags = 0 }
            entry.parser.reset()
            ctx.sessions[session.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.terminalFlushInput [status=adapted hash=292b9ca1b3eb]
    public func terminalFlushInput() -> Bool {
        true
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionControl [status=implemented hash=84c7f95910e0]
    public func sessionControl(
        _ context: NativeContextHandle,
        session: SessionHandle,
        command: NativeSessionControl
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_control")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_control", status: .staleHandle)
            }
            try entry.session.control(command)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionClipboard [status=implemented hash=f0cad37325c8]
    @discardableResult
    public func sessionClipboard(
        _ context: NativeContextHandle,
        session: SessionHandle,
        target: ClipboardTarget = .clipboard,
        bytes: [UInt8]
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_clipboard")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_clipboard", status: .staleHandle)
            }
            return try entry.session.writeClipboard(target: target, bytes: bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionNotification [status=implemented hash=cf4b44cb1ceb]
    @discardableResult
    public func sessionNotification(
        _ context: NativeContextHandle,
        session: SessionHandle,
        message: String,
        title: String? = nil
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_notification")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_notification", status: .staleHandle)
            }
            return try entry.session.triggerNotification(message: message, title: title)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetPaletteState [status=implemented hash=62300c1652ed]
    public func sessionSetPaletteState(
        _ context: NativeContextHandle,
        session: SessionHandle,
        palette: NormalizedTerminalPalette
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_palette_state")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_palette_state", status: .staleHandle)
            }
            entry.session.setPalette(palette)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetCursor [status=implemented hash=67c9da1684a8]
    public func sessionSetCursor(
        _ context: NativeContextHandle,
        session: SessionHandle,
        options: NativeSessionCursorOptions
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_cursor")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_cursor", status: .staleHandle)
            }
            if let x = options.x { entry.cursor.x = x }
            if let y = options.y { entry.cursor.y = y }
            if let visible = options.visible { entry.cursor.visible = visible }
            if let style = options.style { entry.cursor.style = style }
            if let blinking = options.blinking { entry.cursor.blinking = blinking }
            if let color = options.color { entry.cursor.color = color }
            ctx.sessions[session.slot] = entry
            ctx.sceneCursor = entry.cursor
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetCapabilities [status=implemented hash=bd9fdbe597d8]
    public func sessionGetCapabilities(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> NativeSessionCapabilities {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_capabilities")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_capabilities", status: .staleHandle)
            }
            return try entry.session.getCapabilities()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionReadOutput [status=implemented hash=c7cacb3b024c]
    public func sessionReadOutput(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> (ticket: NativeOutputTicket, bytes: [UInt8])? {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_read_output")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_read_output", status: .staleHandle)
            }
            _ = entry.session.flushOutput()
            let bytes = entry.sink.allBytes
            guard !bytes.isEmpty else { return nil }
            entry.sink.clear()
            let reqId = ctx.nextOutputTicketId
            ctx.nextOutputTicketId &+= 1
            entry.pendingTickets[reqId] = bytes.count
            ctx.sessions[session.slot] = entry
            return (NativeOutputTicket(session: session, requestId: reqId, byteCount: bytes.count), bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionDrainStdout [status=implemented hash=21ffd35036d7]
    public func sessionDrainStdout(_ context: NativeContextHandle, session: SessionHandle) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_drain_stdout")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_drain_stdout", status: .staleHandle)
            }
            let flat = entry.stdoutQueue.flatMap { $0 }
            entry.stdoutQueue.removeAll(keepingCapacity: true)
            ctx.sessions[session.slot] = entry
            return flat
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionPostStdout [status=implemented hash=f80bb644c3d3]
    public func sessionPostStdout(
        _ context: NativeContextHandle,
        session: SessionHandle,
        bytes: [UInt8]
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_post_stdout")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_post_stdout", status: .staleHandle)
            }
            entry.stdoutQueue.append(bytes)
            ctx.sessions[session.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionCompleteOutput [status=implemented hash=ab22995ddda8]
    public func sessionCompleteOutput(
        _ context: NativeContextHandle,
        ticket: NativeOutputTicket,
        succeeded: Bool = true
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_complete_output")
            guard var entry = ctx.sessions[ticket.session.slot], entry.generation == ticket.session.generation else {
                throw NativeError(operation: "ot_session_complete_output", status: .staleHandle)
            }
            guard entry.pendingTickets.removeValue(forKey: ticket.requestId) != nil else {
                throw NativeError(operation: "ot_session_complete_output", status: .staleOutput)
            }
            ctx.sessions[ticket.session.slot] = entry
            if !succeeded {
                throw NativeError(operation: "ot_session_complete_output", status: .outputFailed)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionClose [status=implemented hash=36770eddc7d0]
    public func sessionClose(_ context: NativeContextHandle, session: SessionHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_close")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_close", status: .staleHandle)
            }
            try entry.session.closeSync()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionDropOutput [status=implemented hash=97ffe7d76c31]
    public func sessionDropOutput(_ context: NativeContextHandle, session: SessionHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_drop_output")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_drop_output", status: .staleHandle)
            }
            entry.sink.clear()
            entry.pendingTickets.removeAll()
            ctx.sessions[session.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionCancel [status=implemented hash=ab30013b68bd]
    public func sessionCancel(_ context: NativeContextHandle, session: SessionHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_cancel")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_cancel", status: .staleHandle)
            }
            entry.session.dispose()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetState [status=implemented hash=0d37d03f945c]
    public func sessionGetState(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> NativeSessionState {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_state")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_state", status: .staleHandle)
            }
            return entry.session.state
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionRenderSplit [status=implemented hash=ae3f4d1acd2b]
    public func sessionRenderSplit(
        _ context: NativeContextHandle,
        session: SessionHandle,
        frame: NativeSceneFrameRequest?,
        commits: [NativeSplitSnapshot],
        pinnedRenderOffset: Int = 0,
        force: Bool = false
    ) throws -> NativeSessionRenderStatus {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_render_split")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_render_split", status: .staleHandle)
            }
            let res = try entry.session.renderSplit(
                frame: frame,
                commits: commits,
                pinnedRenderOffset: pinnedRenderOffset,
                force: force
            )
            return res.status
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSplitControl [status=implemented hash=7d3278c59fbd]
    public func sessionSplitControl(
        _ context: NativeContextHandle,
        session: SessionHandle,
        control: NativeSessionSplitControl
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_split_control")
            guard var entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_split_control", status: .staleHandle)
            }
            switch control {
            case .reset(_, let pinned): entry.splitPinnedOffset = pinned
            case .sync(let pinned): entry.splitPinnedOffset = pinned
            case .renderOffset(let off): entry.splitPinnedOffset = off
            case .outputOffset, .transition, .clearTransition: break
            }
            ctx.sessions[session.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetScreen [status=implemented hash=a0ecee424aad]
    public func sessionSetScreen(
        _ context: NativeContextHandle,
        session: SessionHandle,
        alternate: Bool,
        width: Int,
        height: Int,
        trailingOutput: [UInt8]? = nil
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_screen")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_screen", status: .staleHandle)
            }
            try entry.session.setScreen(alternate: alternate, width: width, height: height, trailingOutput: trailingOutput)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSyncDetached [status=implemented hash=d88cb7dbc8ce]
    public func sessionSyncDetached(
        _ context: NativeContextHandle,
        session: SessionHandle,
        detached: SessionHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_sync_detached")
            guard let owner = ctx.sessions[session.slot], owner.generation == session.generation,
                  let child = ctx.sessions[detached.slot], child.generation == detached.generation else {
                throw NativeError(operation: "ot_session_sync_detached", status: .staleHandle)
            }
            if let pal = owner.session.palette { child.session.setPalette(pal) }
            child.session.setThemeMode(owner.session.themeMode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetImageResolution [status=implemented hash=b9de5708b778]
    public func sessionSetImageResolution(
        _ context: NativeContextHandle,
        session: SessionHandle,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_image_resolution")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_image_resolution", status: .staleHandle)
            }
            _ = (entry, pixelWidth, pixelHeight)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionSetKittyImageTransport [status=implemented hash=10495a45855a]
    public func sessionSetKittyImageTransport(
        _ context: NativeContextHandle,
        session: SessionHandle,
        mode: Int
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_set_kitty_image_transport")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_set_kitty_image_transport", status: .staleHandle)
            }
            try entry.session.setKittyImageTransport(mode: mode)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionGetKittyImageTransport [status=implemented hash=ec3fcfe5c5df]
    public func sessionGetKittyImageTransport(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> NativeSessionKittyImageTransportStatus {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_get_kitty_image_transport")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_get_kitty_image_transport", status: .staleHandle)
            }
            return try entry.session.getKittyImageTransport()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionPollKittyImageTransport [status=implemented hash=4ff36e875f66]
    public func sessionPollKittyImageTransport(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws -> Bool {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_poll_kitty_image_transport")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_poll_kitty_image_transport", status: .staleHandle)
            }
            return try entry.session.pollKittyImageTransport()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionCancelKittyImageTransport [status=implemented hash=be073f6ceac2]
    public func sessionCancelKittyImageTransport(
        _ context: NativeContextHandle,
        session: SessionHandle,
        failed: Bool = false
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_cancel_kitty_image_transport")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_cancel_kitty_image_transport", status: .staleHandle)
            }
            try entry.session.cancelKittyImageTransport(failed: failed)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionProcessKittyImageReply [status=implemented hash=42a30edda0e8]
    public func sessionProcessKittyImageReply(
        _ context: NativeContextHandle,
        session: SessionHandle,
        bytes: [UInt8]
    ) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_process_kitty_image_reply")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_process_kitty_image_reply", status: .staleHandle)
            }
            return try entry.session.processKittyImageReply(bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.sessionStartKittyFileProbe [status=implemented hash=961aeca85f48]
    public func sessionStartKittyFileProbe(
        _ context: NativeContextHandle,
        session: SessionHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_session_start_kitty_file_probe")
            guard let entry = ctx.sessions[session.slot], entry.generation == session.generation else {
                throw NativeError(operation: "ot_session_start_kitty_file_probe", status: .staleHandle)
            }
            try entry.session.startKittyFileProbe()
        }
    }
}

// MARK: - Markdown (10 methods)

extension SwiftRenderLib {
    private static func mapMarkdownBlocks(_ changes: MarkdownChanges) -> [NativeMarkdownBlock] {
        changes.changed.map { state in
            NativeMarkdownBlock(
                index: state.index,
                parent: nil,
                kind: UInt32(MarkdownBlockKind.allCases.firstIndex(of: state.kind) ?? 0),
                flags: state.isCommitted ? 1 : 0,
                sourceStart: state.sourceRange.lowerBound,
                sourceEnd: state.sourceRange.upperBound,
                infoStart: state.sourceRange.lowerBound,
                infoEnd: state.sourceRange.lowerBound,
                number: state.revision
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownCreate [status=implemented hash=bb099e91efb4]
    public func markdownCreate(
        _ context: NativeContextHandle,
        options: NativeMarkdownOptions = NativeMarkdownOptions()
    ) throws -> ContextMarkdownHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_create")
            let doc = StreamingMarkdownDocument()
            let h = ctx.allocateHandle()
            ctx.markdowns[h.slot] = (h.generation, doc, options, [])
            return ContextMarkdownHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownDestroy [status=implemented hash=b4424b354af6]
    public func markdownDestroy(_ context: NativeContextHandle, markdown: ContextMarkdownHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.markdowns.removeValue(forKey: markdown.slot) {
                entry.doc.destroy()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownSetOptions [status=implemented hash=7e9091428783]
    public func markdownSetOptions(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle,
        options: NativeMarkdownOptions
    ) throws -> NativeMarkdownResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_set_options")
            guard var entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_set_options", status: .staleHandle)
            }
            entry.options = options
            let changes = entry.doc.setOptions(MarkdownParseOptions())
            entry.lastBlocks = Self.mapMarkdownBlocks(changes)
            ctx.markdowns[markdown.slot] = entry
            return NativeMarkdownResult(
                changed: changes.changed.count,
                committed: entry.doc.committed,
                removedFrom: changes.removedFrom
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownWrite [status=implemented hash=26b0d95e652c]
    public func markdownWrite(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle,
        text: String,
        append: Bool = false
    ) throws -> NativeMarkdownResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_write")
            guard var entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_write", status: .staleHandle)
            }
            let nextContent = append ? (entry.doc.content + text) : text
            let changes = entry.doc.write(nextContent, streaming: append)
            entry.lastBlocks = Self.mapMarkdownBlocks(changes)
            ctx.markdowns[markdown.slot] = entry
            return NativeMarkdownResult(
                changed: changes.changed.count,
                committed: entry.doc.committed,
                removedFrom: changes.removedFrom
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownFinish [status=implemented hash=5140332e5a34]
    public func markdownFinish(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle
    ) throws -> NativeMarkdownResult {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_finish")
            guard var entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_finish", status: .staleHandle)
            }
            let changes = entry.doc.write(entry.doc.content, streaming: false)
            entry.lastBlocks = Self.mapMarkdownBlocks(changes)
            ctx.markdowns[markdown.slot] = entry
            return NativeMarkdownResult(
                changed: changes.changed.count,
                committed: entry.doc.committed,
                removedFrom: changes.removedFrom
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownGetSource [status=implemented hash=8d0218383648]
    public func markdownGetSource(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_get_source")
            guard let entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_get_source", status: .staleHandle)
            }
            return entry.doc.content
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownReadChanges [status=implemented hash=7cc470ab13e0]
    public func markdownReadChanges(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle
    ) throws -> [NativeMarkdownBlock] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_read_changes")
            guard let entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_read_changes", status: .staleHandle)
            }
            return entry.lastBlocks
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownReadSource [status=implemented hash=50ee6230da67]
    public func markdownReadSource(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle,
        index: Int
    ) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_read_source")
            guard let entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_read_source", status: .staleHandle)
            }
            return entry.doc.readSource(index)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownReadLeaf [status=implemented hash=aec0f2efced0]
    public func markdownReadLeaf(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle,
        index: Int
    ) throws -> NativeMarkdownLeaf {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_read_leaf")
            guard let entry = ctx.markdowns[markdown.slot], entry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_read_leaf", status: .staleHandle)
            }
            let text = entry.doc.readSource(index)
            return NativeMarkdownLeaf(chunks: [TextChunk(text: text)], spans: [0])
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.markdownBind [status=implemented hash=f9c68fed69dd]
    public func markdownBind(
        _ context: NativeContextHandle,
        markdown: ContextMarkdownHandle,
        index: Int,
        node: SceneNodeHandle
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_markdown_bind")
            guard let mdEntry = ctx.markdowns[markdown.slot], mdEntry.generation == markdown.generation else {
                throw NativeError(operation: "ot_markdown_bind", status: .staleHandle)
            }
            let (scene, sceneNode, _, _, _) = try requireSceneNode(ctx, node, op: "ot_markdown_bind")
            try scene.setText(sceneNode, mdEntry.doc.readSource(index))
        }
    }
}

// MARK: - Clipboard Service (18 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.clipboardServiceCreate [status=implemented hash=b1ce427dfeb4]
    public func clipboardServiceCreate() -> ClipboardServiceHandle {
        lock.withLock { store in
            let id = store.allocId()
            let handle = ClipboardServiceHandle(rawValue: id)
            store.clipboardServices[id] = ClipboardServiceRecord(handle: handle)
            return handle
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardServiceBeginShutdown [status=implemented hash=9c8905f199a1]
    public func clipboardServiceBeginShutdown(_ service: ClipboardServiceHandle) -> NativeClipboardShutdownStatus {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else { return .invalidHandle }
            rec.shuttingDown = true
            return .ready
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardServicePollShutdown [status=implemented hash=037f872ac19f]
    public func clipboardServicePollShutdown(_ service: ClipboardServiceHandle) -> NativeClipboardShutdownStatus {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else { return .invalidHandle }
            return rec.shuttingDown ? .ready : .pending
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardServiceDestroy [status=implemented hash=4d5d82ae391a]
    public func clipboardServiceDestroy(_ service: ClipboardServiceHandle) -> NativeClipboardDestroyStatus {
        lock.withLock { store in
            guard let rec = store.clipboardServices.removeValue(forKey: service.rawValue) else {
                return .invalidHandle
            }
            for opId in rec.operations.keys {
                _ = store.clipboardOpToService.removeValue(forKey: opId)
            }
            return .destroyed
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardServiceDrain [status=implemented hash=88bc040c3df8]
    public func clipboardServiceDrain(_ service: ClipboardServiceHandle) -> Int {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else { return 0 }
            return rec.operations.count
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardReadOperationStart [status=implemented hash=4502697b7d2a]
    public func clipboardReadOperationStart(
        _ service: ClipboardServiceHandle
    ) -> (status: NativeClipboardStartStatus, operation: ClipboardOperationHandle?) {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else {
                return (.invalidService, nil)
            }
            if rec.shuttingDown { return (.shuttingDown, nil) }
            let opId = store.allocId()
            let handle = ClipboardOperationHandle(rawValue: opId)
            let op = ClipboardOperationRecord(
                handle: handle,
                status: rec.hasValue ? .read : .empty,
                mime: rec.hasValue ? rec.storedMime : [],
                data: rec.hasValue ? rec.storedData : []
            )
            rec.operations[opId] = op
            store.clipboardOpToService[opId] = service.rawValue
            return (.ok, handle)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardWriteOperationStart [status=implemented hash=2b066108925a]
    public func clipboardWriteOperationStart(
        _ service: ClipboardServiceHandle,
        mime: String = "text/plain",
        data: [UInt8]
    ) -> (status: NativeClipboardStartStatus, operation: ClipboardOperationHandle?) {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else {
                return (.invalidService, nil)
            }
            if rec.shuttingDown { return (.shuttingDown, nil) }
            rec.storedMime = Array(mime.utf8)
            rec.storedData = data
            rec.hasValue = true
            let opId = store.allocId()
            let handle = ClipboardOperationHandle(rawValue: opId)
            let op = ClipboardOperationRecord(handle: handle, status: .written, mime: rec.storedMime, data: data)
            rec.operations[opId] = op
            store.clipboardOpToService[opId] = service.rawValue
            return (.ok, handle)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardClearOperationStart [status=implemented hash=cee5f1f16727]
    public func clipboardClearOperationStart(
        _ service: ClipboardServiceHandle
    ) -> (status: NativeClipboardStartStatus, operation: ClipboardOperationHandle?) {
        lock.withLock { store in
            guard let rec = store.clipboardServices[service.rawValue] else {
                return (.invalidService, nil)
            }
            if rec.shuttingDown { return (.shuttingDown, nil) }
            rec.storedData.removeAll()
            rec.hasValue = false
            let opId = store.allocId()
            let handle = ClipboardOperationHandle(rawValue: opId)
            let op = ClipboardOperationRecord(handle: handle, status: .cleared)
            rec.operations[opId] = op
            store.clipboardOpToService[opId] = service.rawValue
            return (.ok, handle)
        }
    }

    private func findClipboardOp(_ store: Store, _ op: ClipboardOperationHandle) -> ClipboardOperationRecord? {
        guard let svcId = store.clipboardOpToService[op.rawValue],
              let svc = store.clipboardServices[svcId] else { return nil }
        return svc.operations[op.rawValue]
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationPoll [status=implemented hash=06e6905fced0]
    public func clipboardOperationPoll(_ operation: ClipboardOperationHandle) -> NativeClipboardOperationStatus {
        lock.withLock { store in
            findClipboardOp(store, operation)?.status ?? .invalidHandle
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationCancel [status=implemented hash=261774f228b4]
    public func clipboardOperationCancel(_ operation: ClipboardOperationHandle) -> NativeClipboardCancelStatus {
        lock.withLock { store in
            guard let rec = findClipboardOp(store, operation) else { return .invalidHandle }
            if rec.status == .pending {
                rec.status = .cancelled
                return .requested
            }
            return .alreadyTerminal
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultMimeLength [status=implemented hash=3aae01154c1d]
    public func clipboardOperationResultMimeLength(_ operation: ClipboardOperationHandle) -> Int {
        lock.withLock { store in
            findClipboardOp(store, operation)?.mime.count ?? 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultMimeCopy [status=implemented hash=1e36490728c7]
    public func clipboardOperationResultMimeCopy(
        _ operation: ClipboardOperationHandle,
        into destination: inout [UInt8]
    ) -> NativeClipboardCopyStatus {
        lock.withLock { store in
            guard let rec = findClipboardOp(store, operation) else { return .invalidHandle }
            guard destination.count >= rec.mime.count else { return .bufferTooSmall }
            for i in 0..<rec.mime.count { destination[i] = rec.mime[i] }
            return .ok
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultDataLength [status=implemented hash=3eddf2948b6d]
    public func clipboardOperationResultDataLength(_ operation: ClipboardOperationHandle) -> Int {
        lock.withLock { store in
            findClipboardOp(store, operation)?.data.count ?? 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultDataCopy [status=implemented hash=14ef8f26196c]
    public func clipboardOperationResultDataCopy(
        _ operation: ClipboardOperationHandle,
        into destination: inout [UInt8]
    ) -> NativeClipboardCopyStatus {
        lock.withLock { store in
            guard let rec = findClipboardOp(store, operation) else { return .invalidHandle }
            guard destination.count >= rec.data.count else { return .bufferTooSmall }
            for i in 0..<rec.data.count { destination[i] = rec.data[i] }
            return .ok
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultErrorCode [status=implemented hash=27ad72b8f3fb]
    public func clipboardOperationResultErrorCode(_ operation: ClipboardOperationHandle) -> Int32 {
        lock.withLock { store in
            findClipboardOp(store, operation)?.errorCode ?? -1
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultDiagnosticLength [status=implemented hash=d826a8f0b4ab]
    public func clipboardOperationResultDiagnosticLength(_ operation: ClipboardOperationHandle) -> Int {
        lock.withLock { store in
            findClipboardOp(store, operation)?.diagnostic.count ?? 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationResultDiagnosticCopy [status=implemented hash=caae0ba15672]
    public func clipboardOperationResultDiagnosticCopy(
        _ operation: ClipboardOperationHandle,
        into destination: inout [UInt8]
    ) -> NativeClipboardCopyStatus {
        lock.withLock { store in
            guard let rec = findClipboardOp(store, operation) else { return .invalidHandle }
            guard destination.count >= rec.diagnostic.count else { return .bufferTooSmall }
            for i in 0..<rec.diagnostic.count { destination[i] = rec.diagnostic[i] }
            return .ok
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.clipboardOperationDestroy [status=implemented hash=c5526d92fbf4]
    public func clipboardOperationDestroy(_ operation: ClipboardOperationHandle) -> NativeClipboardDestroyStatus {
        lock.withLock { store in
            guard let svcId = store.clipboardOpToService.removeValue(forKey: operation.rawValue),
                  let svc = store.clipboardServices[svcId] else {
                return .invalidHandle
            }
            _ = svc.operations.removeValue(forKey: operation.rawValue)
            return .destroyed
        }
    }
}

// MARK: - Yoga & Diagnostics (50 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.getYogaHost [status=implemented hash=35650e272171]
    public func getYogaHost() -> YogaHost {
        lock.withLock { $0.yogaHost }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigCreate [status=implemented hash=4bf3b78b99ee]
    public func yogaConfigCreate() -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            store.yogaConfigs[id] = YogaConfig.create(host: store.yogaHost)
            return FFIPointer(address: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigFree [status=implemented hash=c5b2c4c8ad32]
    public func yogaConfigFree(_ config: FFIPointer) {
        lock.withLock { store in
            if let cfg = store.yogaConfigs.removeValue(forKey: config.address) {
                try? cfg.free()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigSetCallbacks [status=adapted hash=211b2833a1d4]
    public func yogaConfigSetCallbacks(_ config: FFIPointer) throws {
        try lock.withLock { store in
            try store.yogaConfigs[config.address]?.ensureCallbacks()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigClearCallbacks [status=adapted hash=fc8a51b1ffcc]
    public func yogaConfigClearCallbacks(_ config: FFIPointer) {
        _ = config
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigSetUseWebDefaults [status=implemented hash=82709fb9fbbd]
    public func yogaConfigSetUseWebDefaults(_ config: FFIPointer, enabled: Bool) {
        lock.withLock { $0.yogaConfigs[config.address]?.setUseWebDefaults(enabled) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigGetUseWebDefaults [status=implemented hash=e7cc5179772c]
    public func yogaConfigGetUseWebDefaults(_ config: FFIPointer) -> Bool {
        lock.withLock { $0.yogaConfigs[config.address]?.useWebDefaults() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigSetPointScaleFactor [status=implemented hash=fd066ac9af2c]
    public func yogaConfigSetPointScaleFactor(_ config: FFIPointer, factor: Float) {
        lock.withLock { $0.yogaConfigs[config.address]?.setPointScaleFactor(factor) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigGetPointScaleFactor [status=implemented hash=499a251e62fe]
    public func yogaConfigGetPointScaleFactor(_ config: FFIPointer) -> Float {
        lock.withLock { $0.yogaConfigs[config.address]?.getPointScaleFactor() ?? 1.0 }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigSetErrata [status=implemented hash=a7f0c435d30d]
    public func yogaConfigSetErrata(_ config: FFIPointer, errata: Errata) {
        lock.withLock { $0.yogaConfigs[config.address]?.setErrata(errata) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigGetErrata [status=implemented hash=41081260880b]
    public func yogaConfigGetErrata(_ config: FFIPointer) -> Errata {
        lock.withLock { $0.yogaConfigs[config.address]?.getErrata() ?? .none }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigSetExperimentalFeatureEnabled [status=implemented hash=e75d4fd08d34]
    public func yogaConfigSetExperimentalFeatureEnabled(
        _ config: FFIPointer,
        feature: ExperimentalFeature,
        enabled: Bool
    ) {
        lock.withLock { $0.yogaConfigs[config.address]?.setExperimentalFeatureEnabled(feature, enabled) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaConfigIsExperimentalFeatureEnabled [status=implemented hash=6b504b1dd7b4]
    public func yogaConfigIsExperimentalFeatureEnabled(
        _ config: FFIPointer,
        feature: ExperimentalFeature
    ) -> Bool {
        lock.withLock { $0.yogaConfigs[config.address]?.isExperimentalFeatureEnabled(feature) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeCreateForOpenTUI [status=implemented hash=f163a710e9fd]
    public func yogaNodeCreateForOpenTUI() -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            store.yogaNodes[id] = YogaNode.createForOpenTUI()
            return FFIPointer(address: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeCreateWithConfig [status=implemented hash=791364ecbd4a]
    public func yogaNodeCreateWithConfig(_ config: FFIPointer) -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            let cfg = store.yogaConfigs[config.address]
            store.yogaNodes[id] = cfg.map { YogaNode.createWithConfig($0) } ?? YogaNode.createDefault()
            return FFIPointer(address: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetConfig [status=implemented hash=3a117401b43d]
    public func yogaNodeGetConfig(_ node: FFIPointer) -> FFIPointer? {
        lock.withLock { store in
            guard store.yogaNodes[node.address] != nil else { return nil }
            return store.yogaConfigs.keys.first.map { FFIPointer(address: $0) }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeFree [status=implemented hash=ab9f6322f65e]
    public func yogaNodeFree(_ node: FFIPointer) {
        lock.withLock { store in
            if let n = store.yogaNodes.removeValue(forKey: node.address) {
                n.free()
            }
            _ = store.yogaMeasureResults.removeValue(forKey: node.address)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeFreeRecursive [status=implemented hash=d51951db8e8a]
    public func yogaNodeFreeRecursive(_ node: FFIPointer) {
        lock.withLock { store in
            if let n = store.yogaNodes.removeValue(forKey: node.address) {
                n.freeRecursive()
            }
            _ = store.yogaMeasureResults.removeValue(forKey: node.address)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeReset [status=implemented hash=4872495223ea]
    public func yogaNodeReset(_ node: FFIPointer) {
        lock.withLock { $0.yogaNodes[node.address]?.reset() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeCopyStyle [status=implemented hash=707e18250002]
    public func yogaNodeCopyStyle(destination: FFIPointer, source: FFIPointer) {
        lock.withLock { store in
            guard let dst = store.yogaNodes[destination.address],
                  let src = store.yogaNodes[source.address] else { return }
            dst.copyStyle(src)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeInsertChild [status=implemented hash=3ee65b82424a]
    public func yogaNodeInsertChild(parent: FFIPointer, child: FFIPointer, index: Int) {
        lock.withLock { store in
            guard let p = store.yogaNodes[parent.address],
                  let c = store.yogaNodes[child.address] else { return }
            p.insertChild(c, index)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeRemoveChild [status=implemented hash=ea218e5a3284]
    public func yogaNodeRemoveChild(parent: FFIPointer, child: FFIPointer) {
        lock.withLock { store in
            guard let p = store.yogaNodes[parent.address],
                  let c = store.yogaNodes[child.address] else { return }
            p.removeChild(c)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeRemoveAllChildren [status=implemented hash=2bf1c740fc59]
    public func yogaNodeRemoveAllChildren(_ node: FFIPointer) {
        lock.withLock { $0.yogaNodes[node.address]?.removeAllChildren() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetChild [status=implemented hash=9b43327ca7d0]
    public func yogaNodeGetChild(_ node: FFIPointer, index: Int) -> FFIPointer? {
        lock.withLock { store in
            guard let child = store.yogaNodes[node.address]?.getChild(index) else { return nil }
            for (addr, candidate) in store.yogaNodes where candidate === child {
                return FFIPointer(address: addr)
            }
            return nil
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetChildCount [status=implemented hash=3f0cddf9b746]
    public func yogaNodeGetChildCount(_ node: FFIPointer) -> Int {
        lock.withLock { $0.yogaNodes[node.address]?.getChildCount() ?? 0 }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetParent [status=implemented hash=8f4cfde8b2ff]
    public func yogaNodeGetParent(_ node: FFIPointer) -> FFIPointer? {
        lock.withLock { store in
            guard let parent = store.yogaNodes[node.address]?.getParent() else { return nil }
            for (addr, candidate) in store.yogaNodes where candidate === parent {
                return FFIPointer(address: addr)
            }
            return nil
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeCalculateLayout [status=implemented hash=1321ddbbe852]
    public func yogaNodeCalculateLayout(
        _ node: FFIPointer,
        width: Float? = nil,
        height: Float? = nil,
        direction: Direction = .ltr
    ) {
        lock.withLock { $0.yogaNodes[node.address]?.calculateLayout(width, height, direction) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeIsDirty [status=implemented hash=eaa9d465fbd7]
    public func yogaNodeIsDirty(_ node: FFIPointer) -> Bool {
        lock.withLock { $0.yogaNodes[node.address]?.isDirty() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeMarkDirty [status=implemented hash=57bd212a3642]
    public func yogaNodeMarkDirty(_ node: FFIPointer) {
        lock.withLock { $0.yogaNodes[node.address]?.markDirty() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetHasNewLayout [status=implemented hash=bddb54d3bad6]
    public func yogaNodeGetHasNewLayout(_ node: FFIPointer) -> Bool {
        lock.withLock { $0.yogaNodes[node.address]?.hasNewLayout() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeSetHasNewLayout [status=implemented hash=115b84c75f43]
    public func yogaNodeSetHasNewLayout(_ node: FFIPointer, hasNewLayout: Bool) {
        lock.withLock { store in
            if !hasNewLayout {
                store.yogaNodes[node.address]?.markLayoutSeen()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeSetIsReferenceBaseline [status=implemented hash=726a31a706a8]
    public func yogaNodeSetIsReferenceBaseline(_ node: FFIPointer, enabled: Bool) {
        lock.withLock { $0.yogaNodes[node.address]?.setIsReferenceBaseline(enabled) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeIsReferenceBaseline [status=implemented hash=1a4f124e08da]
    public func yogaNodeIsReferenceBaseline(_ node: FFIPointer) -> Bool {
        lock.withLock { $0.yogaNodes[node.address]?.isReferenceBaseline() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeSetAlwaysFormsContainingBlock [status=implemented hash=3cca289b0e06]
    public func yogaNodeSetAlwaysFormsContainingBlock(_ node: FFIPointer, enabled: Bool) {
        lock.withLock { $0.yogaNodes[node.address]?.setAlwaysFormsContainingBlock(enabled) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetAlwaysFormsContainingBlock [status=implemented hash=0be014d76fba]
    public func yogaNodeGetAlwaysFormsContainingBlock(_ node: FFIPointer) -> Bool {
        lock.withLock { $0.yogaNodes[node.address]?.getAlwaysFormsContainingBlock() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeGetComputedLayout [status=implemented hash=e70c5e6cba08]
    public func yogaNodeGetComputedLayout(_ node: FFIPointer) -> NativeYogaLayout {
        lock.withLock { store in
            guard let layout = store.yogaNodes[node.address]?.getComputedLayout() else {
                return NativeYogaLayout()
            }
            return NativeYogaLayout(
                left: layout.left,
                top: layout.top,
                right: layout.right,
                bottom: layout.bottom,
                width: layout.width,
                height: layout.height
            )
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeLayoutGetEdge [status=implemented hash=3c9794e82999]
    public func yogaNodeLayoutGetEdge(_ node: FFIPointer, kind: Int32, edge: Edge) -> Float {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return 0 }
            switch kind {
            case 0: return n.getComputedMargin(edge)
            case 1: return n.getComputedPadding(edge)
            default: return n.getComputedBorder(edge)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleSetEnum [status=implemented hash=9eae9969c859]
    public func yogaNodeStyleSetEnum(_ node: FFIPointer, kind: Int32, value: Int32) {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return }
            switch kind {
            case 0: if let v = Direction(rawValue: value) { n.setDirection(v) }
            case 1: n.setFlexDirection(FlexDirection.fromYogaRawValue(value))
            case 2: if let v = Justify(rawValue: value) { n.setJustifyContent(v) }
            case 3: if let v = Align(rawValue: value) { n.setAlignContent(v) }
            case 4: if let v = Align(rawValue: value) { n.setAlignItems(v) }
            case 5: if let v = Align(rawValue: value) { n.setAlignSelf(v) }
            case 6: if let v = PositionType(rawValue: value) { n.setPositionType(v) }
            case 7: if let v = Wrap(rawValue: value) { n.setFlexWrap(v) }
            case 8: if let v = Overflow(rawValue: value) { n.setOverflow(v) }
            case 9: if let v = Display(rawValue: value) { n.setDisplay(v) }
            case 10: if let v = BoxSizing(rawValue: value) { n.setBoxSizing(v) }
            default: break
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleGetEnum [status=implemented hash=ea2c669de2b9]
    public func yogaNodeStyleGetEnum(_ node: FFIPointer, kind: Int32) -> Int32 {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return 0 }
            switch kind {
            case 0: return n.getDirection().rawValue
            case 1: return Int32(n.getFlexDirection().yogaRawValue)
            case 2: return n.getJustifyContent().rawValue
            case 3: return n.getAlignContent().rawValue
            case 4: return n.getAlignItems().rawValue
            case 5: return n.getAlignSelf().rawValue
            case 6: return n.getPositionType().rawValue
            case 7: return n.getFlexWrap().rawValue
            case 8: return n.getOverflow().rawValue
            case 9: return n.getDisplay().rawValue
            case 10: return n.getBoxSizing().rawValue
            default: return 0
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleSetFloat [status=implemented hash=aa63b572dbd6]
    public func yogaNodeStyleSetFloat(_ node: FFIPointer, kind: Int32, value: Float) {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return }
            let opt: Float? = value.isNaN ? nil : value
            switch kind {
            case 0: n.setFlex(opt)
            case 1: n.setFlexGrow(opt)
            case 2: n.setFlexShrink(opt)
            case 3: n.setAspectRatio(opt)
            default: break
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleGetFloat [status=implemented hash=0e9cdc0cc715]
    public func yogaNodeStyleGetFloat(_ node: FFIPointer, kind: Int32) -> Float {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return .nan }
            switch kind {
            case 0: return n.getFlex()
            case 1: return n.getFlexGrow()
            case 2: return n.getFlexShrink()
            case 3: return n.getAspectRatio()
            default: return .nan
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleSetBorder [status=implemented hash=b80e7bae7589]
    public func yogaNodeStyleSetBorder(_ node: FFIPointer, edge: Edge, value: Float) {
        lock.withLock { $0.yogaNodes[node.address]?.setBorder(edge, value.isNaN ? nil : value) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleGetBorder [status=implemented hash=9fa745d5fb1a]
    public func yogaNodeStyleGetBorder(_ node: FFIPointer, edge: Edge) -> Float {
        lock.withLock { $0.yogaNodes[node.address]?.getBorder(edge) ?? .nan }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleSetValue [status=implemented hash=7763cb8bd872]
    public func yogaNodeStyleSetValue(_ node: FFIPointer, kind: Int32, edge: Int32, unit: Unit, value: Float) {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return }
            let e = Edge(rawValue: edge) ?? .all
            let g = Gutter(rawValue: edge) ?? .all
            let input: YogaValueInput = switch unit {
            case .undefined: .undefined
            case .point: .point(value)
            case .percent: .percent(value)
            case .auto: .auto
            }
            switch kind {
            case 0: n.setWidth(input)
            case 1: n.setHeight(input)
            case 2: n.setMinWidth(input)
            case 3: n.setMinHeight(input)
            case 4: n.setMaxWidth(input)
            case 5: n.setMaxHeight(input)
            case 6: n.setFlexBasis(input)
            case 7: n.setMargin(e, input)
            case 8: n.setPadding(e, input)
            case 9: n.setPosition(e, input)
            case 10: n.setGap(g, input)
            default: break
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeStyleGetValue [status=implemented hash=434d91e59f2d]
    public func yogaNodeStyleGetValue(_ node: FFIPointer, kind: Int32, edge: Int32) -> YogaValue {
        lock.withLock { store in
            guard let n = store.yogaNodes[node.address] else { return YogaValue(unit: .undefined, value: .nan) }
            let e = Edge(rawValue: edge) ?? .all
            let g = Gutter(rawValue: edge) ?? .all
            switch kind {
            case 0: return n.getWidth()
            case 1: return n.getHeight()
            case 2: return n.getMinWidth()
            case 3: return n.getMinHeight()
            case 4: return n.getMaxWidth()
            case 5: return n.getMaxHeight()
            case 6: return n.getFlexBasis()
            case 7: return n.getMargin(e)
            case 8: return n.getPadding(e)
            case 9: return n.getPosition(e)
            case 10: return n.getGap(g)
            default: return YogaValue(unit: .undefined, value: .nan)
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeSetMeasureFunc [status=implemented hash=541ff1c735ca]
    public func yogaNodeSetMeasureFunc(_ node: FFIPointer, measure: YogaMeasureFunction?) {
        lock.withLock { $0.yogaNodes[node.address]?.setMeasureFunc(measure) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeUnsetMeasureFunc [status=implemented hash=926b76a39534]
    public func yogaNodeUnsetMeasureFunc(_ node: FFIPointer) {
        lock.withLock { $0.yogaNodes[node.address]?.unsetMeasureFunc() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeHasMeasureFunc [status=implemented hash=9a0cbe0bbbba]
    public func yogaNodeHasMeasureFunc(_ node: FFIPointer) -> Bool {
        lock.withLock { $0.yogaNodes[node.address]?.hasMeasureFunc() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeSetDirtiedFunc [status=implemented hash=97316f15d7bc]
    public func yogaNodeSetDirtiedFunc(_ node: FFIPointer, dirtied: YogaDirtiedFunction?) {
        lock.withLock { $0.yogaNodes[node.address]?.setDirtiedFunc(dirtied) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaNodeUnsetDirtiedFunc [status=implemented hash=f7a0496933d9]
    public func yogaNodeUnsetDirtiedFunc(_ node: FFIPointer) {
        lock.withLock { $0.yogaNodes[node.address]?.unsetDirtiedFunc() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.yogaStoreMeasureResult [status=implemented hash=3960480864c0]
    public func yogaStoreMeasureResult(_ node: FFIPointer, width: Float, height: Float) {
        lock.withLock { $0.yogaMeasureResults[node.address] = (width, height) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createYogaMeasureCallback [status=adapted hash=e8b80958ea83]
    public func createYogaMeasureCallback(_ callback: @escaping NativeYogaMeasureCallback) -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            store.yogaMeasureCallbacks[id] = callback
            return FFIPointer(address: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createYogaDirtiedCallback [status=adapted hash=3702f5121bcb]
    public func createYogaDirtiedCallback(_ callback: @escaping NativeYogaDirtiedCallback) -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            store.yogaDirtiedCallbacks[id] = callback
            return FFIPointer(address: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.getArenaAllocatedBytes [status=implemented hash=f2786c8b479f]
    public func getArenaAllocatedBytes() -> UInt64 {
        lock.withLock { $0.totalRequestedBytes }
    }

    // parity: core/src/zig.ts#FFIRenderLib.getBuildOptions [status=implemented hash=d8b67114fde3]
    public func getBuildOptions() -> BuildOptions {
        BuildOptions(gpaSafeStats: true, gpaMemoryLimitTracking: false)
    }

    // parity: core/src/zig.ts#FFIRenderLib.getAllocatorStats [status=implemented hash=b7c2a170df02]
    public func getAllocatorStats() -> AllocatorStats {
        lock.withLock { store in
            AllocatorStats(
                totalRequestedBytes: store.totalRequestedBytes,
                activeAllocations: store.activeAllocations,
                smallAllocations: store.activeAllocations,
                largeAllocations: 0,
                requestedBytesValid: true
            )
        }
    }
}

// MARK: - Audio Engine (42 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.createAudioEngine [status=implemented hash=77a450615b29]
    public func createAudioEngine(_ options: AudioCreateOptions = AudioCreateOptions()) -> AudioEngineHandle {
        lock.withLock { store in
            let setup = AudioSetupOptions(
                sampleRate: Int(options.sampleRate),
                playbackChannels: Int(options.playbackChannels)
            )
            let engine = Audio(options: setup)
            let id = store.allocId()
            store.audioEngines[id] = AudioEngineRecord(engine: engine)
            return AudioEngineHandle(rawValue: id)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyAudioEngine [status=implemented hash=c807800ae248]
    public func destroyAudioEngine(_ engine: AudioEngineHandle) {
        lock.withLock { store in
            if let rec = store.audioEngines.removeValue(forKey: engine.rawValue) {
                rec.engine.dispose()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioRefreshPlaybackDevices [status=implemented hash=cf2bc2aca2fd]
    public func audioRefreshPlaybackDevices(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue] != nil }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetPlaybackDeviceCount [status=implemented hash=4eaae8e9ad38]
    public func audioGetPlaybackDeviceCount(_ engine: AudioEngineHandle) -> Int {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.listPlaybackDevices()?.count ?? 0 }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetPlaybackDeviceName [status=implemented hash=1be31d8f0085]
    public func audioGetPlaybackDeviceName(_ engine: AudioEngineHandle, index: Int) -> String? {
        lock.withLock { store in
            guard let list = store.audioEngines[engine.rawValue]?.engine.listPlaybackDevices(),
                  index >= 0, index < list.count else { return nil }
            return list[index].name
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioIsPlaybackDeviceDefault [status=implemented hash=9330ed06b043]
    public func audioIsPlaybackDeviceDefault(_ engine: AudioEngineHandle, index: Int) -> Bool {
        lock.withLock { store in
            guard let list = store.audioEngines[engine.rawValue]?.engine.listPlaybackDevices(),
                  index >= 0, index < list.count else { return false }
            return list[index].isDefault
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSelectPlaybackDevice [status=implemented hash=028d82c1dc1a]
    public func audioSelectPlaybackDevice(_ engine: AudioEngineHandle, index: Int) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.selectPlaybackDevice(index) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioClearPlaybackDeviceSelection [status=implemented hash=eef63b460d98]
    public func audioClearPlaybackDeviceSelection(_ engine: AudioEngineHandle) {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.clearPlaybackDeviceSelection() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioRefreshCaptureDevices [status=implemented hash=38e252d65d33]
    public func audioRefreshCaptureDevices(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue] != nil }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetCaptureDeviceCount [status=implemented hash=98353458de99]
    public func audioGetCaptureDeviceCount(_ engine: AudioEngineHandle) -> Int {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.listCaptureDevices()?.count ?? 0 }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetCaptureDeviceName [status=implemented hash=20740d0837da]
    public func audioGetCaptureDeviceName(_ engine: AudioEngineHandle, index: Int) -> String? {
        lock.withLock { store in
            guard let list = store.audioEngines[engine.rawValue]?.engine.listCaptureDevices(),
                  index >= 0, index < list.count else { return nil }
            return list[index].name
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioIsCaptureDeviceDefault [status=implemented hash=0e3bce983742]
    public func audioIsCaptureDeviceDefault(_ engine: AudioEngineHandle, index: Int) -> Bool {
        lock.withLock { store in
            guard let list = store.audioEngines[engine.rawValue]?.engine.listCaptureDevices(),
                  index >= 0, index < list.count else { return false }
            return list[index].isDefault
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSelectCaptureDevice [status=implemented hash=e92239f40192]
    public func audioSelectCaptureDevice(_ engine: AudioEngineHandle, index: Int) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.selectCaptureDevice(index) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioClearCaptureDeviceSelection [status=implemented hash=0b3afbb752cf]
    public func audioClearCaptureDeviceSelection(_ engine: AudioEngineHandle) {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.clearCaptureDeviceSelection() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStartCapture [status=implemented hash=8b701e0825dc]
    public func audioStartCapture(
        _ engine: AudioEngineHandle,
        options: AudioCaptureOptions = AudioCaptureOptions()
    ) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.startCapture(options) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStopCapture [status=implemented hash=e02771e9ce39]
    public func audioStopCapture(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.stopCapture() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioIsCaptureRunning [status=implemented hash=a5135338bdcd]
    public func audioIsCaptureRunning(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.isCapturing() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioReadCapture [status=implemented hash=3cbf0d114abf]
    public func audioReadCapture(_ engine: AudioEngineHandle, frameCount: Int) -> AudioCaptureReadResult? {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.readCaptureFrames(frameCount) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetCaptureStats [status=implemented hash=c88eda7713ca]
    public func audioGetCaptureStats(_ engine: AudioEngineHandle) -> NativeAudioCaptureStats? {
        lock.withLock { store in
            guard let stats = store.audioEngines[engine.rawValue]?.engine.getCaptureStats() else { return nil }
            return NativeAudioCaptureStats(stats)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStart [status=implemented hash=c6921bc4311c]
    public func audioStart(_ engine: AudioEngineHandle, options: ZigAudioStartOptions? = nil) -> Bool {
        lock.withLock { store in
            _ = options
            return store.audioEngines[engine.rawValue]?.engine.start() ?? false
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStartMixer [status=implemented hash=ae189dff0079]
    public func audioStartMixer(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.startMixer() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStop [status=implemented hash=e97fdb2b1c32]
    public func audioStop(_ engine: AudioEngineHandle) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.stop() ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioCreateStream [status=implemented hash=29edf671c4b1]
    public func audioCreateStream(_ engine: AudioEngineHandle, options: AudioStreamCreateOptions) -> UInt32 {
        lock.withLock { store in
            guard let rec = store.audioEngines[engine.rawValue] else { return 0 }
            let id = rec.nextStreamId
            rec.nextStreamId &+= 1
            rec.streams[id] = AudioStreamRecord(id: id, options: options)
            return id
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioWriteStream [status=implemented hash=566cef3e6f89]
    public func audioWriteStream(_ engine: AudioEngineHandle, streamId: UInt32, data: [UInt8]) -> Int {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId], !stream.ended else { return -1 }
            stream.bytes.append(contentsOf: data)
            stream.stats.bytesReceived &+= UInt64(data.count)
            stream.stats.state = NativeAudioStreamState.playing.rawValue
            let frameBytes = max(1, Int(stream.stats.channels) * 2)
            let decoded = UInt64(data.count / frameBytes)
            stream.stats.framesDecoded &+= decoded
            stream.stats.bufferedFrames &+= UInt32(decoded)
            return data.count
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioEndStream [status=implemented hash=9144f49d8233]
    public func audioEndStream(_ engine: AudioEngineHandle, streamId: UInt32) -> Bool {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId] else { return false }
            stream.ended = true
            stream.stats.state = NativeAudioStreamState.ended.rawValue
            return true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioRestartStream [status=implemented hash=9ab78127f189]
    public func audioRestartStream(_ engine: AudioEngineHandle, streamId: UInt32) -> Bool {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId] else { return false }
            stream.ended = false
            stream.bytes.removeAll()
            stream.stats.state = NativeAudioStreamState.buffering.rawValue
            stream.stats.readyGeneration &+= 1
            return true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetStreamVolume [status=implemented hash=051ed59bd963]
    public func audioSetStreamVolume(_ engine: AudioEngineHandle, streamId: UInt32, volume: Float) -> Bool {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId] else { return false }
            stream.options.volume = volume
            return true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetStreamPan [status=implemented hash=ee7f5ad360d2]
    public func audioSetStreamPan(_ engine: AudioEngineHandle, streamId: UInt32, pan: Float) -> Bool {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId] else { return false }
            stream.options.pan = pan
            return true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetStreamGroup [status=implemented hash=e62fac2f0d3b]
    public func audioSetStreamGroup(_ engine: AudioEngineHandle, streamId: UInt32, groupId: UInt32) -> Bool {
        lock.withLock { store in
            guard let stream = store.audioEngines[engine.rawValue]?.streams[streamId] else { return false }
            stream.options.groupId = groupId
            return true
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetStreamStats [status=implemented hash=1298d7ce00db]
    public func audioGetStreamStats(_ engine: AudioEngineHandle, streamId: UInt32) -> NativeAudioStreamStats? {
        lock.withLock { $0.audioEngines[engine.rawValue]?.streams[streamId]?.stats }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioCloseStream [status=implemented hash=021ea84006de]
    public func audioCloseStream(
        _ engine: AudioEngineHandle,
        streamId: UInt32,
        reason: NativeAudioStreamCloseReason = .disposed
    ) -> Bool {
        lock.withLock { store in
            _ = reason
            return store.audioEngines[engine.rawValue]?.streams.removeValue(forKey: streamId) != nil
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioLoad [status=implemented hash=d9c2f8b7439c]
    public func audioLoad(_ engine: AudioEngineHandle, data: [UInt8]) -> UInt32 {
        lock.withLock { store in
            guard let sound = store.audioEngines[engine.rawValue]?.engine.loadSound(data) else { return 0 }
            return sound
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioUnload [status=implemented hash=796f65075871]
    public func audioUnload(_ engine: AudioEngineHandle, soundId: UInt32) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.unloadSound(soundId) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioPlay [status=implemented hash=07b0c37766c9]
    public func audioPlay(
        _ engine: AudioEngineHandle,
        soundId: UInt32,
        options: AudioVoiceOptions? = nil
    ) -> UInt32 {
        lock.withLock { store in
            let playOpts = AudioPlayOptions(
                volume: Double(options?.volume ?? 1.0),
                pan: Double(options?.pan ?? 0.0),
                loop: options?.loop ?? false,
                groupId: options?.groupId
            )
            return store.audioEngines[engine.rawValue]?.engine.play(soundId, options: playOpts) ?? 0
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioStopVoice [status=implemented hash=f32aa431332c]
    public func audioStopVoice(_ engine: AudioEngineHandle, voiceId: UInt32) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.stopVoice(voiceId) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetVoiceGroup [status=implemented hash=a5647d00c115]
    public func audioSetVoiceGroup(_ engine: AudioEngineHandle, voiceId: UInt32, groupId: UInt32) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.setVoiceGroup(voiceId, group: groupId) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioCreateGroup [status=implemented hash=194cc4904f08]
    public func audioCreateGroup(_ engine: AudioEngineHandle, name: String) -> UInt32 {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.group(name) ?? 0 }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetGroupVolume [status=implemented hash=3071ccf26677]
    public func audioSetGroupVolume(_ engine: AudioEngineHandle, groupId: UInt32, volume: Float) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.setGroupVolume(groupId, volume: Double(volume)) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioSetMasterVolume [status=implemented hash=9d4121d13a8a]
    public func audioSetMasterVolume(_ engine: AudioEngineHandle, volume: Float) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.setMasterVolume(Double(volume)) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioMixToBuffer [status=implemented hash=8811e7eb4d8a]
    public func audioMixToBuffer(_ engine: AudioEngineHandle, frameCount: Int, channels: Int = 2) -> [Float]? {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.mixFrames(frameCount, channels: channels) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioEnableTap [status=implemented hash=5447a785e158]
    public func audioEnableTap(_ engine: AudioEngineHandle, capacityFrames: Int = 8192) -> Bool {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.enableTap(capacityFrames: capacityFrames) ?? false }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioReadTap [status=implemented hash=77284174d7f6]
    public func audioReadTap(
        _ engine: AudioEngineHandle,
        frameCount: Int,
        channels: Int = 2
    ) -> AudioCaptureReadResult? {
        lock.withLock { $0.audioEngines[engine.rawValue]?.engine.readTapFrames(frameCount, channels: channels) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.audioGetStats [status=implemented hash=d73e05ffb565]
    public func audioGetStats(_ engine: AudioEngineHandle) -> ZigAudioStats? {
        lock.withLock { store in
            guard let stats = store.audioEngines[engine.rawValue]?.engine.getStats() else { return nil }
            return ZigAudioStats(stats)
        }
    }
}

// MARK: - NativeSpanFeed (13 methods)

extension SwiftRenderLib {
    // parity: core/src/zig.ts#FFIRenderLib.registerNativeSpanFeedStream [status=implemented hash=bfc32742cd59]
    public func registerNativeSpanFeedStream(_ stream: FFIPointer, handler: @escaping NativeSpanFeedEventHandler) {
        lock.withLock { $0.spanFeeds[stream.address]?.eventHandler = handler }
    }

    // parity: core/src/zig.ts#FFIRenderLib.unregisterNativeSpanFeedStream [status=implemented hash=b1cb45410cd5]
    public func unregisterNativeSpanFeedStream(_ stream: FFIPointer) {
        lock.withLock { $0.spanFeeds[stream.address]?.eventHandler = nil }
    }

    // parity: core/src/zig.ts#FFIRenderLib.createNativeSpanFeed [status=implemented hash=e326f6000df1]
    public func createNativeSpanFeed(_ options: ZigNativeSpanFeedOptions = ZigNativeSpanFeedOptions()) -> FFIPointer {
        lock.withLock { store in
            let id = store.allocId()
            let ptr = FFIPointer(address: id)
            let feed = NativeSpanFeed.create(options.toNativeSpanFeedOptions())
            store.spanFeeds[id] = SpanFeedRecord(pointer: ptr, feed: feed)
            return ptr
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.attachNativeSpanFeed [status=implemented hash=1f54bda2f224]
    public func attachNativeSpanFeed(_ stream: FFIPointer) -> Bool {
        lock.withLock { $0.spanFeeds[stream.address] != nil }
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyNativeSpanFeed [status=implemented hash=d5572e4cfde4]
    public func destroyNativeSpanFeed(_ stream: FFIPointer) {
        lock.withLock { store in
            if let rec = store.spanFeeds.removeValue(forKey: stream.address) {
                rec.feed.close()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamWrite [status=implemented hash=fb76abd02f02]
    public func streamWrite(_ stream: FFIPointer, bytes: [UInt8]) throws -> SpanInfo {
        try lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address] else {
                throw NativeError(operation: "streamWrite", status: .staleHandle)
            }
            return try rec.feed.write(bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamCommit [status=implemented hash=56eecb7e7e39]
    public func streamCommit(_ stream: FFIPointer, bytes: [UInt8] = []) throws -> SpanInfo {
        try lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address] else {
                throw NativeError(operation: "streamCommit", status: .staleHandle)
            }
            return try rec.feed.commit(bytes)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamDrainSpans [status=implemented hash=a3c4beb8e396]
    public func streamDrainSpans(_ stream: FFIPointer, maxSpans: Int? = nil) -> [ZigSpanInfo] {
        lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address] else { return [] }
            return rec.feed.drain(maxSpans: maxSpans).map { info in
                let data = rec.feed.readSpan(info) ?? []
                let chunkPtr = ffiRuntime.pinBuffer(data)
                return ZigSpanInfo(
                    chunkPtr: chunkPtr,
                    offset: UInt32(info.offset),
                    len: UInt32(info.len),
                    chunkIndex: UInt32(info.chunkIndex),
                    slotIndex: UInt32(info.slotIndex),
                    releaseId: info.releaseId
                )
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamReleaseSpan [status=implemented hash=96d870b1e2c3]
    public func streamReleaseSpan(_ stream: FFIPointer, slotIndex: Int, releaseId: UInt64) {
        lock.withLock { $0.spanFeeds[stream.address]?.feed.releaseSpan(slotIndex: slotIndex, releaseId: releaseId) }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamClose [status=implemented hash=7fe41c6b62b7]
    public func streamClose(_ stream: FFIPointer) {
        lock.withLock { $0.spanFeeds[stream.address]?.feed.close() }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamGetStats [status=implemented hash=d3df9b4e18f1]
    public func streamGetStats(_ stream: FFIPointer) -> ZigNativeSpanFeedStats? {
        lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address] else { return nil }
            return ZigNativeSpanFeedStats(rec.feed.stats)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamReserve [status=implemented hash=8196ec5c7c40]
    public func streamReserve(_ stream: FFIPointer, minLength: Int) throws -> ReserveInfo {
        try lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address] else {
                throw NativeError(operation: "streamReserve", status: .staleHandle)
            }
            let reservation = try rec.feed.reserve(minLength)
            let ptr = ffiRuntime.pinBuffer(Array(repeating: 0, count: reservation.capacity))
            rec.reservations[ptr.address] = reservation
            return ReserveInfo(ptr: ptr, len: UInt32(reservation.capacity))
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.streamCommitReserved [status=implemented hash=e434871bd004]
    public func streamCommitReserved(_ stream: FFIPointer, reservationPtr: FFIPointer, bytes: [UInt8]) throws -> SpanInfo {
        try lock.withLock { store in
            guard let rec = store.spanFeeds[stream.address],
                  let res = rec.reservations.removeValue(forKey: reservationPtr.address) else {
                throw NativeError(operation: "streamCommitReserved", status: .staleHandle)
            }
            ffiRuntime.releaseBuffer(at: reservationPtr)
            return try rec.feed.commit(reservation: res, bytes: bytes)
        }
    }
}

// MARK: - Image Pipeline (22 methods)

extension SwiftRenderLib {
    private static func mapImageInfo(_ info: ImageInfo) -> NativeImageInfo {
        let fmt: UInt32 = UInt32(ImageFormat.allCases.firstIndex(of: info.format) ?? 0)
        let cs: UInt32 = UInt32(ImageColorStatus.allCases.firstIndex(of: info.colorStatus) ?? 0)
        return NativeImageInfo(
            width: UInt32(max(0, info.width)),
            height: UInt32(max(0, info.height)),
            sourceWidth: UInt32(max(0, info.sourceWidth)),
            sourceHeight: UInt32(max(0, info.sourceHeight)),
            format: fmt,
            colorStatus: cs,
            orientation: UInt32(max(1, info.orientation)),
            hasAlpha: info.hasAlpha ? 1 : 0
        )
    }

    // parity: core/src/zig.ts#FFIRenderLib.destroyContextImage [status=implemented hash=268938395a9d]
    public func destroyContextImage(_ context: NativeContextHandle, image: ContextImageHandle) {
        imageDestroy(context, image: image)
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageInfo [status=implemented hash=37cca0dbe98f]
    public func imageInfo(_ data: [UInt8]) throws -> NativeImageInfo {
        let info = try OpenTUICore.imageInfo(data)
        return Self.mapImageInfo(info)
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageDecode [status=implemented hash=2ef08ee730a9]
    public func imageDecode(_ context: NativeContextHandle, data: [UInt8]) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_decode")
            let img = try NativeImage.decode(data)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, img, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageCreateFromRgba [status=implemented hash=776adfd45863]
    public func imageCreateFromRgba(
        _ context: NativeContextHandle,
        pixels: [UInt8],
        width: Int,
        height: Int,
        stride: Int? = nil
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_create_rgba")
            let img = try NativeImage.fromRgba(pixels, width: width, height: height, stride: stride)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, img, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageCreateFromPixels [status=implemented hash=dc2a8c3d1112]
    public func imageCreateFromPixels(
        _ context: NativeContextHandle,
        pixels: [UInt8],
        width: Int,
        height: Int,
        options: PixelImportOptions = PixelImportOptions()
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_create_pixels")
            let img = try NativeImage.fromPixels(pixels, width: width, height: height, options: options)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, img, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageUpdatePixels [status=implemented hash=985188f815f9]
    public func imageUpdatePixels(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        pixels: [UInt8],
        width: Int,
        height: Int,
        options: PixelImportOptions = PixelImportOptions()
    ) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_update_pixels")
            guard var entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_update_pixels", status: .staleHandle)
            }
            let updated = try NativeImage.fromPixels(pixels, width: width, height: height, options: options)
            entry.image.dispose()
            entry.image = updated
            ctx.images[image.slot] = entry
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageDestroy [status=implemented hash=2c2612e0ff9f]
    public func imageDestroy(_ context: NativeContextHandle, image: ContextImageHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId],
                  var entry = ctx.images[image.slot],
                  entry.generation == image.generation else { return }
            entry.refCount -= 1
            if entry.refCount <= 0 {
                entry.image.dispose()
                _ = ctx.images.removeValue(forKey: image.slot)
            } else {
                ctx.images[image.slot] = entry
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageRetain [status=implemented hash=9f24b00ed270]
    public func imageRetain(_ context: NativeContextHandle, image: ContextImageHandle) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_retain")
            guard var entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_retain", status: .staleHandle)
            }
            entry.refCount += 1
            ctx.images[image.slot] = entry
            return image
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageRetainIccCache [status=implemented hash=00f2da7887da]
    public func imageRetainIccCache(_ context: NativeContextHandle) throws {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_retain_icc_cache")
            ctx.iccCacheRetainCount += 1
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageReleaseIccCache [status=implemented hash=b64faf193a2c]
    public func imageReleaseIccCache(_ context: NativeContextHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            ctx.iccCacheRetainCount = max(0, ctx.iccCacheRetainCount - 1)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageGetInfo [status=implemented hash=41b5e2a99cee]
    public func imageGetInfo(_ context: NativeContextHandle, image: ContextImageHandle) throws -> NativeImageInfo {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_get_info")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_get_info", status: .staleHandle)
            }
            return Self.mapImageInfo(try entry.image.info())
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageEnsureEncodedPng [status=implemented hash=de77be1379dc]
    public func imageEnsureEncodedPng(_ context: NativeContextHandle, image: ContextImageHandle) throws -> Int {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_ensure_encoded_png")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_ensure_encoded_png", status: .staleHandle)
            }
            try entry.image.ensureEncodedPng()
            return try entry.image.encodePNG().count
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageCopyPng [status=implemented hash=bfccaef6e446]
    public func imageCopyPng(_ context: NativeContextHandle, image: ContextImageHandle) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_copy_png")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_copy_png", status: .staleHandle)
            }
            return try entry.image.encodePNG()
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageTakePixels [status=implemented hash=8f1a22ea3032]
    public func imageTakePixels(
        _ context: NativeContextHandle,
        image: ContextImageHandle
    ) throws -> (handle: ContextImagePixelsHandle, raw: RawImage) {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_take_pixels")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_take_pixels", status: .staleHandle)
            }
            let owned = try entry.image.takeRaw()
            let raw = owned.asRawImage()
            let h = ctx.allocateHandle()
            ctx.imagePixels[h.slot] = (h.generation, owned)
            return (ContextImagePixelsHandle(h), raw)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageReleasePixels [status=implemented hash=f22a9e3a5647]
    public func imageReleasePixels(_ context: NativeContextHandle, pixels: ContextImagePixelsHandle) {
        lock.withLock { store in
            guard let ctx = store.contexts[context.contextId] else { return }
            if let entry = ctx.imagePixels.removeValue(forKey: pixels.slot) {
                entry.raw.dispose()
            }
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageClone [status=implemented hash=cc010e2264a4]
    public func imageClone(_ context: NativeContextHandle, image: ContextImageHandle) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_clone")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_clone", status: .staleHandle)
            }
            let cloned = try entry.image.clone()
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, cloned, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageCopyPixels [status=implemented hash=b72cd5eae553]
    public func imageCopyPixels(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        format: PixelFormat = .rgba8
    ) throws -> [UInt8] {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_copy_pixels")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_copy_pixels", status: .staleHandle)
            }
            return try entry.image.raw(format: format).data
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageResize [status=implemented hash=13ab4e87551c]
    public func imageResize(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        options: ResizeOptions
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_resize")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_resize", status: .staleHandle)
            }
            let resized = try entry.image.resize(options)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, resized, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageExtract [status=implemented hash=19930fb52658]
    public func imageExtract(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        options: ExtractOptions
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_extract")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_extract", status: .staleHandle)
            }
            let extracted = try entry.image.extract(options)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, extracted, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageExtend [status=implemented hash=ffe975437acf]
    public func imageExtend(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        options: ExtendOptions
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_extend")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_extend", status: .staleHandle)
            }
            let extended = try entry.image.extend(options)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, extended, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageTransform [status=implemented hash=afe80d4a6049]
    public func imageTransform(
        _ context: NativeContextHandle,
        image: ContextImageHandle,
        operation: String
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_transform")
            guard let entry = ctx.images[image.slot], entry.generation == image.generation else {
                throw NativeError(operation: "ot_image_transform", status: .staleHandle)
            }
            let transformed: NativeImage
            switch operation {
            case "rotate90": transformed = try entry.image.rotate(90)
            case "rotate180": transformed = try entry.image.rotate(180)
            case "rotate270": transformed = try entry.image.rotate(270)
            case "flip": transformed = try entry.image.flip()
            case "flop": transformed = try entry.image.flop()
            default: transformed = try entry.image.clone()
            }
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, transformed, 1)
            return ContextImageHandle(h)
        }
    }

    // parity: core/src/zig.ts#FFIRenderLib.imageComposite [status=implemented hash=02a721fc74a4]
    public func imageComposite(
        _ context: NativeContextHandle,
        base: ContextImageHandle,
        overlay: ContextImageHandle,
        options: CompositeOptions = CompositeOptions()
    ) throws -> ContextImageHandle {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "ot_image_composite")
            guard let baseEntry = ctx.images[base.slot], baseEntry.generation == base.generation,
                  let overlayEntry = ctx.images[overlay.slot], overlayEntry.generation == overlay.generation else {
                throw NativeError(operation: "ot_image_composite", status: .staleHandle)
            }
            let composed = try baseEntry.image.composite(overlayEntry.image, options: options)
            let h = ctx.allocateHandle()
            ctx.images[h.slot] = (h.generation, composed, 1)
            return ContextImageHandle(h)
        }
    }
}

// MARK: - Ergonomic High-Level Convenience Facade on SwiftRenderLib

extension SwiftRenderLib {
    /// Creates a new renderer context + attached session in one step.
    public func createRenderer(
        width: Int,
        height: Int
    ) throws -> (context: NativeContextHandle, session: SessionHandle) {
        let ctx = try createContext()
        let session = try createSession(ctx)
        try sessionAttachRenderer(ctx, session: session, options: NativeSessionRendererOptions(width: width, height: height))
        return (ctx, session)
    }

    /// Destroys a renderer session and its owning context.
    public func destroyRenderer(context: NativeContextHandle, session: SessionHandle) {
        destroySession(context, session: session)
        destroyContext(context)
    }

    /// Creates an `OptimizedBuffer` handle inside a context.
    public func createOptimizedBuffer(
        _ context: NativeContextHandle,
        width: Int,
        height: Int,
        respectAlpha: Bool = false
    ) throws -> ContextBufferHandle {
        try createContextBuffer(
            context,
            options: NativeContextBufferOptions(width: width, height: height, respectAlpha: respectAlpha)
        )
    }

    /// Clears a context buffer with the specified background color.
    public func bufferClear(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle,
        background: RGBA = RGBA.fromInts(0, 0, 0, 255)
    ) throws {
        try contextDrawBuffer(.buffer(context: context, target: buffer), draw: .clear(background: background))
    }

    /// Draws text onto a context buffer.
    public func bufferDrawText(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle,
        text: String,
        x: Int,
        y: Int,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) throws {
        try contextDrawBuffer(
            .buffer(context: context, target: buffer),
            draw: .text(x: x, y: y, text: text, foreground: fg, background: bg, attributes: attributes, maxWidth: nil, ellipsis: false)
        )
    }

    /// Fills a rectangle on a context buffer.
    public func bufferFillRect(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        bg: RGBA
    ) throws {
        try contextDrawBuffer(
            .buffer(context: context, target: buffer),
            draw: .fill(x: x, y: y, width: width, height: height, background: bg)
        )
    }

    /// Draws a box with optional title on a context buffer.
    public func bufferDrawBox(
        _ context: NativeContextHandle,
        buffer: ContextBufferHandle,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        fg: RGBA = .defaultForeground(),
        bg: RGBA = RGBA.fromInts(0, 0, 0, 0),
        title: String? = nil
    ) throws {
        try contextDrawBuffer(
            .buffer(context: context, target: buffer),
            draw: .box(
                x: x,
                y: y,
                width: width,
                height: height,
                foreground: fg,
                background: bg,
                titleColor: nil,
                packedOptions: UInt32(NativeABI.OT_BORDER_ALL),
                borderChars: nil,
                text: title,
                bottomTitle: nil
            )
        )
    }

    /// Reads the rendered plain text of a context buffer for inspection and testing.
    public func bufferPlainText(_ context: NativeContextHandle, buffer: ContextBufferHandle) throws -> String {
        try lock.withLock { store in
            let ctx = try requireContext(store, context, op: "bufferPlainText")
            guard let entry = ctx.buffers[buffer.slot], entry.generation == buffer.generation else {
                throw NativeError(operation: "bufferPlainText", status: .staleHandle)
            }
            return entry.buffer.getPlainText()
        }
    }

    public func createTextBuffer(_ context: NativeContextHandle) throws -> ContextTextBufferHandle {
        try createContextTextBuffer(context)
    }

    public func textBufferSetText(
        _ context: NativeContextHandle,
        textBuffer: ContextTextBufferHandle,
        text: String
    ) throws {
        try contextTextBufferSetText(context, textBuffer: textBuffer, text: text)
    }

    public func createEditBuffer(_ context: NativeContextHandle) throws -> ContextEditBufferHandle {
        try createContextEditBuffer(context)
    }

    public func editBufferInsertText(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        text: String
    ) throws {
        try contextEditBufferInsertText(context, editBuffer: editBuffer, text: text)
    }

    public func createEditorView(
        _ context: NativeContextHandle,
        editBuffer: ContextEditBufferHandle,
        width: Int = 80,
        height: Int = 24
    ) throws -> ContextEditorViewHandle {
        try createContextEditorView(context, editBuffer: editBuffer, width: width, height: height)
    }

    public func createSyntaxStyle(_ context: NativeContextHandle) throws -> ContextSyntaxStyleHandle {
        try createContextSyntaxStyle(context)
    }

    public func registerSyntaxStyle(
        _ context: NativeContextHandle,
        style: ContextSyntaxStyleHandle,
        name: String,
        definition: NativeEditorStyle
    ) throws -> UInt32 {
        try contextSyntaxStyleRegister(context, style: style, name: name, definition: definition)
    }

    public func sceneCreate(_ context: NativeContextHandle) throws -> SceneNodeHandle {
        try sceneCreateNode(context, kind: UInt32(NativeABI.OT_SCENE_ROOT), num: 1)
    }

    public func sessionCreate(_ context: NativeContextHandle) throws -> SessionHandle {
        try createSession(context)
    }
}

/// Source-compatibility alias matching upstream `FFIRenderLib`.
public typealias FFIRenderLib = SwiftRenderLib

// MARK: - Module-Level RenderLib Resolution

private final class RenderLibRegistry {
    var libPath: String?
    var instance: SwiftRenderLib?
}

private let renderLibRegistryLock = Mutex<RenderLibRegistry>(RenderLibRegistry())

/// Creates a fresh isolated pure-Swift `SwiftRenderLib` instance.
public func createRenderLib(ffiRuntime: SwiftFFIRuntime = .shared) -> SwiftRenderLib {
    SwiftRenderLib(ffiRuntime: ffiRuntime)
}

/// Overrides the active singleton `SwiftRenderLib` instance (or resets to default when `nil`).
public func setRenderLib(_ lib: SwiftRenderLib?) {
    renderLibRegistryLock.withLock { reg in
        reg.instance = lib
    }
}

// parity: core/src/zig.ts#setRenderLibPath [status=adapted hash=136bf0c248b9]
public func setRenderLibPath(_ libPath: String?) {
    renderLibRegistryLock.withLock { reg in
        reg.libPath = libPath
    }
}

// parity: core/src/zig.ts#resolveRenderLib [status=implemented hash=373b234c1e27]
public func resolveRenderLib() -> SwiftRenderLib {
    renderLibRegistryLock.withLock { reg in
        if let existing = reg.instance {
            return existing
        }
        let created = SwiftRenderLib()
        reg.instance = created
        return created
    }
}
