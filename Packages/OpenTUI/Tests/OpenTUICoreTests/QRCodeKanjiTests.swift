import Testing
import OpenTUIRenderables

@Suite("QRCode Shift JIS & Kanji Mode Tests")
struct QRCodeKanjiTests {
    @Test("QRCodeShiftJIS table integrity and count")
    func shiftJisTableIntegrity() {
        #expect(QRCodeShiftJIS.entryCount == 6944)
        let dict = QRCodeShiftJIS.codeByCharacter()
        #expect(dict.count == 6944)
        #expect(dict["¢"] == 0x8191)
        #expect(dict["¥"] == 0x005C)
        #expect(dict["‾"] == 0x007E)
        #expect(dict["￥"] == 0x818F)
        #expect(dict["茗"] == 0xE4AA)
        #expect(dict["荷"] == 0x89D7)
    }

    @Test("shiftJisCodeForCharacter covers ASCII, half-width Katakana, Hiragana, Kanji, and unencodable characters")
    func shiftJisCodeForCharacterLookup() {
        // ASCII (0x00...0x7F)
        #expect(shiftJisCodeForCharacter("A") == 0x41)
        #expect(shiftJisCodeForCharacter("0") == 0x30)
        #expect(shiftJisCodeForCharacter(" ") == 0x20)
        #expect(shiftJisCodeForCharacter("~") == 0x7E)
        #expect(shiftJisCodeForCharacter(Unicode.Scalar(0x00)) == 0x00)
        #expect(shiftJisCodeForCharacter(Unicode.Scalar(0x7F)) == 0x7F)

        // Single-byte Shift JIS special mappings & half-width Katakana
        #expect(shiftJisCodeForCharacter("¥") == 0x5C)
        #expect(shiftJisCodeForCharacter("‾") == 0x7E)
        #expect(shiftJisCodeForCharacter("｡") == 0xA1)
        #expect(shiftJisCodeForCharacter("ｱ") == 0xB1)
        #expect(shiftJisCodeForCharacter("ﾝ") == 0xDD)
        #expect(shiftJisCodeForCharacter("ﾟ") == 0xDF)

        // Hiragana & full-width Katakana
        #expect(shiftJisCodeForCharacter("あ") == 0x82A0)
        #expect(shiftJisCodeForCharacter("ん") == 0x82F1)
        #expect(shiftJisCodeForCharacter("テ") == 0x8365)

        // Kanji (including ISO/IEC 18004 example 点茗 and 茗荷, 漢字, 日本語)
        #expect(shiftJisCodeForCharacter("点") == 0x935F)
        #expect(shiftJisCodeForCharacter("茗") == 0xE4AA)
        #expect(shiftJisCodeForCharacter("荷") == 0x89D7)
        #expect(shiftJisCodeForCharacter("漢") == 0x8ABF)
        #expect(shiftJisCodeForCharacter("字") == 0x8E9A)
        #expect(shiftJisCodeForCharacter("日") == 0x93FA)
        #expect(shiftJisCodeForCharacter("本") == 0x967B)
        #expect(shiftJisCodeForCharacter("語") == 0x8CEA)

        // JIS X 0208 includes Russian Cyrillic (А..Я, а..я, Ё, ё)
        #expect(shiftJisCodeForCharacter("А") == 0x8440)
        #expect(shiftJisCodeForCharacter("Ё") == 0x8446)

        // Unencodable characters: emoji, non-JIS Cyrillic (Ukrainian/Serbian), Hangul, accented Latin, Euro
        #expect(shiftJisCodeForCharacter("😀") == nil)
        #expect(shiftJisCodeForCharacter("🚀") == nil)
        #expect(shiftJisCodeForCharacter("Ї") == nil)
        #expect(shiftJisCodeForCharacter("Є") == nil)
        #expect(shiftJisCodeForCharacter("Ґ") == nil)
        #expect(shiftJisCodeForCharacter("Ђ") == nil)
        #expect(shiftJisCodeForCharacter("한") == nil)
        #expect(shiftJisCodeForCharacter("é") == nil)
        #expect(shiftJisCodeForCharacter("€") == nil)

        // Empty and multi-scalar strings return nil
        #expect(shiftJisCodeForCharacter("") == nil)
        #expect(shiftJisCodeForCharacter("AB") == nil)
        #expect(shiftJisCodeForCharacter("茗荷") == nil)
    }

    @Test("encodeTextBytes encodes Shift JIS strings and rejects unencodable characters")
    func encodeTextBytesShiftJis() throws {
        let bytes = try encodeTextBytes("AB¥ｱあ茗", encoding: .shiftJis)
        #expect(bytes == [0x41, 0x42, 0x5C, 0xB1, 0x82, 0xA0, 0xE4, 0xAA])

        let kanjiBytes = try encodeTextBytes("日本語", encoding: .shiftJis)
        #expect(kanjiBytes == [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA])

        #expect(throws: QRCodeError.self) {
            _ = try encodeTextBytes("Hello😀", encoding: .shiftJis)
        }
        #expect(throws: QRCodeError.self) {
            _ = try encodeTextBytes("Київ", encoding: .shiftJis)
        }
    }

    @Test("QrSegment.isKanji identifies ISO/IEC 18004 Shift JIS Kanji-mode strings")
    func segmentIsKanji() {
        #expect(QrSegment.isKanji(""))
        #expect(QrSegment.isKanji("茗荷"))
        #expect(QrSegment.isKanji("漢字"))
        #expect(QrSegment.isKanji("日本語"))
        #expect(QrSegment.isKanji("あいうえお"))
        #expect(QrSegment.isKanji("点茗"))

        // ASCII and half-width Katakana are single-byte Shift JIS, not QR Kanji mode
        #expect(!QrSegment.isKanji("ABC"))
        #expect(!QrSegment.isKanji("123"))
        #expect(!QrSegment.isKanji("ｱｲｳ"))
        #expect(!QrSegment.isKanji("¥"))
        #expect(!QrSegment.isKanji("日本語A"))

        // Unencodable scalars
        #expect(!QrSegment.isKanji("😀"))
        #expect(!QrSegment.isKanji("Ї"))
    }

    @Test("QrSegment.makeKanji matches ISO/IEC 18004 13-bit bitstreams and char-count widths")
    func segmentMakeKanji() throws {
        // ISO/IEC 18004 published Kanji example: 点 (0x935F) + 茗 (0xE4AA)
        let tenMyou = try QrSegment.makeKanji("点茗")
        #expect(tenMyou.mode == .kanji)
        #expect(tenMyou.numChars == 2)
        #expect(tenMyou.data.length == 26)
        #expect(tenMyou.data.bitString == "01101100111111101010101010")
        #expect(try tenMyou.getTotalBits(version: 1) == 38)   // 4 + 8 + 26
        #expect(try tenMyou.getTotalBits(version: 9) == 38)
        #expect(try tenMyou.getTotalBits(version: 10) == 40)  // 4 + 10 + 26
        #expect(try tenMyou.getTotalBits(version: 26) == 40)
        #expect(try tenMyou.getTotalBits(version: 27) == 42)  // 4 + 12 + 26
        #expect(try tenMyou.getTotalBits(version: 40) == 42)

        // 茗荷 (0xE4AA, 0x89D7)
        let myouga = try QrSegment.makeKanji("茗荷")
        #expect(myouga.mode == .kanji)
        #expect(myouga.numChars == 2)
        #expect(myouga.data.length == 26)
        #expect(myouga.data.bitString == "11010101010100011010010111")
        #expect(try myouga.getTotalBits(version: 1) == 38)
        #expect(myouga.parityBytes == [0xE4, 0xAA, 0x89, 0xD7])

        // Upstream conformance test: structured append parity over numeric + Kanji
        let saSegments = [try QrSegment.makeNumeric("0123456789"), try QrSegment.makeKanji("日本")]
        #expect(QRCode.computeStructuredAppendParity(saSegments) == 0x85)

        // Rejects non-Kanji characters (ASCII, half-width katakana, emoji)
        #expect(throws: QRCodeError.self) { _ = try QrSegment.makeKanji("A") }
        #expect(throws: QRCodeError.self) { _ = try QrSegment.makeKanji("ｱ") }
        #expect(throws: QRCodeError.self) { _ = try QrSegment.makeKanji("😀") }
    }

    @Test("QRCode.encodeText with kanji: true matches upstream matrix and beats UTF-8 byte mode in size")
    func encodeTextKanjiComparison() throws {
        // 1. 茗荷: Kanji mode uses 38 bits (no ECI) vs UTF-8 byte mode 72 bits (with ECI 26)
        let kanjiSegs = try QrSegment.makeSegments("茗荷", options: EncodeOptions(kanji: true))
        let utf8Segs = try QrSegment.makeSegments("茗荷", options: EncodeOptions(kanji: false))
        #expect(kanjiSegs.count == 1)
        #expect(kanjiSegs[0].mode == .kanji)
        let kanjiBits = try kanjiSegs.reduce(0) { acc, seg in acc + (try seg.getTotalBits(version: 1) ?? 0) }
        let utf8Bits = try utf8Segs.reduce(0) { acc, seg in acc + (try seg.getTotalBits(version: 1) ?? 0) }
        #expect(kanjiBits == 38)
        #expect(utf8Bits == 72)
        #expect(kanjiBits < utf8Bits)

        let qrKanji = try QRCode.encodeText("茗荷", ecl: .M, options: EncodeOptions(kanji: true))
        let qrUtf8 = try QRCode.encodeText("茗荷", ecl: .M, options: EncodeOptions(kanji: false))
        #expect(qrKanji.version == 1)
        #expect(qrKanji.errorCorrectionLevel == .H)
        #expect(qrKanji.mask == 7)
        #expect(qrKanji.size == 21)
        #expect(!qrKanji.containsEci)
        #expect(qrKanji.symbologyIdentifier == "]Q1")

        #expect(qrUtf8.version == 1)
        #expect(qrUtf8.containsEci)
        #expect(qrUtf8.symbologyIdentifier == "]Q2")

        // Verify exact bit-for-bit upstream matrix rows and dark module count for 茗荷 Kanji QR
        let matrix = qrKanji.toMatrix()
        let row0 = matrix[0].map { $0 ? "#" : "." }.joined()
        let row10 = matrix[10].map { $0 ? "#" : "." }.joined()
        let row20 = matrix[20].map { $0 ? "#" : "." }.joined()
        let darkCount = matrix.reduce(0) { sum, row in sum + row.filter { $0 }.count }
        #expect(row0 == "#######.##.#..#######")
        #expect(row10 == ".#.#..#.###....####.#")
        #expect(row20 == "#######...##...#.##.#")
        #expect(darkCount == 228)

        // 2. 11-character Kanji string: Kanji mode fits in Version 2-M whereas UTF-8 requires Version 3-M
        let jp11 = "日本語漢字茗荷東京大阪"
        let qrJpKanji = try QRCode.encodeText(jp11, ecl: .M, options: EncodeOptions(boostEcl: false, kanji: true))
        let qrJpUtf8 = try QRCode.encodeText(jp11, ecl: .M, options: EncodeOptions(boostEcl: false, kanji: false))
        #expect(qrJpKanji.version == 2)
        #expect(qrJpKanji.mask == 4)
        #expect(qrJpUtf8.version == 3)
        #expect(qrJpUtf8.mask == 1)
        #expect(qrJpKanji.version < qrJpUtf8.version)
        #expect(qrJpKanji.size < qrJpUtf8.size)
    }

    @Test("DP segment optimizer selects Kanji segments for mixed ASCII + Kanji text")
    func mixedAsciiKanjiDpOptimization() throws {
        // Alphanumeric + Kanji: avoids ECI and byte mode completely
        let mixed1 = "HELLO123456日本語漢字"
        let optKanji1 = try QrSegment.makeOptimizedSegments(mixed1, version: 1, options: EncodeOptions(kanji: true))
        #expect(optKanji1.map(\.mode) == [.alphanumeric, .kanji])
        #expect(optKanji1.map(\.numChars) == [11, 5])
        let optKanji1Bits = try optKanji1.reduce(0) { acc, seg in acc + (try seg.getTotalBits(version: 1) ?? 0) }
        #expect(optKanji1Bits == 151)

        let optNoKanji1 = try QrSegment.makeOptimizedSegments(mixed1, version: 1, options: EncodeOptions(kanji: false))
        #expect(optNoKanji1.map(\.mode) == [.eci, .alphanumeric, .byte])
        let optNoKanji1Bits = try optNoKanji1.reduce(0) { acc, seg in acc + (try seg.getTotalBits(version: 1) ?? 0) }
        #expect(optNoKanji1Bits == 218)
        #expect(optKanji1Bits < optNoKanji1Bits)

        // Mixed lowercase ASCII (Byte+ECI) + Kanji + Numeric
        let mixed2 = "OpenTUI:日本語テスト2026"
        let optKanji2 = try QrSegment.makeOptimizedSegments(mixed2, version: 1, options: EncodeOptions(kanji: true))
        #expect(optKanji2.map(\.mode) == [.eci, .byte, .kanji, .numeric])
        #expect(optKanji2.map(\.numChars) == [0, 8, 6, 4])

        let qrMixed2 = try QRCode.encodeText(mixed2, ecl: .M, options: EncodeOptions(kanji: true))
        #expect(qrMixed2.version == 2)
        #expect(qrMixed2.errorCorrectionLevel == .M)
        #expect(qrMixed2.mask == 2)
        #expect(qrMixed2.containsEci)
        #expect(qrMixed2.symbologyIdentifier == "]Q2")

        // Shift JIS byte encoding with ECI 20 when kanji: false
        let sjisOpt = try QrSegment.makeOptimizedSegments(
            "ｱｲｳ",
            version: 1,
            options: EncodeOptions(kanji: false, byteEncoding: .shiftJis)
        )
        #expect(sjisOpt.map(\.mode) == [.eci, .byte])
        #expect(sjisOpt[0].data.toBytes() == [UInt8(EciAssignment.shiftJis)])
        #expect(sjisOpt[1].parityBytes == [0xB1, 0xB2, 0xB3])
    }
}
