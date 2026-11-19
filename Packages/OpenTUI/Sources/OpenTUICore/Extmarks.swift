/// A tracked range mark inside an `EditBuffer`, measured in document display-cell offsets
/// (counting one cell per newline, NOT UTF-16 string indices).
// parity: core/src/lib/extmarks.ts#Extmark [status=implemented hash=dba6d0654ed5]
public struct Extmark: Sendable {
    public var id: Int
    /// Inclusive document display-cell offset (counting one cell per newline).
    public var start: Int
    /// Exclusive document display-cell offset (counting one cell per newline).
    public var end: Int
    /// Whether the mark acts as an atomic virtual unit for cursor motion and editing.
    public var virtual: Bool
    public var styleId: Int?
    public var priority: Int?
    public var data: (any Sendable)?
    public var typeId: Int

    public init(
        id: Int,
        start: Int,
        end: Int,
        virtual: Bool,
        styleId: Int? = nil,
        priority: Int? = nil,
        data: (any Sendable)? = nil,
        typeId: Int = 0
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.virtual = virtual
        self.styleId = styleId
        self.priority = priority
        self.data = data
        self.typeId = typeId
    }
}

/// Options for creating a new `Extmark` via `ExtmarksController.create(_:)`.
// parity: core/src/lib/extmarks.ts#ExtmarkOptions [status=implemented hash=7a7d541fedf4]
public struct ExtmarkOptions: Sendable {
    /// Inclusive document display-cell offset (counting one cell per newline).
    public var start: Int
    /// Exclusive document display-cell offset (counting one cell per newline).
    public var end: Int
    public var virtual: Bool
    public var styleId: Int
    public var priority: Int
    public var data: (any Sendable)?
    public var typeId: Int
    public var metadata: (any Sendable)?

    public init(
        start: Int,
        end: Int,
        virtual: Bool = false,
        styleId: Int = 0,
        priority: Int = 0,
        data: (any Sendable)? = nil,
        typeId: Int = 0,
        metadata: (any Sendable)? = nil
    ) {
        self.start = start
        self.end = end
        self.virtual = virtual
        self.styleId = styleId
        self.priority = priority
        self.data = data
        self.typeId = typeId
        self.metadata = metadata
    }
}

/// Shared per-`EditBuffer` extmark payload and type-registry state.
/// Attached directly to `EditBuffer` so all controllers sharing a buffer share payloads and type names,
/// and they outlive individual controllers while clearing payloads on history reset / destroy.
internal final class ExtmarksBufferState {
    struct Payload: Sendable {
        var data: (any Sendable)?
        var metadata: (any Sendable)?
    }

    var payloads: [Int: Payload] = [:]
    var typeNameToId: [String: Int] = [:]
    var typeIdToName: [Int: String] = [:]
    var nextTypeId: Int = 1
    var controllers: [ExtmarksController] = []
}

private func isU32Int(_ value: Int) -> Bool {
    value >= 0 && value <= Int(UInt32.max)
}

/// Manages normal and virtual (atomic) extmarks on an `EditBuffer` + `EditorView` pair.
///
/// Extmarks live inside the backing `EditBuffer`, shift automatically with edits, and restore
/// on undo/redo. Mark IDs are monotonically increasing and never reused.
// parity: core/src/lib/extmarks.ts#ExtmarksController [status=implemented hash=a53696bda180]
public final class ExtmarksController {
    private let editBuffer: EditBuffer
    private let editorView: EditorView
    private let state: ExtmarksBufferState
    private var destroyed: Bool = false
    private let atomicCheck: () -> Bool

    public init(editBuffer: EditBuffer, editorView: EditorView) {
        self.editBuffer = editBuffer
        self.editorView = editorView

        let bufferState: ExtmarksBufferState
        if let existing = editBuffer._extmarksState {
            bufferState = existing
        } else {
            let fresh = ExtmarksBufferState()
            editBuffer._extmarksState = fresh
            editBuffer._onHistoryReset = { [weak fresh] in
                fresh?.payloads.removeAll()
            }
            bufferState = fresh
        }
        self.state = bufferState
        self.atomicCheck = { [weak editorView] in
            guard let editorView, !editorView.isDestroyed else { return false }
            return !editorView.hasSelection()
        }

        bufferState.controllers.append(self)
        editBuffer._atomic = self.atomicCheck
        editorView._atomic = true
    }

    private var isGone: Bool {
        destroyed || editBuffer.isDestroyed
    }

    private func assertAlive() {
        precondition(!destroyed, "ExtmarksController is destroyed")
    }

    private func toExtmark(_ mark: NativeEditMark) -> Extmark {
        let id = Int(mark.id)
        return Extmark(
            id: id,
            start: mark.start,
            end: mark.end,
            virtual: mark.atomic,
            styleId: mark.style == 0 ? nil : Int(mark.style),
            priority: Int(mark.priority),
            data: state.payloads[id]?.data,
            typeId: Int(mark.kind)
        )
    }

    /// Marks a half-open document display-cell range `[start, end)` (counting 1 cell per newline).
    /// Returns the new mark ID, or `0` if the range or options are invalid.
    // parity: core/src/lib/extmarks.ts#ExtmarksController.create [status=implemented hash=aa98d20587b4]
    @discardableResult
    public func create(_ options: ExtmarkOptions) -> Int {
        assertAlive()
        let startOffset = options.start >= 0 ? min(options.start, Int(UInt32.max)) : -1
        let endOffset = options.end >= 0 ? min(options.end, Int(UInt32.max)) : -1
        guard startOffset >= 0,
              endOffset >= startOffset,
              isU32Int(options.typeId),
              isU32Int(options.styleId),
              isU32Int(options.priority)
        else {
            return 0
        }

        let id = editBuffer._addMark(
            kind: UInt32(options.typeId),
            atomic: options.virtual,
            style: UInt32(options.styleId),
            priority: UInt32(options.priority),
            start: startOffset,
            end: endOffset
        )
        let intId = Int(id)
        if intId != 0 && (options.data != nil || options.metadata != nil) {
            state.payloads[intId] = ExtmarksBufferState.Payload(
                data: options.data,
                metadata: options.metadata
            )
        }
        return intId
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.delete [status=implemented hash=059bbdeb0c44]
    @discardableResult
    public func delete(_ id: Int) -> Bool {
        assertAlive()
        guard isU32Int(id), id != 0 else { return false }
        return editBuffer._removeMark(id: UInt32(id))
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.get [status=implemented hash=5625eb97fec1]
    public func get(_ id: Int) -> Extmark? {
        guard !isGone, isU32Int(id), id != 0 else { return nil }
        guard let mark = editBuffer._getMarks(id: UInt32(id)).first else {
            return nil
        }
        return toExtmark(mark)
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getAll [status=implemented hash=2063b9e127d0]
    public func getAll() -> [Extmark] {
        guard !isGone else { return [] }
        return editBuffer._getMarks().map { toExtmark($0) }
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getVirtual [status=implemented hash=671a6319db23]
    public func getVirtual() -> [Extmark] {
        getAll().filter(\.virtual)
    }

    /// Returns all extmarks covering document display-cell offset `offset` (`start <= offset < end`).
    // parity: core/src/lib/extmarks.ts#ExtmarksController.getAtOffset [status=implemented hash=d1b1644c8779]
    public func getAtOffset(_ offset: Int) -> [Extmark] {
        getAll().filter { offset >= $0.start && offset < $0.end }
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getAllForTypeId [status=implemented hash=0350e992be2f]
    public func getAllForTypeId(_ typeId: Int) -> [Extmark] {
        guard !isGone, isU32Int(typeId) else { return [] }
        let u32TypeId = UInt32(typeId)
        return editBuffer._getMarks(id: nil, kind: u32TypeId)
            .filter { $0.kind == u32TypeId }
            .map { toExtmark($0) }
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.clear [status=implemented hash=12949e6b4cdd]
    public func clear() {
        guard !isGone else { return }
        editBuffer._clearMarks()
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.registerType [status=implemented hash=e857087d6e87]
    public func registerType(_ typeName: String) -> Int {
        assertAlive()
        if let existing = state.typeNameToId[typeName] {
            return existing
        }
        let typeId = state.nextTypeId
        state.nextTypeId += 1
        state.typeNameToId[typeName] = typeId
        state.typeIdToName[typeId] = typeName
        return typeId
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getTypeId [status=implemented hash=4be499ceeeb5]
    public func getTypeId(_ typeName: String) -> Int? {
        guard !destroyed else { return nil }
        return state.typeNameToId[typeName]
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getTypeName [status=implemented hash=47269a27f90e]
    public func getTypeName(_ typeId: Int) -> String? {
        guard !destroyed else { return nil }
        return state.typeIdToName[typeId]
    }

    // parity: core/src/lib/extmarks.ts#ExtmarksController.getMetadataFor [status=implemented hash=fa30b66003bc]
    public func getMetadataFor(_ extmarkId: Int) -> (any Sendable)? {
        guard get(extmarkId) != nil else { return nil }
        return state.payloads[extmarkId]?.metadata
    }

    /// Stops atomic cursor rules for this controller's view. Marks, payloads, and type names remain on the buffer.
    // parity: core/src/lib/extmarks.ts#ExtmarksController.destroy [status=implemented hash=5e3f5e9050d3]
    public func destroy() {
        guard !destroyed else { return }
        state.controllers.removeAll { $0 === self }
        editorView._atomic = state.controllers.contains { $0.editorView === self.editorView }
        editBuffer._atomic = state.controllers.last?.atomicCheck
        destroyed = true
    }
}

/// Creates a new `ExtmarksController` bound to `editBuffer` and `editorView`.
// parity: core/src/lib/extmarks.ts#createExtmarksController [status=implemented hash=37369ebb4427]
public func createExtmarksController(_ editBuffer: EditBuffer, _ editorView: EditorView) -> ExtmarksController {
    ExtmarksController(editBuffer: editBuffer, editorView: editorView)
}
