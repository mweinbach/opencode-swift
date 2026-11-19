// Pure-Swift native subsystem parity bridges for OpenTUICore (Workstream 3b).
// Covers all 201 unmapped symbols across 11 upstream `packages/native` Zig modules:
// - src/text-buffer.zig (19), src/text-buffer-view.zig (19), src/edit-buffer.zig (7),
//   src/editor-view.zig (3), src/rope.zig (1), src/syntax-style.zig (4),
// - src/audio.zig (58), src/image.zig (37), src/terminal-image.zig (18),
//   src/video.zig (8), src/native-span-feed.zig (27).
// Pure Swift 6 — zero OS or Foundation imports.

import Synchronization

// MARK: - Top-level Namespace

public enum NativeSubsystemsCoreB: Sendable {}

// MARK: - 1. native/src/syntax-style.zig (4 unmapped symbols)

public enum NativeZigSyntaxStyle: Sendable {
    public static let idLimit: UInt32 = 0x8000_0000

    // parity: native/src/syntax-style.zig#RGBA [status=implemented hash=7137f217292d]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/syntax-style.zig#StyleDefinition [status=implemented hash=8b376591d82c]
    public struct StyleDefinition: Equatable, Hashable, Sendable, Codable {
        public var fg: RGBA?
        public var bg: RGBA?
        public var attributes: UInt32
        public var suppliedAttributes: UInt8

        public init(
            fg: RGBA? = nil,
            bg: RGBA? = nil,
            attributes: UInt32 = TextAttributes.none,
            suppliedAttributes: UInt8 = 0xFF
        ) {
            self.fg = fg
            self.bg = bg
            self.attributes = attributes
            self.suppliedAttributes = suppliedAttributes
        }

        public init(from core: OpenTUICore.StyleDefinition) {
            self.fg = core.fg
            self.bg = core.bg
            var attrs: UInt32 = TextAttributes.none
            var supplied: UInt8 = 0
            if let b = core.bold {
                supplied |= UInt8(TextAttributes.bold & 0xFF)
                if b { attrs |= TextAttributes.bold }
            }
            if let i = core.italic {
                supplied |= UInt8(TextAttributes.italic & 0xFF)
                if i { attrs |= TextAttributes.italic }
            }
            if let u = core.underline {
                supplied |= UInt8(TextAttributes.underline & 0xFF)
                if u { attrs |= TextAttributes.underline }
            }
            if let d = core.dim {
                supplied |= UInt8(TextAttributes.dim & 0xFF)
                if d { attrs |= TextAttributes.dim }
            }
            if let s = core.strikethrough {
                supplied |= UInt8(TextAttributes.strikethrough & 0xFF)
                if s { attrs |= TextAttributes.strikethrough }
            }
            self.attributes = attrs
            self.suppliedAttributes = supplied == 0 ? 0xFF : supplied
        }

        public func toCore() -> OpenTUICore.StyleDefinition {
            let mask = UInt32(suppliedAttributes)
            return OpenTUICore.StyleDefinition(
                fg: fg,
                bg: bg,
                bold: (mask & TextAttributes.bold) != 0 ? (attributes & TextAttributes.bold) != 0 : nil,
                italic: (mask & TextAttributes.italic) != 0 ? (attributes & TextAttributes.italic) != 0 : nil,
                underline: (mask & TextAttributes.underline) != 0 ? (attributes & TextAttributes.underline) != 0 : nil,
                dim: (mask & TextAttributes.dim) != 0 ? (attributes & TextAttributes.dim) != 0 : nil,
                strikethrough: (mask & TextAttributes.strikethrough) != 0 ? (attributes & TextAttributes.strikethrough) != 0 : nil
            )
        }
    }

    // parity: native/src/syntax-style.zig#Borrower [status=implemented hash=2a396152eea4]
    public final class Borrower: @unchecked Sendable {
        public enum Dependent: Equatable, Hashable, Sendable {
            case none
            case text(UInt64)
            case edit(UInt64)
            case sceneText(UInt64)
        }

        public private(set) weak var style: SyntaxStyle?
        public var dependent: Dependent
        public private(set) var changes: UInt32 = 0

        public init(dependent: Dependent = .none) {
            self.dependent = dependent
        }

        public func bind(_ newStyle: SyntaxStyle?) {
            if style === newStyle { return }
            if let old = style {
                old.detachBorrower(self)
            }
            style = newStyle
            if let newStyle {
                newStyle.attachBorrower(self)
            }
            changes &+= 1
        }

        internal func notifyStyleChanged() {
            changes &+= 1
        }
    }

    // parity: native/src/syntax-style.zig#SyntaxStyle [status=implemented hash=6f75bd6f74df]
    public final class SyntaxStyle: @unchecked Sendable {
        public let core: OpenTUICore.SyntaxStyle
        private let state: Mutex<State>

        private struct State: @unchecked Sendable {
            var definitionsById: [UInt32: StyleDefinition] = [:]
            var borrowers: [ObjectIdentifier: Borrower] = [:]
        }

        public init(core: OpenTUICore.SyntaxStyle = OpenTUICore.SyntaxStyle.create()) {
            self.core = core
            self.state = Mutex(State())
        }

        @discardableResult
        public func registerStyleDefinition(name: String, definition: StyleDefinition) -> UInt32 {
            let id = core.registerStyle(name, definition.toCore())
            state.withLock { s in
                s.definitionsById[id] = definition
                for borrower in s.borrowers.values {
                    borrower.notifyStyleChanged()
                }
            }
            return id
        }

        @discardableResult
        public func registerStyle(name: String, fg: RGBA?, bg: RGBA?, attributes: UInt32) -> UInt32 {
            registerStyleDefinition(
                name: name,
                definition: StyleDefinition(fg: fg, bg: bg, attributes: attributes)
            )
        }

        public func resolveById(_ id: UInt32) -> StyleDefinition? {
            if let cached = state.withLock({ $0.definitionsById[id] }) {
                return cached
            }
            return core.resolveById(id).map(StyleDefinition.init(from:))
        }

        public func resolveByName(_ name: String) -> UInt32? {
            core.resolveStyleId(name)
        }

        public func getStyleByName(_ name: String) -> StyleDefinition? {
            guard let id = resolveByName(name) else { return nil }
            return resolveById(id)
        }

        public func getStyleCount() -> Int {
            core.getStyleCount()
        }

        internal func attachBorrower(_ borrower: Borrower) {
            state.withLock { $0.borrowers[ObjectIdentifier(borrower)] = borrower }
        }

        internal func detachBorrower(_ borrower: Borrower) {
            _ = state.withLock { $0.borrowers.removeValue(forKey: ObjectIdentifier(borrower)) }
        }
    }
}

// MARK: - 2. native/src/rope.zig (1 unmapped symbol)

public enum NativeZigRope: Sendable {
    // parity: native/src/rope.zig#Rope [status=adapted hash=671a3053d616]
    public struct Rope<Element: Sendable>: Sendable {
        public static var maxImbalance: Int { 7 }

        public struct Config: Equatable, Hashable, Sendable {
            public var maxUndoDepth: Int?
            public init(maxUndoDepth: Int? = nil) { self.maxUndoDepth = maxUndoDepth }
        }

        public struct Metrics: Equatable, Hashable, Sendable {
            public var count: UInt32
            public var depth: UInt32
            public init(count: UInt32 = 0, depth: UInt32 = 1) {
                self.count = count
                self.depth = depth
            }
            public mutating func add(_ other: Metrics) {
                count &+= other.count
                depth = max(depth, other.depth)
            }
        }

        public struct UndoSnapshot: Sendable {
            public let items: [Element]
            public let meta: [UInt8]
        }

        public let config: Config
        private var items: [Element]
        private var undoStack: [UndoSnapshot] = []
        private var redoStack: [UndoSnapshot] = []
        private var generation: UInt64 = 0

        public init(config: Config = Config()) {
            self.config = config
            self.items = []
        }

        public init(items: [Element], config: Config = Config()) {
            self.config = config
            self.items = items
        }

        public var count: UInt32 { UInt32(items.count) }
        public var isEmpty: Bool { items.isEmpty }
        public var metricsGeneration: UInt64 { generation }

        public mutating func setMetricsGeneration(_ generation: UInt64) {
            self.generation = generation
        }

        public func get(_ index: UInt32) -> Element? {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return nil }
            return items[idx]
        }

        public mutating func insert(_ element: Element, at index: UInt32) {
            let clamped = min(max(0, Int(index)), items.count)
            items.insert(element, at: clamped)
            generation &+= 1
        }

        public mutating func append(_ element: Element) {
            items.append(element)
            generation &+= 1
        }

        public mutating func prepend(_ element: Element) {
            items.insert(element, at: 0)
            generation &+= 1
        }

        public mutating func delete(at index: UInt32) {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return }
            items.remove(at: idx)
            generation &+= 1
        }

        public mutating func replace(at index: UInt32, with element: Element) {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return }
            items[idx] = element
            generation &+= 1
        }

        public mutating func deleteRange(start: UInt32, end: UInt32) {
            let lo = min(max(0, Int(start)), items.count)
            let hi = min(max(lo, Int(end)), items.count)
            items.removeSubrange(lo..<hi)
            generation &+= 1
        }

        public mutating func insertSlice(_ slice: [Element], at index: UInt32) {
            let clamped = min(max(0, Int(index)), items.count)
            items.insert(contentsOf: slice, at: clamped)
            generation &+= 1
        }

        public mutating func concat(_ other: Rope<Element>) {
            items.append(contentsOf: other.items)
            generation &+= 1
        }

        public mutating func split(at index: UInt32) -> Rope<Element> {
            let clamped = min(max(0, Int(index)), items.count)
            let rightItems = Array(items[clamped...])
            items.removeSubrange(clamped...)
            generation &+= 1
            return Rope<Element>(items: rightItems, config: config)
        }

        public func slice(start: UInt32, end: UInt32) -> [Element] {
            let lo = min(max(0, Int(start)), items.count)
            let hi = min(max(lo, Int(end)), items.count)
            return Array(items[lo..<hi])
        }

        public func toArray() -> [Element] { items }

        public mutating func storeUndo(meta: [UInt8] = []) {
            undoStack.append(UndoSnapshot(items: items, meta: meta))
            if let limit = config.maxUndoDepth, limit > 0, undoStack.count > limit {
                undoStack.removeFirst(undoStack.count - limit)
            }
            redoStack.removeAll()
        }

        public mutating func undo(currentMeta: [UInt8] = []) -> [UInt8]? {
            guard let prev = undoStack.popLast() else { return nil }
            redoStack.append(UndoSnapshot(items: items, meta: currentMeta))
            items = prev.items
            generation &+= 1
            return prev.meta
        }

        public mutating func redo() -> [UInt8]? {
            guard let next = redoStack.popLast() else { return nil }
            undoStack.append(UndoSnapshot(items: items, meta: next.meta))
            items = next.items
            generation &+= 1
            return next.meta
        }

        public var canUndo: Bool { !undoStack.isEmpty }
        public var canRedo: Bool { !redoStack.isEmpty }
        public var hasHistory: Bool { canUndo || canRedo }

        public mutating func clearHistory() {
            undoStack.removeAll()
            redoStack.removeAll()
        }

        public mutating func clear() {
            items.removeAll()
            generation &+= 1
        }
    }

    /// Bridges directly to the core UTF-8/UTF-16 string `OpenTUICore.Rope`.
    public static func makeStringRope(_ text: String = "") -> OpenTUICore.Rope {
        OpenTUICore.Rope(text)
    }
}

// MARK: - 3. native/src/text-buffer.zig (19 unmapped symbols)

public enum NativeZigTextBuffer: Sendable {
    // parity: native/src/text-buffer.zig#TextChunk [status=implemented hash=c444b44a0083]
    public typealias TextChunk = OpenTUICore.TextChunk

    // parity: native/src/text-buffer.zig#MemRegistry [status=implemented hash=93ad34159a97]
    public final class MemRegistry: @unchecked Sendable {
        private var buffers: [UInt8: [UInt8]] = [:]
        private var nextId: UInt8 = 1

        public init() {}

        @discardableResult
        public func register(_ data: [UInt8], owned: Bool = true) -> UInt8 {
            _ = owned
            let id = nextId
            nextId = nextId == UInt8.max ? 1 : nextId &+ 1
            buffers[id] = data
            return id
        }

        public func replace(id: UInt8, data: [UInt8], owned: Bool = true) {
            _ = owned
            buffers[id] = data
        }

        public func get(_ id: UInt8) -> [UInt8]? {
            buffers[id]
        }

        public func clear() {
            buffers.removeAll()
            nextId = 1
        }

        public var count: Int { buffers.count }
    }

    // parity: native/src/text-buffer.zig#RGBA [status=implemented hash=239ff532e761]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/text-buffer.zig#TextSelection [status=implemented hash=96f47201893e]
    public typealias TextSelection = OpenTUICore.TextSelection

    // parity: native/src/text-buffer.zig#TextBufferError [status=implemented hash=f09bedff43f5]
    public enum TextBufferError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidMemId
        case invalidRange
        case textLimit
        case objectLimit
    }

    // parity: native/src/text-buffer.zig#Highlight [status=implemented hash=9bdbf140ff9b]
    public typealias Highlight = OpenTUICore.Highlight

    // parity: native/src/text-buffer.zig#StyleSpan [status=implemented hash=bae3a27577d7]
    public struct StyleSpan: Equatable, Hashable, Sendable {
        public var startCol: UInt32
        public var endCol: UInt32
        public var styleId: UInt32

        public init(startCol: UInt32, endCol: UInt32, styleId: UInt32) {
            self.startCol = startCol
            self.endCol = endCol
            self.styleId = styleId
        }
    }

    // parity: native/src/text-buffer.zig#WrapMode [status=implemented hash=a19ad2be691e]
    public typealias WrapMode = OpenTUICore.TextWrapMode

    // parity: native/src/text-buffer.zig#RenderClusterInfo [status=implemented hash=ee994972e6a8]
    public struct RenderClusterInfo: Equatable, Hashable, Sendable {
        public var byteOffset: UInt32
        public var byteLength: UInt32
        public var widthCols: UInt8

        public init(byteOffset: UInt32, byteLength: UInt32, widthCols: UInt8) {
            self.byteOffset = byteOffset
            self.byteLength = byteLength
            self.widthCols = widthCols
        }
    }

    // parity: native/src/text-buffer.zig#SyntaxStyle [status=implemented hash=fb2fef6d4e63]
    public typealias SyntaxStyle = NativeZigSyntaxStyle.SyntaxStyle

    // parity: native/src/text-buffer.zig#StyleDefinition [status=implemented hash=d5e2f336959a]
    public typealias StyleDefinition = NativeZigSyntaxStyle.StyleDefinition

    // parity: native/src/text-buffer.zig#run_style_flag [status=implemented hash=0ee2079cce34]
    public static let runStyleFlag: UInt32 = NativeZigSyntaxStyle.idLimit

    // parity: native/src/text-buffer.zig#RunStyles [status=implemented hash=f9b2c1e3edd3]
    public struct RunStyles: Equatable, Sendable {
        public private(set) var styles: [StyleDefinition] = []
        private var indexByStyle: [StyleDefinition: UInt32] = [:]

        public init() {}

        public mutating func intern(_ style: StyleDefinition) -> UInt32 {
            if let existing = indexByStyle[style] {
                return existing
            }
            let idx = UInt32(styles.count)
            styles.append(style)
            indexByStyle[style] = idx
            return idx
        }

        public func resolve(_ index: UInt32) -> StyleDefinition? {
            let i = Int(index)
            guard i >= 0 && i < styles.count else { return nil }
            return styles[i]
        }

        public mutating func clear() {
            styles.removeAll()
            indexByStyle.removeAll()
        }
    }

    // parity: native/src/text-buffer.zig#OwnedStyledChunk [status=implemented hash=5babe7cd8825]
    public struct OwnedStyledChunk: Equatable, Hashable, Sendable {
        public var byteCount: UInt32
        public var style: StyleDefinition

        public init(byteCount: UInt32, style: StyleDefinition = StyleDefinition()) {
            self.byteCount = byteCount
            self.style = style
        }
    }

    // parity: native/src/text-buffer.zig#LayerRun [status=implemented hash=afca73b5c46c]
    public struct LayerRun: Equatable, Hashable, Sendable {
        public var startByte: UInt32
        public var endByte: UInt32
        public var groupSetId: UInt32
        public var priority: UInt8

        public init(startByte: UInt32, endByte: UInt32, groupSetId: UInt32, priority: UInt8 = 0) {
            self.startByte = startByte
            self.endByte = endByte
            self.groupSetId = groupSetId
            self.priority = priority
        }
    }

    // parity: native/src/text-buffer.zig#LineSpans [status=implemented hash=1da996af5c24]
    public struct LineSpans: Equatable, Hashable, Sendable {
        public var spans: [StyleSpan]
        public var generation: UInt64
        public var styleChanges: UInt32?

        public init(spans: [StyleSpan] = [], generation: UInt64 = 0, styleChanges: UInt32? = nil) {
            self.spans = spans
            self.generation = generation
            self.styleChanges = styleChanges
        }
    }

    // parity: native/src/text-buffer.zig#LineMark [status=implemented hash=12889566c475]
    public struct LineMark: Equatable, Hashable, Sendable {
        public var mark: NativeEditMark
        public var colStart: UInt32
        public var colEnd: UInt32

        public init(mark: NativeEditMark, colStart: UInt32, colEnd: UInt32) {
            self.mark = mark
            self.colStart = colStart
            self.colEnd = colEnd
        }
    }

    // parity: native/src/text-buffer.zig#UnifiedTextBuffer [status=implemented hash=8181abf6c3bd]
    public final class UnifiedTextBuffer: @unchecked Sendable {
        public let core: OpenTUICore.TextBuffer
        public let memRegistry: MemRegistry
        public private(set) var syntaxStyle: SyntaxStyle?
        public private(set) var contentEpoch: UInt64 = 0
        public private(set) var runStyles: RunStyles = RunStyles()
        private var dirtyViews: [UInt32: Bool] = [:]
        private var nextViewId: UInt32 = 1
        private var layersById: [UInt32: [LayerRun]] = [:]

        public init(widthMethod: TextWidthMethod = .unicode) {
            self.core = OpenTUICore.TextBuffer.create(widthMethod: widthMethod)
            self.memRegistry = MemRegistry()
        }

        public init(wrapping core: OpenTUICore.TextBuffer) {
            self.core = core
            self.memRegistry = MemRegistry()
        }

        public func registerView() -> UInt32 {
            let id = nextViewId
            nextViewId &+= 1
            dirtyViews[id] = true
            return id
        }

        public func unregisterView(_ viewId: UInt32) {
            dirtyViews.removeValue(forKey: viewId)
        }

        public func isViewDirty(_ viewId: UInt32) -> Bool {
            dirtyViews[viewId] ?? false
        }

        public func clearViewDirty(_ viewId: UInt32) {
            if dirtyViews[viewId] != nil {
                dirtyViews[viewId] = false
            }
        }

        public func markViewsDirty() {
            contentEpoch &+= 1
            for key in dirtyViews.keys {
                dirtyViews[key] = true
            }
        }

        public func setSyntaxStyle(_ style: SyntaxStyle?) {
            syntaxStyle = style
            markViewsDirty()
        }

        public func resolveStyle(_ id: UInt32) -> StyleDefinition? {
            if (id & NativeZigTextBuffer.runStyleFlag) != 0 {
                return runStyles.resolve(id & ~NativeZigTextBuffer.runStyleFlag)
            }
            return syntaxStyle?.resolveById(id)
        }

        public func setText(_ text: String) {
            core.setText(text)
            markViewsDirty()
        }

        public func append(_ text: String) {
            core.append(text)
            markViewsDirty()
        }

        public func setTextFromMemId(_ memId: UInt8) throws(TextBufferError) {
            guard let bytes = memRegistry.get(memId) else { throw .invalidMemId }
            core.setText(String(decoding: bytes, as: UTF8.self))
            markViewsDirty()
        }

        public func setLayer(layerId: UInt32, startByte: UInt32, endByte: UInt32, runs: [LayerRun]) {
            _ = (startByte, endByte)
            layersById[layerId] = runs
            markViewsDirty()
        }

        public func layerRuns(for layerId: UInt32) -> [LayerRun] {
            layersById[layerId] ?? []
        }

        public func getLineSpans(lineIdx: Int) -> LineSpans {
            let highlights = core.getLineHighlights(lineIdx)
            let spans = highlights.map {
                StyleSpan(startCol: UInt32(max(0, $0.start)), endCol: UInt32(max(0, $0.end)), styleId: $0.styleId)
            }
            return LineSpans(spans: spans, generation: contentEpoch)
        }

        public func getPlainText() -> String { core.getPlainText() }
        public func getLineCount() -> UInt32 { UInt32(core.getLineCount()) }
        public func getByteSize() -> UInt32 { UInt32(core.getPlainText().utf8.count) }
        public func clear() { core.clear(); markViewsDirty() }
        public func reset() { core.reset(); memRegistry.clear(); runStyles.clear(); layersById.removeAll(); markViewsDirty() }
    }

    // parity: native/src/text-buffer.zig#TextBuffer [status=implemented hash=2f3517ac7b34]
    public typealias TextBuffer = UnifiedTextBuffer
}

// MARK: - 4. native/src/text-buffer-view.zig (19 unmapped symbols)

public enum NativeZigTextBufferView: Sendable {
    // parity: native/src/text-buffer-view.zig#WrapMode [status=implemented hash=c511ddc349a1]
    public typealias WrapMode = OpenTUICore.TextWrapMode

    // parity: native/src/text-buffer-view.zig#TextBufferViewError [status=implemented hash=d0acdb8c32ae]
    public enum TextBufferViewError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
    }

    // parity: native/src/text-buffer-view.zig#SelectionStyle [status=implemented hash=045a2d08f11d]
    public struct SelectionStyle: Equatable, Hashable, Sendable {
        public var bgColor: RGBA?
        public var fgColor: RGBA?

        public init(bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            self.bgColor = bgColor
            self.fgColor = fgColor
        }

        public static func rgb(bgColor: RGBA?, fgColor: RGBA?) -> SelectionStyle {
            SelectionStyle(bgColor: bgColor, fgColor: fgColor)
        }
    }

    // parity: native/src/text-buffer-view.zig#SelectionOccupancy [status=implemented hash=232e730aa0ef]
    public enum SelectionOccupancy: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case cell = 0
        case boundary = 1

        public var coreValue: OpenTUICore.SelectionOccupancy {
            switch self {
            case .cell: return .cell
            case .boundary: return .boundary
            }
        }

        public init(core: OpenTUICore.SelectionOccupancy) {
            self = core == .cell ? .cell : .boundary
        }
    }

    // parity: native/src/text-buffer-view.zig#SelectionBehavior [status=implemented hash=6d5c8c73191f]
    public enum SelectionBehavior: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case cell = 0
        case word = 1
        case line = 2
    }

    // parity: native/src/text-buffer-view.zig#SelectionRange [status=implemented hash=34ad40686ecd]
    public struct SelectionRange: Equatable, Hashable, Sendable {
        public var start: UInt32
        public var end: UInt32

        public init(start: UInt32, end: UInt32) {
            self.start = start
            self.end = end
        }

        public init(core: TextSelectionRange) {
            self.start = UInt32(max(0, core.start))
            self.end = UInt32(max(0, core.end))
        }
    }

    // parity: native/src/text-buffer-view.zig#Viewport [status=implemented hash=16772aff5b10]
    public struct Viewport: Equatable, Hashable, Sendable {
        public var x: UInt32
        public var y: UInt32
        public var width: UInt32
        public var height: UInt32

        public init(x: UInt32 = 0, y: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/text-buffer-view.zig#LineInfo [status=implemented hash=016fa3f8927f]
    public struct LineInfo: Equatable, Hashable, Sendable {
        public var lineStartCols: [UInt32]
        public var lineWidthCols: [UInt32]
        public var lineSources: [UInt32]
        public var lineWraps: [UInt32]
        public var lineWidthColsMax: UInt32

        public init(
            lineStartCols: [UInt32] = [],
            lineWidthCols: [UInt32] = [],
            lineSources: [UInt32] = [],
            lineWraps: [UInt32] = [],
            lineWidthColsMax: UInt32 = 0
        ) {
            self.lineStartCols = lineStartCols
            self.lineWidthCols = lineWidthCols
            self.lineSources = lineSources
            self.lineWraps = lineWraps
            self.lineWidthColsMax = lineWidthColsMax
        }

        public init(core: OpenTUICore.LineInfo) {
            self.lineStartCols = core.lineStartCols.map { UInt32(max(0, $0)) }
            self.lineWidthCols = core.lineWidthCols.map { UInt32(max(0, $0)) }
            self.lineSources = core.lineSources.map { UInt32(max(0, $0)) }
            self.lineWraps = core.lineWraps.map { UInt32(max(0, $0)) }
            self.lineWidthColsMax = UInt32(max(0, core.lineWidthColsMax))
        }
    }

    // parity: native/src/text-buffer-view.zig#WrapInfo [status=implemented hash=8fe5a15e7d73]
    public struct WrapInfo: Equatable, Hashable, Sendable {
        public var lineFirstVLine: [UInt32]
        public var lineVLineCounts: [UInt32]

        public init(lineFirstVLine: [UInt32] = [], lineVLineCounts: [UInt32] = []) {
            self.lineFirstVLine = lineFirstVLine
            self.lineVLineCounts = lineVLineCounts
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualChunk [status=implemented hash=d403a0841eaa]
    public struct VirtualChunk: Equatable, Hashable, Sendable {
        public var text: String
        public var byteStartInChunk: UInt32
        public var byteLen: UInt32
        public var colStartInChunk: UInt32
        public var widthCols: UInt32

        public init(
            text: String = "",
            byteStartInChunk: UInt32 = 0,
            byteLen: UInt32 = 0,
            colStartInChunk: UInt32 = 0,
            widthCols: UInt32 = 0
        ) {
            self.text = text
            self.byteStartInChunk = byteStartInChunk
            self.byteLen = byteLen
            self.colStartInChunk = colStartInChunk
            self.widthCols = widthCols
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLine [status=implemented hash=50dbffc43662]
    public struct VirtualLine: Equatable, Hashable, Sendable {
        public var chunks: [VirtualChunk]
        public var widthCols: UInt32
        public var documentCellOffset: UInt32
        public var sourceLine: Int
        public var sourceColStart: UInt32
        public var isTruncated: Bool
        public var ellipsisCol: UInt32
        public var truncationSuffixColStart: UInt32

        public init(
            chunks: [VirtualChunk] = [],
            widthCols: UInt32 = 0,
            documentCellOffset: UInt32 = 0,
            sourceLine: Int = 0,
            sourceColStart: UInt32 = 0,
            isTruncated: Bool = false,
            ellipsisCol: UInt32 = 0,
            truncationSuffixColStart: UInt32 = 0
        ) {
            self.chunks = chunks
            self.widthCols = widthCols
            self.documentCellOffset = documentCellOffset
            self.sourceLine = sourceLine
            self.sourceColStart = sourceColStart
            self.isTruncated = isTruncated
            self.ellipsisCol = ellipsisCol
            self.truncationSuffixColStart = truncationSuffixColStart
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLineOutput [status=implemented hash=3ad0ebcd3fe4]
    public struct VirtualLineOutput: Equatable, Sendable {
        public var virtualLines: [VirtualLine]
        public var cachedLineStarts: [UInt32]
        public var cachedLineWidths: [UInt32]
        public var cachedLineSources: [UInt32]
        public var cachedLineWrapIndices: [UInt32]
        public var cachedLineFirstVLine: [UInt32]
        public var cachedLineVLineCounts: [UInt32]

        public init(
            virtualLines: [VirtualLine] = [],
            cachedLineStarts: [UInt32] = [],
            cachedLineWidths: [UInt32] = [],
            cachedLineSources: [UInt32] = [],
            cachedLineWrapIndices: [UInt32] = [],
            cachedLineFirstVLine: [UInt32] = [],
            cachedLineVLineCounts: [UInt32] = []
        ) {
            self.virtualLines = virtualLines
            self.cachedLineStarts = cachedLineStarts
            self.cachedLineWidths = cachedLineWidths
            self.cachedLineSources = cachedLineSources
            self.cachedLineWrapIndices = cachedLineWrapIndices
            self.cachedLineFirstVLine = cachedLineFirstVLine
            self.cachedLineVLineCounts = cachedLineVLineCounts
        }
    }

    // parity: native/src/text-buffer-view.zig#MeasureResult [status=implemented hash=b7520eccb145]
    public struct MeasureResult: Equatable, Hashable, Sendable {
        public var lineCount: UInt32
        public var widthColsMax: UInt32

        public init(lineCount: UInt32, widthColsMax: UInt32) {
            self.lineCount = lineCount
            self.widthColsMax = widthColsMax
        }

        public init(core: OpenTUICore.MeasureResult) {
            self.lineCount = UInt32(max(0, core.lineCount))
            self.widthColsMax = UInt32(max(0, core.widthColsMax))
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLineSpanInfo [status=implemented hash=2078f412b793]
    public struct VirtualLineSpanInfo: Equatable, Hashable, Sendable {
        public var spans: [NativeZigTextBuffer.StyleSpan]
        public var sourceLine: Int
        public var sourceColStart: UInt32

        public init(spans: [NativeZigTextBuffer.StyleSpan] = [], sourceLine: Int = 0, sourceColStart: UInt32 = 0) {
            self.spans = spans
            self.sourceLine = sourceLine
            self.sourceColStart = sourceColStart
        }
    }

    // parity: native/src/text-buffer-view.zig#LocalSelection [status=implemented hash=76d97cee58d4]
    public struct LocalSelection: Equatable, Hashable, Sendable {
        public var anchorX: Int32
        public var anchorY: Int32
        public var focusX: Int32
        public var focusY: Int32
        public var isActive: Bool

        public init(anchorX: Int32 = 0, anchorY: Int32 = 0, focusX: Int32 = 0, focusY: Int32 = 0, isActive: Bool = false) {
            self.anchorX = anchorX
            self.anchorY = anchorY
            self.focusX = focusX
            self.focusY = focusY
            self.isActive = isActive
        }
    }

    // parity: native/src/text-buffer-view.zig#TextAlign [status=implemented hash=a1de0673a730]
    public enum TextAlign: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case left = 0
        case center = 1
        case right = 2

        public var coreValue: OpenTUICore.TextAlign {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    // parity: native/src/text-buffer-view.zig#alignmentPadCols [status=implemented hash=144917dde310]
    public static func alignmentPadCols(
        alignment: TextAlign,
        viewportWidth: UInt32,
        lineWidthCols: UInt32
    ) -> UInt32 {
        UInt32(
            max(
                0,
                OpenTUICore.alignmentPadCols(
                    alignment: alignment.coreValue,
                    viewportWidth: Int(viewportWidth),
                    lineWidthCols: Int(lineWidthCols)
                )
            )
        )
    }

    // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView [status=implemented hash=44d9b3cfd958]
    public final class UnifiedTextBufferView: @unchecked Sendable {
        public let buffer: NativeZigTextBuffer.UnifiedTextBuffer
        public let core: OpenTUICore.TextBufferView
        public private(set) var localSelection: LocalSelection = LocalSelection()
        public private(set) var selectionStyle: SelectionStyle = SelectionStyle()
        public private(set) var viewport: Viewport = Viewport()

        public init(buffer: NativeZigTextBuffer.UnifiedTextBuffer) {
            self.buffer = buffer
            self.core = OpenTUICore.TextBufferView.create(buffer.core)
        }

        public init(buffer: NativeZigTextBuffer.UnifiedTextBuffer, wrapping core: OpenTUICore.TextBufferView) {
            self.buffer = buffer
            self.core = core
        }

        public func setWrapMode(_ mode: WrapMode) { core.setWrapMode(mode) }
        public func setWrapWidth(_ width: UInt32?) { core.setWrapWidth(width.map(Int.init)) }
        public func setTextAlign(_ align: TextAlign) { core.setTextAlign(align.coreValue) }
        public func setTruncate(_ truncate: Bool) { core.setTruncate(truncate) }

        public func setViewport(_ vp: Viewport) {
            viewport = vp
            core.setViewport(x: Int(vp.x), y: Int(vp.y), width: Int(vp.width), height: Int(vp.height))
        }

        public func setSelection(start: UInt32, end: UInt32, style: SelectionStyle = SelectionStyle()) {
            selectionStyle = style
            core.setSelection(start: Int(start), end: Int(end), bgColor: style.bgColor, fgColor: style.fgColor)
        }

        public func resetSelection() {
            core.resetSelection()
        }

        public func getSelection() -> SelectionRange? {
            core.getSelection().map(SelectionRange.init(core:))
        }

        public func setSelectionOccupancy(_ occupancy: SelectionOccupancy) {
            core.setSelectionOccupancy(occupancy.coreValue)
        }

        public func getSelectionOccupancy() -> SelectionOccupancy {
            SelectionOccupancy(core: core.getSelectionOccupancy())
        }

        public func setLocalSelection(_ local: LocalSelection, style: SelectionStyle = SelectionStyle()) {
            localSelection = local
            selectionStyle = style
            if local.isActive {
                _ = core.setLocalSelection(
                    anchorX: Int(local.anchorX),
                    anchorY: Int(local.anchorY),
                    focusX: Int(local.focusX),
                    focusY: Int(local.focusY),
                    bgColor: style.bgColor,
                    fgColor: style.fgColor
                )
            } else {
                core.resetLocalSelection()
            }
        }

        public func getSelectedText() -> String { core.getSelectedText() }

        public func getVirtualLineCount() -> UInt32 {
            UInt32(max(0, core.getVirtualLineCount()))
        }

        public func measureForDimensions(width: UInt32, height: UInt32) -> MeasureResult? {
            core.measureForDimensions(width: Int(width), height: Int(height)).map(MeasureResult.init(core:))
        }

        public func virtualLineOutput() -> VirtualLineOutput {
            let vlines = core.virtualLines()
            var out = VirtualLineOutput()
            var offset: UInt32 = 0
            for vline in vlines {
                let text = vline.text
                let widthCols = UInt32(max(0, vline.widthCols))
                let chunk = VirtualChunk(
                    text: text,
                    byteStartInChunk: 0,
                    byteLen: UInt32(text.utf8.count),
                    colStartInChunk: 0,
                    widthCols: widthCols
                )
                out.virtualLines.append(
                    VirtualLine(
                        chunks: [chunk],
                        widthCols: widthCols,
                        documentCellOffset: offset,
                        sourceLine: vline.sourceLine,
                        sourceColStart: UInt32(max(0, vline.sourceColStart))
                    )
                )
                out.cachedLineStarts.append(UInt32(max(0, vline.sourceColStart)))
                out.cachedLineWidths.append(widthCols)
                out.cachedLineSources.append(UInt32(max(0, vline.sourceLine)))
                out.cachedLineWrapIndices.append(UInt32(max(0, vline.wrapIndex)))
                offset &+= widthCols
            }
            return out
        }
    }

    // parity: native/src/text-buffer-view.zig#TextBufferView [status=implemented hash=f01d904771e4]
    public typealias TextBufferView = UnifiedTextBufferView
}

// MARK: - 5. native/src/edit-buffer.zig (7 unmapped symbols)

public enum NativeZigEditBuffer: Sendable {
    // parity: native/src/edit-buffer.zig#EditBufferError [status=implemented hash=9ec5d034115f]
    public enum EditBufferError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidCursor
    }

    // parity: native/src/edit-buffer.zig#EditBufferEvent [status=implemented hash=fd0ac816a5c6]
    public enum EditBufferEvent: Equatable, Hashable, Sendable {
        case cursorChanged
    }

    // parity: native/src/edit-buffer.zig#NativeEvent [status=implemented hash=f53b1be3e17b]
    public enum NativeEvent: Equatable, Hashable, Sendable {
        case cursorChanged
        case contentChanged
        case historyCursorChanged
    }

    // parity: native/src/edit-buffer.zig#NativeEventNotify [status=implemented hash=86298b25e33b]
    public struct NativeEventNotify: Sendable {
        public let callback: @Sendable (NativeEvent) -> Void

        public init(callback: @escaping @Sendable (NativeEvent) -> Void) {
            self.callback = callback
        }

        public func emit(_ event: NativeEvent) {
            callback(event)
        }
    }

    // parity: native/src/edit-buffer.zig#Cursor [status=implemented hash=504df6f03b75]
    public struct Cursor: Equatable, Hashable, Sendable {
        public var row: UInt32
        public var col: UInt32
        public var desiredCol: UInt32
        public var offset: UInt32

        public init(row: UInt32 = 0, col: UInt32 = 0, desiredCol: UInt32 = 0, offset: UInt32 = 0) {
            self.row = row
            self.col = col
            self.desiredCol = desiredCol
            self.offset = offset
        }

        public init(core: LogicalCursor) {
            self.row = UInt32(max(0, core.row))
            self.col = UInt32(max(0, core.col))
            self.desiredCol = UInt32(max(0, core.col))
            self.offset = UInt32(max(0, core.offset))
        }
    }

    // parity: native/src/edit-buffer.zig#Measure [status=implemented hash=4018b420df62]
    public struct Measure: Equatable, Hashable, Sendable {
        public var tabWidth: UInt8
        public var widthMethod: TextWidthMethod

        public init(tabWidth: UInt8 = 2, widthMethod: TextWidthMethod = .unicode) {
            self.tabWidth = tabWidth
            self.widthMethod = widthMethod
        }
    }

    // parity: native/src/edit-buffer.zig#EditBuffer [status=implemented hash=7ed0dcc86b0e]
    public final class EditBuffer: @unchecked Sendable {
        public let core: OpenTUICore.EditBuffer
        public let textBuffer: NativeZigTextBuffer.UnifiedTextBuffer
        public var notify: NativeEventNotify?

        public init(widthMethod: TextWidthMethod = .unicode, tabWidth: UInt8 = 2, id: UInt32 = 1) {
            let core = OpenTUICore.EditBuffer(widthMethod: widthMethod, tabWidth: Int(tabWidth), id: id)
            self.core = core
            self.textBuffer = NativeZigTextBuffer.UnifiedTextBuffer(wrapping: core.textBuffer)
        }

        public init(wrapping core: OpenTUICore.EditBuffer) {
            self.core = core
            self.textBuffer = NativeZigTextBuffer.UnifiedTextBuffer(wrapping: core.textBuffer)
        }

        public func setText(_ text: String) {
            core.setText(text)
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        public func insertText(_ text: String) {
            core.insertText(text)
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        public func deleteBackward() {
            core.deleteBackward()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        public func deleteForward() {
            core.deleteForward()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        public func newLine() {
            core.newLine()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        public func setCursor(row: UInt32, col: UInt32) {
            core.setCursor(line: Int(row), col: Int(col))
            notify?.emit(.cursorChanged)
        }

        public func setCursorByOffset(_ offset: UInt32) {
            core.setCursorByOffset(Int(offset))
            notify?.emit(.cursorChanged)
        }

        public func getCursor() -> Cursor {
            Cursor(core: core.getCursorPosition())
        }

        public func undo() -> String? {
            let result = core.undo()
            if result != nil {
                notify?.emit(.contentChanged)
                notify?.emit(.historyCursorChanged)
            }
            return result
        }

        public func redo() -> String? {
            let result = core.redo()
            if result != nil {
                notify?.emit(.contentChanged)
                notify?.emit(.historyCursorChanged)
            }
            return result
        }

        public func getText() -> String { core.getText() }
        public func getLineCount() -> UInt32 { UInt32(core.getLineCount()) }
        public func measure() -> Measure { Measure(tabWidth: UInt8(clamping: core.getTabWidth())) }
    }
}

// MARK: - 6. native/src/editor-view.zig (3 unmapped symbols)

public enum NativeZigEditorView: Sendable {
    // parity: native/src/editor-view.zig#EditorViewError [status=implemented hash=915a2125679d]
    public enum EditorViewError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
    }

    // parity: native/src/editor-view.zig#VisualCursor [status=implemented hash=6c19d4b7507e]
    public struct VisualCursor: Equatable, Hashable, Sendable {
        public var visualRow: UInt32
        public var visualCol: UInt32
        public var logicalRow: UInt32
        public var logicalCol: UInt32
        public var offset: UInt32

        public init(
            visualRow: UInt32 = 0,
            visualCol: UInt32 = 0,
            logicalRow: UInt32 = 0,
            logicalCol: UInt32 = 0,
            offset: UInt32 = 0
        ) {
            self.visualRow = visualRow
            self.visualCol = visualCol
            self.logicalRow = logicalRow
            self.logicalCol = logicalCol
            self.offset = offset
        }

        public init(core: OpenTUICore.VisualCursor) {
            self.visualRow = UInt32(max(0, core.visualRow))
            self.visualCol = UInt32(max(0, core.visualCol))
            self.logicalRow = UInt32(max(0, core.logicalRow))
            self.logicalCol = UInt32(max(0, core.logicalCol))
            self.offset = UInt32(max(0, core.offset))
        }
    }

    // parity: native/src/editor-view.zig#EditorView [status=implemented hash=8d48f82bce2d]
    public final class EditorView: @unchecked Sendable {
        public let editBuffer: NativeZigEditBuffer.EditBuffer
        public let core: OpenTUICore.EditorView
        public let textBufferView: NativeZigTextBufferView.UnifiedTextBufferView

        public init(editBuffer: NativeZigEditBuffer.EditBuffer, viewportWidth: UInt32, viewportHeight: UInt32) {
            self.editBuffer = editBuffer
            let core = OpenTUICore.EditorView.create(
                editBuffer: editBuffer.core,
                viewportWidth: Int(viewportWidth),
                viewportHeight: Int(viewportHeight)
            )
            self.core = core
            self.textBufferView = NativeZigTextBufferView.UnifiedTextBufferView(
                buffer: editBuffer.textBuffer,
                wrapping: core.textBufferView
            )
        }

        public func setViewportSize(width: UInt32, height: UInt32) {
            core.setViewportSize(width: Int(width), height: Int(height))
        }

        public func setWrapMode(_ mode: TextWrapMode) {
            core.setWrapMode(mode)
        }

        public func getVisualCursor() -> VisualCursor {
            VisualCursor(core: core.getVisualCursor())
        }

        public func moveUpVisual() { core.moveUpVisual() }
        public func moveDownVisual() { core.moveDownVisual() }
        public func gotoVisualLineEnd() { core.gotoVisualLineEnd() }
        public func setCursorByOffset(_ offset: UInt32) { core.setCursorByOffset(Int(offset)) }
        public func getText() -> String { core.getText() }
        public func getSelectedText() -> String { core.getSelectedText() }
        public func deleteSelectedText() { core.deleteSelectedText() }
        public func replaceSelectedText(_ text: String) { core.replaceSelectedText(text) }
        public func getTotalVirtualLineCount() -> UInt32 { UInt32(max(0, core.getTotalVirtualLineCount())) }
        public func measureForDimensions(width: UInt32, height: UInt32) -> NativeZigTextBufferView.MeasureResult? {
            core.measureForDimensions(width: Int(width), height: Int(height)).map(NativeZigTextBufferView.MeasureResult.init(core:))
        }
    }
}

// MARK: - 7. native/src/audio.zig (58 unmapped symbols)

public enum NativeZigAudio: Sendable {
    // parity: native/src/audio.zig#Status [status=implemented hash=95eae0d57358]
    public enum Status: Sendable {
        public static let ok: Int32 = 0
        public static let errInvalid: Int32 = -1
        public static let errNoSpace: Int32 = -2
        public static let errDecode: Int32 = -3
        public static let errNotFound: Int32 = -4
        public static let errDevice: Int32 = -5
    }

    // parity: native/src/audio.zig#CreateOptions [status=implemented hash=323c3a4414c7]
    public struct CreateOptions: Equatable, Hashable, Sendable {
        public var sampleRate: UInt32
        public var playbackChannels: UInt32

        public init(sampleRate: UInt32 = 48_000, playbackChannels: UInt32 = 2) {
            self.sampleRate = sampleRate
            self.playbackChannels = playbackChannels
        }
    }

    // parity: native/src/audio.zig#StartOptions [status=implemented hash=93b481a7ab24]
    public struct StartOptions: Equatable, Hashable, Sendable {
        public var periodSizeInFrames: UInt32
        public var periodSizeInMilliseconds: UInt32
        public var periods: UInt32
        public var performanceProfile: UInt8
        public var shareMode: UInt8
        public var noPreSilencedOutputBuffer: Bool
        public var noClip: Bool
        public var noDisableDenormals: Bool
        public var noFixedSizedCallback: Bool
        public var wasapiNoAutoConvertSrc: Bool
        public var wasapiNoDefaultQualitySrc: Bool
        public var alsaNoMmap: Bool
        public var alsaNoAutoFormat: Bool
        public var alsaNoAutoChannels: Bool
        public var alsaNoAutoResample: Bool

        public init(
            periodSizeInFrames: UInt32 = 0,
            periodSizeInMilliseconds: UInt32 = 0,
            periods: UInt32 = 0,
            performanceProfile: UInt8 = 0,
            shareMode: UInt8 = 0,
            noPreSilencedOutputBuffer: Bool = false,
            noClip: Bool = false,
            noDisableDenormals: Bool = false,
            noFixedSizedCallback: Bool = false,
            wasapiNoAutoConvertSrc: Bool = false,
            wasapiNoDefaultQualitySrc: Bool = false,
            alsaNoMmap: Bool = false,
            alsaNoAutoFormat: Bool = false,
            alsaNoAutoChannels: Bool = false,
            alsaNoAutoResample: Bool = false
        ) {
            self.periodSizeInFrames = periodSizeInFrames
            self.periodSizeInMilliseconds = periodSizeInMilliseconds
            self.periods = periods
            self.performanceProfile = performanceProfile
            self.shareMode = shareMode
            self.noPreSilencedOutputBuffer = noPreSilencedOutputBuffer
            self.noClip = noClip
            self.noDisableDenormals = noDisableDenormals
            self.noFixedSizedCallback = noFixedSizedCallback
            self.wasapiNoAutoConvertSrc = wasapiNoAutoConvertSrc
            self.wasapiNoDefaultQualitySrc = wasapiNoDefaultQualitySrc
            self.alsaNoMmap = alsaNoMmap
            self.alsaNoAutoFormat = alsaNoAutoFormat
            self.alsaNoAutoChannels = alsaNoAutoChannels
            self.alsaNoAutoResample = alsaNoAutoResample
        }

        public func toCore() -> AudioStartOptions {
            AudioStartOptions(
                periodSizeInFrames: periodSizeInFrames == 0 ? nil : Int(periodSizeInFrames),
                periodSizeInMilliseconds: periodSizeInMilliseconds == 0 ? nil : Int(periodSizeInMilliseconds),
                periods: periods == 0 ? nil : Int(periods),
                performanceProfile: Int(performanceProfile),
                shareMode: Int(shareMode),
                noPreSilencedOutputBuffer: noPreSilencedOutputBuffer,
                noClip: noClip,
                noDisableDenormals: noDisableDenormals,
                noFixedSizedCallback: noFixedSizedCallback,
                wasapiNoAutoConvertSrc: wasapiNoAutoConvertSrc,
                wasapiNoDefaultQualitySrc: wasapiNoDefaultQualitySrc,
                alsaNoMMap: alsaNoMmap,
                alsaNoAutoFormat: alsaNoAutoFormat,
                alsaNoAutoChannels: alsaNoAutoChannels,
                alsaNoAutoResample: alsaNoAutoResample
            )
        }
    }

    // parity: native/src/audio.zig#VoiceOptions [status=implemented hash=175b2bc8f7fe]
    public struct VoiceOptions: Equatable, Hashable, Sendable {
        public var volume: Float
        public var pan: Float
        public var loop: Bool
        public var groupId: UInt32

        public init(volume: Float = 1.0, pan: Float = 0.0, loop: Bool = false, groupId: UInt32 = 0) {
            self.volume = volume
            self.pan = pan
            self.loop = loop
            self.groupId = groupId
        }
    }

    // parity: native/src/audio.zig#StreamFormat [status=implemented hash=366784a50263]
    public enum StreamFormat: Sendable {
        public static let mp3: UInt32 = 1
        public static let flac: UInt32 = 2
        public static let pcm: UInt32 = 3
    }

    // parity: native/src/audio.zig#StreamOptions [status=implemented hash=2500058bd257]
    public struct StreamOptions: Equatable, Hashable, Sendable {
        public var capacityMs: UInt32
        public var startupMs: UInt32
        public var resumeMs: UInt32
        public var volume: Float
        public var pan: Float
        public var groupId: UInt32
        public var maxProbeBytes: UInt32
        public var format: UInt32
        public var sampleRate: UInt32
        public var channels: UInt32

        public init(
            capacityMs: UInt32 = 1000,
            startupMs: UInt32 = 100,
            resumeMs: UInt32 = 100,
            volume: Float = 1.0,
            pan: Float = 0.0,
            groupId: UInt32 = 0,
            maxProbeBytes: UInt32 = 1024 * 1024,
            format: UInt32 = StreamFormat.pcm,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2
        ) {
            self.capacityMs = capacityMs
            self.startupMs = startupMs
            self.resumeMs = resumeMs
            self.volume = volume
            self.pan = pan
            self.groupId = groupId
            self.maxProbeBytes = maxProbeBytes
            self.format = format
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    // parity: native/src/audio.zig#StreamState [status=implemented hash=9420c29d2489]
    public enum StreamState: Sendable {
        public static let initializing: UInt32 = 0
        public static let buffering: UInt32 = 1
        public static let playing: UInt32 = 2
        public static let ended: UInt32 = 3
        public static let failed: UInt32 = 4
        public static let cancelled: UInt32 = 5
        public static let reconnecting: UInt32 = 6
    }

    // parity: native/src/audio.zig#StreamStats [status=implemented hash=b4e12a2c88f5]
    public struct StreamStats: Equatable, Hashable, Sendable {
        public var bytesReceived: UInt64
        public var framesDecoded: UInt64
        public var framesPlayed: UInt64
        public var state: UInt32
        public var sampleRate: UInt32
        public var channels: UInt32
        public var bufferedFrames: UInt32
        public var capacityFrames: UInt32
        public var underruns: UInt32
        public var errorCode: Int32
        public var readyGeneration: UInt32

        public init(
            bytesReceived: UInt64 = 0,
            framesDecoded: UInt64 = 0,
            framesPlayed: UInt64 = 0,
            state: UInt32 = StreamState.initializing,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2,
            bufferedFrames: UInt32 = 0,
            capacityFrames: UInt32 = 0,
            underruns: UInt32 = 0,
            errorCode: Int32 = 0,
            readyGeneration: UInt32 = 0
        ) {
            self.bytesReceived = bytesReceived
            self.framesDecoded = framesDecoded
            self.framesPlayed = framesPlayed
            self.state = state
            self.sampleRate = sampleRate
            self.channels = channels
            self.bufferedFrames = bufferedFrames
            self.capacityFrames = capacityFrames
            self.underruns = underruns
            self.errorCode = errorCode
            self.readyGeneration = readyGeneration
        }
    }

    // parity: native/src/audio.zig#StreamCloseReason [status=implemented hash=53b25fc57734]
    public enum StreamCloseReason: Sendable {
        public static let preserveNativeTerminal: UInt32 = 0
        public static let transportError: UInt32 = 1
        public static let disposed: UInt32 = 2
    }

    // parity: native/src/audio.zig#Stats [status=implemented hash=f7f0c8cdc883]
    public struct Stats: Equatable, Sendable {
        public var soundsLoaded: UInt32
        public var voicesActive: UInt32
        public var framesMixed: UInt64
        public var lockMisses: UInt32
        public var lastPeak: Float
        public var lastRms: Float

        public init(
            soundsLoaded: UInt32 = 0,
            voicesActive: UInt32 = 0,
            framesMixed: UInt64 = 0,
            lockMisses: UInt32 = 0,
            lastPeak: Float = 0,
            lastRms: Float = 0
        ) {
            self.soundsLoaded = soundsLoaded
            self.voicesActive = voicesActive
            self.framesMixed = framesMixed
            self.lockMisses = lockMisses
            self.lastPeak = lastPeak
            self.lastRms = lastRms
        }
    }

    // parity: native/src/audio.zig#CaptureStats [status=implemented hash=60db1cd215f0]
    public struct CaptureStats: Equatable, Hashable, Sendable {
        public var framesReceived: UInt64
        public var framesRead: UInt64
        public var framesDropped: UInt64
        public var sampleRate: UInt32
        public var channels: UInt32
        public var bufferedFrames: UInt32
        public var capacityFrames: UInt32

        public init(
            framesReceived: UInt64 = 0,
            framesRead: UInt64 = 0,
            framesDropped: UInt64 = 0,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2,
            bufferedFrames: UInt32 = 0,
            capacityFrames: UInt32 = 0
        ) {
            self.framesReceived = framesReceived
            self.framesRead = framesRead
            self.framesDropped = framesDropped
            self.sampleRate = sampleRate
            self.channels = channels
            self.bufferedFrames = bufferedFrames
            self.capacityFrames = capacityFrames
        }
    }

    // parity: native/src/audio.zig#CaptureBuffer [status=implemented hash=34741908216c]
    public final class CaptureBuffer: @unchecked Sendable {
        public let sampleRate: UInt32
        public let channels: UInt32
        public let capacityFrames: UInt32
        private var ring: [Float]
        private var readPos: Int = 0
        private var writePos: Int = 0
        private var buffered: Int = 0
        private var framesReceived: UInt64 = 0
        private var framesRead: UInt64 = 0
        private var framesDropped: UInt64 = 0

        public init(sampleRate: UInt32, channels: UInt32, capacityFrames: UInt32) {
            self.sampleRate = max(1, sampleRate)
            self.channels = max(1, channels)
            self.capacityFrames = max(1, capacityFrames)
            self.ring = Array(repeating: 0, count: Int(self.capacityFrames) * Int(self.channels))
        }

        public func write(_ input: [Float], frameCount: UInt32) {
            let ch = Int(channels)
            let cap = Int(capacityFrames)
            let count = min(Int(frameCount), input.count / ch)
            framesReceived &+= UInt64(count)
            for f in 0..<count {
                if buffered >= cap {
                    readPos = (readPos + 1) % cap
                    buffered -= 1
                    framesDropped &+= 1
                }
                for c in 0..<ch {
                    ring[writePos * ch + c] = input[f * ch + c]
                }
                writePos = (writePos + 1) % cap
                buffered += 1
            }
        }

        public func read(frameCount: UInt32) -> [Float] {
            let ch = Int(channels)
            let cap = Int(capacityFrames)
            let toRead = min(Int(frameCount), buffered)
            var out: [Float] = []
            out.reserveCapacity(toRead * ch)
            for _ in 0..<toRead {
                for c in 0..<ch {
                    out.append(ring[readPos * ch + c])
                }
                readPos = (readPos + 1) % cap
                buffered -= 1
            }
            framesRead &+= UInt64(toRead)
            return out
        }

        public func snapshot() -> CaptureStats {
            CaptureStats(
                framesReceived: framesReceived,
                framesRead: framesRead,
                framesDropped: framesDropped,
                sampleRate: sampleRate,
                channels: channels,
                bufferedFrames: UInt32(buffered),
                capacityFrames: capacityFrames
            )
        }
    }

    internal struct StreamSlot: Sendable {
        var id: UInt32
        var options: StreamOptions
        var stats: StreamStats
        var volume: Float
        var pan: Float
        var groupId: UInt32
        var pcmQueue: [Float] = []
        var ended: Bool = false
    }

    // parity: native/src/audio.zig#Engine [status=implemented hash=f4b81c92cefa]
    public final class Engine: @unchecked Sendable {
        public let core: AudioEngine
        fileprivate var streams: [UInt32: StreamSlot] = [:]
        fileprivate var nextStreamId: UInt32 = 1
        fileprivate var voiceSlots: [UInt32] = []
        fileprivate var playbackDevices: [AudioPlaybackDevice] = []
        fileprivate var captureDevices: [AudioCaptureDevice] = []
        fileprivate var mixerSuspended: Bool = false
        fileprivate var disposed: Bool = false

        public init(options: CreateOptions = CreateOptions()) {
            self.core = AudioEngine(
                options: AudioSetupOptions(
                    autoStart: false,
                    sampleRate: Int(options.sampleRate),
                    playbackChannels: Int(options.playbackChannels)
                )
            )
            self.playbackDevices = core.listPlaybackDevices() ?? []
            self.captureDevices = core.listCaptureDevices() ?? []
        }
    }

    // parity: native/src/audio.zig#create [status=implemented hash=4c0af1dff4de]
    public static func create(options: CreateOptions? = nil) -> Engine {
        Engine(options: options ?? CreateOptions())
    }

    // parity: native/src/audio.zig#destroy [status=implemented hash=d6b0bdd190ef]
    public static func destroy(_ engine: Engine) {
        engine.disposed = true
        engine.streams.removeAll()
        engine.voiceSlots.removeAll()
        engine.core.dispose()
    }

    // parity: native/src/audio.zig#refreshPlaybackDevices [status=implemented hash=6959fdb36fc3]
    public static func refreshPlaybackDevices(_ engine: Engine) -> Int32 {
        guard !engine.disposed else { return Status.errInvalid }
        engine.playbackDevices = engine.core.listPlaybackDevices() ?? []
        return Status.ok
    }

    // parity: native/src/audio.zig#getPlaybackDeviceCount [status=implemented hash=49845893fc5e]
    public static func getPlaybackDeviceCount(_ engine: Engine) -> UInt32 {
        UInt32(engine.playbackDevices.count)
    }

    // parity: native/src/audio.zig#getPlaybackDeviceName [status=implemented hash=3c88f2661fbf]
    public static func getPlaybackDeviceName(_ engine: Engine, index: UInt32) -> String? {
        let i = Int(index)
        guard i >= 0 && i < engine.playbackDevices.count else { return nil }
        return engine.playbackDevices[i].name
    }

    // parity: native/src/audio.zig#isPlaybackDeviceDefault [status=implemented hash=35709aec084c]
    public static func isPlaybackDeviceDefault(_ engine: Engine, index: UInt32) -> Bool {
        let i = Int(index)
        guard i >= 0 && i < engine.playbackDevices.count else { return false }
        return engine.playbackDevices[i].isDefault
    }

    // parity: native/src/audio.zig#selectPlaybackDevice [status=implemented hash=0d6f84df367b]
    public static func selectPlaybackDevice(_ engine: Engine, index: UInt32) -> Int32 {
        engine.core.selectPlaybackDevice(Int(index)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#clearPlaybackDeviceSelection [status=implemented hash=0ad24f732556]
    public static func clearPlaybackDeviceSelection(_ engine: Engine) {
        engine.core.clearPlaybackDeviceSelection()
    }

    // parity: native/src/audio.zig#refreshCaptureDevices [status=implemented hash=0ecd17a4024c]
    public static func refreshCaptureDevices(_ engine: Engine) -> Int32 {
        guard !engine.disposed else { return Status.errInvalid }
        engine.captureDevices = engine.core.listCaptureDevices() ?? []
        return Status.ok
    }

    // parity: native/src/audio.zig#getCaptureDeviceCount [status=implemented hash=a4c1a1caeb99]
    public static func getCaptureDeviceCount(_ engine: Engine) -> UInt32 {
        UInt32(engine.captureDevices.count)
    }

    // parity: native/src/audio.zig#getCaptureDeviceName [status=implemented hash=77a0c32158ad]
    public static func getCaptureDeviceName(_ engine: Engine, index: UInt32) -> String? {
        let i = Int(index)
        guard i >= 0 && i < engine.captureDevices.count else { return nil }
        return engine.captureDevices[i].name
    }

    // parity: native/src/audio.zig#isCaptureDeviceDefault [status=implemented hash=f49cd7de25b5]
    public static func isCaptureDeviceDefault(_ engine: Engine, index: UInt32) -> Bool {
        let i = Int(index)
        guard i >= 0 && i < engine.captureDevices.count else { return false }
        return engine.captureDevices[i].isDefault
    }

    // parity: native/src/audio.zig#selectCaptureDevice [status=implemented hash=8cc60b8d20a4]
    public static func selectCaptureDevice(_ engine: Engine, index: UInt32) -> Int32 {
        engine.core.selectCaptureDevice(Int(index)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#clearCaptureDeviceSelection [status=implemented hash=b50c6df0055b]
    public static func clearCaptureDeviceSelection(_ engine: Engine) {
        engine.core.clearCaptureDeviceSelection()
    }

    // parity: native/src/audio.zig#isCaptureRunning [status=implemented hash=9a3da8298f05]
    public static func isCaptureRunning(_ engine: Engine) -> Bool {
        engine.core.isCapturing()
    }

    // parity: native/src/audio.zig#startCapture [status=implemented hash=ed5afeb42dd4]
    public static func startCapture(
        _ engine: Engine,
        channels: UInt32 = 1,
        capacityFrames: UInt32 = 8192,
        options: StartOptions? = nil
    ) -> Int32 {
        let opts = AudioCaptureOptions(
            channels: Int(channels),
            capacityFrames: Int(capacityFrames),
            startOptions: options?.toCore()
        )
        return engine.core.startCapture(opts) ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#stopCapture [status=implemented hash=1035cf6b0442]
    public static func stopCapture(_ engine: Engine) -> Int32 {
        engine.core.stopCapture() ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#readCapture [status=implemented hash=76e4bf07cd21]
    public static func readCapture(_ engine: Engine, frameCount: UInt32) -> (status: Int32, samples: [Float], framesRead: UInt32) {
        guard let result = engine.core.readCaptureFrames(Int(frameCount)) else {
            return (Status.errInvalid, [], 0)
        }
        return (Status.ok, result.frames, UInt32(max(0, result.framesRead)))
    }

    // parity: native/src/audio.zig#getCaptureStats [status=implemented hash=45bbdccfbd42]
    public static func getCaptureStats(_ engine: Engine) -> (status: Int32, stats: CaptureStats?) {
        guard let s = engine.core.getCaptureStats() else {
            return (Status.errInvalid, nil)
        }
        return (
            Status.ok,
            CaptureStats(
                framesReceived: s.framesReceived,
                framesRead: s.framesRead,
                framesDropped: s.framesDropped,
                sampleRate: UInt32(max(0, s.sampleRate)),
                channels: UInt32(max(0, s.channels)),
                bufferedFrames: UInt32(max(0, s.bufferedFrames)),
                capacityFrames: UInt32(max(0, s.capacityFrames))
            )
        )
    }

    // parity: native/src/audio.zig#start [status=implemented hash=fc8aaddbabec]
    public static func start(_ engine: Engine, options: StartOptions? = nil) -> Int32 {
        engine.mixerSuspended = false
        return engine.core.start(options?.toCore()) ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#startMixer [status=implemented hash=e3a633a7ec12]
    public static func startMixer(_ engine: Engine) -> Int32 {
        engine.mixerSuspended = false
        return engine.core.startMixer() ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#suspendMixer [status=implemented hash=13e7b2963fab]
    public static func suspendMixer(_ engine: Engine) {
        engine.mixerSuspended = true
    }

    // parity: native/src/audio.zig#stop [status=implemented hash=609d225427a2]
    public static func stop(_ engine: Engine) -> Int32 {
        engine.core.stop() ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#voiceSlotIndex [status=implemented hash=695e6ebaf311]
    public static func voiceSlotIndex(_ engine: Engine, voiceId: UInt32) -> Int? {
        engine.voiceSlots.firstIndex(of: voiceId)
    }

    // parity: native/src/audio.zig#createStream [status=implemented hash=8a2b5022f939]
    public static func createStream(_ engine: Engine, options: StreamOptions = StreamOptions()) -> (status: Int32, streamId: UInt32) {
        guard !engine.disposed else { return (Status.errInvalid, 0) }
        let id = engine.nextStreamId
        engine.nextStreamId &+= 1
        let sr = options.sampleRate > 0 ? options.sampleRate : UInt32(engine.core.sampleRate)
        let ch = options.channels > 0 ? options.channels : UInt32(engine.core.playbackChannels)
        let capFrames = max(1, UInt32((UInt64(sr) * UInt64(max(1, options.capacityMs))) / 1000))
        let stats = StreamStats(
            state: StreamState.buffering,
            sampleRate: sr,
            channels: ch,
            bufferedFrames: 0,
            capacityFrames: capFrames
        )
        engine.streams[id] = StreamSlot(
            id: id,
            options: options,
            stats: stats,
            volume: options.volume,
            pan: options.pan,
            groupId: options.groupId
        )
        return (Status.ok, id)
    }

    // parity: native/src/audio.zig#writeStream [status=implemented hash=01cae06c748b]
    public static func writeStream(_ engine: Engine, streamId: UInt32, data: [UInt8]) -> (status: Int32, written: Int) {
        guard var slot = engine.streams[streamId] else { return (Status.errNotFound, 0) }
        slot.stats.bytesReceived &+= UInt64(data.count)
        let ch = max(1, Int(slot.stats.channels))
        if slot.options.format == StreamFormat.pcm {
            let floats = PCMConverter.bytesLEToFloat32(data)
            slot.pcmQueue.append(contentsOf: floats)
            let frames = floats.count / ch
            slot.stats.framesDecoded &+= UInt64(frames)
            slot.stats.bufferedFrames = UInt32(slot.pcmQueue.count / ch)
            if slot.stats.bufferedFrames > 0 {
                slot.stats.state = StreamState.playing
            }
        } else if !data.isEmpty {
            slot.stats.state = StreamState.playing
        }
        engine.streams[streamId] = slot
        return (Status.ok, data.count)
    }

    // parity: native/src/audio.zig#endStream [status=implemented hash=0b9e16bff64b]
    public static func endStream(_ engine: Engine, streamId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.ended = true
        slot.stats.state = StreamState.ended
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#restartStream [status=implemented hash=bc71af500028]
    public static func restartStream(_ engine: Engine, streamId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.pcmQueue.removeAll()
        slot.ended = false
        slot.stats.bufferedFrames = 0
        slot.stats.state = StreamState.buffering
        slot.stats.readyGeneration &+= 1
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamVolume [status=implemented hash=cbf7f7bdce87]
    public static func setStreamVolume(_ engine: Engine, streamId: UInt32, volume: Float) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.volume = max(0, volume)
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamPan [status=implemented hash=f9cd419996de]
    public static func setStreamPan(_ engine: Engine, streamId: UInt32, pan: Float) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.pan = min(1, max(-1, pan))
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamGroup [status=implemented hash=9422f678d447]
    public static func setStreamGroup(_ engine: Engine, streamId: UInt32, groupId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.groupId = groupId
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#getStreamStats [status=implemented hash=552d9f255987]
    public static func getStreamStats(_ engine: Engine, streamId: UInt32) -> (status: Int32, stats: StreamStats?) {
        guard let slot = engine.streams[streamId] else { return (Status.errNotFound, nil) }
        return (Status.ok, slot.stats)
    }

    // parity: native/src/audio.zig#closeStream [status=implemented hash=593dcc74733a]
    public static func closeStream(_ engine: Engine, streamId: UInt32, reason: UInt32 = StreamCloseReason.disposed) -> (status: Int32, finalStats: StreamStats?) {
        guard var slot = engine.streams.removeValue(forKey: streamId) else {
            return (Status.errNotFound, nil)
        }
        if reason == StreamCloseReason.transportError {
            slot.stats.state = StreamState.failed
        } else if reason == StreamCloseReason.disposed && slot.stats.state != StreamState.ended {
            slot.stats.state = StreamState.cancelled
        }
        return (Status.ok, slot.stats)
    }

    // parity: native/src/audio.zig#load [status=implemented hash=d9542d79e930]
    public static func load(_ engine: Engine, data: [UInt8]) -> (status: Int32, soundId: UInt32) {
        guard let sound = engine.core.loadSound(data) else {
            return (Status.errDecode, 0)
        }
        return (Status.ok, sound)
    }

    // parity: native/src/audio.zig#unload [status=implemented hash=4ff7e98d63e2]
    public static func unload(_ engine: Engine, soundId: UInt32) -> Int32 {
        engine.core.unloadSound(soundId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#createGroup [status=implemented hash=19b14e44e6fb]
    public static func createGroup(_ engine: Engine, name: String) -> (status: Int32, groupId: UInt32) {
        guard let id = engine.core.group(name) else {
            return (Status.errInvalid, 0)
        }
        return (Status.ok, id)
    }

    // parity: native/src/audio.zig#play [status=implemented hash=d5ff4a953d31]
    public static func play(_ engine: Engine, soundId: UInt32, options: VoiceOptions = VoiceOptions()) -> (status: Int32, voiceId: UInt32) {
        let playOpts = AudioPlayOptions(
            volume: Double(options.volume),
            pan: Double(options.pan),
            loop: options.loop,
            groupId: options.groupId == 0 ? nil : options.groupId
        )
        guard let voice = engine.core.play(soundId, options: playOpts) else {
            return (Status.errNotFound, 0)
        }
        if !engine.voiceSlots.contains(voice) {
            engine.voiceSlots.append(voice)
        }
        return (Status.ok, voice)
    }

    // parity: native/src/audio.zig#stopVoice [status=implemented hash=2d24fd8c99cd]
    public static func stopVoice(_ engine: Engine, voiceId: UInt32) -> Int32 {
        engine.voiceSlots.removeAll { $0 == voiceId }
        return engine.core.stopVoice(voiceId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setVoiceGroup [status=implemented hash=63e25792b55e]
    public static func setVoiceGroup(_ engine: Engine, voiceId: UInt32, groupId: UInt32) -> Int32 {
        engine.core.setVoiceGroup(voiceId, group: groupId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setGroupVolume [status=implemented hash=d08702d7a838]
    public static func setGroupVolume(_ engine: Engine, groupId: UInt32, volume: Float) -> Int32 {
        engine.core.setGroupVolume(groupId, volume: Double(volume)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setMasterVolume [status=implemented hash=dc888a8089ae]
    public static func setMasterVolume(_ engine: Engine, volume: Float) -> Int32 {
        engine.core.setMasterVolume(Double(volume)) ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#enableTap [status=implemented hash=02df1edd6f46]
    public static func enableTap(_ engine: Engine, enabled: Bool, capacityFrames: UInt32 = 8192) -> Int32 {
        let ok = enabled
            ? engine.core.enableTap(capacityFrames: Int(capacityFrames))
            : engine.core.disableTap()
        return ok ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#readTap [status=implemented hash=d658b438a863]
    public static func readTap(_ engine: Engine, frameCount: UInt32, channels: UInt8 = 2) -> (status: Int32, samples: [Float], framesRead: UInt32) {
        guard let result = engine.core.readTapFrames(Int(frameCount), channels: Int(channels)) else {
            return (Status.errInvalid, [], 0)
        }
        return (Status.ok, result.frames, UInt32(max(0, result.framesRead)))
    }

    // parity: native/src/audio.zig#mixToBuffer [status=implemented hash=8d7bfb474389]
    public static func mixToBuffer(_ engine: Engine, frameCount: UInt32, channels: UInt8 = 2) -> (status: Int32, samples: [Float]) {
        guard !engine.mixerSuspended else {
            return (Status.ok, Array(repeating: 0, count: Int(frameCount) * Int(channels)))
        }
        guard let mixed = engine.core.mixFrames(Int(frameCount), channels: Int(channels)) else {
            return (Status.errInvalid, [])
        }
        return (Status.ok, mixed)
    }

    // parity: native/src/audio.zig#getStats [status=implemented hash=c2167663b419]
    public static func getStats(_ engine: Engine) -> (status: Int32, stats: Stats?) {
        guard let s = engine.core.getStats() else {
            return (Status.errInvalid, nil)
        }
        return (
            Status.ok,
            Stats(
                soundsLoaded: UInt32(max(0, s.soundsLoaded)),
                voicesActive: UInt32(max(0, s.voicesActive)),
                framesMixed: s.framesMixed,
                lockMisses: UInt32(max(0, s.lockMisses)),
                lastPeak: s.lastPeak,
                lastRms: s.lastRms
            )
        )
    }
}

// MARK: - 8. native/src/image.zig (37 unmapped symbols)

public enum NativeZigImage: Sendable {
    // parity: native/src/image.zig#Status [status=implemented hash=dad504dad748]
    public enum Status: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case ok = 0
        case invalidHandle = 1
        case unsupportedFormat = 2
        case unsupportedColorSpace = 3
        case malformedInput = 4
        case dimensionLimit = 5
        case memoryLimit = 6
        case invalidArgument = 7
        case outOfMemory = 8
        case outputTooSmall = 9
        case internalError = 10
        case unsupportedFeature = 11
        case busy = 12
    }

    // parity: native/src/image.zig#Format [status=implemented hash=92be84a6cc6b]
    public enum Format: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case unknown = 0
        case png = 1
        case rawRgba = 2
        case jpeg = 3
        case webp = 4
        case gif = 5

        public init(core: ImageFormat) {
            switch core {
            case .png: self = .png
            case .rawRgba: self = .rawRgba
            case .jpeg: self = .jpeg
            case .webp: self = .webp
            case .gif: self = .gif
            case .bmp, .ppm: self = .unknown
            }
        }
    }

    // parity: native/src/image.zig#ColorStatus [status=implemented hash=51f06dffef29]
    public enum ColorStatus: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case assumedSRGB = 0
        case explicitSRGB = 1

        public init(core: ImageColorStatus) {
            self = core == .explicitSrgb ? .explicitSRGB : .assumedSRGB
        }
    }

    // parity: native/src/image.zig#PixelFormat [status=implemented hash=b5b34345f305]
    public enum PixelFormat: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case rgba8 = 0
        case bgra8 = 1

        public var coreValue: OpenTUICore.PixelFormat {
            self == .rgba8 ? .rgba8 : .bgra8
        }
    }

    // parity: native/src/image.zig#PixelAlpha [status=implemented hash=c6216317e90d]
    public enum PixelAlpha: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case straight = 0
        case opaque = 1

        public var coreValue: PixelAlphaMode {
            self == .straight ? .straight : .opaque
        }
    }

    // parity: native/src/image.zig#PixelImportOptions [status=implemented hash=0b22237ddcb6]
    public struct PixelImportOptions: Equatable, Hashable, Sendable {
        public var stride: UInt32
        public var format: PixelFormat
        public var alpha: PixelAlpha

        public init(stride: UInt32, format: PixelFormat = .rgba8, alpha: PixelAlpha = .straight) {
            self.stride = stride
            self.format = format
            self.alpha = alpha
        }
    }

    // parity: native/src/image.zig#Info [status=implemented hash=097aa3d6d3ed]
    public struct Info: Equatable, Hashable, Sendable {
        public var width: UInt32
        public var height: UInt32
        public var sourceWidth: UInt32
        public var sourceHeight: UInt32
        public var format: Format
        public var colorStatus: ColorStatus
        public var orientation: UInt32
        public var hasAlpha: UInt32

        public init(
            width: UInt32 = 0,
            height: UInt32 = 0,
            sourceWidth: UInt32 = 0,
            sourceHeight: UInt32 = 0,
            format: Format = .unknown,
            colorStatus: ColorStatus = .assumedSRGB,
            orientation: UInt32 = 1,
            hasAlpha: UInt32 = 0
        ) {
            self.width = width
            self.height = height
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.format = format
            self.colorStatus = colorStatus
            self.orientation = orientation
            self.hasAlpha = hasAlpha
        }

        public init(core: ImageInfo) {
            self.width = UInt32(max(0, core.width))
            self.height = UInt32(max(0, core.height))
            self.sourceWidth = UInt32(max(0, core.sourceWidth))
            self.sourceHeight = UInt32(max(0, core.sourceHeight))
            self.format = Format(core: core.format)
            self.colorStatus = ColorStatus(core: core.colorStatus)
            self.orientation = UInt32(max(1, core.orientation))
            self.hasAlpha = core.hasAlpha ? 1 : 0
        }
    }

    // parity: native/src/image.zig#Limits [status=implemented hash=13f36fc09a7f]
    public struct Limits: Equatable, Hashable, Sendable {
        public var maxEncodedBytes: UInt64
        public var maxWidth: UInt32
        public var maxHeight: UInt32
        public var maxPixels: UInt64
        public var maxDecodedBytes: UInt64

        public init(
            maxEncodedBytes: UInt64 = 64 * 1024 * 1024,
            maxWidth: UInt32 = 16_384,
            maxHeight: UInt32 = 16_384,
            maxPixels: UInt64 = 25_000_000,
            maxDecodedBytes: UInt64 = 100 * 1024 * 1024
        ) {
            self.maxEncodedBytes = maxEncodedBytes
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.maxPixels = maxPixels
            self.maxDecodedBytes = maxDecodedBytes
        }
    }

    // parity: native/src/image.zig#ResizeFilter [status=implemented hash=6927b29c7123]
    public enum ResizeFilter: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case `default` = 0
        case area = 1
        case triangle = 2
        case cubicBSpline = 3
        case catmullRom = 4
        case mitchell = 5
        case nearest = 6

        public var coreValue: ResizeKernel {
            switch self {
            case .default: return .default
            case .area: return .area
            case .triangle: return .triangle
            case .cubicBSpline: return .cubicBspline
            case .catmullRom: return .catmullRom
            case .mitchell: return .mitchell
            case .nearest: return .nearest
            }
        }
    }

    // parity: native/src/image.zig#Transform [status=implemented hash=a9c6bd2e2e05]
    public enum Transform: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case rotate90 = 0
        case rotate180 = 1
        case rotate270 = 2
        case flip = 3
        case flop = 4
    }

    // parity: native/src/image.zig#Blend [status=implemented hash=44927f5d9646]
    public enum Blend: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case sourceOver = 0
        case source = 1
        case destinationOver = 2

        public var coreValue: BlendMode {
            switch self {
            case .sourceOver: return .sourceOver
            case .source: return .source
            case .destinationOver: return .destinationOver
            }
        }
    }

    // parity: native/src/image.zig#RenderProtocol [status=implemented hash=471e6d79a171]
    public enum RenderProtocol: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case auto = 0
        case kitty = 1
        case sixel = 2
        case blocks = 3
    }

    // parity: native/src/image.zig#Fit [status=implemented hash=734260e7966a]
    public enum Fit: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case fit = 0
        case cover = 1
        case fill = 2
    }

    // parity: native/src/image.zig#Region [status=implemented hash=734f9a8e3d62]
    public struct Region: Equatable, Hashable, Sendable {
        public var left: UInt32
        public var top: UInt32
        public var width: UInt32
        public var height: UInt32

        public init(left: UInt32 = 0, top: UInt32 = 0, width: UInt32, height: UInt32) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
        }

        public static func inside(_ crop: Region?, width: UInt32, height: UInt32) -> Region? {
            guard let crop else { return nil }
            guard crop.width > 0, crop.height > 0 else { return nil }
            guard UInt64(crop.left) + UInt64(crop.width) <= UInt64(width),
                  UInt64(crop.top) + UInt64(crop.height) <= UInt64(height)
            else {
                return nil
            }
            return crop
        }
    }

    // parity: native/src/image.zig#Image [status=implemented hash=751013a53630]
    public final class Image: @unchecked Sendable {
        public private(set) var core: NativeImage
        public var ownerContextId: UInt64 = 0
        public var renderId: UInt32 = 0
        public private(set) var refCount: UInt32 = 1

        public init(core: NativeImage) {
            self.core = core
        }

        public var width: UInt32 { UInt32(max(0, core.width)) }
        public var height: UInt32 { UInt32(max(0, core.height)) }
        public var pixels: [UInt8] { core.rgbaBytes }

        public func retain() { refCount &+= 1 }
        public func release() {
            if refCount > 1 {
                refCount -= 1
            } else {
                refCount = 0
                core.dispose()
            }
        }

        public func info() -> Info {
            if let coreInfo = try? core.info() {
                return Info(core: coreInfo)
            }
            return Info(width: width, height: height, sourceWidth: width, sourceHeight: height, format: .rawRgba, hasAlpha: 1)
        }

        public func clone() throws(ImageError) -> Image {
            Image(core: try core.clone())
        }

        public func ensureEncodedPng() throws(ImageError) -> [UInt8] {
            try core.encodePNG()
        }

        internal func replaceCore(_ newCore: NativeImage) {
            self.core = newCore
        }
    }

    // parity: native/src/image.zig#dimensionsWithinLimits [status=implemented hash=1553b7c2c598]
    public static func dimensionsWithinLimits(width: UInt32, height: UInt32, limits: Limits = Limits()) -> Bool {
        guard width > 0 && height > 0 else { return false }
        guard width <= limits.maxWidth && height <= limits.maxHeight else { return false }
        let pixels = UInt64(width) * UInt64(height)
        guard pixels <= limits.maxPixels else { return false }
        return pixels * 4 <= limits.maxDecodedBytes
    }

    // parity: native/src/image.zig#statusFromError [status=implemented hash=c7c97f6d2d90]
    public static func statusFromError(_ error: any Error) -> Status {
        if let imgErr = error as? ImageError {
            switch imgErr.code {
            case .invalidHandle: return .invalidHandle
            case .unsupportedFormat: return .unsupportedFormat
            case .unsupportedColorSpace: return .unsupportedColorSpace
            case .malformedData: return .malformedInput
            case .dimensionLimit: return .dimensionLimit
            case .memoryLimit: return .memoryLimit
            case .invalidArgument: return .invalidArgument
            case .outOfMemory: return .outOfMemory
            case .outputTooSmall: return .outputTooSmall
            case .internalError: return .internalError
            case .unsupportedFeature: return .unsupportedFeature
            case .busy: return .busy
            }
        }
        return .internalError
    }

    // parity: native/src/image.zig#errorFromStatus [status=implemented hash=d2085e9e9ac3]
    public static func errorFromStatus(_ status: Status) throws(ImageError) {
        switch status {
        case .ok: return
        case .invalidHandle: throw ImageError(code: .invalidHandle, message: "invalid image handle")
        case .unsupportedFormat: throw ImageError(code: .unsupportedFormat, message: "unsupported image format")
        case .unsupportedColorSpace: throw ImageError(code: .unsupportedColorSpace, message: "unsupported color space")
        case .malformedInput: throw ImageError(code: .malformedData, message: "malformed image data")
        case .dimensionLimit: throw ImageError(code: .dimensionLimit, message: "image dimension limit exceeded")
        case .memoryLimit: throw ImageError(code: .memoryLimit, message: "image memory limit exceeded")
        case .invalidArgument: throw ImageError(code: .invalidArgument, message: "invalid image argument")
        case .outOfMemory: throw ImageError(code: .outOfMemory, message: "out of memory")
        case .outputTooSmall: throw ImageError(code: .outputTooSmall, message: "image output buffer too small")
        case .internalError: throw ImageError(code: .internalError, message: "internal image error")
        case .unsupportedFeature: throw ImageError(code: .unsupportedFeature, message: "unsupported image feature")
        case .busy: throw ImageError(code: .busy, message: "image is busy")
        }
    }

    // parity: native/src/image.zig#IccCacheStats [status=implemented hash=a8e6aa99a49b]
    public struct IccCacheStats: Equatable, Hashable, Sendable {
        public var hits: UInt64
        public var misses: UInt64
        public var entries: UInt32

        public init(hits: UInt64 = 0, misses: UInt64 = 0, entries: UInt32 = 0) {
            self.hits = hits
            self.misses = misses
            self.entries = entries
        }
    }

    private struct IccCacheState: Sendable {
        var hits: UInt64 = 0
        var misses: UInt64 = 0
        var entries: UInt32 = 0
        var retainCount: UInt32 = 0
        var failCopyOnce: Bool = false
    }

    private static let iccCache = Mutex(IccCacheState())

    // parity: native/src/image.zig#clearIccCache [status=implemented hash=3a69c3702dcf]
    public static func clearIccCache() {
        iccCache.withLock { state in
            state.hits = 0
            state.misses = 0
            state.entries = 0
        }
    }

    // parity: native/src/image.zig#retainIccCache [status=implemented hash=267bad509668]
    public static func retainIccCache() {
        iccCache.withLock { $0.retainCount &+= 1 }
    }

    // parity: native/src/image.zig#releaseIccCache [status=implemented hash=12a30422fef0]
    public static func releaseIccCache() {
        iccCache.withLock { state in
            if state.retainCount > 0 {
                state.retainCount -= 1
            }
            if state.retainCount == 0 {
                state.entries = 0
            }
        }
    }

    // parity: native/src/image.zig#getIccCacheStats [status=implemented hash=16080d5d89bb]
    public static func getIccCacheStats() -> IccCacheStats {
        iccCache.withLock { IccCacheStats(hits: $0.hits, misses: $0.misses, entries: $0.entries) }
    }

    // parity: native/src/image.zig#testFailIccProfileCopyAllocationOnce [status=implemented hash=9887187cb9eb]
    public static func testFailIccProfileCopyAllocationOnce() {
        iccCache.withLock { $0.failCopyOnce = true }
    }

    // parity: native/src/image.zig#probe [status=implemented hash=86fb43edd224]
    public static func probe(_ data: [UInt8], limits: Limits = Limits()) -> (status: Status, info: Info) {
        guard UInt64(data.count) <= limits.maxEncodedBytes else {
            return (.memoryLimit, Info())
        }
        do {
            let coreInfo = try OpenTUICore.imageInfo(data)
            let info = Info(core: coreInfo)
            guard dimensionsWithinLimits(width: info.width, height: info.height, limits: limits) else {
                return (.dimensionLimit, info)
            }
            return (.ok, info)
        } catch {
            return (statusFromError(error), Info())
        }
    }

    // parity: native/src/image.zig#inspect [status=implemented hash=b667ff6c7688]
    public static func inspect(_ data: [UInt8], limits: Limits = Limits()) -> (status: Status, info: Info) {
        probe(data, limits: limits)
    }

    // parity: native/src/image.zig#inspectOwned [status=implemented hash=f9a4718c1942]
    public static func inspectOwned(_ data: [UInt8], limits: Limits = Limits()) throws(ImageError) -> Info {
        let result = inspect(data, limits: limits)
        try errorFromStatus(result.status)
        return result.info
    }

    // parity: native/src/image.zig#createFromRgba [status=implemented hash=76e420de51e4]
    public static func createFromRgba(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        stride: UInt32
    ) throws(ImageError) -> Image {
        guard dimensionsWithinLimits(width: width, height: height) else {
            throw ImageError(code: .dimensionLimit, message: "dimensions exceed limits")
        }
        let core = try NativeImage.fromRgba(
            pixels,
            width: Int(width),
            height: Int(height),
            stride: stride == 0 ? nil : Int(stride)
        )
        return Image(core: core)
    }

    // parity: native/src/image.zig#createFromPixels [status=implemented hash=1c890f4d3eb3]
    public static func createFromPixels(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions
    ) throws(ImageError) -> Image {
        guard dimensionsWithinLimits(width: width, height: height) else {
            throw ImageError(code: .dimensionLimit, message: "dimensions exceed limits")
        }
        let core = try NativeImage.fromPixels(
            pixels,
            width: Int(width),
            height: Int(height),
            options: OpenTUICore.PixelImportOptions(
                stride: options.stride == 0 ? nil : Int(options.stride),
                format: options.format.coreValue,
                alpha: options.alpha.coreValue
            )
        )
        return Image(core: core)
    }

    // parity: native/src/image.zig#updatePixels [status=implemented hash=1eb6406551e1]
    public static func updatePixels(_ image: Image, pixels: [UInt8], options: PixelImportOptions) throws(ImageError) {
        let updated = try NativeImage.fromPixels(
            pixels,
            width: Int(image.width),
            height: Int(image.height),
            options: OpenTUICore.PixelImportOptions(
                stride: options.stride == 0 ? nil : Int(options.stride),
                format: options.format.coreValue,
                alpha: options.alpha.coreValue
            )
        )
        image.replaceCore(updated)
    }

    // parity: native/src/image.zig#decode [status=implemented hash=c9e58e841107]
    public static func decode(_ data: [UInt8], limits: Limits = Limits()) throws(ImageError) -> Image {
        guard UInt64(data.count) <= limits.maxEncodedBytes else {
            throw ImageError(code: .memoryLimit, message: "encoded bytes exceed limit")
        }
        let core = try NativeImage.decode(data)
        guard dimensionsWithinLimits(width: UInt32(max(0, core.width)), height: UInt32(max(0, core.height)), limits: limits) else {
            throw ImageError(code: .dimensionLimit, message: "decoded image exceeds dimension limits")
        }
        return Image(core: core)
    }

    // parity: native/src/image.zig#transform [status=implemented hash=2d148d49d729]
    public static func transform(_ source: Image, operation: Transform) throws(ImageError) -> Image {
        let result: NativeImage
        switch operation {
        case .rotate90: result = try source.core.rotate(90)
        case .rotate180: result = try source.core.rotate(180)
        case .rotate270: result = try source.core.rotate(270)
        case .flip: result = try source.core.flip()
        case .flop: result = try source.core.flop()
        }
        return Image(core: result)
    }

    // parity: native/src/image.zig#extract [status=implemented hash=564936d18fe7]
    public static func extract(
        _ source: Image,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(ImageError) -> Image {
        let result = try source.core.extract(
            ExtractOptions(left: Int(left), top: Int(top), width: Int(width), height: Int(height))
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#extend [status=implemented hash=a63e5518c6a2]
    public static func extend(
        _ source: Image,
        top: UInt32 = 0,
        right: UInt32 = 0,
        bottom: UInt32 = 0,
        left: UInt32 = 0,
        background: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    ) throws(ImageError) -> Image {
        let result = try source.core.extend(
            ExtendOptions(
                top: Int(top),
                right: Int(right),
                bottom: Int(bottom),
                left: Int(left),
                background: background
            )
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#resize [status=implemented hash=9cd1dbebcc5e]
    public static func resize(
        _ source: Image,
        width: UInt32,
        height: UInt32,
        filter: ResizeFilter = .default
    ) throws(ImageError) -> Image {
        let result = try source.core.resize(
            ResizeOptions(width: Int(width), height: Int(height), kernel: filter.coreValue)
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#composite [status=implemented hash=17bb448e320a]
    public static func composite(
        base: Image,
        overlay: Image,
        left: Int32 = 0,
        top: Int32 = 0,
        blend: Blend = .sourceOver,
        opacity: Double = 1.0
    ) throws(ImageError) -> Image {
        let result = try base.core.composite(
            overlay.core,
            options: CompositeOptions(left: Int(left), top: Int(top), blend: blend.coreValue, opacity: opacity)
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#copyPixels [status=implemented hash=c403d45c4d7a]
    public static func copyPixels(
        _ image: Image,
        destination: inout [UInt8],
        stride: UInt32 = 0,
        bgra: Bool = false
    ) -> Status {
        do {
            try image.core.copyTo(
                &destination,
                stride: stride == 0 ? nil : Int(stride),
                format: bgra ? .bgra8 : .rgba8
            )
            return .ok
        } catch {
            return statusFromError(error)
        }
    }
}

// MARK: - 9. native/src/terminal-image.zig (18 unmapped symbols)

public enum NativeZigTerminalImage: Sendable {
    public static let imageIdMask: UInt32 = 0x03FF_FFFF
    private static let tmuxApcStart = "\u{1B}Ptmux;\u{1B}\u{1B}_G"
    private static let tmuxApcEnd = "\u{1B}\u{1B}\\\u{1B}\\"

    // parity: native/src/terminal-image.zig#KittyPixelFormat [status=implemented hash=6340034568b1]
    public enum KittyPixelFormat: Equatable, Hashable, Sendable, CaseIterable {
        case auto
        case rgb
        case rgba
    }

    // parity: native/src/terminal-image.zig#KittyEncoding [status=implemented hash=1a91dfa9af3b]
    public enum KittyEncoding: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case raw = 0
        case zlib = 1
        case png = 2
        case file = 3
    }

    // parity: native/src/terminal-image.zig#KITTY_PREPARE_BYTES_MAX [status=implemented hash=9558ccc61235]
    public static let KITTY_PREPARE_BYTES_MAX: Int = 64 * 1024 * 1024

    // parity: native/src/terminal-image.zig#kittyPayloadSize [status=implemented hash=20044341d28e]
    public static func kittyPayloadSize(_ image: NativeZigImage.Image) -> Int {
        Int(image.width) * Int(image.height) * 4
    }

    // parity: native/src/terminal-image.zig#writeKittyPayload [status=implemented hash=bb8b84529ca6]
    public static func writeKittyPayload(_ image: NativeZigImage.Image, requestedFormat: KittyPixelFormat = .rgba) -> [UInt8] {
        let rgba = image.pixels
        if requestedFormat == .rgb {
            var rgb: [UInt8] = []
            rgb.reserveCapacity((rgba.count / 4) * 3)
            var i = 0
            while i + 3 < rgba.count {
                rgb.append(rgba[i])
                rgb.append(rgba[i + 1])
                rgb.append(rgba[i + 2])
                i += 4
            }
            return rgb
        }
        return rgba
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmitEncoded [status=implemented hash=7767b1efb3dc]
    public static func writeKittyTransmitEncoded(
        payload: [UInt8],
        width: UInt32,
        height: UInt32,
        id: UInt32,
        encoding: KittyEncoding = .raw,
        pixelFormat: KittyPixelFormat = .rgba,
        tmux: Bool = false
    ) -> String {
        let b64 = encodeImageBase64(payload)
        let chunkLimit = 4096
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        let fmtCode: Int
        switch encoding {
        case .png: fmtCode = 100
        case .raw, .zlib, .file: fmtCode = pixelFormat == .rgb ? 24 : 32
        }
        var headerParts = ["a=t", "f=\(fmtCode)", "i=\(id)", "q=2"]
        if encoding != .png {
            headerParts.append("s=\(width)")
            headerParts.append("v=\(height)")
        }
        if encoding == .zlib {
            headerParts.append("o=z")
        } else if encoding == .file {
            headerParts.append("t=f")
        }
        if b64.isEmpty {
            return "\(startSeq)\(headerParts.joined(separator: ","));\(endSeq)"
        }
        var out = ""
        let bytes = Array(b64.utf8)
        var offset = 0
        var first = true
        while offset < bytes.count {
            let end = min(offset + chunkLimit, bytes.count)
            let more = end < bytes.count ? 1 : 0
            let chunkStr = String(decoding: bytes[offset..<end], as: UTF8.self)
            if first {
                out += "\(startSeq)\(headerParts.joined(separator: ",")),m=\(more);\(chunkStr)\(endSeq)"
                first = false
            } else {
                out += "\(startSeq)m=\(more);\(chunkStr)\(endSeq)"
            }
            offset = end
        }
        return out
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmit [status=implemented hash=7b5ec21f40e8]
    public static func writeKittyTransmit(_ image: NativeZigImage.Image, id: UInt32, tmux: Bool = false) -> String {
        writeKittyTransmitFormat(image, id: id, tmux: tmux, requestedFormat: .auto)
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmitFormat [status=implemented hash=0d12fd5daacf]
    public static func writeKittyTransmitFormat(
        _ image: NativeZigImage.Image,
        id: UInt32,
        tmux: Bool = false,
        requestedFormat: KittyPixelFormat = .auto
    ) -> String {
        let effective: KittyPixelFormat
        if requestedFormat == .auto {
            effective = image.info().hasAlpha != 0 ? .rgba : .rgb
        } else {
            effective = requestedFormat
        }
        let payload = writeKittyPayload(image, requestedFormat: effective)
        return writeKittyTransmitEncoded(
            payload: payload,
            width: image.width,
            height: image.height,
            id: id,
            encoding: .raw,
            pixelFormat: effective,
            tmux: tmux
        )
    }

    // parity: native/src/terminal-image.zig#kittyPlacementZ [status=implemented hash=3c0829852a36]
    public static func kittyPlacementZ(placementId: UInt32) -> Int32 {
        let clamped = min(placementId, imageIdMask)
        return (Int32.min / 2) &+ Int32(bitPattern: clamped)
    }

    // parity: native/src/terminal-image.zig#writeKittyPlacement [status=implemented hash=61025e7ef9a4]
    public static func writeKittyPlacement(
        id: UInt32,
        placementId: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        sourceX: UInt32 = 0,
        sourceY: UInt32 = 0,
        sourceWidth: UInt32 = 0,
        sourceHeight: UInt32 = 0,
        z: Int32,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        return "\u{1B}[\(y + 1);\(x + 1)H\(startSeq)a=p,i=\(id),p=\(placementId),c=\(width),r=\(height),x=\(sourceX),y=\(sourceY),w=\(sourceWidth),h=\(sourceHeight),C=1,z=\(z),q=2\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#writeKittyPlacementAtCursor [status=implemented hash=a3b79e0f85ed]
    public static func writeKittyPlacementAtCursor(
        id: UInt32,
        placementId: UInt32,
        width: UInt32,
        height: UInt32,
        z: Int32,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        return "\(startSeq)a=p,i=\(id),p=\(placementId),c=\(width),r=\(height),C=1,z=\(z),q=2\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#writeKittyDelete [status=implemented hash=a3edca49ad85]
    public static func writeKittyDelete(
        id: UInt32,
        placementId: UInt32? = nil,
        freeImage: Bool = false,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        let deleteKind = freeImage ? "I" : "i"
        var body = "a=d,d=\(deleteKind),i=\(id)"
        if let p = placementId {
            body += ",p=\(p)"
        }
        body += ",q=2"
        return "\(startSeq)\(body)\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#QuantizedSixel [status=implemented hash=a022881be45a]
    public struct QuantizedSixel: Equatable, Hashable, Sendable {
        public var palette: [RGBTriplet]
        public var indices: [UInt8]
        public var width: UInt32
        public var height: UInt32

        public init(palette: [RGBTriplet], indices: [UInt8], width: UInt32, height: UInt32) {
            self.palette = palette
            self.indices = indices
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/terminal-image.zig#quantizeSixel [status=implemented hash=f59877321f4f]
    public static func quantizeSixel(_ image: NativeZigImage.Image, maxColors: Int = 255) -> QuantizedSixel {
        let limit = max(1, min(255, maxColors))
        let rgba = image.pixels
        let pixelCount = Int(image.width) * Int(image.height)
        var palette: [RGBTriplet] = []
        var paletteMap: [UInt32: UInt8] = [:]
        var indices: [UInt8] = Array(repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let base = i * 4
            guard base + 3 < rgba.count else { break }
            let r = rgba[base]
            let g = rgba[base + 1]
            let b = rgba[base + 2]
            let a = rgba[base + 3]
            if a < 128 {
                indices[i] = 255 // transparent sentinel
                continue
            }
            let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            if let existing = paletteMap[key] {
                indices[i] = existing
            } else if palette.count < limit {
                let idx = UInt8(palette.count)
                palette.append(RGBTriplet(r, g, b))
                paletteMap[key] = idx
                indices[i] = idx
            } else {
                // Nearest color in palette
                var bestIdx: UInt8 = 0
                var bestDist = Int.max
                for (pIdx, c) in palette.enumerated() {
                    let dr = Int(r) - Int(c.r)
                    let dg = Int(g) - Int(c.g)
                    let db = Int(b) - Int(c.b)
                    let d = dr * dr + dg * dg + db * db
                    if d < bestDist {
                        bestDist = d
                        bestIdx = UInt8(pIdx)
                    }
                }
                indices[i] = bestIdx
            }
        }
        return QuantizedSixel(palette: palette, indices: indices, width: image.width, height: image.height)
    }

    // parity: native/src/terminal-image.zig#writeSixelIndexedPayload [status=implemented hash=4797b0897e46]
    public static func writeSixelIndexedPayload(_ quantized: QuantizedSixel) -> String {
        let width = Int(quantized.width)
        let height = Int(quantized.height)
        guard width > 0 && height > 0 else { return "" }

        var out = "\"1;1;\(width);\(height)"
        for (idx, c) in quantized.palette.enumerated() {
            let rPct = (Int(c.r) * 100 + 127) / 255
            let gPct = (Int(c.g) * 100 + 127) / 255
            let bPct = (Int(c.b) * 100 + 127) / 255
            out += "#\(idx);2;\(rPct);\(gPct);\(bPct)"
        }

        var bandY = 0
        while bandY < height {
            var firstColorInBand = true
            for colorIdx in 0..<quantized.palette.count {
                let target = UInt8(colorIdx)
                var hasAny = false
                var bandBytes: [UInt8] = Array(repeating: 0, count: width)
                for bit in 0..<6 {
                    let y = bandY + bit
                    if y >= height { break }
                    let rowBase = y * width
                    let mask = UInt8(1 << bit)
                    for x in 0..<width {
                        if quantized.indices[rowBase + x] == target {
                            bandBytes[x] |= mask
                            hasAny = true
                        }
                    }
                }
                if !hasAny { continue }
                if !firstColorInBand { out += "$" }
                firstColorInBand = false
                out += "#\(colorIdx)"
                var x = 0
                while x < width {
                    let b = bandBytes[x]
                    var run = 1
                    while x + run < width && bandBytes[x + run] == b {
                        run += 1
                    }
                    let ch = Character(UnicodeScalar(UInt32(b) + 63)!)
                    if run >= 4 {
                        out += "!\(run)\(ch)"
                    } else {
                        for _ in 0..<run { out.append(ch) }
                    }
                    x += run
                }
            }
            if bandY + 6 < height {
                out += "-"
            }
            bandY += 6
        }
        return out
    }

    // parity: native/src/terminal-image.zig#writeSixelPayload [status=implemented hash=629f5f2ca395]
    public static func writeSixelPayload(_ image: NativeZigImage.Image) -> String {
        let quantized = quantizeSixel(image, maxColors: 255)
        return writeSixelIndexedPayload(quantized)
    }

    // parity: native/src/terminal-image.zig#writeSixelFramedPayload [status=implemented hash=9d2438ad2a19]
    public static func writeSixelFramedPayload(_ payload: String, tmux: Bool = false) -> String {
        if tmux {
            return "\u{1B}Ptmux;\u{1B}\u{1B}Pq\(payload)\u{1B}\u{1B}\\\u{1B}\\"
        }
        return "\u{1B}Pq\(payload)\u{1B}\\"
    }

    // parity: native/src/terminal-image.zig#writeSixel [status=implemented hash=fc2a4bae3adb]
    public static func writeSixel(_ image: NativeZigImage.Image, tmux: Bool = false) -> String {
        if !tmux, let encoded = try? SixelEncoder.encode(image.core, maxColors: 255) {
            return encoded
        }
        let payload = writeSixelPayload(image)
        return writeSixelFramedPayload(payload, tmux: tmux)
    }
}

// MARK: - 10. native/src/video.zig (8 unmapped symbols)

public enum NativeZigVideo: Sendable {
    public static let audioSampleRate: UInt32 = 48_000
    public static let maxAVSyncOffsetUs: Int64 = 60_000_000
    private static let latencyWindowSize = 30
    private static let qualityOverloadLimit: UInt8 = 8
    private static let qualityCooldown: UInt8 = 30
    private static let qualityRecovery: UInt32 = 120
    private static let qualityRecoveryMax: UInt32 = 120 * 8

    // parity: native/src/video.zig#Info [status=implemented hash=c29fc9f4faab]
    public struct Info: Equatable, Hashable, Sendable {
        public var durationUs: Int64
        public var width: UInt32
        public var height: UInt32
        public var fpsNum: UInt32
        public var fpsDen: UInt32
        public var hasAudio: UInt32
        public var audioSampleRate: UInt32
        public var audioChannels: UInt32

        public init(
            durationUs: Int64 = 0,
            width: UInt32 = 0,
            height: UInt32 = 0,
            fpsNum: UInt32 = 30,
            fpsDen: UInt32 = 1,
            hasAudio: UInt32 = 0,
            audioSampleRate: UInt32 = 0,
            audioChannels: UInt32 = 0
        ) {
            self.durationUs = durationUs
            self.width = width
            self.height = height
            self.fpsNum = fpsNum
            self.fpsDen = max(1, fpsDen)
            self.hasAudio = hasAudio
            self.audioSampleRate = audioSampleRate
            self.audioChannels = audioChannels
        }
    }

    // parity: native/src/video.zig#State [status=implemented hash=f203b785be91]
    public struct State: Equatable, Hashable, Sendable {
        public var currentTimeUs: Int64
        public var framePtsUs: Int64
        public var frameSerial: UInt64
        public var hasFrame: UInt32
        public var ended: UInt32
        public var playing: UInt32
        public var buffering: UInt32
        public var audioActive: UInt32
        public var audioEnded: UInt32
        public var audioFailed: UInt32
        public var audioQueuedFrames: UInt32
        public var audioConsumedFrames: UInt64
        public var audioProducedFrames: UInt64
        public var audioUnderruns: UInt64
        public var preparedPtsUs: Int64

        public init(
            currentTimeUs: Int64 = 0,
            framePtsUs: Int64 = -1,
            frameSerial: UInt64 = 0,
            hasFrame: UInt32 = 0,
            ended: UInt32 = 0,
            playing: UInt32 = 0,
            buffering: UInt32 = 0,
            audioActive: UInt32 = 0,
            audioEnded: UInt32 = 0,
            audioFailed: UInt32 = 0,
            audioQueuedFrames: UInt32 = 0,
            audioConsumedFrames: UInt64 = 0,
            audioProducedFrames: UInt64 = 0,
            audioUnderruns: UInt64 = 0,
            preparedPtsUs: Int64 = -1
        ) {
            self.currentTimeUs = currentTimeUs
            self.framePtsUs = framePtsUs
            self.frameSerial = frameSerial
            self.hasFrame = hasFrame
            self.ended = ended
            self.playing = playing
            self.buffering = buffering
            self.audioActive = audioActive
            self.audioEnded = audioEnded
            self.audioFailed = audioFailed
            self.audioQueuedFrames = audioQueuedFrames
            self.audioConsumedFrames = audioConsumedFrames
            self.audioProducedFrames = audioProducedFrames
            self.audioUnderruns = audioUnderruns
            self.preparedPtsUs = preparedPtsUs
        }
    }

    // parity: native/src/video.zig#LatencyWindow [status=implemented hash=8face6d7df56]
    public struct LatencyWindow: Equatable, Hashable, Sendable {
        public private(set) var samples: [UInt32]
        public private(set) var count: UInt8
        public private(set) var cursor: UInt8

        public init() {
            self.samples = Array(repeating: 0, count: NativeZigVideo.latencyWindowSize)
            self.count = 0
            self.cursor = 0
        }

        public mutating func add(_ sample: UInt32) {
            samples[Int(cursor)] = sample
            cursor = UInt8((Int(cursor) + 1) % NativeZigVideo.latencyWindowSize)
            if Int(count) < NativeZigVideo.latencyWindowSize {
                count += 1
            }
        }

        public func maximum() -> UInt32 {
            var result: UInt32 = 0
            for i in 0..<Int(count) {
                result = max(result, samples[i])
            }
            return result
        }

        public mutating func reset() {
            self = LatencyWindow()
        }
    }

    // parity: native/src/video.zig#quality_scales [status=implemented hash=8d19b25c0db8]
    public static let qualityScales: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25]

    // parity: native/src/video.zig#Quality [status=implemented hash=e26583cd551a]
    public struct Quality: Equatable, Hashable, Sendable {
        public var tier: UInt8
        public var overload: UInt8
        public var headroom: UInt32
        public var cooldown: UInt8
        public var recovery: UInt32
        public var sinceUpgrade: UInt32?

        public init(
            tier: UInt8 = 0,
            overload: UInt8 = 0,
            headroom: UInt32 = 0,
            cooldown: UInt8 = 0,
            recovery: UInt32 = 120,
            sinceUpgrade: UInt32? = nil
        ) {
            self.tier = tier
            self.overload = overload
            self.headroom = headroom
            self.cooldown = cooldown
            self.recovery = recovery
            self.sinceUpgrade = sinceUpgrade
        }

        public func scale() -> Double {
            let idx = min(Int(tier), NativeZigVideo.qualityScales.count - 1)
            return NativeZigVideo.qualityScales[idx]
        }

        private mutating func settle() {
            overload = 0
            headroom = 0
            cooldown = NativeZigVideo.qualityCooldown
        }

        public mutating func sample(costUs: UInt32, intervalUs: UInt32) {
            let intervals = UInt8(min(costUs / max(intervalUs, 1), UInt32(NativeZigVideo.qualityOverloadLimit)))
            let step = max(intervals, 1)
            if costUs > intervalUs {
                overload = overload > UInt8.max - step ? UInt8.max : overload + step
            } else {
                overload = overload > 2 ? overload - 2 : 0
            }
            if costUs < intervalUs / 2 {
                headroom = headroom == UInt32.max ? UInt32.max : headroom + 1
            } else {
                headroom = headroom > 4 ? headroom - 4 : 0
            }
            if let samples = sinceUpgrade {
                let next = samples &+ 1
                if next >= recovery {
                    sinceUpgrade = nil
                    recovery = NativeZigVideo.qualityRecovery
                } else {
                    sinceUpgrade = next
                }
            }
            if cooldown > 0 {
                cooldown = cooldown > step ? cooldown - step : 0
                overload = 0
                return
            }
            if overload >= NativeZigVideo.qualityOverloadLimit && Int(tier) + 1 < NativeZigVideo.qualityScales.count {
                tier += 1
                if sinceUpgrade != nil {
                    recovery = min(recovery * 2, NativeZigVideo.qualityRecoveryMax)
                }
                sinceUpgrade = nil
                settle()
            } else if headroom >= recovery && tier > 0 {
                tier -= 1
                sinceUpgrade = 0
                settle()
            }
        }
    }

    // parity: native/src/video.zig#Video [status=implemented hash=ce81ebfd076c]
    public final class Video: @unchecked Sendable {
        public let path: String
        public var info: Info
        public private(set) var state: State = State()
        public var quality: Quality = Quality()
        public var latencyWindow: LatencyWindow = LatencyWindow()
        public private(set) var currentImage: NativeZigImage.Image?
        public private(set) var decodedFrameCount: UInt64 = 0
        public private(set) var lastErrorMessage: String = ""
        public private(set) var muted: Bool = false
        public private(set) var volume: Float = 1.0
        public private(set) var avSyncOffsetUs: Int64 = 0
        public private(set) var outputWidth: UInt32 = 0
        public private(set) var outputHeight: UInt32 = 0
        public private(set) var outputCover: Bool = false
        public private(set) var outputCrop: NativeZigImage.Region?
        private var frames: [(ptsUs: Int64, image: NativeZigImage.Image)] = []

        public init(path: String, info: Info = Info()) {
            self.path = path
            self.info = info
        }

        public func loadFrames(_ frames: [(ptsUs: Int64, image: NativeZigImage.Image)]) {
            self.frames = frames.sorted { $0.ptsUs < $1.ptsUs }
            if let first = self.frames.first {
                currentImage = first.image
                state.hasFrame = 1
                state.framePtsUs = first.ptsUs
                state.frameSerial &+= 1
            }
            if let last = self.frames.last, info.durationUs < last.ptsUs {
                info.durationUs = last.ptsUs
            }
        }

        @discardableResult
        public func configureOutput(width: UInt32, height: UInt32, cover: Bool = false, crop: NativeZigImage.Region? = nil) -> Bool {
            let changed = outputWidth != width || outputHeight != height || outputCover != cover || outputCrop != crop
            outputWidth = width
            outputHeight = height
            outputCover = cover
            outputCrop = crop
            return changed
        }

        public func play() {
            state.playing = 1
            state.ended = 0
        }

        public func pause() {
            state.playing = 0
        }

        public func setMuted(_ muted: Bool) { self.muted = muted }
        public func setVolume(_ volume: Float) { self.volume = max(0, volume) }

        public func setAvSyncOffset(_ offsetUs: Int64) {
            avSyncOffsetUs = min(NativeZigVideo.maxAVSyncOffsetUs, max(-NativeZigVideo.maxAVSyncOffsetUs, offsetUs))
        }

        public func seek(targetUs: Int64) {
            let clamped = max(0, info.durationUs > 0 ? min(targetUs, info.durationUs) : targetUs)
            state.currentTimeUs = clamped
            state.ended = 0
            _ = update(targetUs: clamped)
        }

        @discardableResult
        public func update(targetUs: Int64) -> Bool {
            state.currentTimeUs = targetUs
            guard !frames.isEmpty else {
                if info.durationUs > 0 && targetUs >= info.durationUs {
                    state.ended = 1
                }
                return false
            }
            var chosen = frames[0]
            for frame in frames {
                if frame.ptsUs <= targetUs {
                    chosen = frame
                } else {
                    break
                }
            }
            let changed = state.framePtsUs != chosen.ptsUs || currentImage == nil
            currentImage = chosen.image
            state.hasFrame = 1
            state.framePtsUs = chosen.ptsUs
            if changed {
                state.frameSerial &+= 1
                decodedFrameCount &+= 1
            }
            if info.durationUs > 0 && targetUs >= info.durationUs {
                state.ended = 1
            }
            return changed
        }

        public func observeOutput(frame: UInt64, costUs: UInt32, intervalUs: UInt32 = 33_333) {
            _ = frame
            latencyWindow.add(costUs)
            quality.sample(costUs: costUs, intervalUs: intervalUs)
        }

        public func failAudio(_ message: String) {
            state.audioFailed = 1
            state.audioActive = 0
            lastErrorMessage = message
        }

        public func getState() -> State { state }
    }

    // parity: native/src/video.zig#PlayerState [status=implemented hash=fbd0e33d3f2c]
    public struct PlayerState: Equatable, Hashable, Sendable {
        public var currentTimeUs: Int64
        public var framePtsUs: Int64
        public var playing: Bool
        public var ended: Bool
        public var buffering: Bool
        public var audio: Bool
        public var hasFrame: Bool
        public var failed: Bool
        public var qualityTier: UInt32

        public init(
            currentTimeUs: Int64 = 0,
            framePtsUs: Int64 = -1,
            playing: Bool = false,
            ended: Bool = false,
            buffering: Bool = false,
            audio: Bool = false,
            hasFrame: Bool = false,
            failed: Bool = false,
            qualityTier: UInt32 = 0
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

    // parity: native/src/video.zig#Player [status=implemented hash=c6910e281ba9]
    public final class Player: @unchecked Sendable {
        public let video: Video
        public private(set) var playing: Bool = false
        public var loop: Bool = false
        public private(set) var ended: Bool = false
        public private(set) var failed: Bool = false
        public private(set) var positionUs: Int64 = 0
        public private(set) var maxFps: UInt32 = 30

        public init(video: Video) {
            self.video = video
        }

        public func currentTime() -> Int64 { positionUs }

        public func play() {
            playing = true
            ended = false
            video.play()
        }

        public func pause() {
            playing = false
            video.pause()
        }

        public func seek(timeUs: Int64) {
            positionUs = max(0, timeUs)
            ended = false
            video.seek(targetUs: positionUs)
        }

        public func advance(byUs deltaUs: Int64) {
            guard playing && !failed else { return }
            positionUs &+= max(0, deltaUs)
            if video.info.durationUs > 0 && positionUs >= video.info.durationUs {
                if loop {
                    positionUs %= max(1, video.info.durationUs)
                } else {
                    positionUs = video.info.durationUs
                    ended = true
                    playing = false
                    video.pause()
                }
            }
            _ = video.update(targetUs: positionUs)
        }

        public func setLoop(_ loop: Bool) { self.loop = loop }
        public func setMuted(_ muted: Bool) { video.setMuted(muted) }
        public func setVolume(_ volume: Float) { video.setVolume(volume) }
        public func setAvSyncOffset(_ offsetUs: Int64) { video.setAvSyncOffset(offsetUs) }
        public func setMaxFps(_ fps: UInt32) { maxFps = max(1, fps) }
        public func fail() { failed = true; playing = false }

        public func observeFrameCost(completedFrames: UInt64, costUs: UInt32) {
            let intervalUs = UInt32(1_000_000 / max(1, maxFps))
            video.observeOutput(frame: completedFrames, costUs: costUs, intervalUs: intervalUs)
        }

        public func frame(width: UInt32, height: UInt32, cover: Bool = false, crop: NativeZigImage.Region? = nil) -> NativeZigImage.Image? {
            _ = video.configureOutput(width: width, height: height, cover: cover, crop: crop)
            return video.currentImage
        }

        public func snapshot() -> PlayerState {
            let s = video.getState()
            return PlayerState(
                currentTimeUs: positionUs,
                framePtsUs: s.framePtsUs,
                playing: playing,
                ended: ended || s.ended != 0,
                buffering: s.buffering != 0,
                audio: s.audioActive != 0,
                hasFrame: s.hasFrame != 0,
                failed: failed,
                qualityTier: UInt32(video.quality.tier)
            )
        }
    }
}

// MARK: - 11. native/src/native-span-feed.zig (27 unmapped symbols)

public enum NativeZigSpanFeed: Sendable {
    public static let spanQueueCapacityDefault: UInt32 = 4096

    // parity: native/src/native-span-feed.zig#CallbackFn [status=implemented hash=5013463fe2f0]
    public typealias CallbackFn = @Sendable (_ streamId: UInt64, _ eventId: UInt32, _ arg0: Int, _ arg1: UInt64) -> Void

    // parity: native/src/native-span-feed.zig#GrowthPolicy [status=implemented hash=a5ef69835018]
    public enum GrowthPolicy: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case grow = 0
        case block = 1

        public var coreValue: OpenTUICore.GrowthPolicy {
            self == .grow ? .grow : .block
        }
    }

    // parity: native/src/native-span-feed.zig#Options [status=implemented hash=9bf306876b76]
    public struct Options: Equatable, Hashable, Sendable {
        public var chunkSize: UInt32
        public var initialChunks: UInt32
        public var maxBytes: UInt64
        public var growthPolicy: UInt8
        public var autoCommitOnFull: UInt8
        public var spanQueueCapacity: UInt32

        public init(
            chunkSize: UInt32 = 64 * 1024,
            initialChunks: UInt32 = 2,
            maxBytes: UInt64 = 0,
            growthPolicy: UInt8 = GrowthPolicy.grow.rawValue,
            autoCommitOnFull: UInt8 = 1,
            spanQueueCapacity: UInt32 = 0
        ) {
            self.chunkSize = chunkSize
            self.initialChunks = initialChunks
            self.maxBytes = maxBytes
            self.growthPolicy = growthPolicy
            self.autoCommitOnFull = autoCommitOnFull
            self.spanQueueCapacity = spanQueueCapacity
        }

        public func toCore() -> NativeSpanFeedOptions {
            let norm = NativeZigSpanFeed.normalizeOptions(self)
            return NativeSpanFeedOptions(
                chunkSize: Int(norm.chunkSize),
                initialChunks: Int(norm.initialChunks),
                maxBytes: norm.maxBytes,
                growthPolicy: norm.growthPolicy == GrowthPolicy.block.rawValue ? .block : .grow,
                autoCommitOnFull: norm.autoCommitOnFull != 0,
                spanQueueCapacity: Int(norm.spanQueueCapacity)
            )
        }
    }

    // parity: native/src/native-span-feed.zig#Stats [status=implemented hash=9cae5b6f87a6]
    public struct Stats: Equatable, Hashable, Sendable {
        public var bytesWritten: UInt64
        public var spansCommitted: UInt64
        public var chunks: UInt32
        public var pendingSpans: UInt32
        public var outstandingSpans: UInt32
        public var reserved: UInt32
        public var outstandingBytes: UInt64

        public init(
            bytesWritten: UInt64 = 0,
            spansCommitted: UInt64 = 0,
            chunks: UInt32 = 0,
            pendingSpans: UInt32 = 0,
            outstandingSpans: UInt32 = 0,
            reserved: UInt32 = 0,
            outstandingBytes: UInt64 = 0
        ) {
            self.bytesWritten = bytesWritten
            self.spansCommitted = spansCommitted
            self.chunks = chunks
            self.pendingSpans = pendingSpans
            self.outstandingSpans = outstandingSpans
            self.reserved = reserved
            self.outstandingBytes = outstandingBytes
        }

        public init(core: NativeSpanFeedStats) {
            self.bytesWritten = core.bytesWritten
            self.spansCommitted = core.spansCommitted
            self.chunks = UInt32(max(0, core.chunks))
            self.pendingSpans = UInt32(max(0, core.pendingSpans))
            self.outstandingSpans = UInt32(max(0, core.outstandingSpans))
            self.reserved = 0
            self.outstandingBytes = core.outstandingBytes
        }
    }

    // parity: native/src/native-span-feed.zig#SpanInfo [status=implemented hash=aa592d381fc4]
    public struct SpanInfo: Equatable, Hashable, Sendable {
        public var chunkIndex: UInt32
        public var offset: UInt32
        public var len: UInt32
        public var slotIndex: UInt32
        public var releaseId: UInt64

        public init(
            chunkIndex: UInt32 = 0,
            offset: UInt32 = 0,
            len: UInt32 = 0,
            slotIndex: UInt32 = 0,
            releaseId: UInt64 = 0
        ) {
            self.chunkIndex = chunkIndex
            self.offset = offset
            self.len = len
            self.slotIndex = slotIndex
            self.releaseId = releaseId
        }

        public init(core: OpenTUICore.SpanInfo) {
            self.chunkIndex = UInt32(max(0, core.chunkIndex))
            self.offset = UInt32(max(0, core.offset))
            self.len = UInt32(max(0, core.len))
            self.slotIndex = UInt32(max(0, core.slotIndex))
            self.releaseId = core.releaseId
        }

        public func toCore() -> OpenTUICore.SpanInfo {
            OpenTUICore.SpanInfo(
                chunkIndex: Int(chunkIndex),
                offset: Int(offset),
                len: Int(len),
                slotIndex: Int(slotIndex),
                releaseId: releaseId
            )
        }
    }

    // parity: native/src/native-span-feed.zig#ReserveInfo [status=implemented hash=3de743aa45a3]
    public struct ReserveInfo: Equatable, Hashable, Sendable {
        public var chunkIndex: UInt32
        public var offset: UInt32
        public var len: UInt32
        public var reserved: UInt32

        public init(chunkIndex: UInt32 = 0, offset: UInt32 = 0, len: UInt32 = 0, reserved: UInt32 = 0) {
            self.chunkIndex = chunkIndex
            self.offset = offset
            self.len = len
            self.reserved = reserved
        }
    }

    // parity: native/src/native-span-feed.zig#ControlSequenceReservation [status=implemented hash=3ebcf5365653]
    public struct ControlSequenceReservation: Equatable, Hashable, Sendable {
        public var bytes: UInt64
        public var spans: UInt64

        public init(bytes: UInt64 = 0, spans: UInt64 = 0) {
            self.bytes = bytes
            self.spans = spans
        }
    }

    // parity: native/src/native-span-feed.zig#default_pattern [status=implemented hash=a64afa865c3a]
    public static let defaultPattern: String = "\u{1B}[32mnative-span-feed\u{1B}[0m\n"

    // parity: native/src/native-span-feed.zig#EventId [status=implemented hash=edddc1ad7c50]
    public enum EventId: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case chunkAdded = 2
        case closed = 5
        case error = 6
        case dataAvailable = 7
    }

    // parity: native/src/native-span-feed.zig#Status [status=implemented hash=12909ce7eccf]
    public enum Status: Sendable {
        public static let ok: Int32 = 0
        public static let errNoSpace: Int32 = -1
        public static let errMaxBytes: Int32 = -2
        public static let errInvalid: Int32 = -3
        public static let errAlloc: Int32 = -4
        public static let errBusy: Int32 = -5
    }

    // parity: native/src/native-span-feed.zig#StreamError [status=implemented hash=2485f8221d64]
    public enum StreamError: Error, Equatable, Hashable, Sendable {
        case noSpace
        case maxBytes
        case invalid
        case outOfMemory
        case busy

        public var statusCode: Int32 {
            switch self {
            case .noSpace: return Status.errNoSpace
            case .maxBytes: return Status.errMaxBytes
            case .invalid: return Status.errInvalid
            case .outOfMemory: return Status.errAlloc
            case .busy: return Status.errBusy
            }
        }
    }

    // parity: native/src/native-span-feed.zig#Stream [status=implemented hash=3b51e8da7943]
    public final class Stream: @unchecked Sendable {
        public let core: NativeSpanFeed
        public fileprivate(set) var options: Options
        public fileprivate(set) var attached: Bool = false
        public var controlReservation: ControlSequenceReservation = ControlSequenceReservation()
        fileprivate var callback: CallbackFn?
        fileprivate var pendingBytes: [UInt8] = []
        fileprivate var activeReservation: SpanReservation?
        fileprivate var reservedBuffer: [UInt8] = []
        fileprivate let streamId: UInt64

        private static let nextId = Mutex<UInt64>(1)

        public init(options: Options = NativeZigSpanFeed.defaultOptions()) {
            let norm = NativeZigSpanFeed.normalizeOptions(options)
            self.options = norm
            self.core = NativeSpanFeed.create(norm.toCore())
            self.streamId = Stream.nextId.withLock { id in
                let cur = id
                id &+= 1
                return cur
            }
        }

        public func readSpan(_ span: SpanInfo) -> [UInt8]? {
            core.readSpan(span.toCore())
        }

        fileprivate func notify(_ event: EventId, arg0: Int = 0, arg1: UInt64 = 0) {
            callback?(streamId, event.rawValue, arg0, arg1)
        }
    }

    // parity: native/src/native-span-feed.zig#defaultOptions [status=implemented hash=efa38698b4f1]
    public static func defaultOptions() -> Options {
        Options(
            chunkSize: 64 * 1024,
            initialChunks: 2,
            maxBytes: 0,
            growthPolicy: GrowthPolicy.grow.rawValue,
            autoCommitOnFull: 1,
            spanQueueCapacity: 0
        )
    }

    // parity: native/src/native-span-feed.zig#normalizeOptions [status=implemented hash=6bbddf7be5fa]
    public static func normalizeOptions(_ opts: Options) -> Options {
        var out = opts
        if out.chunkSize == 0 { out.chunkSize = 64 * 1024 }
        if out.initialChunks == 0 { out.initialChunks = 1 }
        if out.spanQueueCapacity == 0 { out.spanQueueCapacity = spanQueueCapacityDefault }
        return out
    }

    // parity: native/src/native-span-feed.zig#createNativeSpanFeedWithAllocator [status=implemented hash=6293d06ff897]
    public static func createNativeSpanFeedWithAllocator(options: Options? = nil) -> Stream {
        Stream(options: normalizeOptions(options ?? defaultOptions()))
    }

    // parity: native/src/native-span-feed.zig#streamSetCallback [status=implemented hash=809af5f9bbe2]
    public static func streamSetCallback(_ stream: Stream?, callback: CallbackFn?) {
        stream?.callback = callback
    }

    // parity: native/src/native-span-feed.zig#attachNativeSpanFeed [status=implemented hash=662f599cc5c2]
    public static func attachNativeSpanFeed(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        stream.attached = true
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamClose [status=implemented hash=bd271193fd84]
    public static func streamClose(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        if !stream.pendingBytes.isEmpty {
            _ = streamCommit(stream)
        }
        stream.core.close()
        stream.notify(.closed)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#destroyNativeSpanFeed [status=implemented hash=7b531d97c4a4]
    public static func destroyNativeSpanFeed(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        if !stream.core.isClosed {
            stream.core.close()
        }
        stream.pendingBytes.removeAll()
        stream.activeReservation = nil
        stream.reservedBuffer.removeAll()
        stream.callback = nil
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamReleaseSpan [status=implemented hash=a663a11d10f9]
    public static func streamReleaseSpan(_ stream: Stream?, slotIndex: UInt32, releaseId: UInt64) -> Int32 {
        guard let stream else { return Status.errInvalid }
        stream.core.releaseSpan(slotIndex: Int(slotIndex), releaseId: releaseId)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamWrite [status=implemented hash=3912a04e2807]
    public static func streamWrite(_ stream: Stream?, bytes: [UInt8]) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        if bytes.isEmpty { return Status.ok }
        stream.pendingBytes.append(contentsOf: bytes)
        if stream.options.autoCommitOnFull != 0 && stream.pendingBytes.count >= Int(stream.options.chunkSize) {
            return streamCommit(stream)
        }
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamCommit [status=implemented hash=3de1d4ff83e0]
    public static func streamCommit(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        guard !stream.pendingBytes.isEmpty else { return Status.ok }
        let payload = stream.pendingBytes
        stream.pendingBytes.removeAll(keepingCapacity: true)
        do {
            let span = try stream.core.commit(payload)
            stream.notify(.dataAvailable, arg0: span.len, arg1: span.releaseId)
            return Status.ok
        } catch let err {
            return mapSpanFeedError(err)
        }
    }

    // parity: native/src/native-span-feed.zig#streamReserve [status=implemented hash=f437052fa375]
    public static func streamReserve(_ stream: Stream?, minLen: UInt32) -> (status: Int32, info: ReserveInfo?) {
        guard let stream else { return (Status.errInvalid, nil) }
        guard !stream.core.isClosed else { return (Status.errInvalid, nil) }
        guard stream.activeReservation == nil else { return (Status.errBusy, nil) }
        do {
            let reservation = try stream.core.reserve(Int(minLen))
            stream.activeReservation = reservation
            stream.reservedBuffer = Array(repeating: 0, count: Int(minLen))
            return (
                Status.ok,
                ReserveInfo(
                    chunkIndex: UInt32(max(0, reservation.chunkIndex)),
                    offset: UInt32(max(0, reservation.offset)),
                    len: UInt32(max(0, reservation.capacity)),
                    reserved: minLen
                )
            )
        } catch let err {
            return (mapSpanFeedError(err), nil)
        }
    }

    // parity: native/src/native-span-feed.zig#streamCommitReserved [status=implemented hash=08ddca041a4a]
    public static func streamCommitReserved(_ stream: Stream?, bytes: [UInt8]) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard let reservation = stream.activeReservation else { return Status.errInvalid }
        stream.activeReservation = nil
        stream.reservedBuffer.removeAll(keepingCapacity: false)
        do {
            let span = try stream.core.commit(reservation: reservation, bytes: bytes)
            stream.notify(.dataAvailable, arg0: span.len, arg1: span.releaseId)
            return Status.ok
        } catch let err {
            return mapSpanFeedError(err)
        }
    }

    // parity: native/src/native-span-feed.zig#streamSetOptions [status=implemented hash=85d7d2f18d79]
    public static func streamSetOptions(_ stream: Stream?, options: Options) -> Int32 {
        guard let stream else { return Status.errInvalid }
        stream.options = normalizeOptions(options)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamGetStats [status=implemented hash=c12af3c63f91]
    public static func streamGetStats(_ stream: Stream?) -> (status: Int32, stats: Stats?) {
        guard let stream else { return (Status.errInvalid, nil) }
        return (Status.ok, Stats(core: stream.core.stats))
    }

    // parity: native/src/native-span-feed.zig#streamDrainSpans [status=implemented hash=5662680842a6]
    public static func streamDrainSpans(_ stream: Stream?, maxSpans: UInt32) -> [SpanInfo] {
        guard let stream, maxSpans > 0 else { return [] }
        return stream.core.drain(maxSpans: Int(maxSpans)).map(SpanInfo.init(core:))
    }

    private static func mapSpanFeedError(_ error: NativeSpanFeedError) -> Int32 {
        switch error {
        case .backpressured, .spanQueueFull: return Status.errNoSpace
        case .outOfSpace: return Status.errMaxBytes
        case .closed, .invalidLength, .reservationMismatch: return Status.errInvalid
        }
    }
}
