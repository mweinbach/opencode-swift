import Testing
import OpenTUIKeymap

@Suite("OpenTUIKeymap Unit Tests")
struct OpenTUIKeymapTests {
    @Test("Key normalization, match IDs, and canonical stringification")
    func keyNormalizationAndStringify() throws {
        let match = try createKeyMatch(KeyStrokeInput(name: " Return ", ctrl: true))
        #expect(match == "key:return:1:0:0:0:0")

        let str = try stringifyKeyStroke(.stroke(KeyStrokeInput(name: "Return", ctrl: true, shift: true)))
        #expect(str == "ctrl+shift+enter")

        let seq = try stringifyKeySequence(
            [.stroke(KeyStrokeInput(name: "g")), .stroke(KeyStrokeInput(name: "g"))],
            options: StringifyOptions(separator: " ")
        )
        #expect(seq == "g g")
    }
}
