import Testing
import OpenTUICore

@Suite("OpenTUICore Unit Tests")
struct OpenTUICoreTests {
    @Test("RGBA color packing, intents, and CSS color names")
    func rgbaColorPackingAndIntents() throws {
        let indexed = try RGBA.fromIndex(196)
        #expect(indexed.intent == .indexed)
        #expect(indexed.slot == 196)
        #expect(indexed.toInts().0 == 255)
        #expect(indexed.toInts().1 == 0)
        #expect(indexed.toInts().2 == 0)

        let defFg = RGBA.defaultForeground()
        #expect(defFg.intent == .default)
        #expect(rgbToHex(parseColor("orange")) == "#ffa500")
    }

    @Test("TextAttributes and 24-bit link ID bit packing")
    func textAttributesAndLinks() {
        let base = createTextAttributes(bold: true, underline: true)
        let withLink = attributesWithLink(base, linkId: 42)
        #expect(getBaseAttributes(withLink) == base)
        #expect(getLinkId(withLink) == 42)
    }

    @Test("CellBuffer bounds safety")
    func cellBufferBounds() {
        var buf = CellBuffer(width: 10, height: 4)
        let cell = TerminalCell(scalar: UInt32(Unicode.Scalar("A").value))
        buf.setCell(x: 2, y: 1, cell: cell)
        #expect(buf.cell(atX: 2, y: 1) == cell)
        #expect(buf.cell(atX: 99, y: 0) == nil)
    }
}
