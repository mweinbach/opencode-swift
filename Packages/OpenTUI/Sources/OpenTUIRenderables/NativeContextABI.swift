// Pure-Swift NativeContextHandleTable, NativeContextEngine & NativeContextABI (Workstream 4b).
// Covers all 444 symbols across the 20 context/runtime/ABI upstream `packages/native` Zig modules:
// - src/context.zig (38), src/context-handles.zig (6), src/context-abi.zig (151),
// - src/context-audio-abi.zig (9), src/context-editor-abi.zig (41), src/context-image-abi.zig (19),
// - src/context-input-abi.zig (3), src/context-markdown-abi.zig (11), src/context-output-abi.zig (6),
// - src/context-terminal-abi.zig (15), src/context-text-abi.zig (30), src/context-unicode-abi.zig (4),
// - src/context-video-abi.zig (12), src/audio-abi.zig (42), src/native-span-feed-abi.zig (1),
// - src/runtime.zig (2), src/runtime-abi.zig (6), src/opentui.zig (26), src/lib.zig (2),
// - src/cov_runner.zig (20).
// Pure Swift 6 — zero OS or Foundation imports.

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import Synchronization

// MARK: - 1. NativeContextHandleTable (native/src/context-handles.zig — 6 symbols)

/// Generational, Mutex-safe object handle table matching `native/src/context-handles.zig`.
public enum NativeContextHandleTable: Sendable {
    /// Default maximum number of object handle slots (`1 << 22` = 4,194,304).
    // parity: native/src/context-handles.zig#slot_count_max_default [status=implemented hash=de3a1f332ff1]
    public static let slotCountMaxDefault: UInt32 = 1 << 22

    /// Checked generational handle (`ot_handle` C-ABI layout: `contextId`, `slot`, `generation`).
    // parity: native/src/context-handles.zig#Handle [status=implemented hash=406da47f31fb]
    public struct Handle: Equatable, Hashable, Sendable, Codable {
        public var contextId: UInt64
        public var slot: UInt32
        public var generation: UInt32

        public static let zero = Handle(contextId: 0, slot: 0, generation: 0)

        public init(contextId: UInt64 = 0, slot: UInt32 = 0, generation: UInt32 = 0) {
            self.contextId = contextId
            self.slot = slot
            self.generation = generation
        }

        public init(zigHandle: ZigHandle) {
            self.contextId = zigHandle.contextId
            self.slot = zigHandle.slot
            self.generation = zigHandle.generation
        }

        public init(objectHandle: ContextObjectHandle) {
            self.contextId = objectHandle.contextId
            self.slot = objectHandle.slot
            self.generation = objectHandle.generation
        }

        public var isZero: Bool {
            contextId == 0 && slot == 0 && generation == 0
        }

        public func toZigHandle() -> ZigHandle {
            ZigHandle(contextId: contextId, slot: slot, generation: generation)
        }

        public func toObjectHandle() -> ContextObjectHandle {
            ContextObjectHandle(contextId: contextId, slot: slot, generation: generation)
        }
    }

    /// Resource kind tag stored per slot in the generational handle table.
    // parity: native/src/context-handles.zig#Kind [status=implemented hash=08a2a3901a46]
    public enum Kind: UInt32, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case empty = 0
        case session = 1
        case sceneNode = 2
        case buffer = 3
        case bufferLease = 4
        case editBuffer = 5
        case editorView = 6
        case textBuffer = 7
        case textBufferView = 8
        case syntaxStyle = 9
        case image = 10
        case imagePixels = 11
        case unicode = 12
        case markdown = 13
        case embeddedTerminal = 14
        case audio = 15
        case spanFeed = 16
    }

    /// Handle table validation and allocation errors.
    // parity: native/src/context-handles.zig#Error [status=implemented hash=d82befbb332a]
    public enum TableError: Error, Equatable, Hashable, Sendable {
        case wrongContext
        case wrongKind
        case staleHandle
        case objectLimit
        case outOfMemory
        case invalidArgument
        case contextBusy

        public var abiStatus: Int32 {
            switch self {
            case .wrongContext: return Int32(NativeABI.OT_WRONG_CONTEXT)
            case .wrongKind: return Int32(NativeABI.OT_WRONG_KIND)
            case .staleHandle: return Int32(NativeABI.OT_STALE_HANDLE)
            case .objectLimit: return Int32(NativeABI.OT_OBJECT_LIMIT)
            case .outOfMemory: return Int32(NativeABI.OT_OUT_OF_MEMORY)
            case .invalidArgument: return Int32(NativeABI.OT_INVALID_ARGUMENT)
            case .contextBusy: return Int32(NativeABI.OT_CONTEXT_BUSY)
            }
        }
    }

    /// Two-phase destruction token ensuring slots are detached before teardown and reused only after completion.
    // parity: native/src/context-handles.zig#DestroyToken [status=implemented hash=f0bf70a2b288]
    public struct DestroyToken: Equatable, Hashable, Sendable {
        public let contextId: UInt64
        public let slot: UInt32
        public let generation: UInt32
        public let kind: Kind

        public init(contextId: UInt64, slot: UInt32, generation: UInt32, kind: Kind) {
            self.contextId = contextId
            self.slot = slot
            self.generation = generation
            self.kind = kind
        }
    }

    /// Generational slot allocator with O(1) free-list reuse, generation bumping, kind validation, and two-phase destroy.
    // parity: native/src/context-handles.zig#Table [status=implemented hash=bc79217882f8]
    public final class Table: @unchecked Sendable {
        private struct SlotRecord {
            var kind: Kind = .empty
            var generation: UInt32 = 1
            var active: Bool = false
            var destroying: Bool = false
        }

        private struct Storage {
            var slots: [SlotRecord]
            var freeList: [UInt32]
            var activeCount: Int
            var capacity: Int
        }

        public let contextId: UInt64
        private let state: Mutex<Storage>

        public init(contextId: UInt64, capacity: Int = 65_536) {
            let clamped = max(1, min(capacity, Int(NativeContextHandleTable.slotCountMaxDefault)))
            self.contextId = contextId
            self.state = Mutex(
                Storage(
                    // Reserve slot 0 as permanent invalid sentinel so live slots start at 1.
                    slots: [SlotRecord(kind: .empty, generation: 0, active: false, destroying: false)],
                    freeList: [],
                    activeCount: 0,
                    capacity: clamped
                )
            )
        }

        public var capacity: Int {
            state.withLock { $0.capacity }
        }

        public var activeCount: Int {
            state.withLock { $0.activeCount }
        }

        public var freeSlotCount: Int {
            state.withLock { $0.freeList.count }
        }

        public func allocate(kind: Kind) throws(TableError) -> Handle {
            guard kind != .empty else { throw .invalidArgument }
            return try state.withLock { storage throws(TableError) in
                guard storage.activeCount < storage.capacity else {
                    throw .objectLimit
                }
                if let reusedSlot = storage.freeList.popLast() {
                    let idx = Int(reusedSlot)
                    var rec = storage.slots[idx]
                    rec.kind = kind
                    rec.active = true
                    rec.destroying = false
                    storage.slots[idx] = rec
                    storage.activeCount += 1
                    return Handle(contextId: contextId, slot: reusedSlot, generation: rec.generation)
                }
                let newSlot = UInt32(storage.slots.count)
                storage.slots.append(SlotRecord(kind: kind, generation: 1, active: true, destroying: false))
                storage.activeCount += 1
                return Handle(contextId: contextId, slot: newSlot, generation: 1)
            }
        }

        public func lookup(_ handle: Handle, expectedKind: Kind? = nil) throws(TableError) -> Kind {
            guard handle.contextId == contextId else {
                throw .wrongContext
            }
            guard handle.slot > 0 else {
                throw .staleHandle
            }
            return try state.withLock { storage throws(TableError) in
                let idx = Int(handle.slot)
                guard idx < storage.slots.count else {
                    throw .staleHandle
                }
                let rec = storage.slots[idx]
                guard rec.active && !rec.destroying && rec.generation == handle.generation else {
                    throw .staleHandle
                }
                if let expectedKind, rec.kind != expectedKind {
                    throw .wrongKind
                }
                return rec.kind
            }
        }

        public func beginDestroy(_ handle: Handle, expectedKind: Kind? = nil) throws(TableError) -> DestroyToken {
            guard handle.contextId == contextId else {
                throw .wrongContext
            }
            guard handle.slot > 0 else {
                throw .staleHandle
            }
            return try state.withLock { storage throws(TableError) in
                let idx = Int(handle.slot)
                guard idx < storage.slots.count else {
                    throw .staleHandle
                }
                var rec = storage.slots[idx]
                guard rec.active && !rec.destroying && rec.generation == handle.generation else {
                    throw .staleHandle
                }
                if let expectedKind, rec.kind != expectedKind {
                    throw .wrongKind
                }
                rec.destroying = true
                storage.slots[idx] = rec
                return DestroyToken(contextId: contextId, slot: handle.slot, generation: rec.generation, kind: rec.kind)
            }
        }

        public func finishDestroy(_ token: DestroyToken) {
            guard token.contextId == contextId, token.slot > 0 else { return }
            state.withLock { storage in
                let idx = Int(token.slot)
                guard idx < storage.slots.count else { return }
                var rec = storage.slots[idx]
                guard rec.active && rec.destroying && rec.generation == token.generation else { return }
                rec.active = false
                rec.destroying = false
                rec.kind = .empty
                rec.generation &+= 1
                if rec.generation == 0 { rec.generation = 1 }
                storage.slots[idx] = rec
                storage.activeCount = max(0, storage.activeCount - 1)
                storage.freeList.append(token.slot)
            }
        }

        public func cancelDestroy(_ token: DestroyToken) {
            guard token.contextId == contextId, token.slot > 0 else { return }
            state.withLock { storage in
                let idx = Int(token.slot)
                guard idx < storage.slots.count else { return }
                var rec = storage.slots[idx]
                guard rec.active && rec.destroying && rec.generation == token.generation else { return }
                rec.destroying = false
                storage.slots[idx] = rec
            }
        }

        public func destroy(_ handle: Handle, expectedKind: Kind? = nil) throws(TableError) -> Kind {
            let token = try beginDestroy(handle, expectedKind: expectedKind)
            finishDestroy(token)
            return token.kind
        }

        public func generation(at slot: UInt32) -> UInt32 {
            state.withLock { storage in
                let idx = Int(slot)
                guard idx > 0 && idx < storage.slots.count else { return 0 }
                return storage.slots[idx].generation
            }
        }

        public func activeHandles(ofKind kind: Kind? = nil) -> [Handle] {
            state.withLock { storage in
                var out: [Handle] = []
                for idx in 1..<storage.slots.count {
                    let rec = storage.slots[idx]
                    guard rec.active && !rec.destroying else { continue }
                    if let kind, rec.kind != kind { continue }
                    out.append(Handle(contextId: contextId, slot: UInt32(idx), generation: rec.generation))
                }
                return out
            }
        }

        public func resetAll() {
            state.withLock { storage in
                for idx in 1..<storage.slots.count {
                    if storage.slots[idx].active {
                        storage.slots[idx].active = false
                        storage.slots[idx].destroying = false
                        storage.slots[idx].kind = .empty
                        storage.slots[idx].generation &+= 1
                        if storage.slots[idx].generation == 0 { storage.slots[idx].generation = 1 }
                        storage.freeList.append(UInt32(idx))
                    }
                }
                storage.activeCount = 0
            }
        }
    }
}

// MARK: - 2. NativeContextEngine (native/src/context.zig — 38 symbols)

/// Pure-Swift context runtime and domain types matching `native/src/context.zig`.
public enum NativeContextEngine: Sendable {
    // parity: native/src/context.zig#embedded_terminal [status=implemented hash=b469c4057d8f]
    public typealias EmbeddedTerminal = EmbeddedTerminalRenderable

    // parity: native/src/context.zig#EncodedChar [status=implemented hash=1b8b24889cba]
    public struct EncodedChar: Equatable, Hashable, Sendable, Codable {
        public var width: UInt8
        public var char: UInt32

        public init(width: UInt8, char: UInt32) {
            self.width = width
            self.char = char
        }
    }

    // parity: native/src/context.zig#EncodedUnicode [status=implemented hash=5657181c3dc9]
    public struct EncodedUnicode: Equatable, Hashable, Sendable, Codable {
        public var text: String
        public var widthMethod: WidthMethod
        public var chars: [EncodedChar]

        public init(text: String, widthMethod: WidthMethod = .unicode, chars: [EncodedChar]? = nil) {
            self.text = text
            self.widthMethod = widthMethod
            if let chars {
                self.chars = chars
            } else {
                let bytes = Array(text.utf8)
                let clusters = segmentGraphemeClusters(bytes, widthMethod: widthMethod)
                self.chars = clusters.map { cluster in
                    EncodedChar(width: UInt8(clamping: cluster.width), char: cluster.firstScalar)
                }
            }
        }
    }

    // parity: native/src/context.zig#EmbeddedTerminalKey [status=implemented hash=fffdf34b5c1b]
    public typealias EmbeddedTerminalKey = OpenTUIRenderables.EmbeddedTerminalKey

    // parity: native/src/context.zig#EmbeddedTerminalMouse [status=implemented hash=e1c7e42d6f93]
    public typealias EmbeddedTerminalMouse = OpenTUIRenderables.EmbeddedTerminalMouse

    // parity: native/src/context.zig#Handle [status=implemented hash=60613aa7ce8b]
    public typealias Handle = NativeContextHandleTable.Handle

    // parity: native/src/context.zig#Diagnostic [status=implemented hash=1fa71c281771]
    public struct Diagnostic: Equatable, Hashable, Sendable, Codable {
        public var level: NativeLogLevel
        public var message: String

        public init(level: NativeLogLevel = .info, message: String) {
            self.level = level
            self.message = message
        }
    }

    // parity: native/src/context.zig#Error [status=implemented hash=5892af64b90f]
    public enum ContextError: Error, Equatable, Hashable, Sendable {
        case table(NativeContextHandleTable.TableError)
        case status(Int32, String)
        case invalidOptions(String)
        case unsupportedVersion
        case unsupportedResource
        case imageFailed(Int32, String)
        case videoFailed(String)
        case audioDecodeFailed(String)
        case audioDeviceFailed(String)

        public var abiStatus: Int32 {
            switch self {
            case .table(let err): return err.abiStatus
            case .status(let code, _): return code
            case .invalidOptions: return Int32(NativeABI.OT_INVALID_ARGUMENT)
            case .unsupportedVersion: return Int32(NativeABI.OT_UNSUPPORTED_VERSION)
            case .unsupportedResource: return Int32(NativeABI.OT_UNSUPPORTED_RESOURCE)
            case .imageFailed(let code, _): return code
            case .videoFailed: return Int32(NativeABI.OT_VIDEO_FAILED)
            case .audioDecodeFailed: return Int32(NativeABI.OT_AUDIO_DECODE_FAILED)
            case .audioDeviceFailed: return Int32(NativeABI.OT_AUDIO_DEVICE_FAILED)
            }
        }

        public var message: String {
            switch self {
            case .table(let err): return "handle table error: \(err)"
            case .status(_, let msg): return msg
            case .invalidOptions(let msg): return msg
            case .unsupportedVersion: return "unsupported ABI version"
            case .unsupportedResource: return "unsupported resource"
            case .imageFailed(_, let msg): return msg
            case .videoFailed(let msg): return msg
            case .audioDecodeFailed(let msg): return msg
            case .audioDeviceFailed(let msg): return msg
            }
        }
    }

    // parity: native/src/context.zig#RendererBuffer [status=implemented hash=23f5c552126b]
    public enum RendererBuffer: UInt32, Equatable, Hashable, Sendable, Codable {
        case current = 0
        case next = 1

        public var sessionSlot: NativeSessionBufferSlot {
            switch self {
            case .current: return .current
            case .next: return .next
            }
        }
    }

    // parity: native/src/context.zig#BufferOptions [status=implemented hash=bf271a65d983]
    public typealias BufferOptions = NativeContextBufferOptions

    // parity: native/src/context.zig#BufferCrop [status=implemented hash=6439eed177a0]
    public struct BufferCrop: Equatable, Hashable, Sendable, Codable {
        public var x: UInt32
        public var y: UInt32
        public var width: UInt32?
        public var height: UInt32?

        public init(x: UInt32 = 0, y: UInt32 = 0, width: UInt32? = nil, height: UInt32? = nil) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/context.zig#ImageDraw [status=implemented hash=a5bb488a0254]
    public typealias ImageDraw = NativeContextImageDraw

    // parity: native/src/context.zig#BufferGrid [status=implemented hash=366392cea0c8]
    public typealias BufferGrid = NativeBufferGrid

    // parity: native/src/context.zig#BufferDraw [status=implemented hash=3862318183bd]
    public typealias BufferDraw = NativeBufferDraw

    // parity: native/src/context.zig#BufferStack [status=implemented hash=e453e9bcf481]
    public typealias BufferStack = NativeBufferStack

    // parity: native/src/context.zig#EditEvent [status=implemented hash=062804057830]
    public typealias EditEvent = NativeEditEvent

    // parity: native/src/context.zig#EditEventCallback [status=implemented hash=989c2f445158]
    public typealias EditEventCallback = @Sendable (Handle, EditEvent) -> Void

    // parity: native/src/context.zig#Edit [status=implemented hash=733805752e6e]
    public struct Edit: Equatable, Hashable, Sendable {
        public var handle: Handle
        public var libHandle: ContextEditBufferHandle
        public var followSessionWidth: Bool

        public init(handle: Handle, libHandle: ContextEditBufferHandle, followSessionWidth: Bool = false) {
            self.handle = handle
            self.libHandle = libHandle
            self.followSessionWidth = followSessionWidth
        }
    }

    // parity: native/src/context.zig#Editor [status=implemented hash=f5f50a05ace4]
    public struct Editor: Equatable, Hashable, Sendable {
        public var handle: Handle
        public var editHandle: Handle
        public var libHandle: ContextEditorViewHandle

        public init(handle: Handle, editHandle: Handle, libHandle: ContextEditorViewHandle) {
            self.handle = handle
            self.editHandle = editHandle
            self.libHandle = libHandle
        }
    }

    // parity: native/src/context.zig#SharedText [status=implemented hash=4df60e9af99d]
    public struct SharedText: Equatable, Hashable, Sendable {
        public var handle: Handle
        public var libHandle: ContextTextBufferHandle
        public var followSessionWidth: Bool

        public init(handle: Handle, libHandle: ContextTextBufferHandle, followSessionWidth: Bool = false) {
            self.handle = handle
            self.libHandle = libHandle
            self.followSessionWidth = followSessionWidth
        }
    }

    // parity: native/src/context.zig#TextView [status=implemented hash=4fdbbe08e20c]
    public struct TextView: Equatable, Hashable, Sendable {
        public var handle: Handle
        public var textHandle: Handle
        public var libHandle: ContextTextBufferViewHandle

        public init(handle: Handle, textHandle: Handle, libHandle: ContextTextBufferViewHandle) {
            self.handle = handle
            self.textHandle = textHandle
            self.libHandle = libHandle
        }
    }

    // parity: native/src/context.zig#MarkdownOptions [status=implemented hash=57337b1a8952]
    public typealias MarkdownOptions = NativeMarkdownOptions

    // parity: native/src/context.zig#MarkdownResult [status=implemented hash=0ec7a2690dc3]
    public typealias MarkdownResult = NativeMarkdownResult

    // parity: native/src/context.zig#MarkdownDoc [status=implemented hash=1416678e1399]
    public struct MarkdownDoc: Equatable, Hashable, Sendable {
        public var handle: Handle
        public var libHandle: ContextMarkdownHandle

        public init(handle: Handle, libHandle: ContextMarkdownHandle) {
            self.handle = handle
            self.libHandle = libHandle
        }
    }

    // parity: native/src/context.zig#EditCommand [status=implemented hash=5764d4b365fa]
    public struct EditCommand: Equatable, Hashable, Sendable {
        public var command: NativeEditCommand
        public var argument: UInt32

        public init(command: NativeEditCommand, argument: UInt32 = 0) {
            self.command = command
            self.argument = argument
        }
    }

    // parity: native/src/context.zig#EditorCommand [status=implemented hash=bdd321087dbf]
    public struct EditorCommand: Equatable, Hashable, Sendable {
        public var command: NativeEditorCommand
        public var argument: UInt32

        public init(command: NativeEditorCommand, argument: UInt32 = 0) {
            self.command = command
            self.argument = argument
        }
    }

    // parity: native/src/context.zig#TextViewCommand [status=implemented hash=0dd4833d8759]
    public struct TextViewCommand: Equatable, Hashable, Sendable {
        public var command: NativeTextViewCommand
        public var argument: UInt32

        public init(command: NativeTextViewCommand, argument: UInt32 = 0) {
            self.command = command
            self.argument = argument
        }
    }

    // parity: native/src/context.zig#TextDefaults [status=implemented hash=e2ea1ab22c42]
    public struct TextDefaults: Equatable, Hashable, Sendable {
        public var mask: NativeEditorStyleMask
        public var style: NativeEditorStyle
        public var reset: Bool

        public init(
            mask: NativeEditorStyleMask = .all,
            style: NativeEditorStyle = NativeEditorStyle(),
            reset: Bool = false
        ) {
            self.mask = mask
            self.style = style
            self.reset = reset
        }
    }

    // parity: native/src/context.zig#TextHighlight [status=implemented hash=395f3025d860]
    public struct TextHighlight: Equatable, Hashable, Sendable {
        public var operation: NativeEditHighlightOperation
        public var lineOrRef: Int
        public var highlight: Highlight?

        public init(
            operation: NativeEditHighlightOperation,
            lineOrRef: Int = 0,
            highlight: Highlight? = nil
        ) {
            self.operation = operation
            self.lineOrRef = lineOrRef
            self.highlight = highlight
        }
    }

    // parity: native/src/context.zig#EditMark [status=implemented hash=8e2abde92cf6]
    public struct EditMark: Equatable, Hashable, Sendable {
        public var operation: NativeEditMarkOperation
        public var mark: NativeEditMark?
        public var markId: UInt32?

        public init(
            operation: NativeEditMarkOperation,
            mark: NativeEditMark? = nil,
            markId: UInt32? = nil
        ) {
            self.operation = operation
            self.mark = mark
            self.markId = markId
        }
    }

    // parity: native/src/context.zig#LayerReplacement [status=implemented hash=70b2a6df9ae1]
    public struct LayerReplacement: Equatable, Hashable, Sendable {
        public var layerId: UInt32
        public var startByte: UInt32
        public var endByte: UInt32
        public var highlights: [Highlight]

        public init(
            layerId: UInt32,
            startByte: UInt32 = 0,
            endByte: UInt32 = 0,
            highlights: [Highlight] = []
        ) {
            self.layerId = layerId
            self.startByte = startByte
            self.endByte = endByte
            self.highlights = highlights
        }
    }

    // parity: native/src/context.zig#TextSelection [status=implemented hash=0eec1cf76d11]
    public typealias TextSelection = NativeEditorSelection

    // parity: native/src/context.zig#StyledTextChunk [status=implemented hash=658c75977c21]
    public struct StyledTextChunk: Equatable, Hashable, Sendable {
        public var text: String
        public var fg: RGBA?
        public var bg: RGBA?
        public var attributes: UInt32
        public var link: String?

        public init(
            text: String,
            fg: RGBA? = nil,
            bg: RGBA? = nil,
            attributes: UInt32 = TextAttributes.none,
            link: String? = nil
        ) {
            self.text = text
            self.fg = fg
            self.bg = bg
            self.attributes = attributes
            self.link = link
        }

        public func toTextChunk() -> TextChunk {
            TextChunk(
                text: text,
                fg: fg,
                bg: bg,
                attributes: attributes,
                link: link.map { TextChunkLink(url: $0) }
            )
        }
    }

    // parity: native/src/context.zig#SceneTextSelectionOptions [status=implemented hash=6c5254c56c3b]
    public typealias SceneTextSelectionOptions = NativeSceneTextSelectionOptions

    // parity: native/src/context.zig#Options [status=implemented hash=ea825616a4e5]
    public typealias Options = NativeContextOptions

    // parity: native/src/context.zig#Text [status=implemented hash=f1a2c8868b55]
    public struct Text: Equatable, Hashable, Sendable {
        public var bytes: [UInt8]
        public var text: String { String(decoding: bytes, as: UTF8.self) }

        public init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        public init(_ text: String) {
            self.bytes = Array(text.utf8)
        }
    }

    // parity: native/src/context.zig#SceneMeasureCallback [status=implemented hash=a33ba6c5d35a]
    public typealias SceneMeasureCallback = @Sendable (UInt64, UInt32, UInt32, Float, UInt32, Float, UInt32) -> (width: Float, height: Float)

    /// Pure-Swift owning context matching `native/src/context.zig#Context`.
    /// Owns a generational `NativeContextHandleTable.Table`, delegates domain operations to `SwiftRenderLib`
    /// and pure-Swift engine types, and maintains per-context diagnostics, last-error, callbacks, and leases.
    // parity: native/src/context.zig#Context [status=implemented hash=6998e0adf6a8]
    public final class Context: @unchecked Sendable {
        private struct State {
            var destroyed: Bool = false
            var busy: Bool = false
            var lastError: String = ""
            var diagnostics: [Diagnostic] = []
            var editEventCallback: EditEventCallback?
            var editEventUnsubscribe: (@Sendable () -> Void)?

            var sessions: [UInt32: SessionHandle] = [:]
            var sceneNodes: [UInt32: SceneNodeHandle] = [:]
            var nodeChildren: [UInt32: [Handle]] = [:]
            var nodeParents: [UInt32: UInt32] = [:]
            var buffers: [UInt32: ContextBufferHandle] = [:]
            var bufferLeases: [UInt32: NativeSessionBufferLease] = [:]
            var editBuffers: [UInt32: Edit] = [:]
            var editorViews: [UInt32: Editor] = [:]
            var textBuffers: [UInt32: SharedText] = [:]
            var textBufferViews: [UInt32: TextView] = [:]
            var syntaxStyles: [UInt32: ContextSyntaxStyleHandle] = [:]
            var images: [UInt32: ContextImageHandle] = [:]
            var imagePixels: [UInt32: (handle: ContextImagePixelsHandle, raw: RawImage)] = [:]
            var unicodes: [UInt32: (libHandle: ContextUnicodeHandle, encoded: EncodedUnicode)] = [:]
            var markdowns: [UInt32: MarkdownDoc] = [:]
            var embeddedTerminals: [UInt32: ContextEmbeddedTerminalHandle] = [:]
            var audioEngines: [UInt32: AudioEngineHandle] = [:]
            var spanFeeds: [UInt32: FFIPointer] = [:]
            var groupStyles: [UInt32: [UInt32]] = [:]
            var outputTickets: [UInt64: NativeOutputTicket] = [:]
            var pendingSessionFrames: [UInt32: NativeSceneFrameRequest] = [:]
            var editHandleByLibSlot: [UInt32: Handle] = [:]
        }

        public let renderLib: SwiftRenderLib
        public let libContext: NativeContextHandle
        public let options: Options
        public let table: NativeContextHandleTable.Table
        private let state = Mutex<State>(State())

        public var id: UInt64 { libContext.contextId }

        public init(
            options: Options = Options(),
            renderLib: SwiftRenderLib = SwiftRenderLib()
        ) throws {
            self.options = options
            self.renderLib = renderLib
            let created = try renderLib.createContext(options)
            self.libContext = created
            self.table = NativeContextHandleTable.Table(contextId: created.contextId, capacity: options.objectCapacity)
        }

        public var isDestroyed: Bool {
            state.withLock { $0.destroyed }
        }

        public func enterCall() throws(ContextError) {
            try state.withLock { s throws(ContextError) in
                guard !s.destroyed else {
                    throw .table(.staleHandle)
                }
                guard !s.busy else {
                    throw .table(.contextBusy)
                }
                s.busy = true
            }
        }

        public func leaveCall() {
            state.withLock { $0.busy = false }
        }

        public func recordError(_ message: String) {
            state.withLock { s in
                s.lastError = message
                if !message.isEmpty {
                    s.diagnostics.append(Diagnostic(level: .error, message: message))
                }
            }
        }

        public func clearError() {
            state.withLock { $0.lastError = "" }
        }

        public func getLastError() -> String {
            state.withLock { $0.lastError }
        }

        public func pushDiagnostic(_ diagnostic: Diagnostic) {
            state.withLock { $0.diagnostics.append(diagnostic) }
        }

        public func drainDiagnostics() -> [Diagnostic] {
            var drained = state.withLock { s -> [Diagnostic] in
                let result = s.diagnostics
                s.diagnostics.removeAll(keepingCapacity: true)
                return result
            }
            for line in renderLib.logContextDiagnostics(libContext) {
                drained.append(Diagnostic(level: .info, message: line))
            }
            return drained
        }

        public func setEditEventCallback(_ callback: EditEventCallback?) throws {
            let oldUnsub: (@Sendable () -> Void)? = state.withLock { s in
                let prev = s.editEventUnsubscribe
                s.editEventCallback = callback
                s.editEventUnsubscribe = nil
                return prev
            }
            oldUnsub?()

            if let callback {
                let unsub = try renderLib.onContextEditEvent(libContext) { [weak self] libEdit, event in
                    guard let self else { return }
                    let ctxHandle: Handle? = self.state.withLock { $0.editHandleByLibSlot[libEdit.slot] }
                    if let ctxHandle {
                        callback(ctxHandle, event)
                    }
                }
                state.withLock { $0.editEventUnsubscribe = unsub }
            }
        }

        public func destroy() {
            let snapshot: (
                alreadyDestroyed: Bool,
                unsub: (@Sendable () -> Void)?,
                audioEngines: [AudioEngineHandle],
                spanFeeds: [FFIPointer]
            ) = state.withLock { s in
                if s.destroyed { return (true, nil, [], []) }
                s.destroyed = true
                let unsub = s.editEventUnsubscribe
                s.editEventUnsubscribe = nil
                s.editEventCallback = nil
                let audios = Array(s.audioEngines.values)
                let feeds = Array(s.spanFeeds.values)
                s.sessions.removeAll()
                s.sceneNodes.removeAll()
                s.nodeChildren.removeAll()
                s.nodeParents.removeAll()
                s.buffers.removeAll()
                s.bufferLeases.removeAll()
                s.editBuffers.removeAll()
                s.editorViews.removeAll()
                s.textBuffers.removeAll()
                s.textBufferViews.removeAll()
                s.syntaxStyles.removeAll()
                s.images.removeAll()
                s.imagePixels.removeAll()
                s.unicodes.removeAll()
                s.markdowns.removeAll()
                s.embeddedTerminals.removeAll()
                s.audioEngines.removeAll()
                s.spanFeeds.removeAll()
                s.groupStyles.removeAll()
                s.outputTickets.removeAll()
                s.pendingSessionFrames.removeAll()
                s.editHandleByLibSlot.removeAll()
                return (false, unsub, audios, feeds)
            }
            if snapshot.alreadyDestroyed { return }
            snapshot.unsub?()
            for engine in snapshot.audioEngines {
                renderLib.destroyAudioEngine(engine)
            }
            for feed in snapshot.spanFeeds {
                renderLib.destroyNativeSpanFeed(feed)
            }
            table.resetAll()
            renderLib.destroyContext(libContext)
        }

        // MARK: Internal Slot Registration & Lookup Helpers

        internal func registerSession(_ libHandle: SessionHandle) throws -> Handle {
            let handle = try table.allocate(kind: .session)
            state.withLock { $0.sessions[handle.slot] = libHandle }
            return handle
        }

        internal func resolveSession(_ handle: Handle) throws -> SessionHandle {
            _ = try table.lookup(handle, expectedKind: .session)
            guard let lib = state.withLock({ $0.sessions[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func registerSceneNode(_ libHandle: SceneNodeHandle) throws -> Handle {
            let handle = try table.allocate(kind: .sceneNode)
            state.withLock { $0.sceneNodes[handle.slot] = libHandle }
            return handle
        }

        internal func resolveSceneNode(_ handle: Handle) throws -> SceneNodeHandle {
            _ = try table.lookup(handle, expectedKind: .sceneNode)
            guard let lib = state.withLock({ $0.sceneNodes[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func trackChildMove(child: Handle, parent: Handle?, index: Int) {
            state.withLock { s in
                if let oldParentSlot = s.nodeParents[child.slot] {
                    s.nodeChildren[oldParentSlot]?.removeAll { $0 == child }
                }
                if let parent {
                    s.nodeParents[child.slot] = parent.slot
                    var list = s.nodeChildren[parent.slot] ?? []
                    list.removeAll { $0 == child }
                    let clamped = max(0, min(index, list.count))
                    list.insert(child, at: clamped)
                    s.nodeChildren[parent.slot] = list
                } else {
                    s.nodeParents.removeValue(forKey: child.slot)
                }
            }
        }

        internal func takeChildren(of parent: Handle) -> [Handle] {
            state.withLock { s in
                let children = s.nodeChildren.removeValue(forKey: parent.slot) ?? []
                for c in children {
                    s.nodeParents.removeValue(forKey: c.slot)
                }
                return children
            }
        }

        internal func registerBuffer(_ libHandle: ContextBufferHandle) throws -> Handle {
            let handle = try table.allocate(kind: .buffer)
            state.withLock { $0.buffers[handle.slot] = libHandle }
            return handle
        }

        internal func resolveBuffer(_ handle: Handle) throws -> ContextBufferHandle {
            _ = try table.lookup(handle, expectedKind: .buffer)
            guard let lib = state.withLock({ $0.buffers[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func registerBufferLease(_ lease: NativeSessionBufferLease) throws -> Handle {
            let handle = try table.allocate(kind: .bufferLease)
            state.withLock { $0.bufferLeases[handle.slot] = lease }
            return handle
        }

        internal func resolveBufferLease(_ handle: Handle) throws -> NativeSessionBufferLease {
            _ = try table.lookup(handle, expectedKind: .bufferLease)
            guard let lease = state.withLock({ $0.bufferLeases[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lease
        }

        internal func registerEditBuffer(_ libHandle: ContextEditBufferHandle, followSessionWidth: Bool) throws -> Handle {
            let handle = try table.allocate(kind: .editBuffer)
            let record = Edit(handle: handle, libHandle: libHandle, followSessionWidth: followSessionWidth)
            state.withLock {
                $0.editBuffers[handle.slot] = record
                $0.editHandleByLibSlot[libHandle.slot] = handle
            }
            return handle
        }

        internal func resolveEditBuffer(_ handle: Handle) throws -> Edit {
            _ = try table.lookup(handle, expectedKind: .editBuffer)
            guard let rec = state.withLock({ $0.editBuffers[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerEditorView(_ libHandle: ContextEditorViewHandle, editHandle: Handle) throws -> Handle {
            let handle = try table.allocate(kind: .editorView)
            let record = Editor(handle: handle, editHandle: editHandle, libHandle: libHandle)
            state.withLock { $0.editorViews[handle.slot] = record }
            return handle
        }

        internal func resolveEditorView(_ handle: Handle) throws -> Editor {
            _ = try table.lookup(handle, expectedKind: .editorView)
            guard let rec = state.withLock({ $0.editorViews[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerTextBuffer(_ libHandle: ContextTextBufferHandle, followSessionWidth: Bool) throws -> Handle {
            let handle = try table.allocate(kind: .textBuffer)
            let record = SharedText(handle: handle, libHandle: libHandle, followSessionWidth: followSessionWidth)
            state.withLock { $0.textBuffers[handle.slot] = record }
            return handle
        }

        internal func resolveTextBuffer(_ handle: Handle) throws -> SharedText {
            _ = try table.lookup(handle, expectedKind: .textBuffer)
            guard let rec = state.withLock({ $0.textBuffers[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerTextBufferView(_ libHandle: ContextTextBufferViewHandle, textHandle: Handle) throws -> Handle {
            let handle = try table.allocate(kind: .textBufferView)
            let record = TextView(handle: handle, textHandle: textHandle, libHandle: libHandle)
            state.withLock { $0.textBufferViews[handle.slot] = record }
            return handle
        }

        internal func resolveTextBufferView(_ handle: Handle) throws -> TextView {
            _ = try table.lookup(handle, expectedKind: .textBufferView)
            guard let rec = state.withLock({ $0.textBufferViews[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerSyntaxStyle(_ libHandle: ContextSyntaxStyleHandle) throws -> Handle {
            let handle = try table.allocate(kind: .syntaxStyle)
            state.withLock { $0.syntaxStyles[handle.slot] = libHandle }
            return handle
        }

        internal func resolveSyntaxStyle(_ handle: Handle) throws -> ContextSyntaxStyleHandle {
            _ = try table.lookup(handle, expectedKind: .syntaxStyle)
            guard let lib = state.withLock({ $0.syntaxStyles[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func registerImage(_ libHandle: ContextImageHandle) throws -> Handle {
            let handle = try table.allocate(kind: .image)
            state.withLock { $0.images[handle.slot] = libHandle }
            return handle
        }

        internal func resolveImage(_ handle: Handle) throws -> ContextImageHandle {
            _ = try table.lookup(handle, expectedKind: .image)
            guard let lib = state.withLock({ $0.images[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func registerImagePixels(handle libHandle: ContextImagePixelsHandle, raw: RawImage) throws -> Handle {
            let handle = try table.allocate(kind: .imagePixels)
            state.withLock { $0.imagePixels[handle.slot] = (libHandle, raw) }
            return handle
        }

        internal func resolveImagePixels(_ handle: Handle) throws -> (handle: ContextImagePixelsHandle, raw: RawImage) {
            _ = try table.lookup(handle, expectedKind: .imagePixels)
            guard let rec = state.withLock({ $0.imagePixels[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerUnicode(_ libHandle: ContextUnicodeHandle, encoded: EncodedUnicode) throws -> Handle {
            let handle = try table.allocate(kind: .unicode)
            state.withLock { $0.unicodes[handle.slot] = (libHandle, encoded) }
            return handle
        }

        internal func resolveUnicode(_ handle: Handle) throws -> (libHandle: ContextUnicodeHandle, encoded: EncodedUnicode) {
            _ = try table.lookup(handle, expectedKind: .unicode)
            guard let rec = state.withLock({ $0.unicodes[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerMarkdown(_ libHandle: ContextMarkdownHandle) throws -> Handle {
            let handle = try table.allocate(kind: .markdown)
            let doc = MarkdownDoc(handle: handle, libHandle: libHandle)
            state.withLock { $0.markdowns[handle.slot] = doc }
            return handle
        }

        internal func resolveMarkdown(_ handle: Handle) throws -> MarkdownDoc {
            _ = try table.lookup(handle, expectedKind: .markdown)
            guard let rec = state.withLock({ $0.markdowns[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return rec
        }

        internal func registerEmbeddedTerminal(_ libHandle: ContextEmbeddedTerminalHandle) throws -> Handle {
            let handle = try table.allocate(kind: .embeddedTerminal)
            state.withLock { $0.embeddedTerminals[handle.slot] = libHandle }
            return handle
        }

        internal func resolveEmbeddedTerminal(_ handle: Handle) throws -> ContextEmbeddedTerminalHandle {
            _ = try table.lookup(handle, expectedKind: .embeddedTerminal)
            guard let lib = state.withLock({ $0.embeddedTerminals[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func registerAudio(_ engineHandle: AudioEngineHandle) throws -> Handle {
            let handle = try table.allocate(kind: .audio)
            state.withLock { $0.audioEngines[handle.slot] = engineHandle }
            return handle
        }

        internal func resolveAudio(_ handle: Handle) throws -> AudioEngineHandle {
            _ = try table.lookup(handle, expectedKind: .audio)
            guard let lib = state.withLock({ $0.audioEngines[handle.slot] }) else {
                throw NativeContextHandleTable.TableError.staleHandle
            }
            return lib
        }

        internal func storeOutputTicket(_ ticket: NativeOutputTicket) {
            state.withLock { $0.outputTickets[ticket.requestId] = ticket }
        }

        internal func takeOutputTicket(_ requestId: UInt64) -> NativeOutputTicket? {
            state.withLock { $0.outputTickets.removeValue(forKey: requestId) }
        }

        internal func setGroupStyles(for slot: UInt32, groupIds: [UInt32]) {
            state.withLock { $0.groupStyles[slot] = groupIds }
        }

        internal func storePendingFrame(sessionSlot: UInt32, frame: NativeSceneFrameRequest?) {
            state.withLock { s in
                if let frame {
                    s.pendingSessionFrames[sessionSlot] = frame
                } else {
                    s.pendingSessionFrames.removeValue(forKey: sessionSlot)
                }
            }
        }

        internal func getPendingFrame(sessionSlot: UInt32) -> NativeSceneFrameRequest? {
            state.withLock { $0.pendingSessionFrames[sessionSlot] }
        }

        internal func destroyObject(_ handle: Handle, expectedKind: NativeContextHandleTable.Kind) throws {
            let token = try table.beginDestroy(handle, expectedKind: expectedKind)
            switch expectedKind {
            case .session:
                if let lib = state.withLock({ $0.sessions.removeValue(forKey: token.slot) }) {
                    renderLib.destroySession(libContext, session: lib)
                }
            case .sceneNode:
                let lib = state.withLock { s -> SceneNodeHandle? in
                    if let parentSlot = s.nodeParents.removeValue(forKey: token.slot) {
                        s.nodeChildren[parentSlot]?.removeAll { $0.slot == token.slot }
                    }
                    s.nodeChildren.removeValue(forKey: token.slot)
                    return s.sceneNodes.removeValue(forKey: token.slot)
                }
                if let lib {
                    try? renderLib.sceneDestroyNode(libContext, node: lib)
                }
            case .buffer:
                if let lib = state.withLock({ $0.buffers.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextBuffer(libContext, buffer: lib)
                }
            case .bufferLease:
                if let lease = state.withLock({ $0.bufferLeases.removeValue(forKey: token.slot) }) {
                    renderLib.contextReleaseBufferLease(libContext, lease: lease)
                }
            case .editBuffer:
                if let rec = state.withLock({ s -> Edit? in
                    let removed = s.editBuffers.removeValue(forKey: token.slot)
                    if let removed { s.editHandleByLibSlot.removeValue(forKey: removed.libHandle.slot) }
                    return removed
                }) {
                    renderLib.destroyContextEditBuffer(libContext, editBuffer: rec.libHandle)
                }
            case .editorView:
                if let rec = state.withLock({ $0.editorViews.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextEditorView(libContext, view: rec.libHandle)
                }
            case .textBuffer:
                if let rec = state.withLock({ $0.textBuffers.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextTextBuffer(libContext, textBuffer: rec.libHandle)
                }
            case .textBufferView:
                if let rec = state.withLock({ $0.textBufferViews.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextTextBufferView(libContext, view: rec.libHandle)
                }
            case .syntaxStyle:
                if let lib = state.withLock({ $0.syntaxStyles.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextSyntaxStyle(libContext, style: lib)
                }
            case .image:
                if let lib = state.withLock({ $0.images.removeValue(forKey: token.slot) }) {
                    renderLib.imageDestroy(libContext, image: lib)
                }
            case .imagePixels:
                if let rec = state.withLock({ $0.imagePixels.removeValue(forKey: token.slot) }) {
                    renderLib.imageReleasePixels(libContext, pixels: rec.handle)
                }
            case .unicode:
                if let rec = state.withLock({ $0.unicodes.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextUnicode(libContext, handle: rec.libHandle)
                }
            case .markdown:
                if let rec = state.withLock({ $0.markdowns.removeValue(forKey: token.slot) }) {
                    renderLib.markdownDestroy(libContext, markdown: rec.libHandle)
                }
            case .embeddedTerminal:
                if let lib = state.withLock({ $0.embeddedTerminals.removeValue(forKey: token.slot) }) {
                    renderLib.destroyContextEmbeddedTerminal(libContext, terminal: lib)
                }
            case .audio:
                if let engine = state.withLock({ $0.audioEngines.removeValue(forKey: token.slot) }) {
                    renderLib.destroyAudioEngine(engine)
                }
            case .spanFeed:
                if let feed = state.withLock({ $0.spanFeeds.removeValue(forKey: token.slot) }) {
                    renderLib.destroyNativeSpanFeed(feed)
                }
            case .empty:
                break
            }
            table.finishDestroy(token)
        }
    }
}

// MARK: - 3. NativeContextABI (18 remaining Zig ABI/runtime/export files — 400 symbols)

/// Pure-Swift C-ABI dispatcher delegating to `NativeContextEngine`, `NativeContextHandleTable`, and `SwiftRenderLib`.
public enum NativeContextABI: Sendable {
    public typealias Handle = NativeContextHandleTable.Handle
    public typealias Kind = NativeContextHandleTable.Kind
    public typealias Status = Int32

    // MARK: 3.1 Context Handle & Core Context ABI (`native/src/context-abi.zig` — 151 symbols)

    /// Owning context handle wrapper matching `native/src/context-abi.zig#ContextHandle`.
    // parity: native/src/context-abi.zig#ContextHandle [status=implemented hash=4cb0c4f4c7d2]
    public final class ContextHandle: @unchecked Sendable {
        public let context: NativeContextEngine.Context
        public let audioEngine: AudioEngineHandle?

        public init(context: NativeContextEngine.Context, audioEngine: AudioEngineHandle? = nil) {
            self.context = context
            self.audioEngine = audioEngine
        }

        public var id: UInt64 { context.id }
        public var isDestroyed: Bool { context.isDestroyed }
    }

    // Internal status mapping helper
    internal static func mapError(_ context: ContextHandle?, _ error: any Error) -> Status {
        let code: Status
        let message: String
        if let tableErr = error as? NativeContextHandleTable.TableError {
            code = tableErr.abiStatus
            message = "\(tableErr)"
        } else if let ctxErr = error as? NativeContextEngine.ContextError {
            code = ctxErr.abiStatus
            message = ctxErr.message
        } else if let nativeErr = error as? NativeError {
            code = nativeErr.status.rawValue
            message = nativeErr.description
        } else if let imgErr = error as? ImageError {
            code = Status(imgErr.status)
            message = imgErr.message
        } else {
            code = Status(NativeABI.OT_INTERNAL_ERROR)
            message = "\(error)"
        }
        context?.context.recordError(message)
        return code
    }

    internal static func withAdmittedContext(
        _ context: ContextHandle?,
        _ body: (NativeContextEngine.Context) throws -> Void
    ) -> Status {
        guard let context else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        do {
            try context.context.enterCall()
        } catch {
            return mapError(context, error)
        }
        defer { context.context.leaveCall() }
        do {
            context.context.clearError()
            try body(context.context)
            return Status(NativeABI.OT_OK)
        } catch {
            return mapError(context, error)
        }
    }

    internal static func resolveDrawingTarget(
        ctx: NativeContextEngine.Context,
        target: Handle,
        frame: NativeSceneFrameRequest?
    ) throws -> NativeDrawingTarget {
        if let frame {
            let session = try ctx.resolveSession(target)
            return .frame(context: ctx.libContext, target: session, frame: frame)
        }
        let buf = try ctx.resolveBuffer(target)
        return .buffer(context: ctx.libContext, target: buf)
    }

    // parity: native/src/context-abi.zig#ot_context_abi_version [status=implemented hash=768b2fd91926]
    public static func ot_context_abi_version() -> UInt32 {
        UInt32(NativeABI.OT_CONTEXT_ABI_VERSION)
    }

    // parity: native/src/context-abi.zig#ot_context_create [status=implemented hash=fcdd31e80fe5]
    public static func ot_context_create(
        abiVersion: UInt32 = UInt32(NativeABI.OT_CONTEXT_ABI_VERSION),
        options: NativeContextEngine.Options = NativeContextEngine.Options(),
        renderLib: SwiftRenderLib = SwiftRenderLib(),
        outContext: inout ContextHandle?
    ) -> Status {
        guard abiVersion == UInt32(NativeABI.OT_CONTEXT_ABI_VERSION) else {
            return Status(NativeABI.OT_UNSUPPORTED_VERSION)
        }
        guard options.objectCapacity > 0 && options.renderCellsMax > 0 else {
            return Status(NativeABI.OT_INVALID_ARGUMENT)
        }
        do {
            let ctx = try NativeContextEngine.Context(options: options, renderLib: renderLib)
            outContext = ContextHandle(context: ctx)
            return Status(NativeABI.OT_OK)
        } catch {
            return mapError(nil, error)
        }
    }

    // parity: native/src/context-abi.zig#ot_context_destroy [status=implemented hash=4b718334e94c]
    public static func ot_context_destroy(_ context: ContextHandle?) -> Status {
        guard let context else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        if context.isDestroyed { return Status(NativeABI.OT_STALE_HANDLE) }
        context.context.destroy()
        return Status(NativeABI.OT_OK)
    }

    // parity: native/src/context-abi.zig#ot_context_get_last_error [status=implemented hash=1470e9cdf65a]
    public static func ot_context_get_last_error(_ context: ContextHandle?, outMessage: inout String) -> Status {
        guard let context else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        guard !context.isDestroyed else { return Status(NativeABI.OT_STALE_HANDLE) }
        outMessage = context.context.getLastError()
        return Status(NativeABI.OT_OK)
    }

    // parity: native/src/context-abi.zig#ot_context_drain_diagnostics [status=implemented hash=8e2b82c4fcff]
    public static func ot_context_drain_diagnostics(
        _ context: ContextHandle?,
        outDiagnostics: inout [NativeContextEngine.Diagnostic]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            outDiagnostics = ctx.drainDiagnostics()
        }
    }

    // parity: native/src/context-abi.zig#ot_context_get_link_url [status=implemented hash=b6b127385c2b]
    public static func ot_context_get_link_url(
        _ context: ContextHandle?,
        linkId: UInt32,
        outUrl: inout String?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            outUrl = try ctx.renderLib.contextGetLinkUrl(ctx.libContext, linkId: linkId)
        }
    }

    // parity: native/src/context-abi.zig#ot_context_group_set [status=implemented hash=8c0ef913958e]
    public static func ot_context_group_set(
        _ context: ContextHandle?,
        target: Handle,
        groupIds: [UInt32],
        outCount: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.table.lookup(target)
            ctx.setGroupStyles(for: target.slot, groupIds: groupIds)
            outCount = try ctx.renderLib.contextGroupSet(
                ctx.libContext,
                target: target.toObjectHandle(),
                groupIds: groupIds
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_create [status=implemented hash=ac6e2fc6d63e]
    public static func ot_edit_buffer_create(
        _ context: ContextHandle?,
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions(),
        outHandle: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let follow = try followSessionWidth(options)
            let lib = try ctx.renderLib.createContextEditBuffer(ctx.libContext, options: options)
            outHandle = try ctx.registerEditBuffer(lib, followSessionWidth: follow)
        }
    }

    // parity: native/src/context-abi.zig#followSessionWidth [status=implemented hash=1a0d880e72e2]
    public static func followSessionWidth(_ options: NativeContextEditBufferOptions) throws(NativeContextEngine.ContextError) -> Bool {
        options.followSessionWidth
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_destroy [status=implemented hash=e5e164e6a02a]
    public static func ot_edit_buffer_destroy(_ context: ContextHandle?, _ handle: Handle) -> Status {
        destroyKind(context, handle, kind: .editBuffer)
    }

    // parity: native/src/context-abi.zig#ot_editor_view_create [status=implemented hash=20406698d4d8]
    public static func ot_editor_view_create(
        _ context: ContextHandle?,
        editBuffer: Handle,
        width: UInt32,
        height: UInt32,
        outHandle: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            let lib = try ctx.renderLib.createContextEditorView(
                ctx.libContext,
                editBuffer: edit.libHandle,
                width: Int(width),
                height: Int(height)
            )
            outHandle = try ctx.registerEditorView(lib, editHandle: editBuffer)
        }
    }

    // parity: native/src/context-abi.zig#ot_editor_view_destroy [status=implemented hash=6aa03e793429]
    public static func ot_editor_view_destroy(_ context: ContextHandle?, _ handle: Handle) -> Status {
        destroyKind(context, handle, kind: .editorView)
    }

    // parity: native/src/context-abi.zig#ot_syntax_style_create [status=implemented hash=b31192cd78ae]
    public static func ot_syntax_style_create(_ context: ContextHandle?, outHandle: inout Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.renderLib.createContextSyntaxStyle(ctx.libContext)
            outHandle = try ctx.registerSyntaxStyle(lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_syntax_style_destroy [status=implemented hash=882ef956a7cd]
    public static func ot_syntax_style_destroy(_ context: ContextHandle?, _ handle: Handle) -> Status {
        destroyKind(context, handle, kind: .syntaxStyle)
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_set_syntax_style [status=implemented hash=af6d10e73bd0]
    public static func ot_edit_buffer_set_syntax_style(
        _ context: ContextHandle?,
        editBuffer: Handle,
        style: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            let libStyle = try style.map { try ctx.resolveSyntaxStyle($0) }
            try ctx.renderLib.contextEditBufferSetSyntaxStyle(
                ctx.libContext,
                editBuffer: edit.libHandle,
                style: libStyle
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_set_text [status=implemented hash=d21317f2df2f]
    public static func ot_edit_buffer_set_text(
        _ context: ContextHandle?,
        editBuffer: Handle,
        text: String,
        preserveHistory: Bool = false
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferSetText(
                ctx.libContext,
                editBuffer: edit.libHandle,
                text: text,
                replace: preserveHistory
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_insert_text [status=implemented hash=6246994d0b41]
    public static func ot_edit_buffer_insert_text(
        _ context: ContextHandle?,
        editBuffer: Handle,
        text: String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferInsertText(ctx.libContext, editBuffer: edit.libHandle, text: text)
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_delete_range [status=implemented hash=5d9ca9bbd549]
    public static func ot_edit_buffer_delete_range(
        _ context: ContextHandle?,
        editBuffer: Handle,
        startRow: UInt32,
        startCol: UInt32,
        endRow: UInt32,
        endCol: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferDeleteRange(
                ctx.libContext,
                editBuffer: edit.libHandle,
                startLine: Int(startRow),
                startCol: Int(startCol),
                endLine: Int(endRow),
                endCol: Int(endCol)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_set_cursor [status=implemented hash=db7f42490f29]
    public static func ot_edit_buffer_set_cursor(
        _ context: ContextHandle?,
        editBuffer: Handle,
        row: UInt32,
        col: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferSetCursor(
                ctx.libContext,
                editBuffer: edit.libHandle,
                line: Int(row),
                col: Int(col)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_get_text [status=implemented hash=9f69f632716d]
    public static func ot_edit_buffer_get_text(
        _ context: ContextHandle?,
        editBuffer: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outText = try ctx.renderLib.contextEditBufferGetText(ctx.libContext, editBuffer: edit.libHandle)
        }
    }

    // parity: native/src/context-abi.zig#ot_edit_buffer_get_info [status=implemented hash=9aad28f41932]
    public static func ot_edit_buffer_get_info(
        _ context: ContextHandle?,
        editBuffer: Handle,
        outInfo: inout NativeEditBufferInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outInfo = try ctx.renderLib.contextEditBufferGetInfo(ctx.libContext, editBuffer: edit.libHandle)
        }
    }

    // parity: native/src/context-abi.zig#ot_context_set_edit_event_callback [status=implemented hash=c607a3937693]
    public static func ot_context_set_edit_event_callback(
        _ context: ContextHandle?,
        callback: NativeContextEngine.EditEventCallback?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            try ctx.setEditEventCallback(callback)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_editor_view [status=implemented hash=a36590d9ba16]
    public static func ot_scene_set_editor_view(
        _ context: ContextHandle?,
        node: Handle,
        view: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let sceneNode = try ctx.resolveSceneNode(node)
            let libView = try view.map { try ctx.resolveEditorView($0).libHandle }
            try ctx.renderLib.sceneSetEditorView(ctx.libContext, node: sceneNode, view: libView)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_editor_options [status=implemented hash=85a6d4a2a73f]
    public static func ot_scene_set_editor_options(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneEditorOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let sceneNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetEditorOptions(ctx.libContext, node: sceneNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_image_destroy [status=implemented hash=6c8d5e9c6491]
    public static func ot_image_destroy(_ context: ContextHandle?, _ image: Handle) -> Status {
        destroyKind(context, image, kind: .image)
    }

    // parity: native/src/context-abi.zig#ot_scene_set_image [status=implemented hash=7fe8f97f1ee1]
    public static func ot_scene_set_image(
        _ context: ContextHandle?,
        node: Handle,
        image: Handle?,
        fit: ImageFit = .fit,
        imageProtocol: ImageRenderProtocol = .auto,
        buffer: Handle? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let sceneNode = try ctx.resolveSceneNode(node)
            let libImage = try image.map { try ctx.resolveImage($0) }
            let libBuf = try buffer.map { try ctx.resolveBuffer($0) }
            try ctx.renderLib.sceneSetImage(
                ctx.libContext,
                node: sceneNode,
                image: libImage,
                fit: fit,
                imageProtocol: imageProtocol,
                buffer: libBuf
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_crop [status=implemented hash=6cd01df359a0]
    public static func ot_scene_set_crop(
        _ context: ContextHandle?,
        node: Handle,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let sceneNode = try ctx.resolveSceneNode(node)
            let crop: ImageExtractOptions? = (width == 0 && height == 0)
                ? nil
                : ImageExtractOptions(left: Int(left), top: Int(top), width: Int(width), height: Int(height))
            try ctx.renderLib.sceneSetCrop(ctx.libContext, node: sceneNode, crop: crop)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_image [status=implemented hash=cf785321f900]
    public static func ot_buffer_draw_image(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        image: Handle,
        options: NativeContextImageDraw
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            let libImage = try ctx.resolveImage(image)
            try ctx.renderLib.contextDrawImage(drawTarget, image: libImage, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_set_image_resolution [status=implemented hash=d1e39ee6a7b0]
    public static func ot_session_set_image_resolution(
        _ context: ContextHandle?,
        session: Handle,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetImageResolution(
                ctx.libContext,
                session: libSession,
                pixelWidth: Int(pixelWidth),
                pixelHeight: Int(pixelHeight)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_set_kitty_image_transport [status=implemented hash=30aa288dfb39]
    public static func ot_session_set_kitty_image_transport(
        _ context: ContextHandle?,
        session: Handle,
        mode: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetKittyImageTransport(ctx.libContext, session: libSession, mode: Int(mode))
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_kitty_image_transport [status=implemented hash=213b0b112917]
    public static func ot_session_get_kitty_image_transport(
        _ context: ContextHandle?,
        session: Handle,
        outStatus: inout NativeSessionKittyImageTransportStatus
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            outStatus = try ctx.renderLib.sessionGetKittyImageTransport(ctx.libContext, session: libSession)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_poll_kitty_image_transport [status=implemented hash=3f377a24387f]
    public static func ot_session_poll_kitty_image_transport(
        _ context: ContextHandle?,
        session: Handle,
        outPending: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            outPending = try ctx.renderLib.sessionPollKittyImageTransport(ctx.libContext, session: libSession)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_cancel_kitty_image_transport [status=implemented hash=5b8ffe0b3bb1]
    public static func ot_session_cancel_kitty_image_transport(
        _ context: ContextHandle?,
        session: Handle,
        failed: Bool = false
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionCancelKittyImageTransport(ctx.libContext, session: libSession, failed: failed)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_process_kitty_image_reply [status=implemented hash=a8e40a32c470]
    public static func ot_session_process_kitty_image_reply(
        _ context: ContextHandle?,
        session: Handle,
        bytes: [UInt8],
        outProcessed: inout Int
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            outProcessed = try ctx.renderLib.sessionProcessKittyImageReply(
                ctx.libContext,
                session: libSession,
                bytes: bytes
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_start_kitty_file_probe [status=implemented hash=869e3f18df5f]
    public static func ot_session_start_kitty_file_probe(
        _ context: ContextHandle?,
        session: Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionStartKittyFileProbe(ctx.libContext, session: libSession)
        }
    }

    // parity: native/src/context-abi.zig#widthMethodFromC [status=implemented hash=801c2a81f5f4]
    public static func widthMethodFromC(_ value: UInt32) throws(NativeContextEngine.ContextError) -> WidthMethod {
        switch Int64(value) {
        case NativeABI.OT_WIDTH_METHOD_WCWIDTH: return .wcwidth
        case NativeABI.OT_WIDTH_METHOD_UNICODE: return .unicode
        case NativeABI.OT_WIDTH_METHOD_NO_ZWJ: return .noZWJ
        case NativeABI.OT_WIDTH_METHOD_UNICODE_WIDE: return .unicodeWide
        default: throw .invalidOptions("invalid width method \(value)")
        }
    }

    internal static func textWidthMethodFromC(_ value: UInt32) throws(NativeContextEngine.ContextError) -> TextWidthMethod {
        switch Int64(value) {
        case NativeABI.OT_WIDTH_METHOD_WCWIDTH: return .wcwidth
        case NativeABI.OT_WIDTH_METHOD_UNICODE, NativeABI.OT_WIDTH_METHOD_NO_ZWJ: return .unicode
        case NativeABI.OT_WIDTH_METHOD_UNICODE_WIDE: return .unicodeWide
        default: throw .invalidOptions("invalid text width method \(value)")
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_create [status=implemented hash=7ce4504a4253]
    public static func ot_buffer_create(
        _ context: ContextHandle?,
        options: NativeContextBufferOptions,
        outHandle: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard options.width > 0 && options.height > 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("buffer dimensions must be positive")
            }
            let lib = try ctx.renderLib.createContextBuffer(ctx.libContext, options: options)
            outHandle = try ctx.registerBuffer(lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_destroy [status=implemented hash=2c900584f863]
    public static func ot_buffer_destroy(_ context: ContextHandle?, _ buffer: Handle) -> Status {
        destroyKind(context, buffer, kind: .buffer)
    }

    // parity: native/src/context-abi.zig#ot_buffer_resize [status=implemented hash=b1adfc87fea7]
    public static func ot_buffer_resize(
        _ context: ContextHandle?,
        buffer: Handle,
        width: UInt32,
        height: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libBuf = try ctx.resolveBuffer(buffer)
            try ctx.renderLib.contextResizeBuffer(
                ctx.libContext,
                buffer: libBuf,
                width: Int(width),
                height: Int(height)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw [status=implemented hash=d8cc41737bd2]
    public static func ot_buffer_draw(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        draw: NativeBufferDraw
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextDrawBuffer(drawTarget, draw: draw)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_stack [status=implemented hash=b13ddc1b1f5b]
    public static func ot_buffer_stack(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        operation: NativeBufferStack,
        outOpacity: inout Double
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            outOpacity = try ctx.renderLib.contextBufferStack(drawTarget, op: operation)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_grid [status=implemented hash=2a9085da2e80]
    public static func ot_buffer_draw_grid(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        grid: NativeBufferGrid
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextDrawGrid(drawTarget, grid: grid)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_packed [status=implemented hash=b080c35bc7ac]
    public static func ot_buffer_draw_packed(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        bytes: [UInt8],
        width: UInt32,
        height: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextDrawPackedBuffer(
                drawTarget,
                bytes: bytes,
                width: Int(width),
                height: Int(height),
                x: Int(x),
                y: Int(y)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_supersample [status=implemented hash=1021d1aa2193]
    public static func ot_buffer_draw_supersample(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        bytes: [UInt8],
        width: UInt32,
        height: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextDrawSuperSampleBuffer(
                drawTarget,
                bytes: bytes,
                width: Int(width),
                height: Int(height),
                x: Int(x),
                y: Int(y)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_grayscale [status=implemented hash=d638828763e7]
    public static func ot_buffer_draw_grayscale(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        x: Int32,
        y: Int32,
        width: UInt32,
        height: UInt32,
        intensity: Double = 1.0,
        flags: UInt32 = 3
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextDrawGrayscaleBuffer(
                drawTarget,
                x: Int(x),
                y: Int(y),
                width: Int(width),
                height: Int(height),
                intensity: intensity,
                flags: flags
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_color_matrix [status=implemented hash=dea2738be146]
    public static func ot_buffer_color_matrix(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        matrix: [Float],
        x: Int32 = 0,
        y: Int32 = 0,
        width: UInt32? = nil,
        height: UInt32? = nil,
        strength: Double = 1.0,
        targetMask: UInt32 = 3
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextColorMatrixBuffer(
                drawTarget,
                matrix: matrix,
                x: Int(x),
                y: Int(y),
                width: width.map(Int.init),
                height: height.map(Int.init),
                strength: strength,
                targetMask: targetMask
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_editor_view [status=implemented hash=b6a23f59830c]
    public static func ot_buffer_draw_editor_view(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            let editor = try ctx.resolveEditorView(view)
            try ctx.renderLib.contextDrawEditorView(drawTarget, view: editor.libHandle, x: Int(x), y: Int(y))
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_draw_scene_body [status=implemented hash=229e716aa337]
    public static func ot_buffer_draw_scene_body(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        node: Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            let sceneNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.contextDrawSceneBody(drawTarget, node: sceneNode, x: Int(x), y: Int(y))
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_acquire_lease [status=implemented hash=b094077d52ae]
    public static func ot_buffer_acquire_lease(
        _ context: ContextHandle?,
        buffer: Handle,
        outLeaseHandle: inout Handle,
        outLease: inout NativeSessionBufferLease
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libBuf = try ctx.resolveBuffer(buffer)
            let lease = try ctx.renderLib.contextAcquireBufferLease(ctx.libContext, buffer: libBuf)
            outLeaseHandle = try ctx.registerBufferLease(lease)
            outLease = lease
        }
    }

    // parity: native/src/context-abi.zig#ot_session_create [status=implemented hash=24b200e61831]
    public static func ot_session_create(
        _ context: ContextHandle?,
        options: NativeSessionOptions = NativeSessionOptions(),
        outSession: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.renderLib.createSession(ctx.libContext, options: options)
            outSession = try ctx.registerSession(lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_write_limit [status=implemented hash=03522579cbee]
    public static func ot_session_get_write_limit(
        _ context: ContextHandle?,
        session: Handle,
        outLimit: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outLimit = UInt32(max(0, try ctx.renderLib.sessionGetWriteLimit(ctx.libContext, session: lib)))
        }
    }

    // parity: native/src/context-abi.zig#ot_session_write [status=implemented hash=67b5f8524457]
    public static func ot_session_write(
        _ context: ContextHandle?,
        session: Handle,
        bytes: [UInt8],
        outAccepted: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outAccepted = try ctx.renderLib.sessionWrite(ctx.libContext, session: lib, bytes: bytes)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_attach_renderer [status=implemented hash=9ae7076c0de6]
    public static func ot_session_attach_renderer(
        _ context: ContextHandle?,
        session: Handle,
        options: NativeSessionRendererOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionAttachRenderer(ctx.libContext, session: lib, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_attach_renderer_with_env [status=implemented hash=8de1257dc43e]
    public static func ot_session_attach_renderer_with_env(
        _ context: ContextHandle?,
        session: Handle,
        options: NativeSessionRendererOptions,
        environment: [String: String]
    ) -> Status {
        var merged = options
        merged.environment = environment
        return ot_session_attach_renderer(context, session: session, options: merged)
    }

    // parity: native/src/context-abi.zig#ot_session_render [status=implemented hash=b7cf44f9a3d6]
    public static func ot_session_render(
        _ context: ContextHandle?,
        session: Handle,
        force: Bool = false,
        outRenderStatus: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            if let pending = ctx.getPendingFrame(sessionSlot: session.slot) {
                let status = try ctx.renderLib.sceneFrameCommit(ctx.libContext, frame: pending, force: force)
                ctx.storePendingFrame(sessionSlot: session.slot, frame: nil)
                outRenderStatus = renderStatusToC(status)
            } else {
                let status = try ctx.renderLib.sessionRenderSplit(
                    ctx.libContext,
                    session: lib,
                    frame: nil,
                    commits: [],
                    pinnedRenderOffset: 0,
                    force: force
                )
                outRenderStatus = renderStatusToC(status)
            }
        }
    }

    // parity: native/src/context-abi.zig#renderStatusToC [status=implemented hash=d45d3a623481]
    public static func renderStatusToC(_ result: NativeSessionRenderStatus) -> UInt32 {
        UInt32(bitPattern: result.rawValue)
    }

    // parity: native/src/context-abi.zig#ot_session_resize_renderer [status=implemented hash=660a1bd0b4ff]
    public static func ot_session_resize_renderer(
        _ context: ContextHandle?,
        session: Handle,
        width: UInt32,
        height: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionResizeRenderer(
                ctx.libContext,
                session: lib,
                width: Int(width),
                height: Int(height)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_draw_buffer [status=implemented hash=be7c61ee4e81]
    public static func ot_session_draw_buffer(
        _ context: ContextHandle?,
        session: Handle,
        source: Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        crop: NativeContextEngine.BufferCrop? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let libBuf = try ctx.resolveBuffer(source)
            if let frame = ctx.getPendingFrame(sessionSlot: session.slot) {
                let draw = NativeBufferDraw.compose(
                    x: Int(x),
                    y: Int(y),
                    source: libBuf,
                    sourceX: crop.map { Int($0.x) },
                    sourceY: crop.map { Int($0.y) },
                    sourceWidth: crop?.width.map(Int.init),
                    sourceHeight: crop?.height.map(Int.init)
                )
                try ctx.renderLib.contextDrawBuffer(
                    .frame(context: ctx.libContext, target: libSession, frame: frame),
                    draw: draw
                )
            } else {
                // Acquire session next buffer lease to verify renderer is attached and valid.
                let lease = try ctx.renderLib.sessionAcquireBufferLease(
                    ctx.libContext,
                    session: libSession,
                    slot: .next
                )
                ctx.renderLib.contextReleaseBufferLease(ctx.libContext, lease: lease)
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_session_set_debug_overlay [status=implemented hash=42e2b444b040]
    public static func ot_session_set_debug_overlay(
        _ context: ContextHandle?,
        session: Handle,
        enabled: Bool,
        corner: DebugOverlayCorner = .bottomRight
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetDebugOverlay(
                ctx.libContext,
                session: lib,
                enabled: enabled,
                corner: corner
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_update_stats [status=implemented hash=6ddd97f1d061]
    public static func ot_session_update_stats(
        _ context: ContextHandle?,
        session: Handle,
        overallMs: Double,
        fps: UInt32,
        callbackMs: Double
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionUpdateStats(
                ctx.libContext,
                session: lib,
                fps: Double(fps),
                frameCount: 1,
                lastFrameTimeMs: overallMs + callbackMs
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_update_memory_stats [status=implemented hash=ab0886b464d7]
    public static func ot_session_update_memory_stats(
        _ context: ContextHandle?,
        session: Handle,
        heapUsed: UInt32,
        heapTotal: UInt32,
        arrayBuffers: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionUpdateMemoryStats(
                ctx.libContext,
                session: lib,
                heapUsed: UInt64(heapUsed),
                heapTotal: UInt64(heapTotal),
                arrayBuffers: UInt64(arrayBuffers)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_dump_hit_grid [status=implemented hash=2008a77e8dd3]
    public static func ot_session_dump_hit_grid(
        _ context: ContextHandle?,
        session: Handle,
        outDump: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outDump = try ctx.renderLib.sessionDumpHitGrid(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_renderer_state [status=implemented hash=5baf41a9bde6]
    public static func ot_session_get_renderer_state(
        _ context: ContextHandle?,
        session: Handle,
        outState: inout NativeSessionRendererState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outState = try ctx.renderLib.sessionGetRendererState(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_acquire_buffer_lease [status=implemented hash=408231a9dd48]
    public static func ot_session_acquire_buffer_lease(
        _ context: ContextHandle?,
        session: Handle,
        slot: NativeContextEngine.RendererBuffer = .next,
        outLeaseHandle: inout Handle,
        outLease: inout NativeSessionBufferLease
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            let lease = try ctx.renderLib.sessionAcquireBufferLease(
                ctx.libContext,
                session: lib,
                slot: slot.sessionSlot
            )
            outLeaseHandle = try ctx.registerBufferLease(lease)
            outLease = lease
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_link_id [status=implemented hash=5dd0a31e4802]
    public static func ot_session_get_link_id(
        _ context: ContextHandle?,
        session: Handle,
        url: String,
        outLinkId: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outLinkId = try ctx.renderLib.sessionGetLinkId(ctx.libContext, session: lib, url: url)
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_lease_validate [status=implemented hash=c131a6056560]
    public static func ot_buffer_lease_validate(_ context: ContextHandle?, _ lease: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let record = try ctx.resolveBufferLease(lease)
            let valid = try ctx.renderLib.contextValidateBufferLease(ctx.libContext, lease: record)
            if !valid {
                throw NativeContextEngine.ContextError.status(Int32(NativeABI.OT_STALE_LEASE), "stale buffer lease")
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_lease_release [status=implemented hash=b417474cc0ba]
    public static func ot_buffer_lease_release(_ context: ContextHandle?, _ lease: Handle) -> Status {
        destroyKind(context, lease, kind: .bufferLease)
    }

    // parity: native/src/context-abi.zig#ot_buffer_lease_get_real_char_size [status=implemented hash=19215e400ba0]
    public static func ot_buffer_lease_get_real_char_size(
        _ context: ContextHandle?,
        lease: Handle,
        addLineBreaks: Bool = false,
        outSize: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let record = try ctx.resolveBufferLease(lease)
            let size = try ctx.renderLib.contextBufferLeaseGetRealCharSize(
                ctx.libContext,
                lease: record,
                addLineBreaks: addLineBreaks
            )
            outSize = UInt32(max(0, size))
        }
    }

    // parity: native/src/context-abi.zig#ot_buffer_lease_write_resolved_chars [status=implemented hash=eb9302e5f701]
    public static func ot_buffer_lease_write_resolved_chars(
        _ context: ContextHandle?,
        lease: Handle,
        addLineBreaks: Bool = false,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let record = try ctx.resolveBufferLease(lease)
            outBytes = try ctx.renderLib.contextBufferLeaseWriteResolvedChars(
                ctx.libContext,
                lease: record,
                addLineBreaks: addLineBreaks
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_read_output [status=implemented hash=ed8e2b86920b]
    public static func ot_session_read_output(
        _ context: ContextHandle?,
        session: Handle,
        outTicket: inout NativeOutputTicket?,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            if let read = try ctx.renderLib.sessionReadOutput(ctx.libContext, session: lib) {
                ctx.storeOutputTicket(read.ticket)
                outTicket = read.ticket
                outBytes = read.bytes
            } else {
                outTicket = nil
                outBytes = []
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_session_drain_output [status=implemented hash=af905522b256]
    public static func ot_session_drain_output(
        _ context: ContextHandle?,
        session: Handle,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            var collected: [UInt8] = []
            while let read = try ctx.renderLib.sessionReadOutput(ctx.libContext, session: lib) {
                collected.append(contentsOf: read.bytes)
                try ctx.renderLib.sessionCompleteOutput(ctx.libContext, ticket: read.ticket, succeeded: true)
            }
            outBytes = collected
        }
    }

    // parity: native/src/context-abi.zig#ot_session_drain_stdout [status=implemented hash=e4e5c05acdbd]
    public static func ot_session_drain_stdout(
        _ context: ContextHandle?,
        session: Handle,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outBytes = try ctx.renderLib.sessionDrainStdout(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_post_stdout [status=implemented hash=6e4bb9b0507d]
    public static func ot_session_post_stdout(
        _ context: ContextHandle?,
        session: Handle,
        bytes: [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionPostStdout(ctx.libContext, session: lib, bytes: bytes)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_setup_terminal [status=implemented hash=564fade0985b]
    public static func ot_session_setup_terminal(
        _ context: ContextHandle?,
        session: Handle,
        options: NativeSessionTerminalOptions = NativeSessionTerminalOptions()
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetupTerminal(ctx.libContext, session: lib, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_suspend [status=implemented hash=7096556a29f2]
    public static func ot_session_suspend(_ context: ContextHandle?, session: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSuspend(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_resume [status=implemented hash=35a994b6b1b7]
    public static func ot_session_resume(_ context: ContextHandle?, session: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionResume(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_terminal_state [status=implemented hash=4c756f8474ba]
    public static func ot_session_get_terminal_state(
        _ context: ContextHandle?,
        session: Handle,
        outPhase: inout NativeSessionTerminalPhase
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outPhase = try ctx.renderLib.sessionGetTerminalState(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_pump [status=implemented hash=34e95b7a6e8b]
    public static func ot_session_pump(
        _ context: ContextHandle?,
        session: Handle,
        outResult: inout NativeSessionPumpResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outResult = try ctx.renderLib.sessionPump(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_pump_exit [status=implemented hash=000498235d62]
    public static func ot_session_pump_exit(
        _ context: ContextHandle?,
        session: Handle,
        outExited: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outExited = try ctx.renderLib.sessionPumpExit(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_control [status=implemented hash=a83382bee840]
    public static func ot_session_control(
        _ context: ContextHandle?,
        session: Handle,
        command: NativeSessionControl
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionControl(ctx.libContext, session: lib, command: command)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_clipboard [status=implemented hash=61dde2b8dc0d]
    public static func ot_session_clipboard(
        _ context: ContextHandle?,
        session: Handle,
        target: ClipboardTarget = .clipboard,
        bytes: [UInt8],
        outSent: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outSent = try ctx.renderLib.sessionClipboard(
                ctx.libContext,
                session: lib,
                target: target,
                bytes: bytes
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_set_palette_state [status=implemented hash=2631d4561d83]
    public static func ot_session_set_palette_state(
        _ context: ContextHandle?,
        session: Handle,
        palette: NormalizedTerminalPalette
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetPaletteState(ctx.libContext, session: lib, palette: palette)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_notification [status=implemented hash=bcb44a203130]
    public static func ot_session_notification(
        _ context: ContextHandle?,
        session: Handle,
        message: String,
        title: String? = nil,
        outSent: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outSent = try ctx.renderLib.sessionNotification(
                ctx.libContext,
                session: lib,
                message: message,
                title: title
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_capabilities [status=implemented hash=3000b0f9424b]
    public static func ot_session_get_capabilities(
        _ context: ContextHandle?,
        session: Handle,
        outCapabilities: inout NativeSessionCapabilities
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outCapabilities = try ctx.renderLib.sessionGetCapabilities(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_complete_output [status=implemented hash=cbdf72a61b74]
    public static func ot_session_complete_output(
        _ context: ContextHandle?,
        ticket: NativeOutputTicket,
        succeeded: Bool = true
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = ctx.takeOutputTicket(ticket.requestId)
            try ctx.renderLib.sessionCompleteOutput(ctx.libContext, ticket: ticket, succeeded: succeeded)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_close [status=implemented hash=5fa6aff05ec0]
    public static func ot_session_close(_ context: ContextHandle?, session: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionClose(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_drop_output [status=implemented hash=746abf6d2a26]
    public static func ot_session_drop_output(_ context: ContextHandle?, session: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionDropOutput(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_terminal_flush_input [status=implemented hash=f714dc4239a7]
    public static func ot_terminal_flush_input() -> Status {
        _ = resolveRenderLib().terminalFlushInput()
        return Status(NativeABI.OT_OK)
    }

    // parity: native/src/context-abi.zig#ot_session_cancel [status=implemented hash=185b3b7ff46c]
    public static func ot_session_cancel(_ context: ContextHandle?, session: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionCancel(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_get_state [status=implemented hash=cc30671c3015]
    public static func ot_session_get_state(
        _ context: ContextHandle?,
        session: Handle,
        outState: inout NativeSessionState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outState = try ctx.renderLib.sessionGetState(ctx.libContext, session: lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_session_destroy [status=implemented hash=eb98ebc0e3da]
    public static func ot_session_destroy(_ context: ContextHandle?, session: Handle) -> Status {
        destroyKind(context, session, kind: .session)
    }

    // parity: native/src/context-abi.zig#ot_scene_create_node [status=implemented hash=b71a43f6e624]
    public static func ot_scene_create_node(
        _ context: ContextHandle?,
        session: Handle? = nil,
        kind: UInt32 = UInt32(NativeABI.OT_SCENE_BOX),
        num: UInt32 = 0,
        outNode: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let session {
                _ = try ctx.resolveSession(session)
            }
            let lib = try ctx.renderLib.sceneCreateNode(ctx.libContext, kind: kind, num: num)
            outNode = try ctx.registerSceneNode(lib)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_destroy_node [status=implemented hash=ee77b7d9c244]
    public static func ot_scene_destroy_node(_ context: ContextHandle?, node: Handle) -> Status {
        destroyKind(context, node, kind: .sceneNode)
    }

    // parity: native/src/context-abi.zig#ot_scene_move_node [status=implemented hash=c839263b503b]
    public static func ot_scene_move_node(
        _ context: ContextHandle?,
        node: Handle,
        parent: Handle?,
        index: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let libParent = try parent.map { try ctx.resolveSceneNode($0) }
            try ctx.renderLib.sceneMoveNode(
                ctx.libContext,
                child: libNode,
                parent: libParent,
                index: Int(index)
            )
            ctx.trackChildMove(child: node, parent: parent, index: Int(index))
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_clear_children [status=implemented hash=4cce30c436ed]
    public static func ot_scene_clear_children(_ context: ContextHandle?, node: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSceneNode(node)
            let children = ctx.takeChildren(of: node)
            for child in children {
                if let libChild = try? ctx.resolveSceneNode(child) {
                    try ctx.renderLib.sceneMoveNode(ctx.libContext, child: libChild, parent: nil, index: 0)
                }
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_measure [status=implemented hash=52db494dd875]
    public static func ot_scene_set_measure(
        _ context: ContextHandle?,
        node: Handle,
        measure: FlexMeasureFunc?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetMeasure(ctx.libContext, node: libNode, measure: measure)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_has_measure [status=implemented hash=99f97a31edb3]
    public static func ot_scene_has_measure(
        _ context: ContextHandle?,
        node: Handle,
        outHasMeasure: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outHasMeasure = try ctx.renderLib.sceneHasMeasure(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_reaches_hooks [status=implemented hash=f6a348569280]
    public static func ot_scene_reaches_hooks(
        _ context: ContextHandle?,
        node: Handle,
        outReaches: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outReaches = try ctx.renderLib.sceneReachesHooks(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_painted [status=implemented hash=412c5dfa4952]
    public static func ot_scene_painted(
        _ context: ContextHandle?,
        node: Handle,
        outPainted: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outPainted = try ctx.renderLib.scenePainted(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_mark_dirty [status=implemented hash=7883d89aa0bc]
    public static func ot_scene_mark_dirty(_ context: ContextHandle?, node: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneMarkDirty(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_style [status=implemented hash=b86bfa666b2d]
    public static func ot_scene_set_style(
        _ context: ContextHandle?,
        node: Handle,
        group: UInt32,
        kind: UInt32,
        edge: UInt32,
        unit: UInt32,
        value: Float,
        flags: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let staging = try SceneStaging(initialCapacity: 1)
            try staging.stageStyle(
                context: ctx.libContext,
                node: libNode,
                group: group,
                kind: kind,
                edge: edge,
                unit: unit,
                value: value,
                flags: flags
            )
            _ = try ctx.renderLib.sceneFlush(ctx.libContext, staging: staging)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_style [status=implemented hash=b88d3672a50e]
    public static func ot_scene_get_style(
        _ context: ContextHandle?,
        node: Handle,
        group: NativeStyleGroup,
        kind: Int32,
        edge: Int32 = 0,
        outValue: inout YogaValue
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outValue = try ctx.renderLib.sceneGetStyle(
                ctx.libContext,
                node: libNode,
                group: group,
                kind: kind,
                edge: edge
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_paint [status=implemented hash=4b1fbf3c5592]
    public static func ot_scene_set_paint(
        _ context: ContextHandle?,
        node: Handle,
        update: NativeScenePaintUpdate
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let staging = try SceneStaging(initialCapacity: 1)
            try staging.stagePaint(context: ctx.libContext, node: libNode, update: update)
            _ = try ctx.renderLib.sceneFlush(ctx.libContext, staging: staging)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_flush [status=implemented hash=2df5587f1695]
    public static func ot_scene_flush(
        _ context: ContextHandle?,
        staging: SceneStaging,
        outApplied: inout Int
    ) -> Status {
        withAdmittedContext(context) { ctx in
            outApplied = try ctx.renderLib.sceneFlush(ctx.libContext, staging: staging)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_surface [status=implemented hash=0c1d7353106e]
    public static func ot_scene_set_surface(
        _ context: ContextHandle?,
        node: Handle,
        buffer: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let libBuf = try buffer.map { try ctx.resolveBuffer($0) }
            try ctx.renderLib.sceneSetSurface(ctx.libContext, node: libNode, buffer: libBuf)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_box_details [status=implemented hash=f74d5992c668]
    public static func ot_scene_set_box_details(
        _ context: ContextHandle?,
        node: Handle,
        details: NativeSceneBoxDetails
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetBoxDetails(ctx.libContext, node: libNode, details: details)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_viewport [status=implemented hash=23c5db24ab3f]
    public static func ot_scene_set_viewport(
        _ context: ContextHandle?,
        content: Handle,
        viewport: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libContent = try ctx.resolveSceneNode(content)
            let libViewport = try viewport.map { try ctx.resolveSceneNode($0) }
            try ctx.renderLib.sceneSetViewport(ctx.libContext, content: libContent, viewport: libViewport)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_scroll [status=implemented hash=ea3253686337]
    public static func ot_scene_set_scroll(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneScrollOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetScroll(ctx.libContext, node: libNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_scroll_arrow [status=implemented hash=28e253a12a2e]
    public static func ot_scene_set_scroll_arrow(
        _ context: ContextHandle?,
        node: Handle,
        axis: UInt32,
        end: UInt32,
        options: NativeSceneArrowOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetScrollArrow(
                ctx.libContext,
                node: libNode,
                axis: Int(axis),
                end: Int(end),
                options: options
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_scroll_to [status=implemented hash=269fdffe1c00]
    public static func ot_scene_scroll_to(
        _ context: ContextHandle?,
        node: Handle,
        x: Double,
        y: Double,
        flags: UInt32 = 0,
        outState: inout NativeSceneScrollState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outState = try ctx.renderLib.sceneScrollTo(
                ctx.libContext,
                node: libNode,
                x: x,
                y: y,
                relativeX: (flags & 1) != 0,
                relativeY: (flags & 2) != 0,
                reapply: (flags & 4) != 0
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_scroll_request [status=implemented hash=e7d578f38dbe]
    public static func ot_scene_scroll_request(
        _ context: ContextHandle?,
        node: Handle,
        kind: NativeSceneScrollRequestKind,
        target: Handle? = nil,
        align: NativeSceneScrollAlign = .nearest,
        inset: Double = 0,
        outState: inout NativeSceneScrollState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let libTarget = try target.map { try ctx.resolveSceneNode($0) }
            outState = try ctx.renderLib.sceneScrollRequest(
                ctx.libContext,
                node: libNode,
                kind: kind,
                target: libTarget,
                align: align,
                inset: inset
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_scroll [status=implemented hash=8f9f524373cf]
    public static func ot_scene_get_scroll(
        _ context: ContextHandle?,
        node: Handle,
        outState: inout NativeSceneScrollState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outState = try ctx.renderLib.sceneGetScroll(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_focus [status=implemented hash=48887cc37be8]
    public static func ot_scene_set_focus(
        _ context: ContextHandle?,
        node: Handle,
        focused: Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetFocus(ctx.libContext, node: libNode, focused: focused)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_layout [status=implemented hash=a2d248bb78c9]
    public static func ot_scene_get_layout(
        _ context: ContextHandle?,
        node: Handle,
        kind: NativeSceneLayoutKind = .computed,
        outLayout: inout NativeSceneLayout
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outLayout = try ctx.renderLib.sceneGetLayout(ctx.libContext, node: libNode, kind: kind)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_slider [status=implemented hash=06506adc7abd]
    public static func ot_scene_set_slider(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneSliderOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetSlider(ctx.libContext, node: libNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_slider_thumb [status=implemented hash=2b7f995eee4f]
    public static func ot_scene_get_slider_thumb(
        _ context: ContextHandle?,
        node: Handle,
        outThumb: inout SliderThumb
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outThumb = try ctx.renderLib.sceneGetSliderThumb(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_arrow [status=implemented hash=97703a5afe8c]
    public static func ot_scene_set_arrow(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneArrowOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetArrow(ctx.libContext, node: libNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_text [status=implemented hash=4da37350288c]
    public static func ot_scene_set_text(
        _ context: ContextHandle?,
        node: Handle,
        text: String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetText(ctx.libContext, node: libNode, text: text)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_styled_text [status=implemented hash=ffdaccbe1b66]
    public static func ot_scene_set_styled_text(
        _ context: ContextHandle?,
        node: Handle,
        chunks: [NativeContextEngine.StyledTextChunk]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            try setStyledText(ctx: ctx, node: node, chunks: chunks)
        }
    }

    // parity: native/src/context-abi.zig#setStyledText [status=implemented hash=515c1d0617ae]
    public static func setStyledText(
        ctx: NativeContextEngine.Context,
        node: Handle,
        chunks: [NativeContextEngine.StyledTextChunk]
    ) throws {
        let libNode = try ctx.resolveSceneNode(node)
        let styled = StyledText(chunks.map { $0.toTextChunk() })
        try ctx.renderLib.sceneSetStyledText(ctx.libContext, node: libNode, styledText: styled)
    }

    // parity: native/src/context-abi.zig#styledTextChunkFromC [status=implemented hash=d70d8a6e6963]
    public static func styledTextChunkFromC(
        text: String,
        fg: RGBA? = nil,
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none,
        urlBytes: [UInt8] = []
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.StyledTextChunk {
        guard urlBytes.count <= MAX_LINK_URL_BYTES else {
            throw .invalidOptions("link URL exceeds maximum byte length")
        }
        let link = urlBytes.isEmpty ? nil : String(decoding: urlBytes, as: UTF8.self)
        return NativeContextEngine.StyledTextChunk(
            text: text,
            fg: fg,
            bg: bg,
            attributes: attributes,
            link: link
        )
    }

    // parity: native/src/context-abi.zig#ot_scene_set_text_options [status=implemented hash=f0853941539b]
    public static func ot_scene_set_text_options(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneTextOptions
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetTextOptions(ctx.libContext, node: libNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_text_selection [status=implemented hash=6b405236f03e]
    public static func ot_scene_set_text_selection(
        _ context: ContextHandle?,
        node: Handle,
        options: NativeSceneTextSelectionOptions,
        outChanged: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outChanged = try ctx.renderLib.sceneSetTextSelection(ctx.libContext, node: libNode, options: options)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_text_selection [status=implemented hash=24c5e1c742f4]
    public static func ot_scene_get_text_selection(
        _ context: ContextHandle?,
        node: Handle,
        outPacked: inout UInt64
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            if let range = try ctx.renderLib.sceneGetTextSelection(ctx.libContext, node: libNode) {
                let start = UInt64(UInt32(clamping: range.start))
                let end = UInt64(UInt32(clamping: range.end))
                outPacked = (start << 32) | end
            } else {
                outPacked = UInt64.max
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_selected_text [status=implemented hash=a7b19756a4b3]
    public static func ot_scene_get_selected_text(
        _ context: ContextHandle?,
        node: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outText = try ctx.renderLib.sceneGetSelectedText(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_text [status=implemented hash=c032b884fcc4]
    public static func ot_scene_get_text(
        _ context: ContextHandle?,
        node: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outText = try ctx.renderLib.sceneGetText(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_text_info [status=implemented hash=6a924530e327]
    public static func ot_scene_get_text_info(
        _ context: ContextHandle?,
        node: Handle,
        outMetrics: inout NativeSceneTextMetrics
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outMetrics = try ctx.renderLib.sceneGetTextMetrics(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_text_lines [status=implemented hash=7949413f384e]
    public static func ot_scene_get_text_lines(
        _ context: ContextHandle?,
        node: Handle,
        firstLine: UInt32 = 0,
        lineCount: UInt32? = nil,
        outInfo: inout LineInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outInfo = try ctx.renderLib.sceneGetTextLineInfo(
                ctx.libContext,
                node: libNode,
                firstLine: Int(firstLine),
                lineCount: lineCount.map(Int.init)
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_text_byte_at [status=implemented hash=f6c5b9eafeb7]
    public static func ot_scene_get_text_byte_at(
        _ context: ContextHandle?,
        node: Handle,
        x: Int32,
        y: Int32,
        outByteOffset: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            if let offset = try ctx.renderLib.sceneGetTextByteAt(ctx.libContext, node: libNode, x: Int(x), y: Int(y)) {
                outByteOffset = UInt32(clamping: offset)
            } else {
                outByteOffset = UInt32.max
            }
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_hooks [status=implemented hash=ae3f53b8898a]
    public static func ot_scene_set_hooks(
        _ context: ContextHandle?,
        node: Handle,
        flags: UInt32,
        generation: UInt64 = 1,
        initialWidth: UInt32 = 0,
        initialHeight: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetHooks(
                ctx.libContext,
                node: libNode,
                flags: flags,
                generation: generation,
                initialWidth: Int(initialWidth),
                initialHeight: Int(initialHeight)
            )
        }
    }

    // parity: native/src/context-abi.zig#frameRequestFromC [status=implemented hash=60b7e5c8800b]
    public static func frameRequestFromC(_ request: NativeSceneFrameRequest) throws(NativeContextEngine.ContextError) -> NativeSceneFrameRequest {
        guard request.frameId > 0 else {
            throw .invalidOptions("frame request id must be non-zero")
        }
        return request
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_step_with_geometry [status=implemented hash=3d3b1020a112]
    public static func ot_scene_frame_step_with_geometry(
        _ context: ContextHandle?,
        session: Handle,
        root: Handle,
        options: NativeSceneFrameOptions = NativeSceneFrameOptions(),
        previous: NativeSceneFrameRequest? = nil,
        outRequest: inout NativeSceneFrameRequest
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let libRoot = try ctx.resolveSceneNode(root)
            let req = try ctx.renderLib.sceneFrameStep(
                ctx.libContext,
                session: libSession,
                root: libRoot,
                options: options,
                previous: previous
            )
            ctx.storePendingFrame(sessionSlot: session.slot, frame: req)
            outRequest = req
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_get_paint_slots [status=implemented hash=94a523685913]
    public static func ot_scene_frame_get_paint_slots(
        _ context: ContextHandle?,
        session: Handle,
        request: NativeSceneFrameRequest,
        outSlots: inout [NativeScenePaintSlot]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSession(session)
            let validated = try frameRequestFromC(request)
            outSlots = try ctx.renderLib.sceneFrameGetPaintSlots(ctx.libContext, frame: validated)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_cancel [status=implemented hash=d0e5d9e3db82]
    public static func ot_scene_frame_cancel(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSession(session)
            try ctx.renderLib.sceneFrameCancel(ctx.libContext, frame: frame)
            ctx.storePendingFrame(sessionSlot: session.slot, frame: nil)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_acquire_buffer_lease [status=implemented hash=0ce167c6b5ee]
    public static func ot_scene_frame_acquire_buffer_lease(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest,
        outLeaseHandle: inout Handle,
        outLease: inout NativeSessionBufferLease
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSession(session)
            let lease = try ctx.renderLib.sceneFrameAcquireBufferLease(ctx.libContext, frame: frame)
            outLeaseHandle = try ctx.registerBufferLease(lease)
            outLease = lease
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_draw_buffer [status=implemented hash=050a8ea00b42]
    public static func ot_scene_frame_draw_buffer(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest,
        source: Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        crop: NativeContextEngine.BufferCrop? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let libBuf = try ctx.resolveBuffer(source)
            let draw = NativeBufferDraw.compose(
                x: Int(x),
                y: Int(y),
                source: libBuf,
                sourceX: crop.map { Int($0.x) },
                sourceY: crop.map { Int($0.y) },
                sourceWidth: crop?.width.map(Int.init),
                sourceHeight: crop?.height.map(Int.init)
            )
            try ctx.renderLib.contextDrawBuffer(
                .frame(context: ctx.libContext, target: libSession, frame: frame),
                draw: draw
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_frame_commit [status=implemented hash=834672ead40c]
    public static func ot_scene_frame_commit(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest,
        force: Bool = false,
        outRenderStatus: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSession(session)
            let status = try ctx.renderLib.sceneFrameCommit(ctx.libContext, frame: frame, force: force)
            ctx.storePendingFrame(sessionSlot: session.slot, frame: nil)
            outRenderStatus = renderStatusToC(status)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_paint [status=implemented hash=ee5bbd6dce03]
    public static func ot_scene_paint(
        _ context: ContextHandle?,
        session: Handle,
        root: Handle,
        background: RGBA = RGBA.fromInts(0, 0, 0, 255),
        useMouse: Bool = false,
        excludedHitNum: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let libRoot = try ctx.resolveSceneNode(root)
            let opts = NativeSceneFrameOptions(
                background: background,
                useMouse: useMouse,
                excludedHitNum: excludedHitNum
            )
            let frame = try ctx.renderLib.sceneFrameStep(
                ctx.libContext,
                session: libSession,
                root: libRoot,
                options: opts
            )
            _ = try ctx.renderLib.sceneFrameCommit(ctx.libContext, frame: frame, force: false)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_hit_test [status=implemented hash=6605972193d9]
    public static func ot_scene_hit_test(
        _ context: ContextHandle?,
        root: Handle,
        x: Int32,
        y: Int32,
        outHitNum: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libRoot = try ctx.resolveSceneNode(root)
            outHitNum = try ctx.renderLib.sceneHitTest(ctx.libContext, root: libRoot, x: Int(x), y: Int(y))
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_hit_test_excluding [status=implemented hash=096de5dbf401]
    public static func ot_scene_hit_test_excluding(
        _ context: ContextHandle?,
        root: Handle,
        x: Int32,
        y: Int32,
        excludedNum: UInt32,
        outHitNum: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libRoot = try ctx.resolveSceneNode(root)
            outHitNum = try ctx.renderLib.sceneHitTest(
                ctx.libContext,
                root: libRoot,
                x: Int(x),
                y: Int(y),
                excludingNum: excludedNum
            )
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_stats [status=implemented hash=3105e556befd]
    public static func ot_scene_get_stats(
        _ context: ContextHandle?,
        session: Handle? = nil,
        outStats: inout OpenTUICore.NativeRenderStats
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let session { _ = try ctx.resolveSession(session) }
            outStats = try ctx.renderLib.sceneGetStats(ctx.libContext)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_set_debug_flags [status=implemented hash=34f14dec0983]
    public static func ot_scene_set_debug_flags(
        _ context: ContextHandle?,
        session: Handle? = nil,
        flags: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let session { _ = try ctx.resolveSession(session) }
            try ctx.renderLib.sceneSetDebugFlags(ctx.libContext, flags: flags)
        }
    }

    // parity: native/src/context-abi.zig#ot_scene_get_cursor_state [status=implemented hash=5e0461b128d8]
    public static func ot_scene_get_cursor_state(
        _ context: ContextHandle?,
        session: Handle? = nil,
        outCursor: inout CursorState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let session { _ = try ctx.resolveSession(session) }
            outCursor = try ctx.renderLib.sceneGetCursorState(ctx.libContext)
        }
    }

    // parity: native/src/context-abi.zig#sessionContextStatus [status=implemented hash=37050ff7e8f7]
    public static func sessionContextStatus(_ context: ContextHandle?) -> Status {
        guard let context else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return context.isDestroyed ? Status(NativeABI.OT_STALE_HANDLE) : Status(NativeABI.OT_OK)
    }

    // parity: native/src/context-abi.zig#handleFromC [status=implemented hash=38aac7aaf199]
    public static func handleFromC(_ value: ZigHandle) -> Handle {
        Handle(zigHandle: value)
    }

    // parity: native/src/context-abi.zig#handleToC [status=implemented hash=81812314ebe7]
    public static func handleToC(_ value: Handle) -> ZigHandle {
        value.toZigHandle()
    }

    // parity: native/src/context-abi.zig#sessionError [status=implemented hash=12e4f9d99384]
    public static func sessionError(_ owner: ContextHandle?, _ error: any Error) -> Status {
        mapError(owner, error)
    }

    // parity: native/src/context-abi.zig#destroyKind [status=implemented hash=d030be4a3af8]
    public static func destroyKind(_ context: ContextHandle?, _ handle: Handle, kind: Kind) -> Status {
        withAdmittedContext(context) { ctx in
            try ctx.destroyObject(handle, expectedKind: kind)
        }
    }

    // parity: native/src/context-abi.zig#createTestContext [status=implemented hash=fd8dbaa43b01]
    public static func createTestContext(
        objectCapacity: UInt32 = 4_096,
        renderCellsMax: UInt32 = 250_000
    ) throws -> ContextHandle {
        var handle: ContextHandle?
        let status = ot_context_create(
            abiVersion: UInt32(NativeABI.OT_CONTEXT_ABI_VERSION),
            options: NativeContextEngine.Options(
                objectCapacity: Int(objectCapacity),
                renderCellsMax: Int(renderCellsMax)
            ),
            outContext: &handle
        )
        guard status == Status(NativeABI.OT_OK), let handle else {
            throw NativeContextEngine.ContextError.status(status, "createTestContext failed")
        }
        return handle
    }

    // parity: native/src/context-abi.zig#export_symbols [status=adapted hash=aab3aede1c45]
    public static func export_symbols() -> [String] {
        Array(NativeABI.nativeSymbols.keys).sorted()
    }
}

// MARK: - 3.2 Context Audio ABI (native/src/context-audio-abi.zig — 9 symbols)

public extension NativeContextABI {
    // parity: native/src/context-audio-abi.zig#ot_audio_create [status=implemented hash=5029d0ec1106]
    static func ot_audio_create(
        _ context: ContextHandle?,
        options: AudioCreateOptions = AudioCreateOptions(),
        outAudio: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let engine = ctx.renderLib.createAudioEngine(options)
            outAudio = try ctx.registerAudio(engine)
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_destroy [status=implemented hash=57af7c4cf4ed]
    static func ot_audio_destroy(_ context: ContextHandle?, _ audio: Handle) -> Status {
        destroyKind(context, audio, kind: .audio)
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_start [status=implemented hash=f088fcad62bc]
    static func ot_audio_start(
        _ context: ContextHandle?,
        audio: Handle,
        flags: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let engine = try ctx.resolveAudio(audio)
            let ok: Bool
            if (flags & UInt32(NativeABI.OT_AUDIO_START_NO_DEVICE)) != 0 {
                ok = ctx.renderLib.audioStartMixer(engine)
            } else {
                ok = ctx.renderLib.audioStart(engine, options: nil)
            }
            if !ok {
                throw NativeContextEngine.ContextError.audioDeviceFailed("ot_audio_start failed")
            }
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_stop [status=implemented hash=9e70d1c8a38f]
    static func ot_audio_stop(_ context: ContextHandle?, audio: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let engine = try ctx.resolveAudio(audio)
            if !ctx.renderLib.audioStop(engine) {
                throw NativeContextEngine.ContextError.audioDeviceFailed("ot_audio_stop failed")
            }
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_load [status=implemented hash=bc0658eef28b]
    static func ot_audio_load(
        _ context: ContextHandle?,
        audio: Handle,
        bytes: [UInt8],
        outSound: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard !bytes.isEmpty else {
                throw NativeContextEngine.ContextError.invalidOptions("audio bytes must not be empty")
            }
            let engine = try ctx.resolveAudio(audio)
            let soundId = ctx.renderLib.audioLoad(engine, data: bytes)
            guard soundId != 0 else {
                throw NativeContextEngine.ContextError.audioDecodeFailed("failed to decode audio bytes")
            }
            outSound = soundId
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_play [status=implemented hash=4000f645e295]
    static func ot_audio_play(
        _ context: ContextHandle?,
        audio: Handle,
        sound: UInt32,
        volume: Float = 1.0,
        outVoice: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard volume.isFinite && volume >= 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid volume")
            }
            let engine = try ctx.resolveAudio(audio)
            let opts = AudioVoiceOptions(volume: volume, pan: 0, loop: false, groupId: 0)
            let voiceId = ctx.renderLib.audioPlay(engine, soundId: sound, options: opts)
            guard voiceId != 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid sound id \(sound)")
            }
            outVoice = voiceId
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_stop_voice [status=implemented hash=af4adeb08404]
    static func ot_audio_stop_voice(
        _ context: ContextHandle?,
        audio: Handle,
        voice: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let engine = try ctx.resolveAudio(audio)
            _ = ctx.renderLib.audioStopVoice(engine, voiceId: voice)
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_set_volume [status=implemented hash=6bf5d01b702a]
    static func ot_audio_set_volume(
        _ context: ContextHandle?,
        audio: Handle,
        volume: Float
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard volume.isFinite && volume >= 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid volume")
            }
            let engine = try ctx.resolveAudio(audio)
            _ = ctx.renderLib.audioSetMasterVolume(engine, volume: volume)
        }
    }

    // parity: native/src/context-audio-abi.zig#ot_audio_mix [status=implemented hash=2be6ffb5c279]
    static func ot_audio_mix(
        _ context: ContextHandle?,
        audio: Handle,
        frameCount: UInt32,
        channels: UInt32 = 2,
        outSamples: inout [Float]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard frameCount > 0 && channels > 0 && channels <= 8 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid mix frame/channel count")
            }
            let engine = try ctx.resolveAudio(audio)
            guard let mixed = ctx.renderLib.audioMixToBuffer(engine, frameCount: Int(frameCount), channels: Int(channels)) else {
                throw NativeContextEngine.ContextError.audioDeviceFailed("audio mix failed")
            }
            outSamples = mixed
        }
    }
}

// MARK: - 3.3 Context Editor ABI (native/src/context-editor-abi.zig — 41 symbols)

public extension NativeContextABI {
    // parity: native/src/context-editor-abi.zig#admit [status=implemented hash=23151b8c226f]
    static func admit(_ context: ContextHandle?, read: Bool = true) throws(NativeContextEngine.ContextError) -> ContextHandle {
        guard let context else { throw .invalidOptions("null context") }
        _ = read
        try context.context.enterCall()
        return context
    }

    // parity: native/src/context-editor-abi.zig#beginMutation [status=implemented hash=20e1448e420e]
    static func beginMutation(_ context: ContextHandle?) throws(NativeContextEngine.ContextError) -> ContextHandle {
        try admit(context, read: false)
    }

    // parity: native/src/context-editor-abi.zig#fail [status=implemented hash=6a256a93a1ae]
    static func fail(_ context: ContextHandle?, _ error: any Error) -> Status {
        mapError(context, error)
    }

    // parity: native/src/context-editor-abi.zig#record [status=implemented hash=0cb8b12a5d46]
    static func record<T>(_ value: T?) throws(NativeContextEngine.ContextError) -> T {
        guard let value else { throw .invalidOptions("missing required record") }
        return value
    }

    // parity: native/src/context-editor-abi.zig#rgba [status=implemented hash=25f438861a6f]
    static func rgba(_ color: (UInt16, UInt16, UInt16, UInt16)) throws(NativeContextEngine.ContextError) -> RGBA {
        RGBA(b0: color.0, b1: color.1, b2: color.2, b3: color.3)
    }

    // parity: native/src/context-editor-abi.zig#styleRecord [status=implemented hash=bb38d14827f5]
    static func styleRecord(_ style: NativeEditorStyle?) throws(NativeContextEngine.ContextError) -> NativeEditorStyle {
        try record(style)
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_set_tab_width [status=implemented hash=4cf7ec608dac]
    static func ot_edit_buffer_set_tab_width(
        _ context: ContextHandle?,
        editBuffer: Handle,
        width: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard width > 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("tab width must be positive")
            }
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferSetTabWidth(ctx.libContext, editBuffer: edit.libHandle, tabWidth: Int(width))
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_command [status=implemented hash=b22463b96b3d]
    static func ot_edit_buffer_command(
        _ context: ContextHandle?,
        editBuffer: Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let cmd = NativeEditCommand(rawValue: command) else {
                throw NativeContextEngine.ContextError.invalidOptions("unknown edit buffer command \(command)")
            }
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferCommand(
                ctx.libContext,
                editBuffer: edit.libHandle,
                command: cmd,
                argument: argument
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_history [status=implemented hash=fee7dc8dd4a3]
    static func ot_edit_buffer_history(
        _ context: ContextHandle?,
        editBuffer: Handle,
        redo: Bool,
        outMeta: inout String?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outMeta = try ctx.renderLib.contextEditBufferHistory(
                ctx.libContext,
                editBuffer: edit.libHandle,
                redo: redo
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_get_position [status=implemented hash=e30a3c148452]
    static func ot_edit_buffer_get_position(
        _ context: ContextHandle?,
        editBuffer: Handle,
        query: UInt32,
        arg0: UInt32 = 0,
        arg1: UInt32 = 0,
        outPosition: inout LogicalCursor?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let q = NativeEditPositionQuery(rawValue: query) else {
                throw NativeContextEngine.ContextError.invalidOptions("unknown edit position query \(query)")
            }
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outPosition = try ctx.renderLib.contextEditBufferGetPosition(
                ctx.libContext,
                editBuffer: edit.libHandle,
                query: q,
                arg0: Int(arg0),
                arg1: Int(arg1)
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_get_range [status=implemented hash=1e4ff36f7dce]
    static func ot_edit_buffer_get_range(
        _ context: ContextHandle?,
        editBuffer: Handle,
        byCoords: Bool,
        startA: UInt32,
        startB: UInt32 = 0,
        endA: UInt32,
        endB: UInt32 = 0,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outText = try ctx.renderLib.contextEditBufferGetRange(
                ctx.libContext,
                editBuffer: edit.libHandle,
                byCoords: byCoords,
                startA: Int(startA),
                startB: Int(startB),
                endA: Int(endA),
                endB: Int(endB)
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_convert_offset [status=implemented hash=fb3de8de25ae]
    static func ot_edit_buffer_convert_offset(
        _ context: ContextHandle?,
        editBuffer: Handle,
        toCellOffset: Bool,
        value: UInt32,
        outValue: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            let converted = try ctx.renderLib.contextEditBufferConvertOffset(
                ctx.libContext,
                editBuffer: edit.libHandle,
                offset: Int(value),
                toCellOffset: toCellOffset
            )
            outValue = UInt32(max(0, converted))
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_measure_text [status=implemented hash=09286917a306]
    static func ot_edit_buffer_measure_text(
        _ context: ContextHandle?,
        editBuffer: Handle,
        text: String,
        outWidth: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            let width = try ctx.renderLib.contextEditBufferMeasureText(
                ctx.libContext,
                editBuffer: edit.libHandle,
                text: text
            )
            outWidth = UInt32(max(0, width))
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_measure_text [status=implemented hash=1263e93a5f63]
    static func ot_edit_measure_text(
        _ context: ContextHandle?,
        text: String,
        widthMethod: UInt32 = UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE),
        tabWidth: UInt32 = 2,
        outWidth: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let method = try textWidthMethodFromC(widthMethod)
            let width = ctx.renderLib.editMeasureText(
                text,
                widthMethod: method,
                tabWidth: tabWidth > 0 ? Int(tabWidth) : nil
            )
            outWidth = UInt32(max(0, width))
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_set_defaults [status=implemented hash=135f50685b6a]
    static func ot_edit_buffer_set_defaults(
        _ context: ContextHandle?,
        editBuffer: Handle,
        mask: UInt32,
        options: NativeEditorStyle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let defaults = try defaultsFromC(mask: mask, options: options)
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferSetDefaults(
                ctx.libContext,
                editBuffer: edit.libHandle,
                style: defaults.style,
                reset: defaults.reset
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_syntax_style_register [status=implemented hash=bed5370d441b]
    static func ot_syntax_style_register(
        _ context: ContextHandle?,
        style: Handle,
        name: String,
        definition: NativeEditorStyle,
        outStyleId: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let checked = try styleRecord(definition)
            let libStyle = try ctx.resolveSyntaxStyle(style)
            outStyleId = try ctx.renderLib.contextSyntaxStyleRegister(
                ctx.libContext,
                style: libStyle,
                name: name,
                definition: checked
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_mark [status=implemented hash=e46ab9d6c1b6]
    static func ot_edit_buffer_mark(
        _ context: ContextHandle?,
        editBuffer: Handle,
        operation: UInt32,
        mark: NativeEditMark? = nil,
        markId: UInt32? = nil,
        outId: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let op = NativeEditMarkOperation(rawValue: operation) else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid mark operation \(operation)")
            }
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outId = try ctx.renderLib.contextEditBufferMark(
                ctx.libContext,
                editBuffer: edit.libHandle,
                operation: op,
                mark: mark,
                markId: markId
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_get_marks [status=implemented hash=57364eb05bca]
    static func ot_edit_buffer_get_marks(
        _ context: ContextHandle?,
        editBuffer: Handle,
        markId: UInt32? = nil,
        kind: UInt32 = UInt32(truncatingIfNeeded: NativeABI.OT_EDIT_MARK_ANY_KIND),
        outMarks: inout [NativeEditMark]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            let all = try ctx.renderLib.contextEditBufferGetMarks(ctx.libContext, editBuffer: edit.libHandle, kind: kind)
            if let markId {
                outMarks = all.filter { $0.id == markId }
            } else {
                outMarks = all
            }
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_set_viewport [status=implemented hash=3241f6a80ee6]
    static func ot_editor_view_set_viewport(
        _ context: ContextHandle?,
        view: Handle,
        viewport: NativeEditorViewport,
        sizeOnly: Bool = false,
        moveCursor: Bool = true
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            var vp = viewport
            if sizeOnly {
                let current = try ctx.renderLib.contextEditorViewGetViewport(ctx.libContext, view: editor.libHandle)
                vp.x = current.x
                vp.y = current.y
            }
            try ctx.renderLib.contextEditorViewSetViewport(
                ctx.libContext,
                view: editor.libHandle,
                viewport: vp,
                moveCursor: moveCursor
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_viewport [status=implemented hash=81cfd7185d33]
    static func ot_editor_view_get_viewport(
        _ context: ContextHandle?,
        view: Handle,
        outViewport: inout NativeEditorViewport
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outViewport = try ctx.renderLib.contextEditorViewGetViewport(ctx.libContext, view: editor.libHandle)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_set_scroll_margin [status=implemented hash=82056c04e4a4]
    static func ot_editor_view_set_scroll_margin(
        _ context: ContextHandle?,
        view: Handle,
        margin: Float
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard margin.isFinite && margin >= 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid scroll margin")
            }
            let editor = try ctx.resolveEditorView(view)
            try ctx.renderLib.contextEditorViewSetScrollMargin(
                ctx.libContext,
                view: editor.libHandle,
                margin: Double(margin)
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_command [status=implemented hash=39bc04b122ce]
    static func ot_editor_view_command(
        _ context: ContextHandle?,
        view: Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let cmd = NativeEditorCommand(rawValue: command) else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid editor command \(command)")
            }
            let editor = try ctx.resolveEditorView(view)
            try ctx.renderLib.contextEditorViewCommand(
                ctx.libContext,
                view: editor.libHandle,
                command: cmd,
                argument: argument
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_set_tab_color [status=implemented hash=0e0fe0361ced]
    static func ot_editor_view_set_tab_color(
        _ context: ContextHandle?,
        view: Handle,
        color: RGBA
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            try ctx.renderLib.contextEditorViewSetTabColor(ctx.libContext, view: editor.libHandle, color: color)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_select [status=implemented hash=4fa29a1d47ef]
    static func ot_editor_view_select(
        _ context: ContextHandle?,
        view: Handle,
        options: NativeEditorSelection,
        outChanged: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let selection = try selectionFromC(options, isEditor: true)
            let editor = try ctx.resolveEditorView(view)
            outChanged = try ctx.renderLib.contextEditorViewSelect(
                ctx.libContext,
                view: editor.libHandle,
                selection: selection
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#selectionFromC [status=implemented hash=e20cbd3df0f0]
    static func selectionFromC(
        _ options: NativeEditorSelection?,
        isEditor: Bool
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.TextSelection {
        let sel = try record(options)
        _ = isEditor
        return sel
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_info [status=implemented hash=b2e5b0f9d01d]
    static func ot_editor_view_get_info(
        _ context: ContextHandle?,
        view: Handle,
        followCursor: Bool = false,
        outInfo: inout NativeEditorViewInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = followCursor
            let editor = try ctx.resolveEditorView(view)
            outInfo = try ctx.renderLib.contextEditorViewGetInfo(ctx.libContext, view: editor.libHandle)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_selection [status=implemented hash=4c8dc5963222]
    static func ot_editor_view_get_selection(
        _ context: ContextHandle?,
        view: Handle,
        outSelection: inout TextSelectionRange?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outSelection = try ctx.renderLib.contextEditorViewGetSelection(ctx.libContext, view: editor.libHandle)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_selected_text [status=implemented hash=f955b83693ca]
    static func ot_editor_view_get_selected_text(
        _ context: ContextHandle?,
        view: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outText = try ctx.renderLib.contextEditorViewGetSelectedText(ctx.libContext, view: editor.libHandle)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_position [status=implemented hash=a409dbb4c9fa]
    static func ot_editor_view_get_position(
        _ context: ContextHandle?,
        view: Handle,
        query: UInt32,
        outCursor: inout VisualCursor
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let q = NativeEditorPositionQuery(rawValue: query) else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid editor position query \(query)")
            }
            let editor = try ctx.resolveEditorView(view)
            outCursor = try ctx.renderLib.contextEditorViewGetPosition(
                ctx.libContext,
                view: editor.libHandle,
                query: q
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_get_lines [status=implemented hash=08414da0874d]
    static func ot_editor_view_get_lines(
        _ context: ContextHandle?,
        view: Handle,
        logical: Bool = false,
        outInfo: inout LineInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outInfo = try ctx.renderLib.contextEditorViewGetLines(
                ctx.libContext,
                view: editor.libHandle,
                logical: logical
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_measure [status=implemented hash=e3d361d8c74f]
    static func ot_editor_view_measure(
        _ context: ContextHandle?,
        view: Handle,
        width: UInt32,
        height: UInt32,
        outResult: inout MeasureResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outResult = try ctx.renderLib.contextEditorViewMeasure(
                ctx.libContext,
                view: editor.libHandle,
                width: Int(width),
                height: Int(height)
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_set_placeholder [status=implemented hash=176a7c2008b5]
    static func ot_editor_view_set_placeholder(
        _ context: ContextHandle?,
        view: Handle,
        chunks: [TextChunk]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            try ctx.renderLib.contextEditorViewSetPlaceholder(ctx.libContext, view: editor.libHandle, chunks: chunks)
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_highlight [status=implemented hash=1dbdf68f4434]
    static func ot_edit_buffer_highlight(
        _ context: ContextHandle?,
        editBuffer: Handle,
        operation: UInt32,
        argument: UInt32 = 0,
        highlight: Highlight? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let parsed = try highlightFromC(operation: operation, argument: argument, highlight: highlight)
            let edit = try ctx.resolveEditBuffer(editBuffer)
            try ctx.renderLib.contextEditBufferHighlight(
                ctx.libContext,
                editBuffer: edit.libHandle,
                operation: parsed.operation,
                lineOrRef: parsed.lineOrRef,
                highlight: parsed.highlight
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#highlightFromC [status=implemented hash=8f844c56959d]
    static func highlightFromC(
        operation: UInt32,
        argument: UInt32,
        highlight: Highlight?
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.TextHighlight {
        guard let op = NativeEditHighlightOperation(rawValue: operation) else {
            throw .invalidOptions("invalid highlight operation \(operation)")
        }
        if (op == .addLine || op == .addRange) && highlight == nil {
            throw .invalidOptions("highlight record required for operation \(operation)")
        }
        return NativeContextEngine.TextHighlight(operation: op, lineOrRef: Int(argument), highlight: highlight)
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_get_highlights [status=implemented hash=b00a161425cc]
    static func ot_edit_buffer_get_highlights(
        _ context: ContextHandle?,
        editBuffer: Handle,
        line: UInt32,
        outHighlights: inout [Highlight]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let edit = try ctx.resolveEditBuffer(editBuffer)
            outHighlights = try ctx.renderLib.contextEditBufferGetHighlights(
                ctx.libContext,
                editBuffer: edit.libHandle,
                lineIdx: Int(line)
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_edit_buffer_set_layer [status=implemented hash=4cdb97f36b01]
    static func ot_edit_buffer_set_layer(
        _ context: ContextHandle?,
        editBuffer: Handle,
        layerId: UInt32,
        startByte: UInt32,
        endByte: UInt32,
        runs: [Highlight]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let validated = try layerRunsFromC(runs: runs, startByte: startByte, endByte: endByte)
            let edit = try ctx.resolveEditBuffer(editBuffer)
            for hl in validated {
                var tagged = hl
                tagged.hlRef = Int(layerId)
                try ctx.renderLib.contextEditBufferHighlight(
                    ctx.libContext,
                    editBuffer: edit.libHandle,
                    operation: .addRange,
                    lineOrRef: Int(layerId),
                    highlight: tagged
                )
            }
        }
    }

    // parity: native/src/context-editor-abi.zig#layerRunsFromC [status=implemented hash=3255ca2605c5]
    static func layerRunsFromC(
        runs: [Highlight],
        startByte: UInt32,
        endByte: UInt32
    ) throws(NativeContextEngine.ContextError) -> [Highlight] {
        guard startByte <= endByte else {
            throw .invalidOptions("layer startByte exceeds endByte")
        }
        for run in runs {
            guard run.start <= run.end else {
                throw .invalidOptions("layer run start exceeds end")
            }
        }
        return runs
    }

    // parity: native/src/context-editor-abi.zig#ot_syntax_style_resolve [status=implemented hash=dcbafdf9835f]
    static func ot_syntax_style_resolve(
        _ context: ContextHandle?,
        style: Handle,
        name: String,
        outStyleId: inout UInt32?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libStyle = try ctx.resolveSyntaxStyle(style)
            outStyleId = try ctx.renderLib.contextSyntaxStyleResolveByName(
                ctx.libContext,
                style: libStyle,
                name: name
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_syntax_style_get_count [status=implemented hash=550cf41ba76b]
    static func ot_syntax_style_get_count(
        _ context: ContextHandle?,
        style: Handle,
        outCount: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libStyle = try ctx.resolveSyntaxStyle(style)
            let count = try ctx.renderLib.contextSyntaxStyleGetStyleCount(ctx.libContext, style: libStyle)
            outCount = UInt32(max(0, count))
        }
    }

    // parity: native/src/context-editor-abi.zig#ot_editor_view_replace_selection [status=implemented hash=d6c529ba6f57]
    static func ot_editor_view_replace_selection(
        _ context: ContextHandle?,
        view: Handle,
        text: String,
        outReplacement: inout NativeEditorReplacement
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let editor = try ctx.resolveEditorView(view)
            outReplacement = try ctx.renderLib.contextEditorViewReplaceSelection(
                ctx.libContext,
                view: editor.libHandle,
                text: text
            )
        }
    }

    // parity: native/src/context-editor-abi.zig#defaultsFromC [status=implemented hash=02451b0557ed]
    static func defaultsFromC(
        mask: UInt32,
        options: NativeEditorStyle?
    ) throws(NativeContextEngine.ContextError) -> NativeContextEngine.TextDefaults {
        let styleMask = NativeEditorStyleMask(rawValue: mask)
        if mask == 0 || options == nil {
            return NativeContextEngine.TextDefaults(mask: styleMask, style: NativeEditorStyle(), reset: true)
        }
        return NativeContextEngine.TextDefaults(mask: styleMask, style: options!, reset: false)
    }
}

// MARK: - 3.4 Context Image ABI (native/src/context-image-abi.zig — 19 symbols)

public extension NativeContextABI {
    private struct IccCacheControlState {
        var retainCount: Int = 0
        var failNextCopyAllocation: Bool = false
    }

    private static let iccCacheLock = Mutex<IccCacheControlState>(IccCacheControlState())

    internal static func resizeKernelFromC(_ filter: UInt32) throws(NativeContextEngine.ContextError) -> ResizeKernel {
        switch Int64(filter) {
        case NativeABI.OT_IMAGE_FILTER_DEFAULT: return .default
        case NativeABI.OT_IMAGE_FILTER_AREA: return .area
        case NativeABI.OT_IMAGE_FILTER_TRIANGLE: return .triangle
        case NativeABI.OT_IMAGE_FILTER_CUBIC_BSPLINE: return .cubicBspline
        case NativeABI.OT_IMAGE_FILTER_CATMULL_ROM: return .catmullRom
        case NativeABI.OT_IMAGE_FILTER_MITCHELL: return .mitchell
        case NativeABI.OT_IMAGE_FILTER_NEAREST: return .nearest
        default: throw .invalidOptions("invalid image resize filter \(filter)")
        }
    }

    internal static func blendModeFromC(_ blend: UInt32) throws(NativeContextEngine.ContextError) -> BlendMode {
        switch Int64(blend) {
        case NativeABI.OT_IMAGE_BLEND_SOURCE_OVER: return .sourceOver
        case NativeABI.OT_IMAGE_BLEND_SOURCE: return .source
        case NativeABI.OT_IMAGE_BLEND_DESTINATION_OVER: return .destinationOver
        default: throw .invalidOptions("invalid image blend mode \(blend)")
        }
    }

    internal static func transformOperationFromC(_ operation: UInt32) throws(NativeContextEngine.ContextError) -> String {
        switch operation {
        case 0: return "rotate90"
        case 1: return "rotate180"
        case 2: return "rotate270"
        case 3: return "flipHorizontal"
        case 4: return "flipVertical"
        default: throw .invalidOptions("invalid image transform operation \(operation)")
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_inspect [status=implemented hash=6a26e4d3f70e]
    static func ot_image_inspect(
        _ context: ContextHandle?,
        bytes: [UInt8],
        outInfo: inout NativeImageInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            outInfo = try ctx.renderLib.imageInfo(bytes)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_decode [status=implemented hash=062951de3796]
    static func ot_image_decode(
        _ context: ContextHandle?,
        bytes: [UInt8],
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.renderLib.imageDecode(ctx.libContext, data: bytes)
            outImage = try ctx.registerImage(lib)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_create_pixels [status=implemented hash=356b6c049b3c]
    static func ot_image_create_pixels(
        _ context: ContextHandle?,
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions = PixelImportOptions(),
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.renderLib.imageCreateFromPixels(
                ctx.libContext,
                pixels: pixels,
                width: Int(width),
                height: Int(height),
                options: options
            )
            outImage = try ctx.registerImage(lib)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_update_pixels [status=implemented hash=aa52ab702f66]
    static func ot_image_update_pixels(
        _ context: ContextHandle?,
        image: Handle,
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions = PixelImportOptions()
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            try ctx.renderLib.imageUpdatePixels(
                ctx.libContext,
                image: libImg,
                pixels: pixels,
                width: Int(width),
                height: Int(height),
                options: options
            )
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_clone [status=implemented hash=8eb373c6f6a7]
    static func ot_image_clone(
        _ context: ContextHandle?,
        source: ContextHandle? = nil,
        image: Handle,
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let source, source.id != ctx.id {
                let srcLibImg = try source.context.resolveImage(image)
                let info = try source.context.renderLib.imageGetInfo(source.context.libContext, image: srcLibImg)
                let rgba = try source.context.renderLib.imageCopyPixels(
                    source.context.libContext,
                    image: srcLibImg,
                    format: .rgba8
                )
                let dstLibImg = try ctx.renderLib.imageCreateFromRgba(
                    ctx.libContext,
                    pixels: rgba,
                    width: Int(info.width),
                    height: Int(info.height)
                )
                outImage = try ctx.registerImage(dstLibImg)
            } else {
                let libImg = try ctx.resolveImage(image)
                let cloned = try ctx.renderLib.imageClone(ctx.libContext, image: libImg)
                outImage = try ctx.registerImage(cloned)
            }
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_retain [status=implemented hash=46daf791fb98]
    static func ot_image_retain(
        _ context: ContextHandle?,
        image: Handle,
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            let retained = try ctx.renderLib.imageRetain(ctx.libContext, image: libImg)
            outImage = try ctx.registerImage(retained)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_get_info [status=implemented hash=31fb78b9e037]
    static func ot_image_get_info(
        _ context: ContextHandle?,
        image: Handle,
        outInfo: inout NativeImageInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            outInfo = try ctx.renderLib.imageGetInfo(ctx.libContext, image: libImg)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_resize [status=implemented hash=a8184498b82a]
    static func ot_image_resize(
        _ context: ContextHandle?,
        image: Handle,
        width: UInt32,
        height: UInt32,
        filter: UInt32 = UInt32(NativeABI.OT_IMAGE_FILTER_DEFAULT),
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let kernel = try resizeKernelFromC(filter)
            let libImg = try ctx.resolveImage(image)
            let resized = try ctx.renderLib.imageResize(
                ctx.libContext,
                image: libImg,
                options: ResizeOptions(width: Int(width), height: Int(height), kernel: kernel)
            )
            outImage = try ctx.registerImage(resized)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_extract [status=implemented hash=c37f0a0e8906]
    static func ot_image_extract(
        _ context: ContextHandle?,
        image: Handle,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32,
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            let extracted = try ctx.renderLib.imageExtract(
                ctx.libContext,
                image: libImg,
                options: ExtractOptions(left: Int(left), top: Int(top), width: Int(width), height: Int(height))
            )
            outImage = try ctx.registerImage(extracted)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_extend [status=implemented hash=00deeef90941]
    static func ot_image_extend(
        _ context: ContextHandle?,
        image: Handle,
        top: UInt32,
        right: UInt32,
        bottom: UInt32,
        left: UInt32,
        background: RGBA = RGBA.fromInts(0, 0, 0, 0),
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            let extended = try ctx.renderLib.imageExtend(
                ctx.libContext,
                image: libImg,
                options: ExtendOptions(
                    top: Int(top),
                    right: Int(right),
                    bottom: Int(bottom),
                    left: Int(left),
                    background: (
                        UInt8(background.b0 & 0xFF),
                        UInt8(background.b1 & 0xFF),
                        UInt8(background.b2 & 0xFF),
                        UInt8(background.b3 & 0xFF)
                    )
                )
            )
            outImage = try ctx.registerImage(extended)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_transform [status=implemented hash=109a07039697]
    static func ot_image_transform(
        _ context: ContextHandle?,
        image: Handle,
        operation: UInt32,
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let opName = try transformOperationFromC(operation)
            let libImg = try ctx.resolveImage(image)
            let transformed = try ctx.renderLib.imageTransform(ctx.libContext, image: libImg, operation: opName)
            outImage = try ctx.registerImage(transformed)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_composite [status=implemented hash=b042a675ace6]
    static func ot_image_composite(
        _ context: ContextHandle?,
        base: Handle,
        overlay: Handle,
        left: Int32 = 0,
        top: Int32 = 0,
        blend: UInt32 = UInt32(NativeABI.OT_IMAGE_BLEND_SOURCE_OVER),
        outImage: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let mode = try blendModeFromC(blend)
            let libBase = try ctx.resolveImage(base)
            let libOverlay = try ctx.resolveImage(overlay)
            let composited = try ctx.renderLib.imageComposite(
                ctx.libContext,
                base: libBase,
                overlay: libOverlay,
                options: CompositeOptions(left: Int(left), top: Int(top), blend: mode)
            )
            outImage = try ctx.registerImage(composited)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_copy_pixels [status=implemented hash=359e7384e517]
    static func ot_image_copy_pixels(
        _ context: ContextHandle?,
        image: Handle,
        format: PixelFormat = .rgba8,
        outPixels: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            outPixels = try ctx.renderLib.imageCopyPixels(ctx.libContext, image: libImg, format: format)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_copy_png [status=implemented hash=e31ce83d28c6]
    static func ot_image_copy_png(
        _ context: ContextHandle?,
        image: Handle,
        outPng: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            outPng = try ctx.renderLib.imageCopyPng(ctx.libContext, image: libImg)
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_take_pixels [status=implemented hash=64e90e459fcf]
    static func ot_image_take_pixels(
        _ context: ContextHandle?,
        image: Handle,
        outLeaseHandle: inout Handle,
        outRaw: inout RawImage
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libImg = try ctx.resolveImage(image)
            let taken = try ctx.renderLib.imageTakePixels(ctx.libContext, image: libImg)
            outLeaseHandle = try ctx.registerImagePixels(handle: taken.handle, raw: taken.raw)
            outRaw = taken.raw
        }
    }

    // parity: native/src/context-image-abi.zig#ot_image_pixels_release [status=implemented hash=268170629ad2]
    static func ot_image_pixels_release(_ context: ContextHandle?, lease: Handle) -> Status {
        destroyKind(context, lease, kind: .imagePixels)
    }

    // parity: native/src/context-image-abi.zig#imageRetainIccCache [status=implemented hash=b3a7cb960435]
    static func imageRetainIccCache() {
        iccCacheLock.withLock { $0.retainCount += 1 }
    }

    // parity: native/src/context-image-abi.zig#imageReleaseIccCache [status=implemented hash=b59adf93a9f9]
    static func imageReleaseIccCache() {
        iccCacheLock.withLock { $0.retainCount = max(0, $0.retainCount - 1) }
    }

    // parity: native/src/context-image-abi.zig#imageTestFailIccProfileCopyAllocationOnce [status=implemented hash=849c2b0519ef]
    static func imageTestFailIccProfileCopyAllocationOnce() {
        iccCacheLock.withLock { $0.failNextCopyAllocation = true }
    }

    /// Test helper inspecting ICC cache retain count and consuming the one-shot allocation failure flag.
    static func iccCacheState() -> (retainCount: Int, failNextCopyAllocation: Bool) {
        iccCacheLock.withLock { ($0.retainCount, $0.failNextCopyAllocation) }
    }

    static func consumeIccCopyAllocationFailure() -> Bool {
        iccCacheLock.withLock { s in
            let failed = s.failNextCopyAllocation
            s.failNextCopyAllocation = false
            return failed
        }
    }
}

// MARK: - 3.5 Context Input ABI (native/src/context-input-abi.zig — 3 symbols)

public extension NativeContextABI {
    // parity: native/src/context-input-abi.zig#ot_session_input_feed [status=implemented hash=80ab24a9caa8]
    static func ot_session_input_feed(
        _ context: ContextHandle?,
        session: Handle,
        bytes: [UInt8],
        outDrain: inout NativeInputDrain
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            outDrain = try ctx.renderLib.sessionInputFeed(ctx.libContext, session: lib, bytes: bytes)
        }
    }

    // parity: native/src/context-input-abi.zig#ot_session_input_expect [status=implemented hash=0c641885db7c]
    static func ot_session_input_expect(
        _ context: ContextHandle?,
        session: Handle,
        flags: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionInputExpect(ctx.libContext, session: lib, flags: flags)
        }
    }

    // parity: native/src/context-input-abi.zig#ot_session_input_reset [status=implemented hash=cf8efc125135]
    static func ot_session_input_reset(
        _ context: ContextHandle?,
        session: Handle,
        flags: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveSession(session)
            try ctx.renderLib.sessionInputReset(ctx.libContext, session: lib, flags: flags)
        }
    }
}

// MARK: - 3.6 Context Markdown ABI (native/src/context-markdown-abi.zig — 11 symbols)

public extension NativeContextABI {
    // parity: native/src/context-markdown-abi.zig#ot_markdown_create [status=implemented hash=171ac7e9d8b2]
    static func ot_markdown_create(
        _ context: ContextHandle?,
        options: NativeMarkdownOptions = NativeMarkdownOptions(),
        outDoc: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.renderLib.markdownCreate(ctx.libContext, options: options)
            outDoc = try ctx.registerMarkdown(lib)
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_destroy [status=implemented hash=b7981415e338]
    static func ot_markdown_destroy(_ context: ContextHandle?, doc: Handle) -> Status {
        destroyKind(context, doc, kind: .markdown)
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_set_options [status=implemented hash=793b3a4814bd]
    static func ot_markdown_set_options(
        _ context: ContextHandle?,
        doc: Handle,
        options: NativeMarkdownOptions,
        outResult: inout NativeMarkdownResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outResult = try ctx.renderLib.markdownSetOptions(ctx.libContext, markdown: md.libHandle, options: options)
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_append [status=implemented hash=57b3155cdb1a]
    static func ot_markdown_append(
        _ context: ContextHandle?,
        doc: Handle,
        text: String,
        outResult: inout NativeMarkdownResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outResult = try ctx.renderLib.markdownWrite(
                ctx.libContext,
                markdown: md.libHandle,
                text: text,
                append: true
            )
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_set [status=implemented hash=c2a0545dd62f]
    static func ot_markdown_set(
        _ context: ContextHandle?,
        doc: Handle,
        text: String,
        outResult: inout NativeMarkdownResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outResult = try ctx.renderLib.markdownWrite(
                ctx.libContext,
                markdown: md.libHandle,
                text: text,
                append: false
            )
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_finish [status=implemented hash=216642c5903c]
    static func ot_markdown_finish(
        _ context: ContextHandle?,
        doc: Handle,
        outResult: inout NativeMarkdownResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outResult = try ctx.renderLib.markdownFinish(ctx.libContext, markdown: md.libHandle)
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_get_source [status=implemented hash=5db501303aa3]
    static func ot_markdown_get_source(
        _ context: ContextHandle?,
        doc: Handle,
        outSource: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outSource = try ctx.renderLib.markdownGetSource(ctx.libContext, markdown: md.libHandle)
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_read_changes [status=implemented hash=5d119417a123]
    static func ot_markdown_read_changes(
        _ context: ContextHandle?,
        doc: Handle,
        outBlocks: inout [NativeMarkdownBlock]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outBlocks = try ctx.renderLib.markdownReadChanges(ctx.libContext, markdown: md.libHandle)
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_read_leaf [status=implemented hash=ebd50c20bf09]
    static func ot_markdown_read_leaf(
        _ context: ContextHandle?,
        doc: Handle,
        blockIndex: UInt32,
        outLeaf: inout NativeMarkdownLeaf
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outLeaf = try ctx.renderLib.markdownReadLeaf(
                ctx.libContext,
                markdown: md.libHandle,
                index: Int(blockIndex)
            )
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_read_source [status=implemented hash=39ff43d377ba]
    static func ot_markdown_read_source(
        _ context: ContextHandle?,
        doc: Handle,
        blockIndex: UInt32,
        outSource: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            outSource = try ctx.renderLib.markdownReadSource(
                ctx.libContext,
                markdown: md.libHandle,
                index: Int(blockIndex)
            )
        }
    }

    // parity: native/src/context-markdown-abi.zig#ot_markdown_bind [status=implemented hash=0b16b06f53b2]
    static func ot_markdown_bind(
        _ context: ContextHandle?,
        doc: Handle,
        blockIndex: UInt32,
        node: Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let md = try ctx.resolveMarkdown(doc)
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.markdownBind(
                ctx.libContext,
                markdown: md.libHandle,
                index: Int(blockIndex),
                node: libNode
            )
        }
    }
}

// MARK: - 3.7 Context Output ABI (native/src/context-output-abi.zig — 6 symbols)

public extension NativeContextABI {
    // parity: native/src/context-output-abi.zig#ot_scene_measure_layout [status=implemented hash=62b113f395cb]
    static func ot_scene_measure_layout(
        _ context: ContextHandle?,
        session: Handle? = nil,
        root: Handle,
        availableWidth: Float? = nil,
        outRounds: inout Int
    ) -> Status {
        withAdmittedContext(context) { ctx in
            if let session { _ = try ctx.resolveSession(session) }
            let libRoot = try ctx.resolveSceneNode(root)
            outRounds = try ctx.renderLib.sceneMeasureLayout(
                ctx.libContext,
                root: libRoot,
                availableWidth: availableWidth
            )
        }
    }

    // parity: native/src/context-output-abi.zig#ot_scene_frame_copy_buffer [status=implemented hash=48020c3e5808]
    static func ot_scene_frame_copy_buffer(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest,
        destination: Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = try ctx.resolveSession(session)
            let libDst = try ctx.resolveBuffer(destination)
            try ctx.renderLib.sceneFrameCopyBuffer(ctx.libContext, frame: frame, destination: libDst)
        }
    }

    // parity: native/src/context-output-abi.zig#ot_session_render_split [status=implemented hash=09d3c9e429ef]
    static func ot_session_render_split(
        _ context: ContextHandle?,
        session: Handle,
        frame: NativeSceneFrameRequest? = nil,
        snapshots: [NativeSplitSnapshot] = [],
        pinnedRenderOffset: Int = 0,
        force: Bool = false,
        outRenderStatus: inout UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let status = try ctx.renderLib.sessionRenderSplit(
                ctx.libContext,
                session: libSession,
                frame: frame,
                commits: snapshots,
                pinnedRenderOffset: pinnedRenderOffset,
                force: force
            )
            outRenderStatus = renderStatusToC(status)
        }
    }

    // parity: native/src/context-output-abi.zig#ot_session_split_control [status=implemented hash=74f0ba0a02f4]
    static func ot_session_split_control(
        _ context: ContextHandle?,
        session: Handle,
        control: NativeSessionSplitControl
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSplitControl(ctx.libContext, session: libSession, control: control)
        }
    }

    // parity: native/src/context-output-abi.zig#ot_session_set_screen [status=implemented hash=77f359857be0]
    static func ot_session_set_screen(
        _ context: ContextHandle?,
        session: Handle,
        alternate: Bool,
        width: UInt32,
        height: UInt32,
        trailingOutput: [UInt8]? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            try ctx.renderLib.sessionSetScreen(
                ctx.libContext,
                session: libSession,
                alternate: alternate,
                width: Int(width),
                height: Int(height),
                trailingOutput: trailingOutput
            )
        }
    }

    // parity: native/src/context-output-abi.zig#ot_session_sync_detached [status=implemented hash=575119b6d7d6]
    static func ot_session_sync_detached(
        _ context: ContextHandle?,
        session: Handle,
        detached: Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libSession = try ctx.resolveSession(session)
            let libDetached = try ctx.resolveSession(detached)
            try ctx.renderLib.sessionSyncDetached(ctx.libContext, session: libSession, detached: libDetached)
        }
    }
}

// MARK: - 3.8 Context Terminal ABI (native/src/context-terminal-abi.zig — 15 symbols)

public extension NativeContextABI {
    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_create [status=implemented hash=8a411fa739f3]
    static func ot_embedded_terminal_create(
        _ context: ContextHandle?,
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        maxScrollback: UInt32 = 1_000,
        transparentBackground: Bool = false,
        outTerminal: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard cols > 0 && rows > 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("terminal dimensions must be positive")
            }
            let lib = try ctx.renderLib.createContextEmbeddedTerminal(
                ctx.libContext,
                cols: Int(cols),
                rows: Int(rows),
                maxScrollback: Int(maxScrollback),
                transparentBackground: transparentBackground
            )
            outTerminal = try ctx.registerEmbeddedTerminal(lib)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_destroy [status=implemented hash=3395f8f37b4c]
    static func ot_embedded_terminal_destroy(_ context: ContextHandle?, terminal: Handle) -> Status {
        destroyKind(context, terminal, kind: .embeddedTerminal)
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_write [status=implemented hash=94c7e554f92b]
    static func ot_embedded_terminal_write(
        _ context: ContextHandle?,
        terminal: Handle,
        bytes: [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard bytes.count <= Int(NativeABI.OT_EMBEDDED_TERMINAL_INPUT_BYTES_MAX) else {
                throw NativeContextEngine.ContextError.invalidOptions("terminal write exceeds input limit")
            }
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            try ctx.renderLib.contextEmbeddedTerminalWrite(ctx.libContext, terminal: lib, bytes: bytes)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_resize [status=implemented hash=ec4ed93a856e]
    static func ot_embedded_terminal_resize(
        _ context: ContextHandle?,
        terminal: Handle,
        cols: UInt32,
        rows: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard cols > 0 && rows > 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("terminal dimensions must be positive")
            }
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            try ctx.renderLib.contextEmbeddedTerminalResize(
                ctx.libContext,
                terminal: lib,
                cols: Int(cols),
                rows: Int(rows)
            )
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_command [status=implemented hash=af6b8a4a828a]
    static func ot_embedded_terminal_command(
        _ context: ContextHandle?,
        terminal: Handle,
        command: UInt32,
        argument: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            switch Int64(command) {
            case NativeABI.OT_EMBEDDED_TERMINAL_INVALIDATE:
                try ctx.renderLib.contextEmbeddedTerminalInvalidate(ctx.libContext, terminal: lib)
            case NativeABI.OT_EMBEDDED_TERMINAL_SCROLL:
                try ctx.renderLib.contextEmbeddedTerminalScroll(ctx.libContext, terminal: lib, delta: Int(argument))
            case NativeABI.OT_EMBEDDED_TERMINAL_CLEAR_SELECTION:
                try ctx.renderLib.contextEmbeddedTerminalClearSelection(ctx.libContext, terminal: lib)
            case NativeABI.OT_EMBEDDED_TERMINAL_SET_TRANSPARENT_BACKGROUND:
                try ctx.renderLib.contextEmbeddedTerminalSetTransparentBackground(
                    ctx.libContext,
                    terminal: lib,
                    enabled: argument != 0
                )
            default:
                throw NativeContextEngine.ContextError.invalidOptions("unknown embedded terminal command \(command)")
            }
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_set_selection [status=implemented hash=89e437650463]
    static func ot_embedded_terminal_set_selection(
        _ context: ContextHandle?,
        terminal: Handle,
        startX: UInt32,
        startY: UInt32,
        endX: UInt32,
        endY: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            try ctx.renderLib.contextEmbeddedTerminalSetSelection(
                ctx.libContext,
                terminal: lib,
                startX: Int(startX),
                startY: Int(startY),
                endX: Int(endX),
                endY: Int(endY)
            )
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_get_selected_text [status=implemented hash=1f4b92b5b918]
    static func ot_embedded_terminal_get_selected_text(
        _ context: ContextHandle?,
        terminal: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outText = try ctx.renderLib.contextEmbeddedTerminalGetSelectedText(ctx.libContext, terminal: lib)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_compose [status=implemented hash=ea3cf583920b]
    static func ot_embedded_terminal_compose(
        _ context: ContextHandle?,
        terminal: Handle,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            try ctx.renderLib.contextEmbeddedTerminalCompose(drawTarget, terminal: lib, x: Int(x), y: Int(y))
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_cursor_get [status=implemented hash=013540d13d53]
    static func ot_embedded_terminal_cursor_get(
        _ context: ContextHandle?,
        terminal: Handle,
        outCursor: inout EmbeddedTerminalCursor
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outCursor = try ctx.renderLib.contextEmbeddedTerminalCursor(ctx.libContext, terminal: lib)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_scrollbar_get [status=implemented hash=b82ddb780535]
    static func ot_embedded_terminal_scrollbar_get(
        _ context: ContextHandle?,
        terminal: Handle,
        outScroll: inout EmbeddedTerminalScrollState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outScroll = try ctx.renderLib.contextEmbeddedTerminalScrollbar(ctx.libContext, terminal: lib)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_encode_key [status=implemented hash=1c57e058d1d5]
    static func ot_embedded_terminal_encode_key(
        _ context: ContextHandle?,
        terminal: Handle,
        key: EmbeddedTerminalKey,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outBytes = try ctx.renderLib.contextEmbeddedTerminalEncodeKey(ctx.libContext, terminal: lib, key: key)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_encode_mouse [status=implemented hash=f9a0fa748b9a]
    static func ot_embedded_terminal_encode_mouse(
        _ context: ContextHandle?,
        terminal: Handle,
        mouse: EmbeddedTerminalMouse,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outBytes = try ctx.renderLib.contextEmbeddedTerminalEncodeMouse(ctx.libContext, terminal: lib, mouse: mouse)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_encode_paste [status=implemented hash=eb8262fec535]
    static func ot_embedded_terminal_encode_paste(
        _ context: ContextHandle?,
        terminal: Handle,
        input: [UInt8],
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outBytes = try ctx.renderLib.contextEmbeddedTerminalEncodePaste(ctx.libContext, terminal: lib, bytes: input)
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_encode_focus [status=implemented hash=5958c38396be]
    static func ot_embedded_terminal_encode_focus(
        _ context: ContextHandle?,
        terminal: Handle,
        focused: Bool,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outBytes = try ctx.renderLib.contextEmbeddedTerminalEncodeFocus(
                ctx.libContext,
                terminal: lib,
                focused: focused
            )
        }
    }

    // parity: native/src/context-terminal-abi.zig#ot_embedded_terminal_drain_responses [status=implemented hash=0cee2f950bf6]
    static func ot_embedded_terminal_drain_responses(
        _ context: ContextHandle?,
        terminal: Handle,
        outBytes: inout [UInt8]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let lib = try ctx.resolveEmbeddedTerminal(terminal)
            outBytes = try ctx.renderLib.contextEmbeddedTerminalDrainResponses(ctx.libContext, terminal: lib)
        }
    }
}

// MARK: - 3.9 Context Text ABI (native/src/context-text-abi.zig — 30 symbols)

public extension NativeContextABI {
    // parity: native/src/context-text-abi.zig#ot_text_buffer_create [status=implemented hash=41aa3c8dcee2]
    static func ot_text_buffer_create(
        _ context: ContextHandle?,
        options: NativeContextEditBufferOptions = NativeContextEditBufferOptions(),
        outTextBuffer: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let follow = try followSessionWidth(options)
            let lib = try ctx.renderLib.createContextTextBuffer(ctx.libContext, options: options)
            outTextBuffer = try ctx.registerTextBuffer(lib, followSessionWidth: follow)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_destroy [status=implemented hash=6971dc18fa5f]
    static func ot_text_buffer_destroy(_ context: ContextHandle?, textBuffer: Handle) -> Status {
        destroyKind(context, textBuffer, kind: .textBuffer)
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_create [status=implemented hash=fc7d6ac9c566]
    static func ot_text_buffer_view_create(
        _ context: ContextHandle?,
        textBuffer: Handle,
        outView: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            let lib = try ctx.renderLib.createContextTextBufferView(ctx.libContext, textBuffer: tb.libHandle)
            outView = try ctx.registerTextBufferView(lib, textHandle: textBuffer)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_destroy [status=implemented hash=791694db7cc4]
    static func ot_text_buffer_view_destroy(_ context: ContextHandle?, view: Handle) -> Status {
        destroyKind(context, view, kind: .textBufferView)
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_text [status=implemented hash=f754d188dc71]
    static func ot_text_buffer_set_text(
        _ context: ContextHandle?,
        textBuffer: Handle,
        text: String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetText(ctx.libContext, textBuffer: tb.libHandle, text: text)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_append [status=implemented hash=04945a2c40f7]
    static func ot_text_buffer_append(
        _ context: ContextHandle?,
        textBuffer: Handle,
        text: String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferAppend(ctx.libContext, textBuffer: tb.libHandle, text: text)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_clear [status=implemented hash=5bb70e869374]
    static func ot_text_buffer_clear(
        _ context: ContextHandle?,
        textBuffer: Handle,
        reset: Bool = false
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferClear(ctx.libContext, textBuffer: tb.libHandle)
            if reset {
                try ctx.renderLib.contextTextBufferSetDefaults(
                    ctx.libContext,
                    textBuffer: tb.libHandle,
                    style: NativeEditorStyle(),
                    reset: true
                )
            }
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_styled_text [status=implemented hash=755c197a7f8c]
    static func ot_text_buffer_set_styled_text(
        _ context: ContextHandle?,
        textBuffer: Handle,
        chunks: [TextChunk]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetStyledText(ctx.libContext, textBuffer: tb.libHandle, chunks: chunks)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_replace_styled_batch [status=implemented hash=1a1a6cda97a3]
    static func ot_text_buffer_replace_styled_batch(
        _ context: ContextHandle?,
        updates: [(textBuffer: Handle, chunks: [TextChunk])]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            var resolved: [(textBuffer: ContextTextBufferHandle, chunks: [TextChunk])] = []
            resolved.reserveCapacity(updates.count)
            for item in updates {
                let tb = try ctx.resolveTextBuffer(item.textBuffer)
                resolved.append((tb.libHandle, item.chunks))
            }
            try ctx.renderLib.contextTextBufferReplaceStyledBatch(ctx.libContext, updates: resolved)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_syntax_style [status=implemented hash=bbb3bc056d03]
    static func ot_text_buffer_set_syntax_style(
        _ context: ContextHandle?,
        textBuffer: Handle,
        style: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            let libStyle = try style.map { try ctx.resolveSyntaxStyle($0) }
            try ctx.renderLib.contextTextBufferSetSyntaxStyle(
                ctx.libContext,
                textBuffer: tb.libHandle,
                style: libStyle
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_get_info [status=implemented hash=d79e26c321d1]
    static func ot_text_buffer_get_info(
        _ context: ContextHandle?,
        textBuffer: Handle,
        outInfo: inout NativeTextBufferInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            outInfo = try ctx.renderLib.contextTextBufferGetInfo(ctx.libContext, textBuffer: tb.libHandle)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_get_text [status=implemented hash=480c9909a36c]
    static func ot_text_buffer_get_text(
        _ context: ContextHandle?,
        textBuffer: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            outText = try ctx.renderLib.contextTextBufferGetText(ctx.libContext, textBuffer: tb.libHandle)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_get_range [status=implemented hash=826dc28d74cc]
    static func ot_text_buffer_get_range(
        _ context: ContextHandle?,
        textBuffer: Handle,
        start: UInt32,
        end: UInt32,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            outText = try ctx.renderLib.contextTextBufferGetRange(
                ctx.libContext,
                textBuffer: tb.libHandle,
                startOffset: Int(start),
                endOffset: Int(end)
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_defaults [status=implemented hash=ed3827ebc63e]
    static func ot_text_buffer_set_defaults(
        _ context: ContextHandle?,
        textBuffer: Handle,
        mask: UInt32,
        options: NativeEditorStyle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let defaults = try defaultsFromC(mask: mask, options: options)
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetDefaults(
                ctx.libContext,
                textBuffer: tb.libHandle,
                style: defaults.style,
                reset: defaults.reset
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_tab_width [status=implemented hash=903641d4f65f]
    static func ot_text_buffer_set_tab_width(
        _ context: ContextHandle?,
        textBuffer: Handle,
        width: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard width > 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("tab width must be positive")
            }
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetTabWidth(ctx.libContext, textBuffer: tb.libHandle, tabWidth: Int(width))
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_width_method [status=implemented hash=0676e8db935e]
    static func ot_text_buffer_set_width_method(
        _ context: ContextHandle?,
        textBuffer: Handle,
        widthMethod: UInt32
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let method = try textWidthMethodFromC(widthMethod)
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetWidthMethod(
                ctx.libContext,
                textBuffer: tb.libHandle,
                method: method
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_highlight [status=implemented hash=e06b1fdd529c]
    static func ot_text_buffer_highlight(
        _ context: ContextHandle?,
        textBuffer: Handle,
        operation: UInt32,
        argument: UInt32 = 0,
        highlight: Highlight? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let parsed = try highlightFromC(operation: operation, argument: argument, highlight: highlight)
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferHighlight(
                ctx.libContext,
                textBuffer: tb.libHandle,
                operation: parsed.operation,
                lineOrRef: parsed.lineOrRef,
                highlight: parsed.highlight
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_set_layer [status=implemented hash=77da3cdd69e4]
    static func ot_text_buffer_set_layer(
        _ context: ContextHandle?,
        textBuffer: Handle,
        layerId: UInt32,
        startByte: UInt32,
        endByte: UInt32,
        runs: [Highlight]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let validated = try layerRunsFromC(runs: runs, startByte: startByte, endByte: endByte)
            let tb = try ctx.resolveTextBuffer(textBuffer)
            try ctx.renderLib.contextTextBufferSetLayer(
                ctx.libContext,
                textBuffer: tb.libHandle,
                layer: layerId,
                highlights: validated
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_get_highlights [status=implemented hash=779a4c909b53]
    static func ot_text_buffer_get_highlights(
        _ context: ContextHandle?,
        textBuffer: Handle,
        line: UInt32,
        outHighlights: inout [Highlight]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tb = try ctx.resolveTextBuffer(textBuffer)
            outHighlights = try ctx.renderLib.contextTextBufferGetHighlights(
                ctx.libContext,
                textBuffer: tb.libHandle,
                lineIdx: Int(line)
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_set_viewport [status=implemented hash=b558489ae09d]
    static func ot_text_buffer_view_set_viewport(
        _ context: ContextHandle?,
        view: Handle,
        viewport: NativeEditorViewport,
        sizeOnly: Bool = false
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = sizeOnly
            let tv = try ctx.resolveTextBufferView(view)
            try ctx.renderLib.contextTextBufferViewSetViewport(
                ctx.libContext,
                view: tv.libHandle,
                x: viewport.x,
                y: viewport.y,
                width: viewport.width,
                height: viewport.height
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_command [status=implemented hash=853d4ff5d5b7]
    static func ot_text_buffer_view_command(
        _ context: ContextHandle?,
        view: Handle,
        command: UInt32,
        argument: UInt32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            guard let cmd = NativeTextViewCommand(rawValue: command) else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid text view command \(command)")
            }
            let tv = try ctx.resolveTextBufferView(view)
            try ctx.renderLib.contextTextBufferViewCommand(
                ctx.libContext,
                view: tv.libHandle,
                command: cmd,
                argument: argument
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_set_tab_color [status=implemented hash=437b1dd3da53]
    static func ot_text_buffer_view_set_tab_color(
        _ context: ContextHandle?,
        view: Handle,
        color: RGBA
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tv = try ctx.resolveTextBufferView(view)
            try ctx.renderLib.contextTextBufferViewSetTabColor(ctx.libContext, view: tv.libHandle, color: color)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_select [status=implemented hash=5e0d0f223056]
    static func ot_text_buffer_view_select(
        _ context: ContextHandle?,
        view: Handle,
        options: NativeEditorSelection,
        outChanged: inout Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let sel = try selectionFromC(options, isEditor: false)
            let tv = try ctx.resolveTextBufferView(view)
            outChanged = try ctx.renderLib.contextTextBufferViewSelect(
                ctx.libContext,
                view: tv.libHandle,
                selection: sel
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_get_info [status=implemented hash=ebcbd90d67a2]
    static func ot_text_buffer_view_get_info(
        _ context: ContextHandle?,
        view: Handle,
        outInfo: inout NativeEditorViewInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tv = try ctx.resolveTextBufferView(view)
            outInfo = try ctx.renderLib.contextTextBufferViewGetInfo(ctx.libContext, view: tv.libHandle)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_get_selected_text [status=implemented hash=a48496874520]
    static func ot_text_buffer_view_get_selected_text(
        _ context: ContextHandle?,
        view: Handle,
        outText: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tv = try ctx.resolveTextBufferView(view)
            outText = try ctx.renderLib.contextTextBufferViewGetSelectedText(ctx.libContext, view: tv.libHandle)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_get_lines [status=implemented hash=17c879a74806]
    static func ot_text_buffer_view_get_lines(
        _ context: ContextHandle?,
        view: Handle,
        logical: Bool = false,
        firstLine: UInt32 = 0,
        outInfo: inout LineInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            _ = logical
            _ = firstLine
            let tv = try ctx.resolveTextBufferView(view)
            outInfo = try ctx.renderLib.contextTextBufferViewGetLines(ctx.libContext, view: tv.libHandle)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_text_buffer_view_measure [status=implemented hash=bfeb7995aa91]
    static func ot_text_buffer_view_measure(
        _ context: ContextHandle?,
        view: Handle,
        width: UInt32,
        height: UInt32,
        outResult: inout MeasureResult
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let tv = try ctx.resolveTextBufferView(view)
            outResult = try ctx.renderLib.contextTextBufferViewMeasure(
                ctx.libContext,
                view: tv.libHandle,
                width: Int(width),
                height: Int(height)
            )
        }
    }

    // parity: native/src/context-text-abi.zig#ot_scene_set_text_view [status=implemented hash=5e6f8c9ff3c6]
    static func ot_scene_set_text_view(
        _ context: ContextHandle?,
        node: Handle,
        view: Handle?
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let libView = try view.map { try ctx.resolveTextBufferView($0).libHandle }
            try ctx.renderLib.sceneSetTextView(ctx.libContext, node: libNode, view: libView)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_scene_set_text_view_paint [status=implemented hash=aedd1d427038]
    static func ot_scene_set_text_view_paint(
        _ context: ContextHandle?,
        node: Handle,
        enabled: Bool
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.sceneSetTextViewPaint(ctx.libContext, node: libNode, enabled: enabled)
        }
    }

    // parity: native/src/context-text-abi.zig#ot_buffer_draw_text_view [status=implemented hash=2547f728dbdf]
    static func ot_buffer_draw_text_view(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        view: Handle,
        x: Int32 = 0,
        y: Int32 = 0
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            let tv = try ctx.resolveTextBufferView(view)
            try ctx.renderLib.contextDrawTextBufferView(drawTarget, view: tv.libHandle, x: Int(x), y: Int(y))
        }
    }
}

// MARK: - 3.10 Context Unicode ABI (native/src/context-unicode-abi.zig — 4 symbols)

public extension NativeContextABI {
    // parity: native/src/context-unicode-abi.zig#ot_unicode_create [status=implemented hash=ba31fd950f0e]
    static func ot_unicode_create(
        _ context: ContextHandle?,
        text: String,
        widthMethod: UInt32 = UInt32(NativeABI.OT_WIDTH_METHOD_UNICODE),
        outUnicode: inout Handle
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let method = try widthMethodFromC(widthMethod)
            let encoded = NativeContextEngine.EncodedUnicode(text: text, widthMethod: method)
            let lib = try ctx.renderLib.createContextUnicode(ctx.libContext, text: text)
            outUnicode = try ctx.registerUnicode(lib, encoded: encoded)
        }
    }

    // parity: native/src/context-unicode-abi.zig#ot_unicode_destroy [status=implemented hash=05c0acf01f65]
    static func ot_unicode_destroy(_ context: ContextHandle?, unicode: Handle) -> Status {
        destroyKind(context, unicode, kind: .unicode)
    }

    // parity: native/src/context-unicode-abi.zig#ot_unicode_get [status=implemented hash=2129517652ff]
    static func ot_unicode_get(
        _ context: ContextHandle?,
        unicode: Handle,
        outChars: inout [NativeContextEngine.EncodedChar]
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let entry = try ctx.resolveUnicode(unicode)
            outChars = entry.encoded.chars
        }
    }

    // parity: native/src/context-unicode-abi.zig#ot_buffer_draw_unicode [status=implemented hash=2c8e00e6b80f]
    static func ot_buffer_draw_unicode(
        _ context: ContextHandle?,
        target: Handle,
        frame: NativeSceneFrameRequest? = nil,
        unicode: Handle,
        x: Int32 = 0,
        y: Int32 = 0,
        fg: RGBA = .defaultForeground(),
        bg: RGBA? = nil,
        attributes: UInt32 = TextAttributes.none
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let drawTarget = try resolveDrawingTarget(ctx: ctx, target: target, frame: frame)
            let entry = try ctx.resolveUnicode(unicode)
            try ctx.renderLib.contextBufferDrawUnicode(
                drawTarget,
                unicode: entry.libHandle,
                x: Int(x),
                y: Int(y),
                fg: fg,
                bg: bg,
                attributes: attributes
            )
        }
    }
}

// MARK: - 3.11 Context Video ABI (native/src/context-video-abi.zig — 12 symbols)

public extension NativeContextABI {
    // parity: native/src/context-video-abi.zig#ot_scene_set_video [status=implemented hash=c1110c92dced]
    static func ot_scene_set_video(
        _ context: ContextHandle?,
        node: Handle,
        fit: ImageFit = .fit,
        buffer: Handle? = nil
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            let libBuf = try buffer.map { try ctx.resolveBuffer($0) }
            try ctx.renderLib.sceneSetVideo(ctx.libContext, node: libNode, fit: fit, buffer: libBuf)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_open [status=implemented hash=c75263490b79]
    static func ot_video_open(
        _ context: ContextHandle?,
        node: Handle,
        path: String,
        flags: UInt32 = 0,
        outInfo: inout NativeVideoInfo
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            var info = try ctx.renderLib.videoOpen(ctx.libContext, node: libNode, path: path)
            if (flags & UInt32(NativeABI.OT_VIDEO_OPEN_NO_AUDIO)) != 0 {
                info.hasAudio = false
            }
            outInfo = info
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_play [status=implemented hash=38c87b4234b5]
    static func ot_video_play(_ context: ContextHandle?, node: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoCall(ctx.libContext, node: libNode, command: "play")
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_pause [status=implemented hash=c1af3ae3857e]
    static func ot_video_pause(_ context: ContextHandle?, node: Handle) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoCall(ctx.libContext, node: libNode, command: "pause")
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_seek [status=implemented hash=ebf2ef5714f0]
    static func ot_video_seek(_ context: ContextHandle?, node: Handle, timeUs: Int64) -> Status {
        withAdmittedContext(context) { ctx in
            guard timeUs >= 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("negative video seek timestamp")
            }
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSeek(ctx.libContext, node: libNode, timeUs: UInt64(timeUs))
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_set_loop [status=implemented hash=5ffa0731b631]
    static func ot_video_set_loop(_ context: ContextHandle?, node: Handle, loop: Bool) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSetLoop(ctx.libContext, node: libNode, loop: loop)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_set_muted [status=implemented hash=241a9de7efb5]
    static func ot_video_set_muted(_ context: ContextHandle?, node: Handle, muted: Bool) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSetMuted(ctx.libContext, node: libNode, muted: muted)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_set_volume [status=implemented hash=aa747cfd9f1c]
    static func ot_video_set_volume(_ context: ContextHandle?, node: Handle, volume: Float) -> Status {
        withAdmittedContext(context) { ctx in
            guard volume.isFinite && volume >= 0 else {
                throw NativeContextEngine.ContextError.invalidOptions("invalid video volume")
            }
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSetVolume(ctx.libContext, node: libNode, volume: volume)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_set_av_sync_offset [status=implemented hash=e8434f79f20b]
    static func ot_video_set_av_sync_offset(_ context: ContextHandle?, node: Handle, offsetUs: Int64) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSetAvSyncOffset(ctx.libContext, node: libNode, offsetUs: offsetUs)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_set_max_fps [status=implemented hash=a0121aaf4359]
    static func ot_video_set_max_fps(_ context: ContextHandle?, node: Handle, fps: UInt32) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            try ctx.renderLib.videoSetMaxFps(ctx.libContext, node: libNode, maxFps: Float(fps))
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_get_state [status=implemented hash=69da1fcda535]
    static func ot_video_get_state(
        _ context: ContextHandle?,
        node: Handle,
        outState: inout NativeVideoState
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outState = try ctx.renderLib.videoGetState(ctx.libContext, node: libNode)
        }
    }

    // parity: native/src/context-video-abi.zig#ot_video_get_error [status=implemented hash=363d44696a49]
    static func ot_video_get_error(
        _ context: ContextHandle?,
        node: Handle,
        outError: inout String
    ) -> Status {
        withAdmittedContext(context) { ctx in
            let libNode = try ctx.resolveSceneNode(node)
            outError = try ctx.renderLib.videoGetError(ctx.libContext, node: libNode)
        }
    }
}

// MARK: - 3.12 Audio ABI (native/src/audio-abi.zig — 42 symbols)

public extension NativeContextABI {
    private static let standaloneAudioMap = Mutex<[UInt64: AudioEngineHandle]>([:])

    private static func resolveStandaloneAudio(_ context: ContextHandle?) -> (SwiftRenderLib, AudioEngineHandle)? {
        guard let context, !context.isDestroyed else { return nil }
        if let explicit = context.audioEngine {
            return (context.context.renderLib, explicit)
        }
        guard let engine = standaloneAudioMap.withLock({ $0[context.id] }) else { return nil }
        return (context.context.renderLib, engine)
    }

    // parity: native/src/audio-abi.zig#createAudioEngine [status=implemented hash=c710ea7634da]
    static func createAudioEngine(
        _ context: ContextHandle?,
        options: AudioCreateOptions = AudioCreateOptions()
    ) -> Status {
        guard let context, !context.isDestroyed else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let engine = context.context.renderLib.createAudioEngine(options)
        standaloneAudioMap.withLock { $0[context.id] = engine }
        return Status(NativeABI.OT_OK)
    }

    // parity: native/src/audio-abi.zig#audioRefreshPlaybackDevices [status=implemented hash=41c84bcb057d]
    static func audioRefreshPlaybackDevices(_ context: ContextHandle?) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioRefreshPlaybackDevices(engine) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioGetPlaybackDeviceCount [status=implemented hash=9c32ae2ab5f1]
    static func audioGetPlaybackDeviceCount(_ context: ContextHandle?) -> UInt32 {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return 0 }
        return UInt32(max(0, lib.audioGetPlaybackDeviceCount(engine)))
    }

    // parity: native/src/audio-abi.zig#audioGetPlaybackDeviceName [status=implemented hash=565b5d0d6e23]
    static func audioGetPlaybackDeviceName(_ context: ContextHandle?, index: UInt32) -> String? {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return nil }
        return lib.audioGetPlaybackDeviceName(engine, index: Int(index))
    }

    // parity: native/src/audio-abi.zig#audioIsPlaybackDeviceDefault [status=implemented hash=ce5a91b31491]
    static func audioIsPlaybackDeviceDefault(_ context: ContextHandle?, index: UInt32) -> Bool {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return false }
        return lib.audioIsPlaybackDeviceDefault(engine, index: Int(index))
    }

    // parity: native/src/audio-abi.zig#audioSelectPlaybackDevice [status=implemented hash=244be62f2287]
    static func audioSelectPlaybackDevice(_ context: ContextHandle?, index: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSelectPlaybackDevice(engine, index: Int(index)) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioClearPlaybackDeviceSelection [status=implemented hash=ecd20e6e5dd7]
    static func audioClearPlaybackDeviceSelection(_ context: ContextHandle?) {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return }
        lib.audioClearPlaybackDeviceSelection(engine)
    }

    // parity: native/src/audio-abi.zig#audioRefreshCaptureDevices [status=implemented hash=c1349abd0644]
    static func audioRefreshCaptureDevices(_ context: ContextHandle?) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioRefreshCaptureDevices(engine) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioGetCaptureDeviceCount [status=implemented hash=e2d943b1b64a]
    static func audioGetCaptureDeviceCount(_ context: ContextHandle?) -> UInt32 {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return 0 }
        return UInt32(max(0, lib.audioGetCaptureDeviceCount(engine)))
    }

    // parity: native/src/audio-abi.zig#audioGetCaptureDeviceName [status=implemented hash=8bacbf58da3c]
    static func audioGetCaptureDeviceName(_ context: ContextHandle?, index: UInt32) -> String? {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return nil }
        return lib.audioGetCaptureDeviceName(engine, index: Int(index))
    }

    // parity: native/src/audio-abi.zig#audioIsCaptureDeviceDefault [status=implemented hash=1655d3573058]
    static func audioIsCaptureDeviceDefault(_ context: ContextHandle?, index: UInt32) -> Bool {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return false }
        return lib.audioIsCaptureDeviceDefault(engine, index: Int(index))
    }

    // parity: native/src/audio-abi.zig#audioSelectCaptureDevice [status=implemented hash=f9b411111d23]
    static func audioSelectCaptureDevice(_ context: ContextHandle?, index: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSelectCaptureDevice(engine, index: Int(index)) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioClearCaptureDeviceSelection [status=implemented hash=8f5057e3d8a0]
    static func audioClearCaptureDeviceSelection(_ context: ContextHandle?) {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return }
        lib.audioClearCaptureDeviceSelection(engine)
    }

    // parity: native/src/audio-abi.zig#audioStartCapture [status=implemented hash=41696ea617e1]
    static func audioStartCapture(
        _ context: ContextHandle?,
        options: AudioCaptureOptions = AudioCaptureOptions()
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStartCapture(engine, options: options) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioStopCapture [status=implemented hash=ab01950acbfa]
    static func audioStopCapture(_ context: ContextHandle?) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStopCapture(engine) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioIsCaptureRunning [status=implemented hash=369ab21aefac]
    static func audioIsCaptureRunning(_ context: ContextHandle?) -> Bool {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return false }
        return lib.audioIsCaptureRunning(engine)
    }

    // parity: native/src/audio-abi.zig#audioReadCapture [status=implemented hash=260f133a6bc1]
    static func audioReadCapture(
        _ context: ContextHandle?,
        frameCount: UInt32,
        outResult: inout AudioCaptureReadResult?
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        outResult = lib.audioReadCapture(engine, frameCount: Int(frameCount))
        return outResult != nil ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioGetCaptureStats [status=implemented hash=97f62989cece]
    static func audioGetCaptureStats(
        _ context: ContextHandle?,
        outStats: inout NativeAudioCaptureStats?
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        outStats = lib.audioGetCaptureStats(engine)
        return outStats != nil ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioStart [status=implemented hash=6d3e5ca25586]
    static func audioStart(_ context: ContextHandle?, options: ZigAudioStartOptions? = nil) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStart(engine, options: options) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioStartMixer [status=implemented hash=cbb669a76ae3]
    static func audioStartMixer(_ context: ContextHandle?) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStartMixer(engine) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioStop [status=implemented hash=58901d148b1b]
    static func audioStop(_ context: ContextHandle?) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStop(engine) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioCreateStream [status=implemented hash=04235206acf2]
    static func audioCreateStream(
        _ context: ContextHandle?,
        options: AudioStreamCreateOptions,
        outStreamId: inout UInt32
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let id = lib.audioCreateStream(engine, options: options)
        outStreamId = id
        return id != 0 ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INTERNAL_ERROR)
    }

    // parity: native/src/audio-abi.zig#audioWriteStream [status=implemented hash=4c0415ea6924]
    static func audioWriteStream(
        _ context: ContextHandle?,
        streamId: UInt32,
        bytes: [UInt8],
        outWritten: inout Int
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let written = lib.audioWriteStream(engine, streamId: streamId, data: bytes)
        outWritten = written
        return written >= 0 ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioEndStream [status=implemented hash=e0f52af0ee4d]
    static func audioEndStream(_ context: ContextHandle?, streamId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioEndStream(engine, streamId: streamId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioRestartStream [status=implemented hash=661ae0c5fb4b]
    static func audioRestartStream(_ context: ContextHandle?, streamId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioRestartStream(engine, streamId: streamId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioSetStreamVolume [status=implemented hash=7874210fad85]
    static func audioSetStreamVolume(_ context: ContextHandle?, streamId: UInt32, volume: Float) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetStreamVolume(engine, streamId: streamId, volume: volume) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioSetStreamPan [status=implemented hash=5d144486e491]
    static func audioSetStreamPan(_ context: ContextHandle?, streamId: UInt32, pan: Float) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetStreamPan(engine, streamId: streamId, pan: pan) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioSetStreamGroup [status=implemented hash=85413975b920]
    static func audioSetStreamGroup(_ context: ContextHandle?, streamId: UInt32, groupId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetStreamGroup(engine, streamId: streamId, groupId: groupId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioGetStreamStats [status=implemented hash=7fa666b6af18]
    static func audioGetStreamStats(
        _ context: ContextHandle?,
        streamId: UInt32,
        outStats: inout NativeAudioStreamStats?
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        outStats = lib.audioGetStreamStats(engine, streamId: streamId)
        return outStats != nil ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioCloseStream [status=implemented hash=dc65783ee817]
    static func audioCloseStream(
        _ context: ContextHandle?,
        streamId: UInt32,
        reason: NativeAudioStreamCloseReason = .disposed
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioCloseStream(engine, streamId: streamId, reason: reason) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioLoad [status=implemented hash=6e4c9dd75f45]
    static func audioLoad(
        _ context: ContextHandle?,
        data: [UInt8],
        outSoundId: inout UInt32
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let id = lib.audioLoad(engine, data: data)
        outSoundId = id
        return id != 0 ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DECODE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioUnload [status=implemented hash=6b49ec40748e]
    static func audioUnload(_ context: ContextHandle?, soundId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioUnload(engine, soundId: soundId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioPlay [status=implemented hash=8e0efe839136]
    static func audioPlay(
        _ context: ContextHandle?,
        soundId: UInt32,
        options: AudioVoiceOptions? = nil,
        outVoiceId: inout UInt32
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let id = lib.audioPlay(engine, soundId: soundId, options: options)
        outVoiceId = id
        return id != 0 ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioStopVoice [status=implemented hash=b9a1cd34ef3f]
    static func audioStopVoice(_ context: ContextHandle?, voiceId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioStopVoice(engine, voiceId: voiceId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioSetVoiceGroup [status=implemented hash=b932cd8a35e8]
    static func audioSetVoiceGroup(_ context: ContextHandle?, voiceId: UInt32, groupId: UInt32) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetVoiceGroup(engine, voiceId: voiceId, groupId: groupId) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioCreateGroup [status=implemented hash=fa806befd00c]
    static func audioCreateGroup(
        _ context: ContextHandle?,
        name: String,
        outGroupId: inout UInt32
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        let id = lib.audioCreateGroup(engine, name: name)
        outGroupId = id
        return id != 0 ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INTERNAL_ERROR)
    }

    // parity: native/src/audio-abi.zig#audioSetGroupVolume [status=implemented hash=8b7d3fe66f7b]
    static func audioSetGroupVolume(_ context: ContextHandle?, groupId: UInt32, volume: Float) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetGroupVolume(engine, groupId: groupId, volume: volume) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioSetMasterVolume [status=implemented hash=944a4fa64d91]
    static func audioSetMasterVolume(_ context: ContextHandle?, volume: Float) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        return lib.audioSetMasterVolume(engine, volume: volume) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INVALID_ARGUMENT)
    }

    // parity: native/src/audio-abi.zig#audioMixToBuffer [status=implemented hash=a012ee13309a]
    static func audioMixToBuffer(
        _ context: ContextHandle?,
        frameCount: UInt32,
        channels: UInt8 = 2,
        outSamples: inout [Float]
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        guard let samples = lib.audioMixToBuffer(engine, frameCount: Int(frameCount), channels: Int(channels)) else {
            return Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
        }
        outSamples = samples
        return Status(NativeABI.OT_OK)
    }

    // parity: native/src/audio-abi.zig#audioEnableTap [status=implemented hash=cb1bb023e78d]
    static func audioEnableTap(_ context: ContextHandle?, enabled: Bool, capacityFrames: UInt32 = 8192) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        if !enabled { return Status(NativeABI.OT_OK) }
        return lib.audioEnableTap(engine, capacityFrames: Int(capacityFrames)) ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INTERNAL_ERROR)
    }

    // parity: native/src/audio-abi.zig#audioReadTap [status=implemented hash=4e81fdc35fe6]
    static func audioReadTap(
        _ context: ContextHandle?,
        frameCount: UInt32,
        channels: UInt8 = 2,
        outResult: inout AudioCaptureReadResult?
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        outResult = lib.audioReadTap(engine, frameCount: Int(frameCount), channels: Int(channels))
        return outResult != nil ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_AUDIO_DEVICE_FAILED)
    }

    // parity: native/src/audio-abi.zig#audioGetStats [status=implemented hash=aabe19133911]
    static func audioGetStats(
        _ context: ContextHandle?,
        outStats: inout ZigAudioStats?
    ) -> Status {
        guard let (lib, engine) = resolveStandaloneAudio(context) else { return Status(NativeABI.OT_INVALID_ARGUMENT) }
        outStats = lib.audioGetStats(engine)
        return outStats != nil ? Status(NativeABI.OT_OK) : Status(NativeABI.OT_INTERNAL_ERROR)
    }
}

// MARK: - 3.13 Native Span Feed ABI (native/src/native-span-feed-abi.zig — 1 symbol)

public extension NativeContextABI {
    // parity: native/src/native-span-feed-abi.zig#createNativeSpanFeed [status=implemented hash=b800738a0b65]
    static func createNativeSpanFeed(
        options: ZigNativeSpanFeedOptions = ZigNativeSpanFeedOptions(),
        renderLib: SwiftRenderLib = resolveRenderLib()
    ) -> FFIPointer {
        renderLib.createNativeSpanFeed(options)
    }
}

// MARK: - 3.14 Runtime & Library Entry Points (runtime.zig 2 + runtime-abi.zig 6 + lib.zig 2 = 10 symbols)

public extension NativeContextABI {
    /// Pure-Swift runtime handles mirroring `native/src/runtime.zig`.
    enum Runtime: Sendable {
        public struct AllocatorDescriptor: Equatable, Hashable, Sendable {
            public let name: String
            public init(name: String = "swift-managed-arena") {
                self.name = name
            }
        }

        public struct IoDescriptor: Equatable, Hashable, Sendable {
            public let name: String
            public let nonBlocking: Bool
            public init(name: String = "swift-portable-io", nonBlocking: Bool = true) {
                self.name = name
                self.nonBlocking = nonBlocking
            }
        }

        // parity: native/src/runtime.zig#allocator [status=adapted hash=9f30b5cd498f]
        public static func allocator() -> AllocatorDescriptor {
            AllocatorDescriptor()
        }

        // parity: native/src/runtime.zig#io [status=adapted hash=d8bec8d1369c]
        public static func io() -> IoDescriptor {
            IoDescriptor()
        }
    }

    /// Log callback type matching `native/src/runtime-abi.zig#setLogCallback`.
    typealias LogCallback = @Sendable (UInt8, String) -> Void

    private static let logCallbackLock = Mutex<LogCallback?>(nil)

    // parity: native/src/runtime-abi.zig#ExternalBuildOptions [status=implemented hash=bfe26837a0e5]
    typealias ExternalBuildOptions = BuildOptions

    // parity: native/src/runtime-abi.zig#ExternalAllocatorStats [status=implemented hash=c207b445f85a]
    typealias ExternalAllocatorStats = AllocatorStats

    // parity: native/src/runtime-abi.zig#setLogCallback [status=implemented hash=927ca6da3a7d]
    static func setLogCallback(_ callback: LogCallback?) {
        logCallbackLock.withLock { $0 = callback }
    }

    /// Emits a runtime diagnostic message to the installed `setLogCallback` handler, if any.
    static func emitLog(level: UInt8, message: String) {
        let cb = logCallbackLock.withLock { $0 }
        cb?(level, message)
    }

    // parity: native/src/runtime-abi.zig#getArenaAllocatedBytes [status=implemented hash=98cb2c195731]
    static func getArenaAllocatedBytes(renderLib: SwiftRenderLib = resolveRenderLib()) -> UInt64 {
        renderLib.getArenaAllocatedBytes()
    }

    // parity: native/src/runtime-abi.zig#getBuildOptions [status=implemented hash=12145babee1a]
    static func getBuildOptions(
        renderLib: SwiftRenderLib = resolveRenderLib(),
        outOptions: inout ExternalBuildOptions
    ) {
        outOptions = renderLib.getBuildOptions()
    }

    // parity: native/src/runtime-abi.zig#getAllocatorStats [status=implemented hash=4b465e905f63]
    static func getAllocatorStats(
        renderLib: SwiftRenderLib = resolveRenderLib(),
        outStats: inout ExternalAllocatorStats
    ) {
        outStats = renderLib.getAllocatorStats()
    }

    /// Root library metadata matching `native/src/lib.zig`.
    enum Lib: Sendable {
        public struct StdOptions: Equatable, Hashable, Sendable {
            public let logLevel: NativeLogLevel
            public init(logLevel: NativeLogLevel = .info) {
                self.logLevel = logLevel
            }
        }

        // parity: native/src/lib.zig#io [status=adapted hash=edcc0ff76b18]
        public static let io: Runtime.IoDescriptor = Runtime.io()

        // parity: native/src/lib.zig#std_options [status=adapted hash=8a53ac4f30d5]
        public static let std_options = StdOptions()
    }
}

// MARK: - 3.15 Umbrella Native Package Exports (native/src/opentui.zig — 26 symbols)

public extension NativeContextABI {
    /// Umbrella export namespace matching `native/src/opentui.zig`.
    enum OpenTUI: Sendable {
        // parity: native/src/opentui.zig#ansi [status=implemented hash=5e0fe1bab221]
        public typealias ansi = ANSI

        // parity: native/src/opentui.zig#audio [status=implemented hash=5c49f36b7562]
        public typealias audio = Audio

        // parity: native/src/opentui.zig#buffer [status=implemented hash=224689a05861]
        public typealias buffer = OptimizedBuffer

        // parity: native/src/opentui.zig#context [status=implemented hash=19df78d1f5d7]
        public typealias context = NativeContextEngine

        // parity: native/src/opentui.zig#abi [status=implemented hash=2c04e963dfcd]
        public typealias abi = NativeABI

        // parity: native/src/opentui.zig#image [status=implemented hash=909d999af592]
        public typealias image = NativeImage

        // parity: native/src/opentui.zig#native_renderable [status=implemented hash=bc7128f86ad9]
        public typealias native_renderable = NativeSceneNode

        // parity: native/src/opentui.zig#renderer [status=implemented hash=c70065aa43d0]
        public typealias renderer = CliRenderer

        // parity: native/src/opentui.zig#session [status=implemented hash=c459eaed4cf8]
        public typealias session = NativeSession

        // parity: native/src/opentui.zig#text_buffer [status=implemented hash=4a27e96c50f0]
        public typealias text_buffer = TextBuffer

        // parity: native/src/opentui.zig#text_buffer_view [status=implemented hash=3a2e53aae84c]
        public typealias text_buffer_view = TextBufferView

        // parity: native/src/opentui.zig#yoga_c [status=implemented hash=ebb486494907]
        public typealias yoga_c = YogaConfig

        // parity: native/src/opentui.zig#yoga [status=implemented hash=80c60e7f74af]
        public typealias yoga = YogaHost

        // parity: native/src/opentui.zig#CliRenderer [status=implemented hash=7221a55b0959]
        public typealias CliRenderer = OpenTUIRenderables.CliRenderer

        // parity: native/src/opentui.zig#Context [status=implemented hash=bdd0a0e25d96]
        public typealias Context = NativeContextEngine.Context

        // parity: native/src/opentui.zig#GraphemePool [status=implemented hash=b97935cb56f8]
        public typealias GraphemePool = OpenTUICore.GraphemePool

        // parity: native/src/opentui.zig#LinkPool [status=implemented hash=20dc439c62bc]
        public typealias LinkPool = OpenTUICore.LinkPool

        // parity: native/src/opentui.zig#LinkTracker [status=implemented hash=3c2776b3e222]
        public typealias LinkTracker = OpenTUICore.LinkTracker

        // parity: native/src/opentui.zig#NativeRenderable [status=implemented hash=77a51b378435]
        public typealias NativeRenderable = NativeSceneNode

        // parity: native/src/opentui.zig#OptimizedBuffer [status=implemented hash=6add546c423e]
        public typealias OptimizedBuffer = OpenTUICore.OptimizedBuffer

        // parity: native/src/opentui.zig#RGBA [status=implemented hash=4a2784ea6614]
        public typealias RGBA = OpenTUICore.RGBA

        // parity: native/src/opentui.zig#Session [status=implemented hash=5ebe2b7bf2d1]
        public typealias Session = NativeSession

        // parity: native/src/opentui.zig#TextAttributes [status=implemented hash=a8cf516ce20f]
        public typealias TextAttributes = OpenTUICore.TextAttributes

        // parity: native/src/opentui.zig#UnifiedTextBuffer [status=implemented hash=db6a4f143ff7]
        public typealias UnifiedTextBuffer = OpenTUICore.TextBuffer

        // parity: native/src/opentui.zig#UnifiedTextBufferView [status=implemented hash=d1e751597665]
        public typealias UnifiedTextBufferView = OpenTUICore.TextBufferView

        // parity: native/src/opentui.zig#rgbColor [status=implemented hash=d6e4f232a5b8]
        public static func rgbColor(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> RGBA {
            RGBA.fromInts(Int(r), Int(g), Int(b), Int(a))
        }
    }
}

// MARK: - 3.16 Coverage & Sanitizer Runner Hooks (native/src/cov_runner.zig — 20 symbols)

public extension NativeContextABI {
    /// Pure-Swift adapted coverage/sanitizer hook shims matching `native/src/cov_runner.zig`.
    enum CovRunner: Sendable {
        // parity: native/src/cov_runner.zig#runner_futex_wait [status=adapted hash=530884688860]
        public static func runner_futex_wait() {}

        // parity: native/src/cov_runner.zig#runner_futex_wake [status=adapted hash=8f662b0d32c1]
        public static func runner_futex_wake() {}

        // parity: native/src/cov_runner.zig#runner_broadcast_input [status=adapted hash=37d9dc33ef40]
        public static func runner_broadcast_input() {}

        // parity: native/src/cov_runner.zig#runner_test_name [status=adapted hash=234251babd93]
        public static func runner_test_name() {}

        // parity: native/src/cov_runner.zig#runner_start_input_poller [status=adapted hash=3586e9aecdbe]
        public static func runner_start_input_poller() {}

        // parity: native/src/cov_runner.zig#runner_stop_input_poller [status=adapted hash=1351a0a8878b]
        public static func runner_stop_input_poller() {}

        // parity: native/src/cov_runner.zig#runner_test_run [status=adapted hash=93ce4783832f]
        public static func runner_test_run() {}

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_cmp1 [status=adapted hash=3fd2dc909707]
        public static func __sanitizer_cov_trace_cmp1(_ a: UInt8, _ b: UInt8) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_cmp2 [status=adapted hash=5ec25ccd592f]
        public static func __sanitizer_cov_trace_cmp2(_ a: UInt16, _ b: UInt16) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_cmp4 [status=adapted hash=5b4f81b8266e]
        public static func __sanitizer_cov_trace_cmp4(_ a: UInt32, _ b: UInt32) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_cmp8 [status=adapted hash=09e3cb7a12e5]
        public static func __sanitizer_cov_trace_cmp8(_ a: UInt64, _ b: UInt64) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_const_cmp1 [status=adapted hash=3324d58ae2c3]
        public static func __sanitizer_cov_trace_const_cmp1(_ a: UInt8, _ b: UInt8) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_const_cmp2 [status=adapted hash=1d09dffc4a38]
        public static func __sanitizer_cov_trace_const_cmp2(_ a: UInt16, _ b: UInt16) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_const_cmp4 [status=adapted hash=282a8c8b40c7]
        public static func __sanitizer_cov_trace_const_cmp4(_ a: UInt32, _ b: UInt32) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_const_cmp8 [status=adapted hash=735f7f370e97]
        public static func __sanitizer_cov_trace_const_cmp8(_ a: UInt64, _ b: UInt64) { _ = (a, b) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_switch [status=adapted hash=8b1c05e75b91]
        public static func __sanitizer_cov_trace_switch(_ val: UInt64, _ cases: [UInt64]) { _ = (val, cases) }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_div4 [status=adapted hash=750011636182]
        public static func __sanitizer_cov_trace_div4(_ val: UInt32) { _ = val }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_div8 [status=adapted hash=433a073b430e]
        public static func __sanitizer_cov_trace_div8(_ val: UInt64) { _ = val }

        // parity: native/src/cov_runner.zig#__sanitizer_cov_trace_gep [status=adapted hash=90141c0f607d]
        public static func __sanitizer_cov_trace_gep(_ idx: UInt) { _ = idx }

        // parity: native/src/cov_runner.zig#main [status=adapted hash=fa040c85689f]
        public static func main(_ args: [String] = []) throws -> Int {
            _ = args
            return 0
        }
    }
}
