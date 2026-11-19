import Synchronization
import Testing
@testable import OpenTUICore

@Suite("NativeSubsystemsIO — Workstream 3a1")
struct NativeSubsystemsIOTests {

    // MARK: - 1. NativeUtils (src/utils.zig)

    @Test("NativeUtils repeat, eql, base64Encode, nextPaintEpoch")
    func utilsPrimitives() {
        #expect(NativeUtils.repeat([UInt8(1), 2], count: 3) == [1, 2, 1, 2, 1, 2])
        #expect(NativeUtils.repeat([UInt8(9)], count: 0).isEmpty)
        #expect(NativeUtils.repeatString("ab", count: 2) == "abab")
        #expect(NativeUtils.repeatString("x", count: 0) == "")

        #expect(NativeUtils.eql([UInt32(10), 20, 30], [10, 20, 30]))
        #expect(!NativeUtils.eql([UInt32(10), 20, 30], [10, 21, 30]))
        #expect(!NativeUtils.eql([UInt32(10), 20], [10, 20, 30]))

        // RFC 4648 standard base64 vectors
        #expect(NativeUtils.base64EncodeString([]) == "")
        #expect(NativeUtils.base64EncodeString(Array("f".utf8)) == "Zg==")
        #expect(NativeUtils.base64EncodeString(Array("fo".utf8)) == "Zm8=")
        #expect(NativeUtils.base64EncodeString(Array("foo".utf8)) == "Zm9v")
        #expect(NativeUtils.base64EncodeString(Array("foob".utf8)) == "Zm9vYg==")
        #expect(NativeUtils.base64EncodeString(Array("fooba".utf8)) == "Zm9vYmE=")
        #expect(NativeUtils.base64EncodeString(Array("foobar".utf8)) == "Zm9vYmFy")
        #expect(NativeUtils.base64EncodeString(Array("Hello, OpenTUI!".utf8)) == "SGVsbG8sIE9wZW5UVUkh")

        var dest = Array<UInt8>(repeating: 0, count: 16)
        let written = NativeUtils.base64Encode(into: &dest, source: Array("foobar".utf8))
        #expect(written == 8)
        #expect(String(decoding: dest[0..<written], as: UTF8.self) == "Zm9vYmFy")

        let e1 = NativeUtils.nextPaintEpoch()
        let e2 = NativeUtils.nextPaintEpoch()
        let e3 = NativeUtils.nextPaintEpoch()
        #expect(e1 > 0)
        #expect(e2 > e1)
        #expect(e3 > e2)
    }

    // MARK: - 2. NativeEventEmitter (src/event-emitter.zig)

    private enum SampleEvent: Hashable, Sendable {
        case changed
        case flushed
    }

    @Test("NativeEventEmitter on, off, emit, listenerCount")
    func eventEmitterLifecycle() {
        let emitter = NativeEventEmitter<SampleEvent>()
        let countA = Atomic<Int>(0)
        let countB = Atomic<Int>(0)

        let lA = emitter.on(.changed) { _ = countA.wrappingAdd(1, ordering: .relaxed) }
        let lB = emitter.on(.changed) { _ = countB.wrappingAdd(1, ordering: .relaxed) }
        #expect(emitter.listenerCount(for: .changed) == 2)

        emitter.emit(.changed)
        #expect(countA.load(ordering: .relaxed) == 1)
        #expect(countB.load(ordering: .relaxed) == 1)

        emitter.off(.changed, listener: lA)
        #expect(emitter.listenerCount(for: .changed) == 1)
        emitter.emit(.changed)
        #expect(countA.load(ordering: .relaxed) == 1)
        #expect(countB.load(ordering: .relaxed) == 2)

        emitter.off(.changed, listener: lB)
        #expect(emitter.listenerCount(for: .changed) == 0)
        emitter.emit(.flushed)
        #expect(countB.load(ordering: .relaxed) == 2)
    }

    // MARK: - 3. NativeSplitScrollback (src/split-scrollback.zig)

    @Test("NativeSplitScrollback row promotion, wrapping, and viewport scroll")
    func splitScrollbackBehavior() {
        var sb = NativeSplitScrollback()
        #expect(sb.renderOffset(surfaceOffset: 10) == 0)
        #expect(sb.renderOffset(surfaceOffset: 0) == 0)

        // Publish 25 columns into width 10 -> rows 1 (10 cols), 2 (10 cols), 3 (5 cols)
        sb.publishRow(columns: 25, width: 10, trailingNewline: false)
        #expect(sb.publishedRows == 3)
        #expect(sb.tailColumn == 5)
        #expect(sb.renderOffset(surfaceOffset: 10) == 3)
        #expect(sb.renderOffset(surfaceOffset: 2) == 2)

        // Newline promotes to next row with column 0
        sb.noteNewline()
        #expect(sb.publishedRows == 4)
        #expect(sb.tailColumn == 0)

        // Scroll viewport down by 2 rows
        sb.noteViewportScroll(lines: 2)
        #expect(sb.publishedRows == 2)

        // Over-scrolling clamps to 0 and resets tailColumn
        sb.publishRow(columns: 3, width: 10, trailingNewline: false)
        sb.noteViewportScroll(lines: 100)
        #expect(sb.publishedRows == 0)
        #expect(sb.tailColumn == 0)

        // Snapshot rows
        sb.reset(seedRows: 0)
        sb.publishSnapshotRows(rowCount: 3, rowColumns: 5, terminalWidth: 10, trailingNewline: false)
        #expect(sb.publishedRows == 3)
        #expect(sb.tailColumn == 5)

        sb.reset(seedRows: 1)
        #expect(sb.publishedRows == 1)
        #expect(sb.tailColumn == 0)
    }

    // MARK: - 4. NativeMemRegistry (src/mem-registry.zig)

    @Test("NativeMemRegistry register, reuse, cancelLastRegistration, replace, unregister, limits")
    func memRegistryOperations() throws {
        var reg = NativeMemRegistry()
        #expect(reg.getUsedSlots() == 0)
        #expect(reg.getFreeSlots() == 255)

        let id0 = try reg.register("hello")
        let id1 = try reg.register("world")
        #expect(id0 == 0)
        #expect(id1 == 1)
        #expect(reg.get(id0) == Array("hello".utf8))
        #expect(reg.get(id1) == Array("world".utf8))
        #expect(reg.getUsedSlots() == 2)
        #expect(reg.getFreeSlots() == 253)

        // Replace active slot
        try reg.replace(id0, data: Array("HELLO!".utf8))
        #expect(reg.get(id0) == Array("HELLO!".utf8))

        // Unregister and verify LIFO reuse
        try reg.unregister(id0)
        #expect(reg.get(id0) == nil)
        #expect(reg.getUsedSlots() == 1)
        #expect(reg.getFreeSlots() == 254)

        let prevCount = reg.buffers.count
        let reused = try reg.register("reused")
        #expect(reused == id0)
        // Cancel reused slot returns it to freeSlots
        reg.cancelLastRegistration(id: reused, previousBufferCount: prevCount)
        #expect(reg.get(reused) == nil)
        #expect(reg.freeSlots.last == id0)

        // Cancel newly appended slot shrinks buffers array
        _ = try reg.register("reoccupy")
        let beforeAppend = reg.buffers.count
        let appended = try reg.register("temp")
        #expect(appended == 2)
        reg.cancelLastRegistration(id: appended, previousBufferCount: beforeAppend)
        #expect(reg.buffers.count == beforeAppend)

        // Invalid unregister/replace throws
        #expect(throws: NativeMemRegistryError.invalidMemId) {
            try reg.unregister(99)
        }
        #expect(throws: NativeMemRegistryError.invalidMemId) {
            try reg.replace(99, data: [1])
        }

        // Fill to 255 slots and verify OutOfMemory on 256th
        reg.clear()
        for i in 0..<255 {
            let sid = try reg.register([UInt8(i & 0xFF)])
            #expect(Int(sid) == i)
        }
        #expect(reg.getFreeSlots() == 0)
        #expect(throws: NativeMemRegistryError.outOfMemory) {
            _ = try reg.register([1])
        }
    }

    // MARK: - 5. NativeHighlightLayers (src/highlight-layers.zig)

    @Test("NativeHighlightLayers GroupSets interning, compose, and transactional Layers")
    func highlightLayersCompositionAndEdits() throws {
        var sets = NativeHighlightLayers.GroupSets()
        let gs1 = try sets.intern(["keyword", "keyword.control"])
        let gs1Dup = try sets.intern(["keyword", "keyword.control"])
        #expect(gs1 == 1)
        #expect(gs1Dup == gs1)
        #expect(sets.count == 1)
        #expect(sets.nameCount(id: gs1) == 2)
        #expect(sets.nameString(id: gs1, index: 1) == "keyword.control")

        // Validation rejections change nothing
        #expect(throws: NativeHighlightLayers.HighlightLayerError.invalidIndex) {
            _ = try sets.intern([] as [String])
        }
        #expect(throws: NativeHighlightLayers.HighlightLayerError.invalidIndex) {
            _ = try sets.intern([""])
        }
        #expect(throws: NativeHighlightLayers.HighlightLayerError.invalidIndex) {
            _ = try sets.intern([[0xFF, 0xFE]])
        }
        #expect(throws: NativeHighlightLayers.HighlightLayerError.groupSetLimit) {
            _ = try sets.intern(Array(repeating: "a", count: NativeHighlightLayers.groupSetNameCountMax + 1))
        }
        #expect(sets.count == 1)

        // Compose with dotted fallback and markup.strikethrough default
        let style = NativeZigSyntaxStyle.SyntaxStyle()
        let red = RGBA.fromInts(255, 0, 0, 255)
        let blue = RGBA.fromInts(0, 0, 255, 255)
        style.registerStyleDefinition(
            name: "keyword",
            definition: NativeZigSyntaxStyle.StyleDefinition(
                fg: red,
                bg: nil,
                attributes: TextAttributes.bold,
                suppliedAttributes: UInt8(TextAttributes.bold & 0xFF)
            )
        )
        style.registerStyleDefinition(
            name: "emphasis",
            definition: NativeZigSyntaxStyle.StyleDefinition(
                fg: blue,
                bg: nil,
                attributes: TextAttributes.italic,
                suppliedAttributes: UInt8(TextAttributes.italic & 0xFF)
            )
        )

        let gsComposed = try sets.intern(["keyword.async", "emphasis", "markup.strikethrough"])
        let composed = NativeHighlightLayers.compose(style: style, sets: sets, id: gsComposed)
        #expect(composed.fg == blue)
        #expect((composed.attributes & TextAttributes.bold) != 0)
        #expect((composed.attributes & TextAttributes.italic) != 0)
        #expect((composed.attributes & TextAttributes.strikethrough) != 0)
        #expect(!NativeHighlightLayers.suppliesNothing(composed))

        let gsUnknown = try sets.intern(["nonexistent.group"])
        let emptyComposed = NativeHighlightLayers.compose(style: style, sets: sets, id: gsUnknown)
        #expect(NativeHighlightLayers.suppliesNothing(emptyComposed))

        // Layers set, split, LinkPool refcounting, insertBytes, deleteBytes, layer limit
        let linkPool = LinkPool()
        let linkId = try linkPool.acquire("https://opentui.dev")
        var layers = NativeHighlightLayers.Layers()
        let changed1 = try layers.set(
            linkPool: linkPool,
            layerId: 10,
            startByte: 0,
            endByte: 20,
            runs: [NativeHighlightLayers.LayerRun(startByte: 2, endByte: 18, groupSet: gs1, linkId: linkId)]
        )
        #expect(changed1)
        #expect(try linkPool.getRefcount(linkId) == 2)

        // Identical set returns false
        let changedSame = try layers.set(
            linkPool: linkPool,
            layerId: 10,
            startByte: 0,
            endByte: 20,
            runs: [NativeHighlightLayers.LayerRun(startByte: 2, endByte: 18, groupSet: gs1, linkId: linkId)]
        )
        #expect(!changedSame)

        // Punching a hole in the middle splits the run and increments link refcount
        let changedSplit = try layers.set(
            linkPool: linkPool,
            layerId: 10,
            startByte: 6,
            endByte: 12,
            runs: [NativeHighlightLayers.LayerRun(startByte: 6, endByte: 12, groupSet: gsComposed, linkId: 0)]
        )
        #expect(changedSplit)
        let splitRuns = layers.runsOf(10)
        #expect(splitRuns.count == 3)
        #expect(splitRuns[0] == NativeHighlightLayers.LayerRun(startByte: 2, endByte: 6, groupSet: gs1, linkId: linkId))
        #expect(splitRuns[1] == NativeHighlightLayers.LayerRun(startByte: 6, endByte: 12, groupSet: gsComposed, linkId: 0))
        #expect(splitRuns[2] == NativeHighlightLayers.LayerRun(startByte: 12, endByte: 18, groupSet: gs1, linkId: linkId))
        #expect(try linkPool.getRefcount(linkId) == 3)

        // Insert & delete bytes shift/clip runs properly
        layers.insertBytes(atByte: 4, byteCount: 3)
        #expect(layers.runsOf(10)[0].startByte == 2)
        #expect(layers.runsOf(10)[0].endByte == 9)
        #expect(layers.runsOf(10)[1].startByte == 9)

        layers.deleteBytes(linkPool: linkPool, startByte: 0, endByte: 10)
        #expect(layers.runsOf(10).count == 2)
        #expect(try linkPool.getRefcount(linkId) == 2)

        // Enforce max 4 layers
        _ = try layers.set(linkPool: linkPool, layerId: 1, startByte: 0, endByte: 5, runs: [.init(startByte: 0, endByte: 5, groupSet: gs1)])
        _ = try layers.set(linkPool: linkPool, layerId: 2, startByte: 0, endByte: 5, runs: [.init(startByte: 0, endByte: 5, groupSet: gs1)])
        _ = try layers.set(linkPool: linkPool, layerId: 3, startByte: 0, endByte: 5, runs: [.init(startByte: 0, endByte: 5, groupSet: gs1)])
        #expect(layers.count == 4)
        #expect(throws: NativeHighlightLayers.HighlightLayerError.layerLimit) {
            _ = try layers.set(linkPool: linkPool, layerId: 4, startByte: 0, endByte: 5, runs: [.init(startByte: 0, endByte: 5, groupSet: gs1)])
        }

        // Reset releases all link refs
        layers.reset(linkPool: linkPool)
        #expect(layers.isEmpty)
        #expect(try linkPool.getRefcount(linkId) == 1)
    }

    // MARK: - 6. NativeEditMarks (src/edit-marks.zig)

    @Test("NativeEditMarks versioned add, remove, clear, splice, atomic drop, assertValid")
    func editMarksOperations() {
        let arena = NativeEditMarks.Arena()
        var v0: NativeEditMarks.AuxHandle = 0
        #expect(NativeEditMarks.live(arena, aux: v0).isEmpty)

        let m1 = NativeEditMarks.Mark(id: 1, kind: 1, style: 5, startByte: 2, endByte: 8, priority: 10, atomic: false)
        let m2 = NativeEditMarks.Mark(id: 2, kind: 1, style: 0, startByte: 10, endByte: 15, priority: 0, atomic: true, styleValue: false)
        #expect(m1.styled)
        #expect(!m2.styled)

        v0 = NativeEditMarks.add(arena, aux: v0, owned: true, mark: m2)
        v0 = NativeEditMarks.add(arena, aux: v0, owned: true, mark: m1)
        #expect(NativeEditMarks.live(arena, aux: v0).map(\.id) == [1, 2])
        #expect(NativeEditMarks.isValid(arena, aux: v0, byteCount: 20))
        NativeEditMarks.assertValid(arena, aux: v0, byteCount: 20)

        // Splice after all marks returns nil (unchanged shared version)
        #expect(NativeEditMarks.splice(arena, aux: v0, start: 18, deleted: 1, inserted: 2) == nil)

        // Splice inserting 2 bytes inside m1 grows m1 and shifts m2; original v0 remains immutable
        let v1 = NativeEditMarks.splice(arena, aux: v0, start: 4, deleted: 0, inserted: 2)
        #expect(v1 != nil)
        let liveV1 = NativeEditMarks.live(arena, aux: v1!)
        #expect(liveV1[0].startByte == 2 && liveV1[0].endByte == 10)
        #expect(liveV1[1].startByte == 12 && liveV1[1].endByte == 17)
        // Original v0 unchanged (undo safety)
        #expect(NativeEditMarks.live(arena, aux: v0)[0].endByte == 8)

        // Splice editing inside atomic mark m2 drops m2
        let v2 = NativeEditMarks.splice(arena, aux: v1!, start: 14, deleted: 0, inserted: 1)
        #expect(v2 != nil)
        #expect(NativeEditMarks.live(arena, aux: v2!).map(\.id) == [1])

        // Remove & clear
        #expect(NativeEditMarks.remove(arena, aux: v2!, owned: false, id: 999) == nil)
        let v3 = NativeEditMarks.remove(arena, aux: v2!, owned: false, id: 1)
        #expect(v3 != nil)
        #expect(NativeEditMarks.live(arena, aux: v3!).isEmpty)

        let clearedOwned = NativeEditMarks.clear(arena, aux: v0, owned: true)
        #expect(clearedOwned == v0)
        #expect(NativeEditMarks.live(arena, aux: clearedOwned).isEmpty)
        #expect(NativeEditMarks.clear(arena, aux: v1!, owned: false) == 0)
    }

    // MARK: - 7. NativeUtf8Extras & NativeEncodedUnicode

    @Test("NativeUtf8Extras decodeUtf8Unchecked, isGraphemeBreak, LineBreakResult, TabStopResult, walkChunkLayoutInfoComptime")
    func utf8ExtrasAndGraphemeBreaks() {
        var lb = NativeUtf8Extras.LineBreakResult(breaks: [LineBreak(pos: 3, kind: .lf)])
        #expect(lb.breaks.count == 1)
        lb.reset()
        #expect(lb.breaks.isEmpty)

        var ts = NativeUtf8Extras.TabStopResult(positions: [4, 8])
        #expect(ts.positions == [4, 8])
        ts.reset()
        #expect(ts.positions.isEmpty)

        // decodeUtf8Unchecked for 1-, 2-, 3-, 4-byte UTF-8 and truncated tail
        let sample = Array("Aé中😀".utf8)
        let d1 = NativeUtf8Extras.decodeUtf8Unchecked(sample, at: 0)
        #expect(d1 == .init(cp: 0x41, len: 1))
        let d2 = NativeUtf8Extras.decodeUtf8Unchecked(sample, at: 1)
        #expect(d2 == .init(cp: 0x00E9, len: 2))
        let d3 = NativeUtf8Extras.decodeUtf8Unchecked(sample, at: 3)
        #expect(d3 == .init(cp: 0x4E2D, len: 3))
        let d4 = NativeUtf8Extras.decodeUtf8Unchecked(sample, at: 6)
        #expect(d4 == .init(cp: 0x1F600, len: 4))
        let trunc = NativeUtf8Extras.decodeUtf8Unchecked([0xE4, 0xB8], at: 0)
        #expect(trunc == .init(cp: 0xFFFD, len: 1))

        // isGraphemeBreak: CR+LF stays together, combining mark joins base, ZWJ differs in .unicode vs .noZWJ
        var st: NativeUtf8Extras.GraphemeBreakState = .default
        #expect(!NativeUtf8Extras.isGraphemeBreak(prevCp: 0x0D, currCp: 0x0A, breakState: &st))
        #expect(!NativeUtf8Extras.isGraphemeBreak(prevCp: 0x65, currCp: 0x0301, breakState: &st))
        #expect(NativeUtf8Extras.isGraphemeBreak(prevCp: 0x61, currCp: 0x62, breakState: &st))

        // Emoji ZWJ sequence: woman + ZWJ + rocket
        var stUni: NativeUtf8Extras.GraphemeBreakState = .default
        _ = NativeUtf8Extras.isGraphemeBreak(prevCp: nil, currCp: 0x1F469, breakState: &stUni, widthMethod: .unicode)
        #expect(!NativeUtf8Extras.isGraphemeBreak(prevCp: 0x1F469, currCp: 0x200D, breakState: &stUni, widthMethod: .unicode))
        #expect(!NativeUtf8Extras.isGraphemeBreak(prevCp: 0x200D, currCp: 0x1F680, breakState: &stUni, widthMethod: .unicode))

        var stNoZwj: NativeUtf8Extras.GraphemeBreakState = .default
        _ = NativeUtf8Extras.isGraphemeBreak(prevCp: nil, currCp: 0x1F469, breakState: &stNoZwj, widthMethod: .noZWJ)
        _ = NativeUtf8Extras.isGraphemeBreak(prevCp: 0x1F469, currCp: 0x200D, breakState: &stNoZwj, widthMethod: .noZWJ)
        #expect(NativeUtf8Extras.isGraphemeBreak(prevCp: 0x200D, currCp: 0x1F680, breakState: &stNoZwj, widthMethod: .noZWJ))

        // walkChunkLayoutInfoComptime with early termination
        var visited: [LayoutWrapBreak] = []
        let edges = NativeUtf8Extras.walkChunkLayoutInfoComptime(Array("hello world foo".utf8)) { wb in
            visited.append(wb)
            return visited.count < 1
        }
        #expect(visited.count == 1)
        #expect(edges.first == .asciiWord)
        #expect(edges.last == .asciiWord)
    }

    @Test("NativeEncodedUnicode encodes ASCII, CJK, emoji, and releases GraphemePool refs")
    func encodedUnicodeLifecycle() throws {
        let pool = GraphemePool()
        let encoded = try NativeEncodedUnicode.EncodedUnicode.create(pool: pool, text: "A中😀")
        #expect(encoded.chars.count == 3)
        #expect(encoded.chars[0] == .init(width: 1, char: UInt32(UInt8(ascii: "A"))))
        #expect(encoded.chars[1].width == 2)
        #expect(isGraphemeChar(encoded.chars[1].char))
        #expect(encoded.chars[2].width == 2)
        #expect(isGraphemeChar(encoded.chars[2].char))

        let cjkGid = graphemeIdFromChar(encoded.chars[1].char)
        #expect(try pool.getRefcount(cjkGid) == 1)
        encoded.release(pool: pool)
        #expect(encoded.chars.isEmpty)
        #expect(pool.liveCount == 0)

        // Invalid UTF-8 rejected
        #expect(throws: NativeEncodedUnicode.EncodeError.invalidUtf8) {
            _ = try NativeEncodedUnicode.EncodedUnicode.create(pool: pool, text: [0xFF, 0xFE])
        }
    }

    // MARK: - 8. NativeTextSegment & NativeTextIterators

    @Test("NativeTextSegment chunks, cache, spans, boundary normalization, junction, and UnifiedRope")
    func textSegmentAndLayoutCache() throws {
        var reg = NativeMemRegistry()
        let id = try reg.register("hello world 你好")
        var chunk = NativeTextSegment.TextChunk(
            memId: id,
            byteStart: 0,
            byteEnd: UInt32("hello world 你好".utf8.count),
            widthCols: 16,
            flags: 0
        )
        let cache = NativeTextSegment.ChunkLayoutCache()
        #expect(chunk.getCachedLayoutInfo(tabWidth: 2, widthMethod: .unicode) == nil)

        cache.beginLayout()
        let layout = chunk.getLayoutInfo(cache: cache, memRegistry: reg, tabWidth: 2, widthMethod: .unicode)
        #expect(!layout.wrapBreaks.isEmpty)
        #expect(chunk.getCachedLayoutInfo(tabWidth: 2, widthMethod: .unicode) != nil)
        cache.endLayout()
        #expect(cache.releases == 0)

        // Next layout pass doesn't touch chunk -> endLayout releases it
        cache.beginLayout()
        cache.endLayout()
        #expect(cache.releases == 1)
        #expect(chunk.getCachedLayoutInfo(tabWidth: 2, widthMethod: .unicode) == nil)

        cache.clear()
        #expect(cache.clears == 1)

        // Static ellipsis chunk
        let ellipsis = NativeTextSegment.TextChunk(
            memId: 255,
            byteStart: 0,
            byteEnd: 3,
            widthCols: 3,
            flags: NativeTextSegment.TextChunk.Flags.staticEllipsis | NativeTextSegment.TextChunk.Flags.asciiOnly
        )
        #expect(ellipsis.getBytes(memRegistry: reg) == Array("...".utf8))

        // StyleSpan bit packing
        let span = NativeTextSegment.StyleSpan(endColExclusive: 12, styleId: 7, kind: .groupSet, linkId: 0x12_3456)
        #expect(span.kind == .groupSet)
        #expect(span.linkId == 0x12_3456)
        #expect(NativeTextSegment.StyleSpan.legacy(endColExclusive: 5, styleId: 3).kind == .legacy)

        // Segment.canMerge & findJunction
        let s1 = NativeTextSegment.Segment.text(.init(memId: id, byteStart: 0, byteEnd: 5, widthCols: 5, flags: 1))
        let s2 = NativeTextSegment.Segment.text(.init(memId: id, byteStart: 5, byteEnd: 11, widthCols: 6, flags: 1))
        #expect(NativeTextSegment.Segment.canMerge(left: s1, right: s2))
        #expect(!NativeTextSegment.Segment.canMerge(left: s2, right: s1))

        #expect(NativeTextSegment.Segment.findJunction(left: Array("abc".utf8), right: Array("def".utf8)) == nil)
        let junction = NativeTextSegment.Segment.findJunction(
            left: Array("ae".utf8),
            right: Array("\u{0301}b".utf8)
        )
        #expect(junction?.tail == 1)
        #expect(junction?.head == 2)

        // Boundary rewrite rules
        #expect(NativeTextSegment.Segment.rewriteBoundary(left: .linestart, right: .linestart).deleteRight)
        #expect(NativeTextSegment.Segment.rewriteBoundary(left: .brk, right: .brk).insertBetween == [.linestart])
        #expect(NativeTextSegment.Segment.rewriteBoundary(left: .brk, right: s1).insertBetween == [.linestart])
        #expect(NativeTextSegment.Segment.rewriteBoundary(left: s1, right: .linestart).deleteRight)
        #expect(NativeTextSegment.Segment.rewriteBoundary(left: .brk, right: nil).insertBetween == [.linestart])
        #expect(NativeTextSegment.Segment.rewriteEnds(first: nil, last: nil).insertBetween == [.linestart])
    }

    @Test("NativeTextIterators line metrics, coords/offsets, grapheme bounds, and extraction")
    func textIteratorsFullCoverage() throws {
        var reg = NativeMemRegistry()
        // Line 0: "abc" (width 3, bytes 3)
        // Line 1: "中x"  (width 3, bytes 4)
        // Line 2: "hello" (width 5, bytes 5)
        let rope = try NativeTextSegment.UnifiedRope.fromText("abc\n中x\nhello", memRegistry: &reg)

        #expect(NativeTextIterators.getLineCount(rope) == 3)
        #expect(NativeTextIterators.getMaxLineWidth(rope) == 5)
        #expect(NativeTextIterators.getTotalWidth(rope) == 11)
        #expect(NativeTextIterators.lineWidthAt(rope, row: 0) == 3)
        #expect(NativeTextIterators.lineWidthAt(rope, row: 1) == 3)
        #expect(NativeTextIterators.lineWidthAt(rope, row: 2) == 5)
        #expect(NativeTextIterators.lineWidthAt(rope, row: 9) == 0)

        // lineStartByte accounts for 1 byte per newline
        #expect(NativeTextIterators.lineStartByte(rope, row: 0) == 0)
        #expect(NativeTextIterators.lineStartByte(rope, row: 1) == 4) // "abc\n"
        #expect(NativeTextIterators.lineStartByte(rope, row: 2) == 9) // "abc\n中x\n"

        // coordsToOffset & offsetToCoords round-trip
        // Row 0 weights 0..3, brk=3..4; Row 1 weights 4..7, brk=7..8; Row 2 weights 8..13
        #expect(NativeTextIterators.coordsToOffset(rope, row: 0, col: 2) == 2)
        #expect(NativeTextIterators.coordsToOffset(rope, row: 1, col: 2) == 6)
        #expect(NativeTextIterators.coordsToOffset(rope, row: 2, col: 5) == 13)
        #expect(NativeTextIterators.coordsToOffset(rope, row: 0, col: 4) == nil)

        #expect(NativeTextIterators.offsetToCoords(rope, offset: 0) == .init(row: 0, col: 0))
        #expect(NativeTextIterators.offsetToCoords(rope, offset: 4) == .init(row: 1, col: 0))
        #expect(NativeTextIterators.offsetToCoords(rope, offset: 6) == .init(row: 1, col: 2))
        #expect(NativeTextIterators.offsetToCoords(rope, offset: 13) == .init(row: 2, col: 5))
        #expect(NativeTextIterators.offsetToCoords(rope, offset: 14) == nil)

        // firstLineEndingAfter & lineStartsThroughLeaf
        #expect(NativeTextIterators.firstLineEndingAfter(rope, cell: 0) == 0)
        #expect(NativeTextIterators.firstLineEndingAfter(rope, cell: 3) == 1)
        #expect(NativeTextIterators.lineStartsThroughLeaf(rope, leafIndex: 0) == 1)

        // Grapheme bounds on wide char '中' (cols 0..<2) and 'x' (cols 2..<3) on row 1
        #expect(NativeTextIterators.getGraphemeBoundsAt(rope: rope, memRegistry: reg, row: 1, col: 0) == .init(start: 0, end: 2))
        #expect(NativeTextIterators.getGraphemeBoundsAt(rope: rope, memRegistry: reg, row: 1, col: 1) == .init(start: 0, end: 2))
        #expect(NativeTextIterators.getCursorUnitBoundsAt(rope: rope, memRegistry: reg, row: 1, col: 2) == .init(start: 2, end: 3))
        #expect(NativeTextIterators.getGraphemeWidthAt(rope: rope, memRegistry: reg, row: 1, col: 0) == 2)
        #expect(NativeTextIterators.getPrevGraphemeWidth(rope: rope, memRegistry: reg, row: 1, col: 2) == 2)
        #expect(NativeTextIterators.getPrevGraphemeWidth(rope: rope, memRegistry: reg, row: 1, col: 3) == 1)

        // walkLinesAndSegments
        var walkedLines: [NativeTextIterators.LineInfo] = []
        var walkedChunks: [UInt32] = []
        NativeTextIterators.walkLinesAndSegments(
            rope: rope,
            segmentCallback: { lineIdx, _, _ in walkedChunks.append(lineIdx) },
            lineEndCallback: { info in walkedLines.append(info) }
        )
        #expect(walkedLines.count == 3)
        #expect(walkedLines.map(\.widthCols) == [3, 3, 5])
        #expect(walkedChunks == [0, 1, 2])

        // extractTextBetweenOffsets across lines with grapheme snapping
        let extracted = NativeTextIterators.extractTextBetweenOffsets(
            rope: rope,
            memRegistry: reg,
            startOffset: 1,
            endOffset: 9
        )
        #expect(String(decoding: extracted, as: UTF8.self) == "bc\n中x\nh")

        // Truncated extraction with maxBytes
        let truncated = NativeTextIterators.extractTextBetweenOffsets(
            rope: rope,
            memRegistry: reg,
            startOffset: 0,
            endOffset: 13,
            maxBytes: 4
        )
        #expect(String(decoding: truncated, as: UTF8.self) == "abc\n")
    }

    // MARK: - 9. NativeKittyTransport (src/kitty-transport.zig)

    @Test("NativeKittyTransport probe, reply ACK, leases, frame lifecycle, expiry, and fallbacks")
    func kittyTransportStateMachine() throws {
        let store = MemoryKittyFileStore()
        let transport = NativeKittyTransport.Transport(fileStore: store, mode: .file)

        let probeSeq = try transport.startProbe(firstId: 10, directory: "/tmp")
        #expect(transport.fileState == .probing)
        #expect(transport.queryId == 10)
        #expect(transport.uploadProbeId == 11)
        #expect(transport.pendingCount() == 1)
        #expect(probeSeq.contains("\u{1B}_Ga=q,t=f,f=24,s=1,v=1,i=10,q=0;"))
        #expect(probeSeq.contains("\u{1B}_Ga=t,t=f,f=24,s=1,v=1,i=11,q=0;"))
        #expect(probeSeq.contains("a=d,d=I,i=11"))

        // While probing, transmit falls back with .notReady
        let img = NativeZigImage.Image(core: try NativeImage.fromRgba(Array(repeating: 255, count: 16), width: 2, height: 2))
        _ = transport.transmit(image: img, id: 100, tmux: false, directory: "/tmp")
        #expect(transport.fallback == .notReady)
        #expect(transport.effective == .raw)

        // Probe requires BOTH queryId and uploadProbeId OK
        #expect(transport.handleReply("\u{1B}_Gi=10;OK\u{1B}\\"))
        #expect(transport.fileState == .probing)
        #expect(transport.handleReply("\u{1B}_Gi=11;OK\u{1B}\\"))
        #expect(transport.fileState == .ready)
        #expect(transport.retryImages)
        #expect(transport.pendingCount() == 0)

        // Transmit in ready file mode creates unpublished lease
        let txSeq = transport.transmit(image: img, id: 200, tmux: false, directory: "/tmp")
        #expect(transport.effective == .file)
        #expect(transport.fallback == .none)
        #expect(txSeq.contains("a=t,t=f"))
        #expect(transport.pendingCount() == 1)

        // Busy fallback for duplicate in-flight ID
        _ = transport.transmit(image: img, id: 200, tmux: false, directory: "/tmp")
        #expect(transport.fallback == .busy)

        // Skipped frame releases unpublished lease
        transport.finishFrame(published: false)
        #expect(transport.pendingCount() == 0)

        // Published frame keeps lease until ACK
        _ = transport.transmit(image: img, id: 201, tmux: false, directory: "/tmp")
        transport.finishFrame(published: true)
        #expect(transport.pendingCount() == 1)
        #expect(transport.handleReply("\u{1B}_Gi=201;OK\u{1B}\\"))
        #expect(transport.pendingCount() == 0)

        // Expiry cancels file transport with .timeout
        _ = transport.transmit(image: img, id: 202, tmux: false, directory: "/tmp")
        transport.finishFrame(published: true)
        transport.expire(nowNs: 1_000_000_000)
        #expect(transport.fileState == .ready)
        transport.expire(nowNs: 1_000_000_000 + NativeKittyTransport.timeoutNs)
        #expect(transport.fileState == .timeout)
        #expect(transport.pendingCount() == 0)
    }

    // MARK: - 10. NativeStdoutWriter (src/stdout-writer.zig)

    private final class ScriptSink: NativeStdoutSink, @unchecked Sendable {
        enum ResultItem: Sendable {
            case ok(Int)
            case err(NativeStdoutWriter.SinkError)
        }

        private struct State: Sendable {
            var results: [ResultItem]
            var index: Int = 0
            var written: [UInt8] = []
            var waitCount: Int = 0
        }

        private let state: Mutex<State>

        init(_ results: [ResultItem]) {
            self.state = Mutex(State(results: results))
        }

        func write(_ bytes: ArraySlice<UInt8>) throws(NativeStdoutWriter.SinkError) -> Int {
            try state.withLock { s throws(NativeStdoutWriter.SinkError) in
                let item = s.results[s.index]
                s.index += 1
                switch item {
                case .err(let e):
                    throw e
                case .ok(let count):
                    let clamped = min(count, bytes.count)
                    if clamped > 0 {
                        s.written.append(contentsOf: bytes[bytes.startIndex..<bytes.index(bytes.startIndex, offsetBy: clamped)])
                    }
                    return count
                }
            }
        }

        func waitWritable() {
            state.withLock { $0.waitCount += 1 }
        }

        var writtenBytes: [UInt8] { state.withLock { $0.written } }
        var waitCount: Int { state.withLock { $0.waitCount } }
    }

    @Test("NativeStdoutWriter retries EINTR/EAGAIN, fails zero/overcount, supports Parked reclaim and sync framing")
    func stdoutWriterStateMachineAndFraming() throws {
        // Retry interrupted + wouldBlock then complete
        let sink1 = ScriptSink([.ok(1), .err(.wouldBlock), .err(.interrupted), .ok(3)])
        let w1 = try NativeStdoutWriter.Writer.create(sink: sink1, runner: NativeStdoutWriter.ThreadRunner())
        w1.start(bytes: Array("abcd".utf8))
        #expect(w1.waitCollect(graceNs: 1_000_000_000) == .written)
        #expect(sink1.writtenBytes == Array("abcd".utf8))
        #expect(sink1.waitCount == 1)
        #expect(w1.flushCount == 1)
        #expect(w1.totalBytesWritten == 4)
        w1.abandon()

        // Zero write and overcount fail
        let sinkZero = ScriptSink([.ok(0)])
        let wZero = try NativeStdoutWriter.Writer.create(sink: sinkZero, runner: NativeStdoutWriter.ThreadRunner())
        wZero.start(bytes: Array("abcd".utf8))
        #expect(wZero.waitCollect(graceNs: 1_000_000_000) == .failed)
        wZero.abandon()

        let sinkOver = ScriptSink([.ok(9)])
        let wOver = try NativeStdoutWriter.Writer.create(sink: sinkOver, runner: NativeStdoutWriter.ThreadRunner())
        wOver.start(bytes: Array("abcd".utf8))
        #expect(wOver.waitCollect(graceNs: 1_000_000_000) == .failed)
        wOver.abandon()

        // Parked runner reclaims .inFlight hand-over
        let sinkParked = ScriptSink([.ok(4)])
        let wParked = try NativeStdoutWriter.Writer.create(sink: sinkParked, runner: NativeStdoutWriter.Parked())
        wParked.start(bytes: Array("wxyz".utf8))
        #expect(wParked.collect() == .busy)
        #expect(wParked.waitCollect(graceNs: 1_000) == .reclaimed)
        wParked.release()

        // Stepped race: abandon during .writing causes publish() to return false
        let sinkRace = ScriptSink([.ok(4)])
        let wRace = try NativeStdoutWriter.Writer.create(
            sink: sinkRace,
            runner: NativeStdoutWriter.ThreadRunner(autoDrain: false)
        )
        wRace.start(bytes: Array("race".utf8))
        #expect(wRace.pick())
        #expect(wRace.writeStep() == .written)
        wRace.handle().invoke() // abandon while .writing
        #expect(!wRace.publish(written: true))

        // In-memory pipe + FdSink + sync-output framing
        let pipe = try NativeStdoutWriter.testPipe(capacity: 4096)
        defer { NativeStdoutWriter.closeAll(pipe) }
        let fdWriter = try NativeStdoutWriter.StdoutWriter.create(
            sink: NativeStdoutWriter.FdSink(fd: pipe.writeFd),
            runner: NativeStdoutWriter.ThreadRunner()
        )
        let framedOutcome = fdWriter.writeFramed(Array("HELLO".utf8), syncOutput: true)
        #expect(framedOutcome == .written)
        let expected = "\u{1B}[?2026hHELLO\u{1B}[?2026l"
        let received = try NativeStdoutWriter.readExactly(fd: pipe.readFd, count: expected.utf8.count)
        #expect(String(decoding: received, as: UTF8.self) == expected)
        fdWriter.abandon()

        #expect(NativeStdoutWriter.pinLibrary() == NativeStdoutWriter.supported)
        #expect(NativeStdoutWriter.stdoutSupported(isTTY: false) == false)
        #expect(NativeStdoutWriter.stdoutSupported(isTTY: true) == NativeStdoutWriter.supported)
        try NativeStdoutWriter.waitThreadsGone()
    }

    // MARK: - 11. Global-State Serialized Suite (NativeLogger, NativeFileLogger, NativeTextWork)

    @Suite("NativeSubsystemsIO — Serialized Global State", .serialized)
    struct SerializedGlobalStateTests {

        @Test("NativeDiagnostics ring buffer, zero-capacity drop counter, and truncation")
        func diagnosticsRingBuffer() {
            let zero = NativeDiagnostics(capacity: 0)
            zero.logMessage(.warn, "dropped")
            #expect(zero.count == 0)
            #expect(zero.droppedCount == 1)
            #expect(zero.pop() == nil)

            let queue = NativeDiagnostics(capacity: 2)
            let logger = NativeLogger.diagnostics(queue)
            logger.info("first")
            logger.err(String(repeating: "x", count: 5000))
            logger.debug("overflow")

            #expect(queue.count == 2)
            #expect(queue.droppedCount == 1)

            let d1 = queue.pop()
            #expect(d1?.level == .info)
            #expect(d1?.messageString == "first")
            #expect(d1?.truncated == false)

            let d2 = queue.pop()
            #expect(d2?.level == .err)
            #expect(d2?.truncated == true)
            #expect(d2?.messageLen == UInt32(NativeDiagnostic.messageBytesMax))
            #expect(queue.pop() == nil)
        }

        @Test("NativeLogger process callback honors installer thread token")
        func processLoggerThreadToken() {
            let received = Mutex<[(UInt8, String)]>([])
            NativeLogger.setLogCallback({ level, bytes in
                received.withLock { $0.append((level, String(decoding: bytes, as: UTF8.self))) }
            }, threadToken: 42)
            defer { NativeLogger.setLogCallback(nil, threadToken: 0) }

            #expect(NativeLogger.processLogReady(threadToken: 42))
            #expect(!NativeLogger.processLogReady(threadToken: 99))

            NativeLogger.warn("ignored-other-thread", threadToken: 99)
            NativeLogger.err("owner-err", threadToken: 42)
            NativeLogger.info("owner-info", threadToken: 42)
            NativeLogger.debug("owner-debug", threadToken: 42)

            let items = received.withLock { $0 }
            #expect(items.count == 3)
            #expect(items[0].0 == NativeLogLevel.err.rawValue && items[0].1 == "owner-err")
            #expect(items[1].0 == NativeLogLevel.info.rawValue && items[1].1 == "owner-info")
            #expect(items[2].0 == NativeLogLevel.debug.rawValue && items[2].1 == "owner-debug")
        }

        @Test("NativeFileLogger auto-init header, formatted entries, level filter, and shutdown")
        func fileLoggerFormattingAndLifecycle() {
            let sink = MemoryFileLogSink()
            let clock = Atomic<Int64>(1_700_000_000_000_000)
            NativeFileLogger.configure(sink: sink, maxLevel: .info) {
                clock.wrappingAdd(1_000, ordering: .relaxed).oldValue
            }
            defer { NativeFileLogger.configure(sink: nil) }

            NativeFileLogger.warn("disk low")
            NativeFileLogger.debug("filtered out")
            NativeFileLogger.err("boom")

            #expect(sink.filename == "opentui_debug_1700000000.log")
            #expect(sink.isOpen)
            #expect(sink.text.contains("=== Log initialized at timestamp 1700000000 ===\n"))
            #expect(sink.text.contains("WARN : disk low\n"))
            #expect(sink.text.contains("ERROR: boom\n"))
            #expect(!sink.text.contains("filtered out"))
            #expect(sink.syncCount == 3) // 1 init + 2 logged lines

            NativeFileLogger.shutdown()
            #expect(!sink.isOpen)
            #expect(sink.closeCount == 1)
        }

        @Test("NativeTextWork add and take counters")
        func textWorkCounters() {
            _ = NativeTextWork.take()
            NativeTextWork.add(.layouts, 2)
            NativeTextWork.add(.layerRunsCopied, 7)
            NativeTextWork.add(.asciiBytes, 128)
            let snap = NativeTextWork.take()
            #expect(snap.layouts == 2)
            #expect(snap.layerRunsCopied == 7)
            #expect(snap.asciiBytes == 128)

            // Subsequent take is zeroed
            let zero = NativeTextWork.take()
            #expect(zero == NativeTextWork.Counts())
        }
    }
}
