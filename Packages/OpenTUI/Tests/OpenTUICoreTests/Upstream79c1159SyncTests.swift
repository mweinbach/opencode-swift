import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

@Suite("Upstream 79c1159 Parity Sync (BoxSizing, FlexBasis %, Zero-Width Edits)")
struct Upstream79c1159SyncTests {
    // MARK: - 1. isFlexBasisType & parseBoxSizing

    @Test("isFlexBasisType validates percentage strings within float32 range matching upstream")
    func flexBasisValidation() {
        #expect(isFlexBasisType(.number(100)))
        #expect(isFlexBasisType(.string("auto")))
        #expect(isFlexBasisType(.undefined))
        #expect(isFlexBasisType(.string("50%")))
        #expect(isFlexBasisType(.string("-12.5%")))
        #expect(isFlexBasisType(.string("+50%")))
        #expect(isFlexBasisType(.string("5e1%")))
        #expect(isFlexBasisType(.string("5.%")))
        #expect(isFlexBasisType(.string(".5%")))
        #expect(isFlexBasisType(.string(" 50 %")))
        #expect(isFlexBasisType(.string("0x0%")))
        #expect(isFlexBasisType(.string("1e-400%")))
        #expect(isFlexBasisType(.string("340282346638528859811704183484516925440%")))
        #expect(isFlexBasisType(.string("-340282346638528859811704183484516925440%")))

        #expect(!isFlexBasisType(.string("340282350000000000000000000000000000000%")))
        #expect(!isFlexBasisType(.string("-340282350000000000000000000000000000000%")))
        #expect(!isFlexBasisType(.string("%")))
        #expect(!isFlexBasisType(.string("   %")))
        #expect(!isFlexBasisType(.string("0x10%")))
        #expect(!isFlexBasisType(.string("+0x0%")))
        #expect(!isFlexBasisType(.string("50")))
        #expect(!isFlexBasisType(.string("50px%")))
        #expect(!isFlexBasisType(.string("Infinity%")))
        #expect(!isFlexBasisType(.string("-Infinity%")))
        #expect(!isFlexBasisType(.string("NaN%")))
        #expect(!isFlexBasisType(.string("1" + String(repeating: "0", count: 39) + "%")))
        #expect(!isFlexBasisType(.number(.nan)))
        #expect(!isFlexBasisType(.null))
    }

    @Test("parseBoxSizing handles content-box case-insensitively and defaults to borderBox")
    func parseBoxSizingParity() {
        #expect(parseBoxSizing("content-box") == .contentBox)
        #expect(parseBoxSizing("CONTENT-BOX") == .contentBox)
        #expect(parseBoxSizing("Content-Box") == .contentBox)
        #expect(parseBoxSizing("border-box") == .borderBox)
        #expect(parseBoxSizing("BORDER-BOX") == .borderBox)
        #expect(parseBoxSizing("padding-box") == .borderBox)
        #expect(parseBoxSizing("") == .borderBox)
        #expect(parseBoxSizing(nil) == .borderBox)
    }

    // MARK: - 2. Renderable boxSizing, getBoxSizing, flexBasis %, ScrollBoxContent boxSizing

    @Test("content-box adds padding to box and scroll content sizes, and percentage flexBasis sizes a child")
    func contentBoxAndPercentageFlexBasis() {
        let test = createTestRenderer(width: 40, height: 20)
        defer { test.destroy() }

        let contentBox = BoxOptions(minHeight: .point(3), padding: .point(1), boxSizing: .contentBox)
        let box = BoxRenderable(
            ctx: test.renderer,
            options: BoxOptions(
                width: .point(10),
                minHeight: .point(3),
                flexDirection: .row,
                padding: .point(1),
                boxSizing: .contentBox
            )
        )
        let scroll = ScrollBoxRenderable(
            ctx: test.renderer,
            options: ScrollBoxOptions(
                width: .point(10),
                height: .point(8),
                contentOptions: contentBox,
                scrollbarOptions: ScrollBarOptions(visible: false)
            )
        )
        let child = BoxRenderable(
            ctx: test.renderer,
            options: BoxOptions(height: .point(1), flexBasis: .percent(50))
        )
        box.add(child)
        test.root.add(box)
        test.root.add(scroll)

        #expect(box.getBoxSizing() == .contentBox)
        #expect(child.getBoxSizing() == .borderBox)
        #expect(child.getFlexBasis() == .percent(50))

        func geometry() -> [Int] {
            test.renderOnce()
            return [box.width, box.height, scroll.content.height, child.width]
        }

        #expect(geometry() == [12, 5, 5, 5])

        child.flexBasis = .percent(30)
        scroll.content.boxSizing = .borderBox
        #expect(geometry() == [12, 5, 3, 3])

        box.setBoxSizing(nil)
        child.flexBasis = .undefined
        #expect(box.getBoxSizing() == .borderBox)
        #expect(geometry() == [10, 3, 3, 0])

        // Dynamic prop setter parity for boxSizing & flexBasis
        setRenderableProp(box, name: "boxSizing", value: "content-box")
        setRenderableProp(child, name: "flexBasis", value: "60%")
        #expect(box.getBoxSizing() == .contentBox)
        #expect(child.getFlexBasis() == .percent(60))
        #expect(geometry() == [12, 5, 3, 6])

        // Invalid percentage string ignored by setRenderableProp
        setRenderableProp(child, name: "flexBasis", value: "50px%")
        #expect(child.getFlexBasis() == .percent(60))

        // Destroyed node falls back to borderBox
        box.destroy()
        #expect(box.getBoxSizing() == .borderBox)

        // LayoutOptions carries boxSizing cleanly
        let layoutOpts = LayoutOptions(flexBasis: .percent(25), boxSizing: .contentBox)
        #expect(layoutOpts.flexBasis == .percent(25))
        #expect(layoutOpts.boxSizing == .contentBox)
    }

    // MARK: - 3. Rope split_at_weight with left bias & isVoid

    @Test("NativeZigRope split_at_weight under left bias splits leading zero-width text and avoids void left leaves")
    func ropeSplitAtWeightZeroWidthAndVoid() throws {
        let weightOf: @Sendable (String) -> UInt32 = { s in
            calculateTextWidth(s, tabWidth: 2, controlDisplay: .hidden, widthMethod: .unicode)
        }
        let splitter = NativeZigRope.Rope<String>.Node.LeafSplitFn { leaf, weight in
            let bytes = Array(leaf.utf8)
            let ascii = isAsciiOnly(bytes)
            if weight == 0 && ascii {
                return .init(left: "", right: leaf)
            }
            let pos = findPosByWidth(
                bytes,
                maxColumns: weight,
                tabWidth: 2,
                controlDisplay: .hidden,
                isASCIIOnly: ascii,
                includeStartBefore: false,
                widthMethod: .unicode
            )
            let idx = min(Int(pos.byteOffset), bytes.count)
            return .init(
                left: String(decoding: bytes[0..<idx], as: UTF8.self),
                right: String(decoding: bytes[idx...], as: UTF8.self)
            )
        }
        let isVoid: (String) -> Bool = { $0.isEmpty }

        // Separate pieces ["\t", "\u{0301}cde"]: left-biased insert at weight 2 lands AFTER "\u{0301}"
        var twoPiece = NativeZigRope.Rope<String>(items: ["\t", "\u{0301}cde"], weightOf: weightOf)
        _ = try twoPiece.insertSliceByWeight(weight: 2, bias: .left, elements: ["Z"], splitLeafFn: splitter, isVoid: isVoid)
        #expect(twoPiece.toArray().joined() == "\t\u{0301}Zcde")
        #expect(!twoPiece.toArray().contains(""))

        // Single piece ["\t\u{0301}cde"] produces the exact same text
        var onePiece = NativeZigRope.Rope<String>(items: ["\t\u{0301}cde"], weightOf: weightOf)
        _ = try onePiece.insertSliceByWeight(weight: 2, bias: .left, elements: ["Z"], splitLeafFn: splitter, isVoid: isVoid)
        #expect(onePiece.toArray().joined() == twoPiece.toArray().joined())

        // ASCII leaf at weight 0 under left bias leaves no void left leaf in the tree
        var asciiTwoPiece = NativeZigRope.Rope<String>(items: ["\t", "cde"], weightOf: weightOf)
        _ = try asciiTwoPiece.insertSliceByWeight(weight: 2, bias: .left, elements: ["Z"], splitLeafFn: splitter, isVoid: isVoid)
        #expect(asciiTwoPiece.toArray() == ["\t", "Z", "cde"])

        // Right-biased insert at weight 0 lands BEFORE leading zero-width text
        var lineStart = NativeZigRope.Rope<String>(items: ["\u{0301}cde"], weightOf: weightOf)
        _ = try lineStart.insertSliceByWeight(weight: 0, bias: .right, elements: ["Z"], splitLeafFn: splitter, isVoid: isVoid)
        #expect(lineStart.toArray().joined() == "Z\u{0301}cde")
    }

    // MARK: - 4. UnifiedTextBuffer.byteAtCell & EditBuffer zero-width parity (upstream rope_fuzz_test.zig)

    @Test("Insert next to zero-width pieces matches single-piece text and byteAtOffset across heads, marks, and columns")
    func zeroWidthInsertAndByteAtOffsetParity() {
        let marks = ["\u{0301}", "\u{200B}"]
        let heads = ["ab", "", "\t"]
        let cols: [UInt32] = [0, 2, 4]
        let tailSource = Array("cdef")

        for mark in marks {
            for head in heads {
                let tailCount = 4 - head.utf8.count
                let tail = String(tailSource[0..<tailCount])
                let headEnd: UInt32 = head.isEmpty ? 0 : 2

                for count in 0..<12 {
                    let repeatedMarks = String(repeating: mark, count: count)
                    let fullText = head + repeatedMarks + tail

                    for col in cols {
                        var results: [String] = []
                        var editBytes: [UInt32] = []

                        for pieces in 0..<3 {
                            let eb = NativeZigEditBuffer.EditBuffer(options: .init(widthMethod: .unicode, tabWidth: 2, id: 1))
                            if pieces == 0 {
                                eb.setText(fullText)
                            } else if pieces == 1 {
                                eb.setText(head)
                                for _ in 0..<count {
                                    eb.getTextBuffer().append(mark)
                                }
                                eb.getTextBuffer().append(tail)
                            } else {
                                eb.setText(head)
                                eb.setCursor(row: 0, col: headEnd)
                                eb.insertText(repeatedMarks + tail)
                            }

                            let clampedOffset = min(col, eb.getTextBuffer().getLength())
                            editBytes.append(eb.getTextBuffer().byteAtOffset(clampedOffset))

                            eb.setCursor(row: 0, col: col)
                            eb.insertText("Z")
                            results.append(eb.getText())
                        }

                        #expect(results[1] == results[0], "mark=\(mark.unicodeScalars.first!.value) head=\(head) count=\(count) col=\(col)")
                        #expect(results[2] == results[0], "mark=\(mark.unicodeScalars.first!.value) head=\(head) count=\(count) col=\(col)")
                        #expect(editBytes[1] == editBytes[0], "byteAtOffset mismatch pieces=1")
                        #expect(editBytes[2] == editBytes[0], "byteAtOffset mismatch pieces=2")

                        // Explicit behavioral checks matching upstream:
                        // - At col == 0 (line start), insert goes BEFORE leading zero-width marks.
                        // - At col == 2 after "\t" or "ab", insert goes AFTER zero-width marks.
                        if col == 0 {
                            #expect(results[0] == "Z" + fullText)
                        } else if col == 2 && (head == "\t" || head == "ab") {
                            #expect(results[0] == head + repeatedMarks + "Z" + tail)
                            #expect(editBytes[0] == UInt32((head + repeatedMarks).utf8.count))
                        }
                    }
                }
            }
        }
    }

    @Test("Marks typed at one place with interleaved edits elsewhere stay in typed order")
    func marksStayInTypedOrder() {
        let eb = NativeZigEditBuffer.EditBuffer(options: .init(widthMethod: .unicode, tabWidth: 2, id: 1))
        eb.setText("abc\ndef\nghi\njkl")
        let steps: [(String, UInt32)] = [("\u{0300}", 1), ("\u{0301}", 0), ("\u{0302}", 1)]
        for (mark, col) in steps {
            eb.setCursor(row: 0, col: 3)
            eb.insertText(mark)
            eb.setCursor(row: 1, col: col)
            eb.insertText("x")
        }
        #expect(eb.getText().hasPrefix("abc\u{0300}\u{0301}\u{0302}\n"))
    }

    @Test("UnifiedTextBuffer.byteAtCell and EditBuffer.splitChunkAtWeight handle weight 0 zero-width prefixes")
    func byteAtCellAndSplitChunkWeightZero() {
        let eb = NativeZigEditBuffer.EditBuffer(options: .init(widthMethod: .unicode, tabWidth: 2, id: 1))
        eb.setText("\u{200B}abc")
        // byteAtCell(weight: 0, wholeGrapheme: false) advances past leading zero-width U+200B (3 UTF-8 bytes)
        #expect(eb.getTextBuffer().byteAtCell(weight: 0, wholeGrapheme: false) == 3)
        #expect(eb.getTextBuffer().byteAtCell(weight: 0, wholeGrapheme: true) == 3)

        let splitZW = eb.splitChunkAtWeight(Array("\u{0301}cde".utf8), weight: 0)
        #expect(String(decoding: splitZW.left, as: UTF8.self) == "\u{0301}")
        #expect(String(decoding: splitZW.right, as: UTF8.self) == "cde")

        let splitASCII = eb.splitChunkAtWeight(Array("cde".utf8), weight: 0)
        #expect(splitASCII.left.isEmpty)
        #expect(String(decoding: splitASCII.right, as: UTF8.self) == "cde")
    }
}
