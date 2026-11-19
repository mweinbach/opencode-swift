/// Pure-Swift reference-counted OSC 8 hyperlink URL pool returning 24-bit link IDs
/// compatible with `attributesWithLink(_:linkId:)` and `getLinkId(_:)`,
/// matching `packages/native/src/link.zig`.

// MARK: - Constants & Types

/// 24-bit link ID layout: `[ generation (8 bits) | slot_index (16 bits) ]`.
/// Generation starts at 1 so valid link IDs are always non-zero (`0` means no link).
// parity: native/src/link.zig#GEN_BITS [status=implemented hash=577022c431a7]
public let linkGenerationBits: UInt32 = 8
// parity: native/src/link.zig#SLOT_BITS [status=implemented hash=3aed9389eacc]
public let linkSlotBits: UInt32 = 16
// parity: native/src/link.zig#GEN_MASK [status=implemented hash=191f08721baf]
public let linkGenerationMask: UInt32 = (1 << linkGenerationBits) - 1
// parity: native/src/link.zig#SLOT_MASK [status=implemented hash=8ff6b5ae5caf]
public let linkSlotMask: UInt32 = (1 << linkSlotBits) - 1
// parity: native/src/link.zig#MAX_URL_LENGTH [status=implemented hash=150d2a3c7207]
public let linkMaxUrlLength: Int = 512
private let linkRetiredGeneration: UInt32 = linkGenerationMask + 1

// parity: native/src/link.zig#IdPayload [status=implemented hash=e0288d62a1d2]
public typealias LinkIdPayload = UInt32

// parity: native/src/link.zig#LinkPoolError [status=implemented hash=2b07c871bb09]
public enum LinkPoolError: Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case invalidId
    case wrongGeneration
    case invalidUrl
    case refcountOverflow
}

/// Reports whether `url` is a valid OSC 8 hyperlink target:
/// non-empty valid UTF-8, at most `linkMaxUrlLength` (512) bytes, with no C0, DEL, or C1 controls.
// parity: native/src/link.zig#isWritableUrl [status=implemented hash=fc562d7dfe0a]
public func isWritableUrl(_ url: [UInt8]) -> Bool {
    !url.isEmpty
        && url.count <= linkMaxUrlLength
        && isValidUtf8(url)
        && !containsControl(url)
}

public func isWritableUrl(_ url: String) -> Bool {
    isWritableUrl(Array(url.utf8))
}

// MARK: - LinkPool

/// Reference-counted, interned OSC 8 hyperlink URL table returning 24-bit link IDs.
/// Slots retire permanently after 255 generations so stale 24-bit IDs can never alias reused slots.
// parity: native/src/link.zig#LinkPool [status=implemented hash=d9d4139ace0a]
public final class LinkPool: @unchecked Sendable {
    private struct Slot {
        var url: String = ""
        var bytes: [UInt8] = []
        var refcount: UInt32 = 0
        var generation: UInt32 = 0
    }

    private var slots: [Slot] = []
    private var freeList: [UInt32] = []
    private var retiredSlotCount: Int = 0
    private var internedLiveIds: [String: LinkIdPayload] = [:]

    // parity: native/src/link.zig#LinkPool.init [status=implemented hash=195de84aa513]
    public init() {
        self.slots = []
        self.freeList = []
        self.retiredSlotCount = 0
        self.internedLiveIds = [:]
    }

    // parity: native/src/link.zig#LinkPool.deinit [status=implemented hash=a0b057606077]
    deinit {
        slots.removeAll(keepingCapacity: false)
        freeList.removeAll(keepingCapacity: false)
        internedLiveIds.removeAll(keepingCapacity: false)
    }

    @inline(__always)
    private static func packId(slotIndex: UInt32, generation: UInt32) throws(LinkPoolError) -> LinkIdPayload {
        guard slotIndex <= linkSlotMask else { throw .outOfMemory }
        return ((generation & linkGenerationMask) << linkSlotBits) | (slotIndex & linkSlotMask)
    }

    @inline(__always)
    private static func unpackId(_ id: LinkIdPayload) -> (slotIndex: UInt32, generation: UInt32) {
        (id & linkSlotMask, (id >> linkSlotBits) & linkGenerationMask)
    }

    internal func lookupLive(_ url: String) -> LinkIdPayload? {
        internedLiveIds[url]
    }

    /// Acquires one owned live reference to `url`, interning identical live URLs.
    // parity: native/src/link.zig#LinkPool.acquire [status=implemented hash=c605c1e1a31a]
    public func acquire(_ url: String) throws(LinkPoolError) -> LinkIdPayload {
        let bytes = Array(url.utf8)
        guard isWritableUrl(bytes) else {
            throw .invalidUrl
        }
        if let existing = internedLiveIds[url] {
            try incref(existing)
            return existing
        }

        let slotIndex: UInt32
        if let recycled = freeList.popLast() {
            slotIndex = recycled
        } else {
            guard slots.count <= Int(linkSlotMask) else {
                throw .outOfMemory
            }
            slotIndex = UInt32(slots.count)
            slots.append(Slot())
        }

        let idx = Int(slotIndex)
        let newGeneration = slots[idx].generation + 1
        slots[idx].url = url
        slots[idx].bytes = bytes
        slots[idx].refcount = 1
        slots[idx].generation = newGeneration

        let id = try Self.packId(slotIndex: slotIndex, generation: newGeneration)
        internedLiveIds[url] = id
        return id
    }

    /// Acquires one owned live reference to UTF-8 `bytes`.
    public func acquire(_ bytes: [UInt8]) throws(LinkPoolError) -> LinkIdPayload {
        guard isWritableUrl(bytes) else {
            throw .invalidUrl
        }
        return try acquire(String(decoding: bytes, as: UTF8.self))
    }

    /// Retains an already-live link ID.
    // parity: native/src/link.zig#LinkPool.incref [status=implemented hash=4e9c0a36906c]
    public func incref(_ id: LinkIdPayload) throws(LinkPoolError) {
        let (slotIndex, generation) = Self.unpackId(id)
        let idx = Int(slotIndex)
        guard idx < slots.count else { throw .invalidId }
        if slots[idx].generation != generation { throw .wrongGeneration }
        guard slots[idx].refcount > 0 else { throw .invalidId }
        guard slots[idx].refcount < UInt32.max else { throw .refcountOverflow }
        slots[idx].refcount += 1
    }

    /// Releases one reference to `id`, recycling or retiring the slot at refcount 0.
    // parity: native/src/link.zig#LinkPool.decref [status=implemented hash=143452796e90]
    public func decref(_ id: LinkIdPayload) throws(LinkPoolError) {
        let (slotIndex, generation) = Self.unpackId(id)
        let idx = Int(slotIndex)
        guard idx < slots.count else { throw .invalidId }
        guard slots[idx].refcount > 0 else { throw .invalidId }
        if slots[idx].generation != generation { throw .wrongGeneration }

        if slots[idx].refcount == 1 {
            internedLiveIds.removeValue(forKey: slots[idx].url)
        }
        slots[idx].refcount -= 1

        if slots[idx].refcount == 0 {
            if slots[idx].generation == linkGenerationMask {
                slots[idx].generation = linkRetiredGeneration
                retiredSlotCount += 1
            } else {
                freeList.append(slotIndex)
            }
        }
    }

    /// Returns the URL string stored at `id`.
    // parity: native/src/link.zig#LinkPool.get [status=implemented hash=d6cc2d9e9af7]
    public func get(_ id: LinkIdPayload) throws(LinkPoolError) -> String {
        let (slotIndex, generation) = Self.unpackId(id)
        let idx = Int(slotIndex)
        guard idx < slots.count else { throw .invalidId }
        if slots[idx].generation != generation { throw .wrongGeneration }
        return slots[idx].url
    }

    /// Returns the UTF-8 URL bytes stored at `id`.
    public func getBytes(_ id: LinkIdPayload) throws(LinkPoolError) -> [UInt8] {
        let (slotIndex, generation) = Self.unpackId(id)
        let idx = Int(slotIndex)
        guard idx < slots.count else { throw .invalidId }
        if slots[idx].generation != generation { throw .wrongGeneration }
        return slots[idx].bytes
    }

    /// Returns the current reference count of `id`.
    // parity: native/src/link.zig#LinkPool.getRefcount [status=implemented hash=4930ea6443cf]
    public func getRefcount(_ id: LinkIdPayload) throws(LinkPoolError) -> UInt32 {
        let (slotIndex, generation) = Self.unpackId(id)
        let idx = Int(slotIndex)
        guard idx < slots.count else { throw .invalidId }
        if slots[idx].generation != generation { throw .wrongGeneration }
        return slots[idx].refcount
    }

    // parity: native/src/link.zig#LinkPool.getTotalSlots [status=implemented hash=1e5986e78d0a]
    public var totalSlots: Int { slots.count }
    // parity: native/src/link.zig#LinkPool.getFreeSlotCount [status=implemented hash=fe49f0bb0109]
    public var freeSlotCount: Int { freeList.count }
    // parity: native/src/link.zig#LinkPool.getLiveSlotCount [status=implemented hash=d741005c60bc]
    public var liveSlotCount: Int { slots.count - freeList.count - retiredSlotCount }
}

// MARK: - LinkTracker

/// Tracks per-buffer hyperlink ID usage with cell-level refcounting.
// parity: native/src/link.zig#LinkTracker [status=implemented hash=80329df5ac7b]
public final class LinkTracker: @unchecked Sendable {
    public let pool: LinkPool
    public private(set) var usedIds: [UInt32: UInt32] = [:]

    // parity: native/src/link.zig#LinkTracker.init [status=implemented hash=5557ecdee0e2]
    public init(pool: LinkPool) {
        self.pool = pool
    }

    // parity: native/src/link.zig#LinkTracker.deinit [status=implemented hash=e2d8be6a8f7b]
    deinit {
        clear()
    }

    // parity: native/src/link.zig#LinkTracker.clear [status=implemented hash=40235821cc21]
    public func clear() {
        for id in usedIds.keys {
            try? pool.decref(id)
        }
        usedIds.removeAll(keepingCapacity: true)
    }

    /// Tracks document membership once per URL, independent of chunk count.
    // parity: native/src/link.zig#LinkTracker.trackUrl [status=implemented hash=b77f77ef8003]
    public func trackUrl(_ url: String) throws(LinkPoolError) -> LinkIdPayload {
        if let existing = pool.lookupLive(url), usedIds[existing] != nil {
            return existing
        }
        let id = try pool.acquire(url)
        usedIds[id] = 1
        return id
    }

    // parity: native/src/link.zig#LinkTracker.addCellRef [status=implemented hash=2d9d2c4caac8]
    public func addCellRef(_ id: UInt32) {
        if let existing = usedIds[id] {
            usedIds[id] = existing + 1
        } else {
            do {
                try pool.incref(id)
                usedIds[id] = 1
            } catch {
                // Invalid or stale link IDs are ignored.
            }
        }
    }

    // parity: native/src/link.zig#LinkTracker.removeCellRef [status=implemented hash=5060b902e37c]
    public func removeCellRef(_ id: UInt32) {
        guard let count = usedIds[id], count > 0 else { return }
        if count > 1 {
            usedIds[id] = count - 1
        } else {
            usedIds.removeValue(forKey: id)
            try? pool.decref(id)
        }
    }

    internal func copyFrom(_ source: LinkTracker) {
        clear()
        for (id, count) in source.usedIds {
            if (try? pool.incref(id)) != nil {
                usedIds[id] = count
            }
        }
    }

    // parity: native/src/link.zig#LinkTracker.hasAny [status=implemented hash=093b94ae8654]
    public var hasAny: Bool { !usedIds.isEmpty }
    // parity: native/src/link.zig#LinkTracker.getLinkCount [status=implemented hash=8883887b1331]
    public var linkCount: UInt32 { UInt32(usedIds.count) }
}
