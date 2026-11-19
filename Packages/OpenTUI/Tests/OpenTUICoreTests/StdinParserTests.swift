import Testing
import OpenTUICore

// MARK: - Conformance Helpers

private func jsJSONStringify(_ string: String) -> String {
    var out = "\""
    let hexDigits: [Character] = Array("0123456789abcdef")
    for scalar in string.unicodeScalars {
        let v = scalar.value
        switch v {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x09: out += "\\t"
        case 0x0A: out += "\\n"
        case 0x0C: out += "\\f"
        case 0x0D: out += "\\r"
        case 0x00...0x1F:
            out += "\\u00"
            out.append(hexDigits[Int((v >> 4) & 0xF)])
            out.append(hexDigits[Int(v & 0xF)])
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}

private func formatConformanceEvent(_ event: StdinEvent) -> String {
    switch event {
    case .key(_, let key):
        var parts = jsJSONStringify(key.name)
        if key.ctrl { parts += " ctrl" }
        if key.meta { parts += " meta" }
        if key.shift { parts += " shift" }
        if key.eventType != .press { parts += " \(key.eventType.rawValue)" }
        return "key(\(parts))"
    case .mouse(_, _, let mouse):
        return "mouse(\(mouse.type.rawValue) \(mouse.x),\(mouse.y) b\(mouse.button))"
    case .response(_, let sequence):
        return "response(\(jsJSONStringify(sequence)))"
    case .paste(let bytes):
        return "paste(\(jsJSONStringify(String(decoding: bytes, as: UTF8.self))))"
    }
}

private func makeProtocolContext(from context: StdinConformanceContext) -> StdinParserProtocolContext {
    var protocolContext = StdinParserProtocolContext(kittyKeyboardEnabled: context.kitty)
    for query in context.pending {
        switch query {
        case "cpr":
            protocolContext.explicitWidthCprActive = true
            protocolContext.startupCursorCprActive = true
        case "pixel":
            protocolContext.pixelResolutionQueryActive = true
        default:
            break
        }
    }
    return protocolContext
}

private func runConformanceRow(_ row: StdinConformanceRow, byteByByte: Bool) -> [String] {
    let options = StdinParserOptions(protocolContext: makeProtocolContext(from: row.context))
    var parser = StdinParser(options: options)
    var nowMs: Double = 0
    var output: [String] = []

    let stepsWithFinalTimeout = row.steps + [.timeout]
    for step in stepsWithFinalTimeout {
        switch step {
        case .timeout:
            nowMs += 20
            parser.flushTimeout(nowMs: nowMs)
        case .bytes(let bytes):
            if byteByByte {
                for b in bytes {
                    parser.push([b], nowMs: nowMs)
                }
            } else {
                parser.push(bytes, nowMs: nowMs)
            }
        }
        parser.drain { event in
            output.append(formatConformanceEvent(event))
        }
    }
    return output
}

// MARK: - Conformance Suite

@Suite("StdinParser Conformance Suite")
struct StdinConformanceTests {
    @Test("All stdin-parser.conformance.json rows pass whole-step")
    func conformanceWholeStep() throws {
        let rows = try StdinConformanceLoader.load()
        #expect(rows.count == 63)

        for row in rows {
            let actual = runConformanceRow(row, byteByByte: false)
            #expect(
                actual == row.expected,
                "Whole-step mismatch on row #\(row.index) '\(row.name)': got \(actual), expected \(row.expected)"
            )
        }
    }

    @Test("All stdin-parser.conformance.json rows pass 1-byte-at-a-time streaming")
    func conformanceByteByByte() throws {
        let rows = try StdinConformanceLoader.load()
        #expect(rows.count == 63)

        for row in rows {
            let actual = runConformanceRow(row, byteByByte: true)
            #expect(
                actual == row.expected,
                "Byte-by-byte mismatch on row #\(row.index) '\(row.name)': got \(actual), expected \(row.expected)"
            )
        }
    }
}

// MARK: - StdinParser & parseKeypress Unit Tests

@Suite("StdinParser Unit Tests")
struct StdinParserTests {
    @Test("KittyKeys table and terminalNamedSingleStrokeKeys")
    func kittyKeysAndSingleStrokeKeys() {
        #expect(keypadKeyNames == "0123456789./*-+=,")
        #expect(kittyKeyMap.count == 115)
        #expect(kittyKeyMap[27] == "escape")
        #expect(kittyKeyMap[57364] == "f1")
        #expect(kittyKeyMap[57398] == "f35")
        #expect(kittyKeyMap[57427] == "clear")
        #expect(kittyKeyMap[57454] == "iso_level5_shift")
        #expect(terminalNamedSingleStrokeKeys.first == "linefeed")
        #expect(terminalNamedSingleStrokeKeys.contains("space"))
        #expect(terminalNamedSingleStrokeKeys.contains("kp0"))
        #expect(terminalNamedSingleStrokeKeys.contains("*"))
        #expect(Set(terminalNamedSingleStrokeKeys).count == terminalNamedSingleStrokeKeys.count)
    }

    @Test("parseKeypress decodes ASCII, controls, arrows, function keys, and Kitty sequences")
    func parseKeypressBasics() throws {
        let lower = try #require(parseKeypress("a"))
        #expect(lower.name == "a")
        #expect(!lower.shift && !lower.ctrl && !lower.meta && !lower.option && !lower.number)
        #expect(lower.sequence == "a")
        #expect(lower.raw == "a")
        #expect(lower.source == .raw)

        let upper = try #require(parseKeypress("A"))
        #expect(upper.name == "a")
        #expect(upper.shift)
        #expect(upper.raw == "A")
        #expect(upper.sequence == "A")

        let digit = try #require(parseKeypress("7"))
        #expect(digit.name == "7")
        #expect(digit.number)

        let space = try #require(parseKeypress(" "))
        #expect(space.name == "space")
        #expect(space.sequence == " ")

        let ctrlSpace = try #require(parseKeypress([0x00]))
        #expect(ctrlSpace.name == "space")
        #expect(ctrlSpace.ctrl)

        let ctrlC = try #require(parseKeypress([0x03]))
        #expect(ctrlC.name == "c")
        #expect(ctrlC.ctrl)

        let lf = try #require(parseKeypress("\n"))
        #expect(lf.name == "linefeed")

        let cr = try #require(parseKeypress("\r"))
        #expect(cr.name == "return")

        let loneEsc = try #require(parseKeypress("\u{1B}"))
        #expect(loneEsc.name == "escape")

        let shiftTab = try #require(parseKeypress("\u{1B}[Z"))
        #expect(shiftTab.name == "tab")
        #expect(shiftTab.shift)
        #expect(shiftTab.code == "[Z")

        let altUp = try #require(parseKeypress("\u{1B}[1;3A"))
        #expect(altUp.name == "up")
        #expect(altUp.meta)
        #expect(altUp.option)
        #expect(altUp.code == "[A")

        let rxvtShiftDel = try #require(parseKeypress("\u{1B}[3$"))
        #expect(rxvtShiftDel.name == "delete")
        #expect(rxvtShiftDel.shift)
        #expect(rxvtShiftDel.code == "[3$")

        let linuxF1 = try #require(parseKeypress("\u{1B}[[A"))
        #expect(linuxF1.name == "f1")
        #expect(linuxF1.code == "[[A")

        let ss3Keypad = try #require(parseKeypress("\u{1B}Oj"))
        #expect(ss3Keypad.name == "*")
        #expect(ss3Keypad.sequence == "*")
        #expect(ss3Keypad.code == "Oj")

        let nonKeyMouse = parseKeypress("\u{1B}[<0;1;1M")
        #expect(nonKeyMouse == nil)
    }

    @Test("Kitty keyboard protocol: modifiers, repeat, release, base layout, shifted text, and IME text")
    func kittyKeyboardProtocol() throws {
        let kittyOpts = ParseKeypressOptions(useKittyKeyboard: true)

        // Ctrl+c on Cyrillic layout with baseCode = 99 ('c')
        let cyrCtrlC = try #require(parseKeypress("\u{1B}[1089::99;5u", options: kittyOpts))
        #expect(cyrCtrlC.name == "\u{0441}")
        #expect(cyrCtrlC.ctrl)
        #expect(cyrCtrlC.baseCode == 99)
        #expect(cyrCtrlC.source == .kitty)

        // Shift+a without explicit shifted codepoint uses upper() -> "A"
        let shiftA = try #require(parseKeypress("\u{1B}[97;2u", options: kittyOpts))
        #expect(shiftA.name == "a")
        #expect(shiftA.shift)
        #expect(shiftA.sequence == "A")
        #expect(shiftA.source == .kitty)

        // Repeat action keeps eventType == .press and sets repeated == true
        let repeatA = try #require(parseKeypress("\u{1B}[97;1:2u", options: kittyOpts))
        #expect(repeatA.eventType == .press)
        #expect(repeatA.repeated == true)

        // Release action sets eventType == .release
        let releaseA = try #require(parseKeypress("\u{1B}[97;1:3u", options: kittyOpts))
        #expect(releaseA.eventType == .release)
        #expect(releaseA.repeated == nil)

        // Functional key compat code
        let kittyEsc = try #require(parseKeypress("\u{1B}[27u", options: kittyOpts))
        #expect(kittyEsc.name == "escape")
        #expect(kittyEsc.code == "[27u")

        // Super + Hyper + CapsLock + NumLock modifiers: 1 + 8 + 16 + 64 + 128 = 217
        let superKey = try #require(parseKeypress("\u{1B}[97;217u", options: kittyOpts))
        #expect(superKey.super == true)
        #expect(superKey.hyper == true)
        #expect(superKey.capsLock == true)
        #expect(superKey.numLock == true)

        // IME text-only event (code 0 with associated text)
        let ime = try #require(parseKeypress("\u{1B}[0;1;104:105u", options: kittyOpts))
        #expect(ime.name == "hi")
        #expect(ime.sequence == "hi")
    }

    @Test("Bracketed paste streaming across large chunks and embedded false end markers")
    func bracketedPasteStreaming() throws {
        var parser = StdinParser()
        let payload = String(repeating: "abcdef0123456789", count: 1500) + "\u{1B}[20false\u{1B}\u{1B}[20"

        parser.push("\u{1B}[200~")
        #expect(parser.pasting)

        // Feed body in mixed chunks
        let bodyBytes = Array((payload + "\u{1B}[201~").utf8)
        var i = 0
        while i < bodyBytes.count {
            let chunkEnd = min(i + 137, bodyBytes.count)
            parser.push(Array(bodyBytes[i..<chunkEnd]))
            i = chunkEnd
        }

        #expect(!parser.pasting)
        let firstEvent = parser.read()
        let event = try #require(firstEvent)
        guard case .paste(let bytes) = event else {
            Issue.record("Expected paste event, got \(event)")
            return
        }
        #expect(decodePasteBytes(bytes) == payload)
    }

    @Test("Mouse SGR and X10 modifiers, scroll directions, and button release tracking")
    func mouseParsingDetails() throws {
        var parser = StdinParser()
        // SGR Shift+Alt+Ctrl left press at (10, 5) -> code 0 + 4 + 8 + 16 = 28
        parser.push("\u{1B}[<28;10;5M")
        // SGR scroll right (code 67) at (2, 3) -> button 0, direction .right
        parser.push("\u{1B}[<67;2;3M")
        // X10 middle press (button 1 -> 32+1=33 '!') at (1, 1 -> 34 '"'), then X10 release (button 3 -> 35 '#')
        parser.push([0x1B, 0x5B, 0x4D, 33, 34, 34, 0x1B, 0x5B, 0x4D, 35, 34, 34])

        var events: [StdinEvent] = []
        parser.drain { events.append($0) }
        #expect(events.count == 4)

        if case .mouse(_, let enc0, let m0) = events[0] {
            #expect(enc0 == .sgr)
            #expect(m0.type == .down)
            #expect(m0.button == 0)
            #expect(m0.x == 9 && m0.y == 4)
            #expect(m0.modifiers == MouseModifiers(shift: true, alt: true, ctrl: true))
        } else {
            Issue.record("Expected SGR mouse down")
        }

        if case .mouse(_, let enc1, let m1) = events[1] {
            #expect(enc1 == .sgr)
            #expect(m1.type == .scroll)
            #expect(m1.button == 0)
            #expect(m1.scroll == ScrollInfo(direction: .right, delta: 1))
        } else {
            Issue.record("Expected SGR scroll")
        }

        if case .mouse(_, let enc2, let m2) = events[2],
           case .mouse(_, let enc3, let m3) = events[3]
        {
            #expect(enc2 == .x10 && enc3 == .x10)
            #expect(m2.type == .down && m2.button == 1 && m2.x == 1 && m2.y == 1)
            #expect(m3.type == .up && m3.button == 1 && m3.x == 1 && m3.y == 1)
        } else {
            Issue.record("Expected X10 press and release")
        }
    }

    @Test("Suspend/resume preserves awaited reply prefix while dropping stale units")
    func suspendResumeAndReset() {
        var parser = StdinParser(
            options: StdinParserOptions(
                protocolContext: StdinParserProtocolContext(
                    privateCapabilityRepliesActive: true,
                    replySentinelActive: true
                )
            )
        )
        parser.push("\u{1B}[?62", nowMs: 0)
        parser.suspend()
        parser.resume()
        // Reply prefix is preserved after resume
        parser.push(";22c", nowMs: 50)
        var events: [StdinEvent] = []
        parser.drain { events.append($0) }
        #expect(events == [.response(protocol: .csi, sequence: "\u{1B}[?62;22c")])

        // Reset clears queued events and pending state
        parser.push("a", nowMs: 60)
        parser.reset()
        #expect(parser.read() == nil)

        // Destroy ignores subsequent pushes
        parser.destroy()
        #expect(parser.isDestroyed)
        parser.push("b", nowMs: 70)
        #expect(parser.read() == nil)
    }
}

// MARK: - Paste Unit Tests

@Suite("Paste Unit Tests")
struct PasteTests {
    @Test("decodePasteBytes handles UTF-8, BOM stripping, and invalid sequences")
    func decodePasteBytesTests() {
        #expect(decodePasteBytes(Array("hello 🌍 日本語".utf8)) == "hello 🌍 日本語")
        #expect(decodePasteBytes([0xEF, 0xBB, 0xBF, 0x68, 0x69]) == "hi")
        #expect(decodePasteBytes([0xFF, 0x61]) == "\u{FFFD}a")
        #expect(decodePasteBytes([]) == "")
    }

    @Test("stripAnsiSequences strips CSI, OSC, DCS, APC, C1, and lone/incomplete ESC")
    func stripAnsiSequencesTests() {
        #expect(stripAnsiSequences("plain text") == "plain text")
        #expect(stripAnsiSequences("text with \u{1B}[31mred\u{1B}[0m color") == "text with red color")
        // C1 CSI (U+009B)
        #expect(stripAnsiSequences("a\u{009B}32;1mb\u{009B}0mc") == "abc")
        // OSC terminated by BEL and ST
        #expect(stripAnsiSequences("hi\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\!") == "hilink!")
        // C1 OSC (U+009D) terminated by C1 ST (U+009C)
        #expect(stripAnsiSequences("x\u{009D}0;title\u{009C}y") == "xy")
        // DCS & APC
        #expect(stripAnsiSequences("a\u{1B}P1+r544E\u{1B}\\b\u{1B}_Ga=1\u{1B}\\c") == "abc")
        // Lone ESC and cut-off CSI
        #expect(stripAnsiSequences("abc\u{1B}") == "abc")
        #expect(stripAnsiSequences("abc\u{1B}[31") == "abc")
        // Other 2-byte ESC sequence (e.g. ESC 7, ESC ( B)
        #expect(stripAnsiSequences("\u{1B}7hello\u{1B}(B\u{1B}8") == "hello")
    }

    @Test("PasteKind and PasteMetadata value semantics")
    func pasteMetadataTests() {
        let meta = PasteMetadata(mimeType: "text/plain", kind: .text)
        #expect(meta.mimeType == "text/plain")
        #expect(meta.kind == .text)
    }
}

// MARK: - KeyHandler Unit Tests

@Suite("KeyHandler Unit Tests")
struct KeyHandlerTests {
    @Test("KeyHandler dispatches keypress, repeat, keyrelease, and paste events")
    func keyHandlerBasicDispatch() throws {
        let handler = InternalKeyHandler()
        var receivedPress: KeyEvent?
        var receivedRelease: KeyEvent?
        var receivedPaste: PasteEvent?

        let pressToken = handler.onKeypress { receivedPress = $0 }
        let releaseToken = handler.onKeyrelease { receivedRelease = $0 }
        let pasteToken = handler.onPaste { receivedPaste = $0 }

        let keyA = try #require(parseKeypress("a"))
        #expect(handler.processParsedKey(keyA))
        #expect(receivedPress?.name == "a")
        #expect(receivedRelease == nil)

        let releaseA = try #require(parseKeypress("\u{1B}[97;1:3u", options: ParseKeypressOptions(useKittyKeyboard: true)))
        #expect(handler.processParsedKey(releaseA))
        #expect(receivedRelease?.name == "a")
        #expect(receivedRelease?.eventType == .release)

        let pasteMeta = PasteMetadata(mimeType: "text/plain", kind: .text)
        handler.processPaste(Array("hello".utf8), metadata: pasteMeta)
        #expect(receivedPaste?.type == "paste")
        #expect(receivedPaste?.bytes == Array("hello".utf8))
        #expect(receivedPaste?.metadata == pasteMeta)

        handler.off(pressToken)
        handler.off(releaseToken)
        handler.off(pasteToken)
        receivedPress = nil
        _ = handler.processParsedKey(keyA)
        #expect(receivedPress == nil)
    }

    @Test("InternalKeyHandler priority ordering and preventDefault semantics")
    func internalKeyHandlerPreventDefault() throws {
        let handler = InternalKeyHandler()
        var order: [String] = []

        _ = handler.onInternalKeypress { _ in
            order.append("internal")
        }
        _ = handler.onKeypress { key in
            order.append("global1")
            key.preventDefault()
        }
        _ = handler.onKeypress { key in
            order.append(key.defaultPrevented ? "global2-prevented" : "global2")
        }

        let keyA = try #require(parseKeypress("a"))
        _ = handler.processParsedKey(keyA)

        // Global handlers run before internal; preventDefault lets later global handlers see defaultPrevented,
        // and blocks internal renderable handlers.
        #expect(order == ["global1", "global2-prevented"])
    }

    @Test("InternalKeyHandler stopPropagation stops subsequent global and internal handlers")
    func internalKeyHandlerStopPropagation() throws {
        let handler = InternalKeyHandler()
        var order: [String] = []

        _ = handler.onKeypress { key in
            order.append("global1")
            key.stopPropagation()
        }
        _ = handler.onKeypress { _ in
            order.append("global2")
        }
        _ = handler.onInternalKeypress { _ in
            order.append("internal")
        }

        let keyA = try #require(parseKeypress("a"))
        _ = handler.processParsedKey(keyA)
        #expect(order == ["global1"])

        // Internal handler can also stop subsequent internal handlers
        handler.removeAllListeners()
        order.removeAll()

        let internal1 = handler.onInternalKeypress { key in
            order.append("internal1")
            key.stopPropagation()
        }
        _ = handler.onInternalKeypress { _ in
            order.append("internal2")
        }
        _ = handler.processParsedKey(keyA)
        #expect(order == ["internal1"])

        // Removing internal1 allows internal2 to run
        handler.offInternal(internal1)
        order.removeAll()
        _ = handler.processParsedKey(keyA)
        #expect(order == ["internal2"])
    }

    @Test("InternalKeyHandler snapshots internal handlers so focus changes do not receive in-flight events")
    func internalKeyHandlerSnapshotSafety() throws {
        let handler = InternalKeyHandler()
        var order: [String] = []

        _ = handler.onInternalKeypress { _ in
            order.append("first")
            _ = handler.onInternalKeypress { _ in
                order.append("added-during-dispatch")
            }
        }

        let keyA = try #require(parseKeypress("a"))
        _ = handler.processParsedKey(keyA)
        #expect(order == ["first"])

        // Next keypress invokes both
        order.removeAll()
        _ = handler.processParsedKey(keyA)
        #expect(order == ["first", "added-during-dispatch"])
    }

    @Test("PasteEvent supports preventDefault and stopPropagation")
    func pasteEventPropagation() {
        let handler = InternalKeyHandler()
        var order: [String] = []

        _ = handler.onPaste { event in
            order.append("global1")
            event.preventDefault()
        }
        _ = handler.onInternalPaste { _ in
            order.append("internal")
        }

        handler.processPaste(Array("abc".utf8))
        #expect(order == ["global1"])

        handler.removeAllListeners()
        order.removeAll()

        _ = handler.onPaste { event in
            order.append("global1")
            event.stopPropagation()
        }
        _ = handler.onPaste { _ in
            order.append("global2")
        }
        handler.processPaste(Array("abc".utf8))
        #expect(order == ["global1"])
    }
}
