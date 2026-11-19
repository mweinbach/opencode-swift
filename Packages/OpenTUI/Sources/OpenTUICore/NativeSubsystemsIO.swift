// Pure-Swift native I/O & text/highlight subsystem parity implementations for OpenTUICore (Workstream 3a1).
// Covers all 121 unmapped symbols across 15 upstream `packages/native` Zig modules:
// - src/highlight-layers.zig (12), src/split-scrollback.zig (1), src/stdout-writer.zig (17),
// - src/logger.zig (13), src/file-logger.zig (7), src/mem-registry.zig (3),
// - src/kitty-transport.zig (6), src/text-buffer-iterators.zig (25), src/text-buffer-segment.zig (14),
// - src/text-work.zig (3), src/utf8.zig (5), src/encoded-unicode.zig (2),
// - src/edit-marks.zig (8), src/event-emitter.zig (1), src/utils.zig (4).
// Pure Swift 6 — zero OS or Foundation imports.

import Synchronization

// MARK: - Top-level Namespace

public enum NativeSubsystemsIO: Sendable {}

// MARK: - 1. native/src/text-work.zig (3 symbols)

public enum NativeTextWork: Sendable {
    // parity: native/src/text-work.zig#Counts [status=implemented hash=7bff69da9697]
    public struct Counts: Equatable, Hashable, Sendable, Codable {
        public var layouts: UInt64 = 0
        public var linesLaidOut: UInt64 = 0
        public var ropeDiffNodes: UInt64 = 0
        public var linesShifted: UInt64 = 0
        public var splices: UInt64 = 0
        public var markPreparations: UInt64 = 0
        public var measurePasses: UInt64 = 0
        public var measureLines: UInt64 = 0
        public var lineSeeks: UInt64 = 0
        public var lineSeekNodes: UInt64 = 0
        public var highlightLeaves: UInt64 = 0
        public var remeasureNodes: UInt64 = 0
        public var clusterScanSteps: UInt64 = 0
        public var leftSkipSteps: UInt64 = 0
        public var spanSearchSteps: UInt64 = 0
        public var clustersDrawn: UInt64 = 0
        public var prefixSeeks: UInt64 = 0
        public var graphemeWidthReads: UInt64 = 0
        public var bytesScanned: UInt64 = 0
        public var asciiBytes: UInt64 = 0
        public var styledTextSets: UInt64 = 0
        public var styledTextBytes: UInt64 = 0
        public var styleRegistrations: UInt64 = 0
        public var styleDependentVisits: UInt64 = 0
        public var graphemeJoins: UInt64 = 0
        public var graphemeJoinBytes: UInt64 = 0
        public var lineSpanBuilds: UInt64 = 0
        public var lineSpanHighlights: UInt64 = 0
        public var spanHeapSteps: UInt64 = 0
        public var tailWrites: UInt64 = 0
        public var tailWriteBytes: UInt64 = 0
        public var ropeRebuilds: UInt64 = 0
        public var layerRunsCopied: UInt64 = 0
        public var layerRunSeeks: UInt64 = 0
        public var layerRunsWalked: UInt64 = 0

        public init() {}
    }

    public enum Field: Equatable, Hashable, Sendable, CaseIterable {
        case layouts
        case linesLaidOut
        case ropeDiffNodes
        case linesShifted
        case splices
        case markPreparations
        case measurePasses
        case measureLines
        case lineSeeks
        case lineSeekNodes
        case highlightLeaves
        case remeasureNodes
        case clusterScanSteps
        case leftSkipSteps
        case spanSearchSteps
        case clustersDrawn
        case prefixSeeks
        case graphemeWidthReads
        case bytesScanned
        case asciiBytes
        case styledTextSets
        case styledTextBytes
        case styleRegistrations
        case styleDependentVisits
        case graphemeJoins
        case graphemeJoinBytes
        case lineSpanBuilds
        case lineSpanHighlights
        case spanHeapSteps
        case tailWrites
        case tailWriteBytes
        case ropeRebuilds
        case layerRunsCopied
        case layerRunSeeks
        case layerRunsWalked
    }

    private static let storage = Mutex(Counts())

    // parity: native/src/text-work.zig#add [status=implemented hash=f01babf83247]
    public static func add(_ field: Field, _ n: Int) {
        guard n > 0 else { return }
        let delta = UInt64(n)
        storage.withLock { c in
            switch field {
            case .layouts: c.layouts &+= delta
            case .linesLaidOut: c.linesLaidOut &+= delta
            case .ropeDiffNodes: c.ropeDiffNodes &+= delta
            case .linesShifted: c.linesShifted &+= delta
            case .splices: c.splices &+= delta
            case .markPreparations: c.markPreparations &+= delta
            case .measurePasses: c.measurePasses &+= delta
            case .measureLines: c.measureLines &+= delta
            case .lineSeeks: c.lineSeeks &+= delta
            case .lineSeekNodes: c.lineSeekNodes &+= delta
            case .highlightLeaves: c.highlightLeaves &+= delta
            case .remeasureNodes: c.remeasureNodes &+= delta
            case .clusterScanSteps: c.clusterScanSteps &+= delta
            case .leftSkipSteps: c.leftSkipSteps &+= delta
            case .spanSearchSteps: c.spanSearchSteps &+= delta
            case .clustersDrawn: c.clustersDrawn &+= delta
            case .prefixSeeks: c.prefixSeeks &+= delta
            case .graphemeWidthReads: c.graphemeWidthReads &+= delta
            case .bytesScanned: c.bytesScanned &+= delta
            case .asciiBytes: c.asciiBytes &+= delta
            case .styledTextSets: c.styledTextSets &+= delta
            case .styledTextBytes: c.styledTextBytes &+= delta
            case .styleRegistrations: c.styleRegistrations &+= delta
            case .styleDependentVisits: c.styleDependentVisits &+= delta
            case .graphemeJoins: c.graphemeJoins &+= delta
            case .graphemeJoinBytes: c.graphemeJoinBytes &+= delta
            case .lineSpanBuilds: c.lineSpanBuilds &+= delta
            case .lineSpanHighlights: c.lineSpanHighlights &+= delta
            case .spanHeapSteps: c.spanHeapSteps &+= delta
            case .tailWrites: c.tailWrites &+= delta
            case .tailWriteBytes: c.tailWriteBytes &+= delta
            case .ropeRebuilds: c.ropeRebuilds &+= delta
            case .layerRunsCopied: c.layerRunsCopied &+= delta
            case .layerRunSeeks: c.layerRunSeeks &+= delta
            case .layerRunsWalked: c.layerRunsWalked &+= delta
            }
        }
    }

    // parity: native/src/text-work.zig#take [status=implemented hash=4d1d9e97ef32]
    public static func take() -> Counts {
        storage.withLock { c in
            let snapshot = c
            c = Counts()
            return snapshot
        }
    }
}

// MARK: - 2. native/src/utils.zig (4 symbols)

public enum NativeUtils: Sendable {
    private static let base64Table: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )
    private static let paintClock = Atomic<UInt64>(0)

    // parity: native/src/utils.zig#repeat [status=implemented hash=203fed1115f9]
    public static func `repeat`<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        var out: [T] = []
        out.reserveCapacity(items.count * count)
        for _ in 0..<count {
            out.append(contentsOf: items)
        }
        return out
    }

    public static func repeatString(_ text: String, count: Int) -> String {
        guard count > 0, !text.isEmpty else { return "" }
        return String(repeating: text, count: count)
    }

    // parity: native/src/utils.zig#eql [status=implemented hash=3ab5fc734e12]
    public static func eql<T: FixedWidthInteger>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where a[i] != b[i] {
            return false
        }
        return true
    }

    public static func eql<T: FixedWidthInteger>(_ a: ArraySlice<T>, _ b: ArraySlice<T>) -> Bool {
        guard a.count == b.count else { return false }
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex {
            if a[ia] != b[ib] { return false }
            a.formIndex(after: &ia)
            b.formIndex(after: &ib)
        }
        return true
    }

    public static func base64EncodedLength(_ sourceCount: Int) -> Int {
        guard sourceCount > 0 else { return 0 }
        return ((sourceCount + 2) / 3) * 4
    }

    // parity: native/src/utils.zig#base64Encode [status=implemented hash=86416c122da9]
    public static func base64Encode(_ source: [UInt8]) -> [UInt8] {
        let needed = base64EncodedLength(source.count)
        guard needed > 0 else { return [] }
        var out = Array<UInt8>(repeating: 0, count: needed)
        _ = base64Encode(into: &out, source: source)
        return out
    }

    public static func base64Encode(into dest: inout [UInt8], source: [UInt8]) -> Int {
        let needed = base64EncodedLength(source.count)
        precondition(dest.count >= needed, "base64Encode destination buffer too small")
        var i = 0
        var outIdx = 0
        let count = source.count
        while i + 3 <= count {
            let b0 = UInt32(source[i])
            let b1 = UInt32(source[i + 1])
            let b2 = UInt32(source[i + 2])
            let triple = (b0 << 16) | (b1 << 8) | b2
            dest[outIdx] = base64Table[Int((triple >> 18) & 0x3F)]
            dest[outIdx + 1] = base64Table[Int((triple >> 12) & 0x3F)]
            dest[outIdx + 2] = base64Table[Int((triple >> 6) & 0x3F)]
            dest[outIdx + 3] = base64Table[Int(triple & 0x3F)]
            i += 3
            outIdx += 4
        }
        let rem = count - i
        if rem == 1 {
            let b0 = UInt32(source[i])
            dest[outIdx] = base64Table[Int((b0 >> 2) & 0x3F)]
            dest[outIdx + 1] = base64Table[Int((b0 << 4) & 0x3F)]
            dest[outIdx + 2] = UInt8(ascii: "=")
            dest[outIdx + 3] = UInt8(ascii: "=")
            outIdx += 4
        } else if rem == 2 {
            let b0 = UInt32(source[i])
            let b1 = UInt32(source[i + 1])
            let pair = (b0 << 8) | b1
            dest[outIdx] = base64Table[Int((pair >> 10) & 0x3F)]
            dest[outIdx + 1] = base64Table[Int((pair >> 4) & 0x3F)]
            dest[outIdx + 2] = base64Table[Int((pair << 2) & 0x3F)]
            dest[outIdx + 3] = UInt8(ascii: "=")
            outIdx += 4
        }
        return outIdx
    }

    public static func base64EncodeString(_ source: [UInt8]) -> String {
        String(decoding: base64Encode(source), as: UTF8.self)
    }

    // parity: native/src/utils.zig#nextPaintEpoch [status=implemented hash=d4be86783d72]
    public static func nextPaintEpoch() -> UInt64 {
        paintClock.wrappingAdd(1, ordering: .relaxed).newValue
    }
}

// MARK: - 3. native/src/event-emitter.zig (1 symbol)

// parity: native/src/event-emitter.zig#EventEmitter [status=implemented hash=c18e4be7f942]
public final class NativeEventEmitter<EventType: Hashable & Sendable>: @unchecked Sendable {
    public struct Listener: Equatable, Hashable, Sendable {
        public let id: UInt64
        public let handle: @Sendable () -> Void

        public init(id: UInt64, handle: @escaping @Sendable () -> Void) {
            self.id = id
            self.handle = handle
        }

        public static func == (lhs: Listener, rhs: Listener) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private struct State: Sendable {
        var listeners: [EventType: [Listener]] = [:]
        var nextId: UInt64 = 1
    }

    private let state = Mutex(State())

    public init() {}

    public func on(_ event: EventType, listener: Listener) {
        state.withLock { s in
            s.listeners[event, default: []].append(listener)
        }
    }

    @discardableResult
    public func on(_ event: EventType, handle: @escaping @Sendable () -> Void) -> Listener {
        state.withLock { s in
            let id = s.nextId
            s.nextId &+= 1
            let listener = Listener(id: id, handle: handle)
            s.listeners[event, default: []].append(listener)
            return listener
        }
    }

    public func off(_ event: EventType, listener: Listener) {
        state.withLock { s in
            guard var list = s.listeners[event] else { return }
            var i = 0
            while i < list.count {
                if list[i].id == listener.id {
                    // Match Zig swapRemove semantics
                    let last = list.removeLast()
                    if i < list.count {
                        list[i] = last
                    }
                } else {
                    i += 1
                }
            }
            s.listeners[event] = list
        }
    }

    public func emit(_ event: EventType) {
        let snapshot = state.withLock { $0.listeners[event] ?? [] }
        for listener in snapshot {
            listener.handle()
        }
    }

    public func listenerCount(for event: EventType) -> Int {
        state.withLock { $0.listeners[event]?.count ?? 0 }
    }

    public func removeAllListeners() {
        state.withLock { $0.listeners.removeAll(keepingCapacity: false) }
    }
}

// MARK: - 4. native/src/split-scrollback.zig (1 symbol)

// parity: native/src/split-scrollback.zig#SplitScrollback [status=implemented hash=45e6a40cd867]
public struct NativeSplitScrollback: Equatable, Hashable, Sendable, Codable {
    public var publishedRows: UInt32
    public var tailColumn: UInt32

    public init(publishedRows: UInt32 = 0, tailColumn: UInt32 = 0) {
        self.publishedRows = publishedRows
        self.tailColumn = tailColumn
    }

    public mutating func reset(seedRows: UInt32 = 0) {
        self.publishedRows = seedRows
        self.tailColumn = 0
    }

    public func renderOffset(surfaceOffset: UInt32) -> UInt32 {
        if surfaceOffset == 0 {
            return 0
        }
        return min(publishedRows, surfaceOffset)
    }

    public mutating func noteViewportScroll(lines: UInt32) {
        publishedRows -= min(lines, publishedRows)
        if publishedRows == 0 {
            tailColumn = 0
        }
    }

    public mutating func noteNewline() {
        if publishedRows == 0 {
            publishedRows = 1
        }
        publishedRows &+= 1
        tailColumn = 0
    }

    public mutating func publishSnapshotRows(
        rowCount: UInt32,
        rowColumns: UInt32,
        terminalWidth: UInt32,
        trailingNewline: Bool
    ) {
        guard rowCount > 0 else { return }
        for row in 0..<rowCount {
            publishRow(
                columns: rowColumns,
                width: terminalWidth,
                trailingNewline: (row + 1 < rowCount) || trailingNewline
            )
        }
    }

    public mutating func publishRow(columns: UInt32, width: UInt32, trailingNewline: Bool) {
        publishColumns(columns: columns, width: width)
        if trailingNewline {
            noteNewline()
        }
    }

    private mutating func publishColumns(columns: UInt32, width: UInt32) {
        guard columns > 0 else { return }
        let safeWidth = max(width, 1)
        var remaining = columns

        while remaining > 0 {
            if publishedRows == 0 {
                publishedRows = 1
            }
            if tailColumn >= safeWidth {
                publishedRows &+= 1
                tailColumn = 0
            }
            let availableWidth = safeWidth - tailColumn
            let step = min(remaining, availableWidth)
            tailColumn &+= step
            remaining -= step
            if remaining > 0 && tailColumn >= safeWidth {
                publishedRows &+= 1
                tailColumn = 0
            }
        }
    }
}

// MARK: - 5. native/src/mem-registry.zig (3 symbols)

// parity: native/src/mem-registry.zig#MemRegistryError [status=implemented hash=929f463be1ff]
public enum NativeMemRegistryError: Swift.Error, Equatable, Hashable, Sendable {
    case outOfMemory
    case invalidMemId
}

// parity: native/src/mem-registry.zig#MemBuffer [status=implemented hash=147f999b324e]
public struct NativeMemBuffer: Equatable, Hashable, Sendable {
    public var data: [UInt8]
    public var owned: Bool
    public var active: Bool

    public init(data: [UInt8] = [], owned: Bool = false, active: Bool = false) {
        self.data = data
        self.owned = owned
        self.active = active
    }
}

// parity: native/src/mem-registry.zig#MemRegistry [status=implemented hash=fff2cc64e5d4]
public struct NativeMemRegistry: Equatable, Sendable {
    public static let maxSlots: Int = 255

    public private(set) var buffers: [NativeMemBuffer] = []
    public private(set) var freeSlots: [UInt8] = []

    public init() {}

    public mutating func register(_ data: [UInt8], owned: Bool = true) throws(NativeMemRegistryError) -> UInt8 {
        if let id = freeSlots.popLast() {
            buffers[Int(id)] = NativeMemBuffer(data: data, owned: owned, active: true)
            return id
        }
        guard buffers.count < Self.maxSlots else {
            throw .outOfMemory
        }
        let id = UInt8(buffers.count)
        buffers.append(NativeMemBuffer(data: data, owned: owned, active: true))
        return id
    }

    public mutating func register(_ text: String, owned: Bool = true) throws(NativeMemRegistryError) -> UInt8 {
        try register(Array(text.utf8), owned: owned)
    }

    public mutating func cancelLastRegistration(id: UInt8, previousBufferCount: Int) {
        let idx = Int(id)
        precondition(idx < buffers.count && buffers[idx].active)
        precondition(buffers.count == previousBufferCount || buffers.count == previousBufferCount + 1)

        if buffers.count > previousBufferCount {
            precondition(idx == previousBufferCount && freeSlots.isEmpty)
            _ = buffers.popLast()
        } else {
            buffers[idx] = NativeMemBuffer(data: [], owned: false, active: false)
            freeSlots.append(id)
        }
    }

    public func get(_ id: UInt8) -> [UInt8]? {
        let idx = Int(id)
        guard idx < buffers.count else { return nil }
        let buf = buffers[idx]
        return buf.active ? buf.data : nil
    }

    public mutating func replace(_ id: UInt8, data: [UInt8], owned: Bool = true) throws(NativeMemRegistryError) {
        let idx = Int(id)
        guard idx < buffers.count, buffers[idx].active else {
            throw .invalidMemId
        }
        buffers[idx] = NativeMemBuffer(data: data, owned: owned, active: true)
    }

    public mutating func unregister(_ id: UInt8) throws(NativeMemRegistryError) {
        let idx = Int(id)
        guard idx < buffers.count, buffers[idx].active else {
            throw .invalidMemId
        }
        buffers[idx] = NativeMemBuffer(data: [], owned: false, active: false)
        freeSlots.append(id)
    }

    public mutating func clear() {
        buffers.removeAll(keepingCapacity: true)
        freeSlots.removeAll(keepingCapacity: true)
    }

    public func getUsedSlots() -> Int {
        var count = 0
        for buf in buffers where buf.active {
            count += 1
        }
        return count
    }

    public func getFreeSlots() -> Int {
        Self.maxSlots - buffers.count + freeSlots.count
    }
}

// MARK: - 6. native/src/utf8.zig (5 unmapped symbols)

public enum NativeUtf8Extras: Sendable {
    // parity: native/src/utf8.zig#LineBreakResult [status=implemented hash=291a43575d31]
    public struct LineBreakResult: Equatable, Hashable, Sendable {
        public var breaks: [LineBreak]

        public init(breaks: [LineBreak] = []) {
            self.breaks = breaks
        }

        public mutating func reset() {
            breaks.removeAll(keepingCapacity: true)
        }
    }

    // parity: native/src/utf8.zig#TabStopResult [status=implemented hash=366ac2a3a5f6]
    public struct TabStopResult: Equatable, Hashable, Sendable {
        public var positions: [Int]

        public init(positions: [Int] = []) {
            self.positions = positions
        }

        public mutating func reset() {
            positions.removeAll(keepingCapacity: true)
        }
    }

    public struct DecodedUtf8: Equatable, Hashable, Sendable {
        public var cp: UInt32
        public var len: UInt8

        public init(cp: UInt32, len: UInt8) {
            self.cp = cp
            self.len = len
        }
    }

    // parity: native/src/utf8.zig#decodeUtf8Unchecked [status=implemented hash=ac4891fe83a8]
    @inline(__always)
    public static func decodeUtf8Unchecked(_ text: [UInt8], at pos: Int) -> DecodedUtf8 {
        precondition(pos >= 0 && pos < text.count)
        let b0 = text[pos]
        if b0 < 0x80 {
            return DecodedUtf8(cp: UInt32(b0), len: 1)
        }
        if pos + 1 >= text.count {
            return DecodedUtf8(cp: 0xFFFD, len: 1)
        }
        let b1 = text[pos + 1]
        if (b0 & 0xE0) == 0xC0 {
            let cp2 = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            return DecodedUtf8(cp: cp2, len: 2)
        }
        if pos + 2 >= text.count {
            return DecodedUtf8(cp: 0xFFFD, len: 1)
        }
        let b2 = text[pos + 2]
        if (b0 & 0xF0) == 0xE0 {
            let cp3 = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
            return DecodedUtf8(cp: cp3, len: 3)
        }
        if pos + 3 >= text.count {
            return DecodedUtf8(cp: 0xFFFD, len: 1)
        }
        let b3 = text[pos + 3]
        let cp4 = (UInt32(b0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) | (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)
        return DecodedUtf8(cp: cp4, len: 4)
    }

    /// UAX #29 Extended Grapheme Cluster break state machine.
    public enum GraphemeBreakState: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case `default` = 0
        case riOdd = 1
        case epExtend = 2
        case epZwj = 3
        case incbConsonant = 4
        case incbLinker = 5
    }

    @inline(__always)
    private static func isValidCodepoint(_ cp: UInt32) -> Bool {
        cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) && cp != 0xFFFD
    }

    private static func isRegionalIndicator(_ cp: UInt32) -> Bool {
        cp >= 0x1F1E6 && cp <= 0x1F1FF
    }

    private static func isControlOrBreak(_ cp: UInt32) -> Bool {
        if cp == 0x000A || cp == 0x000D { return true }
        if cp < 0x0020 || (cp >= 0x007F && cp <= 0x009F) { return true }
        switch cp {
        case 0x00AD, 0x061C, 0x180E, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029,
             0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0xFFF9...0xFFFB:
            return true
        default:
            return false
        }
    }

    private static func isPrepend(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2, 0x0D4E,
             0x110BD, 0x110CD, 0x111C2...0x111C3, 0x1193F, 0x11941, 0x11A3A,
             0x11A84...0x11A89, 0x11D46, 0x11F02:
            return true
        default:
            return false
        }
    }

    private static func isExtend(_ cp: UInt32) -> Bool {
        if cp >= 0x1F3FB && cp <= 0x1F3FF { return true } // Emoji skin tone modifiers
        if cp >= 0xFE00 && cp <= 0xFE0F { return true } // Variation selectors
        if cp >= 0xE0100 && cp <= 0xE01EF { return true } // Variation selectors supplement
        if cp >= 0xE0020 && cp <= 0xE007F { return true } // Tag characters
        if cp == 0x20E3 { return true } // Combining enclosing keycap
        if let scalar = Unicode.Scalar(cp) {
            return isCombiningMark(scalar)
        }
        return false
    }

    private static func isSpacingMark(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x0903, 0x093B, 0x093E...0x0940, 0x0949...0x094C, 0x094E...0x094F,
             0x0982...0x0983, 0x09BE...0x09C0, 0x09C7...0x09C8, 0x09CB...0x09CC,
             0x0A03, 0x0A3E...0x0A40, 0x0B02...0x0B03, 0x0BBE...0x0BBF, 0x0BC1...0x0BC2,
             0x0BC6...0x0BC8, 0x0BCA...0x0BCC, 0x0D02...0x0D03, 0x0D3E...0x0D40:
            return true
        default:
            return false
        }
    }

    private static func isExtendedPictographic(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139, 0x2194...0x2199, 0x21A9...0x21AA,
             0x231A...0x231B, 0x2328, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA,
             0x24C2, 0x25AA...0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE,
             0x2600...0x27BF, 0x2934...0x2935, 0x2B05...0x2B07, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x3030, 0x303D, 0x3297, 0x3299,
             0x1F000...0x1FAFF:
            return true
        default:
            return false
        }
    }

    private static func isHangulL(_ cp: UInt32) -> Bool {
        (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0xA960 && cp <= 0xA97C)
    }

    private static func isHangulV(_ cp: UInt32) -> Bool {
        (cp >= 0x1160 && cp <= 0x11A7) || (cp >= 0xD7B0 && cp <= 0xD7C6)
    }

    private static func isHangulT(_ cp: UInt32) -> Bool {
        (cp >= 0x11A8 && cp <= 0x11FF) || (cp >= 0xD7CB && cp <= 0xD7FB)
    }

    private static func isHangulLV(_ cp: UInt32) -> Bool {
        cp >= 0xAC00 && cp <= 0xD7A3 && (cp - 0xAC00) % 28 == 0
    }

    private static func isHangulLVT(_ cp: UInt32) -> Bool {
        cp >= 0xAC00 && cp <= 0xD7A3 && (cp - 0xAC00) % 28 != 0
    }

    private static func isIndicLinker(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x094D, 0x09CD, 0x0ACD, 0x0B4D, 0x0C4D, 0x0D4D:
            return true
        default:
            return false
        }
    }

    private static func isIndicConsonant(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x0915...0x0939, 0x0958...0x095F,
             0x0995...0x09B9, 0x0A95...0x0AB9,
             0x0B15...0x0B39, 0x0C15...0x0C39,
             0x0D15...0x0D39:
            return true
        default:
            return false
        }
    }

    // parity: native/src/utf8.zig#isGraphemeBreak [status=implemented hash=8aba8c783578]
    public static func isGraphemeBreak(
        prevCp: UInt32?,
        currCp: UInt32,
        breakState: inout GraphemeBreakState,
        widthMethod: WidthMethod = .unicode
    ) -> Bool {
        guard let p = prevCp else {
            // Initialize state for the first code point of a sequence
            if isExtendedPictographic(currCp) {
                breakState = .epExtend
            } else if isRegionalIndicator(currCp) {
                breakState = .riOdd
            } else if isIndicConsonant(currCp) {
                breakState = .incbConsonant
            } else {
                breakState = .default
            }
            return true
        }

        let forced = !isValidCodepoint(currCp) || !isValidCodepoint(p)
            || (widthMethod == .noZWJ && p == 0x200D)
        if forced {
            breakState = .default
            return true
        }

        // GB3: CR x LF
        if p == 0x000D && currCp == 0x000A {
            breakState = .default
            return false
        }
        // GB4 / GB5: Control | CR | LF
        if isControlOrBreak(p) || isControlOrBreak(currCp) {
            breakState = .default
            return true
        }
        // GB6: L x (L | V | LV | LVT)
        if isHangulL(p) && (isHangulL(currCp) || isHangulV(currCp) || isHangulLV(currCp) || isHangulLVT(currCp)) {
            breakState = .default
            return false
        }
        // GB7: (LV | V) x (V | T)
        if (isHangulLV(p) || isHangulV(p)) && (isHangulV(currCp) || isHangulT(currCp)) {
            breakState = .default
            return false
        }
        // GB8: (LVT | T) x T
        if (isHangulLVT(p) || isHangulT(p)) && isHangulT(currCp) {
            breakState = .default
            return false
        }
        // GB11: Extended_Pictographic Extend* ZWJ x Extended_Pictographic
        if breakState == .epZwj && isExtendedPictographic(currCp) {
            breakState = .epExtend
            return false
        }
        // GB9c: Indic_Conjunct_Break
        if breakState == .incbLinker && isIndicConsonant(currCp) {
            breakState = .incbConsonant
            return false
        }
        // GB9: x (Extend | ZWJ)
        if currCp == 0x200D {
            if breakState == .epExtend || isExtendedPictographic(p) {
                breakState = .epZwj
            } else if breakState == .incbConsonant || breakState == .incbLinker {
                // Keep InCB state across ZWJ
            } else {
                breakState = .default
            }
            return false
        }
        if isExtend(currCp) {
            if breakState == .epExtend || isExtendedPictographic(p) {
                breakState = .epExtend
            } else if (breakState == .incbConsonant || breakState == .incbLinker) && isIndicLinker(currCp) {
                breakState = .incbLinker
            } else if isIndicConsonant(p) && isIndicLinker(currCp) {
                breakState = .incbLinker
            }
            return false
        }
        // GB9a: x SpacingMark
        if isSpacingMark(currCp) {
            breakState = .default
            return false
        }
        // GB9b: Prepend x
        if isPrepend(p) {
            breakState = .default
            return false
        }
        // GB12 / GB13: RI x RI (odd pairs)
        if isRegionalIndicator(p) && isRegionalIndicator(currCp) {
            if breakState == .riOdd {
                breakState = .default
                return false
            }
            breakState = .riOdd
            return true
        }

        // GB999: Any ÷ Any
        if isExtendedPictographic(currCp) {
            breakState = .epExtend
        } else if isRegionalIndicator(currCp) {
            breakState = .riOdd
        } else if isIndicConsonant(currCp) {
            breakState = .incbConsonant
        } else {
            breakState = .default
        }
        return true
    }

    // parity: native/src/utf8.zig#walkChunkLayoutInfoComptime [status=implemented hash=64ee29a03772]
    public static func walkChunkLayoutInfoComptime(
        _ bytes: [UInt8],
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        isASCIIOnly: Bool? = nil,
        widthMethod: WidthMethod = .unicode,
        callback: (LayoutWrapBreak) throws -> Bool
    ) rethrows -> WordClassEdges {
        let ascii = isASCIIOnly ?? isAsciiOnly(bytes)
        if ascii {
            NativeTextWork.add(.asciiBytes, bytes.count)
        } else {
            NativeTextWork.add(.bytesScanned, bytes.count)
        }
        guard !bytes.isEmpty else {
            return WordClassEdges(first: .other, last: .other, hasCjkBreaks: false)
        }
        let info = findChunkLayoutInfo(
            bytes,
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            isASCIIOnly: ascii,
            widthMethod: widthMethod
        )
        for wb in info.wrapBreaks {
            if try !callback(wb) {
                break
            }
        }
        return info.wordClasses
    }
}

// MARK: - 7. native/src/encoded-unicode.zig (2 symbols)

public enum NativeEncodedUnicode: Sendable {
    public enum EncodeError: Swift.Error, Equatable, Hashable, Sendable {
        case invalidUtf8
        case trackerLimit
        case outOfMemory
    }

    // parity: native/src/encoded-unicode.zig#EncodedChar [status=implemented hash=154b08ba56e7]
    public struct EncodedChar: Equatable, Hashable, Sendable {
        public var width: UInt8
        public var char: UInt32

        public init(width: UInt8, char: UInt32) {
            self.width = width
            self.char = char
        }
    }

    // parity: native/src/encoded-unicode.zig#EncodedUnicode [status=implemented hash=540df14b764f]
    public final class EncodedUnicode: @unchecked Sendable {
        public private(set) var chars: [EncodedChar]

        private init(chars: [EncodedChar]) {
            self.chars = chars
        }

        public static func create(
            pool: GraphemePool,
            text: [UInt8],
            widthMethod: WidthMethod = .unicode
        ) throws(EncodeError) -> EncodedUnicode {
            guard isValidUtf8(text) else {
                throw .invalidUtf8
            }
            let tabWidth: UInt8 = 2
            let clusters = findRenderClusterInfo(
                text,
                tabWidth: tabWidth,
                controlDisplay: .hidden,
                isASCIIOnly: isAsciiOnly(text),
                widthMethod: widthMethod
            )
            var result: [EncodedChar] = []
            result.reserveCapacity(text.count)

            var byteOffset = 0
            var clusterIndex = 0
            do {
                while byteOffset < text.count {
                    let start = byteOffset
                    if clusterIndex < clusters.count && Int(clusters[clusterIndex].byteStart) == start {
                        byteOffset += Int(clusters[clusterIndex].byteLen)
                        clusterIndex += 1
                    } else {
                        let dec = NativeUtf8Extras.decodeUtf8Unchecked(text, at: start)
                        byteOffset += Int(dec.len)
                    }
                    let slice = Array(text[start..<byteOffset])
                    let width = getGraphemeWidthAt(
                        slice,
                        byteOffset: 0,
                        tabWidth: tabWidth,
                        controlDisplay: .hidden,
                        widthMethod: widthMethod
                    )
                    if width == 0 { continue }
                    if !isPrintableGlyph(slice, width: width) {
                        for _ in 0..<width {
                            result.append(EncodedChar(width: 1, char: defaultSpaceChar))
                        }
                        continue
                    }
                    let encodedChar: UInt32
                    if slice.count == 1 && width == 1 {
                        encodedChar = UInt32(slice[0])
                    } else {
                        let gid = try pool.acquire(slice)
                        encodedChar = packGraphemeStart(gid: gid, totalWidth: width)
                    }
                    result.append(EncodedChar(width: UInt8(clamping: width), char: encodedChar))
                }
            } catch let poolErr {
                Self.releaseChars(pool: pool, chars: result)
                switch poolErr {
                case .refcountOverflow: throw .trackerLimit
                case .outOfMemory, .graphemeTooLong, .invalidId, .wrongGeneration: throw .outOfMemory
                }
            }
            return EncodedUnicode(chars: result)
        }

        public static func create(
            pool: GraphemePool,
            text: String,
            widthMethod: WidthMethod = .unicode
        ) throws(EncodeError) -> EncodedUnicode {
            try create(pool: pool, text: Array(text.utf8), widthMethod: widthMethod)
        }

        public func release(pool: GraphemePool) {
            Self.releaseChars(pool: pool, chars: chars)
            chars.removeAll(keepingCapacity: false)
        }

        private static func releaseChars(pool: GraphemePool, chars: [EncodedChar]) {
            for cell in chars where isGraphemeChar(cell.char) {
                try? pool.decref(graphemeIdFromChar(cell.char))
            }
        }
    }
}

// MARK: - 8. native/src/edit-marks.zig (8 symbols)

public enum NativeEditMarks: Sendable {
    // parity: native/src/edit-marks.zig#count_max [status=implemented hash=0c8471a025d5]
    public static let countMax: Int = 65_536

    // parity: native/src/edit-marks.zig#Mark [status=implemented hash=4aa15d46b87d]
    public struct Mark: Equatable, Hashable, Sendable, Codable {
        public var id: UInt32
        public var kind: UInt32
        public var style: UInt32
        public var startByte: UInt32
        public var endByte: UInt32
        public var priority: UInt32
        public var atomic: Bool
        public var styleValue: Bool

        public init(
            id: UInt32,
            kind: UInt32 = 0,
            style: UInt32 = 0,
            startByte: UInt32,
            endByte: UInt32,
            priority: UInt32 = 0,
            atomic: Bool = false,
            styleValue: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.style = style
            self.startByte = startByte
            self.endByte = endByte
            self.priority = priority
            self.atomic = atomic
            self.styleValue = styleValue
        }

        public var styled: Bool {
            style != 0 || styleValue
        }

        /// Moves the mark for `end - start` bytes deleted at `start`. Returns whether it survives.
        public mutating func deleted(start: UInt32, end: UInt32) -> Bool {
            if start == end || endByte <= start { return true }
            let count = end - start
            if startByte >= end {
                startByte -= count
                endByte -= count
                return true
            }
            if atomic || (startByte >= start && endByte <= end) {
                return false
            }
            endByte = endByte > end ? endByte - count : start
            startByte = min(startByte, start)
            return true
        }

        /// Moves the mark for `count` bytes inserted at `at`. Returns whether it survives.
        public mutating func inserted(at: UInt32, count: UInt32) -> Bool {
            if count == 0 || endByte <= at { return true }
            if startByte >= at {
                startByte &+= count
                endByte &+= count
                return true
            }
            if atomic { return false }
            endByte &+= count
            return true
        }
    }

    public typealias AuxHandle = UInt64

    /// Pure-Swift version arena backing persistent `AuxHandle` mark sets (0 is the empty set).
    public final class Arena: @unchecked Sendable {
        private let versions = Mutex<[AuxHandle: [Mark]]>([:])
        private let nextHandle = Atomic<AuxHandle>(1)

        public init() {}

        fileprivate func publish(_ marks: [Mark]) -> AuxHandle {
            if marks.isEmpty { return 0 }
            let sorted = marks.sorted(by: NativeEditMarks.lessThan)
            let handle = nextHandle.wrappingAdd(1, ordering: .relaxed).oldValue
            versions.withLock { $0[handle] = sorted }
            return handle
        }

        fileprivate func read(_ aux: AuxHandle) -> [Mark] {
            if aux == 0 { return [] }
            return versions.withLock { $0[aux] ?? [] }
        }

        fileprivate func write(aux: AuxHandle, owned: Bool, _ mutate: (inout [Mark]) -> Void) -> AuxHandle {
            if owned && aux != 0 {
                return versions.withLock { map in
                    var current = map[aux] ?? []
                    mutate(&current)
                    map[aux] = current
                    return aux
                }
            }
            var copy = read(aux)
            mutate(&copy)
            let handle = nextHandle.wrappingAdd(1, ordering: .relaxed).oldValue
            versions.withLock { $0[handle] = copy }
            return handle
        }

        fileprivate func clearInPlace(_ aux: AuxHandle) {
            versions.withLock { $0[aux] = [] }
        }
    }

    internal static func lessThan(_ a: Mark, _ b: Mark) -> Bool {
        if a.startByte != b.startByte { return a.startByte < b.startByte }
        return a.id < b.id
    }

    // parity: native/src/edit-marks.zig#live [status=implemented hash=ca849c919a62]
    public static func live(_ arena: Arena, aux: AuxHandle) -> [Mark] {
        arena.read(aux)
    }

    // parity: native/src/edit-marks.zig#splice [status=implemented hash=742705cc4e2b]
    public static func splice(
        _ arena: Arena,
        aux: AuxHandle,
        start: UInt32,
        deleted: UInt32,
        inserted: UInt32
    ) -> AuxHandle? {
        let marks = live(arena, aux: aux)
        var anyAffected = false
        for mark in marks where mark.endByte > start {
            anyAffected = true
            break
        }
        if !anyAffected { return nil }
        var next: [Mark] = []
        next.reserveCapacity(marks.count)
        for var mark in marks {
            if mark.deleted(start: start, end: start &+ deleted)
                && mark.inserted(at: start, count: inserted)
            {
                next.append(mark)
            }
        }
        return arena.publish(next)
    }

    // parity: native/src/edit-marks.zig#add [status=implemented hash=905ddbe3f4e4]
    public static func add(_ arena: Arena, aux: AuxHandle, owned: Bool, mark: Mark) -> AuxHandle {
        precondition(live(arena, aux: aux).count < countMax, "Edit mark count limit reached")
        return arena.write(aux: aux, owned: owned) { list in
            // Upper bound insertion matching Zig's std.sort.upperBound
            var low = 0
            var high = list.count
            while low < high {
                let mid = low + (high - low) / 2
                if lessThan(mark, list[mid]) {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            list.insert(mark, at: low)
        }
    }

    // parity: native/src/edit-marks.zig#remove [status=implemented hash=230d2982c275]
    public static func remove(_ arena: Arena, aux: AuxHandle, owned: Bool, id: UInt32) -> AuxHandle? {
        let current = live(arena, aux: aux)
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return arena.write(aux: aux, owned: owned) { list in
            list.remove(at: index)
        }
    }

    // parity: native/src/edit-marks.zig#clear [status=implemented hash=65adde30397d]
    public static func clear(_ arena: Arena, aux: AuxHandle, owned: Bool) -> AuxHandle {
        if !owned || aux == 0 { return 0 }
        arena.clearInPlace(aux)
        return aux
    }

    public static func isValid(_ arena: Arena, aux: AuxHandle, byteCount: UInt32) -> Bool {
        let marks = live(arena, aux: aux)
        for i in 0..<marks.count {
            let mark = marks[i]
            if mark.startByte > mark.endByte || mark.endByte > byteCount { return false }
            if i > 0 && !lessThan(marks[i - 1], mark) { return false }
        }
        return true
    }

    // parity: native/src/edit-marks.zig#assertValid [status=implemented hash=ab91362b2d01]
    public static func assertValid(_ arena: Arena, aux: AuxHandle, byteCount: UInt32) {
        assert(isValid(arena, aux: aux, byteCount: byteCount), "Edit marks invariant violated")
    }
}

// MARK: - 9. native/src/highlight-layers.zig (12 symbols)

public enum NativeHighlightLayers: Sendable {
    // parity: native/src/highlight-layers.zig#layer_count_max [status=implemented hash=f98d9d3cb01e]
    public static let layerCountMax: Int = 4

    // parity: native/src/highlight-layers.zig#group_set_count_max [status=implemented hash=b04a83723853]
    public static let groupSetCountMax: Int = 4096

    // parity: native/src/highlight-layers.zig#group_set_name_count_max [status=implemented hash=77a84caac4b5]
    public static let groupSetNameCountMax: Int = 16

    // parity: native/src/highlight-layers.zig#group_set_name_byte_count_max [status=implemented hash=4b4e45e36cfc]
    public static let groupSetNameByteCountMax: Int = 64

    // parity: native/src/highlight-layers.zig#group_set_pool_byte_count_max [status=implemented hash=fee5719db499]
    public static let groupSetPoolByteCountMax: Int = 64 * 1024

    // parity: native/src/highlight-layers.zig#Error [status=implemented hash=32f71f61e5ff]
    public enum HighlightLayerError: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidIndex
        case invalidId
        case layerLimit
        case groupSetLimit
    }

    // parity: native/src/highlight-layers.zig#GroupSets [status=implemented hash=1070bd2a45b2]
    public struct GroupSets: Equatable, Sendable {
        private var nameBytes: [UInt8] = []
        private var nameEndBytes: [UInt32] = []
        private var setNameEnds: [UInt32] = []

        public init() {}

        public var count: UInt32 {
            UInt32(setNameEnds.count)
        }

        public var poolByteCount: Int {
            nameBytes.count
        }

        public func nameCount(id: UInt32) -> UInt32 {
            precondition(id != 0 && id <= count)
            let idx = Int(id)
            let first = idx == 1 ? 0 : setNameEnds[idx - 2]
            return setNameEnds[idx - 1] - first
        }

        public func name(id: UInt32, index: UInt32) -> [UInt8] {
            precondition(index < nameCount(id: id))
            let idx = Int(id)
            let firstName = Int(idx == 1 ? 0 : setNameEnds[idx - 2]) + Int(index)
            let start = firstName == 0 ? 0 : Int(nameEndBytes[firstName - 1])
            let end = Int(nameEndBytes[firstName])
            return Array(nameBytes[start..<end])
        }

        public func nameString(id: UInt32, index: UInt32) -> String {
            String(decoding: name(id: id, index: index), as: UTF8.self)
        }

        public mutating func intern(_ names: [[UInt8]]) throws(HighlightLayerError) -> UInt32 {
            if names.isEmpty { throw .invalidIndex }
            if names.count > groupSetNameCountMax { throw .groupSetLimit }
            var byteCount = 0
            for value in names {
                if value.isEmpty { throw .invalidIndex }
                if value.count > groupSetNameByteCountMax { throw .groupSetLimit }
                if !isValidUtf8(value) { throw .invalidIndex }
                byteCount += value.count
            }
            if let existing = find(names) {
                return existing
            }
            if Int(count) >= groupSetCountMax { throw .groupSetLimit }
            if nameBytes.count + byteCount > groupSetPoolByteCountMax { throw .groupSetLimit }

            nameBytes.reserveCapacity(nameBytes.count + byteCount)
            nameEndBytes.reserveCapacity(nameEndBytes.count + names.count)
            setNameEnds.reserveCapacity(setNameEnds.count + 1)

            for value in names {
                nameBytes.append(contentsOf: value)
                nameEndBytes.append(UInt32(nameBytes.count))
            }
            setNameEnds.append(UInt32(nameEndBytes.count))
            return count
        }

        public mutating func intern(_ names: [String]) throws(HighlightLayerError) -> UInt32 {
            try intern(names.map { Array($0.utf8) })
        }

        private func find(_ names: [[UInt8]]) -> UInt32? {
            guard count > 0 else { return nil }
            for id in 1...count {
                if Int(nameCount(id: id)) != names.count { continue }
                var matched = true
                for (i, value) in names.enumerated() {
                    if name(id: id, index: UInt32(i)) != value {
                        matched = false
                        break
                    }
                }
                if matched { return id }
            }
            return nil
        }
    }

    // parity: native/src/highlight-layers.zig#compose [status=implemented hash=3a90d1204571]
    public static func compose(
        style: NativeZigSyntaxStyle.SyntaxStyle,
        sets: GroupSets,
        id: UInt32
    ) -> NativeZigSyntaxStyle.StyleDefinition {
        let strikeBit = UInt8(TextAttributes.strikethrough & 0xFF)
        var result = NativeZigSyntaxStyle.StyleDefinition(
            fg: nil,
            bg: nil,
            attributes: 0,
            suppliedAttributes: 0
        )
        let n = sets.nameCount(id: id)
        for i in 0..<n {
            let value = sets.nameString(id: id, index: i)
            let emptyDef = NativeZigSyntaxStyle.StyleDefinition(
                fg: nil,
                bg: nil,
                attributes: 0,
                suppliedAttributes: 0
            )
            var definition: NativeZigSyntaxStyle.StyleDefinition
            if let direct = style.getStyleByName(value) {
                definition = direct
            } else if let dot = value.firstIndex(of: ".") {
                let prefix = String(value[..<dot])
                definition = style.getStyleByName(prefix) ?? emptyDef
            } else {
                definition = emptyDef
            }
            if value == "markup.strikethrough" && (definition.suppliedAttributes & strikeBit) == 0 {
                definition.attributes |= UInt32(strikeBit)
                definition.suppliedAttributes |= strikeBit
            }
            if let fg = definition.fg { result.fg = fg }
            if let bg = definition.bg { result.bg = bg }
            result.attributes = (result.attributes & ~UInt32(definition.suppliedAttributes))
                | (definition.attributes & UInt32(definition.suppliedAttributes))
            result.suppliedAttributes |= definition.suppliedAttributes
        }
        return result
    }

    // parity: native/src/highlight-layers.zig#suppliesNothing [status=implemented hash=89e76e972093]
    public static func suppliesNothing(_ definition: NativeZigSyntaxStyle.StyleDefinition) -> Bool {
        definition.fg == nil && definition.bg == nil && definition.suppliedAttributes == 0
    }

    // parity: native/src/highlight-layers.zig#LayerRun [status=implemented hash=28e48896c8c8]
    public struct LayerRun: Equatable, Hashable, Sendable, Codable {
        public var startByte: UInt32
        public var endByte: UInt32
        public var groupSet: UInt32
        public var linkId: UInt32

        public init(startByte: UInt32, endByte: UInt32, groupSet: UInt32, linkId: UInt32 = 0) {
            self.startByte = startByte
            self.endByte = endByte
            self.groupSet = groupSet
            self.linkId = linkId
        }
    }

    // parity: native/src/highlight-layers.zig#Layer [status=implemented hash=57e05f969454]
    public struct Layer: Equatable, Hashable, Sendable {
        public var layerId: UInt32
        public var runs: [LayerRun]

        public init(layerId: UInt32, runs: [LayerRun] = []) {
            self.layerId = layerId
            self.runs = runs
        }
    }

    // parity: native/src/highlight-layers.zig#Layers [status=implemented hash=82f420fb96e3]
    public struct Layers: Equatable, Sendable {
        private var items: [Layer] = []

        public init() {}

        public var slice: [Layer] { items }

        public var count: Int { items.count }

        public var isEmpty: Bool { items.isEmpty }

        public func runsOf(_ layerId: UInt32) -> [LayerRun] {
            let found = position(layerId)
            return found.exists ? items[found.index].runs : []
        }

        @discardableResult
        public mutating func set(
            linkPool: LinkPool,
            layerId: UInt32,
            startByte: UInt32,
            endByte: UInt32,
            runs: [LayerRun]
        ) throws(HighlightLayerError) -> Bool {
            var spare: [LayerRun]? = nil
            return try setWithSpare(
                linkPool: linkPool,
                layerId: layerId,
                startByte: startByte,
                endByte: endByte,
                runs: runs,
                spare: &spare
            )
        }

        @discardableResult
        public mutating func setWithSpare(
            linkPool: LinkPool,
            layerId: UInt32,
            startByte: UInt32,
            endByte: UInt32,
            runs: [LayerRun],
            spare: inout [LayerRun]?
        ) throws(HighlightLayerError) -> Bool {
            if startByte > endByte { throw .invalidIndex }
            var previousEnd = startByte
            for run in runs {
                if run.startByte < previousEnd || run.startByte >= run.endByte || run.endByte > endByte {
                    throw .invalidIndex
                }
                previousEnd = run.endByte
            }
            if startByte == endByte { return false }

            let found = position(layerId)
            let old: [LayerRun] = found.exists ? items[found.index].runs : []
            let first = Self.firstEndingAfter(old, byte: startByte)
            var last = first
            while last < old.count && old[last].startByte < endByte {
                last += 1
            }

            let keepHead = first < old.count && old[first].startByte < startByte
            let keepTail = last > first && old[last - 1].endByte > endByte
            let split = keepHead && keepTail && (last - first == 1)

            var middle: [LayerRun] = []
            middle.reserveCapacity((keepHead ? 1 : 0) + runs.count + (keepTail ? 1 : 0))
            if keepHead {
                middle.append(LayerRun(
                    startByte: old[first].startByte,
                    endByte: startByte,
                    groupSet: old[first].groupSet,
                    linkId: old[first].linkId
                ))
            }
            middle.append(contentsOf: runs)
            if keepTail {
                middle.append(LayerRun(
                    startByte: endByte,
                    endByte: old[last - 1].endByte,
                    groupSet: old[last - 1].groupSet,
                    linkId: old[last - 1].linkId
                ))
            }

            let shared = min(last - first, middle.count)
            var sameHead = 0
            while sameHead < shared && old[first + sameHead] == middle[sameHead] {
                sameHead += 1
            }
            var sameTail = 0
            while sameHead + sameTail < shared
                && old[last - 1 - sameTail] == middle[middle.count - 1 - sameTail]
            {
                sameTail += 1
            }
            let removed = (last - first) - sameHead - sameTail
            let added = middle.count - sameHead - sameTail
            if removed == 0 && added == 0 { return false }

            let resultLen = old.count - removed + added
            if resultLen > 0 && !found.exists && items.count >= layerCountMax {
                throw .layerLimit
            }

            // Acquire link references transactionally before mutating state
            var acquired = 0
            for run in runs {
                if run.linkId != 0 {
                    do {
                        try linkPool.incref(run.linkId)
                    } catch {
                        for k in 0..<acquired where runs[k].linkId != 0 {
                            try? linkPool.decref(runs[k].linkId)
                        }
                        throw .invalidId
                    }
                }
                acquired += 1
            }
            let splitLink = split ? old[first].linkId : 0
            if splitLink != 0 {
                do {
                    try linkPool.incref(splitLink)
                } catch {
                    for k in 0..<acquired where runs[k].linkId != 0 {
                        try? linkPool.decref(runs[k].linkId)
                    }
                    throw .invalidId
                }
            }

            // Release references for runs wholly inside the replaced range
            for idx in first..<last {
                let kept = (idx == first && keepHead) || (idx == last - 1 && keepTail)
                if !kept && old[idx].linkId != 0 {
                    try? linkPool.decref(old[idx].linkId)
                }
            }

            var next: [LayerRun]
            if var reusable = spare, reusable.capacity >= resultLen {
                reusable.removeAll(keepingCapacity: true)
                spare = nil
                next = reusable
            } else {
                next = []
                next.reserveCapacity(resultLen)
            }
            next.append(contentsOf: old[0..<first])
            next.append(contentsOf: middle)
            next.append(contentsOf: old[last..<old.count])
            NativeTextWork.add(.layerRunsCopied, resultLen)

            if found.exists {
                if spare != nil && spare!.capacity == 0 {
                    var recycled = items[found.index].runs
                    recycled.removeAll(keepingCapacity: true)
                    spare = recycled
                }
                if next.isEmpty {
                    items.remove(at: found.index)
                } else {
                    items[found.index].runs = next
                }
            } else if !next.isEmpty {
                items.insert(Layer(layerId: layerId, runs: next), at: found.index)
            }
            return true
        }

        public mutating func insertBytes(atByte: UInt32, byteCount: UInt32) {
            precondition(byteCount > 0)
            for li in 0..<items.count {
                for ri in 0..<items[li].runs.count {
                    if items[li].runs[ri].startByte >= atByte {
                        items[li].runs[ri].startByte &+= byteCount
                        items[li].runs[ri].endByte &+= byteCount
                    } else if items[li].runs[ri].endByte > atByte {
                        items[li].runs[ri].endByte &+= byteCount
                    }
                }
            }
        }

        public mutating func deleteBytes(linkPool: LinkPool, startByte: UInt32, endByte: UInt32) {
            precondition(startByte <= endByte)
            guard startByte < endByte else { return }
            let byteCount = endByte - startByte
            var li = items.count
            while li > 0 {
                li -= 1
                var kept: [LayerRun] = []
                kept.reserveCapacity(items[li].runs.count)
                for run in items[li].runs {
                    let clippedStart = Self.clip(run.startByte, startByte: startByte, endByte: endByte, byteCount: byteCount)
                    let clippedEnd = Self.clip(run.endByte, startByte: startByte, endByte: endByte, byteCount: byteCount)
                    if clippedStart >= clippedEnd {
                        if run.linkId != 0 {
                            try? linkPool.decref(run.linkId)
                        }
                        continue
                    }
                    kept.append(LayerRun(
                        startByte: clippedStart,
                        endByte: clippedEnd,
                        groupSet: run.groupSet,
                        linkId: run.linkId
                    ))
                }
                if kept.isEmpty {
                    items.remove(at: li)
                } else {
                    items[li].runs = kept
                }
            }
        }

        public mutating func reset(linkPool: LinkPool) {
            for layer in items {
                for run in layer.runs where run.linkId != 0 {
                    try? linkPool.decref(run.linkId)
                }
            }
            items.removeAll(keepingCapacity: false)
        }

        public static func firstEndingAfter(_ runs: [LayerRun], byte: UInt32) -> Int {
            var low = 0
            var high = runs.count
            while low < high {
                let mid = low + (high - low) / 2
                if runs[mid].endByte <= byte {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        private func position(_ layerId: UInt32) -> (index: Int, exists: Bool) {
            for (index, layer) in items.enumerated() {
                if layer.layerId == layerId { return (index, true) }
                if layer.layerId > layerId { return (index, false) }
            }
            return (items.count, false)
        }

        private static func clip(_ byte: UInt32, startByte: UInt32, endByte: UInt32, byteCount: UInt32) -> UInt32 {
            if byte <= startByte { return byte }
            if byte >= endByte { return byte - byteCount }
            return startByte
        }
    }
}

// MARK: - 10. native/src/logger.zig (13 symbols)

// parity: native/src/logger.zig#LogLevel [status=implemented hash=9181bc3f1ff2]
public enum NativeLogLevel: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case err = 0
    case warn = 1
    case info = 2
    case debug = 3

    public static func < (lhs: NativeLogLevel, rhs: NativeLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .err: "ERROR"
        case .warn: "WARN "
        case .info: "INFO "
        case .debug: "DEBUG"
        }
    }
}

// parity: native/src/logger.zig#LogCallback [status=implemented hash=d5b319a4df68]
public typealias NativeLogCallback = @Sendable (_ level: UInt8, _ message: [UInt8]) -> Void

// parity: native/src/logger.zig#Diagnostic [status=implemented hash=d03bc833442a]
public struct NativeDiagnostic: Equatable, Hashable, Sendable {
    public static let messageBytesMax: Int = 4096

    public var level: NativeLogLevel
    public var truncated: Bool
    public var messageLen: UInt32
    public var message: [UInt8]

    public init(
        level: NativeLogLevel,
        truncated: Bool = false,
        message: [UInt8] = []
    ) {
        let clamped = Array(message.prefix(Self.messageBytesMax))
        self.level = level
        self.truncated = truncated || message.count > Self.messageBytesMax
        self.messageLen = UInt32(clamped.count)
        self.message = clamped
    }

    public var messageString: String {
        String(decoding: message, as: UTF8.self)
    }
}

// parity: native/src/logger.zig#Diagnostics [status=implemented hash=118d27889349]
public final class NativeDiagnostics: @unchecked Sendable {
    private struct State: Sendable {
        var events: [NativeDiagnostic?]
        var head: Int = 0
        var count: Int = 0
        var droppedCount: UInt64 = 0
        let capacity: Int
    }

    private let state: Mutex<State>

    /// Zero capacity disables storage but still counts dropped messages.
    public init(capacity: UInt32) {
        let cap = Int(capacity)
        self.state = Mutex(State(
            events: Array(repeating: nil, count: cap),
            capacity: cap
        ))
    }

    public var count: UInt32 {
        state.withLock { UInt32($0.count) }
    }

    public var droppedCount: UInt64 {
        state.withLock { $0.droppedCount }
    }

    public var capacity: UInt32 {
        state.withLock { UInt32($0.capacity) }
    }

    public func pop() -> NativeDiagnostic? {
        state.withLock { s in
            guard s.count > 0, s.capacity > 0 else { return nil }
            let event = s.events[s.head]
            s.events[s.head] = nil
            s.head = (s.head + 1) % s.capacity
            s.count -= 1
            return event
        }
    }

    public func logMessage(_ level: NativeLogLevel, _ message: String) {
        logBytes(level, Array(message.utf8))
    }

    public func logBytes(_ level: NativeLogLevel, _ bytes: [UInt8]) {
        state.withLock { s in
            if s.count == s.capacity {
                s.droppedCount = s.droppedCount == UInt64.max ? UInt64.max : s.droppedCount + 1
                return
            }
            let index = (s.head + s.count) % s.capacity
            let truncated = bytes.count > NativeDiagnostic.messageBytesMax
            s.events[index] = NativeDiagnostic(
                level: level,
                truncated: truncated,
                message: truncated ? Array(bytes.prefix(NativeDiagnostic.messageBytesMax)) : bytes
            )
            s.count += 1
        }
    }
}

// parity: native/src/logger.zig#Logger [status=implemented hash=d9c9c805141a]
public enum NativeLogger: Sendable {
    case callback(NativeLogCallback?)
    case diagnostics(NativeDiagnostics)
    case process

    private struct ProcessSinkState: Sendable {
        var callback: NativeLogCallback?
        var ownerToken: UInt64 = 0
        var minLevel: NativeLogLevel = .debug
    }

    private static let processState = Mutex(ProcessSinkState())

    // parity: native/src/logger.zig#processLogger [status=implemented hash=5e87da48f049]
    public static func processLogger() -> NativeLogger {
        .process
    }

    // parity: native/src/logger.zig#processLogReady [status=implemented hash=29aefc7ab5cb]
    public static func processLogReady(threadToken: UInt64 = 0) -> Bool {
        processState.withLock { s in
            s.callback != nil && s.ownerToken == threadToken
        }
    }

    // parity: native/src/logger.zig#setLogCallback [status=implemented hash=a858aea6a127]
    public static func setLogCallback(_ callback: NativeLogCallback?, threadToken: UInt64 = 0) {
        processState.withLock { s in
            s.ownerToken = threadToken
            s.callback = callback
        }
    }

    public static func setMaxLevel(_ level: NativeLogLevel) {
        processState.withLock { $0.minLevel = level }
    }

    public func logMessage(_ level: NativeLogLevel, _ message: String, threadToken: UInt64 = 0) {
        switch self {
        case .diagnostics(let queue):
            queue.logMessage(level, message)
        case .process:
            let cb: NativeLogCallback? = Self.processState.withLock { s in
                guard s.ownerToken == threadToken, level <= s.minLevel else { return nil }
                return s.callback
            }
            NativeLogger.callback(cb).logMessage(level, message, threadToken: threadToken)
        case .callback(let maybeCallback):
            guard let callback = maybeCallback else { return }
            let bytes = Array(message.utf8)
            if bytes.count > NativeDiagnostic.messageBytesMax {
                callback(NativeLogLevel.err.rawValue, Array("Log formatting failed".utf8))
                return
            }
            callback(level.rawValue, bytes)
        }
    }

    public func err(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.err, message, threadToken: threadToken)
    }

    public func warn(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.warn, message, threadToken: threadToken)
    }

    public func info(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.info, message, threadToken: threadToken)
    }

    public func debug(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.debug, message, threadToken: threadToken)
    }

    // parity: native/src/logger.zig#logMessage [status=implemented hash=f65088060d2d]
    public static func logMessage(_ level: NativeLogLevel, _ message: String, threadToken: UInt64 = 0) {
        processLogger().logMessage(level, message, threadToken: threadToken)
    }

    // parity: native/src/logger.zig#err [status=implemented hash=df6795ef4ddb]
    public static func err(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.err, message, threadToken: threadToken)
    }

    // parity: native/src/logger.zig#warn [status=implemented hash=7a87622aae88]
    public static func warn(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.warn, message, threadToken: threadToken)
    }

    // parity: native/src/logger.zig#info [status=implemented hash=7a6834098fc7]
    public static func info(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.info, message, threadToken: threadToken)
    }

    // parity: native/src/logger.zig#debug [status=implemented hash=cdb774bf101b]
    public static func debug(_ message: String, threadToken: UInt64 = 0) {
        logMessage(.debug, message, threadToken: threadToken)
    }
}

// MARK: - 11. native/src/file-logger.zig (7 symbols)

/// Pure-Swift injectable sink backing `NativeFileLogger` (no direct OS filesystem I/O in Pure Tier).
public protocol NativeFileLogSink: AnyObject, Sendable {
    func open(filename: String) -> Bool
    func write(_ bytes: [UInt8])
    func sync()
    func close()
}

/// In-memory `NativeFileLogSink` for headless testing and pure-Swift capture.
public final class MemoryFileLogSink: NativeFileLogSink, @unchecked Sendable {
    private struct State: Sendable {
        var filename: String?
        var isOpen: Bool = false
        var bytes: [UInt8] = []
        var syncCount: Int = 0
        var closeCount: Int = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func open(filename: String) -> Bool {
        state.withLock { s in
            s.filename = filename
            s.isOpen = true
            s.bytes.removeAll(keepingCapacity: true)
            return true
        }
    }

    public func write(_ bytes: [UInt8]) {
        state.withLock { s in
            guard s.isOpen else { return }
            s.bytes.append(contentsOf: bytes)
        }
    }

    public func sync() {
        state.withLock { $0.syncCount += 1 }
    }

    public func close() {
        state.withLock { s in
            s.isOpen = false
            s.closeCount += 1
        }
    }

    public var filename: String? { state.withLock { $0.filename } }
    public var isOpen: Bool { state.withLock { $0.isOpen } }
    public var syncCount: Int { state.withLock { $0.syncCount } }
    public var closeCount: Int { state.withLock { $0.closeCount } }
    public var text: String { state.withLock { String(decoding: $0.bytes, as: UTF8.self) } }
}

public enum NativeFileLogger: Sendable {
    // parity: native/src/file-logger.zig#LogLevel [status=implemented hash=9181bc3f1ff2]
    public typealias LogLevel = NativeLogLevel

    public typealias ClockMicroseconds = @Sendable () -> Int64

    private struct State: Sendable {
        var sink: (any NativeFileLogSink)?
        var clock: ClockMicroseconds = { 0 }
        var maxLevel: LogLevel = .debug
        var initialized: Bool = false
    }

    private static let state = Mutex(State())

    /// Configures the pure-Swift sink, clock, and level filter used by `NativeFileLogger`.
    public static func configure(
        sink: (any NativeFileLogSink)?,
        maxLevel: LogLevel = .debug,
        clockMicroseconds: @escaping ClockMicroseconds = { 0 }
    ) {
        state.withLock { s in
            if s.initialized {
                s.sink?.close()
                s.initialized = false
            }
            s.sink = sink
            s.maxLevel = maxLevel
            s.clock = clockMicroseconds
        }
    }

    // parity: native/src/file-logger.zig#deinit [status=adapted hash=34348ed73464]
    public static func shutdown() {
        state.withLock { s in
            if s.initialized {
                s.sink?.close()
                s.initialized = false
            }
        }
    }

    // parity: native/src/file-logger.zig#logMessage [status=adapted hash=b2ce1655eb69]
    public static func logMessage(_ level: LogLevel, _ message: String) {
        state.withLock { s in
            guard level <= s.maxLevel, let sink = s.sink else { return }
            if !s.initialized {
                let sec = s.clock() / 1_000_000
                let filename = "opentui_debug_\(sec).log"
                guard sink.open(filename: filename) else { return }
                sink.write(Array("=== Log initialized at timestamp \(sec) ===\n".utf8))
                sink.sync()
                s.initialized = true
            }
            let ts = s.clock()
            let line = "[\(ts)] \(level.label): \(message)\n"
            sink.write(Array(line.utf8))
            sink.sync()
        }
    }

    // parity: native/src/file-logger.zig#err [status=implemented hash=df6795ef4ddb]
    public static func err(_ message: String) {
        logMessage(.err, message)
    }

    // parity: native/src/file-logger.zig#warn [status=implemented hash=7a87622aae88]
    public static func warn(_ message: String) {
        logMessage(.warn, message)
    }

    // parity: native/src/file-logger.zig#info [status=implemented hash=7a6834098fc7]
    public static func info(_ message: String) {
        logMessage(.info, message)
    }

    // parity: native/src/file-logger.zig#debug [status=implemented hash=cdb774bf101b]
    public static func debug(_ message: String) {
        logMessage(.debug, message)
    }
}

// MARK: - 12. native/src/stdout-writer.zig (17 symbols)

public protocol NativeStdoutSink: Sendable {
    func write(_ bytes: ArraySlice<UInt8>) throws(NativeStdoutWriter.SinkError) -> Int
    func waitWritable()
}

public protocol NativeStdoutRunner: Sendable {
    static var threaded: Bool { get }
    var afterWriteHook: (@Sendable () -> Void)? { get }
    func waitChange(expected: NativeStdoutWriter.State, hasTimeout: Bool)
}

public enum NativeStdoutWriter: Sendable {
    /// Maximum bytes copied per hand-over (64 KiB).
    public static let handoverMax: Int = 64 * 1024

    /// Synchronized output framing sequences (DEC private mode 2026).
    public static let beginSyncOutput: [UInt8] = Array("\u{1B}[?2026h".utf8)
    public static let endSyncOutput: [UInt8] = Array("\u{1B}[?2026l".utf8)

    // parity: native/src/stdout-writer.zig#supported [status=implemented hash=d4d77b37773e]
    #if os(macOS) || os(Linux)
    public static let supported: Bool = true
    #else
    public static let supported: Bool = false
    #endif

    // parity: native/src/stdout-writer.zig#State [status=implemented hash=ea6a79c7daeb]
    public enum State: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case idle = 0
        case inFlight = 1
        case writing = 2
        case doneOk = 3
        case doneFailed = 4
        case stop = 5
    }

    // parity: native/src/stdout-writer.zig#SinkError [status=implemented hash=7896d5bfd660]
    public enum SinkError: Swift.Error, Equatable, Hashable, Sendable {
        case wouldBlock
        case interrupted
        case failed
    }

    // parity: native/src/stdout-writer.zig#Outcome [status=implemented hash=efd20a92d8e5]
    public enum Outcome: Equatable, Hashable, Sendable {
        case busy
        case written
        case failed
        case reclaimed
    }

    public enum WriterCreateError: Swift.Error, Equatable, Hashable, Sendable {
        case unsupportedResource
    }

    public enum PipeError: Swift.Error, Equatable, Hashable, Sendable {
        case pipeFailed
        case shortRead
        case timeout
    }

    public enum DeadlineError: Swift.Error, Equatable, Hashable, Sendable {
        case timeout
    }

    // parity: native/src/stdout-writer.zig#Abandon [status=implemented hash=05bc2d2209e4]
    public struct Abandon: Sendable {
        private let action: @Sendable () -> Void

        public init(_ action: @escaping @Sendable () -> Void) {
            self.action = action
        }

        public func invoke() {
            action()
        }
    }

    public static let liveThreads = Atomic<UInt32>(0)

    /// Pure-Swift in-memory pipe registry powering `FdSink`, `testPipe`, `closeAll`, and `readExactly`.
    private final class InMemoryPipeRegistry: @unchecked Sendable {
        struct Channel: Sendable {
            var buffer: [UInt8] = []
            var capacity: Int
            var readOpen: Bool = true
            var writeOpen: Bool = true
            var nonBlocking: Bool = false
        }

        struct RegistryState: Sendable {
            var nextFd: Int32 = 100
            var channels: [Int32: Channel] = [:]
            var fdToChannel: [Int32: (channelId: Int32, isWrite: Bool)] = [:]
        }

        static let shared = InMemoryPipeRegistry()
        private let state = Mutex(RegistryState())

        func makePipe(capacity: Int32) throws(PipeError) -> (readFd: Int32, writeFd: Int32) {
            guard capacity > 0 else { throw .pipeFailed }
            return state.withLock { s in
                let channelId = s.nextFd
                let readFd = s.nextFd
                let writeFd = s.nextFd + 1
                s.nextFd += 2
                s.channels[channelId] = Channel(capacity: Int(capacity))
                s.fdToChannel[readFd] = (channelId, false)
                s.fdToChannel[writeFd] = (channelId, true)
                return (readFd, writeFd)
            }
        }

        func setNonBlocking(fd: Int32, _ value: Bool) {
            state.withLock { s in
                guard let info = s.fdToChannel[fd] else { return }
                s.channels[info.channelId]?.nonBlocking = value
            }
        }

        func close(fd: Int32) {
            state.withLock { s in
                guard let info = s.fdToChannel.removeValue(forKey: fd),
                      var ch = s.channels[info.channelId]
                else { return }
                if info.isWrite {
                    ch.writeOpen = false
                } else {
                    ch.readOpen = false
                }
                if !ch.readOpen && !ch.writeOpen {
                    s.channels.removeValue(forKey: info.channelId)
                } else {
                    s.channels[info.channelId] = ch
                }
            }
        }

        func write(fd: Int32, bytes: ArraySlice<UInt8>) throws(SinkError) -> Int {
            try state.withLock { s throws(SinkError) in
                guard let info = s.fdToChannel[fd], info.isWrite,
                      var ch = s.channels[info.channelId], ch.writeOpen
                else {
                    throw .failed
                }
                if !ch.readOpen {
                    throw .failed
                }
                let room = ch.capacity - ch.buffer.count
                if room <= 0 {
                    throw .wouldBlock
                }
                let n = min(room, bytes.count)
                ch.buffer.append(contentsOf: bytes[bytes.startIndex..<bytes.index(bytes.startIndex, offsetBy: n)])
                s.channels[info.channelId] = ch
                return n
            }
        }

        func read(fd: Int32, maxCount: Int) -> (bytes: [UInt8], closed: Bool) {
            state.withLock { s in
                guard let info = s.fdToChannel[fd], !info.isWrite,
                      var ch = s.channels[info.channelId], ch.readOpen
                else {
                    return ([], true)
                }
                if ch.buffer.isEmpty {
                    return ([], !ch.writeOpen)
                }
                let n = min(maxCount, ch.buffer.count)
                let slice = Array(ch.buffer[0..<n])
                ch.buffer.removeFirst(n)
                s.channels[info.channelId] = ch
                return (slice, false)
            }
        }
    }

    // parity: native/src/stdout-writer.zig#FdSink [status=adapted hash=6510bc662e5e]
    public struct FdSink: NativeStdoutSink, Sendable {
        public let fd: Int32
        private let customWrite: (@Sendable (ArraySlice<UInt8>) throws(SinkError) -> Int)?
        private let customWaitWritable: (@Sendable () -> Void)?

        public init(
            fd: Int32,
            write: (@Sendable (ArraySlice<UInt8>) throws(SinkError) -> Int)? = nil,
            waitWritable: (@Sendable () -> Void)? = nil
        ) {
            self.fd = fd
            self.customWrite = write
            self.customWaitWritable = waitWritable
        }

        public func write(_ bytes: ArraySlice<UInt8>) throws(SinkError) -> Int {
            if let customWrite {
                return try customWrite(bytes)
            }
            return try InMemoryPipeRegistry.shared.write(fd: fd, bytes: bytes)
        }

        public func waitWritable() {
            customWaitWritable?()
        }
    }

    // parity: native/src/stdout-writer.zig#ThreadRunner [status=adapted hash=298e0deb09ff]
    public struct ThreadRunner: NativeStdoutRunner, Sendable {
        public static let threaded: Bool = true
        public let afterWriteHook: (@Sendable () -> Void)?
        /// When `true`, `start` executes synchronously on the caller's thread (deterministic portable mode).
        /// When `false`, callers drive `pick()` / `writeStep()` / `publish()` directly to test interleavings.
        public let autoDrain: Bool

        public init(
            afterWriteHook: (@Sendable () -> Void)? = nil,
            autoDrain: Bool = true
        ) {
            self.afterWriteHook = afterWriteHook
            self.autoDrain = autoDrain
        }

        public func waitChange(expected: State, hasTimeout: Bool) {}
    }

    // parity: native/src/stdout-writer.zig#Parked [status=implemented hash=cd03832ab0bf]
    public struct Parked: NativeStdoutRunner, Sendable {
        public static let threaded: Bool = false
        public let afterWriteHook: (@Sendable () -> Void)? = nil

        public init() {}

        public func waitChange(expected: State, hasTimeout: Bool) {}
    }

    // parity: native/src/stdout-writer.zig#Writer [status=adapted hash=95f4268bd033]
    public final class Writer<Sink: NativeStdoutSink, Runner: NativeStdoutRunner>: @unchecked Sendable {
        public enum Step: Equatable, Hashable, Sendable {
            case more
            case written
            case failed
        }

        private let stateWord = Atomic<UInt32>(State.idle.rawValue)
        public let sink: Sink
        public let runner: Runner
        public var buffer: [UInt8]
        public private(set) var len: UInt32 = 0
        public private(set) var done: UInt32 = 0
        public private(set) var totalBytesWritten: UInt64 = 0
        public private(set) var flushCount: UInt64 = 0
        private var ownsLiveThreadSlot: Bool = false

        private init(sink: Sink, runner: Runner) {
            self.sink = sink
            self.runner = runner
            self.buffer = Array(repeating: 0, count: handoverMax)
            if Runner.threaded {
                _ = NativeStdoutWriter.liveThreads.wrappingAdd(1, ordering: .relaxed)
                self.ownsLiveThreadSlot = true
            }
        }

        public static func create(sink: Sink, runner: Runner) throws(WriterCreateError) -> Writer<Sink, Runner> {
            Writer(sink: sink, runner: runner)
        }

        public var currentState: State {
            State(rawValue: stateWord.load(ordering: .acquiring)) ?? .stop
        }

        public func handle() -> Abandon {
            Abandon { [self] in
                self.abandon()
            }
        }

        /// Copies `bytes` into `buffer` and starts a hand-over.
        public func start(bytes: [UInt8]) {
            precondition(!bytes.isEmpty && bytes.count <= handoverMax)
            for i in 0..<bytes.count {
                buffer[i] = bytes[i]
            }
            start(UInt32(bytes.count))
        }

        /// Writes `bytes` wrapped in DEC 2026 synchronized-output framing across chunked hand-overs.
        @discardableResult
        public func writeFramed(_ bytes: [UInt8], syncOutput: Bool = true) -> Outcome {
            var payload: [UInt8] = []
            if syncOutput {
                payload.reserveCapacity(bytes.count + beginSyncOutput.count + endSyncOutput.count)
                payload.append(contentsOf: beginSyncOutput)
                payload.append(contentsOf: bytes)
                payload.append(contentsOf: endSyncOutput)
            } else {
                payload = bytes
            }
            if payload.isEmpty { return .written }
            var offset = 0
            while offset < payload.count {
                let end = min(offset + handoverMax, payload.count)
                start(bytes: Array(payload[offset..<end]))
                let outcome = waitCollect(graceNs: 1_000_000_000)
                if outcome != .written { return outcome }
                offset = end
            }
            return .written
        }

        /// Owner: the first `len` bytes of `buffer` are the copy to write.
        public func start(_ len: UInt32) {
            precondition(len > 0 && Int(len) <= handoverMax)
            precondition(currentState == .idle)
            self.len = len
            self.done = 0
            stateWord.store(State.inFlight.rawValue, ordering: .releasing)

            if let threadRunner = runner as? ThreadRunner, threadRunner.autoDrain {
                runDrainCycle()
            }
        }

        /// Owner: the result of the hand-over, once published.
        public func collect() -> Outcome {
            switch currentState {
            case .inFlight, .writing:
                return .busy
            case .doneOk:
                stateWord.store(State.idle.rawValue, ordering: .relaxed)
                flushCount &+= 1
                totalBytesWritten &+= UInt64(done)
                return .written
            case .doneFailed:
                stateWord.store(State.idle.rawValue, ordering: .relaxed)
                return .failed
            case .idle, .stop:
                preconditionFailure("collect() called in invalid state")
            }
        }

        /// Owner, at exit: waits for a running write or reclaims an unpicked `.inFlight` hand-over.
        public func waitCollect(graceNs: UInt64) -> Outcome {
            var waitedInFlight = false
            while true {
                let state = currentState
                switch state {
                case .doneOk, .doneFailed:
                    return collect()
                case .inFlight:
                    if waitedInFlight {
                        let (exchanged, _) = stateWord.compareExchange(
                            expected: State.inFlight.rawValue,
                            desired: State.stop.rawValue,
                            ordering: .acquiringAndReleasing
                        )
                        if exchanged {
                            releaseLiveSlot()
                            return .reclaimed
                        }
                        continue
                    }
                    waitedInFlight = true
                    runner.waitChange(expected: state, hasTimeout: true)
                case .writing:
                    runner.waitChange(expected: state, hasTimeout: false)
                    // If a non-threaded runner didn't advance, complete the remaining steps to avoid spinning.
                    if currentState == .writing {
                        finishActiveWrite()
                    }
                case .idle, .stop:
                    preconditionFailure("waitCollect() called in invalid state")
                }
            }
        }

        /// Owner: gives the writer up. Afterwards the owner must not use it.
        public func abandon() {
            let prevRaw = stateWord.exchange(State.stop.rawValue, ordering: .acquiringAndReleasing)
            let prev = State(rawValue: prevRaw) ?? .stop
            if prev == .writing {
                // Detached writer thread completes its in-progress step and releases when publish fails.
                return
            }
            release()
        }

        /// Owner: state is `.stop` and no thread is inside a write.
        public func release() {
            precondition(currentState == .stop)
            releaseLiveSlot()
        }

        private func releaseLiveSlot() {
            if ownsLiveThreadSlot {
                ownsLiveThreadSlot = false
                _ = NativeStdoutWriter.liveThreads.wrappingSubtract(1, ordering: .releasing)
            }
        }

        /// Worker step 1: atomically claim `.inFlight -> .writing`.
        public func pick() -> Bool {
            stateWord.compareExchange(
                expected: State.inFlight.rawValue,
                desired: State.writing.rawValue,
                ordering: .acquiringAndReleasing
            ).exchanged
        }

        /// Worker step 2: one write attempt of the remaining slice.
        public func writeStep() -> Step {
            let startIdx = Int(done)
            let endIdx = Int(len)
            let rest = buffer[startIdx..<endIdx]
            let count: Int
            do {
                count = try sink.write(rest)
            } catch let err {
                switch err {
                case .interrupted:
                    return .more
                case .wouldBlock:
                    if Runner.threaded {
                        sink.waitWritable()
                    }
                    return .more
                case .failed:
                    return .failed
                }
            }
            if count <= 0 || count > rest.count {
                return .failed
            }
            done &+= UInt32(count)
            return done == len ? .written : .more
        }

        /// Worker step 3: publish result `.writing -> .doneOk/.doneFailed`.
        /// Returns `false` if the owner abandoned the writer meanwhile.
        public func publish(written: Bool) -> Bool {
            let desired = written ? State.doneOk.rawValue : State.doneFailed.rawValue
            let exchanged = stateWord.compareExchange(
                expected: State.writing.rawValue,
                desired: desired,
                ordering: .acquiringAndReleasing
            ).exchanged
            if !exchanged {
                releaseLiveSlot()
            }
            return exchanged
        }

        /// Runs one complete worker cycle (`pick -> writeStep* -> hook -> publish`).
        public func runDrainCycle() {
            guard pick() else { return }
            finishActiveWrite()
        }

        private func finishActiveWrite() {
            var step: Step = .more
            while step == .more && currentState != .stop {
                step = writeStep()
            }
            runner.afterWriteHook?()
            _ = publish(written: step == .written)
        }
    }

    // parity: native/src/stdout-writer.zig#StdoutWriter [status=adapted hash=8ddfdaa5b859]
    public typealias StdoutWriter = Writer<FdSink, ThreadRunner>

    // parity: native/src/stdout-writer.zig#pinLibrary [status=adapted hash=21991db784e1]
    public static func pinLibrary() -> Bool {
        supported
    }

    // parity: native/src/stdout-writer.zig#stdoutSupported [status=adapted hash=9adae8061125]
    public static func stdoutSupported(isTTY: Bool = false) -> Bool {
        supported && isTTY
    }

    // parity: native/src/stdout-writer.zig#testPipe [status=adapted hash=43026e067559]
    public static func testPipe(capacity: Int32) throws(PipeError) -> (readFd: Int32, writeFd: Int32) {
        try InMemoryPipeRegistry.shared.makePipe(capacity: capacity)
    }

    public static func setPipeNonBlocking(fd: Int32, _ nonBlocking: Bool) {
        InMemoryPipeRegistry.shared.setNonBlocking(fd: fd, nonBlocking)
    }

    public static func closeFd(_ fd: Int32) {
        InMemoryPipeRegistry.shared.close(fd: fd)
    }

    // parity: native/src/stdout-writer.zig#closeAll [status=adapted hash=e10ab46814cf]
    public static func closeAll(_ fds: (Int32, Int32)) {
        InMemoryPipeRegistry.shared.close(fd: fds.0)
        InMemoryPipeRegistry.shared.close(fd: fds.1)
    }

    // parity: native/src/stdout-writer.zig#readExactly [status=adapted hash=a75ad5bbf95a]
    public static func readExactly(fd: Int32, count: Int, deadline: Deadline = Deadline()) throws(PipeError) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let (chunk, closed) = InMemoryPipeRegistry.shared.read(fd: fd, maxCount: count - out.count)
            if !chunk.isEmpty {
                out.append(contentsOf: chunk)
                continue
            }
            if closed {
                throw .shortRead
            }
            do {
                try deadline.check()
            } catch {
                throw .timeout
            }
        }
        return out
    }

    // parity: native/src/stdout-writer.zig#Deadline [status=adapted hash=1055119c8f3a]
    public struct Deadline: Sendable {
        public let endNs: UInt64
        private let nowNs: @Sendable () -> UInt64

        public init(
            timeoutNs: UInt64 = 10_000_000_000,
            clock: (@Sendable () -> UInt64)? = nil
        ) {
            let clockFn: @Sendable () -> UInt64 = clock ?? {
                let instant = ContinuousClock.now
                let duration = ContinuousClock.Instant.now.duration(to: instant)
                _ = duration
                let components = (ContinuousClock.now - Self.epoch).components
                let secs = UInt64(max(0, components.seconds))
                let nanos = UInt64(max(0, components.attoseconds / 1_000_000_000))
                return secs &* 1_000_000_000 &+ nanos
            }
            self.nowNs = clockFn
            let start = clockFn()
            self.endNs = start > UInt64.max - timeoutNs ? UInt64.max : start + timeoutNs
        }

        private static let epoch = ContinuousClock.now

        public func check() throws(DeadlineError) {
            if nowNs() > endNs {
                throw .timeout
            }
        }
    }

    // parity: native/src/stdout-writer.zig#waitThreadsGone [status=adapted hash=6e96c3c1de74]
    public static func waitThreadsGone(deadline: Deadline = Deadline()) throws(DeadlineError) {
        while liveThreads.load(ordering: .acquiring) != 0 {
            try deadline.check()
        }
    }
}

// MARK: - 13. native/src/kitty-transport.zig (6 symbols)

/// Pure-Swift injectable file lease storage for `NativeKittyTransport`.
public protocol NativeKittyFileStore: AnyObject, Sendable {
    func createFile(path: String, payload: [UInt8]) -> Bool
    func deleteFile(path: String) -> NativeKittyFileDeleteResult
}

public enum NativeKittyFileDeleteResult: Equatable, Hashable, Sendable {
    case deleted
    case notFound
    case failed
}

/// In-memory `NativeKittyFileStore` for portable headless Kitty file-transport operation & tests.
public final class MemoryKittyFileStore: NativeKittyFileStore, @unchecked Sendable {
    private struct State: Sendable {
        var files: [String: [UInt8]] = [:]
        var failCreate: Bool = false
        var failDeletePaths: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    public func setFailCreate(_ fail: Bool) {
        state.withLock { $0.failCreate = fail }
    }

    public func setFailDelete(path: String, fail: Bool) {
        state.withLock { s in
            if fail { s.failDeletePaths.insert(path) } else { s.failDeletePaths.remove(path) }
        }
    }

    public func createFile(path: String, payload: [UInt8]) -> Bool {
        state.withLock { s in
            if s.failCreate || s.files[path] != nil { return false }
            s.files[path] = payload
            return true
        }
    }

    public func deleteFile(path: String) -> NativeKittyFileDeleteResult {
        state.withLock { s in
            if s.failDeletePaths.contains(path) { return .failed }
            if s.files.removeValue(forKey: path) != nil { return .deleted }
            return .notFound
        }
    }

    public func storedPaths() -> [String] {
        state.withLock { Array($0.files.keys).sorted() }
    }

    public func payload(at path: String) -> [UInt8]? {
        state.withLock { $0.files[path] }
    }
}

public enum NativeKittyTransport: Sendable {
    // parity: native/src/kitty-transport.zig#Mode [status=implemented hash=ff208b4453b1]
    public enum Mode: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case raw = 0
        case zlib = 1
        case file = 2
    }

    // parity: native/src/kitty-transport.zig#FileState [status=implemented hash=b3e031e05131]
    public enum FileState: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case disabled = 0
        case probing = 1
        case ready = 2
        case unsupported = 3
        case timeout = 4
        case ioError = 5
        case cancelled = 6
    }

    // parity: native/src/kitty-transport.zig#Fallback [status=implemented hash=df28c8315aec]
    public enum Fallback: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case none = 0
        case notReady = 1
        case unavailable = 2
        case budget = 3
        case busy = 4
        case preparation = 5
        case compression = 6
    }

    // parity: native/src/kitty-transport.zig#LEASES_MAX [status=implemented hash=ec4232db5d31]
    public static let leasesMax: Int = 8

    // parity: native/src/kitty-transport.zig#BYTES_MAX [status=implemented hash=80709168557a]
    public static let bytesMax: Int = NativeZigTerminalImage.KITTY_PREPARE_BYTES_MAX

    public static let timeoutNs: UInt64 = 5_000_000_000

    public enum LeaseError: Swift.Error, Equatable, Hashable, Sendable {
        case unsupported
        case invalidDirectory
        case budget
        case busy
        case ioFailed
    }

    private struct Lease: Equatable, Sendable {
        var id: UInt32 = 0
        var path: String = ""
        var size: Int = 0
        var deadlineNs: UInt64? = nil
        var unpublished: Bool = false

        var isActive: Bool { !path.isEmpty }

        mutating func release(store: any NativeKittyFileStore) {
            guard isActive else { return }
            switch store.deleteFile(path: path) {
            case .deleted, .notFound:
                self = Lease()
            case .failed:
                // Keep failed unlinks accounted for and retry on the next expiry/teardown.
                break
            }
        }
    }

    // parity: native/src/kitty-transport.zig#Transport [status=adapted hash=820adffaffea]
    public final class Transport: @unchecked Sendable {
        public let fileStore: any NativeKittyFileStore
        public var mode: Mode = .raw
        public private(set) var effective: NativeZigTerminalImage.KittyEncoding = .raw
        public var fileState: FileState = .disabled
        public private(set) var fallback: Fallback = .none
        public private(set) var queryId: UInt32 = 0
        public private(set) var uploadProbeId: UInt32 = 0
        public private(set) var queryOk: Bool = false
        public private(set) var uploadOk: Bool = false
        public var retryImages: Bool = false

        private var leases: [Lease] = Array(repeating: Lease(), count: leasesMax)
        private var nonceCounter: UInt64 = 1

        public init(fileStore: any NativeKittyFileStore = MemoryKittyFileStore(), mode: Mode = .raw) {
            self.fileStore = fileStore
            self.mode = mode
        }

        public func pendingBytes() -> Int {
            var bytes = 0
            for lease in leases { bytes += lease.size }
            return bytes
        }

        public func pendingCount() -> UInt32 {
            var count: UInt32 = 0
            for lease in leases where lease.isActive { count += 1 }
            return count
        }

        public func cancel(reason: FileState) {
            retryImages = retryImages || fileState == .ready
            for i in 0..<leases.count {
                leases[i].release(store: fileStore)
            }
            if mode == .file || fileState != .disabled {
                fileState = pendingCount() == 0 ? reason : .ioError
            }
        }

        /// Release new leases of a skipped frame; a published frame keeps them until ACK or expiry.
        public func finishFrame(published: Bool) {
            for i in 0..<leases.count {
                if leases[i].unpublished && !published {
                    leases[i].release(store: fileStore)
                }
                leases[i].unpublished = false
            }
        }

        /// Release the new lease of an upload that a published frame left out.
        public func discard(id: UInt32) {
            for i in 0..<leases.count {
                if leases[i].unpublished && leases[i].id == id {
                    leases[i].release(store: fileStore)
                }
            }
        }

        /// Arm new leases without releasing files referenced by an encoded frame.
        /// Clamps at `UInt64.max` so deadlines never wrap.
        public func arm(nowNs: UInt64) {
            for i in 0..<leases.count {
                if leases[i].isActive && leases[i].deadlineNs == nil {
                    let deadline = nowNs > UInt64.max - timeoutNs ? UInt64.max : nowNs + timeoutNs
                    leases[i].deadlineNs = deadline
                }
            }
        }

        /// Arm new leases and cancel with `.timeout` if any active lease reached its deadline.
        public func expire(nowNs: UInt64) {
            arm(nowNs: nowNs)
            for lease in leases {
                guard lease.isActive, let deadline = lease.deadlineNs else { continue }
                if nowNs >= deadline {
                    cancel(reason: .timeout)
                    return
                }
            }
        }

        private func createLease(
            id: UInt32,
            payload: [UInt8],
            directory: String
        ) throws(LeaseError) -> Int {
            #if os(Windows)
            throw .unsupported
            #else
            guard directory.hasPrefix("/") else {
                throw .invalidDirectory
            }
            let size = payload.count
            guard size <= bytesMax - pendingBytes() else {
                throw .budget
            }
            var slotIndex: Int? = nil
            for i in 0..<leases.count {
                if leases[i].isActive && leases[i].id == id {
                    throw .busy
                }
                if !leases[i].isActive {
                    slotIndex = i
                }
            }
            guard let slot = slotIndex else {
                throw .budget
            }
            let nonce = nonceCounter
            nonceCounter &+= 1
            let hex = Self.hexToken(nonce: nonce, id: id)
            let path = "\(directory)/opentui-kitty-\(hex)"
            guard fileStore.createFile(path: path, payload: payload) else {
                throw .ioFailed
            }
            leases[slot] = Lease(id: id, path: path, size: size, deadlineNs: nil, unpublished: false)
            return slot
            #endif
        }

        private static func hexToken(nonce: UInt64, id: UInt32) -> String {
            let digits = Array("0123456789abcdef".utf8)
            var out: [UInt8] = []
            out.reserveCapacity(24)
            for shift in stride(from: 60, through: 0, by: -4) {
                out.append(digits[Int((nonce >> shift) & 0xF)])
            }
            for shift in stride(from: 28, through: 0, by: -4) {
                out.append(digits[Int((id >> shift) & 0xF)])
            }
            return String(decoding: out, as: UTF8.self)
        }

        private static func formatReference(
            path: String,
            width: UInt32,
            height: UInt32,
            format: UInt32,
            id: UInt32,
            action: Character
        ) -> String {
            let encoded = NativeUtils.base64EncodeString(Array(path.utf8))
            return "\u{1B}_Ga=\(action),t=f,f=\(format),s=\(width),v=\(height),i=\(id),q=0;\(encoded)\u{1B}\\"
        }

        public func startProbe(firstId: UInt32, directory: String) throws(LeaseError) -> String {
            guard mode == .file && fileState == .disabled else { return "" }
            fileState = .probing
            queryOk = false
            uploadOk = false
            queryId = firstId
            uploadProbeId = firstId &+ 1
            do {
                let slot = try createLease(id: uploadProbeId, payload: [0, 0, 0], directory: directory)
                let path = leases[slot].path
                var out = Self.formatReference(path: path, width: 1, height: 1, format: 24, id: queryId, action: "q")
                out += Self.formatReference(path: path, width: 1, height: 1, format: 24, id: uploadProbeId, action: "t")
                out += NativeZigTerminalImage.writeKittyDelete(id: uploadProbeId, placementId: nil, freeImage: true, tmux: false)
                return out
            } catch let err {
                cancel(reason: .ioError)
                throw err
            }
        }

        public func handleReply(_ response: String) -> Bool {
            handleReply(Array(response.utf8))
        }

        public func handleReply(_ response: [UInt8]) -> Bool {
            let prefix: [UInt8] = [0x1B, UInt8(ascii: "_"), UInt8(ascii: "G")]
            let suffix: [UInt8] = [0x1B, UInt8(ascii: "\\")]
            guard fileState != .disabled,
                  response.count <= 4096,
                  response.count >= prefix.count + suffix.count + 1,
                  Array(response.prefix(3)) == prefix,
                  Array(response.suffix(2)) == suffix
            else {
                return false
            }
            guard let sepIdx = response.firstIndex(of: UInt8(ascii: ";")),
                  sepIdx >= 3,
                  sepIdx < response.count - 2
            else {
                return false
            }
            let headerStr = String(decoding: response[3..<sepIdx], as: UTF8.self)
            var parsedId: UInt32? = nil
            for field in headerStr.split(separator: ",", omittingEmptySubsequences: false) {
                guard field.hasPrefix("i=") else { continue }
                if parsedId != nil { return false }
                guard let idVal = UInt32(field.dropFirst(2)) else { return false }
                parsedId = idVal
            }
            guard let imageId = parsedId else { return false }
            let statusStr = String(decoding: response[(sepIdx + 1)..<(response.count - 2)], as: UTF8.self)
            let ok = statusStr == "OK"

            if imageId == queryId || imageId == uploadProbeId {
                if fileState != .probing { return true }
                if !ok {
                    cancel(reason: .unsupported)
                } else {
                    if imageId == queryId {
                        queryOk = true
                    } else {
                        uploadOk = true
                    }
                    if queryOk && uploadOk {
                        for i in 0..<leases.count {
                            leases[i].release(store: fileStore)
                        }
                        fileState = pendingCount() == 0 ? .ready : .ioError
                        if fileState == .ready && mode == .file {
                            retryImages = true
                        }
                    }
                }
                return true
            }

            for i in 0..<leases.count {
                if !leases[i].isActive || leases[i].id != imageId { continue }
                if ok {
                    leases[i].release(store: fileStore)
                    if leases[i].isActive {
                        cancel(reason: .ioError)
                    }
                } else {
                    cancel(reason: .unsupported)
                }
                return true
            }
            return false
        }

        public func transmit(
            image: NativeZigImage.Image,
            id: UInt32,
            tmux: Bool = false,
            directory: String = "/tmp"
        ) -> String {
            fallback = .none
            let info = image.info()
            let pixelFormat: NativeZigTerminalImage.KittyPixelFormat = info.hasAlpha == 0 ? .rgb : .rgba
            let payload = NativeZigTerminalImage.writeKittyPayload(image, requestedFormat: pixelFormat)

            if mode == .file {
                if fileState != .ready || tmux {
                    fallback = fileState == .probing ? .notReady : .unavailable
                } else {
                    do {
                        let slot = try createLease(id: id, payload: payload, directory: directory)
                        leases[slot].unpublished = true
                        let fmtCode: UInt32 = pixelFormat == .rgb ? 24 : 32
                        effective = .file
                        return Self.formatReference(
                            path: leases[slot].path,
                            width: image.width,
                            height: image.height,
                            format: fmtCode,
                            id: id,
                            action: "t"
                        )
                    } catch let err {
                        switch err {
                        case .budget:
                            fallback = .budget
                        case .busy:
                            fallback = .busy
                        case .unsupported, .invalidDirectory, .ioFailed:
                            fallback = .preparation
                            cancel(reason: .ioError)
                        }
                    }
                }
            }

            let encoding: NativeZigTerminalImage.KittyEncoding = mode == .zlib ? .zlib : .raw
            let seq = NativeZigTerminalImage.writeKittyTransmitEncoded(
                payload: payload,
                width: image.width,
                height: image.height,
                id: id,
                encoding: encoding,
                pixelFormat: pixelFormat,
                tmux: tmux
            )
            effective = encoding
            return seq
        }
    }
}

// MARK: - 14. native/src/text-buffer-segment.zig (14 symbols)

public enum NativeTextSegment: Sendable {
    // parity: native/src/text-buffer-segment.zig#RGBA [status=implemented hash=7137f217292d]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/text-buffer-segment.zig#TextSelection [status=implemented hash=fa3020fb837e]
    public typealias TextSelection = OpenTUICore.TextSelection

    // parity: native/src/text-buffer-segment.zig#TextBufferError [status=implemented hash=1c229d6ee9a8]
    public enum TextBufferError: Swift.Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidDimensions
        case invalidIndex
        case invalidId
        case invalidMemId
        case layerLimit
    }

    // parity: native/src/text-buffer-segment.zig#WrapMode [status=implemented hash=2928a3ab93df]
    public enum WrapMode: UInt8, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case none = 0
        case char = 1
        case word = 2
    }

    // parity: native/src/text-buffer-segment.zig#RenderClusterInfo [status=implemented hash=6cdaa0f7eddf]
    public typealias RenderClusterInfo = OpenTUICore.RenderClusterInfo

    // parity: native/src/text-buffer-segment.zig#ChunkLayoutInfo [status=implemented hash=2bf953081abf]
    public typealias ChunkLayoutInfo = OpenTUICore.ChunkLayoutInfo

    // parity: native/src/text-buffer-segment.zig#WordLayoutInfo [status=implemented hash=5e4a56bc9759]
    public struct WordLayoutInfo: Equatable, Hashable, Sendable {
        public var wrapBreaks: [LayoutWrapBreak]
        public var firstWordClass: WordClass
        public var lastWordClass: WordClass

        public init(wrapBreaks: [LayoutWrapBreak], firstWordClass: WordClass, lastWordClass: WordClass) {
            self.wrapBreaks = wrapBreaks
            self.firstWordClass = firstWordClass
            self.lastWordClass = lastWordClass
        }
    }

    // parity: native/src/text-buffer-segment.zig#TextChunkColdState [status=implemented hash=f75458e33631]
    public final class TextChunkColdState: @unchecked Sendable {
        public var renderClusters: [RenderClusterInfo]? = nil
        public var renderClustersTabWidth: UInt8? = nil
        public var renderClustersWidthMethod: WidthMethod? = nil
        public var wrapBreaks: [LayoutWrapBreak]? = nil
        public var wrapBreaksTabWidth: UInt8? = nil
        public var wrapBreaksWidthMethod: WidthMethod? = nil
        public var wordClasses: WordClassEdges = WordClassEdges(first: .other, last: .other)
        public var cjkBreaks: [LayoutWrapBreak] = []
        public var layoutUsed: Bool = false
        public var lineBreaksReady: Bool = false
        internal var inCache: Bool = false

        public init() {}
    }

    // parity: native/src/text-buffer-segment.zig#ChunkLayoutCache [status=implemented hash=ab20d25c56ea]
    public final class ChunkLayoutCache: @unchecked Sendable {
        private var entries: [TextChunkColdState] = []
        public private(set) var clears: UInt64 = 0
        public private(set) var releases: UInt64 = 0

        public init() {}

        public var entryCount: Int { entries.count }

        internal func register(_ cold: TextChunkColdState) {
            guard !cold.inCache else { return }
            cold.inCache = true
            entries.append(cold)
        }

        public func clear() {
            clears &+= 1
            release(onlyUnused: false)
        }

        public func beginLayout() {
            for cold in entries {
                cold.layoutUsed = false
            }
        }

        public func endLayout() {
            release(onlyUnused: true)
        }

        private func release(onlyUnused: Bool) {
            var remaining: [TextChunkColdState] = []
            for cold in entries {
                if onlyUnused && cold.layoutUsed {
                    remaining.append(cold)
                    continue
                }
                releases &+= 1
                cold.wrapBreaks = nil
                cold.wrapBreaksTabWidth = nil
                cold.wrapBreaksWidthMethod = nil
                cold.cjkBreaks.removeAll(keepingCapacity: false)
                cold.lineBreaksReady = false
                cold.inCache = false
            }
            entries = remaining
        }
    }

    // parity: native/src/text-buffer-segment.zig#TextChunk [status=implemented hash=a8d898469a9a]
    public struct TextChunk: Equatable, Sendable {
        public enum Flags: Sendable {
            public static let asciiOnly: UInt8 = 0b0000_0001
            public static let hasTab: UInt8 = 0b0000_0010
            public static let staticEllipsis: UInt8 = 0b0000_0100
        }

        public var memId: UInt8
        public var byteStart: UInt32
        public var byteEnd: UInt32
        public var widthCols: UInt32
        public var flags: UInt8
        public var cold: TextChunkColdState?

        public init(
            memId: UInt8 = 0,
            byteStart: UInt32 = 0,
            byteEnd: UInt32 = 0,
            widthCols: UInt32 = 0,
            flags: UInt8 = 0,
            cold: TextChunkColdState? = nil
        ) {
            self.memId = memId
            self.byteStart = byteStart
            self.byteEnd = byteEnd
            self.widthCols = widthCols
            self.flags = flags
            self.cold = cold
        }

        public static func == (lhs: TextChunk, rhs: TextChunk) -> Bool {
            lhs.memId == rhs.memId
                && lhs.byteStart == rhs.byteStart
                && lhs.byteEnd == rhs.byteEnd
                && lhs.widthCols == rhs.widthCols
                && lhs.flags == rhs.flags
        }

        public var isAsciiOnly: Bool { (flags & Flags.asciiOnly) != 0 }
        public var hasTab: Bool { (flags & Flags.hasTab) != 0 }
        public var isEmpty: Bool { widthCols == 0 }

        public static func empty() -> TextChunk {
            TextChunk()
        }

        public func getBytes(memRegistry: NativeMemRegistry) -> [UInt8] {
            let memBuf: [UInt8]
            if (flags & Flags.staticEllipsis) != 0 {
                memBuf = [0x2E, 0x2E, 0x2E] // "..."
            } else if let data = memRegistry.get(memId) {
                memBuf = data
            } else {
                return []
            }
            let start = min(Int(byteStart), memBuf.count)
            let end = min(Int(byteEnd), memBuf.count)
            guard start < end else { return [] }
            return Array(memBuf[start..<end])
        }

        private mutating func getOrCreateCold() -> TextChunkColdState {
            if let existing = cold { return existing }
            let created = TextChunkColdState()
            cold = created
            return created
        }

        public func getCachedLayoutInfo(tabWidth: UInt8, widthMethod: WidthMethod) -> ChunkLayoutInfo? {
            guard let cold else { return nil }
            cold.layoutUsed = true
            guard cold.lineBreaksReady, let cached = cold.wrapBreaks else { return nil }
            guard cold.wrapBreaksTabWidth == tabWidth && cold.wrapBreaksWidthMethod == widthMethod else { return nil }
            return ChunkLayoutInfo(wrapBreaks: cached, cjkBreaks: cold.cjkBreaks, wordClasses: cold.wordClasses)
        }

        public mutating func getRenderClusters(
            memRegistry: NativeMemRegistry,
            tabWidth: UInt8 = 2,
            controlDisplay: ControlDisplay = .hidden,
            widthMethod: WidthMethod = .unicode
        ) -> [RenderClusterInfo] {
            if isAsciiOnly { return [] }
            let cold = getOrCreateCold()
            if let cached = cold.renderClusters,
               cold.renderClustersTabWidth == tabWidth,
               cold.renderClustersWidthMethod == widthMethod
            {
                return cached
            }
            let computed = findRenderClusterInfo(
                getBytes(memRegistry: memRegistry),
                tabWidth: tabWidth,
                controlDisplay: controlDisplay,
                isASCIIOnly: isAsciiOnly,
                widthMethod: widthMethod
            )
            cold.renderClusters = computed
            cold.renderClustersTabWidth = tabWidth
            cold.renderClustersWidthMethod = widthMethod
            return computed
        }

        public mutating func getLayoutInfo(
            cache: ChunkLayoutCache,
            memRegistry: NativeMemRegistry,
            tabWidth: UInt8 = 2,
            controlDisplay: ControlDisplay = .hidden,
            widthMethod: WidthMethod = .unicode
        ) -> ChunkLayoutInfo {
            let cold = getOrCreateCold()
            if cold.wrapBreaks == nil {
                cache.register(cold)
                cold.wrapBreaks = []
            }
            cold.layoutUsed = true
            if let cached = cold.wrapBreaks,
               cold.wrapBreaksTabWidth == tabWidth,
               cold.wrapBreaksWidthMethod == widthMethod,
               cold.lineBreaksReady
            {
                return ChunkLayoutInfo(wrapBreaks: cached, cjkBreaks: cold.cjkBreaks, wordClasses: cold.wordClasses)
            }
            let bytes = getBytes(memRegistry: memRegistry)
            let info: ChunkLayoutInfo
            if isAsciiOnly {
                info = findWordChunkLayoutInfo(
                    bytes,
                    tabWidth: tabWidth,
                    controlDisplay: controlDisplay,
                    isASCIIOnly: true,
                    widthMethod: widthMethod
                )
            } else {
                info = findLineAndWordChunkLayoutInfo(
                    bytes,
                    tabWidth: tabWidth,
                    controlDisplay: controlDisplay,
                    isASCIIOnly: false,
                    widthMethod: widthMethod
                )
            }
            cold.wrapBreaks = info.wrapBreaks
            cold.cjkBreaks = info.cjkBreaks
            cold.wrapBreaksTabWidth = tabWidth
            cold.wrapBreaksWidthMethod = widthMethod
            cold.lineBreaksReady = true
            cold.wordClasses = info.wordClasses
            return info
        }

        public mutating func getWordLayoutInfo(
            cache: ChunkLayoutCache,
            memRegistry: NativeMemRegistry,
            tabWidth: UInt8 = 2,
            controlDisplay: ControlDisplay = .hidden,
            widthMethod: WidthMethod = .unicode
        ) -> WordLayoutInfo {
            let cold = getOrCreateCold()
            if cold.wrapBreaks == nil {
                cache.register(cold)
                cold.wrapBreaks = []
            }
            cold.layoutUsed = true
            if let cached = cold.wrapBreaks,
               cold.wrapBreaksTabWidth == tabWidth,
               cold.wrapBreaksWidthMethod == widthMethod
            {
                return WordLayoutInfo(
                    wrapBreaks: cached,
                    firstWordClass: cold.wordClasses.first,
                    lastWordClass: cold.wordClasses.last
                )
            }
            let bytes = getBytes(memRegistry: memRegistry)
            let info = findWordChunkLayoutInfo(
                bytes,
                tabWidth: tabWidth,
                controlDisplay: controlDisplay,
                isASCIIOnly: isAsciiOnly,
                widthMethod: widthMethod
            )
            cold.wrapBreaks = info.wrapBreaks
            cold.cjkBreaks.removeAll(keepingCapacity: true)
            cold.wrapBreaksTabWidth = tabWidth
            cold.wrapBreaksWidthMethod = widthMethod
            cold.lineBreaksReady = !info.wordClasses.hasCjkBreaks
            cold.wordClasses = info.wordClasses
            return WordLayoutInfo(
                wrapBreaks: info.wrapBreaks,
                firstWordClass: info.wordClasses.first,
                lastWordClass: info.wordClasses.last
            )
        }
    }

    // parity: native/src/text-buffer-segment.zig#Highlight [status=implemented hash=7f21057108ea]
    public struct Highlight: Equatable, Hashable, Sendable, Codable {
        public var colStart: UInt32
        public var colEnd: UInt32
        public var styleId: UInt32
        public var priority: UInt8
        public var hlRef: UInt16
        public var isInternal: Bool

        public init(
            colStart: UInt32,
            colEnd: UInt32,
            styleId: UInt32,
            priority: UInt8,
            hlRef: UInt16 = 0,
            isInternal: Bool = false
        ) {
            self.colStart = colStart
            self.colEnd = colEnd
            self.styleId = styleId
            self.priority = priority
            self.hlRef = hlRef
            self.isInternal = isInternal
        }
    }

    // parity: native/src/text-buffer-segment.zig#StyleSpan [status=implemented hash=04c278f5d8d9]
    public struct StyleSpan: Equatable, Hashable, Sendable, Codable {
        public enum Kind: UInt8, Equatable, Hashable, Sendable, Codable {
            case legacy = 0
            case groupSet = 1
            case markStyle = 2
        }

        public static let linkIdMask: UInt32 = 0x00FF_FFFF

        public var endColExclusive: UInt32
        public var styleId: UInt32
        public var linkIdAndKind: UInt32

        public init(endColExclusive: UInt32, styleId: UInt32, linkIdAndKind: UInt32 = 0) {
            self.endColExclusive = endColExclusive
            self.styleId = styleId
            self.linkIdAndKind = linkIdAndKind
        }

        public init(endColExclusive: UInt32, styleId: UInt32, kind: Kind, linkId: UInt32 = 0) {
            self.endColExclusive = endColExclusive
            self.styleId = styleId
            self.linkIdAndKind = (UInt32(kind.rawValue) << 24) | (linkId & Self.linkIdMask)
        }

        public static func legacy(endColExclusive: UInt32, styleId: UInt32) -> StyleSpan {
            StyleSpan(endColExclusive: endColExclusive, styleId: styleId, linkIdAndKind: 0)
        }

        public var kind: Kind {
            Kind(rawValue: UInt8(linkIdAndKind >> 24)) ?? .legacy
        }

        public var linkId: UInt32 {
            linkIdAndKind & Self.linkIdMask
        }
    }

    // parity: native/src/text-buffer-segment.zig#Segment [status=implemented hash=b8b32706136b]
    public enum Segment: Equatable, Sendable {
        case text(TextChunk)
        case brk
        case linestart

        public struct Metrics: Equatable, Hashable, Sendable {
            public var totalWidthCols: UInt32 = 0
            public var totalBytes: UInt32 = 0
            public var linestartCount: UInt32 = 0
            public var newlineCount: UInt32 = 0
            public var lineWidthFirst: UInt32 = 0
            public var lineWidthLast: UInt32 = 0
            public var lineWidthInnerMax: UInt32 = 0
            public var asciiOnly: Bool = true
            public var hasTabs: Bool = false

            public init(
                totalWidthCols: UInt32 = 0,
                totalBytes: UInt32 = 0,
                linestartCount: UInt32 = 0,
                newlineCount: UInt32 = 0,
                lineWidthFirst: UInt32 = 0,
                lineWidthLast: UInt32 = 0,
                lineWidthInnerMax: UInt32 = 0,
                asciiOnly: Bool = true,
                hasTabs: Bool = false
            ) {
                self.totalWidthCols = totalWidthCols
                self.totalBytes = totalBytes
                self.linestartCount = linestartCount
                self.newlineCount = newlineCount
                self.lineWidthFirst = lineWidthFirst
                self.lineWidthLast = lineWidthLast
                self.lineWidthInnerMax = lineWidthInnerMax
                self.asciiOnly = asciiOnly
                self.hasTabs = hasTabs
            }

            public mutating func add(_ other: Metrics) {
                if other.newlineCount == 0 {
                    lineWidthLast &+= other.totalWidthCols
                    if newlineCount == 0 {
                        lineWidthFirst &+= other.totalWidthCols
                    }
                } else if newlineCount == 0 {
                    lineWidthFirst &+= other.lineWidthFirst
                    lineWidthLast = other.lineWidthLast
                    lineWidthInnerMax = other.lineWidthInnerMax
                } else {
                    lineWidthInnerMax = max(
                        max(lineWidthInnerMax, other.lineWidthInnerMax),
                        lineWidthLast &+ other.lineWidthFirst
                    )
                    lineWidthLast = other.lineWidthLast
                }

                totalWidthCols &+= other.totalWidthCols
                totalBytes &+= other.totalBytes
                linestartCount &+= other.linestartCount
                newlineCount &+= other.newlineCount
                asciiOnly = asciiOnly && other.asciiOnly
                hasTabs = hasTabs || other.hasTabs
            }

            public func lineWidthMax() -> UInt32 {
                max(max(lineWidthFirst, lineWidthLast), lineWidthInnerMax)
            }

            public func weight() -> UInt32 {
                totalWidthCols &+ newlineCount
            }
        }

        public struct BoundaryAction: Equatable, Sendable {
            public var deleteLeft: Bool
            public var deleteRight: Bool
            public var insertBetween: [Segment]

            public init(deleteLeft: Bool = false, deleteRight: Bool = false, insertBetween: [Segment] = []) {
                self.deleteLeft = deleteLeft
                self.deleteRight = deleteRight
                self.insertBetween = insertBetween
            }
        }

        public func measure() -> Metrics {
            switch self {
            case .text(let chunk):
                let byteLen = chunk.byteEnd &- chunk.byteStart
                return Metrics(
                    totalWidthCols: chunk.widthCols,
                    totalBytes: byteLen,
                    linestartCount: 0,
                    newlineCount: 0,
                    lineWidthFirst: chunk.widthCols,
                    lineWidthLast: chunk.widthCols,
                    asciiOnly: chunk.isAsciiOnly,
                    hasTabs: chunk.hasTab
                )
            case .brk:
                return Metrics(newlineCount: 1, asciiOnly: true)
            case .linestart:
                return Metrics(linestartCount: 1, asciiOnly: true)
            }
        }

        public static func empty() -> Segment { .text(TextChunk.empty()) }

        public var isEmpty: Bool {
            switch self {
            case .text(let chunk): chunk.isEmpty
            case .brk, .linestart: false
            }
        }

        public var isVoid: Bool {
            if case .text(let chunk) = self {
                return chunk.byteStart == chunk.byteEnd
            }
            return false
        }

        public func getBytes(memRegistry: NativeMemRegistry) -> [UInt8] {
            switch self {
            case .text(let chunk): chunk.getBytes(memRegistry: memRegistry)
            case .brk, .linestart: []
            }
        }

        public var isBreak: Bool {
            if case .brk = self { return true }
            return false
        }

        public var isLineStart: Bool {
            if case .linestart = self { return true }
            return false
        }

        public var isText: Bool {
            if case .text = self { return true }
            return false
        }

        public var asText: TextChunk? {
            if case .text(let chunk) = self { return chunk }
            return nil
        }

        public static func canMerge(left: Segment, right: Segment) -> Bool {
            guard let lc = left.asText, let rc = right.asText else { return false }
            if lc.memId != rc.memId { return false }
            if lc.byteEnd != rc.byteStart { return false }
            if (lc.flags & ~TextChunk.Flags.hasTab) != (rc.flags & ~TextChunk.Flags.hasTab) { return false }
            return true
        }

        public static func findJunction(
            left: [UInt8],
            right: [UInt8],
            method: WidthMethod = .unicode
        ) -> (tail: UInt32, head: UInt32)? {
            precondition(!right.isEmpty)
            guard !left.isEmpty else { return nil }
            var pos = codepointStartBefore(left, end: left.count)
            var cp = NativeUtf8Extras.decodeUtf8Unchecked(left, at: pos).cp
            let rightFirst = NativeUtf8Extras.decodeUtf8Unchecked(right, at: 0).cp
            if breaksInEveryState(prev: cp, curr: rightFirst, method: method) {
                return nil
            }
            while pos > 0 {
                let prevPos = codepointStartBefore(left, end: pos)
                let prevCp = NativeUtf8Extras.decodeUtf8Unchecked(left, at: prevPos).cp
                if breaksInEveryState(prev: prevCp, curr: cp, method: method) { break }
                pos = prevPos
                cp = prevCp
            }
            var state: NativeUtf8Extras.GraphemeBreakState = .default
            var prev: UInt32? = nil
            var tail = pos
            while pos < left.count {
                let dec = NativeUtf8Extras.decodeUtf8Unchecked(left, at: pos)
                if NativeUtf8Extras.isGraphemeBreak(prevCp: prev, currCp: dec.cp, breakState: &state, widthMethod: method) {
                    tail = pos
                }
                prev = dec.cp
                pos += Int(dec.len)
            }
            var head = 0
            while head < right.count {
                let dec = NativeUtf8Extras.decodeUtf8Unchecked(right, at: head)
                if NativeUtf8Extras.isGraphemeBreak(prevCp: prev, currCp: dec.cp, breakState: &state, widthMethod: method) {
                    break
                }
                prev = dec.cp
                head += Int(dec.len)
            }
            if head == 0 { return nil }
            return (UInt32(tail), UInt32(head))
        }

        private static func breaksInEveryState(prev: UInt32, curr: UInt32, method: WidthMethod) -> Bool {
            for initial in NativeUtf8Extras.GraphemeBreakState.allCases {
                var state = initial
                if !NativeUtf8Extras.isGraphemeBreak(prevCp: prev, currCp: curr, breakState: &state, widthMethod: method) {
                    return false
                }
            }
            return true
        }

        private static func codepointStartBefore(_ bytes: [UInt8], end: Int) -> Int {
            var pos = end - 1
            while pos > 0 && (bytes[pos] & 0xC0) == 0x80 {
                pos -= 1
            }
            return pos
        }

        public static func rewriteBoundary(left: Segment?, right: Segment?) -> BoundaryAction {
            if right == nil, let left, left.isBreak {
                return BoundaryAction(insertBetween: [.linestart])
            }
            guard let left, let right else {
                return BoundaryAction()
            }
            if left.isLineStart && right.isLineStart {
                return BoundaryAction(deleteRight: true)
            }
            if left.isBreak && right.isBreak {
                return BoundaryAction(insertBetween: [.linestart])
            }
            if left.isBreak && right.isText {
                return BoundaryAction(insertBetween: [.linestart])
            }
            if left.isText && right.isLineStart {
                return BoundaryAction(deleteRight: true)
            }
            return BoundaryAction()
        }

        public static func rewriteEnds(first: Segment?, last: Segment?) -> BoundaryAction {
            _ = last
            if let first {
                if !first.isLineStart {
                    return BoundaryAction(insertBetween: [.linestart])
                }
            } else {
                return BoundaryAction(insertBetween: [.linestart])
            }
            return BoundaryAction()
        }
    }

    // parity: native/src/text-buffer-segment.zig#UnifiedRope [status=implemented hash=3e6395147c36]
    public struct UnifiedRope: Sendable {
        public struct Metrics: Equatable, Hashable, Sendable {
            public var count: UInt32
            public var custom: Segment.Metrics

            public init(count: UInt32 = 0, custom: Segment.Metrics = Segment.Metrics()) {
                self.count = count
                self.custom = custom
            }

            public func weight() -> UInt32 {
                custom.weight()
            }

            public mutating func add(_ other: Metrics) {
                count &+= other.count
                custom.add(other.custom)
            }
        }

        public struct Position: Equatable, Hashable, Sendable {
            public var leafIndex: UInt32
            public var weight: UInt32

            public init(leafIndex: UInt32, weight: UInt32) {
                self.leafIndex = leafIndex
                self.weight = weight
            }
        }

        public struct WeightFindResult: Equatable, Sendable {
            public var leaf: Segment
            public var startWeight: UInt32
            public var leafIndex: UInt32
        }

        private indirect enum Node: Sendable {
            case leaf(Segment, Metrics)
            case branch(left: Node, right: Node, metrics: Metrics)

            var metrics: Metrics {
                switch self {
                case .leaf(_, let m): m
                case .branch(_, _, let m): m
                }
            }
        }

        private var root: Node?

        public init() {
            self.root = Self.buildBalanced([.linestart][...])
        }

        public init(segments: [Segment], normalize: Bool = true) {
            let finalSegments = normalize ? Self.normalizeSegments(segments) : segments
            self.root = Self.buildBalanced(finalSegments[...])
        }

        /// Builds a normalized `UnifiedRope` from raw lines of UTF-8 text registered in `memRegistry`.
        public static func fromText(
            _ text: String,
            memRegistry: inout NativeMemRegistry,
            tabWidth: UInt8 = 2,
            controlDisplay: ControlDisplay = .hidden,
            widthMethod: WidthMethod = .unicode
        ) throws(NativeMemRegistryError) -> UnifiedRope {
            let bytes = Array(text.utf8)
            var segments: [Segment] = [.linestart]
            if bytes.isEmpty {
                return UnifiedRope(segments: segments, normalize: false)
            }
            let memId = try memRegistry.register(bytes, owned: true)
            let breaks = findLineBreaks(bytes)
            var lineStart = 0
            for lb in breaks {
                if lb.pos > lineStart {
                    let slice = Array(bytes[lineStart..<lb.pos])
                    let width = calculateTextWidth(
                        slice,
                        tabWidth: tabWidth,
                        controlDisplay: controlDisplay,
                        widthMethod: widthMethod
                    )
                    var flags: UInt8 = 0
                    if isAsciiOnly(slice) { flags |= TextChunk.Flags.asciiOnly }
                    if slice.contains(0x09) { flags |= TextChunk.Flags.hasTab }
                    segments.append(.text(TextChunk(
                        memId: memId,
                        byteStart: UInt32(lineStart),
                        byteEnd: UInt32(lb.pos),
                        widthCols: width,
                        flags: flags
                    )))
                }
                segments.append(.brk)
                segments.append(.linestart)
                lineStart = lb.pos + (lb.kind == .crlf ? 2 : 1)
            }
            if lineStart < bytes.count {
                let slice = Array(bytes[lineStart..<bytes.count])
                let width = calculateTextWidth(
                    slice,
                    tabWidth: tabWidth,
                    controlDisplay: controlDisplay,
                    widthMethod: widthMethod
                )
                var flags: UInt8 = 0
                if isAsciiOnly(slice) { flags |= TextChunk.Flags.asciiOnly }
                if slice.contains(0x09) { flags |= TextChunk.Flags.hasTab }
                segments.append(.text(TextChunk(
                    memId: memId,
                    byteStart: UInt32(lineStart),
                    byteEnd: UInt32(bytes.count),
                    widthCols: width,
                    flags: flags
                )))
            }
            return UnifiedRope(segments: segments, normalize: false)
        }

        private static func normalizeSegments(_ raw: [Segment]) -> [Segment] {
            var out: [Segment] = []
            let ends = Segment.rewriteEnds(first: raw.first, last: raw.last)
            out.append(contentsOf: ends.insertBetween)
            for seg in raw {
                if let prev = out.last {
                    let action = Segment.rewriteBoundary(left: prev, right: seg)
                    if action.deleteLeft { _ = out.popLast() }
                    out.append(contentsOf: action.insertBetween)
                    if !action.deleteRight { out.append(seg) }
                } else {
                    out.append(seg)
                }
            }
            if let last = out.last {
                let tailAction = Segment.rewriteBoundary(left: last, right: nil)
                out.append(contentsOf: tailAction.insertBetween)
            }
            return out
        }

        private static func buildBalanced(_ slice: ArraySlice<Segment>) -> Node? {
            if slice.isEmpty { return nil }
            if slice.count == 1 {
                let seg = slice[slice.startIndex]
                return .leaf(seg, Metrics(count: 1, custom: seg.measure()))
            }
            let mid = slice.startIndex + slice.count / 2
            guard let left = buildBalanced(slice[slice.startIndex..<mid]),
                  let right = buildBalanced(slice[mid..<slice.endIndex])
            else { return nil }
            var combined = left.metrics
            combined.add(right.metrics)
            return .branch(left: left, right: right, metrics: combined)
        }

        public func rootMetrics() -> Metrics {
            root?.metrics ?? Metrics()
        }

        public var count: UInt32 {
            root?.metrics.count ?? 0
        }

        public func totalWeight() -> UInt32 {
            root?.metrics.weight() ?? 0
        }

        public func get(_ index: UInt32) -> Segment? {
            guard var node = root, index < node.metrics.count else { return nil }
            var rest = index
            while true {
                switch node {
                case .leaf(let seg, _):
                    return seg
                case .branch(let left, let right, _):
                    if rest < left.metrics.count {
                        node = left
                    } else {
                        rest -= left.metrics.count
                        node = right
                    }
                }
            }
        }

        public func walkFrom(_ startIndex: UInt32, _ visitor: (Segment, UInt32) -> Bool) {
            guard let root, startIndex < root.metrics.count else { return }
            var relative: UInt32 = 0
            _ = walkNode(root, startIndex: startIndex, relative: &relative, visitor: visitor)
        }

        private func walkNode(
            _ node: Node,
            startIndex: UInt32,
            relative: inout UInt32,
            visitor: (Segment, UInt32) -> Bool
        ) -> Bool {
            switch node {
            case .leaf(let seg, _):
                let keep = visitor(seg, relative)
                relative &+= 1
                return keep
            case .branch(let left, let right, _):
                let leftCount = left.metrics.count
                if startIndex < leftCount {
                    if !walkNode(left, startIndex: startIndex, relative: &relative, visitor: visitor) {
                        return false
                    }
                    return walkNode(right, startIndex: 0, relative: &relative, visitor: visitor)
                } else {
                    return walkNode(right, startIndex: startIndex - leftCount, relative: &relative, visitor: visitor)
                }
            }
        }

        public func findByWeight(_ weight: UInt32) -> WeightFindResult? {
            guard var node = root, weight < totalWeight() else { return nil }
            var startWeight: UInt32 = 0
            var leafIndex: UInt32 = 0
            while true {
                switch node {
                case .branch(let left, let right, _):
                    let leftWeight = left.metrics.weight()
                    if weight < startWeight &+ leftWeight {
                        node = left
                    } else {
                        node = right
                        startWeight &+= leftWeight
                        leafIndex &+= left.metrics.count
                    }
                case .leaf(let seg, _):
                    return WeightFindResult(leaf: seg, startWeight: startWeight, leafIndex: leafIndex)
                }
            }
        }

        public func seekCount(counted: (Metrics) -> UInt32, n: UInt32) -> Position? {
            guard var node = root, n < counted(node.metrics) else { return nil }
            NativeTextWork.add(.lineSeeks, 1)
            var rest = n
            var position = Position(leafIndex: 0, weight: 0)
            while case .branch(let left, let right, _) = node {
                NativeTextWork.add(.lineSeekNodes, 1)
                let lm = left.metrics
                if rest < counted(lm) {
                    node = left
                } else {
                    rest -= counted(lm)
                    position.leafIndex &+= lm.count
                    position.weight &+= lm.weight()
                    node = right
                }
            }
            return position
        }

        public func seekCountSum(
            counted: (Metrics) -> UInt32,
            summed: (Metrics) -> UInt32,
            n: UInt32
        ) -> (leafIndex: UInt32, sum: UInt32)? {
            guard var node = root, n < counted(node.metrics) else { return nil }
            NativeTextWork.add(.lineSeeks, 1)
            var rest = n
            var leafIndex: UInt32 = 0
            var sum: UInt32 = 0
            while case .branch(let left, let right, _) = node {
                NativeTextWork.add(.lineSeekNodes, 1)
                let lm = left.metrics
                if rest < counted(lm) {
                    node = left
                } else {
                    rest -= counted(lm)
                    leafIndex &+= lm.count
                    sum &+= summed(lm)
                    node = right
                }
            }
            return (leafIndex, sum)
        }

        public func countThrough(
            key: (Metrics) -> UInt32,
            counted: (Metrics) -> UInt32,
            target: UInt32
        ) -> UInt32 {
            guard var node = root else { return 0 }
            NativeTextWork.add(.lineSeeks, 1)
            var rest = target
            var total: UInt32 = 0
            while case .branch(let left, let right, _) = node {
                NativeTextWork.add(.lineSeekNodes, 1)
                let lm = left.metrics
                if rest < key(lm) {
                    node = left
                } else {
                    rest -= key(lm)
                    total &+= counted(lm)
                    node = right
                }
            }
            return total &+ counted(node.metrics)
        }
    }
}

// MARK: - 15. native/src/text-buffer-iterators.zig (25 symbols)

public enum NativeTextIterators: Sendable {
    // parity: native/src/text-buffer-iterators.zig#LineInfo [status=implemented hash=5825252dee45]
    public struct LineInfo: Equatable, Hashable, Sendable, Codable {
        public var lineIdx: UInt32
        public var colOffset: UInt32
        public var widthCols: UInt32
        public var segStart: UInt32
        public var segEnd: UInt32

        public init(
            lineIdx: UInt32,
            colOffset: UInt32,
            widthCols: UInt32,
            segStart: UInt32,
            segEnd: UInt32
        ) {
            self.lineIdx = lineIdx
            self.colOffset = colOffset
            self.widthCols = widthCols
            self.segStart = segStart
            self.segEnd = segEnd
        }
    }

    // parity: native/src/text-buffer-iterators.zig#Coords [status=implemented hash=54cbe2a75ef8]
    public struct Coords: Equatable, Hashable, Sendable, Codable {
        public var row: UInt32
        public var col: UInt32

        public init(row: UInt32, col: UInt32) {
            self.row = row
            self.col = col
        }
    }

    // parity: native/src/text-buffer-iterators.zig#SegmentCallback [status=implemented hash=be46415d861a]
    public typealias SegmentCallback = (
        _ lineIdx: UInt32,
        _ chunk: NativeTextSegment.TextChunk,
        _ chunkIdxInLine: UInt32
    ) -> Void

    // parity: native/src/text-buffer-iterators.zig#LineEndCallback [status=implemented hash=2f9b53244ab3]
    public typealias LineEndCallback = (_ lineInfo: LineInfo) -> Void

    // parity: native/src/text-buffer-iterators.zig#GraphemeBounds [status=implemented hash=00d367414698]
    public struct GraphemeBounds: Equatable, Hashable, Sendable, Codable {
        public var start: UInt32
        public var end: UInt32

        public init(start: UInt32, end: UInt32) {
            self.start = start
            self.end = end
        }
    }

    // parity: native/src/text-buffer-iterators.zig#walkLinesAndSegments [status=implemented hash=c5136875f72a]
    public static func walkLinesAndSegments(
        rope: NativeTextSegment.UnifiedRope,
        segmentCallback: SegmentCallback,
        lineEndCallback: LineEndCallback
    ) {
        walkLineRange(
            rope: rope,
            first: 0,
            start: NativeTextSegment.UnifiedRope.Position(leafIndex: 0, weight: 0),
            count: UInt32.max,
            segmentCallback: segmentCallback,
            lineEndCallback: lineEndCallback
        )
    }

    // parity: native/src/text-buffer-iterators.zig#walkLineRange [status=implemented hash=c35846dbfef3]
    public static func walkLineRange(
        rope: NativeTextSegment.UnifiedRope,
        first: UInt32,
        start: NativeTextSegment.UnifiedRope.Position,
        count: UInt32,
        segmentCallback: SegmentCallback,
        lineEndCallback: LineEndCallback
    ) {
        guard rope.count > 0 && count > 0 else { return }

        var linesLeft = count
        var currentLineIdx = first
        var currentColOffset = start.weight
        var lineStartSeg = start.leafIndex
        var currentSegIdx = start.leafIndex
        var lineWidthCols: UInt32 = 0
        var chunkIdxInLine: UInt32 = 0

        rope.walkFrom(start.leafIndex) { seg, relativeIdx in
            let idx = start.leafIndex &+ relativeIdx
            if let chunk = seg.asText {
                segmentCallback(currentLineIdx, chunk, chunkIdxInLine)
                chunkIdxInLine &+= 1
                lineWidthCols &+= chunk.widthCols
            } else if seg.isBreak {
                lineEndCallback(LineInfo(
                    lineIdx: currentLineIdx,
                    colOffset: currentColOffset,
                    widthCols: lineWidthCols,
                    segStart: lineStartSeg,
                    segEnd: idx
                ))
                currentLineIdx &+= 1
                currentColOffset &+= lineWidthCols &+ 1
                lineStartSeg = idx &+ 1
                lineWidthCols = 0
                chunkIdxInLine = 0
                linesLeft -= 1
            }
            currentSegIdx = idx &+ 1
            return linesLeft > 0
        }

        if linesLeft == 0 { return }

        let hadBreaks = currentLineIdx > 0
        let hasContentAfterBreak = lineStartSeg < currentSegIdx
        if hasContentAfterBreak || hadBreaks {
            lineEndCallback(LineInfo(
                lineIdx: currentLineIdx,
                colOffset: currentColOffset,
                widthCols: lineWidthCols,
                segStart: lineStartSeg,
                segEnd: currentSegIdx
            ))
        }
    }

    // parity: native/src/text-buffer-iterators.zig#getLineCount [status=implemented hash=e99695aa0a14]
    public static func getLineCount(_ rope: NativeTextSegment.UnifiedRope) -> UInt32 {
        rope.rootMetrics().custom.linestartCount
    }

    // parity: native/src/text-buffer-iterators.zig#getMaxLineWidth [status=implemented hash=a6dfbcfc701f]
    public static func getMaxLineWidth(_ rope: NativeTextSegment.UnifiedRope) -> UInt32 {
        rope.rootMetrics().custom.lineWidthMax()
    }

    // parity: native/src/text-buffer-iterators.zig#getTotalWidth [status=implemented hash=ecb2e1f4bb89]
    public static func getTotalWidth(_ rope: NativeTextSegment.UnifiedRope) -> UInt32 {
        rope.rootMetrics().custom.totalWidthCols
    }

    // parity: native/src/text-buffer-iterators.zig#lineStartsThroughLeaf [status=implemented hash=e8701e0c78d8]
    public static func lineStartsThroughLeaf(_ rope: NativeTextSegment.UnifiedRope, leafIndex: UInt32) -> UInt32 {
        rope.countThrough(key: leafCount, counted: { $0.custom.linestartCount }, target: leafIndex)
    }

    // parity: native/src/text-buffer-iterators.zig#weight [status=implemented hash=74b8be997e0b]
    public static func weight(_ metrics: NativeTextSegment.UnifiedRope.Metrics) -> UInt32 {
        metrics.weight()
    }

    // parity: native/src/text-buffer-iterators.zig#lineStart [status=implemented hash=a79daf863e66]
    public static func lineStart(_ rope: NativeTextSegment.UnifiedRope, row: UInt32) -> NativeTextSegment.UnifiedRope.Position? {
        rope.seekCount(counted: { $0.custom.linestartCount }, n: row)
    }

    // parity: native/src/text-buffer-iterators.zig#textBytes [status=implemented hash=2594fb499a25]
    public static func textBytes(_ metrics: NativeTextSegment.UnifiedRope.Metrics) -> UInt32 {
        metrics.custom.totalBytes &+ metrics.custom.newlineCount
    }

    // parity: native/src/text-buffer-iterators.zig#leafCount [status=implemented hash=d6c9496738e9]
    public static func leafCount(_ metrics: NativeTextSegment.UnifiedRope.Metrics) -> UInt32 {
        metrics.count
    }

    // parity: native/src/text-buffer-iterators.zig#lineStartByte [status=implemented hash=2552e5b60826]
    public static func lineStartByte(_ rope: NativeTextSegment.UnifiedRope, row: UInt32) -> UInt32? {
        rope.seekCountSum(counted: { $0.custom.linestartCount }, summed: textBytes, n: row)?.sum
    }

    private static func lineWidthFrom(_ rope: NativeTextSegment.UnifiedRope, row: UInt32, startWeight: UInt32) -> UInt32 {
        guard let next = lineStart(rope, row: row &+ 1) else {
            return rope.totalWeight() - startWeight
        }
        precondition(next.weight > startWeight)
        return next.weight - startWeight - 1
    }

    // parity: native/src/text-buffer-iterators.zig#coordsToOffset [status=implemented hash=f4766940a871]
    public static func coordsToOffset(_ rope: NativeTextSegment.UnifiedRope, row: UInt32, col: UInt32) -> UInt32? {
        guard let start = lineStart(rope, row: row) else { return nil }
        if col > lineWidthFrom(rope, row: row, startWeight: start.weight) { return nil }
        return start.weight &+ col
    }

    // parity: native/src/text-buffer-iterators.zig#offsetToCoords [status=implemented hash=306fc71a9f37]
    public static func offsetToCoords(_ rope: NativeTextSegment.UnifiedRope, offset: UInt32) -> Coords? {
        if offset > rope.totalWeight() { return nil }
        let starts = rope.countThrough(key: weight, counted: { $0.custom.linestartCount }, target: offset)
        guard starts > 0 else { return nil }
        let row = starts - 1
        guard let start = lineStart(rope, row: row) else { return nil }
        return Coords(row: row, col: offset - start.weight)
    }

    // parity: native/src/text-buffer-iterators.zig#lineWidthAt [status=implemented hash=62a9f0232c56]
    public static func lineWidthAt(_ rope: NativeTextSegment.UnifiedRope, row: UInt32) -> UInt32 {
        guard let start = lineStart(rope, row: row) else { return 0 }
        return lineWidthFrom(rope, row: row, startWeight: start.weight)
    }

    // parity: native/src/text-buffer-iterators.zig#firstLineEndingAfter [status=implemented hash=76cd2a1163ff]
    public static func firstLineEndingAfter(_ rope: NativeTextSegment.UnifiedRope, cell: UInt32) -> UInt32 {
        rope.countThrough(
            key: { $0.custom.totalWidthCols },
            counted: { $0.custom.newlineCount },
            target: cell
        )
    }

    private static func getTextUnitBoundsAt(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        row: UInt32,
        col: UInt32,
        tabWidth: UInt8,
        controlDisplay: ControlDisplay,
        widthMethod: WidthMethod,
        clusterGraphemes: Bool
    ) -> GraphemeBounds? {
        let lineWidth = lineWidthAt(rope, row: row)
        if col >= lineWidth { return nil }
        guard let start = lineStart(rope, row: row) else { return nil }
        var segIdx = start.leafIndex &+ 1
        var colsBefore: UInt32 = 0

        while segIdx < rope.count {
            guard let seg = rope.get(segIdx) else { break }
            if seg.isBreak || seg.isLineStart { break }
            if let chunk = seg.asText {
                let nextCols = colsBefore &+ chunk.widthCols
                if col < nextCols {
                    let localCol = col - colsBefore
                    let bytes = chunk.getBytes(memRegistry: memRegistry)
                    let pos = clusterGraphemes
                        ? findGraphemePosByWidth(
                            bytes,
                            maxColumns: localCol,
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            isASCIIOnly: chunk.isAsciiOnly,
                            includeStartBefore: false,
                            widthMethod: widthMethod
                        )
                        : findPosByWidth(
                            bytes,
                            maxColumns: localCol,
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            isASCIIOnly: chunk.isAsciiOnly,
                            includeStartBefore: false,
                            widthMethod: widthMethod
                        )
                    if Int(pos.byteOffset) >= bytes.count { return nil }
                    let width = clusterGraphemes
                        ? OpenTUICore.getGraphemeWidthAt(
                            bytes,
                            byteOffset: Int(pos.byteOffset),
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            widthMethod: widthMethod
                        )
                        : getWidthAt(
                            bytes,
                            byteOffset: Int(pos.byteOffset),
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            widthMethod: widthMethod
                        )
                    let boundStart = colsBefore &+ pos.columnsUsed
                    return GraphemeBounds(start: boundStart, end: boundStart &+ width)
                }
                colsBefore = nextCols
            }
            segIdx &+= 1
        }
        return nil
    }

    // parity: native/src/text-buffer-iterators.zig#getGraphemeBoundsAt [status=implemented hash=fd2b89f2ba97]
    public static func getGraphemeBoundsAt(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        row: UInt32,
        col: UInt32,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) -> GraphemeBounds? {
        getTextUnitBoundsAt(
            rope: rope,
            memRegistry: memRegistry,
            row: row,
            col: col,
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            widthMethod: widthMethod,
            clusterGraphemes: true
        )
    }

    // parity: native/src/text-buffer-iterators.zig#getCursorUnitBoundsAt [status=implemented hash=39157eccafa0]
    public static func getCursorUnitBoundsAt(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        row: UInt32,
        col: UInt32,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) -> GraphemeBounds? {
        getTextUnitBoundsAt(
            rope: rope,
            memRegistry: memRegistry,
            row: row,
            col: col,
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            widthMethod: widthMethod,
            clusterGraphemes: false
        )
    }

    // parity: native/src/text-buffer-iterators.zig#getGraphemeWidthAt [status=implemented hash=c0367d9923ed]
    public static func getGraphemeWidthAt(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        row: UInt32,
        col: UInt32,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) -> UInt32 {
        guard let bounds = getCursorUnitBoundsAt(
            rope: rope,
            memRegistry: memRegistry,
            row: row,
            col: col,
            tabWidth: tabWidth,
            controlDisplay: controlDisplay,
            widthMethod: widthMethod
        ) else {
            return 0
        }
        return bounds.end > col ? bounds.end - col : 0
    }

    // parity: native/src/text-buffer-iterators.zig#getPrevGraphemeWidth [status=implemented hash=0566539bd2c5]
    public static func getPrevGraphemeWidth(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        row: UInt32,
        col: UInt32,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        widthMethod: WidthMethod = .unicode
    ) -> UInt32 {
        if col == 0 { return 0 }
        let lineWidth = lineWidthAt(rope, row: row)
        let clampedCol = min(col, lineWidth)
        guard let start = lineStart(rope, row: row) else { return 0 }

        var segIdx = start.leafIndex &+ 1
        var colsBefore: UInt32 = 0
        var prevChunk: NativeTextSegment.TextChunk? = nil

        while segIdx < rope.count {
            guard let seg = rope.get(segIdx) else { break }
            if seg.isBreak || seg.isLineStart { break }
            if let chunk = seg.asText {
                let nextCols = colsBefore &+ chunk.widthCols
                if clampedCol <= nextCols {
                    if clampedCol == colsBefore, let pc = prevChunk {
                        let prevBytes = pc.getBytes(memRegistry: memRegistry)
                        if let res = getPrevGraphemeStart(
                            prevBytes,
                            byteOffset: prevBytes.count,
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            widthMethod: widthMethod
                        ) {
                            return res.width
                        }
                        return 0
                    }
                    let bytes = chunk.getBytes(memRegistry: memRegistry)
                    let localCol = clampedCol - colsBefore
                    let here = findPosByWidth(
                        bytes,
                        maxColumns: localCol,
                        tabWidth: tabWidth,
                        controlDisplay: controlDisplay,
                        isASCIIOnly: chunk.isAsciiOnly,
                        includeStartBefore: false,
                        widthMethod: widthMethod
                    )
                    let graphemeStartCol = here.columnsUsed
                    if graphemeStartCol > localCol {
                        if let pc = prevChunk {
                            let prevBytes = pc.getBytes(memRegistry: memRegistry)
                            if let res = getPrevGraphemeStart(
                                prevBytes,
                                byteOffset: prevBytes.count,
                                tabWidth: tabWidth,
                                controlDisplay: controlDisplay,
                                widthMethod: widthMethod
                            ) {
                                return res.width
                            }
                        }
                        return 0
                    }
                    let offsetIntoGrapheme = localCol - graphemeStartCol
                    if offsetIntoGrapheme > 0 {
                        if let res = getPrevGraphemeStart(
                            bytes,
                            byteOffset: Int(here.byteOffset),
                            tabWidth: tabWidth,
                            controlDisplay: controlDisplay,
                            widthMethod: widthMethod
                        ) {
                            return offsetIntoGrapheme &+ res.width
                        }
                        return offsetIntoGrapheme
                    }
                    if let res = getPrevGraphemeStart(
                        bytes,
                        byteOffset: Int(here.byteOffset),
                        tabWidth: tabWidth,
                        controlDisplay: controlDisplay,
                        widthMethod: widthMethod
                    ) {
                        return res.width
                    }
                    return 0
                }
                prevChunk = chunk
                colsBefore = nextCols
            }
            segIdx &+= 1
        }
        return 0
    }

    // parity: native/src/text-buffer-iterators.zig#extractTextBetweenOffsets [status=implemented hash=da9c1b1c56a0]
    public static func extractTextBetweenOffsets(
        rope: NativeTextSegment.UnifiedRope,
        memRegistry: NativeMemRegistry,
        tabWidth: UInt8 = 2,
        controlDisplay: ControlDisplay = .hidden,
        startOffset: UInt32,
        endOffset: UInt32,
        maxBytes: Int? = nil,
        widthMethod: WidthMethod = .unicode
    ) -> [UInt8] {
        guard startOffset < endOffset else { return [] }
        if let maxBytes, maxBytes <= 0 { return [] }
        guard let first = rope.findByWeight(startOffset) else { return [] }

        var output: [UInt8] = []
        var colOffset = first.startWeight

        func appendSlice(_ bytes: ArraySlice<UInt8>) {
            if let limit = maxBytes {
                let room = max(0, limit - output.count)
                if room == 0 { return }
                let count = min(bytes.count, room)
                output.append(contentsOf: bytes[bytes.startIndex..<bytes.index(bytes.startIndex, offsetBy: count)])
            } else {
                output.append(contentsOf: bytes)
            }
        }

        rope.walkFrom(first.leafIndex) { segment, _ in
            if colOffset >= endOffset { return false }
            if let chunk = segment.asText {
                let chunkStartOffset = colOffset
                let chunkEndOffset = chunkStartOffset &+ chunk.widthCols
                colOffset = chunkEndOffset
                if chunkEndOffset <= startOffset { return true }

                let chunkBytes = chunk.getBytes(memRegistry: memRegistry)
                let localStartCol: UInt32 = startOffset > chunkStartOffset ? startOffset - chunkStartOffset : 0
                let localEndCol: UInt32 = min(endOffset - chunkStartOffset, chunk.widthCols)

                var byteStart: Int = 0
                var byteEnd: Int = chunkBytes.count

                if localStartCol > 0 {
                    let startRes = findGraphemePosByWidth(
                        chunkBytes,
                        maxColumns: localStartCol,
                        tabWidth: tabWidth,
                        controlDisplay: controlDisplay,
                        isASCIIOnly: chunk.isAsciiOnly,
                        includeStartBefore: false,
                        widthMethod: widthMethod
                    )
                    byteStart = Int(startRes.byteOffset)
                }

                if localEndCol < chunk.widthCols {
                    let endRes = findGraphemePosByWidth(
                        chunkBytes,
                        maxColumns: localEndCol,
                        tabWidth: tabWidth,
                        controlDisplay: controlDisplay,
                        isASCIIOnly: chunk.isAsciiOnly,
                        includeStartBefore: true,
                        widthMethod: widthMethod
                    )
                    byteEnd = Int(endRes.byteOffset)
                }

                if byteStart < byteEnd && byteStart < chunkBytes.count {
                    let actualEnd = min(byteEnd, chunkBytes.count)
                    appendSlice(chunkBytes[byteStart..<actualEnd])
                }
            } else if segment.isBreak {
                if colOffset >= startOffset {
                    appendSlice([0x0A][...])
                }
                colOffset &+= 1
            }
            return true
        }
        return output
    }
}
