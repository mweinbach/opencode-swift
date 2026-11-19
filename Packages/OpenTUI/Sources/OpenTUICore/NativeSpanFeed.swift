// Pure-Swift chunked span-feed stream (`core/src/NativeSpanFeed.ts`).
// Zero OS / Foundation imports, zero unsafe C pointers (Pure Tier).

// MARK: - Supporting Types

/// Memory growth policy when all allocated chunks are full or pinned.
public enum GrowthPolicy: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case grow
    case block
}

/// Configuration options for creating a `NativeSpanFeed`.
public struct NativeSpanFeedOptions: Equatable, Hashable, Sendable, Codable {
    public var chunkSize: Int
    public var initialChunks: Int
    public var maxBytes: UInt64
    public var growthPolicy: GrowthPolicy
    public var autoCommitOnFull: Bool
    public var spanQueueCapacity: Int

    public init(
        chunkSize: Int = 64 * 1024,
        initialChunks: Int = 2,
        maxBytes: UInt64 = 0,
        growthPolicy: GrowthPolicy = .grow,
        autoCommitOnFull: Bool = true,
        spanQueueCapacity: Int = 256
    ) {
        self.chunkSize = max(1, chunkSize)
        self.initialChunks = max(1, initialChunks)
        self.maxBytes = maxBytes
        self.growthPolicy = growthPolicy
        self.autoCommitOnFull = autoCommitOnFull
        self.spanQueueCapacity = max(1, spanQueueCapacity)
    }
}

/// Runtime telemetry snapshot for a `NativeSpanFeed`.
public struct NativeSpanFeedStats: Equatable, Hashable, Sendable, Codable {
    public var bytesWritten: UInt64
    public var spansCommitted: UInt64
    public var chunks: Int
    public var pendingSpans: Int
    public var outstandingSpans: Int
    public var outstandingBytes: UInt64

    public init(
        bytesWritten: UInt64 = 0,
        spansCommitted: UInt64 = 0,
        chunks: Int = 0,
        pendingSpans: Int = 0,
        outstandingSpans: Int = 0,
        outstandingBytes: UInt64 = 0
    ) {
        self.bytesWritten = bytesWritten
        self.spansCommitted = spansCommitted
        self.chunks = chunks
        self.pendingSpans = pendingSpans
        self.outstandingSpans = outstandingSpans
        self.outstandingBytes = outstandingBytes
    }
}

/// Pure-Swift header metadata for a chunked span-feed arena.
public struct SpanFeedHeader: Equatable, Hashable, Sendable, Codable {
    public var chunkSize: Int
    public var maxBytes: UInt64
    public var growthPolicy: GrowthPolicy
    public var spanQueueCapacity: Int
    public var chunkCount: Int
    public var activeChunkIndex: Int
    public var totalBytesAllocated: UInt64
    public var isClosed: Bool

    public init(
        chunkSize: Int,
        maxBytes: UInt64,
        growthPolicy: GrowthPolicy,
        spanQueueCapacity: Int,
        chunkCount: Int,
        activeChunkIndex: Int,
        totalBytesAllocated: UInt64,
        isClosed: Bool
    ) {
        self.chunkSize = chunkSize
        self.maxBytes = maxBytes
        self.growthPolicy = growthPolicy
        self.spanQueueCapacity = spanQueueCapacity
        self.chunkCount = chunkCount
        self.activeChunkIndex = activeChunkIndex
        self.totalBytesAllocated = totalBytesAllocated
        self.isClosed = isClosed
    }
}

/// Safe pure-Swift byte chunk backing one arena segment of a `NativeSpanFeed`.
public struct SpanFeedChunk: Equatable, Sendable {
    public let index: Int
    public let capacity: Int
    public internal(set) var writeOffset: Int
    public internal(set) var pinnedSpans: Int
    public internal(set) var bytes: [UInt8]

    public init(index: Int, capacity: Int) {
        self.index = index
        self.capacity = max(1, capacity)
        self.writeOffset = 0
        self.pinnedSpans = 0
        self.bytes = Array(repeating: 0, count: max(1, capacity))
    }

    public var remainingCapacity: Int {
        max(0, capacity - writeOffset)
    }

    public var isPinned: Bool {
        pinnedSpans > 0
    }
}

/// Descriptor for one committed byte span inside a `SpanFeedChunk`.
public struct SpanInfo: Equatable, Hashable, Sendable, Codable {
    public let chunkIndex: Int
    public let offset: Int
    public let len: Int
    public let slotIndex: Int
    public let releaseId: UInt64

    public init(chunkIndex: Int, offset: Int, len: Int, slotIndex: Int, releaseId: UInt64) {
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.len = len
        self.slotIndex = slotIndex
        self.releaseId = releaseId
    }
}

/// Reservation returned by `NativeSpanFeed.reserve(_:)` before calling `commit(...)`.
public struct SpanReservation: Equatable, Hashable, Sendable {
    public let chunkIndex: Int
    public let offset: Int
    public let capacity: Int

    public init(chunkIndex: Int, offset: Int, capacity: Int) {
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.capacity = capacity
    }
}

/// Errors raised by `NativeSpanFeed` producer operations.
public enum NativeSpanFeedError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case closed
    case invalidLength(Int)
    case outOfSpace(requested: Int, available: Int)
    case spanQueueFull(capacity: Int)
    case reservationMismatch
    case backpressured

    public var description: String {
        switch self {
        case .closed:
            return "NativeSpanFeed is closed"
        case .invalidLength(let len):
            return "Invalid span length: \(len)"
        case .outOfSpace(let requested, let available):
            return "Span feed out of space: requested \(requested) bytes, available \(available)"
        case .spanQueueFull(let capacity):
            return "Span feed queue capacity exceeded (\(capacity))"
        case .reservationMismatch:
            return "Commit does not match active reservation"
        case .backpressured:
            return "Span feed is backpressured"
        }
    }
}

/// Synchronous consumer callback receiving a committed byte slice.
// parity: core/src/NativeSpanFeed.ts#DataHandler [status=implemented hash=81621fda3bb1]
public typealias DataHandler = ([UInt8]) -> Void

/// Optional asynchronous consumer callback whose completion unpins the delivered span.
public typealias AsyncDataHandler = @Sendable ([UInt8]) async -> Void

// MARK: - NativeSpanFeed

/// Pure-Swift chunked span-feed stream matching `core/src/NativeSpanFeed.ts`.
// parity: core/src/NativeSpanFeed.ts#NativeSpanFeed [status=adapted hash=cf71f84e4355]
public final class NativeSpanFeed: @unchecked Sendable {
    private struct DataSubscription {
        let id: UInt64
        let handler: DataHandler
    }

    private struct AsyncDataSubscription {
        let id: UInt64
        let handler: AsyncDataHandler
    }

    private struct ErrorSubscription {
        let id: UInt64
        let handler: (Int32) -> Void
    }

    private struct OutstandingSpan {
        let info: SpanInfo
    }

    public let options: NativeSpanFeedOptions
    private var _chunks: [SpanFeedChunk] = []
    private var activeChunkIndex: Int = 0
    private var activeReservation: SpanReservation? = nil

    private var pendingQueue: [SpanInfo] = []
    private var outstandingSpans: [UInt64: OutstandingSpan] = [:]
    private var nextSlotIndex: Int = 0
    private var nextReleaseId: UInt64 = 1

    private var bytesWritten: UInt64 = 0
    private var spansCommitted: UInt64 = 0
    private var outstandingBytes: UInt64 = 0

    private var nextSubscriptionId: UInt64 = 1
    private var dataSubscriptions: [DataSubscription] = []
    private var asyncDataSubscriptions: [AsyncDataSubscription] = []
    private var errorSubscriptions: [ErrorSubscription] = []

    private var closed: Bool = false
    private var destroyed: Bool = false
    private var draining: Bool = false
    private var pendingDataAvailable: Bool = false
    private var pendingClose: Bool = false
    private var closing: Bool = false
    private var pendingAsyncHandlers: Int = 0
    private var inCallback: Bool = false
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    // MARK: Factories

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.create [status=adapted hash=c0d5becd195e]
    public static func create(_ options: NativeSpanFeedOptions = NativeSpanFeedOptions()) -> NativeSpanFeed {
        NativeSpanFeed(options: options)
    }

    /// Attaches a consumer facade to an existing `NativeSpanFeed` instance.
    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.attach [status=adapted hash=8a38f74f72a3]
    public static func attach(
        _ stream: NativeSpanFeed,
        options: NativeSpanFeedOptions? = nil
    ) -> NativeSpanFeed {
        _ = options
        return stream
    }

    public init(options: NativeSpanFeedOptions = NativeSpanFeedOptions()) {
        self.options = options
        var initialCount = options.initialChunks
        if options.maxBytes > 0 {
            let maxChunks = max(1, Int(options.maxBytes / UInt64(options.chunkSize)))
            initialCount = min(initialCount, maxChunks)
        }
        self._chunks.reserveCapacity(initialCount)
        for idx in 0..<initialCount {
            self._chunks.append(SpanFeedChunk(index: idx, capacity: options.chunkSize))
        }
    }

    // MARK: Introspection

    public var isClosed: Bool { closed }
    public var isDestroyed: Bool { destroyed }
    public var chunks: [SpanFeedChunk] { _chunks }

    public var header: SpanFeedHeader {
        let totalAlloc = _chunks.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
        return SpanFeedHeader(
            chunkSize: options.chunkSize,
            maxBytes: options.maxBytes,
            growthPolicy: options.growthPolicy,
            spanQueueCapacity: options.spanQueueCapacity,
            chunkCount: _chunks.count,
            activeChunkIndex: activeChunkIndex,
            totalBytesAllocated: totalAlloc,
            isClosed: closed
        )
    }

    public var stats: NativeSpanFeedStats {
        NativeSpanFeedStats(
            bytesWritten: bytesWritten,
            spansCommitted: spansCommitted,
            chunks: _chunks.count,
            pendingSpans: pendingQueue.count,
            outstandingSpans: outstandingSpans.count,
            outstandingBytes: outstandingBytes
        )
    }

    // MARK: Subscriptions

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.onData [status=implemented hash=3b0a73c55122]
    @discardableResult
    public func onData(_ handler: @escaping DataHandler) -> () -> Void {
        let id = allocateSubscriptionId()
        dataSubscriptions.append(DataSubscription(id: id, handler: handler))
        if pendingDataAvailable {
            pendingDataAvailable = false
            drainAll()
        }
        return { [weak self] in
            self?.dataSubscriptions.removeAll { $0.id == id }
        }
    }

    /// Subscribes an async handler that pins each delivered span until completion.
    @discardableResult
    public func onAsyncData(_ handler: @escaping AsyncDataHandler) -> () -> Void {
        let id = allocateSubscriptionId()
        asyncDataSubscriptions.append(AsyncDataSubscription(id: id, handler: handler))
        if pendingDataAvailable {
            pendingDataAvailable = false
            drainAll()
        }
        return { [weak self] in
            self?.asyncDataSubscriptions.removeAll { $0.id == id }
        }
    }

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.onError [status=implemented hash=73de4b8b1471]
    @discardableResult
    public func onError(_ handler: @escaping (Int32) -> Void) -> () -> Void {
        let id = allocateSubscriptionId()
        errorSubscriptions.append(ErrorSubscription(id: id, handler: handler))
        return { [weak self] in
            self?.errorSubscriptions.removeAll { $0.id == id }
        }
    }

    /// Dispatches an error code to all registered `onError` subscribers.
    public func emitError(_ code: Int32) {
        let wasInCallback = inCallback
        inCallback = true
        defer {
            inCallback = wasInCallback
            processPendingClose()
            resolveIdleIfNeeded()
        }
        for sub in errorSubscriptions {
            sub.handler(code)
        }
    }

    // MARK: Producer API (reserve / commit / write)

    /// Reserves at least `minLength` contiguous bytes in a chunk, rotating or growing chunks as needed.
    public func reserve(_ minLength: Int) throws(NativeSpanFeedError) -> SpanReservation {
        guard !closed && !destroyed && !closing else {
            throw .closed
        }
        guard minLength > 0 else {
            throw .invalidLength(minLength)
        }
        if pendingQueue.count >= options.spanQueueCapacity {
            if options.autoCommitOnFull && hasDataHandlers {
                drainAll()
            }
            if pendingQueue.count >= options.spanQueueCapacity {
                throw .spanQueueFull(capacity: options.spanQueueCapacity)
            }
        }

        // Try current active chunk first.
        if activeChunkIndex < _chunks.count, _chunks[activeChunkIndex].remainingCapacity >= minLength {
            let chunk = _chunks[activeChunkIndex]
            let res = SpanReservation(
                chunkIndex: chunk.index,
                offset: chunk.writeOffset,
                capacity: chunk.remainingCapacity
            )
            activeReservation = res
            return res
        }

        // Attempt to reuse any unpinned chunk with enough capacity (resetting it).
        for idx in 0..<_chunks.count {
            if !_chunks[idx].isPinned && _chunks[idx].capacity >= minLength {
                _chunks[idx].writeOffset = 0
                activeChunkIndex = idx
                let res = SpanReservation(
                    chunkIndex: _chunks[idx].index,
                    offset: 0,
                    capacity: _chunks[idx].capacity
                )
                activeReservation = res
                return res
            }
        }

        // If auto-drain is enabled and handlers exist, drain once and retry reuse.
        if options.autoCommitOnFull && hasDataHandlers && !pendingQueue.isEmpty {
            drainAll()
            for idx in 0..<_chunks.count {
                if !_chunks[idx].isPinned && _chunks[idx].capacity >= minLength {
                    _chunks[idx].writeOffset = 0
                    activeChunkIndex = idx
                    let res = SpanReservation(
                        chunkIndex: _chunks[idx].index,
                        offset: 0,
                        capacity: _chunks[idx].capacity
                    )
                    activeReservation = res
                    return res
                }
            }
        }

        // Allocate a new chunk if allowed by growth policy & maxBytes.
        let newChunkSize = max(options.chunkSize, minLength)
        let allocatedSoFar = _chunks.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
        if options.growthPolicy == .block {
            throw .outOfSpace(requested: minLength, available: availableBytesInActiveChunk())
        }
        if options.maxBytes > 0 && allocatedSoFar + UInt64(newChunkSize) > options.maxBytes {
            throw .outOfSpace(requested: minLength, available: availableBytesInActiveChunk())
        }

        let newIndex = _chunks.count
        _chunks.append(SpanFeedChunk(index: newIndex, capacity: newChunkSize))
        activeChunkIndex = newIndex
        let res = SpanReservation(chunkIndex: newIndex, offset: 0, capacity: newChunkSize)
        activeReservation = res
        return res
    }

    /// Commits `bytes` into an active `SpanReservation` and notifies data handlers.
    @discardableResult
    public func commit(reservation: SpanReservation, bytes: [UInt8]) throws(NativeSpanFeedError) -> SpanInfo {
        guard !closed && !destroyed && !closing else {
            throw .closed
        }
        guard activeReservation == reservation else {
            throw .reservationMismatch
        }
        guard !bytes.isEmpty && bytes.count <= reservation.capacity else {
            throw .invalidLength(bytes.count)
        }
        guard reservation.chunkIndex >= 0 && reservation.chunkIndex < _chunks.count else {
            throw .reservationMismatch
        }

        let start = reservation.offset
        let end = start + bytes.count
        guard end <= _chunks[reservation.chunkIndex].capacity else {
            throw .outOfSpace(requested: bytes.count, available: _chunks[reservation.chunkIndex].remainingCapacity)
        }

        for i in 0..<bytes.count {
            _chunks[reservation.chunkIndex].bytes[start + i] = bytes[i]
        }
        _chunks[reservation.chunkIndex].writeOffset = end
        _chunks[reservation.chunkIndex].pinnedSpans += 1
        activeReservation = nil

        let slot = nextSlotIndex
        nextSlotIndex = (nextSlotIndex + 1) % max(1, options.spanQueueCapacity)
        let releaseId = nextReleaseId
        nextReleaseId &+= 1
        if nextReleaseId == 0 { nextReleaseId = 1 }

        let info = SpanInfo(
            chunkIndex: reservation.chunkIndex,
            offset: start,
            len: bytes.count,
            slotIndex: slot,
            releaseId: releaseId
        )
        pendingQueue.append(info)
        outstandingSpans[releaseId] = OutstandingSpan(info: info)
        bytesWritten &+= UInt64(bytes.count)
        spansCommitted &+= 1
        outstandingBytes &+= UInt64(bytes.count)

        notifyDataAvailable()
        return info
    }

    /// Convenience reserve + commit for a byte array.
    @discardableResult
    public func commit(_ bytes: [UInt8]) throws(NativeSpanFeedError) -> SpanInfo {
        let res = try reserve(bytes.count)
        return try commit(reservation: res, bytes: bytes)
    }

    /// Convenience reserve + commit for a UTF-8 string.
    @discardableResult
    public func write(_ string: String) throws(NativeSpanFeedError) -> SpanInfo {
        try commit(Array(string.utf8))
    }

    /// Convenience reserve + commit for raw bytes.
    @discardableResult
    public func write(_ bytes: [UInt8]) throws(NativeSpanFeedError) -> SpanInfo {
        try commit(bytes)
    }

    // MARK: Consumer API (drain / drainAll / releaseSpan)

    /// Drains up to `maxSpans` pending span descriptors without invoking callbacks.
    /// Callers must call `releaseSpan(slotIndex:releaseId:)` for each returned span when finished.
    public func drain(maxSpans: Int? = nil) -> [SpanInfo] {
        guard !destroyed && !pendingQueue.isEmpty else { return [] }
        let limit = maxSpans.map { max(0, min($0, pendingQueue.count)) } ?? pendingQueue.count
        guard limit > 0 else { return [] }
        let drained = Array(pendingQueue.prefix(limit))
        pendingQueue.removeFirst(limit)
        if pendingQueue.isEmpty {
            pendingDataAvailable = false
        }
        return drained
    }

    /// Reads the copied byte slice for an outstanding `SpanInfo`.
    public func readSpan(_ span: SpanInfo) -> [UInt8]? {
        guard !destroyed,
              span.chunkIndex >= 0,
              span.chunkIndex < _chunks.count,
              span.offset >= 0,
              span.len >= 0,
              span.offset + span.len <= _chunks[span.chunkIndex].capacity
        else {
            return nil
        }
        let chunk = _chunks[span.chunkIndex]
        return Array(chunk.bytes[span.offset..<(span.offset + span.len)])
    }

    /// Releases a previously drained span, unpinning its backing chunk and recycling space when free.
    public func releaseSpan(slotIndex: Int, releaseId: UInt64) {
        _ = slotIndex
        guard let removed = outstandingSpans.removeValue(forKey: releaseId) else { return }
        let info = removed.info
        if outstandingBytes >= UInt64(info.len) {
            outstandingBytes -= UInt64(info.len)
        } else {
            outstandingBytes = 0
        }
        if info.chunkIndex >= 0 && info.chunkIndex < _chunks.count {
            _chunks[info.chunkIndex].pinnedSpans = max(0, _chunks[info.chunkIndex].pinnedSpans - 1)
            if _chunks[info.chunkIndex].pinnedSpans == 0 && info.chunkIndex != activeChunkIndex {
                _chunks[info.chunkIndex].writeOffset = 0
            }
        }
        processPendingClose()
        resolveIdleIfNeeded()
    }

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.drainAll [status=implemented hash=ccb1ae022f8c]
    public func drainAll() {
        while drainOnce() > 0 {}
    }

    private func drainOnce() -> Int {
        if destroyed || draining || pendingClose || pendingQueue.isEmpty {
            return 0
        }
        let batch = drain(maxSpans: options.spanQueueCapacity)
        if batch.isEmpty { return 0 }

        draining = true
        defer {
            draining = false
            processPendingClose()
            resolveIdleIfNeeded()
        }

        for span in batch {
            if pendingClose || span.len == 0 {
                releaseSpan(slotIndex: span.slotIndex, releaseId: span.releaseId)
                continue
            }
            guard let slice = readSpan(span) else {
                releaseSpan(slotIndex: span.slotIndex, releaseId: span.releaseId)
                continue
            }

            let wasInCallback = inCallback
            inCallback = true
            for sub in dataSubscriptions {
                sub.handler(slice)
            }
            inCallback = wasInCallback

            if !asyncDataSubscriptions.isEmpty {
                let handlers = asyncDataSubscriptions.map(\.handler)
                pendingAsyncHandlers += 1
                Task { [weak self] in
                    for handler in handlers {
                        await handler(slice)
                    }
                    guard let self else { return }
                    self.releaseSpan(slotIndex: span.slotIndex, releaseId: span.releaseId)
                    self.pendingAsyncHandlers = max(0, self.pendingAsyncHandlers - 1)
                    self.processPendingClose()
                    self.resolveIdleIfNeeded()
                }
            } else {
                releaseSpan(slotIndex: span.slotIndex, releaseId: span.releaseId)
            }
        }

        return batch.count
    }

    // MARK: Backpressure, Idle & Lifecycle

    private var hasDataHandlers: Bool {
        !dataSubscriptions.isEmpty || !asyncDataSubscriptions.isEmpty
    }

    private func hasPinnedChunks() -> Bool {
        !destroyed && !outstandingSpans.isEmpty
    }

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.isBackpressured [status=implemented hash=6c86b7922f1b]
    public func isBackpressured() -> Bool {
        pendingAsyncHandlers > 0 || pendingDataAvailable || hasPinnedChunks()
    }

    public var isIdle: Bool {
        !inCallback && !draining && pendingAsyncHandlers == 0 && !pendingDataAvailable && !hasPinnedChunks()
    }

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.idle [status=adapted hash=da0b17313b36]
    public func idle() async {
        if isIdle { return }
        await withCheckedContinuation { continuation in
            if isIdle {
                continuation.resume()
            } else {
                idleContinuations.append(continuation)
            }
        }
    }

    // parity: core/src/NativeSpanFeed.ts#NativeSpanFeed.close [status=implemented hash=da2a05fa77d7]
    public func close() {
        if destroyed { return }
        if inCallback || draining || pendingAsyncHandlers > 0 {
            pendingClose = true
            return
        }
        performClose()
    }

    private func processPendingClose() {
        guard pendingClose && !destroyed else { return }
        guard !inCallback && !draining && pendingAsyncHandlers == 0 else { return }
        pendingClose = false
        performClose()
        resolveIdleIfNeeded()
    }

    private func performClose() {
        if closing { return }
        closing = true
        closed = true
        activeReservation = nil

        // Release any undelivered pending spans.
        let remaining = pendingQueue
        pendingQueue.removeAll()
        for span in remaining {
            outstandingSpans.removeValue(forKey: span.releaseId)
        }
        outstandingSpans.removeAll()
        outstandingBytes = 0

        destroyed = true
        _chunks.removeAll()
        dataSubscriptions.removeAll()
        asyncDataSubscriptions.removeAll()
        errorSubscriptions.removeAll()
        pendingDataAvailable = false
        resolveIdleIfNeeded()
    }

    private func resolveIdleIfNeeded() {
        guard !idleContinuations.isEmpty && isIdle else { return }
        let waiters = idleContinuations
        idleContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func notifyDataAvailable() {
        if closing || destroyed { return }
        if !hasDataHandlers {
            pendingDataAvailable = true
            return
        }
        let wasInCallback = inCallback
        inCallback = true
        drainAll()
        inCallback = wasInCallback
        processPendingClose()
        resolveIdleIfNeeded()
    }

    private func availableBytesInActiveChunk() -> Int {
        guard activeChunkIndex >= 0 && activeChunkIndex < _chunks.count else { return 0 }
        return _chunks[activeChunkIndex].remainingCapacity
    }

    private func allocateSubscriptionId() -> UInt64 {
        let id = nextSubscriptionId
        nextSubscriptionId &+= 1
        if nextSubscriptionId == 0 { nextSubscriptionId = 1 }
        return id
    }
}

/// Concise alias for `NativeSpanFeed`.
public typealias SpanFeed = NativeSpanFeed
