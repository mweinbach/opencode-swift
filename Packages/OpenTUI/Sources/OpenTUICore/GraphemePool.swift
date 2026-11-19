/// Pure-Swift reference-counted grapheme cluster pool and 32-bit cell char encoding
/// matching `packages/native/src/grapheme.zig` and `packages/native/include/opentui.h`.

// MARK: - Cell Character Encoding Flags (`opentui.h` OT_CELL_CHAR_*)

/// Bits 31-30 encoding type mask:
/// - `00`: direct Unicode scalar value (30 bits)
/// - `01`: image cell with reservation ID and fallback quadrant
/// - `10`: grapheme start cell with extent (bits 29..26) and 26-bit pool ID
/// - `11`: continuation cell with left extent (bits 29..26) and 26-bit pool ID
public let cellCharTypeMask: UInt32 = 0xC000_0000
public let cellCharFlagImage: UInt32 = 0x4000_0000
public let cellCharFlagGrapheme: UInt32 = 0x8000_0000
public let cellCharFlagContinuation: UInt32 = 0xC000_0000

public let cellImageIdMask: UInt32 = 0x03FF_FFFF
public let cellCharExtShift: UInt32 = 26
public let cellCharExtMask: UInt32 = 0xF
/// Maximum display cells one glyph can span (16).
public let glyphWidthMax: UInt32 = cellCharExtMask + 1

/// 26-bit grapheme pool ID payload: `[ class (3 bits) | generation (7 bits) | slot_index (16 bits) ]`.
public let graphemeIdMask: UInt32 = 0x03FF_FFFF
public let graphemeClassBits: UInt32 = 3
public let graphemeGenerationBits: UInt32 = 7
public let graphemeSlotBits: UInt32 = 16
public let graphemeClassMask: UInt32 = (1 << graphemeClassBits) - 1
public let graphemeGenerationMask: UInt32 = (1 << graphemeGenerationBits) - 1
public let graphemeSlotMask: UInt32 = (1 << graphemeSlotBits) - 1

/// Maximum UTF-8 bytes stored per grapheme cluster in `GraphemePool`.
// parity: native/src/buffer.zig#grapheme_bytes_max [status=implemented hash=cb3c964e883b]
public let graphemeBytesMax: Int = 128

// MARK: - Errors

// parity: native/src/grapheme.zig#GraphemePoolError [status=implemented hash=f9320e7c2062]
public enum GraphemePoolError: Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case graphemeTooLong
    case invalidId
    case wrongGeneration
    case refcountOverflow
}

// MARK: - Packed Cell Bit Manipulation

// parity: native/src/grapheme.zig#packImageCell [status=implemented hash=64b4784d884d]
@inline(__always)
public func packImageCell(id: UInt32, fallback: UInt8) -> UInt32 {
    precondition(id <= cellImageIdMask, "Image ID exceeds 26-bit mask")
    return cellCharFlagImage | (id << 4) | UInt32(fallback & 0xF)
}

// parity: native/src/grapheme.zig#isImageChar [status=implemented hash=5245e69120df]
@inline(__always)
public func isImageChar(_ char: UInt32) -> Bool {
    (char & cellCharTypeMask) == cellCharFlagImage
}

// parity: native/src/grapheme.zig#imageIdFromChar [status=implemented hash=7cd9f92e0f90]
@inline(__always)
public func imageIdFromChar(_ char: UInt32) -> UInt32 {
    precondition(isImageChar(char))
    return (char >> 4) & cellImageIdMask
}

// parity: native/src/grapheme.zig#imageFallbackFromChar [status=implemented hash=d960e465014d]
@inline(__always)
public func imageFallbackFromChar(_ char: UInt32) -> UInt8 {
    precondition(isImageChar(char))
    return UInt8(char & 0xF)
}

// parity: native/src/grapheme.zig#isGraphemeChar [status=implemented hash=3128be9f0715]
@inline(__always)
public func isGraphemeChar(_ c: UInt32) -> Bool {
    (c & cellCharTypeMask) == cellCharFlagGrapheme
}

// parity: native/src/grapheme.zig#isContinuationChar [status=implemented hash=434dbd7b0e44]
@inline(__always)
public func isContinuationChar(_ c: UInt32) -> Bool {
    (c & cellCharTypeMask) == cellCharFlagContinuation
}

// parity: native/src/grapheme.zig#isClusterChar [status=implemented hash=83a6c7090c21]
@inline(__always)
public func isClusterChar(_ c: UInt32) -> Bool {
    isGraphemeChar(c) || isContinuationChar(c)
}

// parity: native/src/grapheme.zig#graphemeIdFromChar [status=implemented hash=f1432dfa2f88]
@inline(__always)
public func graphemeIdFromChar(_ c: UInt32) -> UInt32 {
    precondition(isClusterChar(c))
    return c & graphemeIdMask
}

// parity: native/src/grapheme.zig#charRightExtent [status=implemented hash=65a14c2f1f84]
@inline(__always)
public func charRightExtent(_ c: UInt32) -> UInt32 {
    precondition(isGraphemeChar(c))
    return (c >> cellCharExtShift) & cellCharExtMask
}

/// Cells from a grapheme cell back to its start cell (0 for a start cell).
// parity: native/src/grapheme.zig#charLeftExtent [status=implemented hash=594b0789084e]
@inline(__always)
public func charLeftExtent(_ c: UInt32) -> UInt32 {
    precondition(isClusterChar(c))
    return isContinuationChar(c) ? ((c >> cellCharExtShift) & cellCharExtMask) : 0
}

// parity: native/src/grapheme.zig#packGraphemeStart [status=implemented hash=60a9c1de23a6]
@inline(__always)
public func packGraphemeStart(gid: UInt32, totalWidth: UInt32) -> UInt32 {
    precondition(gid <= graphemeIdMask, "Grapheme ID exceeds 26-bit payload")
    precondition(totalWidth > 0 && totalWidth <= glyphWidthMax, "Grapheme width out of range 1...16")
    return cellCharFlagGrapheme | ((totalWidth - 1) << cellCharExtShift) | gid
}

// parity: native/src/grapheme.zig#packContinuation [status=implemented hash=506352127ff5]
@inline(__always)
public func packContinuation(left: UInt32, gid: UInt32) -> UInt32 {
    precondition(gid <= graphemeIdMask, "Grapheme ID exceeds 26-bit payload")
    precondition(left > 0 && left <= cellCharExtMask, "Continuation left extent out of range 1...15")
    return cellCharFlagContinuation | (left << cellCharExtShift) | gid
}

/// Display cells occupied by the glyph starting in this cell (`0` for a continuation cell).
// parity: native/src/grapheme.zig#encodedCharWidth [status=implemented hash=b48dd663edfa]
@inline(__always)
public func encodedCharWidth(_ c: UInt32) -> UInt32 {
    if isContinuationChar(c) { return 0 }
    return isGraphemeChar(c) ? (charRightExtent(c) + 1) : 1
}

// MARK: - GraphemePool

/// Reference-counted, interned storage for multi-codepoint and wide grapheme clusters.
/// IDs are 26-bit payloads: `[ class (3 bits) | generation (7 bits) | slot_index (16 bits) ]`.
// parity: native/src/grapheme.zig#GraphemePool [status=implemented hash=c9cb0e2bf79c]
public final class GraphemePool: @unchecked Sendable {
    public typealias IdPayload = UInt32

    private static let classSizes: [Int] = [8, 16, 32, 64, 128]
    private static let maxClasses: UInt32 = 5

    private struct Slot {
        var bytes: [UInt8] = []
        var refcount: UInt32 = 0
        var generation: UInt32 = 0
        var isAllocated: Bool = false
    }

    private struct ClassPool {
        let slotCapacity: Int
        var slots: [Slot] = []
        var freeList: [UInt32] = []

        init(slotCapacity: Int) {
            self.slotCapacity = slotCapacity
        }

        mutating func allocSlot(_ bytes: [UInt8]) throws(GraphemePoolError) -> (slotIndex: UInt32, generation: UInt32) {
            if bytes.count > slotCapacity {
                throw .graphemeTooLong
            }

            let slotIndex: UInt32
            if let recycled = freeList.popLast() {
                slotIndex = recycled
            } else {
                guard slots.count <= Int(graphemeSlotMask) else {
                    throw .outOfMemory
                }
                slotIndex = UInt32(slots.count)
                slots.append(Slot())
            }

            let idx = Int(slotIndex)
            let newGeneration = (slots[idx].generation + 1) & graphemeGenerationMask
            slots[idx].bytes = bytes
            slots[idx].refcount = 1
            slots[idx].generation = newGeneration
            slots[idx].isAllocated = true
            return (slotIndex, newGeneration)
        }

        func validate(slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) -> Int {
            let idx = Int(slotIndex)
            guard idx < slots.count else { throw .invalidId }
            if slots[idx].generation != generation {
                throw .wrongGeneration
            }
            guard slots[idx].isAllocated else { throw .invalidId }
            return idx
        }

        mutating func incref(slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) {
            let idx = try validate(slotIndex: slotIndex, generation: generation)
            guard slots[idx].refcount > 0 else { throw .invalidId }
            guard slots[idx].refcount < UInt32.max else { throw .refcountOverflow }
            slots[idx].refcount += 1
        }

        mutating func decref(slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) -> [UInt8]? {
            let idx = try validate(slotIndex: slotIndex, generation: generation)
            guard slots[idx].refcount > 0 else { throw .invalidId }
            slots[idx].refcount -= 1
            if slots[idx].refcount == 0 {
                let freedBytes = slots[idx].bytes
                slots[idx].isAllocated = false
                slots[idx].bytes = []
                freeList.append(slotIndex)
                return freedBytes
            }
            return nil
        }

        func get(slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) -> [UInt8] {
            let idx = try validate(slotIndex: slotIndex, generation: generation)
            return slots[idx].bytes
        }

        func getRefcount(slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) -> UInt32 {
            let idx = try validate(slotIndex: slotIndex, generation: generation)
            return slots[idx].refcount
        }
    }

    private var classes: [ClassPool]
    private var internedLiveIds: [[UInt8]: IdPayload] = [:]

    public init() {
        self.classes = Self.classSizes.map { ClassPool(slotCapacity: $0) }
    }

    @inline(__always)
    private static func classForSize(_ size: Int) -> UInt32 {
        if size <= 8 { return 0 }
        if size <= 16 { return 1 }
        if size <= 32 { return 2 }
        if size <= 64 { return 3 }
        return 4
    }

    @inline(__always)
    private static func packId(classId: UInt32, slotIndex: UInt32, generation: UInt32) throws(GraphemePoolError) -> IdPayload {
        guard slotIndex <= graphemeSlotMask else { throw .outOfMemory }
        return (classId << (graphemeGenerationBits + graphemeSlotBits))
            | ((generation & graphemeGenerationMask) << graphemeSlotBits)
            | (slotIndex & graphemeSlotMask)
    }

    @inline(__always)
    private static func unpackId(_ id: IdPayload) -> (classId: UInt32, generation: UInt32, slotIndex: UInt32) {
        let classId = (id >> (graphemeGenerationBits + graphemeSlotBits)) & graphemeClassMask
        let generation = (id >> graphemeSlotBits) & graphemeGenerationMask
        let slotIndex = id & graphemeSlotMask
        return (classId, generation, slotIndex)
    }

    /// Acquires one owned live reference to `bytes`, interning identical live clusters.
    public func acquire(_ bytes: [UInt8]) throws(GraphemePoolError) -> IdPayload {
        guard bytes.count <= graphemeBytesMax else {
            throw .graphemeTooLong
        }
        if let existing = internedLiveIds[bytes] {
            try incref(existing)
            return existing
        }
        let classId = Self.classForSize(bytes.count)
        let (slotIndex, generation) = try classes[Int(classId)].allocSlot(bytes)
        let id = try Self.packId(classId: classId, slotIndex: slotIndex, generation: generation)
        internedLiveIds[bytes] = id
        return id
    }

    /// Convenience overload acquiring a UTF-8 `String` grapheme cluster.
    public func acquire(_ text: String) throws(GraphemePoolError) -> IdPayload {
        try acquire(Array(text.utf8))
    }

    /// Retains an already-live grapheme ID.
    public func incref(_ id: IdPayload) throws(GraphemePoolError) {
        let (classId, generation, slotIndex) = Self.unpackId(id)
        guard classId < Self.maxClasses else { throw .invalidId }
        try classes[Int(classId)].incref(slotIndex: slotIndex, generation: generation)
    }

    /// Releases one reference to `id`, recycling the slot and removing interned identity at refcount 0.
    public func decref(_ id: IdPayload) throws(GraphemePoolError) {
        let (classId, generation, slotIndex) = Self.unpackId(id)
        guard classId < Self.maxClasses else { throw .invalidId }
        if let freedBytes = try classes[Int(classId)].decref(slotIndex: slotIndex, generation: generation) {
            internedLiveIds.removeValue(forKey: freedBytes)
        }
    }

    /// Returns the stored UTF-8 bytes for a live grapheme ID.
    public func get(_ id: IdPayload) throws(GraphemePoolError) -> [UInt8] {
        let (classId, generation, slotIndex) = Self.unpackId(id)
        guard classId < Self.maxClasses else { throw .invalidId }
        return try classes[Int(classId)].get(slotIndex: slotIndex, generation: generation)
    }

    /// Returns the stored UTF-8 text as a `String` for a live grapheme ID.
    public func getString(_ id: IdPayload) throws(GraphemePoolError) -> String {
        let bytes = try get(id)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Returns the current reference count of a live grapheme ID.
    public func getRefcount(_ id: IdPayload) throws(GraphemePoolError) -> UInt32 {
        let (classId, generation, slotIndex) = Self.unpackId(id)
        guard classId < Self.maxClasses else { throw .invalidId }
        return try classes[Int(classId)].getRefcount(slotIndex: slotIndex, generation: generation)
    }

    /// Number of currently live interned grapheme clusters in the pool.
    public var liveCount: Int {
        internedLiveIds.count
    }
}

// MARK: - GraphemeTracker

/// Tracks per-buffer grapheme ID usage, holding one `GraphemePool` reference per distinct
/// live grapheme ID present in the owning buffer.
// parity: native/src/grapheme.zig#GraphemeTracker [status=implemented hash=c130357725f5]
public final class GraphemeTracker: @unchecked Sendable {
    public let pool: GraphemePool
    public private(set) var usedIds: [UInt32: UInt32] = [:]

    public init(pool: GraphemePool) {
        self.pool = pool
    }

    deinit {
        clear()
    }

    public func clear() {
        for id in usedIds.keys {
            try? pool.decref(id)
        }
        usedIds.removeAll(keepingCapacity: true)
    }

    public func add(_ id: UInt32) {
        if let existing = usedIds[id] {
            usedIds[id] = existing + 1
        } else {
            do {
                try pool.incref(id)
                usedIds[id] = 1
            } catch {
                // Invalid/stale IDs cannot be retained.
            }
        }
    }

    public func remove(_ id: UInt32) {
        guard let count = usedIds[id] else { return }
        if count > 1 {
            usedIds[id] = count - 1
            return
        }
        usedIds.removeValue(forKey: id)
        try? pool.decref(id)
    }

    public func replace(oldId: UInt32?, newId: UInt32?) {
        if let oldId, let newId, oldId == newId { return }
        if let newId { add(newId) }
        if let oldId { remove(oldId) }
    }

    /// Replaces the entire tracked map from `source`, retaining each live ID once.
    internal func copyFrom(_ source: GraphemeTracker) {
        clear()
        for (id, count) in source.usedIds {
            if (try? pool.incref(id)) != nil {
                usedIds[id] = count
            }
        }
    }

    public func contains(_ id: UInt32) -> Bool {
        usedIds[id] != nil
    }

    public var hasAny: Bool {
        !usedIds.isEmpty
    }

    public var graphemeCount: UInt32 {
        UInt32(usedIds.count)
    }

    public var graphemeCellCount: UInt32 {
        var total: UInt32 = 0
        for count in usedIds.values {
            total += count
        }
        return total
    }

    public var totalGraphemeBytes: UInt32 {
        var total: UInt32 = 0
        for (id, count) in usedIds {
            if let bytes = try? pool.get(id) {
                total += UInt32(bytes.count) * count
            }
        }
        return total
    }
}
