import Testing
import OpenTUICore
import OpenTUIRenderables
import OpenTUITerminal

// MARK: - Unified Diff Conformance & Unit Tests

@Suite("DiffParser Conformance & Unit Tests")
struct DiffParserConformanceTests {
    @Test("Every row in upstream diff.conformance.json passes")
    func diffConformanceCorpus() throws {
        let rows = try RenderableConformanceLoader.loadDiffConformance()
        #expect(rows.count == 15)

        for row in rows {
            switch row.expected {
            case .error:
                #expect(throws: DiffParseError.self) {
                    _ = try parseUnifiedDiff(row.diff)
                }
            case .hunks(let expectedHunks):
                let parsed = try parseUnifiedDiff(row.diff)
                let actualHunks = parsed.hunks.map { hunk in
                    hunk.lines.map(\.signedLine)
                }
                #expect(
                    actualHunks == expectedHunks,
                    "Diff conformance row #\(row.index) '\(row.name)': got \(actualHunks), expected \(expectedHunks)"
                )
            }
        }
    }

    @Test("Diff unified & split view projection and hunk row offsets")
    func diffUnifiedAndSplitProjections() throws {
        let patch = """
        diff --git a/demo.swift b/demo.swift
        --- a/demo.swift
        +++ b/demo.swift
        @@ -1,3 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 20
        +let c = 30
         let d = 4
        @@ -10,2 +11,1 @@
        -let old = true
         let keep = true
        """
        let parsed = try parseUnifiedDiff(patch)
        #expect(parsed.oldFileName == "a/demo.swift")
        #expect(parsed.newFileName == "b/demo.swift")
        #expect(parsed.hunks.count == 2)

        let unified = buildUnifiedDiffLines(parsed)
        #expect(unified.hunkRowOffsets == [0, 5])
        #expect(unified.lines.count == 7)
        #expect(unified.lines[1].kind == .removed && unified.lines[1].oldLineNumber == 2)
        #expect(unified.lines[2].kind == .added && unified.lines[2].newLineNumber == 2)
        #expect(unified.lines[3].kind == .added && unified.lines[3].newLineNumber == 3)

        let split = buildSplitDiffLines(parsed)
        #expect(split.left.count == split.right.count)
        #expect(split.hunkRowOffsets == [0, 4])
        // Removed 1 line paired with 2 added lines -> left gets 1 empty padding row
        #expect(split.left[1].kind == .removed && split.right[1].kind == .added)
        #expect(split.left[2].kind == .empty && split.right[2].kind == .added)
    }

    @Test("Diff malformed hunk headers and premature hunk end report errors")
    func diffMalformedErrors() {
        #expect(throws: DiffParseError.self) {
            _ = try parseUnifiedDiff("@@ invalid @@\n-a\n+b\n")
        }
        #expect(throws: DiffParseError.self) {
            _ = try parseUnifiedDiff("@@ -1,3 +1,3 @@\n a\n@@ -10,1 +10,1 @@\n b\n")
        }
        #expect(throws: DiffParseError.self) {
            _ = try parseUnifiedDiff("@@ -1,1 +1,1 @@\n-a\n-b\n")
        }
    }
}

// MARK: - Markdown Conformance & Unit Tests

@Suite("MarkdownParser Conformance & Unit Tests")
struct MarkdownParserConformanceTests {
    @Test("Upstream markdown.conformance.json corpus")
    func markdownConformanceCorpus() throws {
        let rows = try RenderableConformanceLoader.loadMarkdownConformance()
        #expect(rows.count == 800)

        var passed = 0
        var failures: [(index: Int, name: String, actual: String, expected: String)] = []

        for row in rows {
            let enableMath = row.name.hasPrefix("math")
            let doc = parseMarkdown(row.source, options: MarkdownParseOptions(enableGFM: true, enableMath: enableMath))
            let actualNorm = normalizeMarkdownHTML(doc.renderHTML())
            let expectedNorm = normalizeMarkdownHTML(row.expectedHTML)

            if actualNorm == expectedNorm {
                passed += 1
            } else {
                failures.append((row.index, row.name, actualNorm, expectedNorm))
            }
        }

        if !failures.isEmpty {
            let preview = failures.prefix(25).map { f in
                "  [\(f.index)] \(f.name):\n    got:      \(f.actual.debugDescription)\n    expected: \(f.expected.debugDescription)"
            }.joined(separator: "\n")
            Issue.record("Markdown conformance: \(passed)/\(rows.count) passed (\(failures.count) failed).\nFirst failures:\n\(preview)")
        }
        #expect(passed == rows.count)
    }

    @Test("Markdown AST structure for headings, tables, task lists, emphasis, code, links")
    func markdownASTStructure() {
        let md = """
        # Hello *World*

        - [ ] First
        - [x] Second ~~old~~

        | Name | Value |
        | :--- | ---: |
        | `x` | [link](https://example.com "t") |
        """
        let doc = parseMarkdown(md)
        #expect(doc.blocks.count == 3)
        if case .heading(let level, let content) = doc.blocks[0] {
            #expect(level == 1)
            #expect(content == [.text("Hello "), .emphasis([.text("World")])])
        } else {
            Issue.record("Expected heading block")
        }
        if case .list(let ordered, _, let tight, let items) = doc.blocks[1] {
            #expect(!ordered && tight && items.count == 2)
            #expect(items[0].taskChecked == false)
            #expect(items[1].taskChecked == true)
        } else {
            Issue.record("Expected list block")
        }
        if case .table(let alignments, let header, let rows) = doc.blocks[2] {
            #expect(alignments == [.left, .right])
            #expect(header.count == 2)
            #expect(rows.count == 1)
        } else {
            Issue.record("Expected table block")
        }
    }
}

// MARK: - TextTableWidth Tests

@Suite("TextTableWidth Solver Tests")
struct TextTableWidthTests {
    @Test("Proportional allocation matches upstream square-root priority regressions")
    func proportionalRegressions() {
        #expect(allocateProportionalColumnWidths([91, 9], targetWidth: 37, minWidth: 1) == [28, 9])
        #expect(allocateProportionalColumnWidths([91, 9], targetWidth: 38, minWidth: 1) == [29, 9])
        #expect(allocateProportionalColumnWidths([1000, 100], targetWidth: 401, minWidth: 1) == [305, 96])
        #expect(allocateProportionalColumnWidths([1000, 100], targetWidth: 402, minWidth: 1) == [305, 97])
        #expect(allocateProportionalColumnWidths([4, 49, 4, 54, 38], targetWidth: 104, minWidth: 1) == [4, 33, 4, 34, 29])
        #expect(allocateProportionalColumnWidths([2_516_760, 2_528_584], targetWidth: 58_886, minWidth: 1) == [29_408, 29_478])
    }

    @Test("Proportional allocation resolves exact priority ties by lower index (including >53-bit cross-products)")
    func proportionalTieBreaking() {
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 10, minWidth: 3) == [4, 3, 3])
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 11, minWidth: 3) == [4, 4, 3])
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 12, minWidth: 3) == [4, 4, 4])
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 13, minWidth: 3) == [5, 4, 4])
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 17, minWidth: 3) == [6, 6, 5])
        #expect(allocateProportionalColumnWidths([7, 7, 7], targetWidth: 20, minWidth: 3) == [7, 7, 6])
        #expect(allocateProportionalColumnWidths([19, 3], targetWidth: 5, minWidth: 1) == [4, 1])
        #expect(
            allocateProportionalColumnWidths([4_000_000_001, 1_000_000_001], targetWidth: 300_001, minWidth: 1)
                == [200_001, 100_000]
        )
    }

    @Test("Clamps targets and preserves hard minimums and intrinsic caps")
    func proportionalClampingAndBalancedFitter() {
        #expect(allocateProportionalColumnWidths([4, 49, 4, 54, 38], targetWidth: 3, minWidth: 1) == [1, 1, 1, 1, 1])
        #expect(allocateProportionalColumnWidths([4, 49, 4, 54, 38], targetWidth: 149, minWidth: 1) == [4, 49, 4, 54, 38])
        #expect(allocateProportionalColumnWidths([4, 49, 4, 54, 38], targetWidth: 200, minWidth: 1) == [4, 49, 4, 54, 38])
        #expect(allocateProportionalColumnWidths([2, 8, 20], targetWidth: 14, minWidth: 3) == [3, 5, 6])
        #expect(fitTextTableColumnWidths([4, 49, 4, 54, 38], targetWidth: 104, minWidth: 1, fitter: .proportional) == [4, 33, 4, 34, 29])
        let balanced = fitTextTableColumnWidths([10, 40, 20], targetWidth: 40, minWidth: 2, fitter: .balanced)
        #expect(balanced.reduce(0, +) == 40)
        #expect(balanced.allSatisfy { $0 >= 2 })
    }

    @Test("Proportional allocation is prefix-monotonic across deterministic vectors")
    func proportionalMonotonicity() {
        var seed: UInt32 = 0x1259
        func nextRand() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        for _ in 0..<25 {
            let cols = Int(nextRand() % 5) + 2
            let minWidth = Int(nextRand() % 3) + 1
            let widths = (0..<cols).map { _ in Int(nextRand() % 35) + minWidth }
            let minTotal = cols * minWidth
            let maxTotal = widths.reduce(0, +)
            var previous = allocateProportionalColumnWidths(widths, targetWidth: minTotal, minWidth: minWidth)
            for target in (minTotal + 1)...maxTotal {
                let next = allocateProportionalColumnWidths(widths, targetWidth: target, minWidth: minWidth)
                #expect(next.reduce(0, +) == target)
                for c in 0..<cols {
                    #expect(next[c] >= previous[c])
                    #expect(next[c] <= widths[c])
                }
                previous = next
            }
        }
    }
}

// MARK: - QRCode ISO/IEC 18004:2024 Conformance & Render Tests

@Suite("QRCode Conformance & Rendering Tests")
struct QRCodeConformanceTests {
    @Test("Numeric, alphanumeric, Kanji, and ECI segment bitstreams match ISO/IEC 18004:2024")
    func qrSegmentBitstreams() throws {
        let numeric = try QrSegment.makeNumeric("01234567")
        #expect(numeric.data.bitString == "000000110001010110011000011")
        #expect(try numeric.getTotalBits(version: 1) == 41)

        let alpha = try QrSegment.makeAlphanumeric("AC-42")
        #expect(alpha.data.bitString == "0011100111011100111001000010")
        #expect(try alpha.getTotalBits(version: 1) == 41)

        let kanji = try QrSegment.makeKanjiFromShiftJis([0x93, 0x5F, 0xE4, 0xAA])
        #expect(kanji.data.bitString == "01101100111111101010101010")
        #expect(try kanji.getTotalBits(version: 1) == 38)

        #expect(try QrSegment.makeEci(9).data.bitString == "00001001")
        #expect(try QrSegment.makeEci(128).data.bitString == "1000000010000000")
        #expect(try QrSegment.makeEci(999_999).data.bitString == "110011110100001000111111")
    }

    @Test("Version 1-M numeric codeword placement matches published ISO vector")
    func qrVersion1MPlacedCodewords() throws {
        let qr = try QRCode.encodeText(
            "01234567",
            ecl: .M,
            options: EncodeOptions(minVersion: 1, maxVersion: 1, mask: 2, boostEcl: false, eciForUtf8: false)
        )
        let placed = try readPlacedCodewords(modules: qr.toMatrix(), version: qr.version, mask: qr.mask)
        #expect(placed == [
            0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
            0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55,
        ])
    }

    @Test("All 32 format-information sequences and representative version-information sequences match ISO table")
    func qrFormatAndVersionInformation() throws {
        let expectedFormat = [
            0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0,
            0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976,
            0x1689, 0x13BE, 0x1CE7, 0x19D0, 0x0762, 0x0255, 0x0D0C, 0x083B,
            0x355F, 0x3068, 0x3F31, 0x3A06, 0x24B4, 0x2183, 0x2EDA, 0x2BED,
        ]
        let eclByBits: [Int: ErrorCorrectionLevel] = [0b00: .M, 0b01: .L, 0b10: .H, 0b11: .Q]
        for dataBits in 0..<expectedFormat.count {
            let ecl = eclByBits[dataBits >> 3]!
            let mask = dataBits & 0b111
            let qr = try QRCode.encodeText(
                "A",
                ecl: ecl,
                options: EncodeOptions(minVersion: 1, maxVersion: 1, mask: mask, boostEcl: false, eciForUtf8: false)
            )
            let m = qr.toMatrix()
            #expect(readPrimaryFormatBits(m) == expectedFormat[dataBits])
            #expect(readSecondaryFormatBits(m) == expectedFormat[dataBits])
        }

        let versionVectors: [(Int, Int)] = [
            (7, 0x07C94), (8, 0x085BC), (14, 0x0E60D), (21, 0x15683), (32, 0x209D5), (40, 0x28C69),
        ]
        for (version, expected) in versionVectors {
            let qr = try QRCode.encodeText(
                "A",
                ecl: .H,
                options: EncodeOptions(minVersion: version, maxVersion: version, mask: 0, boostEcl: false, eciForUtf8: false)
            )
            let m = qr.toMatrix()
            #expect(readTopRightVersionBits(m) == expected)
            #expect(readBottomLeftVersionBits(m) == expected)
        }
    }

    @Test("Capacity boundaries, symbology identifiers, and half-block / terminal / SVG rendering")
    func qrCapacitySymbologyAndRender() throws {
        // Data capacity boundaries
        _ = try QRCode.encodeSegments(
            [try QrSegment.makeNumeric(String(repeating: "1", count: 17))],
            ecl: .H,
            options: EncodeOptions(minVersion: 1, maxVersion: 1, mask: 0, boostEcl: false)
        )
        #expect(throws: QRCodeError.self) {
            _ = try QRCode.encodeSegments(
                [try QrSegment.makeNumeric(String(repeating: "1", count: 18))],
                ecl: .H,
                options: EncodeOptions(minVersion: 1, maxVersion: 1, mask: 0, boostEcl: false)
            )
        }
        _ = try QRCode.encodeSegments(
            [try QrSegment.makeNumeric(String(repeating: "1", count: 7089))],
            ecl: .L,
            options: EncodeOptions(minVersion: 40, maxVersion: 40, mask: 0, boostEcl: false)
        )
        #expect(throws: QRCodeError.self) {
            _ = try QRCode.encodeSegments(
                [try QrSegment.makeNumeric(String(repeating: "1", count: 7090))],
                ecl: .L,
                options: EncodeOptions(minVersion: 40, maxVersion: 40, mask: 0, boostEcl: false)
            )
        }

        // Symbology identifiers ]Q1 .. ]Q6
        #expect(try QRCode.encodeText("ABC", ecl: .M, options: EncodeOptions(eciForUtf8: false)).symbologyIdentifier == "]Q1")
        #expect(try QRCode.encodeEciText("\\000009ABC", ecl: .M).symbologyIdentifier == "]Q2")
        #expect(try QRCode.encodeGs1Text("0104912345123459", ecl: .M).symbologyIdentifier == "]Q3")
        #expect(
            try QRCode.encodeSegments(
                [try QrSegment.makeEci(EciAssignment.iso8859_1), try QrSegment.makeBytes([0x41])],
                ecl: .M,
                options: EncodeOptions(fnc1First: true)
            ).symbologyIdentifier == "]Q4"
        )
        #expect(
            try QRCode.encodeSegments(
                [try QrSegment.makeAlphanumeric("AA1234")],
                ecl: .M,
                options: EncodeOptions(fnc1Second: Fnc1SecondPositionInfo(applicationIndicator: 37))
            ).symbologyIdentifier == "]Q5"
        )
        #expect(
            try QRCode.encodeSegments(
                [try QrSegment.makeEci(EciAssignment.iso8859_1), try QrSegment.makeBytes([0x41])],
                ecl: .M,
                options: EncodeOptions(fnc1Second: Fnc1SecondPositionInfo(applicationIndicator: 37))
            ).symbologyIdentifier == "]Q6"
        )

        // Rendering: half-block, full-block, ANSI, and SVG
        let qr = try QRCode.encodeText("https://opentui.com", ecl: .M)
        let halfBlock = try qr.toHalfBlockString(border: 4)
        let hbLines = halfBlock.split(separator: "\n", omittingEmptySubsequences: false)
        let totalModules = qr.size + 8
        #expect(hbLines.count == (totalModules + 1) / 2)
        #expect(hbLines.allSatisfy { $0.count == totalModules })
        #expect(halfBlock.contains("█") || halfBlock.contains("▀") || halfBlock.contains("▄"))

        let fullBlock = try qr.toTerminalString(options: TerminalRenderOptions(border: 4, ansi: false))
        #expect(fullBlock.split(separator: "\n").count == totalModules)
        let ansiOut = try qr.toTerminalString(options: TerminalRenderOptions(border: 4, ansi: true))
        #expect(ansiOut.contains("\u{1B}[40m") && ansiOut.contains("\u{1B}[47m"))

        let svg = try qr.toSvgString(border: 4, moduleSize: 2)
        #expect(svg.hasPrefix("<svg ") && svg.hasSuffix("</svg>"))
    }
}

// MARK: - QR Conformance Test Helpers

private func readPrimaryFormatBits(_ modules: [[Bool]]) -> Int {
    var bits = 0
    for i in 0...5 { if modules[i][8] { bits |= 1 << i } }
    if modules[7][8] { bits |= 1 << 6 }
    if modules[8][8] { bits |= 1 << 7 }
    if modules[8][7] { bits |= 1 << 8 }
    for i in 9..<15 { if modules[8][14 - i] { bits |= 1 << i } }
    return bits
}

private func readSecondaryFormatBits(_ modules: [[Bool]]) -> Int {
    let size = modules.count
    var bits = 0
    for i in 0..<8 { if modules[8][size - 1 - i] { bits |= 1 << i } }
    for i in 8..<15 { if modules[size - 15 + i][8] { bits |= 1 << i } }
    return bits
}

private func readTopRightVersionBits(_ modules: [[Bool]]) -> Int {
    let size = modules.count
    var bits = 0
    for i in 0..<18 {
        if modules[i / 3][size - 11 + (i % 3)] { bits |= 1 << i }
    }
    return bits
}

private func readBottomLeftVersionBits(_ modules: [[Bool]]) -> Int {
    let size = modules.count
    var bits = 0
    for i in 0..<18 {
        if modules[size - 11 + (i % 3)][i / 3] { bits |= 1 << i }
    }
    return bits
}

private func readPlacedCodewords(modules: [[Bool]], version: Int, mask: Int) throws -> [UInt8] {
    let size = modules.count
    var funcMap = Array(repeating: Array(repeating: false, count: size), count: size)
    func mark(_ x: Int, _ y: Int) {
        if x >= 0 && y >= 0 && x < size && y < size { funcMap[y][x] = true }
    }
    func markFinder(_ cx: Int, _ cy: Int) {
        for dy in -4...4 { for dx in -4...4 { mark(cx + dx, cy + dy) } }
    }
    for i in 0..<size {
        mark(i, 6)
        mark(6, i)
    }
    markFinder(3, 3)
    markFinder(size - 4, 3)
    markFinder(3, size - 4)
    for i in 0...8 {
        mark(8, i)
        mark(i, 8)
    }
    for i in 0..<8 {
        mark(size - 1 - i, 8)
        mark(8, size - 1 - i)
    }

    var dataBits: [UInt8] = []
    var right = size - 1
    while right >= 1 {
        if right == 6 { right = 5 }
        for vert in 0..<size {
            for j in 0..<2 {
                let x = right - j
                let upward = ((right + 1) & 2) == 0
                let y = upward ? size - 1 - vert : vert
                if funcMap[y][x] { continue }
                let unmasked = modules[y][x] != (try QRCode.maskCondition(mask: mask, x: x, y: y))
                dataBits.append(unmasked ? 1 : 0)
            }
        }
        right -= 2
    }

    var codewords: [UInt8] = []
    var i = 0
    while i + 7 < dataBits.count {
        var val: UInt8 = 0
        for j in 0..<8 { val = (val << 1) | dataBits[i + j] }
        codewords.append(val)
        i += 8
    }
    return codewords
}

// MARK: - PlatformTerminalBackend Tests

@Suite("PlatformTerminalBackend Tests")
struct PlatformTerminalBackendTests {
    @Test("PlatformTerminalBackend conforms to TerminalBackend and safely reports size & handles non-TTY fds")
    func platformTerminalSafetyAndFallback() async throws {
        // Using invalid fds (-1) avoids touching the host test runner's real stdin/stdout
        #if os(macOS) || os(Linux) || os(FreeBSD) || os(Android)
        let backend = PlatformTerminalBackend(
            inputFD: -1,
            outputFD: -1,
            defaultSize: TerminalSize(width: 100, height: 30)
        )
        #else
        let backend = PlatformTerminalBackend(defaultSize: TerminalSize(width: 100, height: 30))
        #endif

        let size = await backend.size
        #expect(size == TerminalSize(width: 100, height: 30))

        // Empty writes are always a safe no-op
        try await backend.write([])

        // exitRawMode when not in raw mode is idempotent and does not throw
        try await backend.exitRawMode()
        #expect(await backend.isRawMode == false)

        // enterRawMode on a non-TTY descriptor reports a structured PlatformTerminalError
        await #expect(throws: PlatformTerminalError.self) {
            try await backend.enterRawMode()
        }
        #expect(await backend.isRawMode == false)

        // Default backend size query always returns positive dimensions
        let defaultBackend = PlatformTerminalBackend()
        let detected = await defaultBackend.size
        #expect(detected.width > 0 && detected.height > 0)
    }
}
